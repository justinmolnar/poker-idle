-- sim/gen_preflop_equity.lua
--
-- Generates data/preflop_equity.lua: heads-up preflop equity for all
-- 169 × 169 canonical starting-hand matchups (models/HandClass), plus each
-- class's equity against a random hand.
--
-- Monte Carlo, not enumeration: an exact answer needs C(48,5) = 1.7M
-- boards per matchup, and this table only has to be good enough to SAMPLE
-- matchups into 2.5%-wide bands. A few thousand trials per matchup puts
-- the standard error near half a percent, far inside a band.
--
-- Deliberately scores with the live models/HandEval — the same evaluator
-- the game uses at showdown — so a matchup the table calls 65% really does
-- win 65% of the boards the game will deal it.
--
-- ─── Running it ─────────────────────────────────────────────────────────
-- A FULL RUN MUST USE THE STANDALONE INTERPRETER:
--
--   lua sim/gen_preflop_equity.lua [trials] [seed]
--
-- Not LÖVE. LÖVE is roughly twice as fast here (it runs LuaJIT), but the
-- whole generation happens inside love.load(), and a LÖVE process whose
-- window never reaches the event loop is killed a couple of minutes in —
-- a full run reproducibly dies around 40% with no error. The short modes
-- below finish well inside that window and are fine under either:
--
--   lovec.exe sim --gen-equity bench          time a sample, project a run
--   lovec.exe sim --gen-equity anchors [n]    check against known equities
--
-- Wall time on the standalone interpreter is about 185 µs per trial:
-- 1500 trials over 14,196 matchups is a bit over an hour. Trials buy
-- precision as 0.5/√n, so 1500 lands near ±1.3 points — comfortably
-- inside the 12.5-to-25-point bands data/showdown_realism.lua samples,
-- and there is little reason to pay for more.
--
-- Only the upper triangle is simulated; the mirror is exact
-- (M[j][i] = 1000 − M[i][j]) because equity is tie-split, and the
-- diagonal is exactly 500 for the same reason.

io.stdout:setvbuf("no")

-- Love shim BEFORE any require (models call love.math.random inline).
-- Under LÖVE the real love table already exists — don't clobber it.
local argv = rawget(_G, "GEN_EQUITY_ARGS") or arg or {}
local bench_mode = (argv[1] == "bench")
local TRIALS = tonumber(bench_mode and argv[2] or argv[1]) or 3000
local SEED   = tonumber(bench_mode and argv[3] or argv[2]) or 12345

if not rawget(_G, "love") then
    math.randomseed(SEED)
    love = {
        math  = { random = math.random },
        timer = { getTime = os.clock },
    }
    package.path = package.path .. ";./?.lua"
else
    love.math.setRandomSeed(SEED)
end

local Card      = require("models.Card")
local HandEval  = require("models.HandEval")
local HandClass = require("models.HandClass")

local N        = HandClass.COUNT
local random   = love.math.random
local clock    = os.clock

-- ── Card pool ───────────────────────────────────────────────────────────
-- 52 Card objects built once. Trials reference them by index; nothing
-- allocates a Card in the inner loop.

local POOL, POOL_INDEX = {}, {}
do
    local n = 0
    for _, suit in ipairs(Card.SUITS) do
        for _, rank in ipairs(Card.RANKS) do
            n = n + 1
            POOL[n] = Card:new(suit, rank)
            POOL_INDEX[suit .. rank] = n
        end
    end
    assert(n == 52)
end

-- Concrete (pool index, pool index) combinations for each class, so a
-- trial picks a suit configuration with one random draw.
local CLASS_COMBOS = {}
do
    for i = 1, N do
        local rank_hi, rank_lo = HandClass.ranks(i)
        local flat = {}
        for _, combo in ipairs(HandClass.comboSuits(i)) do
            flat[#flat + 1] = {
                POOL_INDEX[combo[1] .. rank_hi],
                POOL_INDEX[combo[2] .. rank_lo],
            }
        end
        assert(#flat == HandClass.comboCount(i),
            ("class %s: %d combos, expected %d")
            :format(HandClass.name(i), #flat, HandClass.comboCount(i)))
        CLASS_COMBOS[i] = flat
    end
end

-- ── One matchup ─────────────────────────────────────────────────────────
-- Scratch tables reused across every trial: the inner loop allocates
-- nothing, which is most of the difference between an hour and a night.

local blocked   = {}          -- [pool idx] = true for the 4 hole cards
local avail     = {}          -- 48 pool indices
local p_cards   = { nil, nil, nil, nil, nil, nil, nil }
local d_cards   = { nil, nil, nil, nil, nil, nil, nil }

-- Player-class `i` vs opponent-class `j`, `trials` boards. Returns permille
-- equity for i (win + tie/2), rounded.
local function simulate(i, j, trials)
    local combos_i, combos_j = CLASS_COMBOS[i], CLASS_COMBOS[j]
    local ni, nj = #combos_i, #combos_j
    local score = 0        -- 2 per win, 1 per tie (halves without floats)

    for _ = 1, trials do
        -- Pick a suit configuration for each side that doesn't collide.
        local ci, cj, a1, a2, b1, b2
        repeat
            ci = combos_i[random(ni)]
            cj = combos_j[random(nj)]
            a1, a2 = ci[1], ci[2]
            b1, b2 = cj[1], cj[2]
        until a1 ~= b1 and a1 ~= b2 and a2 ~= b1 and a2 ~= b2

        blocked[a1], blocked[a2] = true, true
        blocked[b1], blocked[b2] = true, true
        local n_avail = 0
        for k = 1, 52 do
            if not blocked[k] then
                n_avail = n_avail + 1
                avail[n_avail] = k
            end
        end
        blocked[a1], blocked[a2] = nil, nil
        blocked[b1], blocked[b2] = nil, nil

        p_cards[1], p_cards[2] = POOL[a1], POOL[a2]
        d_cards[1], d_cards[2] = POOL[b1], POOL[b2]

        -- Partial Fisher-Yates: 5 board cards off the front of `avail`.
        for s = 1, 5 do
            local pick = random(s, n_avail)
            avail[s], avail[pick] = avail[pick], avail[s]
            local card = POOL[avail[s]]
            p_cards[s + 2] = card
            d_cards[s + 2] = card
        end

        local p_rank = HandEval.bestFiveOfN(p_cards)
        local d_rank = HandEval.bestFiveOfN(d_cards)
        local cmp = HandEval.compare(p_rank, d_rank)
        if cmp > 0 then score = score + 2
        elseif cmp == 0 then score = score + 1 end
    end

    -- score / (2 * trials) in permille.
    return math.floor(score * 1000 / (2 * trials) + 0.5)
end

-- ── Bench mode ──────────────────────────────────────────────────────────

-- ── Anchor mode ─────────────────────────────────────────────────────────
-- Simulates only the well-known matchups, at high trial counts, so a
-- suspicious full-run anchor can be told from sampling noise.

if argv[1] == "anchors" then
    local n = tonumber(argv[2]) or 20000
    local ANCHORS = {
        { "AKs", "QQ",  46.0 },
        { "AKo", "QQ",  43.0 },
        { "AKo", "22",  47.0 },
        { "AA",  "KK",  82.0 },
        { "AA",  "72o", 88.0 },
        { "JTs", "AA",  19.0 },
        { "99",  "AKs", 52.0 },
        { "AQo", "KJs", 61.0 },
    }
    print(string.format("anchors: %d trials each", n))
    local worst = 0
    for _, a in ipairs(ANCHORS) do
        local i, j = HandClass.INDEX[a[1]], HandClass.INDEX[a[2]]
        local eq = simulate(i, j, n) / 10
        local diff = eq - a[3]
        if math.abs(diff) > math.abs(worst) then worst = diff end
        print(string.format("  %-4s vs %-4s  %5.1f%%   published %5.1f%%   diff %+.1f",
            a[1], a[2], eq, a[3], diff))
    end
    print(string.format("worst deviation: %+.1f points", worst))
    return
end

if bench_mode then
    local sample = { {1,1}, {2,20}, {50,120}, {169,80}, {13,140} }
    local n = 2000
    local t0 = clock()
    for _, pair in ipairs(sample) do simulate(pair[1], pair[2], n) end
    local dt = clock() - t0
    local trials_done = n * #sample
    local per = dt / trials_done
    print(string.format("bench: %d trials in %.2fs  →  %.1f µs/trial",
        trials_done, dt, per * 1e6))
    local n_pairs = N * (N - 1) / 2
    for _, t in ipairs({ 1000, 2000, 3000, 10000 }) do
        print(string.format("  %5d trials/pair over %d pairs → %.1f min",
            t, n_pairs, n_pairs * t * per / 60))
    end
    return
end

-- ── Full run ────────────────────────────────────────────────────────────

print(string.format("gen_preflop_equity: %d classes, %d trials/pair, seed %d",
    N, TRIALS, SEED))

local M = {}
for i = 1, N do
    M[i] = {}
    M[i][i] = 500
end

local n_pairs   = N * (N - 1) / 2
local done      = 0
local t_start   = clock()
local next_mark = 0

for i = 1, N do
    for j = i + 1, N do
        local eq = simulate(i, j, TRIALS)
        M[i][j] = eq
        M[j][i] = 1000 - eq
        done = done + 1
    end
    if done >= next_mark then
        local frac    = done / n_pairs
        local elapsed = clock() - t_start
        local eta     = frac > 0 and (elapsed / frac - elapsed) or 0
        print(string.format("  %5.1f%%  (%s)  elapsed %.1f min, eta %.1f min",
            100 * frac, HandClass.name(i), elapsed / 60, eta / 60))
        next_mark = done + math.floor(n_pairs / 20)
    end
end

-- Equity vs a random hand: combo-weighted average across the row. The
-- card-removal error from ignoring blocked combos is far below the
-- precision anything downstream needs.
local eq_vs_random = {}
for i = 1, N do
    local sum, wsum = 0, 0
    for j = 1, N do
        local w = HandClass.comboCount(j)
        sum  = sum + M[i][j] * w
        wsum = wsum + w
    end
    eq_vs_random[i] = math.floor(sum / wsum + 0.5)
end

-- ── Sanity anchors ──────────────────────────────────────────────────────

local function eqOf(a, b)
    return M[HandClass.INDEX[a]][HandClass.INDEX[b]] / 10
end
print("")
print("sanity anchors (published values in parens):")
print(string.format("  AA vs random   %.1f%%  (85.2%%)", eq_vs_random[HandClass.INDEX["AA"]] / 10))
print(string.format("  AKs vs QQ      %.1f%%  (46.0%%)", eqOf("AKs", "QQ")))
print(string.format("  AKo vs 22      %.1f%%  (47.0%%)", eqOf("AKo", "22")))
print(string.format("  KK vs AA       %.1f%%  (18.0%%)", eqOf("KK", "AA")))
print(string.format("  72o vs random  %.1f%%  (~34%%)", eq_vs_random[HandClass.INDEX["72o"]] / 10))

local best_i, worst_i = 1, 1
for i = 2, N do
    if eq_vs_random[i] > eq_vs_random[best_i]  then best_i  = i end
    if eq_vs_random[i] < eq_vs_random[worst_i] then worst_i = i end
end
print(string.format("  best vs random:  %s (%.1f%%)",
    HandClass.name(best_i), eq_vs_random[best_i] / 10))
print(string.format("  worst vs random: %s (%.1f%%)",
    HandClass.name(worst_i), eq_vs_random[worst_i] / 10))

-- ── Emit ────────────────────────────────────────────────────────────────

local out = {}
out[#out + 1] = [[
-- data/preflop_equity.lua
--
-- ═══════════════════════════════════════════════════════════════════════
-- GENERATED FILE — DO NOT HAND-EDIT
-- Regenerate with:
--   lua sim/gen_preflop_equity.lua [trials] [seed]
-- (the standalone interpreter, NOT LÖVE — see the generator's header)
-- Source: sim/gen_preflop_equity.lua
-- ═══════════════════════════════════════════════════════════════════════
--
-- Heads-up preflop equity for every pair of the 169 canonical starting
-- hands, in models/HandClass index order (1 = AA, 2 = AKs, 3 = AKo, …).
-- Read through models/PreflopEquity, never directly.
--
-- rows[i] is a 507-character string: 169 fixed-width 3-digit PERMILLE
-- values. Entry j (characters 3j-2 .. 3j) is class i's equity against
-- class j, counting a tie as half a win. Packed as strings because 169
-- interned strings cost a fraction of what 28,561 numeric table slots
-- would, and this ships in the web build.
--
-- eq_vs_random[i] is class i's permille equity against a uniformly random
-- hand — the playability ordering the showdown range weighting uses.
]]
out[#out + 1] = string.format([[
return {
    trials_per_pair = %d,
    seed            = %d,

    -- class order: models/HandClass.NAMES
    rows = {
]], TRIALS, SEED)

local buf = {}
for i = 1, N do
    for j = 1, N do
        buf[j] = string.format("%03d", M[i][j])
    end
    out[#out + 1] = string.format('        "%s",   -- %s\n',
        table.concat(buf), HandClass.name(i))
end
out[#out + 1] = "    },\n\n    eq_vs_random = {\n"
for i = 1, N, 13 do
    local line = {}
    for j = i, math.min(i + 12, N) do
        line[#line + 1] = string.format("%3d,", eq_vs_random[j])
    end
    out[#out + 1] = "        " .. table.concat(line, " ") .. "\n"
end
out[#out + 1] = "    },\n}\n"

local path = "data/preflop_equity.lua"
local f, err = io.open(path, "w")
if not f then
    print("ERROR: could not write " .. path .. ": " .. tostring(err))
    return
end
f:write(table.concat(out))
f:close()

print("")
print(string.format("wrote %s in %.1f min", path, (clock() - t_start) / 60))
