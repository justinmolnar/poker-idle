-- controllers/InputController.lua
--
-- Wires global hotkeys onto the InputDispatcher with predicate-based routing.
-- The dispatcher fires the FIRST handler whose predicate passes — so global
-- hotkeys (F2 toggle state, F10 quit, etc.) are registered first, and the
-- catch-all forwards everything else to the StateMachine.
--
-- Adding a new global hotkey = one .on() call here. State-local input stays
-- in the state's own keypressed.

local InputController = {}
InputController.__index = InputController

function InputController:new(game)
    local self = setmetatable({ game = game }, InputController)
    return self
end

function InputController:wire()
    local game       = self.game
    local dispatcher = game.input_dispatcher
    local sm         = game.state_machine

    -- ── keypressed ────────────────────────────────────────────────────────

    -- F2: toggle grind ↔ shove. Useful while iterating on either screen.
    dispatcher:on("keypressed",
        function(key) return key == "f2" end,
        function()
            local next_name = (sm:current() == "grind") and "shove" or "grind"
            sm:switch(next_name)
        end)

    -- ESC: quit, dev convenience. Production builds will gate this behind a
    -- confirmation dialog; for the skeleton it's a fast exit.
    dispatcher:on("keypressed",
        function(key) return key == "escape" end,
        function() love.event.quit() end)

    -- Catch-all: forward every other keypress to the active state.
    dispatcher:on("keypressed", nil, function(key) sm:keypressed(key) end)

    -- ── other events: always forward to state ────────────────────────────

    dispatcher:on("keyreleased",   nil, function(key)        sm:keyreleased(key)        end)
    dispatcher:on("mousepressed",  nil, function(x, y, b)    sm:mousepressed(x, y, b)   end)
    dispatcher:on("mousereleased", nil, function(x, y, b)    sm:mousereleased(x, y, b)  end)
    dispatcher:on("mousemoved",    nil, function(x, y, dx, dy) sm:mousemoved(x, y, dx, dy) end)
    dispatcher:on("textinput",     nil, function(text)       sm:textinput(text)         end)
    dispatcher:on("wheelmoved",    nil, function(x, y)       sm:wheelmoved(x, y)        end)
end

return InputController
