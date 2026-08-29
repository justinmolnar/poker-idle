-- views/HintView.lua
--
-- Renders the tutorial hint layer (see controllers/HintController): the
-- active STICKY hint — an instruction ("open a table"). The rest of the
-- screen dims; the highlighted widget(s) + the bubble punch through at
-- full brightness. Stays until acted on (or the bubble is clicked).
--
-- The [i] info-hint strip that used to share this layer is RETIRED:
-- teaching lives in story beats, reference in the glossary.
--
-- A hint's `anchor` may be one name or a list — every fresh anchor gets a
-- highlight hole; the bubble hangs off the first fresh one.
--
-- Presence follows the target. Anchors are frame-stamped; a hint with NO
-- fresh anchor (none of its widgets drew this frame) is simply not
-- rendered: the bubble vanishes, nothing is dismissed — the moment a
-- target draws again, the hint returns with it. Generic: no per-hint
-- cases.
--
-- The dim is a cached full-screen canvas: fill with the backdrop tint,
-- erase the holes with a replace-blend, composite back. No stencil, so
-- the main frame canvas needs no stencil buffer.
--
-- The host state routes clicks via :mousepressed (→ "bubble" | nil) to
-- HintController; this view never mutates anything (MVC). Clicks on the
-- highlighted widget itself pass through untouched — that's the
-- advance-on-action path.

local Theme       = require("views.Theme")
local IconText    = require("views.IconText")
local Anchors     = require("services.AnchorRegistry")
local HintMarks   = require("views.HintMarks")

local HintView = {}
HintView.__index = HintView

local BUBBLE_MAX_W_BASE = 340   -- text wrap width, pre-scale
local FOOTER = "click to dismiss"

-- Dim overlay: constant darkness; every hole feathers out over
-- FEATHER_STEPS bands instead of a hard cut, and the hole EDGE grows and
-- shrinks in phase with the pulsing highlight border.
local DIM_BASE      = 0.75
local FEATHER_STEPS = 6
local FEATHER_PX    = 4   -- band width, pre-scale

-- Color constants routed through Theme.setColor (never raw setColor):
-- CLEAR erases dim-canvas holes (alpha 0 under replace blend), WHITE
-- composites the canvas back untinted.
local CLEAR = { 0, 0, 0 }
local WHITE = { 1, 1, 1 }

-- Anchor freshness and the mark list live in views/HintMarks, shared with
-- the story band so a popup and a beat point at a widget the same way.
local freshAnchor = HintMarks.freshAnchor

local function freshMarks(hint)
    return HintMarks.fresh(hint.anchor)
end

function HintView:new(game)
    return setmetatable({
        game        = game,
        bubble_rect = nil,   -- active sticky hint's bubble, for hit-test
        _dim_canvas = nil,   -- lazily built full-screen scratch canvas
    }, HintView)
end

-- Word-wrap `str` (with inline {icon} markers) to max_w using IconText
-- measurement. Returns the line list + the widest line's width.
local function wrapLines(str, font, max_w)
    local space_w = font:getWidth(" ")
    local lines, widest = {}, 0
    local line, line_w = nil, 0
    local function flush()
        if line then
            lines[#lines + 1] = line
            if line_w > widest then widest = line_w end
            line, line_w = nil, 0
        end
    end
    for word in str:gmatch("%S+") do
        local ww = IconText.measure(word, font)
        if not line then
            line, line_w = word, ww
        elseif line_w + space_w + ww <= max_w then
            line, line_w = line .. " " .. word, line_w + space_w + ww
        else
            flush()
            line, line_w = word, ww
        end
    end
    flush()
    return lines, widest
end

-- ── Layout ───────────────────────────────────────────────────────────

-- Everything needed to render one hint: the fresh anchor marks, wrapped
-- copy, and the bubble rect (placed against the FIRST mark: right → left
-- → below → above, first placement fully on screen, clamped regardless).
-- nil when no target is on screen. `with_footer = false` drops the
-- "click to dismiss" row (help-desk replays aren't dismissable).
function HintView:_layoutHint(hint, with_footer)
    local marks = freshMarks(hint)
    if #marks == 0 then return nil end

    local game  = self.game
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local W, H  = love.graphics.getDimensions()

    local font      = fonts.sm
    local lh        = font:getHeight()
    local pad_x     = fl(12 * s)
    local pad_y     = fl(10 * s)
    local line_gap  = fl(2 * s)
    -- hint.text is one string or a LIST of paragraph strings — each
    -- paragraph wraps on its own with a gap before it, so structured
    -- copy (a glyph legend row, then prose) doesn't run together.
    local paras    = (type(hint.text) == "table") and hint.text
                     or { hint.text }
    local para_gap = fl(6 * s)
    local lines, text_w = {}, 0
    for pi, para in ipairs(paras) do
        local plines, pw = wrapLines(para, font, fl(BUBBLE_MAX_W_BASE * s))
        for li, str in ipairs(plines) do
            lines[#lines + 1] = {
                t   = str,
                gap = (pi > 1 and li == 1) and para_gap or 0,
            }
        end
        if pw > text_w then text_w = pw end
    end
    local body_h = -line_gap
    for _, l in ipairs(lines) do
        body_h = body_h + l.gap + lh + line_gap
    end
    local footer    = (with_footer ~= false) and FOOTER or nil
    local footer_w  = footer and font:getWidth(footer) or 0
    local bw = math.max(text_w, footer_w) + pad_x * 2
    local bh = pad_y * 2 + body_h
               + (footer and (fl(6 * s) + lh) or 0)   -- footer row

    -- Placement: the bubble is THE HOUSE talking. When the poster is on
    -- screen (registered by GrindView as anchor "house") the bubble
    -- rises from it — right-aligned above, with a speech tail down to
    -- the roof. Fallback when there's no House on screen: float beside
    -- the first mark, clamped, never covering a highlighted mark.
    local gap    = fl(14 * s)
    local margin = fl(8 * s)
    local pad    = fl(8 * s)   -- max highlight-pulse extent
    local house  = Anchors.age("house") <= 1 and Anchors.get("house") or nil
    local bx, by, tail
    if house and house[3] then
        bx = math.max(margin,
             math.min(house[1] + house[3], W - margin) - bw)
        by = math.max(margin, house[2] - gap - bh)
        tail = { tip_x = house[1] + house[3] * 0.5,
                 tip_y = house[2] + fl(4 * s) }
    else
        local m      = marks[1]
        local cx, cy = m.x + m.w / 2, m.y + m.h / 2
        local spots = {
            { x = m.x + m.w + gap + pad, y = cy - bh / 2 },        -- right
            { x = m.x - gap - pad - bw,  y = cy - bh / 2 },        -- left
            { x = cx - bw / 2,           y = m.y + m.h + gap + pad },  -- below
            { x = cx - bw / 2,           y = m.y - gap - pad - bh },   -- above
        }
        -- Each candidate is clamped to the viewport first, then rejected
        -- if the clamped rect would sit on ANY highlighted mark —
        -- clamping used to shove corner-anchored bubbles right on top of
        -- their own target.
        local function clampSpot(p)
            return math.max(margin, math.min(p.x, W - margin - bw)),
                   math.max(margin, math.min(p.y, H - margin - bh))
        end
        local function coversAMark(x, y)
            for _, mk in ipairs(marks) do
                if x < mk.x + mk.w + pad and x + bw > mk.x - pad
                   and y < mk.y + mk.h + pad and y + bh > mk.y - pad then
                    return true
                end
            end
            return false
        end
        bx, by = clampSpot(spots[1])
        for _, p in ipairs(spots) do
            local px, py = clampSpot(p)
            if not coversAMark(px, py) then
                bx, by = px, py
                break
            end
        end
    end

    return {
        marks  = marks,
        lines  = lines,
        footer = footer,
        tail   = tail,
        -- The speaker stays lit: callers punch this out of the dim too.
        house  = house and { x = house[1], y = house[2],
                             w = house[3], h = house[4] } or nil,
        bubble = { x = fl(bx), y = fl(by), w = bw, h = bh },
    }
end

-- ── Dim overlay ──────────────────────────────────────────────────────

-- Dim the whole frame except `holes` (rects; entries with is_rect ==
-- false are point marks and punch a circle). Built on a scratch canvas
-- so multiple holes stay simple; composited premultiplied.
--
-- Feathering: replace-blend passes walk from the outermost band (full
-- dim) down to the hole interior (alpha 0). A later, smaller pass
-- overwrites any earlier band it covers, so where two holes' feathers
-- overlap the pixel ends at the LOWEST alpha of the two — soft holes
-- union cleanly with no seams.
function HintView:_drawDim(holes)
    local W, H = love.graphics.getDimensions()
    if not self._dim_canvas
       or self._dim_canvas:getWidth()  ~= W
       or self._dim_canvas:getHeight() ~= H then
        self._dim_canvas = love.graphics.newCanvas(W, H)
    end

    local s    = self.game.ui_scale or 1
    local fl   = math.floor
    local prev = love.graphics.getCanvas()

    local dim = DIM_BASE

    love.graphics.setCanvas(self._dim_canvas)
    love.graphics.clear(0, 0, 0, 0)
    Theme.setColor(Theme.debug.hud_bg, dim)
    love.graphics.rectangle("fill", 0, 0, W, H)
    love.graphics.setBlendMode("replace", "premultiplied")
    -- Hole edge breathes with the highlight ring: same sin(t*4) offset
    -- _drawHint adds to its border pad, so gradient and ring move as one.
    local t        = love.timer.getTime()
    local base_pad = fl(10 * s) + fl(2 * math.sin(t * 4) + 2)
    local band     = math.max(1, fl(FEATHER_PX * s))
    for step = FEATHER_STEPS, 0, -1 do
        Theme.setColor(CLEAR, dim * (step / FEATHER_STEPS))
        local grow = base_pad + step * band
        for _, hole in ipairs(holes) do
            if hole.is_rect == false then
                love.graphics.circle("fill",
                    hole.x, hole.y, fl(18 * s) + grow)
            else
                love.graphics.rectangle("fill",
                    hole.x - grow, hole.y - grow,
                    hole.w + grow * 2, hole.h + grow * 2,
                    fl(4 * s) + fl(grow * 0.5))
            end
        end
    end
    love.graphics.setBlendMode("alpha")
    love.graphics.setCanvas(prev)

    love.graphics.setBlendMode("alpha", "premultiplied")
    Theme.setColor(WHITE)
    love.graphics.draw(self._dim_canvas, 0, 0)
    love.graphics.setBlendMode("alpha")
end

-- ── Rendering ────────────────────────────────────────────────────────

-- Pulsing highlight rings around a mark list (views/HintMarks).
function HintView:_drawMarks(marks)
    HintMarks.draw(self.game, marks)
end

-- Pulsing highlight around every fresh mark + the copy bubble.
-- `track_bubble` stashes the bubble rect for the host's hit-test.
function HintView:_drawHint(layout, track_bubble)
    local game  = self.game
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor

    self:_drawMarks(layout.marks)

    local b        = layout.bubble
    local font     = fonts.sm
    local lh       = font:getHeight()
    local pad_x    = fl(12 * s)
    local pad_y    = fl(10 * s)
    local line_gap = fl(2 * s)
    local r        = fl(4 * s)
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, r)
    Theme.setColor(Theme.status.warn)
    love.graphics.rectangle("line", b.x, b.y, b.w, b.h, r)

    -- Speech tail down to THE HOUSE: fill first (covers the bubble's
    -- border segment at the base), then the two edges.
    if layout.tail then
        local tw     = fl(9 * s)
        local base_y = b.y + b.h
        local tip_x  = math.max(b.x + r + tw,
                       math.min(layout.tail.tip_x, b.x + b.w - r - tw))
        Theme.setColor(Theme.bg.window)
        love.graphics.polygon("fill",
            tip_x - tw, base_y - 1,
            tip_x + tw, base_y - 1,
            tip_x, layout.tail.tip_y)
        Theme.setColor(Theme.status.warn)
        love.graphics.line(tip_x - tw, base_y, tip_x, layout.tail.tip_y)
        love.graphics.line(tip_x + tw, base_y, tip_x, layout.tail.tip_y)
    end

    love.graphics.setFont(font)
    local ty = b.y + pad_y
    for _, line in ipairs(layout.lines) do
        ty = ty + line.gap
        IconText.draw(game, line.t, b.x + pad_x, ty, font, Theme.fg.primary)
        ty = ty + lh + line_gap
    end
    if layout.footer then
        ty = ty - line_gap + fl(6 * s)
        Theme.setColor(Theme.fg.faint)
        love.graphics.print(layout.footer, b.x + pad_x, ty)
    end

    if track_bubble then
        self.bubble_rect = { x = b.x, y = b.y, w = b.w, h = b.h }
    end
end

-- Draw the hint layer: the active sticky hint, or nothing. `paused` (a
-- story beat is running): the sticky is hidden, not dismissed — he does
-- not talk over himself.
function HintView:draw(active, paused)
    self.bubble_rect = nil
    if paused or not active then return end

    local layout = self:_layoutHint(active)
    if not layout then return end

    local holes = { layout.bubble }
    for _, m in ipairs(layout.marks) do holes[#holes + 1] = m end
    if layout.house then holes[#holes + 1] = layout.house end
    self:_drawDim(holes)
    self:_drawHint(layout, true)
end

-- Hit-test a click against the hint layer:
--   "bubble" — the active sticky hint's bubble was clicked
--   nil      — not ours; the click falls through to normal input
--     (including clicks on the highlighted widget — advance-on-action).
function HintView:mousepressed(x, y)
    local b = self.bubble_rect
    if b and x >= b.x and x < b.x + b.w
         and y >= b.y and y < b.y + b.h then
        return "bubble"
    end
    return nil
end

-- Static export: word-wrap with {icon} measurement. Used by views/StoryView.
HintView.wrapLines = wrapLines

return HintView
