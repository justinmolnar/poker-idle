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

-- Sum strength across descriptors that match this gtype.
local function sumFills(list, gtype)
    if not list then return 0 end
    local total = 0
    for _, d in ipairs(list) do
        if shiftApplies(d, gtype) then
            total = total + (d.strength or 1)
        end
    end
    return total
end
OutcomeMath.sumFills = sumFills

-- Convert fill units to a [0, 1] ratio via the stake's fill_window.
-- Below window.start: 0 (warmup). At window.complete: 1. Linear in between.
local function fillRatio(units, window)
    if not window then return 1 end
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)
    local span     = complete - start
    if span <= 0 then return units >= complete and 1 or 0 end
    local r = (units - start) / span
    if r < 0 then return 0 end
    if r > 1 then return 1 end
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
    -- 1. Sum fill units per dimension (filtered by gtype).
    local wc_units = sumFills(ctx and ctx.win_chance_fills, gtype)
    local wd_units = sumFills(ctx and ctx.win_dist_fills,   gtype)
    local ld_units = sumFills(ctx and ctx.loss_dist_fills,  gtype)

    -- 2. Convert to fill ratio via stake's window.
    local window = stake and stake.fill_window
    local wc_fill = fillRatio(wc_units, window)
    local wd_fill = fillRatio(wd_units, window)
    local ld_fill = fillRatio(ld_units, window)

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
        local tier_idx = stake and Lookups.indexById(StakesData, stake.id) or nil
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

return OutcomeMath
