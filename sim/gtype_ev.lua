-- sim/gtype_ev.lua
--
-- Game-type identity sim (chunk 1 of docs/gametype-identity-redesign.md).
-- Rolls real outcomes (OutcomeMath.resolvedOutcome — the live pipeline,
-- zoom's jackpot_emerge overwrite included) and real HandScript scripts
-- (the live duration model) per (stake × gtype × scenario × candidate),
-- and prints the identity axes side by side:
--
--   $/hand (seats-capped), s/hand, $/hr, jackpot hits/hr, expected hands
--   to first jackpot, {stack}%, per-hand $ stddev, p95 max drawdown over
--   30-minute walks, and the capped-vs-uncapped EV gap.
--
-- Run headless from the repo root:
--   lua sim/gtype_ev.lua [seed] [candidate] [scenario|all] [stake_id] [n_hands]
--   e.g.  lua sim/gtype_ev.lua 12345 c1 all s001 100000
--
-- Candidates are DUMB TABLES below — merged into COPIES of the gtype
-- defs and resolved through a local band lookup that mirrors the
-- phase-B data shape. Live data files are never mutated. `structure`
-- overrides (fold-out weights etc.) are recorded but INERT until phase D
-- moves those tables out of HandScript into data; the sim prints a
-- notice when a candidate carries one.
--
-- Wall time per hand = last event's `t` / pace + 0.4 / pace: the walker
-- transitions to settling the moment the final event fires (pot_push's
-- beat is never awaited) and the 0.4s settling window is pace-scaled
-- (models/Table.lua). Cash hands add the scenario's cursor_overhead_s
-- (deal click cadence); MTT auto-deals and adds nothing.

io.stdout:setvbuf("no")

-- Love shim BEFORE any require (models call love.math.random inline).
local seed = tonumber(arg and arg[1]) or 12345
math.randomseed(seed)
love = {
    math  = { random = math.random },
    timer = { getTime = os.clock },
}

package.path = package.path .. ";./?.lua"

local OutcomeMath = require("models.outcome_math")
local HandScript  = require("models.HandScript")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local PotTiers    = require("data.pot_tiers")
local Timings     = require("data.poker_event_timings")

local STACK_BB = 100   -- cash stacks are pinned to buy_in = 100bb

-- ── Candidates ──────────────────────────────────────────────────────────
-- bands: the phase-B shape ({ default = { win/loss }, by_gtype }); nil
--   default falls through to today's data/pot_tiers.lua on both sides.
--   Band cells are { lo, hi } in bb.
-- gtype: shallow field overrides merged into a copy of the gtype def
--   (dist_shifts replace wholesale).
-- timings: per-gtype event-beat overrides merged over poker_event_timings.
-- structure: INERT until phase D (printed as a notice).

local CANDIDATES = {
    live = {},

    -- Phase-E starting point from the plan: six_max slow tank with the
    -- seats-rule bands, zoom fast drip with the same ceiling, HU testing
    -- the 70-100 jackpot variant against its 100bb cap.
    c1 = {
        bands = {
            by_gtype = {
                six_max = { win = {
                    small   = { 2, 5 },
                    medium  = { 10, 30 },
                    large   = { 60, 150 },
                    jackpot = { 380, 500 },
                } },
                zoom = { win = {
                    small   = { 1, 4 },
                    medium  = { 8, 24 },
                    large   = { 60, 150 },
                    jackpot = { 380, 500 },
                } },
                hu = { win = { jackpot = { 70, 100 } },
                       loss = { jackpot = { 70, 100 } } },
            },
        },
        gtype = {
            six_max = { pace_mult = 0.35 },
            zoom    = { pace_mult = 2.2, jackpot_scale = 0.10 },
        },
        timings = {
            zoom = { deal_flop = 0.20, deal_turn = 0.15, deal_river = 0.15,
                     showdown_reveal = 0.25, pot_push = 0.25, street_gap = 0.10 },
        },
    },

    -- c2: the shipping cut. Same seats-rule shape as c1, but zoom's
    -- middle bands are cut hard (it is the DRIP, not a second tank) and
    -- six-max pays for its huge win bands with a lower win rate, so the
    -- tank earns through rare coolers rather than through winning more.
    c2 = {
        bands = {
            by_gtype = {
                six_max = { win = {
                    small   = { 2, 6 },
                    medium  = { 12, 35 },
                    large   = { 70, 180 },
                    jackpot = { 380, 500 },
                } },
                zoom = { win = {
                    small   = { 1, 3 },
                    medium  = { 4, 12 },
                    large   = { 25, 60 },
                    jackpot = { 300, 500 },
                } },
                -- HU tops out at ONE stack, so its jackpot band sits just
                -- under the cap instead of being clipped by it.
                hu = { win = {
                    small   = { 3, 8 },
                    medium  = { 15, 40 },
                    large   = { 45, 85 },
                    jackpot = { 70, 100 },
                } },
            },
        },
        gtype = {
            six_max = { pace_mult = 0.35, win_chance_shift = -0.08 },
            zoom    = { pace_mult = 2.2, jackpot_scale = 0.08, win_chance_shift = 0.05 },
        },
        timings = {
            zoom = { deal_flop = 0.18, deal_turn = 0.14, deal_river = 0.14,
                     showdown_reveal = 0.22, pot_push = 0.22, street_gap = 0.08,
                     fold = 0.05, call = 0.10, check = 0.07 },
        },
    },
}

-- fill = run-upgrade fill ratio; cursor_overhead_s = seconds of deal
-- cadence added per cash hand (0 = instant redeal fantasy).
local SCENARIOS = {
    naked      = { fill = 0.0, cursor_overhead_s = 1.5 },
    midrun     = { fill = 0.6, cursor_overhead_s = 1.0 },
    capped     = { fill = 1.0, cursor_overhead_s = 0.5 },
    capped_afk = { fill = 1.0, cursor_overhead_s = 3.0 },
}
local SCENARIO_ORDER = { "naked", "midrun", "capped", "capped_afk" }

-- ── Helpers ─────────────────────────────────────────────────────────────

local function findById(list, id)
    for _, e in ipairs(list) do if e.id == id then return e end end
end

local function shallowCopy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function mergedGtype(cand, gtype)
    local g = shallowCopy(gtype)
    local ov = cand.gtype and cand.gtype[gtype.id]
    if ov then for k, v in pairs(ov) do g[k] = v end end
    return g
end

local function mergedTimings(cand, gtype_id)
    local ov = cand.timings and cand.timings[gtype_id]
    if not ov then return Timings end
    local t = shallowCopy(Timings)
    for k, v in pairs(ov) do t[k] = v end
    return t
end

-- Band resolver — mirrors the phase-B fallthrough exactly:
-- by_gtype[id][side][tier] → default[side][tier] → live pot_tiers.
local function bandFor(cand, gtype_id, won, tier)
    local side = won and "win" or "loss"
    local b = cand.bands
    if b then
        local bg = b.by_gtype and b.by_gtype[gtype_id]
        local cell = bg and bg[side] and bg[side][tier]
        if not cell and b.default and b.default[side] then
            cell = b.default[side][tier]
        end
        if cell then
            local lo = cell.lo or cell[1]
            local hi = cell.hi or cell[2]
            return lo, hi
        end
    end
    -- No candidate override: the live data, through the real resolver.
    local r = OutcomeMath.tierBand(tier, gtype_id, won)
    return r.lo, r.hi
end

-- Fill units that land the stake's window at `fill` ∈ [0,1].
local function ctxForFill(stake, fill)
    local w = stake.fill_window or { start = 0, complete = 1 }
    local u = (w.start or 0) + fill * ((w.complete or 1) - (w.start or 0))
    return {
        win_chance_fills = { { strength = u } },
        win_dist_fills   = { { strength = u } },
        loss_dist_fills  = { { strength = u } },
    }
end

-- Mean script wall-seconds per (gtype, tier, won), memoized over K rolls.
local DUR_ROLLS = 300
local function durationModel(gtype, timings)
    local memo = {}
    local n_seats = (gtype.seats or 0) + 1
    local pace = gtype.pace_mult or 1
    return function(tier, won)
        local key = tier .. (won and "W" or "L")
        local m = memo[key]
        if not m then
            local sum = 0
            for _ = 1, DUR_ROLLS do
                local result = HandScript.write(
                    { won = won, magnitude_bb = math.min(50, STACK_BB),
                      tier = tier, gtype_id = gtype.id, stake_bb = 0.02 },
                    { n_seats = n_seats,
                      player_seat = love.math.random(1, n_seats),
                      button_seat = love.math.random(1, n_seats) },
                    nil, nil, nil, timings)
                local ev = result.events
                local last_t = (#ev > 0) and ev[#ev].t or 0
                sum = sum + (last_t / pace) + (0.4 / pace)
            end
            m = sum / DUR_ROLLS
            memo[key] = m
        end
        return m
    end
end

local function pctl(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
    return sorted[i]
end

-- ── Cash Monte Carlo ────────────────────────────────────────────────────

local function simCash(cand, stake, gtype_live, scen, n_hands)
    local gtype   = mergedGtype(cand, gtype_live)
    local timings = mergedTimings(cand, gtype.id)
    local ctx     = ctxForFill(stake, scen.fill)
    local durOf   = durationModel(gtype, timings)
    local seats   = gtype.seats or 1
    local bb      = stake.bb

    local wc, wd, ld = OutcomeMath.resolvedOutcome(ctx, gtype, stake)
    local stack_pct  = wc * (wd.jackpot or 0) * 100

    local sum, sum2, sum_unc, dur_sum = 0, 0, 0, 0
    local jackpots, first_jp_hand = 0, nil
    local deltas = {}
    for i = 1, n_hands do
        local won, tier = OutcomeMath.sampleOutcome(wc, wd, ld, ctx, gtype)
        local lo, hi = bandFor(cand, gtype.id, won, tier)
        local mag = lo + love.math.random() * (hi - lo)
        local mult = OutcomeMath.payoutMult(ctx, stake, tier, won)
        local delta, delta_unc
        if won then
            delta_unc = mag * bb * mult
            delta     = math.min(mag, seats * STACK_BB) * bb * mult
            if tier == "jackpot" then
                jackpots = jackpots + 1
                if not first_jp_hand then first_jp_hand = i end
            end
        else
            delta_unc = -mag * bb * mult
            delta     = -math.min(mag, STACK_BB) * bb * mult
        end
        sum      = sum + delta
        sum2     = sum2 + delta * delta
        sum_unc  = sum_unc + delta_unc
        dur_sum  = dur_sum + durOf(tier, won)
        deltas[i] = delta
    end

    local ev_hand   = sum / n_hands
    local ev_unc    = sum_unc / n_hands
    local s_hand    = dur_sum / n_hands + scen.cursor_overhead_s
    local hands_hr  = 3600 / s_hand
    local var       = sum2 / n_hands - ev_hand * ev_hand
    local sd        = math.sqrt(math.max(0, var))

    -- p95 max drawdown over 30-minute walks resampled from the deltas.
    local walk_hands = math.max(1, math.floor(1800 / s_hand))
    local drawdowns = {}
    for w = 1, 200 do
        local bal, peak, maxdd = 0, 0, 0
        for _ = 1, walk_hands do
            bal = bal + deltas[love.math.random(1, n_hands)]
            if bal > peak then peak = bal end
            local dd = peak - bal
            if dd > maxdd then maxdd = dd end
        end
        drawdowns[w] = maxdd
    end
    table.sort(drawdowns)

    return {
        ev_hand = ev_hand, s_hand = s_hand, per_hr = ev_hand * hands_hr,
        hands_hr = hands_hr,
        jp_hr = jackpots / n_hands * hands_hr,
        ttf_jp = (jackpots > 0) and (n_hands / jackpots) or math.huge,
        stack_pct = stack_pct, sd = sd,
        p95_dd = pctl(drawdowns, 0.95),
        cap_gap = (ev_unc ~= 0) and ((ev_unc - ev_hand) / math.abs(ev_unc) * 100) or 0,
    }
end

-- ── MTT (analytic EV + rolled durations; approximates the planner) ─────

local function simMtt(cand, stake, gtype_live, scen)
    local gtype   = mergedGtype(cand, gtype_live)
    local timings = mergedTimings(cand, gtype.id)
    local ctx     = ctxForFill(stake, scen.fill)
    local stats   = OutcomeMath.evStats(ctx, gtype, stake)
    if not stats then return nil end
    local durOf = durationModel(gtype, timings)
    -- Filler mix ≈ the planner: mostly small/medium hands, jackpots on
    -- the scheduled bust hands.
    local s_hand = 0.70 * durOf("small", false)
                 + 0.25 * durOf("medium", true)
                 + 0.05 * durOf("jackpot", true)
    local pool = stats.pool
    local hands_hr = 3600 / s_hand   -- auto-deal: zero overhead
    return {
        ev_hand = pool.ev_per_hand, s_hand = s_hand,
        per_hr = pool.ev_per_hand * hands_hr, hands_hr = hands_hr,
        jp_hr = 0, ttf_jp = math.huge,
        stack_pct = pool.win_chance * ((pool.win_dist and pool.win_dist.jackpot) or 0) * 100,
        sd = 0, p95_dd = 0, cap_gap = 0,
        roi = pool.roi_pct, exp_hands = pool.exp_hands,
    }
end

-- ── Driver ──────────────────────────────────────────────────────────────

local cand_name = (arg and arg[2]) or "live"
local scen_arg  = (arg and arg[3]) or "all"
local stake_id  = (arg and arg[4]) or "s001"
local n_hands   = tonumber(arg and arg[5]) or 100000

local cand  = CANDIDATES[cand_name] or CANDIDATES.live
local stake = findById(Stakes, stake_id)
assert(stake, "unknown stake " .. tostring(stake_id))

if cand.structure then
    print("NOTE: candidate carries `structure` overrides — INERT until "
          .. "phase D moves fold-out/showdown tables into data.")
end

local scen_list = (scen_arg == "all") and SCENARIO_ORDER or { scen_arg }

print(string.format(
    "gtype_ev — stake %s (%s) · candidate %s · seed %d · %d hands/cell",
    stake.id, stake.display_name or "", cand_name, seed, n_hands))

local HDR = "%-8s | %9s %7s %10s %8s | %6s %8s %8s | %9s %9s %6s"
local ROW = "%-8s | %9.4f %7.2f %10.2f %8.0f | %6.2f %8.1f %8.2f | %9.2f %9.2f %5.1f%%"

for _, scen_name in ipairs(scen_list) do
    local scen = SCENARIOS[scen_name]
    if not scen then
        print("unknown scenario: " .. tostring(scen_name))
    else
        print(string.format(
            "\n── scenario %s (fill %.1f, cursor overhead %.1fs) %s",
            scen_name, scen.fill, scen.cursor_overhead_s,
            string.rep("─", 20)))
        print(string.format(HDR,
            "gtype", "$/hand", "s/hand", "$/hr", "hands/hr",
            "jp/hr", "ttf(jp)", "{stack}%", "sd($)", "p95dd($)", "capgap"))
        local best = { per_hr = -math.huge, jp = -math.huge, hands = -math.huge }
        local rows = {}
        for _, g in ipairs(GameTypes) do
            local r
            if g.chip_stack_table then
                r = simMtt(cand, stake, g, scen)
            else
                r = simCash(cand, stake, g, scen, n_hands)
            end
            if r then
                rows[#rows + 1] = { id = g.id, r = r }
                if r.per_hr > best.per_hr then best.per_hr, best.money = r.per_hr, g.id end
                if r.jp_hr > best.jp then best.jp, best.chips = r.jp_hr, g.id end
                if r.hands_hr > best.hands then best.hands, best.volume = r.hands_hr, g.id end
                print(string.format(ROW, g.id,
                    r.ev_hand, r.s_hand, r.per_hr, r.hands_hr,
                    r.jp_hr, (r.ttf_jp == math.huge) and -1 or r.ttf_jp,
                    r.stack_pct, r.sd, r.p95_dd, r.cap_gap))
            end
        end
        print(string.format(
            "   best $/hr: %s · best jackpot rate: %s · most hands/hr: %s",
            best.money or "?", best.chips or "?", best.volume or "?"))
    end
end
