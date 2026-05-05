-- views/Chips.lua
--
-- Engine-agnostic chip rendering. Operates on opaque denomination
-- indices (into data/chips.lua); no knowledge of poker. Procedural
-- top-down chips for now — `drawChip` is the single seam to swap in
-- sprite art later.
--
-- Pure breakdown logic (amount → ordered token-index list, tier inference)
-- lives in services/DenominationBreakdown so non-view callers can compose
-- breakdowns without reaching across layers.

local ChipData = require("data.chips")
local Theme    = require("views.Theme")

local Chips = {}

-- ── Constants (procedural rendering tunables) ────────────────────────
-- Bases are the 1× design values; the live values are recomputed by
-- Chips.setScale(s) at boot + resize so chips grow with the window.
local CHIP_RADIUS_BASE   = 11
local STACK_OFFSET_Y_BASE = -3
local COL_GAP_BASE       = 2
local LABEL_FONT_PX_BASE = 9

local CHIP_RADIUS    = CHIP_RADIUS_BASE
local CHIP_DIAMETER  = 2 * CHIP_RADIUS
local STACK_OFFSET_Y = STACK_OFFSET_Y_BASE
local COL_GAP        = COL_GAP_BASE
local MAX_PER_COLUMN = 6
local LABEL_FONT_PX  = LABEL_FONT_PX_BASE

-- Lazy-initialised font for chip labels. Held in module scope so we don't
-- thrash newFont every frame. Invalidated by Chips.setScale.
local _label_font
local function getLabelFont()
    if not _label_font then
        _label_font = love.graphics.newFont(LABEL_FONT_PX)
    end
    return _label_font
end

-- Rescale chip rendering against the live ui_scale. main.lua calls
-- this at boot + on resize.
function Chips.setScale(s)
    s = s or 1
    CHIP_RADIUS    = math.max(2, math.floor(CHIP_RADIUS_BASE * s))
    CHIP_DIAMETER  = 2 * CHIP_RADIUS
    STACK_OFFSET_Y = math.floor(STACK_OFFSET_Y_BASE * s)
    COL_GAP        = math.max(1, math.floor(COL_GAP_BASE * s))
    LABEL_FONT_PX  = math.max(6, math.floor(LABEL_FONT_PX_BASE * s))
    _label_font    = nil  -- force rebuild at new size on next getLabelFont
end

-- ── Single chip render (the seam for sprite art later) ───────────────
-- with_label = true draws the denomination text centered on the chip,
-- with auto-contrast (light label on dark chips, dark on light) chosen
-- by Y'CbCr-ish luminance.
--
-- tint (optional) is a {r, g, b} multiplier applied to the chip body
-- color so per-stake themes can shift the chip palette toward warm gold
-- (T6) or desaturated dim (T1) without redefining the denomination
-- colors. {1, 1, 1} (or nil) is identity.
function Chips.drawChip(x, y, denom_idx, alpha, with_label, tint)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    local c = d.color
    if tint then
        c = { c[1] * tint[1], c[2] * tint[2], c[3] * tint[3] }
    end

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

-- Build deferred-render closures for a chip-index list. Each closure
-- captures its denomination and renders one chip at the (x, y) the
-- caller (e.g. FlightSystem) hands back at draw time.
--
-- Lives here, not in the controller, so the controller never has to
-- name a draw function; it just hands the resulting closure list to
-- FlightSystem.emitBurst. Keeps the view layer the only producer of
-- render callbacks.
function Chips.makeRenderFns(chip_indices, tint)
    local fns = {}
    if not chip_indices then return fns end
    for i, idx in ipairs(chip_indices) do
        fns[i] = function(x, y) Chips.drawChip(x, y, idx, 1, true, tint) end
    end
    return fns
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
    local tint  = options.tint                       -- nil = identity (no tint)
    local max_w = options.max_w                      -- nil = unbounded width

    -- Group by denomination preserving first-appearance order. Breakdown
    -- returns chips largest-denom-first, so the FIRST groups are the
    -- biggest chips and the LAST groups are the smallest.
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

    -- Cols-per-group helper. Each group breaks into vertical columns of
    -- MAX_PER_COLUMN chips each.
    local function colsFor(g) return math.ceil(g.count / MAX_PER_COLUMN) end
    local function widthFor(cols)
        return cols * CHIP_DIAMETER + math.max(0, cols - 1) * COL_GAP
    end

    -- If a width budget is set and the natural layout overflows, drop
    -- columns from the smallest-denomination groups (the tail) one at a
    -- time until the pile fits. Largest-denomination chips (the
    -- showcase + primary tier) are always preserved — better to lose a
    -- handful of trailing 1¢ chips than to lose the fat 25¢ stack that
    -- signals "this is a big pot".
    if max_w and max_w > 0 then
        local total_cols = 0
        for _, g in ipairs(groups) do total_cols = total_cols + colsFor(g) end
        while widthFor(total_cols) > max_w and #groups > 0 do
            local last = groups[#groups]
            -- Drop one column's worth of chips from the tail group.
            last.count = last.count - MAX_PER_COLUMN
            if last.count <= 0 then
                groups[#groups] = nil
            end
            total_cols = total_cols - 1
        end
        if #groups == 0 then return end   -- everything got dropped
    end

    -- Recompute total cols / width after any clipping.
    local total_cols = 0
    for _, g in ipairs(groups) do total_cols = total_cols + colsFor(g) end
    local total_w = widthFor(total_cols)

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
                Chips.drawChip(cx, cy, g.idx, 1, with_label, tint)
            end
            cx = cx + CHIP_DIAMETER + COL_GAP
        end
    end
end

return Chips
