-- views/Panel.lua
-- Tab-routed panel container. Knows nothing about game content.
-- Each tab provides a build(game) → component list function.
-- Panel calls ComponentRenderer to draw and handles scroll/scrollbar.
--
-- Lifted from cosmic courier. Removed `views.DataGrid` overlay-close calls
-- in setActiveTab (DataGrid not lifted). require paths repointed: CC's
-- `data.theme` → poker-idle's `views.Theme` (the dispatch layer that
-- re-points per palette via setActive).

local CR        = require("views.ComponentRenderer")
local Scrollbar = require("views.Scrollbar")
local Theme     = require("views.Theme")

local Panel = {}
Panel.__index = Panel

Panel.TAB_BAR_H = 32

local function _trackX(self) return self.x + self.w - Scrollbar.margin() end

function Panel:new(x, y, w, h)
    local instance = setmetatable({}, Panel)
    instance.x = x
    instance.y = y
    instance.w = w
    instance.h = h
    instance.content_y = y + Panel.TAB_BAR_H
    instance.content_h = h - Panel.TAB_BAR_H

    instance.tabs      = {}
    instance.tab_order = {}

    instance.active_tab_id = nil

    instance.scroll = {}

    instance._last_components = nil

    return instance
end

function Panel:registerTab(def)
    self.tabs[def.id] = def
    table.insert(self.tab_order, def)
    table.sort(self.tab_order, function(a, b)
        return (a.priority or 0) < (b.priority or 0)
    end)
    self.scroll[def.id] = {
        scroll_y       = 0,
        total_h        = 0,
        is_dragging    = false,
        drag_start_y   = 0,
        scroll_at_drag = 0,
    }
end

function Panel:_isTabVisible(tab, game)
    return tab ~= nil and (tab.visible_when == nil or tab.visible_when(game) == true)
end

function Panel:_resolveActiveTab(game)
    local current = self.tabs[self.active_tab_id]
    if self:_isTabVisible(current, game) then return current end
    for _, tab in ipairs(self.tab_order) do
        if self:_isTabVisible(tab, game) then
            self.active_tab_id = tab.id
            return tab
        end
    end
    return nil
end

function Panel:setActiveTab(id)
    if self.tabs[id] then
        self.active_tab_id = id
    end
end

function Panel:getActiveTab()
    return self.tabs[self.active_tab_id]
end

function Panel:getComponents()
    return self._last_components
end

function Panel:handleScroll(dy)
    local s = self.scroll[self.active_tab_id]
    if not s then return end
    s.scroll_y = Scrollbar.clamp(s.scroll_y - dy * Scrollbar.WHEEL_NOTCH_PX,
                                 self.content_h, s.total_h)
end

function Panel:handleMouseDown(x, y, _button, game)
    if y >= self.y and y < self.y + Panel.TAB_BAR_H then
        local visible = self:_visibleTabs(game)
        local n = #visible
        if n == 0 then return false end
        local tab_w = self.w / n
        for i, tab in ipairs(visible) do
            local tx = self.x + (i - 1) * tab_w
            if x >= tx and x < tx + tab_w then
                local prev = self.active_tab_id
                self:setActiveTab(tab.id)
                if tab.id ~= prev then
                    local s = self.scroll[tab.id]
                    if s then s.scroll_y = 0 end
                end
                return true
            end
        end
    end

    if self:isInContentArea(x, y) then
        local s = self.scroll[self.active_tab_id]
        if s and s.total_h > self.content_h then
            local tx, ty, th = _trackX(self), self.content_y, self.content_h
            if Scrollbar.containsThumb(tx, ty, th, s.scroll_y, s.total_h, x, y) then
                s.is_dragging    = true
                s.drag_start_y   = y
                s.scroll_at_drag = s.scroll_y
                return true
            end
            if Scrollbar.containsPoint(tx, ty, th, x, y) then
                s.scroll_y = Scrollbar.scrollFromTrackClick(ty, th, y, s.total_h)
                return true
            end
        end
    end

    return false
end

function Panel:handleMouseUp()
    for _, s in pairs(self.scroll) do
        s.is_dragging = false
    end
end

function Panel:update(my)
    local s = self.scroll[self.active_tab_id]
    if not s or not s.is_dragging then return end
    s.scroll_y = Scrollbar.scrollFromDrag(self.content_h,
                                          my - s.drag_start_y,
                                          s.scroll_at_drag,
                                          s.total_h)
end

function Panel:updateHover(mx, my, game)
    local HoverService = require("services.HoverService")
    if my >= self.y and my < self.y + Panel.TAB_BAR_H then
        local visible = self:_visibleTabs(game)
        local n = #visible
        if n > 0 then
            local tab_w = self.w / n
            for i, tab in ipairs(visible) do
                local tx = self.x + (i - 1) * tab_w
                if mx >= tx and mx < tx + tab_w then
                    HoverService.set("tab", tab.id)
                    break
                end
            end
        end
    end
    local s = self.scroll[self.active_tab_id]
    if s and s.total_h > self.content_h then
        local tx = self.x + self.w - Scrollbar.margin()
        if Scrollbar.containsThumb(tx, self.content_y, self.content_h,
                                   s.scroll_y, s.total_h, mx, my) then
            HoverService.set("scrollbar_thumb", "panel")
        end
    end
end

function Panel:toContentY(screen_y)
    local s = self.scroll[self.active_tab_id]
    return screen_y - self.content_y + (s and s.scroll_y or 0)
end

function Panel:isInContentArea(screen_x, screen_y)
    return screen_x >= self.x and screen_x < self.x + self.w
       and screen_y >= self.content_y and screen_y < self.content_y + self.content_h
end

function Panel:_visibleTabs(game)
    local out = {}
    for _, tab in ipairs(self.tab_order) do
        if self:_isTabVisible(tab, game) then out[#out+1] = tab end
    end
    return out
end

function Panel:draw(game)
    local visible = self:_visibleTabs(game)
    local n       = #visible
    local tab_w   = n > 0 and (self.w / n) or self.w

    local active_tab = self:_resolveActiveTab(game)

    local HoverService = require("services.HoverService")
    love.graphics.setFont(game.fonts.ui)
    love.graphics.setScissor(self.x, self.y, self.w, Panel.TAB_BAR_H)
    for i, tab in ipairs(visible) do
        local tx = self.x + (i - 1) * tab_w
        local is_active = (tab.id == self.active_tab_id)
        local hovered   = (not is_active) and HoverService.is("tab", tab.id)
        local bg = (is_active or hovered) and Theme.bg.widget_hover or Theme.bg.chrome
        Theme.setColor(bg)
        love.graphics.rectangle("fill", tx, self.y, tab_w, Panel.TAB_BAR_H)
        Theme.setColor(is_active and Theme.border.strong or Theme.border.default)
        love.graphics.rectangle("line", tx, self.y, tab_w, Panel.TAB_BAR_H)
        Theme.setColor(is_active and Theme.fg.heading
                       or hovered and Theme.fg.primary
                       or Theme.fg.muted)
        local label = tab.icon and (tab.icon .. " " .. tab.label) or tab.label
        love.graphics.printf(label, tx + 2, self.y + 9, tab_w - 4, "center")
    end
    love.graphics.setScissor()

    if not active_tab or not active_tab.build then return end

    local s = self.scroll[self.active_tab_id]

    love.graphics.setScissor(self.x, self.content_y, self.w, self.content_h)
    love.graphics.push()
    love.graphics.translate(0, self.content_y - (s and s.scroll_y or 0))

    local comps = active_tab.build(game)
    self._last_components = comps

    local scroll_view = s and {
        scroll_y   = s.scroll_y or 0,
        viewport_h = self.content_h,
        content_y  = self.content_y,
    } or nil

    local total_h = CR.draw(comps, self.x, self.w, game, scroll_view)

    if s then
        s.total_h = total_h
        local max_scroll = math.max(0, total_h - self.content_h)
        if s.scroll_y > max_scroll then s.scroll_y = max_scroll end
    end

    love.graphics.pop()
    love.graphics.setScissor()

    if s then
        local hovered = HoverService.is("scrollbar_thumb", "panel")
        Scrollbar.draw(_trackX(self), self.content_y, self.content_h,
                       s.scroll_y, s.total_h, hovered)
    end
end

return Panel
