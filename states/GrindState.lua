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

local Theme            = require("views.Theme")
local GrindView        = require("views.GrindView")
local GrindController  = require("controllers.GrindController")
local CursorPool       = require("services.CursorPool")
local ChipFlightSystem = require("services.ChipFlightSystem")

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
    --
    -- Effects ctx must be computed BEFORE the rebuild so freshly seeded
    -- tables (e.g. start_table_count from Free Sit) pick up Cold Read's
    -- pre-revealed attributes.
    self.controller:invalidateEffects()
    self.controller.pool:rebuildFromState(self.controller.ctx)
end

function GrindState:exit() end

function GrindState:update(dt)
    self.controller:update(dt)
    self.view:update(dt)
    -- Cursor swarm steps after the controller/view tick. Hit-boxes were
    -- populated by last frame's draw — 1-frame stale, invisible at 60fps.
    -- The dispatcher closure routes a synthetic click through the same
    -- handler the mouse uses (GrindView:_handleHitBox).
    local view = self.view
    CursorPool.update(dt, view.hit_boxes, self.controller.ctx,
        function(hb) view:_handleHitBox(hb) end)
end

function GrindState:draw()
    self.view:draw()
end

-- Called by InputController F6/F7 handlers via the fullResetAllStates
-- sweep. Wipes the cursor swarm and any in-flight chips so a fresh game
-- / reload doesn't carry dangling pointers or sprites.
function GrindState:fullReset()
    CursorPool.reset()
    ChipFlightSystem.clear()
end

-- Phase 2 debug: H deals one hand on table 1. J deals every idle table.
-- Both are temporary — Phase 3 brings click-to-deal via TablePanel buttons.
function GrindState:keypressed(key)
    if key == "h" then
        self.controller:dealHand(1)
    elseif key == "j" then
        self.controller:dealAll()
    end
end

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

function GrindState:resize(w, h)
    if self.view.resize then self.view:resize(w, h) end
end

return GrindState
