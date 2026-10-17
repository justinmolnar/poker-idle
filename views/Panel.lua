-- views/Panel.lua
-- Tab-routed panel container. Knows nothing about game content.
-- Each tab provides a build(game) → component list function.
-- Panel calls ComponentRenderer to draw and handles scroll/scrollbar.
--
-- The tree a tab builds is RETAINED across frames. A tab may declare:
--   inputs(game, arr) → n   fills the reused array arr[1..n] with the
--                           scalars its build depends on (numbers, booleans,
--                           strings that already exist); the panel compares
--                           them to last frame's and rebuilds only when one
--                           moved, on a tab change, or on the first frame.
--                           A tab without `inputs` rebuilds every frame.
--   refresh(game, comps)    mutates the live fields of the retained tree in
--                           place each frame (a stat's value, a bar's frac):
--                           what changes without changing the tree's shape.
-- The steady path allocates nothing: the two input arrays swap, the
-- visible-tab list is cached on a bitmask, and the scroll view is reused.
-- `build_count` counts the builds (the checks read it).
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

-- Initial value; overwritten in Panel.configureFromFonts (called from
-- main.lua right after FontService builds the canonical fonts table).
-- Derived from md:getHeight() + vertical padding so the tab label has
-- breathing room above and below.
Panel.TAB_BAR_H = 44

-- Reconfigure layout constants from the active fonts. Called once at
-- boot and again on resize via main.lua. Keeps Panel engine-agnostic
-- (it doesn't reach into Theme directly; caller passes fonts in).
function Panel.configureFromFonts(fonts)
    if not (fonts and fonts.md) then return end
    Panel.TAB_BAR_H = fonts.md:getHeight() + 24
end

local function _trackX(self) return self.x + self.w - Scrollbar.margin() end

function Panel:new(x, y, w, h)
    local instance = setmetatable({}, Panel)
    instance.x = x
    instance.y = y
    instance.w = w
    instance.h = h
    -- content_y / content_h are recomputed each frame via
    -- :_layout(game) so panels with only one visible tab can hide
    -- the tab bar entirely (no wasted vertical strip).
    instance.content_y = y + Panel.TAB_BAR_H
    instance.content_h = h - Panel.TAB_BAR_H

    instance.tabs      = {}
    instance.tab_order = {}

    instance.active_tab_id = nil

    instance.scroll = {}

    instance._last_components = nil
    -- The retained tree's inputs: last frame's and this frame's, swapped
    -- on a rebuild so neither is ever reallocated.
    instance._in_prev, instance._in_cur, instance._in_n = {}, {}, -1
    instance._built_tab = nil
    instance.build_count = 0
    return instance
end

-- Forget the retained tree: the next draw rebuilds whatever tab is up.
function Panel:invalidate()
    self._built_tab = nil
end

-- Effective tab-bar height for the current game state. Returns 0 when
-- only one tab is visible — the bar is decorative noise in that case
-- since there's nothing to switch to.
function Panel:_effTabBarH(game)
    local visible = self:_visibleTabs(game)
    if #visible <= 1 then return 0 end
    return Panel.TAB_BAR_H
end

-- Recompute content rect against the current tab-bar height. Cheap;
-- run at the top of any method that uses content_y / content_h.
function Panel:_layout(game)
    local h_bar = self:_effTabBarH(game)
    self.content_y = self.y + h_bar
    self.content_h = self.h - h_bar
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
    self._vis_mask = nil   -- the visible-tab list is stale
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
    self:_layout(game)
    local h_bar = self:_effTabBarH(game)
    if h_bar > 0 and y >= self.y and y < self.y + h_bar then
        local visible = self:_visibleTabs(game)
        local n = #visible
        if n == 0 then return false end
        local tab_w = self.w / n
        for i, tab in ipairs(visible) do
            local tx = self.x + (i - 1) * tab_w
            if x >= tx and x < tx + tab_w then
                local prev = self.active_tab_id
                require("services.ClickFlash").click()
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
    self:_layout(game)
    local HoverService = require("services.HoverService")
    local h_bar = self:_effTabBarH(game)
    if h_bar > 0 and my >= self.y and my < self.y + h_bar then
        local visible = self:_visibleTabs(game)
        local n = #visible
        if n > 0 then
            local tab_w = self.w / n
            for i, tab in ipairs(visible) do
                local tx = self.x + (i - 1) * tab_w
                if mx >= tx and mx < tx + tab_w then
                    HoverService.set("tab", tab.id)
            require("services.CursorIntent").mark("point")
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

-- The visible tabs, as one cached list. Every caller (the layout, the
-- tab bar, the hover and click routing) asked for this several times a
-- frame and each answer was a fresh table; the visibility is folded into
-- a bitmask over tab_order and the list is rebuilt only when that moves.
function Panel:_visibleTabs(game)
    local order = self.tab_order
    local mask, bit = 0, 1
    for i = 1, #order do
        if self:_isTabVisible(order[i], game) then mask = mask + bit end
        bit = bit * 2
    end
    local list = self._vis_list
    if not list or mask ~= self._vis_mask then
        list = list or {}
        for i = #list, 1, -1 do list[i] = nil end
        for i = 1, #order do
            if self:_isTabVisible(order[i], game) then list[#list + 1] = order[i] end
        end
        self._vis_list, self._vis_mask = list, mask
    end
    return list
end

-- The active tab's tree: the retained one, or a fresh build when the
-- tab's inputs moved (element by element and by count), the tab changed,
-- or nothing has been built yet. On a rebuild the input arrays swap, so
-- this frame's readings become the ones the next frame compares against.
function Panel:_components(game, tab)
    local comps = self._last_components
    local need  = (comps == nil) or (tab ~= self._built_tab)
    if tab.inputs then
        local cur = self._in_cur
        local n   = tab.inputs(game, cur) or 0
        if not need then
            local prev = self._in_prev
            if n ~= self._in_n then
                need = true
            else
                for i = 1, n do
                    if cur[i] ~= prev[i] then need = true; break end
                end
            end
        end
        if need then
            self._in_prev, self._in_cur, self._in_n = cur, self._in_prev, n
        end
    else
        need = true
    end
    if need then
        comps = tab.build(game)
        self._last_components = comps
        self._built_tab  = tab
        self.build_count = self.build_count + 1
    end
    return comps
end

function Panel:draw(game)
    self:_layout(game)
    local visible = self:_visibleTabs(game)
    local n       = #visible
    local tab_w   = n > 0 and (self.w / n) or self.w
    local h_bar   = self:_effTabBarH(game)

    local active_tab   = self:_resolveActiveTab(game)
    local HoverService = require("services.HoverService")

    -- Tab bar only renders when there's more than one tab. Single-tab
    -- panels skip the strip entirely so content fills the full panel.
    if h_bar > 0 then
        love.graphics.setFont(game.fonts.md)
        love.graphics.setScissor(self.x, self.y, self.w, h_bar)
        for i, tab in ipairs(visible) do
            local tx = self.x + (i - 1) * tab_w
            local is_active = (tab.id == self.active_tab_id)
            local hovered   = (not is_active) and HoverService.is("tab", tab.id)
            local bg = (is_active or hovered) and Theme.bg.widget_hover or Theme.bg.chrome
            Theme.setColor(bg)
            love.graphics.rectangle("fill", tx, self.y, tab_w, h_bar)
            Theme.setColor(is_active and Theme.border.strong or Theme.border.default)
            love.graphics.rectangle("line", tx, self.y, tab_w, h_bar)
            Theme.setColor(is_active and Theme.fg.heading
                           or hovered and Theme.fg.primary
                           or Theme.fg.muted)
            local label = tab.icon and (tab.icon .. " " .. tab.label) or tab.label
            local label_y = self.y + math.floor((h_bar - game.fonts.md:getHeight()) * 0.5)
            love.graphics.printf(label, tx + 2, label_y, tab_w - 4, "center")
        end
        love.graphics.setScissor()
    end

    if not active_tab or not active_tab.build then return end

    local s = self.scroll[self.active_tab_id]
    -- scissor_pad_top: pixels the content may draw ABOVE the panel (the
    -- rail's quick-reset overlay straddles the SHOVE button's top edge).
    local pad_top = self.scissor_pad_top or 0
    love.graphics.setScissor(self.x, self.content_y - pad_top, self.w, self.content_h + pad_top)
    love.graphics.push()
    love.graphics.translate(0, self.content_y - (s and s.scroll_y or 0))
    local comps = self:_components(game, active_tab)
    if active_tab.refresh then active_tab.refresh(game, comps) end

    local scroll_view
    if s then
        scroll_view = self._scroll_view
        if not scroll_view then scroll_view = {}; self._scroll_view = scroll_view end
        scroll_view.scroll_y   = s.scroll_y or 0
        scroll_view.viewport_h = self.content_h
        scroll_view.content_y  = self.content_y
    end

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
