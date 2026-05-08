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

-- ── Tier inference for surfaces without an explicit tier hint ────────
-- Maps a magnitude in caller-defined units to the four target buckets.
-- Thresholds match the unit conventions in the consuming data file's tier
-- table.
function DenominationBreakdown.tierFromUnit(magnitude)
    if magnitude < 5  then return "small"    end
    if magnitude < 18 then return "medium"   end
    if magnitude < 80 then return "large"  end
    return "jackpot"
end

-- For surfaces without a unit context, bucket by log10(amount) so medium
-- numbers read "small" and very large ones read "jackpot".
function DenominationBreakdown.tierFromAmount(amount)
    if amount <= 0 then return "small" end
    local mag = math.log10(amount)
    if mag < 1 then return "small"    end   -- < 10
    if mag < 3 then return "medium"   end   -- < 1k
    if mag < 5 then return "large"  end   -- < 100k
    return "jackpot"
end

-- ── Breakdown: amount → ordered denomination-index list ──────────────
-- `denominations` is a list of `{ value = number, ... }` entries; only
-- `.value` is read. `palette_indices` is a list of indices into it.
-- `tier_chip_target` is a `{ small = N, medium = N, large = N, jackpot = N }`
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

    -- Showcase token (large / jackpot only) — one token of the next-larger
    -- denomination on top of the pile, signalling "this is a big one."
    if (tier_hint == "large" or tier_hint == "jackpot") and primary_idx > 1 then
        local showcase = denoms[primary_idx - 1]
        if showcase.value <= remaining + 1e-9 then
            tokens[#tokens + 1] = showcase.idx
            remaining = remaining - showcase.value
        end
    end

    -- Fill primary.
    while remaining >= primary.value - 1e-9 do
        tokens[#tokens + 1] = primary.idx
        remaining = remaining - primary.value
    end

    -- Greedy change with smaller denominations.
    for i = primary_idx + 1, #denoms do
        local d = denoms[i]
        while remaining >= d.value - 1e-9 do
            tokens[#tokens + 1] = d.idx
            remaining = remaining - d.value
        end
    end

    return tokens
end

return DenominationBreakdown
