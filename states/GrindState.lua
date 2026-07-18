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
local HintController  = require("controllers.HintController")
local HintView        = require("views.HintView")
local CursorPool      = require("services.CursorPool")
local FlightSystem    = require("services.FlightSystem")
local ClickFlash      = require("services.ClickFlash")
local Ghosts          = require("services.Ghosts")
local CatalogModal    = require("views.CatalogModal")
local DeckSelectModal = require("views.DeckSelectModal")
local SettingsModal   = require("views.SettingsModal")
local OnboardingModal        = require("views.OnboardingModal")
local HintLogPanel           = require("views.HintLogPanel")
local AnalyticsConsentModal  = require("views.AnalyticsConsentModal")
local Constants       = require("data.constants")
local Decks           = require("models.Decks")
local HandAnalytics   = require("services.HandAnalytics")
local Tooltip         = require("services.Tooltip")
local HoverService    = require("services.HoverService")

local GrindState = {}
GrindState.__index = GrindState

function GrindState:new(game)
    local self = setmetatable({
        game           = game,
        -- Mid-grind catalog modal: nil = closed. Opened by the in-game
        -- "CATALOG" button in the top bar; same modal class the shove
        -- state uses post-bust, just instantiated on demand here so the
        -- player can shop with chips without busting first.
        catalog_modal      = nil,
        -- Read-only deck roster popup. Opened by clicking the top-bar
        -- DECK chip; swap is still restricted to the post-shove flow.
        deck_roster_modal  = nil,
        settings_modal     = nil,
        -- One-page how-to-play. Prototype builds (ONBOARDING_MODAL)
        -- auto-open it on first grind; TUTORIAL builds never show it —
        -- their "?" opens the hint log instead.
        onboarding_modal   = nil,
        -- "Help desk": the seen-hints log behind "?" in TUTORIAL builds.
        -- A slide-in side panel, NOT a modal — the grind stays visible
        -- so hovering a log entry can spotlight its targets in-game.
        help_panel         = nil,
        analytics_modal    = nil,
    }, GrindState)
    self.controller = GrindController:new(game)
    self.view       = GrindView:new(game, self.controller)
    -- Tutorial hint queue + bubble renderer (inert unless FEATURES.TUTORIAL).
    self.hints      = HintController:new(game, self.controller)
    self.hint_view  = HintView:new(game)
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
    game.openHelp       = function() state_self:openHelp()       end
    game.quickReset     = function() state_self:quickReset()     end
    game.toggleRoom     = function() state_self.game.state_machine:switch("room") end
    return self
end

function GrindState:openCatalog()
    if not self.catalog_modal then
        -- Mid-grind catalog is inspection-only. Purchases live in the
        -- post-bust ritual so the player can't compound a bankroll dump
        -- with an upgrade that strands the run.
        self.catalog_modal = CatalogModal:new(self.game, { read_only = true })
    end
end

function GrindState:closeCatalog()
    self.catalog_modal = nil
end

-- Mid-grind read-only deck-roster popup. Same view as the post-shove
-- swap modal but in read_only mode — clicking a tile does nothing,
-- clicking anywhere dismisses. Gated on the deck system's unlock (first
-- gauntlet clear) so it never opens before decks exist.
function GrindState:openDeckRoster()
    if not Decks.systemUnlocked(self.game.state) then return end
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

-- Top-bar "?" — TUTORIAL builds toggle the hint-log side panel ("help
-- desk", every hint delivered so far); prototype builds open the classic
-- how-to-play modal. Neither touches the `onboarded` flag.
function GrindState:openHelp()
    if Constants.FEATURES.TUTORIAL then
        if self.help_panel then
            self.help_panel:beginClose()
        else
            self.help_panel = HintLogPanel:new(self.game, self.hint_view)
        end
        return
    end
    if not self.onboarding_modal then
        self.onboarding_modal = OnboardingModal:new(self.game)
    end
end

-- Close the how-to-play modal. The first time it's dismissed we persist the
-- acknowledgement so it never auto-opens again. The view never sets this —
-- the host owns the state mutation (MVC).
--
-- The extra "Help Balance the Game" consent modal only escalates on the
-- true first run (fresh install) when the checkbox is left unchecked — a
-- one-time nudge, not something that should reappear every time the player
-- replays the how-to-play page via the top-bar "?". On a replay the
-- checkbox here just sets consent directly, checked or not.
function GrindState:_dismissOnboarding()
    local consent      = self.onboarding_modal:checkboxChecked()
    local was_first_run = not self.game.state.onboarded
    self.onboarding_modal = nil
    if consent or not was_first_run then
        self:_saveConsent(consent)
        self:_finalizeOnboarding()
    else
        self.analytics_modal = AnalyticsConsentModal:new(self.game)
    end
end

function GrindState:_resolveAnalyticsConsent()
    local accepted = self.analytics_modal:resolved() == "accept"
    self.analytics_modal = nil
    self:_saveConsent(accepted)
    self:_finalizeOnboarding()
end

function GrindState:_saveConsent(consent)
    if self.game.settings then
        self.game.settings.analytics_consent = consent
        self.game.save_service:saveSettings(self.game.settings)
    end
end

function GrindState:_finalizeOnboarding()
    if not self.game.state.onboarded then
        self.game.state.onboarded = true
        self.game.save_service:saveAll(
            self.game.state:serializeMeta(), self.game.state:serializeRun())
    end
end

-- No-cost rescue when the player is bricked with no chips (see
-- GrindController:canQuickReset). The view renders the button only when
-- allowed; the host owns the mutation + persisting it (MVC).
function GrindState:quickReset()
    self.controller:quickReset()
    self.game.save_service:saveAll(
        self.game.state:serializeMeta(), self.game.state:serializeRun())
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

    HandAnalytics.startRun(self.game.state)

    -- First-run setup. With ONBOARDING_MODAL the how-to-play force-opens
    -- once (dismissing it persists `onboarded`). Without it the modal
    -- stays behind the top-bar "?" and only the analytics-consent ask
    -- remains — asked once, then onboarding finalizes; if consent is
    -- already set (dev machine), finalize straight away.
    if not self.game.state.onboarded then
        if Constants.FEATURES.ONBOARDING_MODAL then
            self:openHelp()
        elseif self.game.settings
               and self.game.settings.analytics_consent == nil then
            self.analytics_modal = AnalyticsConsentModal:new(self.game)
        else
            self:_finalizeOnboarding()
        end
    end
end

function GrindState:exit() end

-- Any overlay up? Hints neither evaluate nor render underneath one — a
-- hint firing behind the catalog (or beside the consent dialog) is noise.
function GrindState:_modalUp()
    return (self.catalog_modal or self.deck_roster_modal
            or self.settings_modal or self.onboarding_modal
            or self.help_panel or self.analytics_modal) ~= nil
end

function GrindState:update(dt)
    self.controller:update(dt)
    self.view:update(dt)
    if self.help_panel then
        self.help_panel:update(dt)
        if self.help_panel.done then self.help_panel = nil end
    end
    if self:_modalUp() then
        if self.help_panel then
            -- The help panel dropdown blocks what's under it: the view's hover pass
            -- (just ran) has no idea it exists, so kill any tooltip/hover it set
            -- for a widget beneath the pointer.
            if self.help_panel:containsPoint(love.mouse.getPosition()) then
                Tooltip.clear()
                HoverService.clear()
            end
        else
            -- A full-screen modal is active. Clear all background tooltips and hovers.
            Tooltip.clear()
            HoverService.clear()
        end
    end
    if not self:_modalUp() then self.hints:update(dt) end
    -- Cursor swarm steps after the controller/view tick. Hit-boxes were
    -- populated by last frame's draw — 1-frame stale, invisible at 60fps.
    -- The dispatcher closure routes a synthetic click through the same
    -- handler the mouse uses (GrindView:_handleHitBox).
    local view = self.view
    CursorPool.update(dt, view.hit_boxes, self.controller.ctx,
        function(hb) view:_handleHitBox(hb) end)
end

function GrindState:draw()
    -- Tutorial hint layer (active sticky hint + the [i] info queue) —
    -- passed into the view as its overlay (above gameplay, below the
    -- hover tooltip), and dropped entirely while a modal is up.
    local hint_overlay
    if not self:_modalUp() then
        local state_self = self
        hint_overlay = function()
            state_self.hint_view:draw(state_self.hints:activeHint(),
                                      state_self.hints:queuedHints())
        end
    end
    self.view:draw(hint_overlay)
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
    -- Hint-log side panel rides over the grind but under real modals.
    if self.help_panel then
        self.help_panel:draw()
    end
    -- How-to-play sits on top of everything else.
    if self.onboarding_modal then
        self.onboarding_modal:draw()
    end
    if self.analytics_modal then
        self.analytics_modal:draw()
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
    -- Drop open overlays so a new-game wipe (Settings → Start new game) doesn't
    -- leave the Settings / catalog / deck modal hanging over the fresh run.
    -- The onboarding modal is intentionally left alone — :enter reopens it for
    -- the fresh (un-onboarded) game.
    self.settings_modal    = nil
    self.catalog_modal     = nil
    self.deck_roster_modal = nil
    self.help_panel        = nil
    -- Drop any active hint; the seen-set was wiped on GameState, so the
    -- fresh game re-teaches from the top.
    self.hints:reset()
end

-- Phase 2 debug: H deals one hand on table 1. J deals every idle table.
-- Both are temporary — Phase 3 brings click-to-deal via TablePanel buttons.
function GrindState:keypressed(key)
    if key == "tab" then
        self.game.state_machine:switch("room")
        return
    end

    -- How-to-play is the most forced modal — it owns input while up; only its
    -- button / space-return dismisses it (ESC does not escape it).
    if self.onboarding_modal then
        self.onboarding_modal:consumeKey(key)
        if self.onboarding_modal:resolved() then self:_dismissOnboarding() end
        return
    end
    -- Hint-log panel: ESC slides it out; everything else is mouse-driven.
    if self.help_panel then
        if key == "escape" then self.help_panel:beginClose() end
        return
    end
    if self.analytics_modal then
        self.analytics_modal:consumeKey(key)
        if self.analytics_modal:resolved() then self:_resolveAnalyticsConsent() end
        return
    end
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
    -- ESC outside any modal opens the settings modal (which carries its own
    -- Quit row and closes on a second ESC). It must NOT also fire the quit
    -- confirm — that stacked a second dialog on top of the freshly-opened
    -- settings modal.
    if key == "escape" then
        self:openSettings()
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
    elseif key == "y" then
        self.game.state.cleared = not self.game.state.cleared
        print("[debug] Toggled gauntlet clear state (decks unlocked = " .. tostring(self.game.state.cleared) .. ")")
    end
end

function GrindState:mousepressed(x, y, b)
    if self.onboarding_modal then
        self.onboarding_modal:consumeMouse(x, y, b)
        if self.onboarding_modal:resolved() then self:_dismissOnboarding() end
        return
    end
    -- Hint-log panel: clicks inside are consumed (hover does the work);
    -- clicking anywhere else slides it away.
    if self.help_panel then
        if not self.help_panel:mousepressed(x, y) then
            self.help_panel:beginClose()
        end
        return
    end
    if self.analytics_modal then
        self.analytics_modal:consumeMouse(x, y, b)
        if self.analytics_modal:resolved() then self:_resolveAnalyticsConsent() end
        return
    end
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
    -- Hint layer clicks: an [i] icon dismisses that queued info hint; the
    -- active sticky hint's bubble dismisses it. Everything else falls
    -- through — clicks on a highlighted widget are the advance-on-action
    -- path, and info hints can never be lost to a stray click.
    local hint_hit = self.hint_view:mousepressed(x, y)
    if hint_hit == "bubble" then
        self.hints:dismissActive()
        return
    elseif hint_hit then
        self.hints:dismissQueued(hint_hit.id)
        return
    end

    self.view:mousepressed(x, y, b)
end

function GrindState:mousereleased(x, y, b)
    if self.onboarding_modal then
        self.onboarding_modal:mousereleased(x, y, b)
        return
    end
    if self.analytics_modal then
        self.analytics_modal:mousereleased(x, y, b)
        return
    end
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
    if self.onboarding_modal then
        self.onboarding_modal:mousemoved(x, y)
        return
    end
    if self.analytics_modal then
        self.analytics_modal:mousemoved(x, y)
        return
    end
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
    if self.onboarding_modal then
        self.onboarding_modal:wheelmoved(x, y)
        return
    end
    if self.help_panel then
        self.help_panel:wheelmoved(x, y)
        return
    end
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
