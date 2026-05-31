-- views/widgets/ActionModal.lua
--
-- A modal with content + a centered row of action buttons. Captures the
-- forced-acknowledge boilerplate every "read this, click to continue" overlay
-- repeats: a resolved value, a key->value map, button-row layout with hover +
-- hit-test, and the Modal frame.
--
-- The modal sizes itself to its content (auto-height, capped by the Modal's
-- max_h_frac) — the body is run once to MEASURE, then once to DRAW, via a
-- small layout context. Engine-agnostic: the body's only game-specific drawing
-- goes through Layout:custom, so this widget knows nothing about the game.

local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")
local Scrollbar   = require("views.Scrollbar")

local ActionModal = {}
ActionModal.__index = ActionModal

local BTN_W_BASE     = 200
local BTN_H_BASE     = 44
local BTN_GAP_BASE   = 18
local BTN_BOTTOM_PAD = 12

-- ── Layout context ──────────────────────────────────────────────────
-- In the measure pass (draw=false) the helpers only advance the y cursor; in
-- the draw pass they render. Generic primitives only — glyph rows are drawn by
-- the caller through :custom, keeping this widget poker-agnostic.
local Layout = {}
Layout.__index = Layout

local function newLayout(game, draw)
    return setmetatable({
        game = game, draw = draw, s = game.ui_scale or 1,
        x = 0, y = 0, w = 0,
    }, Layout)
end

function Layout:origin(x, y, w) self.x, self.y, self.w = x, y, w end

function Layout:gap(px) self.y = self.y + math.floor(px * self.s) end

-- Wrapped paragraph. `style` indexes game.fonts; `color` is a Theme token.
function Layout:para(text, style, color, align)
    local font = self.game.fonts[style] or self.game.fonts.sm
    local _, lines = font:getWrap(text, self.w)
    if self.draw then
        love.graphics.setFont(font)
        Theme.setColor(color)
        love.graphics.printf(text, self.x, self.y, self.w, align or "left")
    end
    self.y = self.y + math.max(1, #lines) * font:getHeight()
end

-- Arbitrary content of fixed height `h`: the draw pass calls fn(x, y, w).
function Layout:custom(h, fn)
    if self.draw and fn then fn(self.x, self.y, self.w) end
    self.y = self.y + h
end

-- opts:
--   game, title, w (base design width, x ui_scale)
--   buttons = { { text=, value=, primary=bool }, ... }
--   keys    = { [keyname] = value, ... }
--   body    = function(layout, fonts, s) end   (uses layout:para/gap/custom)
function ActionModal:new(opts)
    local s = (opts.game.ui_scale) or 1
    return setmetatable({
        game         = opts.game,
        buttons      = opts.buttons or {},
        keys         = opts.keys or {},
        body_fn      = opts.body,
        button_align = opts.button_align or "center",
        note         = opts.note,
        _resolved = nil,
        _rects    = {},
        _scroll_y = 0,
        _drag     = false,
        _modal    = Modal:new{
            title       = opts.title,
            title_align = opts.title_align,
            aside       = opts.aside,
            w           = opts.w and math.floor(opts.w * s) or 480,
        },
    }, ActionModal)
end

function ActionModal:resolved() return self._resolved end

function ActionModal:consumeKey(key)
    if self._resolved == nil then
        local v = self.keys[key]
        if v ~= nil then self._resolved = v end
    end
    return self._resolved ~= nil
end

function ActionModal:consumeMouse(mx, my, button)
    if button == 1 and self._resolved == nil then
        -- Scrollbar takes the click before any button (thumb -> drag, track ->
        -- jump) so a press on the bar never resolves the modal.
        local t = self._track
        if t then
            if Scrollbar.containsThumb(t.x, t.y, t.h, self._scroll_y,
                                       t.content_h, mx, my) then
                self._drag           = true
                self._drag_my0       = my
                self._scroll_at_drag = self._scroll_y
                return true
            elseif Scrollbar.containsPoint(t.x, t.y, t.h, mx, my) then
                self._scroll_y = Scrollbar.scrollFromTrackClick(
                    t.y, t.h, my, t.content_h)
                return true
            end
        end
        for _, r in ipairs(self._rects) do
            if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
                self._resolved = r.value
                break
            end
        end
    end
    return true
end

-- Scroll input. No-ops unless the last draw left a scrollable track.
function ActionModal:wheelmoved(_, dy)
    local t = self._track
    if not t then return false end
    self._scroll_y = Scrollbar.clamp(
        self._scroll_y - dy * Scrollbar.WHEEL_NOTCH_PX, t.h, t.content_h)
    return true
end

function ActionModal:mousemoved(mx, my)
    local t = self._track
    if self._drag and t then
        self._scroll_y = Scrollbar.scrollFromDrag(
            t.h, my - self._drag_my0, self._scroll_at_drag, t.content_h)
    end
end

function ActionModal:mousereleased()
    self._drag = false
end

-- Run the body in the measure pass at width `w`; returns the content height.
function ActionModal:_measure(fonts, s, w)
    local mui = newLayout(self.game, false)
    mui:origin(0, 0, w)
    if self.body_fn then self.body_fn(mui, fonts, s) end
    return mui.y
end

function ActionModal:draw()
    local fonts  = self.game.fonts
    local s      = (self.game.ui_scale) or 1
    local full_w = self._modal.w - self._modal.pad * 2

    -- Button-row metrics. Buttons size to the widest label so text can't wrap.
    local btn_h = math.floor(BTN_H_BASE * s)
    local gap   = math.floor(BTN_GAP_BASE * s)
    local btn_w = math.floor(BTN_W_BASE * s)
    for _, spec in ipairs(self.buttons) do
        btn_w = math.max(btn_w, fonts.md:getWidth(spec.text) + math.floor(40 * s))
    end
    local btn_area = math.floor(24 * s) + btn_h + math.floor(BTN_BOTTOM_PAD * s)

    -- Measure the body, then size the frame to fit content + buttons (the Modal
    -- caps the height at its max_h_frac).
    local content_h = self:_measure(fonts, s, full_w)
    local body      = self._modal:draw(fonts, content_h + btn_area)

    -- Content region above the pinned button row. When the copy is taller than
    -- the (capped) region we re-measure for the narrower scrollbar gutter,
    -- clip, and offset by the scroll position.
    local view_h     = body.h - btn_area
    local scrollable = content_h > view_h + 1
    local content_w  = full_w
    local dui        = newLayout(self.game, true)
    if scrollable then
        content_w = body.w - (Scrollbar.width() + Scrollbar.margin())
        content_h = self:_measure(fonts, s, content_w)
        self._scroll_y = Scrollbar.clamp(self._scroll_y, view_h, content_h)

        love.graphics.setScissor(body.x, body.y, body.w, view_h)
        love.graphics.push()
        love.graphics.translate(0, -self._scroll_y)
        dui:origin(body.x, body.y, content_w)
        if self.body_fn then self.body_fn(dui, fonts, s) end
        love.graphics.pop()
        love.graphics.setScissor()

        local track_x = body.x + body.w - Scrollbar.width()
        local mx, my  = love.mouse.getPosition()
        local hov     = self._drag
                     or Scrollbar.containsPoint(track_x, body.y, view_h, mx, my)
        Scrollbar.draw(track_x, body.y, view_h, self._scroll_y, content_h, hov)
        self._track = { x = track_x, y = body.y, h = view_h, content_h = content_h }
    else
        self._scroll_y = 0
        dui:origin(body.x, body.y, content_w)
        if self.body_fn then self.body_fn(dui, fonts, s) end
        self._track = nil
    end

    -- Button row at the bottom of the body. With a note it's a two-column row
    -- distributed space-around (note + button group each sit a calculated
    -- distance off their edge); otherwise centered (or right via button_align).
    local n        = #self.buttons
    local total    = n * btn_w + math.max(0, n - 1) * gap
    local by       = body.y + body.h - btn_h - math.floor(BTN_BOTTOM_PAD * s)
    local has_note = self.note and self.note ~= ""
    local note_w, note_lines = 0, nil
    if has_note then note_w, note_lines = fonts.sm:getWrap(self.note, body.w) end

    local bx, note_x
    if has_note then
        local free = body.w - note_w - total
        local edge = math.max(0, math.floor(free / 4))
        local mid  = free - edge * 2
        note_x = body.x + edge
        bx     = body.x + edge + note_w + mid
    elseif self.button_align == "right" then
        bx = body.x + body.w - total
    else
        bx = body.x + math.floor((body.w - total) / 2)
    end

    if has_note then
        local note_h = #note_lines * fonts.sm:getHeight()
        local ny     = by + math.max(0, math.floor((btn_h - note_h) / 2))
        Theme.setColor(Theme.fg.muted)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf(self.note, note_x, ny, note_w, "left")
    end

    local mx, my = love.mouse.getPosition()
    self._rects = {}
    for i, spec in ipairs(self.buttons) do
        local x   = bx + (i - 1) * (btn_w + gap)
        local hov = mx >= x and mx < x + btn_w and my >= by and my < by + btn_h
        self._rects[i] = { value = spec.value, x = x, y = by, w = btn_w, h = btn_h }

        local draw_opts = {
            x = x, y = by, w = btn_w, h = btn_h,
            text = spec.text, fonts = fonts, font = fonts.md,
            hovered = hov, depth = 3,
        }
        if spec.primary then
            draw_opts.fill_token   = hov and Theme.status.good or Theme.bg.widget
            draw_opts.border_token = Theme.status.good
            draw_opts.text_token   = hov and Theme.bg.window or Theme.status.good
        end
        LabelButton.draw(draw_opts)
    end

    self._modal:endDraw()
end

return ActionModal
