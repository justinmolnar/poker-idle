-- views/widgets/Slider.lua
--
-- Horizontal click-and-drag slider. Click anywhere on the track jumps
-- the knob to that position; pressing on the knob and dragging tracks
-- the cursor continuously. Returns a 0..1 float.
--
-- Engine-agnostic. Caller owns the rect (passes x/y/w/h to :draw and
-- forwards mouse events). Single shared module-locals for sizing scale
-- with ui_scale via Slider.setScale(s) — main.lua wires this on boot
-- and on resize alongside Chips / ComponentRenderer / ConfirmDialog.

local Theme = require("views.Theme")

local Slider = {}
Slider.__index = Slider

local TRACK_H_BASE = 8
local KNOB_R_BASE  = 9
local TRACK_H = TRACK_H_BASE
local KNOB_R  = KNOB_R_BASE

function Slider.setScale(s)
    s = s or 1
    TRACK_H = math.max(2, math.floor(TRACK_H_BASE * s))
    KNOB_R  = math.max(4, math.floor(KNOB_R_BASE  * s))
end

-- opts:
--   value      (number 0..1, default 0)
--   on_change  (function(v) — fired whenever value changes
function Slider:new(opts)
    opts = opts or {}
    return setmetatable({
        value      = math.max(0, math.min(1, opts.value or 0)),
        on_change  = opts.on_change,
        _dragging  = false,
        _rect      = nil,    -- last-drawn rect for hit-testing
    }, Slider)
end

function Slider:setValue(v)
    v = math.max(0, math.min(1, v or 0))
    if v ~= self.value then
        self.value = v
        if self.on_change then self.on_change(v) end
    end
end

local function valueFromMouse(rect, mx)
    local t = (mx - rect.x) / rect.w
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end
    return t
end

function Slider:draw(x, y, w, h)
    -- Track is centered vertically inside the (x, y, w, h) row.
    local track_y = y + math.floor((h - TRACK_H) / 2)
    self._rect = { x = x, y = track_y, w = w, h = TRACK_H }

    -- Track background.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", x, track_y, w, TRACK_H, math.floor(TRACK_H / 2))

    -- Filled portion (left of knob).
    local fill_w = math.floor(w * self.value)
    if fill_w > 0 then
        Theme.setColor(Theme.fg.heading)
        love.graphics.rectangle("fill", x, track_y, fill_w, TRACK_H, math.floor(TRACK_H / 2))
    end

    -- Knob.
    local knob_x = x + fill_w
    local knob_y = track_y + math.floor(TRACK_H / 2)
    Theme.setColor(Theme.fg.heading)
    love.graphics.circle("fill", knob_x, knob_y, KNOB_R)
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", knob_x, knob_y, KNOB_R)
    love.graphics.setLineWidth(1)
end

-- Returns true if the press landed on the slider (track or knob).
function Slider:mousepressed(mx, my, button)
    if button ~= 1 or not self._rect then return false end
    local r = self._rect
    -- Hit-test the track band, expanded by knob radius vertically so
    -- pressing right on the knob always counts even if the cursor is
    -- a few pixels above/below the track.
    local hit_top    = r.y - KNOB_R
    local hit_bottom = r.y + r.h + KNOB_R
    if mx < r.x or mx > r.x + r.w then return false end
    if my < hit_top or my > hit_bottom then return false end

    self._dragging = true
    self:setValue(valueFromMouse(r, mx))
    return true
end

function Slider:mousemoved(mx, my)
    if not self._dragging or not self._rect then return end
    self:setValue(valueFromMouse(self._rect, mx))
end

function Slider:mousereleased(mx, my, button)
    if button ~= 1 then return end
    self._dragging = false
end

return Slider
