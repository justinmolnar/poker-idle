-- states/GrindState.lua
--
-- Grind mode: the room, tables, bankroll grind, catalog UI. The player
-- spends most of their time here.
--
-- For the skeleton, this is a near-empty shell that activates the room
-- palette and renders RoomView. Game logic (table ticks, hand resolution,
-- catalog interactions) goes here.

local Theme    = require("views.Theme")
local RoomView = require("views.RoomView")

local GrindState = {}
GrindState.__index = GrindState

function GrindState:new(game)
    return setmetatable({
        game = game,
        view = RoomView:new(game),
    }, GrindState)
end

function GrindState:enter()
    Theme.setActive("room")
end

function GrindState:exit() end

function GrindState:update(dt)
    self.view:update(dt)
end

function GrindState:draw()
    self.view:draw()
end

function GrindState:keypressed(_) end
function GrindState:mousepressed(_, _, _) end

return GrindState
