-- views/widgets/Dropdown.lua
--
-- Single-select dropdown with a scrollable popup. Stateful — caller
-- holds an instance per dropdown on the modal/screen and forwards
-- mouse / wheel / key events. Mouse + ESC close; Up/Down/Enter
-- keyboard nav while open.
--
-- Header row uses md font; popup items use md too but with tight
-- vertical padding so a long list fits in a reasonable height.
-- Beyond MAX_VISIBLE the popup scrolls (mouse wheel or auto-follow on
-- keyboard nav).
--
-- Engine-agnostic.

local Theme  = require("views.Theme")
local Button = require("views.Button")

local Dropdown = {}
Dropdown.__index = Dropdown

local PAD_X       = 14
local ROW_PAD_Y   = 6   -- top + bottom padding inside an item; item h = font_h + ROW_PAD_Y*2
local DEFAULT_MAX_VISIBLE = 8

-- opts:
--   items          (list of { label = string, value = any })
--   selected_value (optional; will be marked with a • in popup)
--   on_pick        (function(value) — called when user picks)
--   max_visible    (int, default 8) — popup item cap before scroll
function Dropdown:new(opts)
    return setmetatable({
        items          = opts.items or {},
        selected_value = opts.selected_value,
        on_pick        = opts.on_pick,
        max_visible    = opts.max_visible or DEFAULT_MAX_VISIBLE,
        is_open        = false,
        scroll         = 0,                -- top visible item index (0 = first)
        focus          = nil,              -- keyboard focus (1..#items) or nil
        _header_rect   = nil,
        _item_rects    = {},               -- per-frame rects for hit-test
        _popup_rect    = nil,
    }, Dropdown)
end

function Dropdown:setItems(items, selected_value)
    self.items          = items or {}
    self.selected_value = selected_value
    if self.scroll > math.max(0, #self.items - self.max_visible) then
        self.scroll = math.max(0, #self.items - self.max_visible)
    end
    if self.focus and self.focus > #self.items then self.focus = nil end
end

function Dropdown:open()
    self.is_open = true
    -- Auto-focus current selection so keyboard nav starts at the user's
    -- existing pick.
    if not self.focus then
        for i, it in ipairs(self.items) do
            if it.value == self.selected_value then self.focus = i; break end
        end
        self.focus = self.focus or 1
    end
    self:_clampScrollToFocus()
end

function Dropdown:close()
    self.is_open = false
    self.focus   = nil
end

function Dropdown:toggle()
    if self.is_open then self:close() else self:open() end
end

function Dropdown:_clampScrollToFocus()
    if not self.focus then return end
    if self.focus - 1 < self.scroll then
        self.scroll = self.focus - 1
    elseif self.focus > self.scroll + self.max_visible then
        self.scroll = self.focus - self.max_visible
    end
    if self.scroll < 0 then self.scroll = 0 end
end

-- Find rendered label (for the header) of the currently selected value.
function Dropdown:selectedLabel()
    for _, it in ipairs(self.items) do
        if it.value == self.selected_value then return it.label end
    end
    return ""
end

-- ─── Input ─────────────────────────────────────────────────────────────

function Dropdown:consumeKey(key)
    if not self.is_open then return false end
    if key == "escape" then self:close(); return true end
    if key == "up" then
        self.focus = math.max(1, (self.focus or 1) - 1)
        self:_clampScrollToFocus(); return true
    end
    if key == "down" then
        self.focus = math.min(#self.items, (self.focus or 0) + 1)
        self:_clampScrollToFocus(); return true
    end
    if key == "home" then self.focus = 1; self:_clampScrollToFocus(); return true end
    if key == "end"  then self.focus = #self.items; self:_clampScrollToFocus(); return true end
    if key == "pageup"   then
        self.focus = math.max(1, (self.focus or 1) - self.max_visible)
        self:_clampScrollToFocus(); return true
    end
    if key == "pagedown" then
        self.focus = math.min(#self.items, (self.focus or 0) + self.max_visible)
        self:_clampScrollToFocus(); return true
    end
    if key == "return" or key == "kpenter" or key == "space" then
        if self.focus and self.items[self.focus] then
            local it = self.items[self.focus]
            self.selected_value = it.value
            if self.on_pick then self.on_pick(it.value) end
        end
        self:close()
        return true
    end
    return true  -- swallow other keys while open
end

-- Returns:
--   "header"   — header clicked (toggle).
--   "item"     — popup item picked (on_pick fired).
--   "consumed" — click landed inside the popup rect but not on an
--                item (e.g. scroll thumb / padding); popup closed and
--                the click is fully consumed so it doesn't fall
--                through to whatever's underneath.
--   "outside"  — click was outside header AND popup; popup closed if
--                it was open. Caller may still want to swallow this
--                click (a click that closes a popup shouldn't also
--                fire the row beneath it).
function Dropdown:consumeMouse(mx, my, button)
    if button ~= 1 then return "outside" end

    local h = self._header_rect
    if h and mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then
        self:toggle()
        return "header"
    end

    if self.is_open then
        for _, r in ipairs(self._item_rects) do
            if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
                self.selected_value = r.value
                if self.on_pick then self.on_pick(r.value) end
                self:close()
                return "item"
            end
        end
        local p = self._popup_rect
        if p and mx >= p.x and mx < p.x + p.w and my >= p.y and my < p.y + p.h then
            self:close()
            return "consumed"
        end
        self:close()
    end
    return "outside"
end

-- Returns true iff the dropdown's popup is currently open. Hosts can
-- use this to suppress underlying-row clicks for one frame after a
-- click that closes the popup.
function Dropdown:wasOpen() return self.is_open end

function Dropdown:wheelmoved(_, dy)
    if not self.is_open then return end
    if dy > 0 then self.scroll = math.max(0, self.scroll - 1)
    elseif dy < 0 then
        local maxs = math.max(0, #self.items - self.max_visible)
        self.scroll = math.min(maxs, self.scroll + 1)
    end
end

-- ─── Drawing ───────────────────────────────────────────────────────────

-- Closed-state header: label on left, value + arrow on right.
-- Returns the header's hit rect (also stashed for consumeMouse).
function Dropdown:drawHeader(x, y, w, h, label, fonts)
    local mx, my = love.mouse.getPosition()
    local hovered = require("services.HoverService").rest("button",
        "dropdown:" .. tostring(label or "header"),
        mx >= x and mx < x + w and my >= y and my < y + h, 0)
    local border  = self.is_open and Theme.border.strong
                 or (hovered and Theme.border.strong or Theme.border.default)
    Button.draw(x, y, w, h, {
        fill_color   = hovered and Theme.bg.widget_hover or Theme.bg.widget,
        border_color = border,
        hovered      = hovered,
        depth        = 3,
    }, function(fx, fy, fw, fh)
        local md = fonts.md
        local label_y = fy + math.floor((fh - md:getHeight()) * 0.5)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(md)
        love.graphics.print(label, fx + PAD_X, label_y)
        local arrow = self.is_open and " ^" or " v"
        local val_text = (self:selectedLabel() or "") .. arrow
        Theme.setColor(Theme.fg.primary)
        local vw = md:getWidth(val_text)
        love.graphics.print(val_text, fx + fw - PAD_X - vw, label_y)
    end)
    self._header_rect = { x = x, y = y, w = w, h = h }
    return self._header_rect
end

-- Popup list. Caller decides where to anchor (typically directly
-- under the header). Only call when self.is_open. ITEM_H derives from
-- font height + tight padding so a 14-item list still fits.
function Dropdown:drawPopup(x, y, w, fonts)
    self._item_rects = {}
    if not self.is_open or #self.items == 0 then
        self._popup_rect = nil
        return
    end
    local md     = fonts.md
    local item_h = md:getHeight() + ROW_PAD_Y * 2
    local visible = math.min(#self.items, self.max_visible)
    local list_h  = visible * item_h

    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", x, y, w, list_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", x, y, w, list_h, Theme.space.radius)
    self._popup_rect = { x = x, y = y, w = w, h = list_h }

    -- Clip popup contents so partial-row scroll doesn't bleed.
    love.graphics.setScissor(x, y, w, list_h)

    local mx, my = love.mouse.getPosition()
    local first  = self.scroll + 1
    local last   = math.min(#self.items, first + visible - 1)

    for i = first, last do
        local it = self.items[i]
        local iy = y + (i - first) * item_h
        local hov = mx >= x and mx < x + w and my >= iy and my < iy + item_h
        local focused = (i == self.focus)
        if hov or focused then
            Theme.setColor(Theme.bg.widget_hover)
            love.graphics.rectangle("fill", x + 2, iy + 1, w - 4, item_h - 2, Theme.space.radius)
        end
        local is_selected = (it.value == self.selected_value)
        Theme.setColor(is_selected and Theme.fg.heading or Theme.fg.primary)
        love.graphics.setFont(md)
        local ly  = iy + math.floor((item_h - md:getHeight()) * 0.5)
        local txt = is_selected and (it.label .. "  •") or it.label
        love.graphics.print(txt, x + PAD_X, ly)
        self._item_rects[#self._item_rects + 1] = {
            x = x, y = iy, w = w, h = item_h, value = it.value,
        }
    end

    love.graphics.setScissor()

    -- Scroll indicator. Drawn after scissor restore so it sits on the
    -- popup edge without being clipped.
    if #self.items > visible then
        local track_x = x + w - 4
        local track_y = y + 4
        local track_h = list_h - 8
        Theme.setColor(Theme.bg.sunken, 0.6)
        love.graphics.rectangle("fill", track_x, track_y, 2, track_h)
        local thumb_h = math.max(8, track_h * (visible / #self.items))
        local thumb_y = track_y
            + (track_h - thumb_h) * (self.scroll / math.max(1, #self.items - visible))
        Theme.setColor(Theme.border.strong)
        love.graphics.rectangle("fill", track_x, thumb_y, 2, thumb_h)
    end
end

return Dropdown
