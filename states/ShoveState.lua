-- states/ShoveState.lua
--
-- Shove mode: the all-in gauntlet. Three runouts, cheating dealer, cinematic
-- card reveal. The MVP plan calls for this to be prototyped first as a
-- standalone screen — the skeleton sets up the state and the palette swap;
-- all the real cinematic work lives in ShoveView and (eventually) a
-- gauntlet-orchestrating service.

local Theme     = require("views.Theme")
local ShoveView = require("views.ShoveView")

local ShoveState = {}
ShoveState.__index = ShoveState

function ShoveState:new(game)
    return setmetatable({
        game = game,
        view = ShoveView:new(game),
    }, ShoveState)
end

function ShoveState:enter()
    Theme.setActive("shove")
end

function ShoveState:exit() end

function ShoveState:update(dt)
    self.view:update(dt)
end

function ShoveState:draw()
    self.view:draw()
end

function ShoveState:keypressed(_) end
function ShoveState:mousepressed(_, _, _) end

return ShoveState
