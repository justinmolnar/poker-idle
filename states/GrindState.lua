-- states/GrindState.lua
--
-- Grind mode: tables ticking, bankroll growing, run upgrades + catalog UI
-- in the sidebars (Phase 4+), the SHOVE button as exit. Owns:
--   • a GrindController (runs the TablePool, applies bankroll deltas, emits
--     floating text, validates purchases)
--   • a GrindView (renders top bar, table grid, sidebars, floating text)
--
-- The controller is exposed on `game.grind` so other states (notably the
-- shove-state's prestige flow) can call into it post-bust to invalidate
-- effects after a `:resetRun()`.

local Theme           = require("views.Theme")
local GrindView       = require("views.GrindView")
local GrindController = require("controllers.GrindController")

local GrindState = {}
GrindState.__index = GrindState

function GrindState:new(game)
    local self = setmetatable({
        game = game,
    }, GrindState)
    self.controller = GrindController:new(game)
    self.view       = GrindView:new(game, self.controller)
    return self
end

function GrindState:enter()
    Theme.setActive("room")
    -- Rebuild the table pool from the current state — covers the case where
    -- the run was reset via prestige while we were in the shove state. The
    -- shove flow only mutates state directly; we rehydrate on re-enter.
    self.controller.pool:rebuildFromState()
    self.controller:invalidateEffects()
end

function GrindState:exit() end

function GrindState:update(dt)
    self.controller:update(dt)
    self.view:update(dt)
end

function GrindState:draw()
    self.view:draw()
end

function GrindState:keypressed(_) end

function GrindState:mousepressed(x, y, b)
    self.view:mousepressed(x, y, b)
end

function GrindState:mousereleased(x, y, b)
    self.view:mousereleased(x, y, b)
end

function GrindState:mousemoved(x, y, dx, dy)
    self.view:mousemoved(x, y, dx, dy)
end

function GrindState:wheelmoved(x, y)
    self.view:wheelmoved(x, y)
end

return GrindState
