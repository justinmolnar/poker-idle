-- views/Chips.lua
--
-- Engine-agnostic chip rendering. Operates on opaque denomination
-- indices (into data/chips.lua); no knowledge of poker. Procedural
-- top-down chips for now — `drawChip` is the single seam to swap in
-- sprite art later.
--
-- The breakdown algorithm picks a chip composition that signals
-- *magnitude* (target chip count from tier hint) rather than minimizing
-- chip count. A T1 jackpot's $2 yields a pile of ~35 chips on the
-- felt, not 2 × $1, because the player needs to *see* the win is big.

local ChipData = require("data.chips")
local Theme    = require("views.Theme")

local Chips = {}

-- ── Constants (procedural rendering tunables) ────────────────────────
local CHIP_RADIUS    = 11
local CHIP_DIAMETER  = 2 * CHIP_RADIUS
local STACK_OFFSET_Y = -3
local COL_GAP        = 2
local MAX_PER_COLUMN = 6
local LABEL_FONT_PX  = 9      -- baseline label font

-- Lazy-initialised font for chip labels. Held in module scope so we don't
-- thrash newFont every frame.
local _label_font
local function getLabelFont()
    if not _label_font then
        _label_font = love.graphics.newFont(LABEL_FONT_PX)
    end
    return _label_font
end

-- ── Tier inference for surfaces without an explicit tier hint ────────
-- Used by the bankroll pile and resting player stacks (no per-hand
-- outcome_tier). Maps amount-in-bb to the same four buckets the outcome
-- model uses: tiny < 5 bb, small < 18, medium < 80, jackpot >= 80.
function Chips.tierFromBB(magnitude_bb)
    if magnitude_bb < 5  then return "tiny"    end
    if magnitude_bb < 18 then return "small"   end
    if magnitude_bb < 80 then return "medium"  end
    return "jackpot"
end

-- For surfaces without a stake context (the bankroll pile), bucket by
-- log10(amount) so a $5 bankroll reads "tiny" and a $5M reads "jackpot".
function Chips.tierFromAmount(amount)
    if amount <= 0 then return "tiny" end
    local mag = math.log10(amount)
    if mag < 1 then return "tiny"    end   -- < $10
    if mag < 3 then return "small"   end   -- < $1k
    if mag < 5 then return "medium"  end   -- < $100k
    return "jackpot"
end

-- ── Breakdown: amount → ordered chip-index list ──────────────────────
-- `palette_indices` is a list of indices into ChipData.denominations
-- (e.g., a stake's `stake_palettes` entry, or `full_palette` for bankroll).
-- `tier_hint` ∈ {"tiny","small","medium","jackpot"} biases the result
-- toward a target chip count for visual heft. Optional — falls back to
-- "small" if omitted.
function Chips.breakdown(amount, palette_indices, tier_hint)
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
    local chips   = {}
    local remaining = amount

    -- Showcase chip (medium / jackpot only) — one chip of the next-larger
    -- denomination on top of the pile, signalling "this is a big one."
    if (tier_hint == "medium" or tier_hint == "jackpot") and primary_idx > 1 then
        local showcase = denoms[primary_idx - 1]
        if showcase.value <= remaining + 1e-9 then
            chips[#chips + 1] = showcase.idx
            remaining = remaining - showcase.value
        end
    end

    -- Fill primary.
    while remaining >= primary.value - 1e-9 do
        chips[#chips + 1] = primary.idx
        remaining = remaining - primary.value
    end

    -- Greedy change with smaller denominations.
    for i = primary_idx + 1, #denoms do
        local d = denoms[i]
        while remaining >= d.value - 1e-9 do
            chips[#chips + 1] = d.idx
            remaining = remaining - d.value
        end
    end

    return chips
end

-- ── Single chip render (the seam for sprite art later) ───────────────
-- with_label = true draws the denomination text centered on the chip,
-- with auto-contrast (light label on dark chips, dark on light) chosen
-- by Y'CbCr-ish luminance.
function Chips.drawChip(x, y, denom_idx, alpha, with_label)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    local c = d.color

    -- Outer ring — darkened denomination color.
    local dark = { c[1] * 0.55, c[2] * 0.55, c[3] * 0.55 }
    Theme.setColor(dark, alpha)
    love.graphics.circle("fill", x, y, CHIP_RADIUS)

    -- Inner disc — full-saturation denomination color.
    Theme.setColor(c, alpha)
    love.graphics.circle("fill", x, y, CHIP_RADIUS - 2)

    if with_label and d.label then
        local prev_font = love.graphics.getFont()
        local font      = getLabelFont()
        love.graphics.setFont(font)
        local lum  = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
        local tone = (lum > 0.55) and Theme.bg.window or Theme.fg.heading
        Theme.setColor(tone, alpha)
        local fw = font:getWidth(d.label)
        local fh = font:getHeight()
        love.graphics.print(d.label, x - fw * 0.5, y - fh * 0.5)
        if prev_font then love.graphics.setFont(prev_font) end
    end
end

-- Approximate footprint of a stack render, for layout hit-testing if
-- ever needed. Returns (width, height) in px.
function Chips.stackFootprint(chip_indices)
    if not chip_indices or #chip_indices == 0 then return 0, 0 end
    -- Quick group-count to get column count.
    local seen, groups = {}, 0
    local counts = {}
    for _, idx in ipairs(chip_indices) do
        if not seen[idx] then
            seen[idx] = true
            groups = groups + 1
        end
        counts[idx] = (counts[idx] or 0) + 1
    end
    local cols = 0
    for _, n in pairs(counts) do
        cols = cols + math.ceil(n / MAX_PER_COLUMN)
    end
    local w = cols * CHIP_DIAMETER + math.max(0, cols - 1) * COL_GAP
    local h = CHIP_DIAMETER + math.max(0, MAX_PER_COLUMN - 1) * (-STACK_OFFSET_Y)
    return w, h
end

-- ── Stack render — multi-column pile, anchored at (x, y) ─────────────
-- Default align = "center" (pile centered on x). y is the BOTTOM of
-- each column (chips stack upward via STACK_OFFSET_Y).
--
-- Groups chips by denomination in their first-appearance order. A
-- showcase chip (when present) renders as its own group at the front,
-- so it visually sits on its own short column at the left end.
function Chips.drawStack(x, y, chip_indices, options)
    if not chip_indices or #chip_indices == 0 then return end
    options = options or {}
    local align = options.align or "center"

    -- Group by denomination preserving first-appearance order.
    local groups, group_for = {}, {}
    for _, idx in ipairs(chip_indices) do
        local g = group_for[idx]
        if not g then
            groups[#groups + 1] = { idx = idx, count = 1 }
            group_for[idx]      = #groups
        else
            groups[g].count = groups[g].count + 1
        end
    end

    -- Total columns across all groups (each group breaks into vertical
    -- columns of MAX_PER_COLUMN chips each).
    local total_cols = 0
    for _, g in ipairs(groups) do
        total_cols = total_cols + math.ceil(g.count / MAX_PER_COLUMN)
    end

    local total_w = total_cols * CHIP_DIAMETER
                    + math.max(0, total_cols - 1) * COL_GAP

    local origin_x
    if align == "left"  then origin_x = x
    elseif align == "right" then origin_x = x - total_w
    else origin_x = x - total_w / 2 end

    local cx = origin_x + CHIP_RADIUS
    for _, g in ipairs(groups) do
        local cols = math.ceil(g.count / MAX_PER_COLUMN)
        for c = 1, cols do
            local in_col = math.min(MAX_PER_COLUMN, g.count - (c - 1) * MAX_PER_COLUMN)
            for i = 1, in_col do
                local cy = y + (i - 1) * STACK_OFFSET_Y
                -- Label only the topmost chip of each column — labels on
                -- buried chips would be obscured anyway.
                local with_label = (i == in_col)
                Chips.drawChip(cx, cy, g.idx, 1, with_label)
            end
            cx = cx + CHIP_DIAMETER + COL_GAP
        end
    end
end

return Chips
