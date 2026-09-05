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
local ChipPile        = require("views.ChipPile")
local ClickFlash      = require("services.ClickFlash")
local Ghosts          = require("services.Ghosts")
local RollingValue    = require("services.RollingValue")
local ItemGhosts      = require("views.ItemGhosts")
local CatalogModal    = require("views.CatalogModal")
local DeckFlyer       = require("views.DeckFlyer")
local SettingsModal   = require("views.SettingsModal")
local GlossaryPanel          = require("views.GlossaryPanel")
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
        -- The glossary behind "?" on the House poster (TUTORIAL builds).
        -- A slide-in side panel, NOT a modal — the grind stays visible
        -- so hovering a log entry can spotlight its targets in-game.
        help_panel         = nil,
        analytics_modal    = nil,
    }, GrindState)
    self.controller = GrindController:new(game)
    self.view       = GrindView:new(game, self.controller)
    -- Tutorial hint queue + bubble renderer.
    -- Hints are hosted by main.lua now (game.hints / game.hint_view), so
    -- they render on every screen and above every modal. This state only
    -- says when they should stay quiet: see hintsBlocked.
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
        self.deck_roster_modal = DeckFlyer:new(self.game, { read_only = true })
        self.game.state.decks_unseen = {}
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

-- The "?" on THE HOUSE poster toggles the glossary (everything the beats
-- have taught, written down). Never touches the `onboarded` flag.
function GrindState:openHelp()
    if self.help_panel then
        self.help_panel:beginClose()
    else
        self.help_panel = GlossaryPanel:new(self.game)
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
    -- The rebuild discards every Table object. A resting result floater
    -- parked on one of them would wait forever: its removal needs the
    -- table to leave "idle" or play another hand, and a discarded table
    -- does neither (the "stuck payout" bug). Queued chip bursts anchor to
    -- those tables too. Drop both before the objects go away.
    self.game.floating_text.clear()
    self.controller.pending_bursts = {}
    self.controller.pool:rebuildFromState(self.controller.ctx)

    HandAnalytics.startRun(self.game.state)

    -- First-run setup: the analytics-consent ask, once, then onboarding
    -- finalizes; if consent is already set (dev machine), finalize
    -- straight away.
    if not self.game.state.onboarded then
        if self.game.settings
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
            or self.settings_modal
            or self.help_panel or self.analytics_modal) ~= nil
end

-- Whether the global hint layer should stay quiet right now. Narrower than
-- _modalUp on purpose: the catalog and deck roster are surfaces the
-- tutorial needs to teach, so hints render OVER them. Settings is a menu,
-- consent is already explaining, and the glossary is a reading surface —
-- nothing should talk over the player mid-lookup.
function GrindState:hintsBlocked()
    return (self.settings_modal
            or self.help_panel or self.analytics_modal) ~= nil
end

function GrindState:update(dt)
    -- Cursor swarm steps BEFORE the controller tick: its hit-boxes came
    -- from last frame's draw, and the controller's update is what removes
    -- tables (deferred closes) — dispatching first keeps a box's index
    -- valid for the pool it was built against. The identity check in
    -- _handleHitBox covers whatever this ordering can't.
    local cursor_view = self.view
    local state = self.game.state
    -- The House has the floor on a `pause` beat: the tables, the cursors
    -- and the status clocks stand still until the click. The view still
    -- runs its hover pass with no time.
    if self.game.sim_frozen then
        self.view:update(0)
        return
    end
    CursorPool.update(dt, cursor_view.hit_boxes, self.controller.ctx,
        function(hb)
            -- Lifetime count of DEAL clicks the swarm makes: the cursor
            -- catalog items gate on it (Gaming Keyboard, Desk Lamp,
            -- Telephone), so idling itself is what opens more idling.
            if hb and hb.action == "deal" then
                state.total_cursor_deals = (state.total_cursor_deals or 0) + 1
            end
            cursor_view:_handleHitBox(hb)
        end)

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
end

function GrindState:draw()
    -- The hint layer used to be handed in here as the view's overlay,
    -- which put it UNDER every modal drawn below. main.lua draws it after
    -- the whole state now, so the catalog and deck roster can be taught.
    self.view:draw(nil)
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
    ChipPile.clearAll()
    ClickFlash.clear()
    -- Resting result floaters reference tables the wipe destroys; without
    -- this a persisted "+$X" from the old game survives onto the fresh one.
    self.game.floating_text.clear()
    Ghosts.clear()
    RollingValue.clear()
    ItemGhosts.clear()
    -- Queued chip bursts reference anchors of tables the wipe destroyed.
    if self.controller then self.controller.pending_bursts = {} end
    -- Snap the view's display tweens to the fresh state so the bankroll
    -- doesn't visibly count down from the previous game's total.
    if self.view and self.view.resetDisplays then self.view:resetDisplays() end
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
    if self.game.hints then self.game.hints:reset() end
    if self.game.story then self.game.story:reset() end
end

-- Phase 2 debug: H deals one hand on table 1. J deals every idle table.
-- Both are temporary — Phase 3 brings click-to-deal via TablePanel buttons.
function GrindState:keypressed(key)
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
        -- The modal gets the key first: ESC may only be tucking the
        -- manifest away (consumed, book stays). An unconsumed ESC, or a
        -- consumed key that resolved the modal (SPACE/ENTER), closes it.
        if self.catalog_modal:consumeKey(key) then
            if self.catalog_modal:resolved() then self:closeCatalog() end
            return
        end
        if key == "escape" then self:closeCatalog() end
        return
    end
    if self.deck_roster_modal then
        if key == "escape" or self.deck_roster_modal:consumeKey(key) then
            self:closeDeckRoster()
        end
        return
    end
    -- Tab sits BELOW the modal blocks on purpose: it used to be checked
    -- first, which let it yank the screen to the Room out from under any
    -- open modal.
    if key == "tab" then
        self.game.state_machine:switch("room")
        return
    end
    -- ESC outside any modal opens the settings modal (which carries its own
    -- Quit row and closes on a second ESC). It must NOT also fire the quit
    -- confirm — that stacked a second dialog on top of the freshly-opened
    -- settings modal.
    if key == "escape" then
        -- A table drag in flight eats the ESC (cancel + snap back)
        -- instead of opening settings on top of a held panel.
        if self.view.cancelDrag and self.view:cancelDrag() then return end
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
    if b ~= 1 then return end
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
    -- Hint-layer clicks are consumed by main.lua's dispatcher handler
    -- before this state ever sees them.

    self.view:mousepressed(x, y, b)
end

function GrindState:mousereleased(x, y, b)
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
