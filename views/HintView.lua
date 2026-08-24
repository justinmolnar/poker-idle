-- views/HintView.lua
--
-- Renders the tutorial hint layer (see controllers/HintController):
--
--   • The active STICKY hint — an instruction ("open a table"). The rest
--     of the screen dims; the highlighted widget(s) + the bubble punch
--     through at full brightness. Stays until acted on (or the bubble is
--     clicked). While a sticky is up the [i] queue is hidden entirely —
--     one voice at a time.
--   • The info-hint QUEUE — a vertical strip of small [i] buttons at the
--     "hint_queue" anchor. Hovering an icon shows that hint with the same
--     dim treatment (the strip itself stays lit); clicking the icon
--     dismisses it. Info hints never steal focus and can't be lost to a
--     stray click.
--
-- A hint's `anchor` may be one name or a list — every fresh anchor gets a
-- highlight hole; the bubble hangs off the first fresh one.
--
-- Presence follows the target. Anchors are frame-stamped; a hint with NO
-- fresh anchor (none of its widgets drew this frame) is simply not
-- rendered: the sticky bubble vanishes, the queue [i] drops out of the
-- strip. Nothing is dismissed — the moment a target draws again, the hint
-- returns with it. Generic: no per-hint cases.
--
-- The dim is a cached full-screen canvas: fill with the backdrop tint,
-- erase the holes with a replace-blend, composite back. No stencil, so
-- the main frame canvas needs no stencil buffer.
--
-- The host state routes clicks via :mousepressed (→ "bubble" | queued
-- spec | nil) to HintController; this view never mutates anything (MVC).
-- Clicks on the highlighted widget itself pass through untouched —
-- that's the advance-on-action path.

local Theme       = require("views.Theme")
local IconText    = require("views.IconText")
local Anchors     = require("services.AnchorRegistry")
local HintMarks   = require("views.HintMarks")
local LabelButton = require("views.widgets.LabelButton")
local AwardGlow   = require("views.AwardGlow")

local HintView = {}
HintView.__index = HintView

local BUBBLE_MAX_W_BASE = 340   -- text wrap width, pre-scale
local ICON_SIZE_BASE    = 26    -- queue [i] button square, pre-scale
local ICON_GAP_BASE     = 6
local FOOTER = "click to dismiss"

-- New-hint fanfare: the [i] gets the gold AwardGlow pop the moment it
-- first appears, then keeps a pulsing ring for NEW_PULSE_SECS so a
-- player looking elsewhere still catches it.
local NEW_PULSE_SECS = 3

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
        icon_rects  = {},    -- queue strip: { x, y, w, h, spec }
        _dim_canvas = nil,   -- lazily built full-screen scratch canvas
        -- New-hint fanfare bookkeeping (per session: a reload re-announces
        -- whatever's still unread — a feature, not a bug).
        _announced  = {},    -- id → true once its arrival fanfare fired
        _new_until  = {},    -- id → clock time the arrival pulse ends
        -- On-screen strip order (hint ids). Kept stable across frames:
        -- anything that becomes visible — first trigger OR a hidden hint
        -- whose target returned — APPENDS here, so icons already showing
        -- never get pushed around. Purely presentational; the persisted
        -- queue on GameState keeps its own order.
        display_order = {},
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

-- NOTE: views/HintLogPanel calls _drawDim and _drawMarks directly (dim
-- under its chrome, rings over it, so targets the panel covers still
-- read) — same hint-UI layer, deliberate coupling.

-- Pulsing highlight around every fresh mark + the copy bubble.
-- `track_bubble` stashes the bubble rect for the host's hit-test (only
-- the active sticky hint wants that — a hovered queue hint is dismissed
-- via its icon, not its bubble).
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

-- Draw the whole hint layer. `active` (sticky) may be nil; `queued` is
-- the spec list in queue order (may be empty/nil). While a sticky hint
-- renders, the queue strip is hidden entirely — one voice at a time.
-- `paused` (a story beat is running): the sticky is hidden, not
-- dismissed, and no hover preview opens; the [i] strip still draws so an
-- unread hint stays reachable.
function HintView:draw(active, queued, paused)
    self.bubble_rect = nil
    self.icon_rects  = {}
    if paused then active = nil end

    -- 1. Which queued hints are visible right now (a target drew this frame).
    local visible = {}
    for _, spec in ipairs(queued or {}) do
        if #freshMarks(spec) > 0 then visible[spec.id] = spec end
    end

    -- 2. Sync the stable strip order.
    local order = self.display_order
    for i = #order, 1, -1 do
        if not visible[order[i]] then table.remove(order, i) end
    end
    local shown = {}
    for _, id in ipairs(order) do shown[id] = true end
    for _, spec in ipairs(queued or {}) do
        if visible[spec.id] and not shown[spec.id] then
            order[#order + 1] = spec.id
            if not self._announced[spec.id] then
                self._announced[spec.id] = true
                self._new_until[spec.id] = love.timer.getTime() + NEW_PULSE_SECS
                AwardGlow.flash("hint:queue")
            end
        end
    end

    local n_available = #order
    local game   = self.game
    local s      = game.ui_scale or 1
    local fl     = math.floor
    -- The [i] button lives on the House poster in the grind, which
    -- registers "btn:info". Every other screen gets a corner rect instead.
    -- This used to be `if not ib then return end`, which aborted the WHOLE
    -- draw, sticky bubble included, anywhere the grind was not drawing --
    -- the single line that confined the tutorial to one screen.
    local ib = Anchors.get("btn:info") or self:_defaultInfoRect()
    local ix, iy, iw, ih = fl(ib[1]), fl(ib[2]), fl(ib[3]), fl(ib[4])
    -- Off the grind there is no poster to sit on, so the button only
    -- exists while it has something to show.
    -- Screens can opt out of the queue button entirely (the shove felt has
    -- one thing to read and a badge counting four hints is noise there).
    local info_visible = not self.suppress_queue
                         and (Anchors.get("btn:info") ~= nil or n_available > 0)

    -- 3. Resolve active sticky hint or hovered queued hint preview
    local active_layout = nil
    if active then
        active_layout = self:_layoutHint(active)
    end

    local mx, my = love.mouse.getPosition()
    local is_hovered = false
    local hovered_spec = nil

    if active_layout == nil and n_available > 0 and not paused then
        is_hovered = mx >= ix and mx < ix + iw and my >= iy and my < iy + ih
        if is_hovered then
            hovered_spec = visible[order[1]]
        end
    end

    local hovered_layout = hovered_spec and self:_layoutHint(hovered_spec)

    -- 4. Draw the dim overlay (if active or preview is hovered)
    if active_layout then
        local holes = { active_layout.bubble }
        for _, m in ipairs(active_layout.marks) do holes[#holes + 1] = m end
        if active_layout.house then holes[#holes + 1] = active_layout.house end
        self:_drawDim(holes)
    elseif hovered_layout then
        local holes = { hovered_layout.bubble }
        for _, m in ipairs(hovered_layout.marks) do holes[#holes + 1] = m end
        if hovered_layout.house then holes[#holes + 1] = hovered_layout.house end
        self:_drawDim(holes)
    end

    -- Populate icon_rects for mousepressed click checking (only when interactive)
    if active_layout == nil and n_available > 0 then
        self.icon_rects[1] = {
            x = ix, y = iy, w = iw, h = ih, spec = visible[order[1]],
        }
    end

    -- 5. Draw the [i] button itself. Skipped entirely on a poster-less
    -- screen with nothing queued: a grey disabled button floating over the
    -- shove felt would be exactly the kind of unexplained UI this exists
    -- to prevent.
    local now = love.timer.getTime()
    local is_disabled = (n_available == 0)
    if not info_visible then
        if active_layout then self:_drawHint(active_layout, true) end
        return
    end

    local fill_color
    if is_disabled then
        fill_color = Theme.bg.sunken
    else
        local warn_color = Theme.status.warn
        -- Gentle background pulse (oscillates between 0.10 and 0.26 alpha)
        local pulse_alpha = 0.18 + 0.08 * math.sin(now * 3.5)
        if is_hovered then
            fill_color = { warn_color[1], warn_color[2], warn_color[3], pulse_alpha + 0.10 }
        else
            fill_color = { warn_color[1], warn_color[2], warn_color[3], pulse_alpha }
        end
    end

    LabelButton.draw{
        x = ix, y = iy, w = iw, h = ih,
        text         = "i",
        fonts        = game.fonts,
        font         = game.fonts.md,
        hovered      = is_hovered,
        disabled     = is_disabled,
        fill_token   = fill_color,
        border_token = is_disabled and Theme.border.soft or Theme.status.warn,
        text_token   = is_disabled and Theme.fg.disabled or Theme.fg.heading,
    }

    -- Pulse effect for new hints
    local is_any_new = false
    for _, id in ipairs(order) do
        local until_t = self._new_until[id]
        if until_t and now < until_t then
            is_any_new = true
            break
        end
    end

    if is_any_new then
        AwardGlow.draw("hint:queue", ix, iy, iw, ih)
        local ring = fl(2 * math.sin(now * 6) + 2)
        Theme.setColor(Theme.status.warn, 0.35 + 0.35 * math.sin(now * 6))
        love.graphics.rectangle("line",
            ix - ring, iy - ring,
            iw + ring * 2, ih + ring * 2, fl(4 * s))
    end

    -- 6. Draw the count badge if more than 1 hint is available
    if n_available > 1 then
        local rad = fl(7 * s)
        local cx  = ix + iw - fl(2 * s)
        local cy  = iy + fl(2 * s)
        -- Separator border
        Theme.setColor(is_hovered and Theme.bg.widget_hover or Theme.bg.sunken)
        love.graphics.circle("fill", cx, cy, rad + fl(1 * s))
        -- Badge background
        Theme.setColor(Theme.status.error)
        love.graphics.circle("fill", cx, cy, rad)
        -- Badge count text
        local txt = tostring(n_available)
        love.graphics.setFont(game.fonts.sm)
        Theme.setColor(Theme.fg.heading)
        local tw = game.fonts.sm:getWidth(txt)
        local th = game.fonts.sm:getHeight()
        love.graphics.print(txt, fl(cx - tw * 0.5), fl(cy - th * 0.5))
    end

    -- 7. Draw the actual active hint or preview bubble on top
    if active_layout then
        self:_drawHint(active_layout, true)
    elseif hovered_layout then
        self:_drawHint(hovered_layout, false)
    end
end

-- Hit-test a click against the hint layer:
--   queued spec — an [i] icon was clicked (host dismisses that hint)
--   "bubble"    — the active sticky hint's bubble was clicked
--   nil         — not ours; the click falls through to normal input
--     (including clicks on the highlighted widget — advance-on-action).
-- Where the [i] button sits on a screen with no House poster: top-right
-- corner, clear of the top bar's right-hand buttons. Same size the poster
-- button is.
function HintView:_defaultInfoRect()
    local s = self.game.ui_scale or 1
    local W = love.graphics.getWidth()
    local d = math.floor(36 * s)
    local m = math.floor(10 * s)
    return { W - d - m, m, d, d }
end

function HintView:mousepressed(x, y)
    for _, ir in ipairs(self.icon_rects) do
        if x >= ir.x and x < ir.x + ir.w
           and y >= ir.y and y < ir.y + ir.h then
            return ir.spec
        end
    end
    local b = self.bubble_rect
    if b and x >= b.x and x < b.x + b.w
         and y >= b.y and y < b.y + b.h then
        return "bubble"
    end
    return nil
end

-- Static export: fresh anchor marks for an arbitrary spec (see
-- freshMarks). Used by views/HintLogPanel.
HintView.freshMarksFor = freshMarks
-- Static export: word-wrap with {icon} measurement. Used by views/StoryView.
HintView.wrapLines = wrapLines

return HintView
