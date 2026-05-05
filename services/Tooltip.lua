-- services/Tooltip.lua
--
-- Deferred hover-tooltip rendering. Stateless module. Only one tooltip can
-- be visible at a time — the most recent Tooltip.set wins. Cleared each
-- frame from love.update; populated by hit-test passes during update; drawn
-- once per frame near the top of the render order (above gameplay layers,
-- below any debug overlays).
--
-- Filled bg rect, strong border, light text. Auto-sizes to content. Keeps
-- inside the screen via edge-clamping near the mouse cursor.

local Theme = require("views.Theme")

local Tooltip = {}

-- Module-private: the current tooltip (lines + anchor) or nil.
local _t       = nil
local _padding = 6
local _line_h  = 14   -- font row height; matches ui_small in Theme.font

-- Stash a tooltip for this frame. Caller passes either a string (single
-- line) or a list of strings. mx/my anchor near the mouse cursor.
function Tooltip.set(text_or_lines, mx, my)
    if not text_or_lines then return end
    local lines
    if type(text_or_lines) == "table" then
        if #text_or_lines == 0 then return end
        lines = text_or_lines
    else
        lines = { text_or_lines }
    end
    _t = { lines = lines, mx = mx or 0, my = my or 0 }
end

function Tooltip.clear()
    _t = nil
end

function Tooltip.draw(font)
    if not _t then return end
    if font then love.graphics.setFont(font) else
        font = love.graphics.getFont()
    end
    if not font then return end

    -- Line height = the font's actual line height (auto-tracks any
    -- ui_scale that rebuilt the font at a bigger size). The hardcoded
    -- 14 px assumed sm at scale 1.
    local line_h = font:getHeight() + 2

    -- Measure content.
    local max_w = 0
    for _, line in ipairs(_t.lines) do
        local w = font:getWidth(line)
        if w > max_w then max_w = w end
    end
    local box_w = max_w + _padding * 2
    local box_h = _padding * 2 + line_h * #_t.lines

    -- Anchor near cursor; flip to the left if the right edge would clip,
    -- and clamp to screen bounds.
    local screen_w, screen_h = love.graphics.getDimensions()
    local x = _t.mx + 14
    local y = _t.my + 14
    if x + box_w > screen_w then x = _t.mx - box_w - 8 end
    if x < 4 then x = 4 end
    if y + box_h > screen_h then y = screen_h - box_h - 4 end
    if y < 4 then y = 4 end

    Theme.setColor(Theme.bg.window, 0.95)
    love.graphics.rectangle("fill", x, y, box_w, box_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", x, y, box_w, box_h, Theme.space.radius)

    Theme.setColor(Theme.fg.heading)
    for i, line in ipairs(_t.lines) do
        love.graphics.print(line, x + _padding, y + _padding + (i - 1) * line_h)
    end
end

return Tooltip
