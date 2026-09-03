-- sim/verify_showdown_realism.lua
--
-- Headless conformance harness for the showdown-realism policies
-- (data/showdown_realism.lua). Runs the REAL construction code — the
-- gauntlet's joint construction with runner out-count bands, and (phase 3)
-- the cash-table matchup sampler — many times per scenario and asserts the
-- shown cards obey the policy, printing distributions for eyeballing.
--
-- Run headless from the repo root:
--   lua sim/verify_showdown_realism.lua [seed] [n_per_case]
--   e.g.  lua sim/verify_showdown_realism.lua 12345 300
--
-- Exits nonzero on any assertion failure (prints FAIL lines first).

io.stdout:setvbuf("no")

-- Love shim BEFORE any require (models call love.math.random inline).
-- Under LÖVE (`lovec sim --verify-realism`) the real love table exists.
local argv = rawget(_G, "VERIFY_REALISM_ARGS") or arg or {}
local seed = tonumber(argv[1]) or 12345
local N    = tonumber(argv[2]) or 300

if not rawget(_G, "love") then
    math.randomseed(seed)
    love = {
        math  = { random = math.random },
        timer = { getTime = os.clock },
    }
    package.path = package.path .. ";./?.lua"
else
    love.math.setRandomSeed(seed)
end

local Gauntlet        = require("models.Gauntlet")
local HandEval        = require("models.HandEval")
local HandClass       = require("models.HandClass")
local HandRealism     = require("models.HandRealism")
local PreflopEquity   = require("models.PreflopEquity")
local ShowdownRealism = require("data.showdown_realism")

local failures = 0
local function check(ok, fmt, ...)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. string.format(fmt, ...))
    end
end

local function pct(n, d) return d > 0 and (100 * n / d) or 0 end

local function histogramLine(counts, max_key)
    local parts = {}
    for k = 0, max_key do
        if counts[k] and counts[k] > 0 then
            parts[#parts + 1] = string.format("%d:%d", k, counts[k])
        end
    end
    return table.concat(parts, " ")
end

-- ═══ Gauntlet half ══════════════════════════════════════════════════════

local pol = ShowdownRealism.gauntlet

-- Forced outcome triples and what each must produce. Gauntlet:begin
-- coerces nils to false, so {true} means "win R1, robbed at c6".
local CASES = {
    { name = "R1 loss",      forced = { false },             board = 5 },
    { name = "robbed at c6", forced = { true },              board = 6 },
    { name = "robbed at c7", forced = { true, true },        board = 7 },
    { name = "full win",     forced = { true, true, true },  board = 7 },
}

print(string.format(
    "verify_showdown_realism  seed=%d  n_per_case=%d", seed, N))
print(string.format(
    "gauntlet policy: rob_outs=[%d,%d] max_sweat=%d strict=%d",
    pol.rob_outs[1], pol.rob_outs[2], pol.max_sweat_outs,
    pol.strict_attempts))
print("")

-- Allowance for the relaxed tail: attempts past strict_attempts may use
-- the wider bands, so strict-band conformance is asserted at >= 95%.
local STRICT_MIN = 0.95

for _, case in ipairs(CASES) do
    local game_stub = { state = {} }
    local n_natural, n_board_ok = 0, 0
    local n_c6_in_band, n_c6_present = 0, 0
    local n_c7_in_band, n_c7_present = 0, 0
    local n_sweat_ok_c6, n_sweat_ok_c7 = 0, 0
    local n_r1_floor, n_winner_ok = 0, 0
    local n_draws = 0
    local c6_hist, c7_hist = {}, {}
    local t0 = os.clock()

    for _ = 1, N do
        local g = Gauntlet:new(game_stub, { r1 = 0, r2 = 0, r3 = 0 })
        local result = g:begin(case.forced)

        -- Outcomes must equal the forced triple (coerced), always.
        local want2 = case.forced[2] and true or false
        local want3 = case.forced[3] and true or false
        check(result.outcomes[1] == (case.forced[1] and true or false)
              and (result.outcomes[2] == want2 or result.outcomes[2] == nil)
              and (result.outcomes[3] == want3 or result.outcomes[3] == nil),
              "%s: outcomes drifted from forced triple", case.name)

        local all_natural = result.natural[1] ~= false
            and result.natural[2] ~= false and result.natural[3] ~= false
        if all_natural then n_natural = n_natural + 1 end
        if #result.board == case.board then n_board_ok = n_board_ok + 1 end

        -- Per-runout winner correctness straight from the evals
        -- (draw-never-wins comes free: eval.won is strict compare > 0).
        for i = 1, 3 do
            local ev = result.evals[i]
            if ev and result.outcomes[i] ~= nil then
                if ev.won ~= result.outcomes[i] then
                    n_draws = n_draws + 1
                end
            end
        end

        -- R1 category floor: the runout-1 winner shows at least a pair.
        local ev1 = result.evals[1]
        if ev1 then
            local winner_rank = result.outcomes[1] and ev1.player_rank
                                                    or ev1.dealer_rank
            if winner_rank[1] >= 2 then n_r1_floor = n_r1_floor + 1 end
            if (HandEval.compare(ev1.player_rank, ev1.dealer_rank) > 0)
               == result.outcomes[1] then
                n_winner_ok = n_winner_ok + 1
            end
        end

        -- Out-count bands.
        local outs = result.outs or {}
        if outs.c6 then
            c6_hist[outs.c6] = (c6_hist[outs.c6] or 0) + 1
            if case.forced[1] and not case.forced[2] then
                -- robbery at c6
                n_c6_present = n_c6_present + 1
                if outs.c6 >= pol.rob_outs[1] and outs.c6 <= pol.rob_outs[2] then
                    n_c6_in_band = n_c6_in_band + 1
                end
            else
                -- survived c6: sweat cap
                if outs.c6 <= pol.max_sweat_outs then
                    n_sweat_ok_c6 = n_sweat_ok_c6 + 1
                end
            end
        end
        if outs.c7 then
            c7_hist[outs.c7] = (c7_hist[outs.c7] or 0) + 1
            if case.forced[2] and not case.forced[3] then
                n_c7_present = n_c7_present + 1
                if outs.c7 >= pol.rob_outs[1] and outs.c7 <= pol.rob_outs[2] then
                    n_c7_in_band = n_c7_in_band + 1
                end
            else
                if outs.c7 <= pol.max_sweat_outs then
                    n_sweat_ok_c7 = n_sweat_ok_c7 + 1
                end
            end
        end
    end

    local dt = os.clock() - t0
    print(string.format("── %s  (%.1fs, %.0fms/gauntlet)",
        case.name, dt, 1000 * dt / N))
    print(string.format("  natural: %.1f%%   board=%d: %.1f%%   winner-matches: %.1f%%   r1 floor(≥pair): %.1f%%",
        pct(n_natural, N), case.board, pct(n_board_ok, N),
        pct(n_winner_ok, N), pct(n_r1_floor, N)))

    check(n_natural >= N * 0.99, "%s: natural rate %.1f%% < 99%%",
          case.name, pct(n_natural, N))
    check(n_board_ok == N, "%s: wrong board size in %d/%d runs",
          case.name, N - n_board_ok, N)
    check(n_draws == 0, "%s: %d runout evals disagreed with outcomes",
          case.name, n_draws)
    check(n_winner_ok == N, "%s: R1 winner mismatch in %d/%d",
          case.name, N - n_winner_ok, N)
    check(n_r1_floor >= N * STRICT_MIN,
          "%s: r1 category floor %.1f%% < %.0f%%",
          case.name, pct(n_r1_floor, N), 100 * STRICT_MIN)

    if n_c6_present > 0 then
        print(string.format("  c6 rob-outs in band [%d,%d]: %.1f%%   hist: %s",
            pol.rob_outs[1], pol.rob_outs[2],
            pct(n_c6_in_band, n_c6_present), histogramLine(c6_hist, 43)))
        check(n_c6_in_band >= n_c6_present * STRICT_MIN,
              "%s: c6 rob band conformance %.1f%%",
              case.name, pct(n_c6_in_band, n_c6_present))
    elseif next(c6_hist) then
        print(string.format("  c6 sweat-outs (≤%d ok): %.1f%%   hist: %s",
            pol.max_sweat_outs, pct(n_sweat_ok_c6, N),
            histogramLine(c6_hist, 43)))
        check(n_sweat_ok_c6 >= N * STRICT_MIN,
              "%s: c6 sweat cap conformance %.1f%%",
              case.name, pct(n_sweat_ok_c6, N))
    end
    if n_c7_present > 0 then
        print(string.format("  c7 rob-outs in band [%d,%d]: %.1f%%   hist: %s",
            pol.rob_outs[1], pol.rob_outs[2],
            pct(n_c7_in_band, n_c7_present), histogramLine(c7_hist, 42)))
        check(n_c7_in_band >= n_c7_present * STRICT_MIN,
              "%s: c7 rob band conformance %.1f%%",
              case.name, pct(n_c7_in_band, n_c7_present))
    elseif next(c7_hist) then
        print(string.format("  c7 sweat-outs (≤%d ok): %.1f%%   hist: %s",
            pol.max_sweat_outs, pct(n_sweat_ok_c7, N),
            histogramLine(c7_hist, 42)))
        check(n_sweat_ok_c7 >= N * STRICT_MIN,
              "%s: c7 sweat cap conformance %.1f%%",
              case.name, pct(n_sweat_ok_c7, N))
    end
    print("")
end

-- ═══ Cash half ══════════════════════════════════════════════════════════

local TIERS  = { "small", "medium", "large", "jackpot" }
local GTYPES = { nil, "zoom", "six_max" }

-- The union of a tier's bands, for conformance scoring.
local function inAnyBand(bands, eq)
    for _, b in ipairs(bands) do
        if eq >= b.lo and eq < b.hi then return true end
    end
    return false
end

local function bandsFor(pol, won, tier)
    local side = pol.bands and pol.bands[won and "win" or "loss"]
    return side and side[tier]
end

-- No card may appear twice across the two holes and the board.
local function hasDuplicates(p_hole, o_hole, board)
    local seen = {}
    for _, list in ipairs({ p_hole, o_hole, board }) do
        for _, c in ipairs(list) do
            local k = c.suit .. c.rank
            if seen[k] then return true end
            seen[k] = true
        end
    end
    return false
end

print("═══ cash / MTT table construction ═══")
print("")

local total_construct_ms, total_construct_n = 0, 0

for _, gtype in ipairs({ "\0none", "zoom", "six_max" }) do
    local gtype_id = (gtype ~= "\0none") and gtype or nil
    local pol = HandRealism.policyFor(ShowdownRealism, gtype_id)
    for _, tier in ipairs(TIERS) do
        for _, won in ipairs({ true, false }) do
            local bands = bandsFor(pol, won, tier)
            local floors = pol.cat_floors and pol.cat_floors[tier]
            local n_natural, n_winner_ok, n_dupes = 0, 0, 0
            local n_in_band, n_floor_ok, n_same_label = 0, 0, 0
            local eq_hist = {}
            local cat_hist = {}
            local t0 = os.clock()

            for _ = 1, N do
                local p_hole, o_hole, board, natural =
                    HandRealism.constructShowdownHand(won, tier,
                        { policy = ShowdownRealism, gtype_id = gtype_id })

                if natural then n_natural = n_natural + 1 end
                if hasDuplicates(p_hole, o_hole, board) then
                    n_dupes = n_dupes + 1
                end

                -- Winner must match the outcome the money already paid.
                local pc, oc = {}, {}
                for _, c in ipairs(p_hole) do pc[#pc + 1] = c end
                for _, c in ipairs(board)  do pc[#pc + 1] = c end
                for _, c in ipairs(o_hole) do oc[#oc + 1] = c end
                for _, c in ipairs(board)  do oc[#oc + 1] = c end
                local p_rank = HandEval.bestFiveOfN(pc)
                local o_rank = HandEval.bestFiveOfN(oc)
                if (HandEval.compare(p_rank, o_rank) > 0) == won then
                    n_winner_ok = n_winner_ok + 1
                end

                -- Realized preflop equity of the shown matchup.
                local pi = HandClass.classIndex(p_hole[1], p_hole[2])
                local oi = HandClass.classIndex(o_hole[1], o_hole[2])
                local eq = PreflopEquity.equity(pi, oi)
                local bin = math.floor(eq * 20)     -- 5% bins
                eq_hist[bin] = (eq_hist[bin] or 0) + 1
                if bands and inAnyBand(bands, eq) then
                    n_in_band = n_in_band + 1
                end

                local w_rank = won and p_rank or o_rank
                local l_rank = won and o_rank or p_rank
                local w_cat = w_rank[1]
                cat_hist[w_cat] = (cat_hist[w_cat] or 0) + 1
                if w_cat >= ((floors and floors.winner) or 1)
                   and l_rank[1] >= ((floors and floors.loser) or 1) then
                    n_floor_ok = n_floor_ok + 1
                end
                -- The two labels the felt prints must not be identical.
                if bands and HandEval.describe(w_rank)
                          == HandEval.describe(l_rank) then
                    n_same_label = n_same_label + 1
                end
            end

            local dt = os.clock() - t0
            total_construct_ms = total_construct_ms + dt * 1000
            total_construct_n  = total_construct_n + N

            local label = string.format("%-8s %-7s %s",
                gtype_id or "(default)", tier, won and "WIN " or "LOSS")
            print(string.format("── %s   %.2fms/hand", label, 1000 * dt / N))
            print(string.format("     natural %.1f%%   winner-ok %.1f%%   band %s   floors %.1f%%   same-label %.1f%%",
                pct(n_natural, N), pct(n_winner_ok, N),
                bands and string.format("%.1f%%", pct(n_in_band, N)) or "n/a",
                pct(n_floor_ok, N), pct(n_same_label, N)))

            local bins = {}
            for b = 0, 19 do
                if eq_hist[b] then
                    bins[#bins + 1] = string.format("%d-%d%%:%d",
                        b * 5, b * 5 + 5, eq_hist[b])
                end
            end
            print("     equity: " .. table.concat(bins, " "))
            local cats = {}
            for c = 1, 9 do
                if cat_hist[c] then
                    cats[#cats + 1] = string.format("%s:%d",
                        HandEval.categoryName(c), cat_hist[c])
                end
            end
            print("     winner hand: " .. table.concat(cats, "  "))

            check(n_dupes == 0, "%s: %d hands contained a duplicate card",
                  label, n_dupes)
            check(n_winner_ok == N,
                  "%s: winner mismatch in %d/%d hands", label, N - n_winner_ok, N)
            check(n_natural >= N * 0.99,
                  "%s: natural rate %.1f%% < 99%%", label, pct(n_natural, N))
            if bands then
                check(n_in_band >= N * 0.97,
                      "%s: band conformance %.1f%% < 97%%",
                      label, pct(n_in_band, N))
                check(n_floor_ok >= N * 0.97,
                      "%s: category floors met only %.1f%%",
                      label, pct(n_floor_ok, N))
                check(n_same_label <= N * 0.03,
                      "%s: %.1f%% of showdowns print the same hand name twice",
                      label, pct(n_same_label, N))
            end
        end
    end
    print("")
end

-- ═══ Sample showdowns, in words ════════════════════════════════════════
-- The numbers above say the policy is being obeyed. These say whether
-- obeying it produces a hand a poker player would believe. Read them.

print("═══ sample showdowns ═══")
for _, tier in ipairs({ "medium", "large", "jackpot" }) do
    for _, won in ipairs({ true, false }) do
        print(string.format("── %s, player %s", tier, won and "WINS" or "LOSES"))
        for _ = 1, 4 do
            local p_hole, o_hole, board = HandRealism.constructShowdownHand(
                won, tier, { policy = ShowdownRealism })
            local pi = HandClass.classIndex(p_hole[1], p_hole[2])
            local oi = HandClass.classIndex(o_hole[1], o_hole[2])
            local p_name = HandEval.handLabel(p_hole, board)
            local o_name = HandEval.handLabel(o_hole, board)
            local b = {}
            for _, c in ipairs(board) do b[#b + 1] = tostring(c) end
            print(string.format(
                "   %s (%s) vs %s (%s) — %.0f%% pre — board %s",
                HandClass.name(pi), tostring(p_hole[1]) .. tostring(p_hole[2]),
                HandClass.name(oi), tostring(o_hole[1]) .. tostring(o_hole[2]),
                100 * PreflopEquity.equity(pi, oi), table.concat(b, " ")))
            print(string.format("       player: %-28s opponent: %s",
                p_name, o_name))
        end
    end
end
print("")

-- Perf. The gate is an ABSOLUTE per-hand budget, not a ratio against the
-- old sampler: constructing a hand happens once per deal, seconds apart
-- per table, so what matters is that it stays far inside a frame even
-- with every table dealing — not that it beats a cheap baseline. The
-- ratio is printed alongside because a sudden jump in it is a good
-- smell test, but a loaded machine moves it and it is not the gate.
--
-- `small` is the one to watch: it is the overwhelming majority of hands.
local BUDGET_MS = 5.0
print(string.format("═══ perf (budget %.1f ms/hand) ═══", BUDGET_MS))
local M = N * 4
for _, tier in ipairs(TIERS) do
    for _, won in ipairs({ true, false }) do
        local t1 = os.clock()
        for _ = 1, M do
            HandRealism.constructShowdownHand(won, tier,
                { policy = ShowdownRealism })
        end
        local new_ms = (os.clock() - t1) * 1000 / M

        local t2 = os.clock()
        for _ = 1, M do HandRealism.legacyConstructHand(won) end
        local legacy_ms = (os.clock() - t2) * 1000 / M

        print(string.format("  %-7s %-5s  new %.3f ms   legacy %.3f ms   ×%.2f",
            tier, won and "WIN" or "LOSS", new_ms, legacy_ms,
            legacy_ms > 0 and (new_ms / legacy_ms) or 0))
        check(new_ms <= BUDGET_MS,
              "%s %s construction %.3f ms exceeds the %.1f ms budget",
              tier, won and "WIN" or "LOSS", new_ms, BUDGET_MS)
    end
end
print("")

-- ═══ Interrupt re-deal ══════════════════════════════════════════════════

-- The re-deal enumerates every remaining two-card combination, so a
-- "wrong" winner can only mean the board made the required result
-- impossible (a straight lying face-up: every opponent plays the same
-- board, so the player can never get strictly ahead). Those cases are
-- reported as `natural = false`. What is asserted here is therefore:
-- every NATURAL re-deal produces the required winner, and an impossible
-- one is confirmed impossible by an independent exhaustive check.
print("═══ interrupt re-deal ═══")
for _, want_win in ipairs({ true, false }) do
    local n_natural, n_dupe = 0, 0
    local n_nat_ok, n_forced, n_forced_confirmed, n_forced_chopped = 0, 0, 0, 0
    local eqvr_sum, eqvr_n = 0, 0
    -- Times ONLY the re-deal. The independent impossibility check below
    -- is the harness doing its own exhaustive sweep, and counting that
    -- would report it as the cost of the thing it is checking.
    local redeal_s = 0
    for _ = 1, N do
        -- A live hand: player hole + full board already on the felt,
        -- built for the OPPOSITE result, exactly as an interrupt finds it.
        local p_hole, _, board = HandRealism.legacyConstructHand(not want_win)
        local t0 = os.clock()
        local o_hole, natural = HandRealism.redealOpponent(
            p_hole, board, want_win, { policy = ShowdownRealism })
        redeal_s = redeal_s + (os.clock() - t0)
        check(o_hole ~= nil, "redeal(%s) returned nil", tostring(want_win))
        if o_hole then
            if hasDuplicates(p_hole, o_hole, board) then n_dupe = n_dupe + 1 end
            local pc, oc = {}, {}
            for _, c in ipairs(p_hole) do pc[#pc + 1] = c end
            for _, c in ipairs(board)  do pc[#pc + 1] = c end
            for _, c in ipairs(o_hole) do oc[#oc + 1] = c end
            for _, c in ipairs(board)  do oc[#oc + 1] = c end
            local cmp = HandEval.compare(HandEval.bestFiveOfN(pc),
                                         HandEval.bestFiveOfN(oc))
            local correct = (cmp > 0) == want_win

            if natural then
                n_natural = n_natural + 1
                if correct then n_nat_ok = n_nat_ok + 1 end
                eqvr_sum = eqvr_sum + PreflopEquity.eqVsRandom(
                    HandClass.classIndex(o_hole[1], o_hole[2]))
                eqvr_n = eqvr_n + 1
            else
                n_forced = n_forced + 1
                if cmp == 0 then n_forced_chopped = n_forced_chopped + 1 end
                -- Independently confirm no valid combination existed.
                local seen = {}
                for _, c in ipairs(p_hole) do seen[c.suit .. c.rank] = true end
                for _, c in ipairs(board)  do seen[c.suit .. c.rank] = true end
                local avail = HandClass.remainingCards(seen)
                local found = false
                for a = 1, #avail - 1 do
                    for b = a + 1, #avail do
                        local t = { avail[a], avail[b] }
                        for _, c in ipairs(board) do t[#t + 1] = c end
                        if (HandEval.compare(HandEval.bestFiveOfN(pc),
                                             HandEval.bestFiveOfN(t)) > 0)
                           == want_win then
                            found = true; break
                        end
                    end
                    if found then break end
                end
                if not found then n_forced_confirmed = n_forced_confirmed + 1 end
            end
        end
    end
    local dt = redeal_s
    print(string.format("  opp must %s: natural %.1f%% (all correct: %s)   impossible %.1f%% (confirmed %d/%d, chopped %d)",
        want_win and "LOSE " or "WIN  ",
        pct(n_natural, N), tostring(n_nat_ok == n_natural),
        pct(n_forced, N), n_forced_confirmed, n_forced, n_forced_chopped))
    print(string.format("       mean opp eq-vs-random %.1f%%   %.2fms/redeal",
        eqvr_n > 0 and (100 * eqvr_sum / eqvr_n) or 0, 1000 * dt / N))
    check(n_dupe == 0, "redeal(%s): %d duplicate cards", tostring(want_win), n_dupe)
    check(n_nat_ok == n_natural,
          "redeal(%s): %d natural re-deals produced the wrong winner",
          tostring(want_win), n_natural - n_nat_ok)
    check(n_forced_confirmed == n_forced,
          "redeal(%s): %d/%d 'impossible' cases actually had a valid combination",
          tostring(want_win), n_forced - n_forced_confirmed, n_forced)
end
print("")

if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("all checks passed")
