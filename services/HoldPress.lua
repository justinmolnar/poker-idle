-- services/HoldPress.lua
--
-- Hold-to-press: a button that fires only once it has been held down for
-- HoldPress.DURATION. Pressing starts the hold; the button's face fills
-- left to right while the mouse stays down on it (HoldPress.progress), and
-- the moment the fill reaches the right edge the action fires. Letting go,
-- or sliding off the button, drains the fill back and fires nothing. The
-- grind's SHOVE (views/GrindView) and the shove's CONTINUE (states/
-- ShoveState) are held, not clicked: a stray click can't spend the run.
--
-- One hold at a time. main.lua ticks it every frame (HoldPress.update).

local HoldPress = {}

HoldPress.DURATION = 0.6   -- seconds from press to fire
local DRAIN        = 4.0   -- the fill empties at this many fills a second

local _active = nil        -- { id, t, fire, over }
local _drain  = {}         -- [id] = fill left after a let-go

-- Start holding `id`. `fire()` runs when the hold completes; `over(mx, my)`
-- says whether the pointer is still on the button.
function HoldPress.begin(id, fire, over)
    _active = { id = id, t = 0, fire = fire, over = over }
    _drain[id] = nil
end

function HoldPress.active(id)
    return _active ~= nil and (id == nil or _active.id == id)
end

local function letGo()
    if not _active then return end
    _drain[_active.id] = math.min(1, _active.t / HoldPress.DURATION)
    _active = nil
end

HoldPress.cancel = letGo

-- Advance the hold: the mouse must still be down (button 1) and on the
-- button; complete fires it.
function HoldPress.update(dt)
    for id, p in pairs(_drain) do
        p = p - dt * DRAIN
        _drain[id] = (p > 0) and p or nil
    end
    local a = _active
    if not a then return end
    local down = love.mouse and love.mouse.isDown and love.mouse.isDown(1)
    local mx, my = 0, 0
    if love.mouse and love.mouse.getPosition then mx, my = love.mouse.getPosition() end
    if not down or (a.over and not a.over(mx, my)) then return letGo() end
    a.t = a.t + dt
    if a.t >= HoldPress.DURATION then
        _active = nil
        if a.fire then a.fire() end
    end
end

-- How full `id`'s face is, 0..1.
function HoldPress.progress(id)
    if _active and _active.id == id then
        return math.min(1, _active.t / HoldPress.DURATION)
    end
    return _drain[id] or 0
end

-- Draw the fill over a face rect (under its text): left to right, in
-- `color` at `alpha`.
function HoldPress.drawFill(id, x, y, w, h, color, alpha, radius)
    local p = HoldPress.progress(id)
    if p <= 0 then return end
    local Theme = require("views.Theme")
    Theme.setColor(color or Theme.fg.heading, alpha or 0.30)
    love.graphics.rectangle("fill", x, y, math.floor(w * p), h, radius or 0)
end

return HoldPress
