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
-- descriptor strengths becomes "fill units" (one per level) that lerp the
-- dimension from naked toward run-capped via the stake's fill_window. The
-- window is a MAX: a stake with 5 levels of gain is done at 5. Two ctx
-- values move that max without moving the levels:
--   run_upgrade_bonus_levels  extra levels, each worth one more level's
--                             gain (5 levels adding 25% become 6 adding 30%)
--   run_upgrade_strength_mult scales the per-level gain (those 5 levels
--                             add 28.75%)
-- Catalog perks add flat additive bumps on top — the other way past
-- run-capped toward the absolute 0.95 WC ceiling.
--
-- Pipeline (buildOutcome(ctx, gtype, stake)):
--   1. Sum fill units per dimension (only descriptors whose gtype filter
--      matches the table's game_type).
--   2. Convert units → fill ratio via stake.fill_window {start, complete}.
--   3. Lerp naked → run-capped per dimension.
--   4. Gtype additive shape on dists.
--   5. Catalog ctx.win_chance_shifts (additive on top of lerp).
--   6. Clamp WC to [0, 0.95]. Clamp dist cells ≥0 and renormalize.

local Lookups       = require("utils.lookups")
local ShoveRate = require("models.shove_rate")
local StakesData    = require("data.stakes")
local PotTiers      = require("data.pot_tiers")
local MttFinishDist = require("data.mtt_finish_dist")
local MttPayouts    = require("data.mtt_payouts")
local MttHandCount  = require("data.mtt_hand_count")

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

-- Deterministic iteration order for a dist's keys. Tier dists walk the
-- canonical TIER_KEYS order; anything else (MTT finish positions keyed
-- 1..N) sorts its keys. `pairs` order is hash order, which made sampling
-- unreplayable even under a fixed seed — the sim and any future replay
-- need the same roll to land on the same key every run.
local function orderedKeys(dist)
    for _, k in ipairs(TIER_KEYS) do
        if dist[k] ~= nil then return TIER_KEYS end
    end
    local ks = {}
    for k in pairs(dist) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    return ks
end

-- Weighted-random pick from a {[key]=weight} map. Returns one key.
-- Defensive against unnormalized inputs (weights need not sum to 1) and
-- against zero/negative totals (falls back to first key in order).
local function sampleDist(dist)
    if not dist then return nil end
    local keys = orderedKeys(dist)
    local total = 0
    for _, k in ipairs(keys) do total = total + (dist[k] or 0) end
    if total <= 0 then
        for _, k in ipairs(keys) do
            if dist[k] ~= nil then return k end
        end
        return nil
    end
    local r = love.math.random() * total
    local acc = 0
    for _, k in ipairs(keys) do
        acc = acc + (dist[k] or 0)
        if r <= acc then return k end
    end
    for i = #keys, 1, -1 do
        if dist[keys[i]] ~= nil then return keys[i] end
    end
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
-- Below window.start: 0 (warmup). At window.complete: 1. Bonus levels
-- (ctx.run_upgrade_bonus_levels) extend the top of the window at the same
-- per-level rate, so the ratio can reach 1 + bonus/span. Linear between,
-- divided by the ACTUAL span and clamped to [0, 1]. Optional widening
-- (fill_window_widen) grows the window symmetrically; cascade (fill_cascade,
-- Tier Manipulator capstone) opens the window from 0 and completes at the
-- current fill so every stake reaches full.
-- The window a stake actually fills against, after the ctx modifiers:
-- widening (fill_window_widen: start down, complete up, symmetric) and
-- cascade (fill_cascade: start at 0, so every level counts at every
-- stake). ONE definition, read by the model (fillRatio), the sidebar
-- tooltip's MAX cell and the shop's level cap, so all three agree on
-- where a stake's max is. They used to disagree: the tooltip and the
-- shop read the raw window, so with Tier Manipulator the grid said MAX
-- two levels early and the last widened levels could not be bought.
--   returns start, complete
local function effectiveWindow(window, ctx)
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)
    -- Each point of widen alternates: one off the start (the stake begins
    -- improving a level earlier), one onto the top (one more level to
    -- buy). A point that cannot go down (start is already 0) goes up
    -- instead, so a point is never lost: T1 (0..5) with 4 points is 0..9,
    -- T3 (6..11) is 4..13.
    local L = ctx and ctx.fill_window_widen
    if L and L > 0 then
        for i = 1, L do
            if i % 2 == 1 and start > 0 then
                start = start - 1
            else
                complete = complete + 1
            end
        end
    end
    if ctx and ctx.fill_cascade then start = 0 end
    return start, complete
end
OutcomeMath.effectiveWindow = effectiveWindow

local function fillRatio(units, window, ctx)
    if not window then return 1 end
    -- Cascade used to also pin complete at the current units, which
    -- clamped the ratio at exactly 1 and made a bonus level do nothing
    -- while the capstone was active. The r_max clamp below is the cap.
    local start, complete = effectiveWindow(window, ctx)

    local span = complete - start
    if span <= 0 then return units >= complete and 1 or 0 end
    -- "15% stronger" applies to every level, the warm-up ones included:
    -- each level counts as `mult` units against a window whose top is
    -- scaled the same way, so a stronger build enters a stake's window
    -- sooner and STILL tops out at exactly its level count (r = 1 at
    -- complete). buildOutcome then scales the gain by mult. Eating the
    -- warm-up without scaling the top is what made MAX land at level 9.
    local mult  = (ctx and ctx.run_upgrade_strength_mult) or 1
    local units_m = units * mult
    local span_m  = complete * mult - start
    if span_m <= 0 then span_m = span end
    local r_max = (span_m + ((ctx and ctx.run_upgrade_bonus_levels) or 0) * mult) / span_m
    local r = (units_m - start) / span_m
    if r < 0 then return 0 elseif r > r_max then return r_max end
    return r
end
OutcomeMath.fillRatio = fillRatio

-- How far a tournament's finish odds sit between MttFinishDist.naked and
-- .capped: the player's effective per-hand win chance over THIS STAKE's
-- bar (data/mtt_finish_dist wc_ref, one per stake), raised to the
-- curve exponent. Deliberately NOT clamped at 1: the bar rises with the
-- tier, and a player who out-powers it keeps gaining (the caller floors
-- any weight the extrapolation drives below zero). The stake's difficulty
-- rides in twice — through eff_wc and through the bar.
function OutcomeMath.mttFinishFill(eff_wc, stake)
    local refs = MttFinishDist.wc_ref
    local ref
    if type(refs) == "table" then
        local idx = stake and Lookups.indexById(StakesData, stake.id)
        ref = (idx and refs[idx]) or MttFinishDist.wc_ref_default or refs[#refs] or 1
    else
        ref = refs or 0.75
    end
    local f = (eff_wc or 0) / ref
    if f < 0 then f = 0 end
    return f ^ (MttFinishDist.curve or 1)
end

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

    -- 3. Lerp naked → run-capped on each dimension. The strength
    --    multiplier scales the gain per level, not the level count, so
    --    the ratio the level count reaches is unchanged and the value it
    --    lands on is bigger. Past 1 (bonus levels, the multiplier) the lerp
    --    extrapolates; step 7 clamps and renormalises.
    local gain_mult = (ctx and ctx.run_upgrade_strength_mult) or 1
    local naked_wc  = (stake and stake.win_chance)        or 0
    local capped_wc = (stake and stake.win_chance_capped) or naked_wc
    local win_chance = naked_wc + (capped_wc - naked_wc) * wc_fill * gain_mult
    local win_dist   = lerpDist(stake and stake.win_dist,  stake and stake.win_dist_capped,  wd_fill * gain_mult)
    local loss_dist  = lerpDist(stake and stake.loss_dist, stake and stake.loss_dist_capped, ld_fill * gain_mult)

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
    --    An entry may carry `stake` and/or `cash_only` next to the gtype
    --    filter: the derived High Roller Pass bonus is per-stake and lands
    --    on cash games only (GrindController appends one entry per stake
    --    with open, finished tournaments at rollup).
    if ctx and ctx.win_chance_shifts then
        for _, shift in ipairs(ctx.win_chance_shifts) do
            local stake_ok = not shift.stake or (stake and stake.id == shift.stake)
            local cash_ok  = not shift.cash_only
                             or not (gtype and gtype.chip_stack_table)
            if stake_ok and cash_ok and shiftApplies(shift, gtype) then
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
        -- The target is a FRACTION of the stake's capped jackpot share
        -- (gtype.jackpot_scale), scaled by the strength multiplier like
        -- every other gain. A flat `capped + shift` fell to zero at T5.
        local capped = (stake and stake.win_dist_capped and stake.win_dist_capped.jackpot) or 0
        local target = capped * (gtype.jackpot_scale or 1) * gain_mult
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
function OutcomeMath.sampleOutcome(win_chance, win_dist, loss_dist, ctx, gtype, forced_won)
    local won = false
    -- An interrupted hand forces the NEXT one's side (Table.deal passes the
    -- flag through). The side is decided, so nothing rolls for it — and the
    -- tier below then samples from the side that actually happened. Forcing
    -- after the fact would hand a forced win a loss-dist tier.
    if forced_won ~= nil then
        won = forced_won
    else
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
        -- The Bank capstone: literally the BANK multiplier.
        mult = mult * ShoveRate.bankrollMultiplier(opts.bankroll)
    end
    return mult
end

-- Resolve a tier's {lo, hi} band for a game type and side. Fallthrough:
-- by_gtype[id][side][tier] → default[side][tier]. `gtype_or_id` may be a
-- gtype table, a string id, or nil (default). `won == false` reads the
-- loss side; anything else the win side.
local function tierBand(tier, gtype_or_id, won)
    local side = (won == false) and "loss" or "win"
    local id = (type(gtype_or_id) == "table") and gtype_or_id.id or gtype_or_id
    local bg = id and PotTiers.by_gtype and PotTiers.by_gtype[id]
    local cell = bg and bg[side] and bg[side][tier]
    if not cell then
        cell = PotTiers.default and PotTiers.default[side]
              and PotTiers.default[side][tier]
    end
    return cell
end
OutcomeMath.tierBand = tierBand

-- THE seats rule, one definition: the most a hand can pay is one stack
-- from each opponent matching your all-in. Unit-agnostic (bb or $ —
-- whatever unit `stack` is in). Shared by the money cap (Table:deal) and
-- the theater magnitude clamp so payout and cinematic can never drift.
function OutcomeMath.maxWinBB(gtype, stack)
    return ((gtype and gtype.seats) or 1) * (stack or 0)
end

-- Roll a magnitude (in bb) within the gtype's band for this tier/side.
function OutcomeMath.rollTierMagnitude(tier, gtype, won)
    local r = tierBand(tier, gtype, won)
    if not r then return 0 end
    return r.lo + love.math.random() * (r.hi - r.lo)
end

-- Average bb magnitude inside a tier (uniform over [lo, hi]), per gtype
-- and side. Optional `cap_bb`: the closed-form mean of min(U(lo,hi), cap)
-- — what the EV estimator needs once the seats-rule cap can actually
-- bite inside a band.
function OutcomeMath.tierAvgBB(tier, gtype, won, cap_bb)
    local r = tierBand(tier, gtype, won)
    if not r then return 0 end
    local lo, hi = r.lo, r.hi
    if not cap_bb or cap_bb >= hi then return (lo + hi) * 0.5 end
    if cap_bb <= lo then return cap_bb end
    -- P(roll ≤ cap) = (cap-lo)/(hi-lo), mean of that slice = (lo+cap)/2;
    -- the rest sits at exactly cap.
    local span = hi - lo
    return ((lo + cap_bb) * 0.5) * (cap_bb - lo) / span
         + cap_bb * (hi - cap_bb) / span
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
    -- Cash tables enforce the seats-rule caps at deal time (win ≤ seats ×
    -- stack, loss ≤ stack; stack = buy_in = 100bb) — the estimate has to
    -- model them or it over-reports whenever a band's top can clip.
    -- Chip-stack tables (mtt) settle through the payout table, not these
    -- magnitudes; their per_tier stays uncapped like today.
    local stack_bb = (bb > 0) and ((stake.buy_in or 0) / bb) or 0
    local win_cap, loss_cap
    if not gtype.chip_stack_table and stack_bb > 0 then
        win_cap  = OutcomeMath.maxWinBB(gtype, stack_bb)
        loss_cap = stack_bb
    end
    for _, t in ipairs(TIER_KEYS) do
        local wavg = OutcomeMath.tierAvgBB(t, gtype, true,  win_cap)
        local lavg = OutcomeMath.tierAvgBB(t, gtype, false, loss_cap)
        local wm  = OutcomeMath.payoutMult(ctx, stake, t, true,  opts)
        local lm  = OutcomeMath.payoutMult(ctx, stake, t, false, opts)
        win_avg   = win_avg   + (wd[t] or 0) * wavg
        loss_avg  = loss_avg  + (ld[t] or 0) * lavg
        win_cash  = win_cash  + (wd[t] or 0) * wavg * bb * wm
        loss_cash = loss_cash + (ld[t] or 0) * lavg * bb * lm
        per_tier[t] = {
            win_p = wd[t] or 0, loss_p = ld[t] or 0,
            win_mult = wm,      loss_mult = lm,
            win_cash = wavg * bb * wm, loss_cash = lavg * bb * lm,
        }
    end

    if gtype.chip_stack_table then
        local buy_in = stake.buy_in or 0
        local n_seats = (gtype.seats or 0) + 1  -- 7 opps + player = 8

        -- Finish odds follow the effective win chance (mirror of
        -- MttSession:planRun), so this readout and the plan agree.
        local mtt_wc = OutcomeMath.buildOutcome(ctx, gtype, stake)
        local auto_win_total = 0
        if ctx.auto_win_chances then
            for _, e in ipairs(ctx.auto_win_chances) do
                if OutcomeMath.shiftApplies(e, gtype) then
                    auto_win_total = auto_win_total + (e.amount or 0)
                end
            end
        end
        -- Unclamped on purpose (see mttFinishFill); weights floor at 0.
        local eff_fill = OutcomeMath.mttFinishFill(mtt_wc, stake) + auto_win_total

        local raw_weights = {}
        local total_weight = 0
        for pos = 1, n_seats do
            local naked  = MttFinishDist.naked[pos]  or 0
            local capped = MttFinishDist.capped[pos] or naked
            local w = naked + (capped - naked) * eff_fill
            if w < 0 then w = 0 end
            raw_weights[pos] = w
            total_weight = total_weight + w
        end

        local boost = ctx.mtt_payout_boost or 0
        local payouts = MttPayouts[boost] or MttPayouts[0]

        local exp_payout = 0
        local exp_hands  = 0
        local pos_probs  = {}
        for pos = 1, n_seats do
            local prob = (total_weight > 0) and (raw_weights[pos] / total_weight) or 0
            pos_probs[pos] = prob
            local key = n_seats - pos + 1
            local mult = payouts[key] or 0
            exp_payout = exp_payout + prob * mult * buy_in
            local hc = MttHandCount[pos]
            local avg_h = hc and ((hc.lo + hc.hi) * 0.5) or 8
            exp_hands = exp_hands + prob * avg_h
        end

        local net_ev_run = exp_payout - buy_in
        local ev_per_hand = (exp_hands > 0) and (net_ev_run / exp_hands) or 0
        local roi_pct = (buy_in > 0) and ((net_ev_run / buy_in) * 100) or 0

        return {
            stake = stake,
            gtype = gtype,
            per_tier = per_tier,
            pool = {
                win_chance  = wc,
                win_dist    = wd,
                loss_dist   = ld,
                ev_per_hand = ev_per_hand,
                net_ev_run  = net_ev_run,
                roi_pct     = roi_pct,
                exp_payout  = exp_payout,
                exp_hands   = exp_hands,
                pos_probs   = pos_probs,
                buy_in      = buy_in,
                win_avg_bb  = win_avg,
                loss_avg_bb = loss_avg,
            },
        }
    elseif gtype.hand_count and not gtype.chip_stack_table then
        local buy_in = stake.buy_in or 0
        local cap = gtype.hand_count or 8
        local boost = ctx.mtt_payout_boost or 0
        local payouts = MttPayouts[boost] or MttPayouts[0]

        local function finishOdds(k)
            return (k >= cap) and (wc ^ k) or (wc ^ k) * (1 - wc)
        end
        local exp_mult = 0
        for k, mult in pairs(payouts) do
            exp_mult = exp_mult + finishOdds(k) * mult
        end
        local net_ev_run = buy_in * (exp_mult - 1)
        local ev_per_hand = (cap > 0) and (net_ev_run / cap) or 0
        local roi_pct = (buy_in > 0) and ((net_ev_run / buy_in) * 100) or 0

        return {
            stake = stake,
            gtype = gtype,
            per_tier = per_tier,
            pool = {
                win_chance  = wc,
                win_dist    = wd,
                loss_dist   = ld,
                ev_per_hand = ev_per_hand,
                net_ev_run  = net_ev_run,
                roi_pct     = roi_pct,
                exp_hands   = cap,
                buy_in      = buy_in,
                win_avg_bb  = win_avg,
                loss_avg_bb = loss_avg,
            },
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
