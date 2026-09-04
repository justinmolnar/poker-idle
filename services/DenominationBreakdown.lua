-- services/DenominationBreakdown.lua
--
-- Pure-logic breakdown of a magnitude into an ordered list of denomination
-- indices. Engine-agnostic: operates on opaque indices into a denomination
-- ladder supplied by the caller. No domain knowledge, no rendering — the
-- drawing seam is owned by views.
--
-- The breakdown algorithm picks a composition that signals *magnitude*
-- (target token count from a tier hint) rather than minimizing token count
-- — a top-tier $2 yields ~35 tokens, not 2×$1, because the player needs to
-- *see* the magnitude.
--
-- The caller passes the denomination ladder + tier-target table on every
-- call so this service stays uncoupled from any specific data file. A
-- poker-side caller will typically pass `ChipData.denominations` and
-- `ChipData.tier_chip_target`; a future game would pass its own.

local DenominationBreakdown = {}

-- Hard ceiling on tokens returned, whatever the amount.
--
-- Without it this is unbounded: the fill loop emits one token per unit of
-- the primary denomination, so an amount far past the top of the ladder
-- emits amount/top_value tokens. A trillion against a ladder topping out
-- at $1M is a MILLION-entry table — built on every recomposition, then
-- walked every frame by whatever lays the pile out. That is a freeze, not
-- a slowdown, and it arrives exactly when a player's numbers get big.
--
-- The ladder in data/chips.lua should always reach high enough that this
-- never binds; the cap is here so that running off the end of it degrades
-- to "the pile under-represents the value" instead of locking the game.
local MAX_TOKENS = 200

-- ── Tier inference for surfaces without an explicit tier hint ────────
-- Maps a magnitude in bb to the four target buckets. Thresholds are the
-- DEFAULT win bands' lower bounds from data/pot_tiers.lua — derived, not
-- duplicated, so a band retune moves these with it. Callers pass
-- gtype-agnostic amounts (buy-ins, cash-outs), which is exactly what the
-- default side is for.
local PotTiers = require("data.pot_tiers")
local _dw = PotTiers.default.win
function DenominationBreakdown.tierFromUnit(magnitude)
    if magnitude < _dw.medium.lo  then return "small"  end
    if magnitude < _dw.large.lo   then return "medium" end
    if magnitude < _dw.stack.lo then return "large"  end
    return "stack"
end

-- For surfaces without a unit context, bucket by log10(amount) so medium
-- numbers read "small" and very large ones read "stack".
function DenominationBreakdown.tierFromAmount(amount)
    if amount <= 0 then return "small" end
    local mag = math.log10(amount)
    if mag < 1 then return "small"    end   -- < 10
    if mag < 3 then return "medium"   end   -- < 1k
    if mag < 5 then return "large"  end   -- < 100k
    return "stack"
end

-- ── Palette choice for an amount ─────────────────────────────────────
-- A stake's four-chip window is sized for TABLE money (blinds, stacks).
-- A payout pushed through it composes as one top-denomination chip per
-- unit — hundreds of identical chips, stopped only by MAX_TOKENS above.
-- Past `palette_max_chips` top chips, compose off the full ladder
-- instead; it has a rung for every magnitude.
--
-- ONE definition, shared by the payout bursts (GrindController), the
-- flights (views/ChipFlight) and the live piles (views/TablePanel).
-- Anything derived from a payout — outcome_delta, r.delta, a pot that
-- can hold several stacks — belongs here. Bets and blinds are table
-- money and can use the stake window directly.
function DenominationBreakdown.paletteForAmount(chip_data, stake_id, amount)
    local pal = chip_data.stake_palettes[stake_id] or chip_data.full_palette
    local top = 0
    for _, idx in ipairs(pal) do
        local d = chip_data.denominations[idx]
        if d and d.value > top then top = d.value end
    end
    local cap = chip_data.palette_max_chips or 60
    if top > 0 and (amount or 0) / top > cap then
        return chip_data.full_palette
    end
    return pal
end

-- ── Breakdown: amount → ordered denomination-index list ──────────────
-- `denominations` is a list of `{ value = number, ... }` entries; only
-- `.value` is read. `palette_indices` is a list of indices into it.
-- `tier_chip_target` is a `{ small = N, medium = N, large = N, stack = N }`
-- table that drives target token count. `tier_hint` ∈ those keys biases
-- the result toward visual heft. Optional — falls back to "medium".
function DenominationBreakdown.breakdown(amount, denominations, palette_indices, tier_chip_target, tier_hint)
    if amount <= 0 or not palette_indices or #palette_indices == 0 then
        return {}
    end

    -- Sort palette by descending value so we walk largest-first.
    local denoms = {}
    for _, idx in ipairs(palette_indices) do
        denoms[#denoms + 1] = {
            idx   = idx,
            value = denominations[idx].value,
        }
    end
    table.sort(denoms, function(a, b) return a.value > b.value end)

    local target_count = (tier_chip_target and tier_chip_target[tier_hint or "medium"]) or 8

    -- Pick the primary denomination — the one whose count would land
    -- closest to target. Soft preference for being >= target ("chunkier"
    -- piles read richer).
    local primary_idx = #denoms   -- default to smallest if nothing fits well
    local best_score  = math.huge
    for i, d in ipairs(denoms) do
        local count = math.floor(amount / d.value + 1e-9)
        if count >= 1 then
            local diff = count - target_count
            -- Penalize being below target more than being above.
            local score = (diff < 0) and (-diff * 1.5) or diff
            if score < best_score then
                best_score  = score
                primary_idx = i
            end
        end
    end

    local primary = denoms[primary_idx]
    local tokens  = {}
    local remaining = amount

    -- Showcase token (large / stack only) — one token of the next-larger
    -- denomination on top of the pile, signalling "this is a big one."
    if (tier_hint == "large" or tier_hint == "stack") and primary_idx > 1 then
        local showcase = denoms[primary_idx - 1]
        if showcase.value <= remaining + 1e-9 then
            tokens[#tokens + 1] = showcase.idx
            remaining = remaining - showcase.value
        end
    end

    -- Fill primary. Counted rather than looped-until-empty: the count is
    -- what the cap has to be applied to, and an amount past the top of
    -- the ladder makes that count astronomically large.
    -- Relative epsilon, not the absolute 1e-9 the old loop compared
    -- against: it has to absorb float residue on a $0.01 rung and on a
    -- $5e17 one, and an absolute tolerance can only suit one of them.
    local n_primary = math.floor(remaining / primary.value + 1e-6)
    if n_primary > MAX_TOKENS - #tokens then n_primary = MAX_TOKENS - #tokens end
    for _ = 1, n_primary do
        tokens[#tokens + 1] = primary.idx
    end
    remaining = remaining - n_primary * primary.value

    -- Greedy change with smaller denominations. Naturally short — each
    -- rung contributes fewer tokens than its ratio to the next — but it
    -- shares the same budget so the total can't drift past the cap.
    for i = primary_idx + 1, #denoms do
        if #tokens >= MAX_TOKENS then break end
        local d = denoms[i]
        local n = math.floor(remaining / d.value + 1e-6)
        if n > MAX_TOKENS - #tokens then n = MAX_TOKENS - #tokens end
        for _ = 1, n do
            tokens[#tokens + 1] = d.idx
        end
        remaining = remaining - n * d.value
    end

    return tokens
end

return DenominationBreakdown
