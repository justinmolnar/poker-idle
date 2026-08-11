-- models/outcome_math.lua
--
-- Pure outcome math for the 3-distribution model. Lifted out of
-- models/Table.lua so both Table (per-hand outcome roll on cash games)
-- and MttSession (tournament-plan generation) can call the same pipeline.
--
-- ─── 3-distribution model ─────────────────────────────────────────────
-- Each hand resolves through three independent dimensions:
--
--   • win_chance — single probability ∈ [0, 1] that the hand is a Win
--   • win_dist   — { small, medium, large, jackpot } sums to 1; sampled
--                  when winning
--   • loss_dist  — { small, medium, large, jackpot } sums to 1; sampled
--                  when losing
--
-- Each stake declares both naked AND run-capped values for these three.
-- Run upgrades push fill descriptors onto ctx lists; the sum of matching
-- descriptor strengths becomes "fill units" that lerp the dimension from
-- naked toward run-capped via the stake's fill_window. Catalog perks add
-- flat additive bumps on top — the only mechanism for crossing run-capped
-- toward the absolute 0.95 WC ceiling.
--
-- Pipeline (buildOutcome(ctx, gtype, stake)):
--   1. Sum fill units per dimension (only descriptors whose gtype filter
--      matches the table's game_type).
--   2. Convert units → fill ratio via stake.fill_window {start, complete}.
--   3. Lerp naked → run-capped per dimension.
--   4. Gtype additive shape on dists.
--   5. Catalog ctx.win_chance_shifts (additive on top of lerp).
--   6. Clamp WC to [0, 0.95]. Clamp dist cells ≥0 and renormalize.

local Lookups    = require("utils.lookups")
local StakesData = require("data.stakes")
local PotTiers   = require("data.pot_tiers")

local OutcomeMath = {}

-- ─── Shared constants ──────────────────────────────────────────────────

local TIER_KEYS = { "small", "medium", "large", "jackpot" }
OutcomeMath.TIER_KEYS = TIER_KEYS

-- Name → 1-based rank. Shared source of truth for tier ordering so
-- effect applicators (poker_effects tier floors/ceilings) and the
-- sampler agree. TIER_KEYS is the inverse (rank → name).
local TIER_INDEX = { small = 1, medium = 2, large = 3, jackpot = 4 }
OutcomeMath.TIER_INDEX = TIER_INDEX

-- Raise `tier` to at least `floor_idx` (a rank). Used by deck capstones
-- like Standard ("wins never roll Small") and Maniac ("no pot below Large").
function OutcomeMath.clampTierFloor(tier, floor_idx)
    if not floor_idx then return tier end
    local idx = TIER_INDEX[tier] or 1
    if idx < floor_idx then return TIER_KEYS[floor_idx] or tier end
    return tier
end

-- Lower `tier` to at most `ceil_idx` (a rank). Used by the Nit capstone
-- ("stack loss cannot happen" — caps the loss tier below jackpot).
function OutcomeMath.clampTierCeiling(tier, ceil_idx)
    if not ceil_idx then return tier end
    local idx = TIER_INDEX[tier] or 1
    if idx > ceil_idx then return TIER_KEYS[ceil_idx] or tier end
    return tier
end

local WC_ABSOLUTE_CAP = 0.95   -- final WC ceiling regardless of fill/shifts
OutcomeMath.WC_ABSOLUTE_CAP = WC_ABSOLUTE_CAP

-- ─── Sampling helpers ──────────────────────────────────────────────────

-- Weighted-random pick from a {[key]=weight} map. Returns one key.
-- Defensive against unnormalized inputs (weights need not sum to 1) and
-- against zero/negative totals (falls back to first key).
local function sampleDist(dist)
    if not dist then return nil end
    local total = 0
    for _, p in pairs(dist) do total = total + p end
    if total <= 0 then
        for k in pairs(dist) do return k end
    end
    local r = love.math.random() * total
    local acc = 0
    for k, p in pairs(dist) do
        acc = acc + p
        if r <= acc then return k end
    end
    for k in pairs(dist) do return k end
end
OutcomeMath.sampleDist = sampleDist

-- ─── Distribution helpers ──────────────────────────────────────────────

local function distCopy(src)
    local d = {}
    if src then
        for _, t in ipairs(TIER_KEYS) do d[t] = src[t] or 0 end
    else
        for _, t in ipairs(TIER_KEYS) do d[t] = 0 end
    end
    return d
end
OutcomeMath.distCopy = distCopy

local function distAddInPlace(dst, delta)
    if not delta then return end
    for k, v in pairs(delta) do
        dst[k] = (dst[k] or 0) + v
    end
end
OutcomeMath.distAddInPlace = distAddInPlace

local function distClampAndNormalize(d)
    for _, t in ipairs(TIER_KEYS) do
        if (d[t] or 0) < 0 then d[t] = 0 end
    end
    local s = 0
    for _, t in ipairs(TIER_KEYS) do s = s + (d[t] or 0) end
    if s <= 0 then
        d.small, d.medium, d.large, d.jackpot = 1, 0, 0, 0
        return
    end
    for _, t in ipairs(TIER_KEYS) do d[t] = d[t] / s end
end
OutcomeMath.distClampAndNormalize = distClampAndNormalize

-- ─── Pipeline helpers ──────────────────────────────────────────────────

-- Returns true if the descriptor's gtype filter matches the table's
-- game-type. (Skill / style filters were removed when player types were
-- ripped — the only filter dimension that survived is gtype.)
local function shiftApplies(shift, gtype)
    if shift.gtype and shift.gtype ~= gtype.id then return false end
    return true
end
OutcomeMath.shiftApplies = shiftApplies

-- Sum strength across descriptors that match this gtype. Optional
-- `tier_min` / `tier_max` bounds on a descriptor (1-based stake index)
-- scope a fill to certain stakes only — e.g. High Roller fills WC at T4+
-- exclusively. Unbounded descriptors apply everywhere.
local function sumFills(list, gtype, tier_idx, ctx)
    if not list then return 0 end
    local total = 0
    local cascade = ctx and ctx.fill_cascade
    for _, d in ipairs(list) do
        local tier_ok = cascade
                    or ((not d.tier_min or (tier_idx and tier_idx >= d.tier_min))
                    and (not d.tier_max or (tier_idx and tier_idx <= d.tier_max)))
        if tier_ok and shiftApplies(d, gtype) then
            total = total + (d.strength or 1)
        end
    end
    return total
end
OutcomeMath.sumFills = sumFills

-- Convert fill units to a [0, 1] ratio via the stake's fill_window.
-- Below window.start: 0 (warmup). At window.complete: 1. Linear between,
-- divided by the ACTUAL span and clamped to [0, 1]. Optional widening
-- (fill_window_widen) grows the window symmetrically; cascade (fill_cascade,
-- Tier Manipulator capstone) opens the window from 0 and completes at the
-- current fill so every stake reaches full.
local function fillRatio(units, window, ctx)
    if not window then return 1 end
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)

    local L = ctx and ctx.fill_window_widen
    if L and L > 0 then
        start    = math.max(0, start - math.ceil(L / 2))
        complete = complete + math.floor(L / 2)
    end

    if ctx and ctx.fill_cascade then
        start    = 0
        complete = math.max(complete, units)
    end

    local span = complete - start
    if span <= 0 then return units >= complete and 1 or 0 end
    local r = (units - start) / span
    if r < 0 then return 0 elseif r > 1 then return 1 end
    return r
end
OutcomeMath.fillRatio = fillRatio

-- Linear interpolation between two distributions (per-tier).
local function lerpDist(naked, capped, t)
    local d = {}
    for _, k in ipairs(TIER_KEYS) do
        local a = (naked  and naked[k])  or 0
        local b = (capped and capped[k]) or a
        d[k] = a + (b - a) * t
    end
    return d
end
OutcomeMath.lerpDist = lerpDist

-- ─── Outcome pipeline ──────────────────────────────────────────────────

-- Build the effective (win_chance, win_dist, loss_dist) tuple for the
-- table, given the player ctx. Returns three fresh values; caller may
-- mutate the dist tables freely.
function OutcomeMath.buildOutcome(ctx, gtype, stake)
    -- Stake's 1-based tier index (T1..T6) — used both by tier-scoped fill
    -- descriptors here and by the win_dist_shift bounds at step 4c.
    local tier_idx = stake and Lookups.indexById(StakesData, stake.id) or nil

    -- 1. Sum fill units per dimension (filtered by gtype + tier bounds).
    local wc_units = sumFills(ctx and ctx.win_chance_fills, gtype, tier_idx, ctx)
    local wd_units = sumFills(ctx and ctx.win_dist_fills,   gtype, tier_idx, ctx)
    local ld_units = sumFills(ctx and ctx.loss_dist_fills,  gtype, tier_idx, ctx)

    -- 2. Convert to fill ratio via stake's window.
    local window = stake and stake.fill_window
    local wc_fill = fillRatio(wc_units, window, ctx)
    local wd_fill = fillRatio(wd_units, window, ctx)
    local ld_fill = fillRatio(ld_units, window, ctx)

    -- 3. Lerp naked → run-capped on each dimension.
    local naked_wc  = (stake and stake.win_chance)        or 0
    local capped_wc = (stake and stake.win_chance_capped) or naked_wc
    local win_chance = naked_wc + (capped_wc - naked_wc) * wc_fill
    local win_dist   = lerpDist(stake and stake.win_dist,  stake and stake.win_dist_capped,  wd_fill)
    local loss_dist  = lerpDist(stake and stake.loss_dist, stake and stake.loss_dist_capped, ld_fill)

    -- 4. Per-gtype additive shape on both dists (depth/pace texture).
    if gtype and gtype.dist_shifts then
        distAddInPlace(win_dist,  gtype.dist_shifts.win_dist)
        distAddInPlace(loss_dist, gtype.dist_shifts.loss_dist)
    end

    -- 4b. Catalog ctx.loss_dist_shifts — additive shape on the loss
    --     distribution (mirror of gtype dist_shifts on the loss side).
    --     Used by the no-poster handicap to skew Run-0 losses toward
    --     Medium+. Renormalized at step 7.
    if ctx and ctx.loss_dist_shifts then
        for _, sh in ipairs(ctx.loss_dist_shifts) do
            if shiftApplies(sh, gtype) then
                distAddInPlace(loss_dist, sh.shift)
            end
        end
    end

    -- 4c. Catalog/deck ctx.win_dist_shifts — same mechanism, win side.
    --     Optional tier_min / tier_max bounds let tier-scoped decks
    --     (e.g. Low Stakes Hero) reshape the win-dist only at certain
    --     stakes. Stake tier index is the 1-based position in the
    --     Stakes data list — looked up via Lookups.indexById.
    if ctx and ctx.win_dist_shifts then
        for _, sh in ipairs(ctx.win_dist_shifts) do
            local tier_ok = (not sh.tier_min or (tier_idx and tier_idx >= sh.tier_min))
                            and (not sh.tier_max or (tier_idx and tier_idx <= sh.tier_max))
            if shiftApplies(sh, gtype) and tier_ok then
                distAddInPlace(win_dist, sh.shift)
            end
        end
    end

    -- 5. Catalog ctx.win_chance_shifts — flat additive ON TOP of the lerp.
    --    The only mechanism for crossing run-capped toward the absolute cap.
    if ctx and ctx.win_chance_shifts then
        for _, shift in ipairs(ctx.win_chance_shifts) do
            if shiftApplies(shift, gtype) then
                win_chance = win_chance + (shift.amount or 0)
            end
        end
    end

    -- 6. Per-gtype WC shift — gives modes a real win-rate identity (Zoom
    --    higher, HU lower) instead of only shaping dists. Treated as
    --    additive on top of catalog shifts so HU Specialist still works.
    if gtype and gtype.win_chance_shift then
        win_chance = win_chance + gtype.win_chance_shift
    end

    -- 6b. Multiplicative final-WC modifier (no-poster handicap, future
    --     skill discounts). Applied AFTER all additive shifts so the
    --     handicap multiplies the *effective* WC, not the lerped baseline.
    if ctx and ctx.wc_mult then
        win_chance = win_chance * ctx.wc_mult
    end

    -- 7. Per-gtype delayed jackpot emergence (Zoom). A flat negative jackpot
    --    shift otherwise keeps the cell pinned at 0 until the lerp overtakes it
    --    near full fill — so the entire Stack-rate gain lands in the last
    --    Pot Control level. Instead, ramp the jackpot cell from `jackpot_emerge`
    --    fill up to its target (the stake's capped jackpot plus that shift), so
    --    the Stack rate climbs gradually over the upgrade's top levels and ends
    --    at the same value. Overwrites the jackpot cell computed above; catalog
    --    jackpot shifts on this gtype don't compound — this IS the rule here.
    if gtype and gtype.jackpot_emerge then
        local sh     = gtype.dist_shifts and gtype.dist_shifts.win_dist
        local offset = (sh and sh.jackpot) or 0
        local capped = (stake and stake.win_dist_capped and stake.win_dist_capped.jackpot) or 0
        local target = capped + offset
        if target < 0 then target = 0 end
        local thr  = gtype.jackpot_emerge
        local ramp = (wd_fill - thr) / math.max(1e-6, 1 - thr)
        if ramp < 0 then ramp = 0 elseif ramp > 1 then ramp = 1 end
        win_dist.jackpot = target * ramp
    end

    -- 8. Final clamps. Absolute WC ceiling (no 100% wins).
    if     win_chance < 0               then win_chance = 0
    elseif win_chance > WC_ABSOLUTE_CAP then win_chance = WC_ABSOLUTE_CAP end
    distClampAndNormalize(win_dist)
    distClampAndNormalize(loss_dist)

    return win_chance, win_dist, loss_dist
end

-- Sample (won, tier) from the 3-distribution outcome.
--
-- Auto-win check fires BEFORE the WC roll: for each ctx.auto_win_chances
-- entry whose gtype filter passes, sum the `amount` and roll once against
-- the total. A successful roll forces won=true regardless of the natural
-- win_chance — used by MTT Pro to flat-bump cash rate without touching
-- the fill / distribution pipeline.
function OutcomeMath.sampleOutcome(win_chance, win_dist, loss_dist, ctx, gtype)
    local won = false
    if ctx and ctx.auto_win_chances then
        local total = 0
        for _, e in ipairs(ctx.auto_win_chances) do
            if shiftApplies(e, gtype) then
                total = total + (e.amount or 0)
            end
        end
        if total > 0 and love.math.random() < total then
            won = true
        end
    end
    if not won then
        won = love.math.random() < win_chance
    end
    local tier = sampleDist(won and win_dist or loss_dist) or "small"

    -- Deck-capstone tier rules clamp the sampled tier. Win side: floor
    -- (Standard "no Small wins"). Loss side: ceiling (the Nit bans jackpot
    -- "stack" losses by capping below jackpot).
    if ctx then
        if won then
            tier = OutcomeMath.clampTierFloor(tier, ctx.win_tier_floor)
        else
            tier = OutcomeMath.clampTierCeiling(tier, ctx.loss_tier_ceiling)
        end
    end
    return won, tier
end

-- Walk the shift list, bumping the current tier whenever (a) the gtype
-- filter matches, (b) the descriptor's `from` equals the current tier, and
-- (c) the chance roll succeeds. Bumps chain by design: Self-Help Book
-- (Small→Medium @25%) + Lava Lamp (Medium→Large @15%) can take a hand from
-- Small → Medium → Large in one resolve. Walk order = registration order
-- in poker_effects.lua; deterministic per build.
function OutcomeMath.applyTierShift(tier, shifts, gtype)
    if not shifts then return tier end
    for _, sh in ipairs(shifts) do
        if shiftApplies(sh, gtype) and tier == sh.from
           and love.math.random() < (sh.chance or 0) then
            tier = sh.to
        end
    end
    return tier
end

-- ─── Distribution mirrors of the sampling rules ────────────────────────
--
-- Everything below expresses, as a transform on a whole distribution,
-- what the samplers above do to ONE roll. They exist so an estimate can
-- account for tier shifts, floors, ceilings and bumps instead of quietly
-- ignoring them: an item that turns a quarter of Small wins into Medium
-- changes your earnings, and a readout that models only earnings_mult
-- will never show it.
--
-- Each one is paired with the sampler it mirrors. If you change a
-- sampling rule, change its mirror in the same edit or the numbers the
-- player is shown stop matching the numbers they get.

-- Mirrors the auto_win_chances block in sampleOutcome: a hand wins if
-- the auto roll OR the win-chance roll succeeds.
function OutcomeMath.effectiveWinChance(win_chance, ctx, gtype)
    local auto = 0
    if ctx and ctx.auto_win_chances then
        for _, e in ipairs(ctx.auto_win_chances) do
            if shiftApplies(e, gtype) then auto = auto + (e.amount or 0) end
        end
    end
    if auto <= 0 then return win_chance end
    if auto > 1 then auto = 1 end
    return auto + (1 - auto) * win_chance
end

-- Mirrors clampTierFloor: every cell below the floor collapses onto it.
function OutcomeMath.distClampFloor(d, floor_idx)
    if not floor_idx then return d end
    for i = 1, math.min(#TIER_KEYS, floor_idx) - 1 do
        local k = TIER_KEYS[i]
        d[TIER_KEYS[floor_idx]] = (d[TIER_KEYS[floor_idx]] or 0) + (d[k] or 0)
        d[k] = 0
    end
    return d
end

-- Mirrors clampTierCeiling: every cell above the ceiling collapses onto it.
function OutcomeMath.distClampCeiling(d, ceil_idx)
    if not ceil_idx then return d end
    for i = math.max(1, ceil_idx) + 1, #TIER_KEYS do
        local k = TIER_KEYS[i]
        d[TIER_KEYS[ceil_idx]] = (d[TIER_KEYS[ceil_idx]] or 0) + (d[k] or 0)
        d[k] = 0
    end
    return d
end

-- Mirrors applyTierShift. Walked in the SAME order, so the chaining is
-- reproduced exactly: mass moved into Medium by one descriptor is
-- available to a later Medium→Large descriptor, just as it is for a
-- single sampled hand.
function OutcomeMath.distTierShift(d, shifts, gtype)
    if not shifts then return d end
    for _, sh in ipairs(shifts) do
        if shiftApplies(sh, gtype) and sh.from and sh.to then
            local moved = (d[sh.from] or 0) * (sh.chance or 0)
            d[sh.from] = (d[sh.from] or 0) - moved
            d[sh.to]   = (d[sh.to]   or 0) + moved
        end
    end
    return d
end

-- Mirrors the tier_bump_chance block in Table:deal — one non-chaining
-- step up the ladder, jackpot staying put.
function OutcomeMath.distTierBump(d, chance)
    if not chance or chance <= 0 then return d end
    local out = distCopy(nil)
    for i, k in ipairs(TIER_KEYS) do
        local m  = d[k] or 0
        local up = TIER_KEYS[math.min(#TIER_KEYS, i + 1)]
        out[up] = out[up] + m * chance
        out[k]  = out[k]  + m * (1 - chance)
    end
    for _, k in ipairs(TIER_KEYS) do d[k] = out[k] end
    return d
end

-- The distributions a hand ACTUALLY resolves against: buildOutcome, then
-- every post-sample rule applied in the order Table:deal applies them
-- (clamp, then shift, then bump).
function OutcomeMath.resolvedOutcome(ctx, gtype, stake)
    local wc, wd, ld = OutcomeMath.buildOutcome(ctx, gtype, stake)
    ctx = ctx or {}
    wc = OutcomeMath.effectiveWinChance(wc, ctx, gtype)

    OutcomeMath.distClampFloor(wd, ctx.win_tier_floor)
    OutcomeMath.distClampCeiling(ld, ctx.loss_tier_ceiling)
    OutcomeMath.distTierShift(wd, ctx.win_tier_shifts,  gtype)
    OutcomeMath.distTierShift(ld, ctx.loss_tier_shifts, gtype)
    OutcomeMath.distTierBump(wd, ctx.tier_bump_chance)
    OutcomeMath.distTierBump(ld, ctx.tier_bump_chance)

    return wc, wd, ld
end

-- ─── Payout multiplier ─────────────────────────────────────────────────
-- Everything that scales a hand's magnitude once its tier is known, as a
-- single number. THE definition — models/Table.lua applies these factors
-- inline at deal time and GrindController applies the last two at
-- resolve; this is what any readout must agree with.
--
-- opts.focus_mult / opts.bankroll are the live resolve-time factors. Omit
-- them for the "per hand at this table, before attention and bankroll"
-- reading.
function OutcomeMath.payoutMult(ctx, stake, tier, won, opts)
    ctx, opts = ctx or {}, opts or {}
    -- payout_double_chance is a coin flip for 2×, so its contribution to
    -- an expectation is 1 + p.
    local mult = 1 + (ctx.payout_double_chance or 0)

    if won then
        mult = mult * (ctx.earnings_mult or 1)
        if ctx.earnings_per_tier then
            local idx = stake and Lookups.indexById(StakesData, stake.id) or 0
            mult = mult * (1 + ctx.earnings_per_tier * idx)
        end
        if tier == "jackpot" then mult = mult * (ctx.jackpot_mult or 1) end
    else
        mult = mult * (ctx.loss_mult or 1)
    end

    if opts.focus_mult then mult = mult * opts.focus_mult end
    if ctx.earnings_scale_by_bankroll and opts.bankroll then
        mult = mult * (1.0 + math.log10((opts.bankroll or 0) + 1) * 0.1)
    end
    return mult
end

-- Roll a magnitude (in bb) within the cell's tier range.
function OutcomeMath.rollTierMagnitude(tier)
    local r = PotTiers[tier]
    if not r then return 0 end
    return r.lo + love.math.random() * (r.hi - r.lo)
end

-- Average bb magnitude inside a tier (uniform over [lo, hi]). Used by
-- the EV estimator in Table:estimateStats / debugStats.
function OutcomeMath.tierAvgBB(tier)
    local r = PotTiers[tier]
    if not r then return 0 end
    return (r.lo + r.hi) * 0.5
end

-- Full per-hand EV stats for a (ctx, gtype, stake) — pure, no Table needed.
-- THE one place the EV math lives: Table:debugStats / :estimateStats and the
-- stake-add buttons all call this so nothing reimplements it. Shape matches
-- what TablePanelStats.buildCashLines / buildMttLines consume.
-- `opts` is passed through to payoutMult (focus_mult, bankroll) so a
-- caller can ask for the raw per-table number or the one the bankroll
-- actually sees.
--
-- The distributions returned are the RESOLVED ones — post floor/ceiling,
-- post tier shift, post bump — because those are the odds a hand really
-- runs against. A readout built on the raw buildOutcome dists reports a
-- Stack rate the player never experiences.
function OutcomeMath.evStats(ctx, gtype, stake, opts)
    if not stake or not gtype then return nil end
    ctx = ctx or {}
    local wc, wd, ld = OutcomeMath.resolvedOutcome(ctx, gtype, stake)
    if not wc then return nil end

    local bb = stake.bb or 1

    -- Per-tier expected magnitude in $, multiplier included. The
    -- multiplier is inside the sum because it varies BY tier: jackpot_mult
    -- lands on one cell only.
    local win_avg, loss_avg = 0, 0     -- bb, multiplier-free (display)
    local win_cash, loss_cash = 0, 0   -- $, fully multiplied
    local per_tier = {}
    for _, t in ipairs(TIER_KEYS) do
        local avg = OutcomeMath.tierAvgBB(t)
        local wm  = OutcomeMath.payoutMult(ctx, stake, t, true,  opts)
        local lm  = OutcomeMath.payoutMult(ctx, stake, t, false, opts)
        win_avg   = win_avg   + (wd[t] or 0) * avg
        loss_avg  = loss_avg  + (ld[t] or 0) * avg
        win_cash  = win_cash  + (wd[t] or 0) * avg * bb * wm
        loss_cash = loss_cash + (ld[t] or 0) * avg * bb * lm
        per_tier[t] = {
            win_p = wd[t] or 0, loss_p = ld[t] or 0,
            win_mult = wm,      loss_mult = lm,
            win_cash = avg * bb * wm, loss_cash = avg * bb * lm,
        }
    end
    local ev = wc * win_cash - (1 - wc) * loss_cash

    return {
        stake = stake,
        gtype = gtype,
        per_tier = per_tier,
        pool  = {
            win_chance  = wc,
            win_dist    = wd,
            loss_dist   = ld,
            ev_per_hand = ev,
            win_avg_bb  = win_avg,
            loss_avg_bb = loss_avg,
        },
    }
end

return OutcomeMath
