-- sim/standard_reroll.lua
--
-- The Standard deck's proposed bonus: "a stack loss is rerolled N times
-- (N = deck level), keep the smallest loss." Run through the engine's own
-- outcome pipeline (models/outcome_math.buildOutcome) at every stake, for
-- every cash game type, naked and with the run upgrades fully filled.
--
--   lua sim/standard_reroll.lua            (the table)
--   lua sim/standard_reroll.lua capstone   (rerolls draw from the whole
--                                           outcome, keep the best)
--   lua sim/standard_reroll.lua --sample   (Monte Carlo the LIVE
--                                           sampleOutcome, 6-Max, against
--                                           the analytic numbers)
--
-- A reroll redraws the loss tier from the stake's effective loss_dist, so
-- the chance a stack loss survives N rerolls is stack^(N+1); with the
-- capstone each redraw is a fresh (win?, tier) draw and the stack loss
-- survives only if every redraw is a stack loss too: ((1-wc)*stack)^N.

io.stdout:setvbuf("no")
love = { math = { random = math.random }, timer = { getTime = os.clock } }
package.path = package.path .. ";./?.lua"

local OutcomeMath = require("models.outcome_math")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")

local capstone = arg and arg[1] == "capstone"
local sample   = arg and arg[1] == "--sample"

-- The implementation against the arithmetic: roll sampleOutcome with the
-- ctx the deck writes (stack_loss_rerolls, stack_loss_reroll_wins) and
-- count stack losses per hand. Sampling noise on 40k hands is about
-- +-0.3% at the top stakes; the low stakes read 0 either way.
if sample then
    local N = 40000
    local gt
    for _, g in ipairs(GameTypes) do if g.id == "six_max" then gt = g end end
    local function fullCtx(levels)
        local fill = { { strength = levels } }
        return { win_chance_fills = fill, win_dist_fills = fill, loss_dist_fills = fill }
    end
    print(("Live sampleOutcome, six_max, %d hands per cell: stack-loss %% (analytic in brackets)"):format(N))
    print(("%-5s %-6s %14s %14s %14s"):format("stake", "build", "L0", "L5", "L5+capstone"))
    for _, st in ipairs(Stakes) do
        if st.id ~= "s010" then
            for _, build in ipairs{ "naked", "full" } do
                local base = build == "full" and fullCtx(st.fill_window.complete) or {}
                local wc, wd, ld = OutcomeMath.buildOutcome(build == "full" and base or nil, gt, st)
                local cells = {}
                for _, cfg in ipairs{ { 0, false }, { 5, false }, { 5, true } } do
                    local ctx = { stack_loss_rerolls = cfg[1], stack_loss_reroll_wins = cfg[2] }
                    local hits = 0
                    for _ = 1, N do
                        local won, tier = OutcomeMath.sampleOutcome(wc, wd, ld, ctx, gt)
                        if not won and tier == "stack" then hits = hits + 1 end
                    end
                    local p_loss, p_stack = 1 - wc, ld.stack or 0
                    local expect
                    if cfg[2] then expect = p_loss * p_stack * ((p_loss * p_stack) ^ cfg[1])
                    else expect = p_loss * (p_stack ^ (cfg[1] + 1)) end
                    cells[#cells + 1] = ("%6.2f%% [%5.2f%%]"):format(hits / N * 100, expect * 100)
                end
                print(("%-5s %-6s %s"):format(st.id, build, table.concat(cells, " ")))
            end
        end
    end
    os.exit(0)
end

local gtypes = {}
for _, gt in ipairs(GameTypes) do
    if gt.id ~= "ko" then gtypes[#gtypes + 1] = gt end
end

-- A ctx whose fills top out every stake's window (levels = complete).
local function fullCtx(levels)
    local fill = { { strength = levels } }
    return { win_chance_fills = fill, win_dist_fills = fill, loss_dist_fills = fill }
end

local function pct(p)
    if p == 0 then return "0" end
    if p >= 0.01 then return ("%.1f%%"):format(p * 100) end
    if p >= 0.0001 then return ("%.3f%%"):format(p * 100) end
    return ("1 in %s"):format(tostring(math.floor(1 / p + 0.5)))
end

print(("Standard reroll%s: chance a HAND is a stack loss, by deck level (0 = no deck)"):format(capstone and " + capstone" or ""))
print("naked = no run upgrades; full = the stake's window filled (levels = complete)")
print()
for _, gt in ipairs(gtypes) do
    print(("== %s =="):format(gt.id))
    print(("%-5s %-6s %10s %10s %10s %10s %10s %10s   %s"):format("stake", "build", "L0", "L1", "L2", "L3", "L5", "L0/L5", "loss tier stack share"))
    for _, st in ipairs(Stakes) do
        if st.id ~= "s010" then
            for _, build in ipairs{ "naked", "full" } do
                local ctx = build == "full" and fullCtx(st.fill_window.complete) or nil
                local wc, _, ld = OutcomeMath.buildOutcome(ctx, gt, st)
                local p_loss  = 1 - wc
                local p_stack = ld.stack or 0
                local row = {}
                local per = {}
                for _, n in ipairs{ 0, 1, 2, 3, 5 } do
                    local p
                    if capstone then
                        p = p_loss * p_stack * ((p_loss * p_stack) ^ n)
                    else
                        p = p_loss * (p_stack ^ (n + 1))
                    end
                    per[#per + 1] = p
                    row[#row + 1] = ("%10s"):format(pct(p))
                end
                local ratio = per[1] > 0 and per[5] > 0 and per[1] / per[5] or 0
                print(("%-5s %-6s %s %10s   %.3f"):format(st.id, build, table.concat(row, " "),
                      ratio > 0 and ("%.0fx"):format(ratio) or "-", p_stack))
            end
        end
    end
    print()
end
