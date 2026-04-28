-- controllers/StateMachine.lua
--
-- Single-state machine. Lifted from 10000-games verbatim. Names map to
-- registered state objects; state objects implement any subset of the LÖVE
-- callbacks (enter, update, draw, keypressed, mousepressed, etc.) and the
-- machine forwards events to the current state if the method exists.
--
-- States transition by calling `state_machine:switch("name", ...)` from
-- inside their own callbacks (the state stores a reference to the machine).
-- No pushdown stack — this is a flat finite-state machine.

local Object = require("lib.class")
local StateMachine = Object:extend("StateMachine")

function StateMachine:init(di)
    self.states = {}
    self.current_state = nil
    self.current_name = nil
    self.di = di
end

function StateMachine:register(state_name, state_object)
    self.states[state_name] = state_object
end

function StateMachine:switch(state_name, ...)
    if not self.states[state_name] then return end
    if self.current_state and self.current_state.exit then
        self.current_state:exit()
    end
    self.current_state = self.states[state_name]
    self.current_name  = state_name
    if self.current_state.enter then
        self.current_state:enter(...)
    end
end

function StateMachine:current() return self.current_name end

function StateMachine:update(dt)
    if self.current_state and self.current_state.update then
        self.current_state:update(dt)
    end
end

function StateMachine:draw()
    if self.current_state and self.current_state.draw then
        self.current_state:draw()
    end
end

function StateMachine:keypressed(key)
    if self.current_state and self.current_state.keypressed then
        self.current_state:keypressed(key)
    end
end

function StateMachine:keyreleased(key)
    if self.current_state and self.current_state.keyreleased then
        self.current_state:keyreleased(key)
    end
end

function StateMachine:mousepressed(x, y, button)
    if self.current_state and self.current_state.mousepressed then
        self.current_state:mousepressed(x, y, button)
    end
end

function StateMachine:mousereleased(x, y, button)
    if self.current_state and self.current_state.mousereleased then
        self.current_state:mousereleased(x, y, button)
    end
end

function StateMachine:mousemoved(x, y, dx, dy)
    if self.current_state and self.current_state.mousemoved then
        self.current_state:mousemoved(x, y, dx, dy)
    end
end

function StateMachine:textinput(text)
    if self.current_state and self.current_state.textinput then
        self.current_state:textinput(text)
    end
end

function StateMachine:wheelmoved(x, y)
    if self.current_state and self.current_state.wheelmoved then
        self.current_state:wheelmoved(x, y)
    end
end

return StateMachine
