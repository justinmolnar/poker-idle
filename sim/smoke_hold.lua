-- sim/smoke_hold.lua
--
-- Hold-to-press (services/HoldPress): SHOVE on the grind's rail and the
-- shove's CONTINUE fire only once held for HoldPress.DURATION.
--   press     pressing starts a hold and fires nothing
--   full      held to the end, it fires once; the fill climbs 0 -> 1
--   early     let go before the end, nothing fires and the fill drains
--   off       slide off the button, nothing fires
--   grind     the rail's SHOVE goes through the hold (GrindView)
--
-- Standalone: `lua sim/smoke_hold.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local down, mx, my = false, 10, 10
love.mouse = love.mouse or {}
love.mouse.isDown = function() return down end
love.mouse.getPosition = function() return mx, my end

local HoldPress = require("services.HoldPress")
local D = HoldPress.DURATION
local function over(x, y) return x >= 0 and x < 100 and y >= 0 and y < 40 end

-- press + full
local fired = 0
down, mx, my = true, 10, 10
HoldPress.begin("t", function() fired = fired + 1 end, over)
c.eq(fired, 0, "pressing fires nothing")
HoldPress.update(D * 0.5)
local mid = HoldPress.progress("t")
c.ok(mid > 0.4 and mid < 0.6 and fired == 0, ("half a hold is half a fill (%.2f), not fired"):format(mid))
HoldPress.update(D * 0.6)
c.eq(fired, 1, "held to the end, it fires once")
HoldPress.update(D)
c.eq(fired, 1, "and only once")

-- early
fired = 0
HoldPress.begin("t", function() fired = fired + 1 end, over)
HoldPress.update(D * 0.5)
down = false
HoldPress.update(0.01)
c.eq(fired, 0, "let go early, nothing fires")
local left = HoldPress.progress("t")
HoldPress.update(1)
c.ok(left > 0 and HoldPress.progress("t") == 0, "the fill drains back after a let-go")

-- off
fired = 0
down = true
HoldPress.begin("t", function() fired = fired + 1 end, over)
HoldPress.update(D * 0.5)
mx = 500
HoldPress.update(D)
c.eq(fired, 0, "slid off the button, nothing fires")

-- grind: the rail's SHOVE goes through the hold
do
    local GrindView = require("views.GrindView")
    local shoved = 0
    local view = setmetatable({
        rail = { x = 0, y = 0, w = 100, h = 40 },
        chromeHit = function(_, x, y) return over(x, y) and "shove" or nil end,
        _handleSidebarButton = function(_, id) if id == "shove" then shoved = shoved + 1 end end,
    }, { __index = GrindView })
    down, mx, my = true, 10, 10
    view:chromeMousepressed(10, 10)
    c.eq(shoved, 0, "clicking SHOVE does not shove")
    HoldPress.update(D * 1.1)
    c.eq(shoved, 1, "holding SHOVE to the end shoves")
end

if c.report("smoke_hold") > 0 then os.exit(1) end
