-- states/ShoveState.lua
--
-- Shove mode: the all-in gauntlet. Owns the live Gauntlet model (one per
-- shove attempt), the always-on debug overlay, the per-shove debug-mutable
-- `shove_rates` struct (r1/r2/r3/clear) seeded from the player's computed
-- effects on enter, and the prestige flow that fires when a gauntlet
-- finishes:
--
--   • Gauntlet busts (any runout LOSS) → the result and the run's banked
--     {chip} stay on the felt until the player clicks through, then the
--     CatalogModal slides in. Closing the catalog → resetRun → grind.
--   • Gauntlet clears (3 of 3 runouts WON) → award chips, set state.cleared,
--     switch to CreditsState. The win-condition path.
--
-- The state auto-starts a gauntlet on enter when none exists. Switching to
-- this state via the SHOVE button (or F2 from grind for testing) just plays
-- the gauntlet. SPACE during animation skips the cinematic.

local Theme              = require("views.Theme")
local ShoveView          = require("views.ShoveView")
local Overlay            = require("views.ShoveDebugOverlay")
local PrototypeEndModal  = require("views.PrototypeEndModal")
local CatalogModal       = require("views.CatalogModal")
local DeckSelectModal    = require("views.DeckSelectModal")
local SettingsModal      = require("views.SettingsModal")
local Gauntlet           = require("models.Gauntlet")
local Decks              = require("models.Decks")
local Catalog            = require("data.catalog")
local RunUpgrades        = require("data.run_upgrades")
local FlightSystem       = require("services.FlightSystem")
local ClickFlash         = require("services.ClickFlash")
local Constants          = require("data.constants")
local ShoveRate          = require("models.shove_rate")
local HandAnalytics      = require("services.HandAnalytics")

local ShoveState = {}
ShoveState.__index = ShoveState

local function isShiftDown()
    return love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function ShoveState:new(game)
    local self = setmetatable({
        game            = game,
        shove_rates     = nil,    -- locked at :enter; struct from ShoveRate.compute
        gauntlet        = nil,
        catalog_modal        = nil,    -- bust step 2: post-run chip shop
        deck_select_modal    = nil,    -- bust step 3: choose active deck for next run (post-first-clear)
        settings_modal       = nil,    -- ESC overlay (volume, resolution, quit)
        prototype_end_modal  = nil,    -- prototype-mode "you beat the demo" screen
        _ended_handled       = false,  -- guard so _onGauntletEnded fires once per gauntlet
    }, ShoveState)
    self.view    = ShoveView:new(game, self)
    self.overlay = Overlay:new(game, self)
    return self
end

function ShoveState:openSettings()
    if not self.settings_modal then
        self.settings_modal = SettingsModal:new(self.game)
    end
end

function ShoveState:closeSettings()
    self.settings_modal = nil
end

-- Wipe all per-shove transient state. Called by the F6/F7 debug hotkeys
-- (reload-from-disk and wipe-saves) so a stale gauntlet from before the
-- reload doesn't pop back when the player next enters shove.
function ShoveState:fullReset()
    self.gauntlet            = nil
    self.catalog_modal       = nil
    self.deck_select_modal   = nil
    self.prototype_end_modal = nil
    self.settings_modal      = nil
    self._ended_handled      = false
    self.view:resetTimeline()
    self.overlay:resetStats()
end

function ShoveState:enter()
    Theme.setActive("shove")
    local state = self.game.state

    -- All-in cash-out: every table's current stack returns to bankroll
    -- and the pool is cleared. The shove commits the player's total
    -- wealth, not just spendable bankroll — the buildup spectacle then
    -- visualizes those chips moving from stack to pot. Run only on a
    -- fresh gauntlet entry; if we're re-entering shove after a hot
    -- reload (F6 path) the gauntlet flag prevents a double cash-out.
    if not self.gauntlet and self.game.grind then
        local pool = self.game.grind.pool
        if pool and pool.tables then
            local tied = 0
            for _, t in ipairs(pool.tables) do
                tied = tied + (t.stack or 0)
            end
            pool.tables = {}
            state.bankroll = state.bankroll + tied
        end
        state.active_table_specs         = {}
        state.active_table_mutes         = {}
        state.active_table_rebuy_mutes   = {}
        state.active_table_mtt_hands_won = {}
        state.active_table_mtt_state     = {}
    end

    -- Lock in the shove rate from the current catalog ctx + post-
    -- cashout bankroll. Catalog purchases between shoves count toward
    -- the next attempt because computeEffects rebuilds ctx fresh each
    -- :enter.
    local ctx = state:computeEffects(self.game.effects, Catalog, RunUpgrades)
    self.shove_rates = ShoveRate.compute(ctx, state.bankroll or 0)

    -- Auto-start the buildup spectacle on entry. The gauntlet itself
    -- doesn't begin until the view's buildup phase finishes (handled
    -- in :update — sees view:isReadyToDeal and fires _beginGauntlet).
    if not self.gauntlet then
        self.view:beginBuildup(self.shove_rates)
    end
end

function ShoveState:exit() end

-- The catalog and deck select are teachable and stay open to hints;
-- settings is a menu and the prototype-end modal is a hard stop.
-- No [i] queue on the felt: one thing to read at a time here.
ShoveState.suppressHintQueue = true

function ShoveState:hintsBlocked()
    return (self.settings_modal or self.prototype_end_modal) ~= nil
end

function ShoveState:_beginGauntlet()
    HandAnalytics.recordShoveStart(self.shove_rates)
    self.gauntlet = Gauntlet:new(self.game, self.shove_rates)
    local result = self.gauntlet:begin()
    self.overlay:recordAttempt(result)
    -- The act this shove opens, if any, is knowable NOW: the result is
    -- pre-baked. It used to be computed at the end, in the same statement
    -- that flipped the persistent flag, which meant the House could not
    -- react to it on the felt because by then the flag was already true.
    self._pending_milestone = self:_milestoneFor(result)
    self.view:onGauntletBegin(self._pending_milestone,
                              self.game.state.chips_this_run or 0)
    self._ended_handled = false

    if Constants.DEBUG.SHOW_DEBUG_OVERLAY then
        print(Gauntlet.formatResult(result, self.overlay.attempts))
        print(string.format("  ↳ session: %d/%d wins (%.1f%%, expected %.1f%%)",
            self.overlay.wins, self.overlay.attempts,
            100 * self.overlay.wins / math.max(1, self.overlay.attempts),
            100 * (self.shove_rates and self.shove_rates.clear or 0)))
    end
end

-- Which act a result opens: "act2" for a first R1 win, "act3" for a first
-- R2 win, nil otherwise. R2 implies R1, so act3 wins on a double.
function ShoveState:_milestoneFor(result)
    local state = self.game.state
    local m = nil
    if result and result.outcomes then
        if result.outcomes[1] == true and not state.shove_r1_won then m = "act2" end
        if result.outcomes[2] == true and not state.shove_r2_won then m = "act3" end
    end
    return m
end

function ShoveState:_onGauntletEnded()
    self._ended_handled = true
    local result = self.gauntlet.result
    local state  = self.game.state

    -- Chips aren't computed at bust anymore. They were banked into
    -- state.chips during the run via GrindController on each
    -- first-win-at-stake. The modal just reads state.chips_this_run.
    local chips_banked = state.chips_this_run or 0
    HandAnalytics.recordShoveResult(result, chips_banked)

    -- Which act this shove opened, if any. Captured in the same block that
    -- flips the flags, so it is inherently once-per-game and rides the save
    -- below. The prestige modal reads it and reframes itself: winning a
    -- runout is an act break, not a bust, and titling it BUSTED was the
    -- worst-timed word in the game.
    --
    -- R2 can only be won on a shove that also won R1, so on a
    -- double-milestone shove act3 correctly overwrites act2: the bigger
    -- reveal is the one worth showing.
    local save_needed = false
    if result.outcomes then
        if result.outcomes[1] == true and not state.shove_r1_won then
            state.shove_r1_won = true
            save_needed = true
            print("[shove] Won Runout 1 of the gauntlet: unlocked Act 2!")
        end
        if result.outcomes[2] == true and not state.shove_r2_won then
            state.shove_r2_won = true
            save_needed = true
            print("[shove] Won Runout 2 of the gauntlet: unlocked Act 3!")
        end
    end
    if save_needed then
        self.game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
    end

    -- Demo-cut intercept: when FEATURES.DEMO_CUT is on, winning R1 then
    -- losing R2 is the natural cliffhanger that ends the demo. Show the
    -- end-of-prototype modal instead of the bust prestige flow. The
    -- player chooses Continue (resetRun + grind) or Exit to Title.
    if Constants.FEATURES.DEMO_CUT
       and not result.won
       and result.busted_at == 2
       and result.outcomes
       and result.outcomes[1] == true then
        self.prototype_end_modal = PrototypeEndModal:new(self.game)
        return
    end

    if result.won then
        state.cleared = true
        -- Persist immediately: love.quit only saves from grind/shove, so
        -- quitting at the credits screen would otherwise lose the clear
        -- (and with it the deck-system unlock).
        self.game.save_service:saveAll(
            state:serializeMeta(), state:serializeRun())
        self.gauntlet = nil
        self.view:resetTimeline()
        self.game.state_machine:switch("credits")
    else
        -- The catalog was thrown onto the felt before the hold; the click
        -- that advanced the hold means "leave". If the throw never fired
        -- (skipped past), build it now so the shop is never missed.
        if not self.catalog_modal then self:throwCatalog() end
        self:_dismissCatalogAndReturn()
    end
end

-- Prototype-end resolution. "Continue Playing" routes through the
-- catalog (mirrors the standard post-bust flow — same chance to spend
-- banked chips before the next run starts). "Exit to Title" skips the
-- catalog and drops the player back at the start screen with their
-- current run reset.
function ShoveState:_resolvePrototypeEnd(choice)
    self.prototype_end_modal = nil

    if choice == "exit" then
        local state = self.game.state
        state:resetRun()
        local meta_ctx = state:computeEffects(
            self.game.effects, self.game.catalog, self.game.run_upgrades)
        state:applyStartingPerks(meta_ctx)
        self.gauntlet       = nil
        self._ended_handled = false
        self.view:resetTimeline()
        self.game.state_machine:switch("title")
        return
    end

    -- "continue" path: open the catalog (player banked chips this run;
    -- this is the moment to spend it). The catalog's Continue button
    -- runs _dismissCatalogAndReturn which handles the run reset and
    -- the switch back to grind.
    self.game.state.catalog_seen = true
    self.catalog_modal = CatalogModal:new(self.game,
        { intro_callout = self:_catalogIntroPending() })
end

-- The catalog's one-time tutorial lede shows on the first post-shove
-- visit only (TUTORIAL builds; seen-flag set on dismiss).
function ShoveState:_catalogIntroPending()
    local seen = self.game.state.hints_seen
    return Constants.FEATURES.TUTORIAL
       and seen ~= nil
       and not seen["catalog_intro"]
end

-- Step 1 of the post-bust flow: prestige summary modal closes, catalog
-- modal opens. Run state stays put — the player still has their
-- chips_this_run banked to state.chips at this point and can spend it.
-- The catalog has now introduced itself: catalog_seen (meta, persisted
-- on the next save) lets the grind top-bar CATALOG button render.
-- The dealer throws the catalog onto the felt. Called by the view as a
-- timeline beat, before the result hold, so the book is on the table while
-- the player is still reading the hand.
function ShoveState:throwCatalog()
    if self.catalog_modal then return end
    self.game.state.catalog_seen = true
    self.catalog_modal = CatalogModal:new(self.game,
        { intro_callout = self:_catalogIntroPending(),
          on_felt = true, scrim = false,
          -- Keyed on a per-throw counter, not shove_count: resetRun bumps
          -- shove_count AFTER the shove, so every throw during one hashed
          -- the same number and the book landed in the same spot every time.
          throw_key = "catalog:" .. tostring(self:_nextThrowId()) })
end

-- A different key every throw, persisted so it keeps varying across
-- sessions. Lives in the free-form hints_seen map like the House's
-- once-lines do, so it needs no new serialized field.
function ShoveState:_nextThrowId()
    local seen = self.game.state.hints_seen
    if not seen then return os.time() end
    local n = (tonumber(seen["catalog:throws"]) or 0) + 1
    seen["catalog:throws"] = n
    return n
end

-- (_advanceToCatalog is gone: the catalog is thrown as a timeline beat, see
-- throwCatalog, and the hold's click leaves.)

-- Step 2 of the post-bust flow: catalog modal closes, run resets, then —
-- once the deck system has unlocked (first gauntlet clear) — the
-- deck-select modal opens for step 3.
-- Before that, the run goes straight to grind. New owned_items
-- (Poker Poster + whatever was bought) propagate via computeEffects →
-- applyStartingPerks before either branch.
function ShoveState:_dismissCatalogAndReturn()
    local state = self.game.state
    -- The intro callout (if it showed this visit) is now delivered.
    if state.hints_seen then state.hints_seen["catalog_intro"] = true end
    state:resetRun()
    -- Apply meta-progression perks owned in the catalog (Pocket Cash,
    -- Free Sit, ...). Run-side state was just reset, so the ctx is
    -- catalog-only here. GrindState:enter will rebuild the pool with
    -- the freshly seeded specs.
    local meta_ctx = state:computeEffects(
        self.game.effects, self.game.catalog, self.game.run_upgrades)
    state:applyStartingPerks(meta_ctx)
    self.catalog_modal = nil

    if Decks.systemUnlocked(state) then
        self.deck_select_modal = DeckSelectModal:new(self.game)
        return
    end

    self:_finalizePostBustReturn()
end

-- Step 3 of the post-bust flow (DECKS only): deck-select modal closes,
-- control returns to grind. State is already reset + perks applied at
-- this point — this only finalises bookkeeping and switches.
function ShoveState:_dismissDeckSelectAndReturn()
    self.deck_select_modal = nil
    self:_finalizePostBustReturn()
end

-- Shared tail of the post-bust flow. Called from either the catalog
-- dismiss (when DECKS is off) or the deck-select dismiss. Resets the
-- per-shove transient state and switches back to grind.
function ShoveState:_finalizePostBustReturn()
    FlightSystem.clear()
    self.gauntlet       = nil
    self.catalog_modal  = nil
    self.deck_select_modal = nil
    self._ended_handled = false
    self.view:resetTimeline()
    self.game.state_machine:switch("grind")
end

function ShoveState:update(dt)
    self.view:update(dt)

    -- Buildup just finished — kick off the actual gauntlet. The view
    -- transitions to "running" and its existing card-cinematic
    -- timeline takes over.
    if self.view:isReadyToDeal() and not self.gauntlet then
        self.view:markRunning()
        self:_beginGauntlet()
        return
    end

    -- After the cinematic finishes, fire the prestige flow once. No-op if
    -- already handled, mid-animation, no gauntlet, or any modal is showing.
    if self.gauntlet
       and self.gauntlet.state == "finished"
       and not self.view:isAnimating()
       and not self._ended_handled
       and not self.deck_select_modal
       and not self.prototype_end_modal then
        self:_onGauntletEnded()
    end
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
    if self.prototype_end_modal then
        self.prototype_end_modal:draw()
    elseif self.catalog_modal then
        self.catalog_modal:draw()
    elseif self.deck_select_modal then
        self.deck_select_modal:draw()
    end
    if self.settings_modal then
        self.settings_modal:draw()
    end
end

function ShoveState:keypressed(key)
    -- Settings modal sits on top of everything (ESC overlay).
    -- consumeKey returns true when an internal overlay handles a key;
    -- only top-level ESC falls through and signals the host to close.
    if self.settings_modal then
        if self.settings_modal:consumeKey(key) then return end
        if key == "escape" then self:closeSettings() end
        return
    end
    -- Modals consume input first; sequence is prototype-end →
    -- prestige → catalog → grind.
    if self.prototype_end_modal then
        self.prototype_end_modal:consumeKey(key)
        local r = self.prototype_end_modal:resolved()
        if r then self:_resolvePrototypeEnd(r) end
        return
    end
    if self.catalog_modal then
        if self.catalog_modal:consumeKey(key) then return end
        if key == "space" or key == "return" or key == "kpenter" then
            if self.view:isHolding() then self.view:advance()
            else self:_dismissCatalogAndReturn() end
            return
        end
    end
    if self.deck_select_modal and self.deck_select_modal:consumeKey(key) then
        if self.deck_select_modal:resolved() then
            self:_dismissDeckSelectAndReturn()
        end
        return
    end
    -- ESC with no modal up: open the settings modal (no stacked quit confirm —
    -- it carries its own Quit row and closes on a second ESC).
    if key == "escape" then
        self:openSettings()
        return
    end

    -- SPACE during the cinematic = "skip" (continue semantic). That
    -- stays in every build. The other branches (re-deal a finished
    -- gauntlet, R reset, [/] catalog nudge, D overlay toggle) are
    -- debug hotkeys gated on FEATURES.DEV_HOTKEYS.
    if key == "space" then
        -- On a hold, SPACE is "continue". Otherwise it fast-forwards to the
        -- next hold. Either way it never falls through to the dev re-deal.
        if self.view:isHolding() then self.view:advance(); return end
        if self.view:isAnimating() then
            self.view:skip()
            return
        end
    end

    if not Constants.FEATURES.DEV_HOTKEYS then return end

    if key == "space" then
        if not self.gauntlet or self.gauntlet.state == "finished" then
            self:_beginGauntlet()
        end

    elseif key == "r" then
        if isShiftDown() then
            self.overlay:resetStats()
            print("[shove] stats cleared")
        else
            self.gauntlet       = nil
            self._ended_handled = false
            self.view:resetTimeline()
            print("[shove] gauntlet reset (press SPACE to deal a new one)")
        end

    elseif key == "[" or key == "]" then
        -- Debug: nudge the catalog base ±5% and recompute the rate struct.
        -- Bypasses the live ctx so dev can sweep rates without buying items.
        local delta = (key == "]") and 0.05 or -0.05
        local cur_base = (self.shove_rates and self.shove_rates.catalog) or 0
        local new_base = clamp(cur_base + delta, 0, 1)
        local bankroll = self.shove_rates and self.shove_rates.bankroll or 0
        self.shove_rates = ShoveRate.computeFromBase(new_base, bankroll)
        local r = self.shove_rates
        print(string.format(
            "[shove] catalog=%.2f mult=%.2f  →  r1=%.2f r2=%.2f r3=%.2f clear=%.2f%%",
            r.catalog, r.mult, r.r1, r.r2, r.r3, r.clear * 100))

    elseif key == "d" then
        self.overlay.visible = not self.overlay.visible
    end
end

function ShoveState:mousepressed(mx, my, button)
    -- Settings modal owns input first (ESC overlay).
    if self.settings_modal then
        local consumed = self.settings_modal:consumeMouse(mx, my, button)
        if not consumed then self:closeSettings() end
        return
    end
    -- Prototype-end modal sits above the post-bust flow.
    if self.prototype_end_modal then
        self.prototype_end_modal:consumeMouse(mx, my, button)
        local r = self.prototype_end_modal:resolved()
        if r then self:_resolvePrototypeEnd(r) end
        return
    end
    -- Prestige modal: click Continue to advance to catalog.
    -- Catalog modal owns mouse input while open — clicks land on item
    -- cards, not on the underlying shove view. The Continue button at
    -- the bottom resolves the modal so the host can advance.
    if self.catalog_modal then
        -- CONTINUE works whether the book is open or closed, so it is
        -- tested before the book gets the click.
        if self.view:hitContinue(mx, my) then
            ClickFlash.flash("continue_btn", "continue_btn")
            self.view:advance()
            return
        end
        if self.catalog_modal:consumeMouse(mx, my, button) then return end
        if self.catalog_modal:resolved() then
            self:_dismissCatalogAndReturn()
            return
        end
        -- A stray click on the felt does nothing.
        return
    end
    -- Deck-select modal: post-catalog. Tile clicks dispatch through
    -- state:setActiveDeck; Continue resolves the modal.
    if self.deck_select_modal then
        self.deck_select_modal:consumeMouse(mx, my, button)
        if self.deck_select_modal:resolved() then
            self:_dismissDeckSelectAndReturn()
        end
        return
    end
    -- No modal. On a hold only the CONTINUE button advances; a stray click
    -- on the felt does nothing. During the deal a click fast-forwards.
    if self.view:isHolding() then
        if self.view:hitContinue(mx, my) then
            ClickFlash.flash("continue_btn", "continue_btn")
            self.view:advance()
        end
    elseif self.view:isAnimating() then
        self.view:skip()
    end
end

function ShoveState:mousemoved(x, y, _, _)
    if self.settings_modal and self.settings_modal.mousemoved then
        self.settings_modal:mousemoved(x, y)
    end
end

function ShoveState:mousereleased(x, y, b)
    if self.settings_modal and self.settings_modal.mousereleased then
        self.settings_modal:mousereleased(x, y, b)
    end
end

function ShoveState:wheelmoved(dx, dy)
    if self.settings_modal and self.settings_modal.wheelmoved then
        self.settings_modal:wheelmoved(dx, dy)
        return
    end
    -- Forward scroll wheel to the catalog modal so a catalog longer than
    -- the viewport can be browsed.
    if self.catalog_modal and self.catalog_modal.wheelmoved then
        self.catalog_modal:wheelmoved(dx, dy)
    end
end

return ShoveState
