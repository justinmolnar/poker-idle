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
local CursorPool      = require("services.CursorPool")
local FlightSystem    = require("services.FlightSystem")
local ClickFlash      = require("services.ClickFlash")
local Ghosts          = require("services.Ghosts")
local CatalogModal    = require("views.CatalogModal")
local DeckSelectModal = require("views.DeckSelectModal")
local SettingsModal   = require("views.SettingsModal")
local Constants       = require("data.constants")

local GrindState = {}
GrindState.__index = GrindState

function GrindState:new(game)
    local self = setmetatable({
        game           = game,
        -- Mid-grind catalog modal: nil = closed. Opened by the in-game
        -- "CATALOG" button in the top bar; same modal class the shove
        -- state uses post-bust, just instantiated on demand here so the
        -- player can shop PP without busting first.
        catalog_modal      = nil,
        -- Read-only deck roster popup. Opened by clicking the top-bar
        -- DECK chip; swap is still restricted to the post-shove flow.
        deck_roster_modal  = nil,
        settings_modal     = nil,
    }, GrindState)
    self.controller = GrindController:new(game)
    self.view       = GrindView:new(game, self.controller)
    -- Expose the controller on the DI container so other states (the
    -- shove-state's CatalogModal) can dispatch purchase intents through
    -- the proper layer instead of mutating GameState directly.
    game.grind = self.controller
    -- Expose a hook the view can call to open the in-grind catalog modal
    -- without the view having to know about state internals.
    local state_self = self
    game.openCatalog    = function() state_self:openCatalog()    end
    game.openSettings   = function() state_self:openSettings()   end
    game.openDeckRoster = function() state_self:openDeckRoster() end
    return self
end

function GrindState:openCatalog()
    if not self.catalog_modal then
        self.catalog_modal = CatalogModal:new(self.game)
    end
end

function GrindState:closeCatalog()
    self.catalog_modal = nil
end

-- Mid-grind read-only deck-roster popup. Same view as the post-shove
-- swap modal but in read_only mode — clicking a tile does nothing,
-- clicking anywhere dismisses. Gated on FEATURES.DECKS so the prototype
-- build never opens it.
function GrindState:openDeckRoster()
    if not Constants.FEATURES.DECKS then return end
    if not self.deck_roster_modal then
        self.deck_roster_modal = DeckSelectModal:new(self.game,
                                                     { read_only = true })
    end
end

function GrindState:closeDeckRoster()
    self.deck_roster_modal = nil
end

function GrindState:openSettings()
    if not self.settings_modal then
        self.settings_modal = SettingsModal:new(self.game)
    end
end

function GrindState:closeSettings()
    self.settings_modal = nil
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
    -- Mid-grind catalog modal — drawn over the live grind view so the
    -- player can shop without leaving the table layout behind. Same
    -- visual modal as the post-bust flow.
    if self.catalog_modal then
        self.catalog_modal:draw()
    end
    if self.deck_roster_modal then
        self.deck_roster_modal:draw()
    end
    if self.settings_modal then
        self.settings_modal:draw()
    end
end

-- Called by InputController F6/F7 handlers via the fullResetAllStates
-- sweep. Wipes the cursor swarm and any in-flight chips so a fresh game
-- / reload doesn't carry dangling pointers or sprites.
function GrindState:fullReset()
    CursorPool.reset()
    FlightSystem.clear()
    ClickFlash.clear()
    Ghosts.clear()
end

-- Phase 2 debug: H deals one hand on table 1. J deals every idle table.
-- Both are temporary — Phase 3 brings click-to-deal via TablePanel buttons.
function GrindState:keypressed(key)
    -- Modal-first input: ESC always closes; SPACE/RETURN dismiss the
    -- modal back to grind. Modal-context keys are not hotkeys, so they
    -- run in every mode.
    if self.settings_modal then
        if self.settings_modal:consumeKey(key) then return end
        if key == "escape" then self:closeSettings() end
        return
    end
    if self.catalog_modal then
        if key == "escape" or self.catalog_modal:consumeKey(key) then
            self:closeCatalog()
        end
        return
    end
    if self.deck_roster_modal then
        if key == "escape" or self.deck_roster_modal:consumeKey(key) then
            self:closeDeckRoster()
        end
        return
    end
    -- ESC outside any modal opens settings (kept in every mode — it's
    -- the conventional UX path).
    if key == "escape" then
        self:openSettings()
        if self.settings_modal then self.settings_modal:promptQuit() end
        return
    end
    -- H/J are deal hotkeys that circumvent the per-table DEAL button.
    -- Gated on FEATURES.DEV_HOTKEYS so shipping builds don't let the
    -- player bypass the intended click-to-deal gameplay loop.
    if not Constants.FEATURES.DEV_HOTKEYS then return end
    if key == "h" then
        self.controller:dealHand(1)
    elseif key == "j" then
        self.controller:dealAll()
    end
end

function GrindState:mousepressed(x, y, b)
    if self.settings_modal then
        local consumed = self.settings_modal:consumeMouse(x, y, b)
        if not consumed then self:closeSettings() end
        return
    end
    if self.catalog_modal then
        local consumed = self.catalog_modal:consumeMouse(x, y, b)
        -- Continue button click sets the modal's resolved flag — close
        -- the modal in response. Otherwise: outside-click dismiss when
        -- nothing else consumed the click (dead-space click).
        if self.catalog_modal:resolved() then
            self:closeCatalog()
        elseif not consumed then
            self:closeCatalog()
        end
        return
    end
    if self.deck_roster_modal then
        self.deck_roster_modal:consumeMouse(x, y, b)
        if self.deck_roster_modal:resolved() then
            self:closeDeckRoster()
        end
        return
    end
    self.view:mousepressed(x, y, b)
end

function GrindState:mousereleased(x, y, b)
    if self.settings_modal then
        if self.settings_modal.mousereleased then
            self.settings_modal:mousereleased(x, y, b)
        end
        return
    end
    if self.catalog_modal then return end
    if self.deck_roster_modal then return end
    self.view:mousereleased(x, y, b)
end

function GrindState:mousemoved(x, y, dx, dy)
    if self.settings_modal then
        if self.settings_modal.mousemoved then
            self.settings_modal:mousemoved(x, y)
        end
        return
    end
    if self.catalog_modal then return end
    if self.deck_roster_modal then return end
    self.view:mousemoved(x, y, dx, dy)
end

function GrindState:wheelmoved(x, y)
    if self.settings_modal and self.settings_modal.wheelmoved then
        self.settings_modal:wheelmoved(x, y)
        return
    end
    if self.catalog_modal and self.catalog_modal.wheelmoved then
        self.catalog_modal:wheelmoved(x, y)
        return
    end
    self.view:wheelmoved(x, y)
end

function GrindState:resize(w, h)
    if self.view.resize then self.view:resize(w, h) end
end

return GrindState
