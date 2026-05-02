-- services/DenominationBreakdown.lua
--
-- Pure-logic breakdown of a magnitude into an ordered list of denomination
-- indices. Engine-agnostic: operates on opaque indices into a denomination
-- ladder (data file). No domain knowledge, no rendering — the drawing seam
-- is owned by views.
--
-- The breakdown algorithm picks a composition that signals *magnitude*
-- (target token count from a tier hint) rather than minimizing token count
-- — a top-tier $2 yields ~35 tokens, not 2×$1, because the player needs to
-- *see* the magnitude.

local ChipData = require("data.chips")

local DenominationBreakdown = {}

-- ── Tier inference for surfaces without an explicit tier hint ────────
-- Maps a magnitude in caller-defined units to the four target buckets.
-- Thresholds match the unit conventions in the consuming data file's tier
-- table.
function DenominationBreakdown.tierFromUnit(magnitude)
    if magnitude < 5  then return "tiny"    end
    if magnitude < 18 then return "small"   end
    if magnitude < 80 then return "medium"  end
    return "jackpot"
end

-- For surfaces without a unit context, bucket by log10(amount) so small
-- numbers read "tiny" and very large ones read "jackpot".
function DenominationBreakdown.tierFromAmount(amount)
    if amount <= 0 then return "tiny" end
    local mag = math.log10(amount)
    if mag < 1 then return "tiny"    end   -- < 10
    if mag < 3 then return "small"   end   -- < 1k
    if mag < 5 then return "medium"  end   -- < 100k
    return "jackpot"
end

-- ── Breakdown: amount → ordered denomination-index list ──────────────
-- `palette_indices` is a list of indices into ChipData.denominations.
-- `tier_hint` ∈ {"tiny","small","medium","jackpot"} biases the result
-- toward a target token count for visual heft. Optional — falls back to
-- "small" if omitted.
function DenominationBreakdown.breakdown(amount, palette_indices, tier_hint)
    if amount <= 0 or not palette_indices or #palette_indices == 0 then
        return {}
    end

    -- Sort palette by descending value so we walk largest-first.
    local denoms = {}
    for _, idx in ipairs(palette_indices) do
        denoms[#denoms + 1] = {
            idx   = idx,
            value = ChipData.denominations[idx].value,
        }
    end
    table.sort(denoms, function(a, b) return a.value > b.value end)

    local target_count = ChipData.tier_chip_target[tier_hint or "small"] or 8

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

    -- Showcase token (medium / jackpot only) — one token of the next-larger
    -- denomination on top of the pile, signalling "this is a big one."
    if (tier_hint == "medium" or tier_hint == "jackpot") and primary_idx > 1 then
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
