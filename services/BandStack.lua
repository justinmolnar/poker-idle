-- services/BandStack.lua
--
-- Generic 1-D layout allocator. Engine-agnostic infrastructure: pure math,
-- no rendering, no domain knowledge (mirrors services/DenominationBreakdown).
-- Knows nothing about any specific UI or game — it stacks abstract bands in
-- a length and splits a width three ways. Liftable into any project verbatim.
--
-- Two operations:
--   • allocate  — pack ordered vertical bands into a height, dropping the
--                 lowest-priority "optional" bands when they don't all fit,
--                 then distributing leftover slack by weight.
--   • threeUp   — place a left-anchored and a right-anchored item in a width
--                 and report whether a centered item fits in the gap between.

local BandStack = {}

local function ifloor(v) return math.floor(v) end

-- Pack `bands` (ordered top→bottom) into `total_h`, separated by `gap`.
--
-- Each band: { min_h = number, weight = number?, drop_priority = number? }
--   • Bands with a drop_priority are OPTIONAL. When the kept set's summed
--     minimums + gaps exceed total_h, the optional band with the SMALLEST
--     drop_priority is dropped first, repeating until it fits (or only
--     required bands remain — see the return contract).
--   • Leftover slack (total_h - kept minimums - gaps) is handed out in
--     proportion to `weight` (default 0 → fixed-height band).
--
-- Returns:
--   • rects: array parallel to `bands`; rects[i] = { y, h } for a kept band
--            (y relative to 0 at the stack's top), or nil for a dropped one.
--   • nil  : if the REQUIRED (non-optional) bands can't fit even alone — the
--            caller decides how to degrade past that floor.
function BandStack.allocate(total_h, bands, gap)
    gap = gap or 0
    local n = #bands
    local kept = {}
    for i = 1, n do kept[i] = true end

    local function requiredHeight()
        local sum, count = 0, 0
        for i = 1, n do
            if kept[i] then sum = sum + bands[i].min_h; count = count + 1 end
        end
        if count > 0 then sum = sum + gap * (count - 1) end
        return sum
    end

    -- Drop optional bands (smallest drop_priority first) until it fits.
    while requiredHeight() > total_h do
        local victim = nil
        for i = 1, n do
            if kept[i] and bands[i].drop_priority then
                if not victim or bands[i].drop_priority < bands[victim].drop_priority then
                    victim = i
                end
            end
        end
        if not victim then break end   -- nothing droppable left; pack as-is (overlap, never drop)
        kept[victim] = false
    end

    -- Distribute slack by weight among the kept bands.
    local total_min, total_weight, count = 0, 0, 0
    for i = 1, n do
        if kept[i] then
            total_min = total_min + bands[i].min_h
            total_weight = total_weight + (bands[i].weight or 0)
            count = count + 1
        end
    end
    local gaps  = (count > 0) and gap * (count - 1) or 0
    local slack = math.max(0, total_h - total_min - gaps)

    local rects, y = {}, 0
    for i = 1, n do
        if kept[i] then
            local extra = (total_weight > 0)
                and ifloor(slack * (bands[i].weight or 0) / total_weight) or 0
            local h = bands[i].min_h + extra
            rects[i] = { y = y, h = h }
            y = y + h + gap
        else
            rects[i] = nil
        end
    end
    return rects
end

-- Place a left-anchored item (width left_w) and a right-anchored item
-- (width right_w) inside `total_w`, with `inner` padding flanking a centered
-- item of width center_w. Reports whether the centered item fits the gap.
--
-- Returns { left_x, right_x, center_x, center_show } with x's relative to 0.
function BandStack.threeUp(total_w, left_w, right_w, center_w, inner)
    inner = inner or 0
    local left_x  = 0
    local right_x = total_w - right_w
    local gap_left  = left_w + inner
    local gap_right = right_x - inner
    local center_show = (gap_right - gap_left) >= center_w
    local center_x = ifloor((total_w - center_w) / 2)
    return {
        left_x = left_x,
        right_x = right_x,
        center_x = center_x,
        center_show = center_show,
    }
end

return BandStack
