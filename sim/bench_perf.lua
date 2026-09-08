-- sim/bench_perf.lua
--
-- The optimization pass's stopwatch. Times the hot paths the audit named
-- (docs/optimization-audit-2026-09.md) so each phase of
-- docs/optimization-plan-2026-09.md can be diffed against the one before.
--
-- Headless: `lua sim/bench_perf.lua` from the repo root. Fixed seed and
-- fixed output shape, so two runs diff cleanly.
--
-- These are PUC Lua numbers. The game runs LuaJIT, where the arithmetic is
-- several times faster but the allocation-heavy paths gain much less —
-- read the RATIO between runs, not the absolute milliseconds.

io.stdout:setvbuf("no")
local cwd = (love and love.filesystem and love.filesystem.getWorkingDirectory()) or "."
package.path = package.path .. ";" .. cwd .. "/?.lua"

-- ─── LÖVE shim (same shape as sim/harness.lua) ─────────────────────────
local function rnd(a, b)
    if a and b then return math.random(a, b) end
    if a then return math.random(a) end
    return math.random()
end
love = love or {}
love.math   = love.math or {}
love.math.random = rnd
love.timer  = { getTime = function() return os.clock() end }
love.graphics = setmetatable({
    getDimensions = function() return 1600, 900 end,
    getColor      = function() return 1, 1, 1, 1 end,
}, { __index = function() return function() end end })
love.filesystem = {
    getInfo = function() return nil end,
    read    = function() return nil end,
    write   = function() return true end,
}

local SEED = 20260908
math.randomseed(SEED)

local CatalogLoader = require("models.catalog_loader")
CatalogLoader.deriveAll(require("data.catalog"))

local Gauntlet    = require("models.Gauntlet")
local HandEval    = require("models.HandEval")
local Deck        = require("models.Deck")
local HandRealism = require("models.HandRealism")
local OutcomeMath = require("models.outcome_math")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")

-- ─── Reporting ─────────────────────────────────────────────────────────
local rows = {}
local function report(label, avg_ms, worst_ms)
    rows[#rows + 1] = { label = label, avg = avg_ms, worst = worst_ms }
end

local function timeN(label, n, fn)
    local worst, total = 0, 0
    for i = 1, n do
        local t0 = os.clock()
        fn(i)
        local dt = os.clock() - t0
        total = total + dt
        if dt > worst then worst = dt end
    end
    report(label, total / n * 1000, worst * 1000)
end

-- ─── 1. Hand evaluation ────────────────────────────────────────────────
do
    local d = Deck:new()
    local cards = {}
    for i = 1, 7 do cards[i] = d:draw() end
    local N = 20000
    local t0 = os.clock()
    for _ = 1, N do HandEval.bestFiveOfN(cards) end
    report("bestFiveOfN(7)", (os.clock() - t0) / N * 1000, nil)

    -- score() lands in Phase 5; bench it once it exists so the two can be
    -- compared directly on the same deal.
    if HandEval.score then
        t0 = os.clock()
        for _ = 1, N do HandEval.score(cards, 7) end
        report("score(7)", (os.clock() - t0) / N * 1000, nil)
    end
end

-- ─── 2. The gauntlet, by outcome pattern ───────────────────────────────
-- The construction cost is wildly asymmetric: a first-runout loss is one
-- deal, while "win, win, then robbed" has to find a board that supports
-- all three. This is the shove's stall.
do
    local game  = { state = { shove_r1_won = true, shove_r2_won = true } }
    local rates = { r1 = 0.5, r2 = 0.4, r3 = 0.3, clear = 0.06 }
    local cases = {
        { "gauntlet R1 loss",          { false, false, false } },
        { "gauntlet R1w R2 loss",      { true,  false, false } },
        { "gauntlet R1w R2w R3 loss",  { true,  true,  false } },
        { "gauntlet full clear",       { true,  true,  true  } },
    }
    for _, case in ipairs(cases) do
        timeN(case[1], 40, function()
            Gauntlet:new(game, rates):begin(case[2])
        end)
    end
end

-- ─── 3. Per-deal showdown construction (models/Table:deal) ─────────────
do
    for _, tier in ipairs({ "small", "stack" }) do
        timeN("constructShowdownHand " .. tier, 200, function(i)
            HandRealism.constructShowdownHand(i % 2 == 0, tier,
                                              { gtype_id = "six_max" })
        end)
    end
end

-- ─── 4. The EV math the UI calls per table per frame ───────────────────
do
    local ctx = {
        win_chance_fills  = { { strength = 1 }, { strength = 1 }, { strength = 1 } },
        win_dist_fills    = { { strength = 1 } },
        loss_dist_fills   = {},
        win_chance_shifts = { { amount = 0.01 } },
        earnings_mult     = 1.2,
    }
    local stake = Stakes[3] or Stakes[1]
    local cash, ko
    for _, g in ipairs(GameTypes) do
        if g.chip_stack_table then ko = ko or g else cash = cash or g end
    end
    cash = cash or GameTypes[1]

    local N = 5000
    local function per(label, fn)
        local t0 = os.clock()
        for _ = 1, N do fn() end
        report(label, (os.clock() - t0) / N * 1000, nil)
    end
    per("evStats cash",  function() OutcomeMath.evStats(ctx, cash, stake) end)
    if ko then
        per("evStats ko", function() OutcomeMath.evStats(ctx, ko, stake) end)
    end
    per("buildOutcome",  function() OutcomeMath.buildOutcome(ctx, cash, stake) end)
end

-- ─── Output ────────────────────────────────────────────────────────────
print(string.format("bench_perf  seed=%d  %s", SEED, _VERSION))
print(string.rep("-", 58))
print(string.format("%-30s %10s %14s", "case", "avg ms", "worst ms"))
for _, r in ipairs(rows) do
    print(string.format("%-30s %10.3f %14s", r.label, r.avg,
        r.worst and string.format("%.3f", r.worst) or "-"))
end
print(string.rep("-", 58))
