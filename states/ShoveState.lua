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
local DemoEndModal       = require("views.DemoEndModal")
local CatalogModal       = require("views.CatalogModal")
local DeckFlyer          = require("views.DeckFlyer")
local ConfirmDialog      = require("views.widgets.ConfirmDialog")
local SoundService       = require("services.SoundService")
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
        deck_flyer           = nil,    -- the deck flyer thrown beside the catalog (decks unlocked)
        _confirm             = nil,    -- the maxed-deck warning on CONTINUE
        _deck_warned         = false,  -- warned once this shove
        settings_modal       = nil,    -- ESC overlay (volume, display, save, quit)
        demo_end_modal       = nil,    -- the demo build's end-of-content screen
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
    self.deck_flyer          = nil
    self._confirm            = nil
    self._deck_warned        = false
    self.demo_end_modal = nil
    self.settings_modal      = nil
    self._ended_handled      = false
    self.view:resetTimeline()
    self.overlay:resetStats()
end

function ShoveState:enter()
    Theme.setActive("room")   -- one palette everywhere; the shove palette is retired
    local state = self.game.state

    -- All-in cash-out: every table's current stack returns to bankroll
    -- and the pool is cleared. The shove commits the player's total
    -- wealth, not just spendable bankroll — the buildup spectacle then
    -- visualizes those chips moving from stack to pot. Run only on a
    -- fresh gauntlet entry; if we're re-entering shove after a hot
    -- reload (F6 path) the gauntlet flag prevents a double cash-out.
    if not self.gauntlet and self.game.grind then
        -- Route through the controller's REAL close rules: a chip-stack
        -- tournament refunds $0 (its chips are tournament chips, not
        -- money — crediting t.stack 1:1 here converted a doubled-up KO
        -- stack straight into bankroll, a shove-to-cash exploit), and a
        -- settled one drains its payout first. force = every table closes
        -- this frame; the pool sync updates the save arrays itself.
        self.game.grind:cashOutAll(true)
    end

    -- Lock in the shove rate from the current catalog ctx + post-
    -- cashout bankroll. Catalog purchases between shoves count toward
    -- the next attempt because computeEffects rebuilds ctx fresh each
    -- :enter.
    local ctx = state:computeEffects(self.game.effects, Catalog, RunUpgrades)
    self.shove_rates = ShoveRate.compute(ctx, state.bankroll or 0)

    -- Commit the roll. The three runout outcomes are decided HERE — after
    -- the cash-out, so the rates they were rolled against are final — and
    -- ride the save inside shove_pending. From this write on, closing the
    -- game anywhere on the shove screen and reloading resumes the SAME
    -- shove with the SAME result: no close-and-retry, no reroll scumming.
    -- Already-rolled outcomes (a resumed shove) are left alone; the debug
    -- entries (F2, START_IN_SHOVE) have no shove_pending and keep the
    -- roll-at-deal behavior.
    if state.shove_pending and not state.shove_pending.outcomes then
        state.shove_pending.outcomes =
            Gauntlet.rollOutcomes(state, self.shove_rates)
        self.game.save_service:saveAll(
            state:serializeMeta(), state:serializeRun())
    end

    -- Auto-start the buildup spectacle on entry. The gauntlet itself
    -- doesn't begin until the view's buildup phase finishes (handled
    -- in :update — sees view:isReadyToDeal and fires _beginGauntlet).
    if not self.gauntlet then
        -- Nothing owned (the first shove): no room to count, so no room.
        -- The view goes straight to the buildup when it gets no room view;
        -- the empty room, and the room_* lines, wait until there is a room.
        local ids = self:_countedItems()
        if #ids == 0 then
            self.view:beginRoomCount(nil, ids, self.shove_rates)
        else
            self.view:beginRoomCount(self:_roomView(), ids, self.shove_rates)
        end
    end
end

-- The player's room, for the intro. RoomState owns the view; a harness
-- without a room state gets nil and the view skips straight to the felt.
function ShoveState:_roomView()
    local sm = self.game.state_machine
    local room = sm and sm.states and sm.states.room
    if room and room.getRoomView then return room:getRoomView() end
    return nil
end

-- The things you own (GameState:countedItems: the rule the room screen's
-- count shares), shuffled. #list is the BASE integer.
function ShoveState:_countedItems()
    local ids = self.game.state:countedItems(Catalog)
    -- A different order every shove: the room is counted, not read.
    local rnd = (love.math and love.math.random) or math.random
    for i = #ids, 2, -1 do
        local j = rnd(i)
        ids[i], ids[j] = ids[j], ids[i]
    end
    return ids
end

function ShoveState:exit() end

-- The catalog and deck select are teachable and stay open to hints;
-- settings is a menu and the prototype-end modal is a hard stop.
function ShoveState:hintsBlocked()
    return (self.settings_modal or self.demo_end_modal) ~= nil
end

function ShoveState:_beginGauntlet()
    HandAnalytics.recordShoveStart(self.shove_rates)
    local pending = self.game.state.shove_pending
    self.gauntlet = Gauntlet:new(self.game, self.shove_rates)
    -- The outcomes were rolled and persisted at :enter (shove_pending);
    -- the gauntlet just constructs cards for them. nil on the debug
    -- entries, where begin rolls its own.
    local result = self.gauntlet:begin(pending and pending.outcomes)
    self.overlay:recordAttempt(result)
    -- The act this shove opens, if any, is knowable NOW: the result is
    -- pre-baked. It used to be computed at the end, in the same statement
    -- that flipped the persistent flag, which meant the House could not
    -- react to it on the felt because by then the flag was already true.
    self._pending_milestone = self:_milestoneFor(result)
    self.view:onGauntletBegin(self._pending_milestone,
                              pending and pending.chips or 0)
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
    -- The demo records no act breaks: without this, every cliffhanger
    -- R1 win would replay the House's act-2 reaction on the felt.
    if Constants.FEATURES.DEMO_CUT then return nil end
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
    -- state.chips at the shove commit; shove_pending.chips remembers the
    -- amount for the readout (chips_this_run was zeroed at the commit).
    local chips_banked = (state.shove_pending and state.shove_pending.chips)
                         or 0
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
    -- The demo never records the act flags: the gauntlet stays Act 1
    -- shaped forever (R2 is never even rolled), every future R1 win
    -- repeats the same cliffhanger, and nothing downstream (act2 story
    -- beats, decks, mid/high stakes, act-gated catalog items) unlocks.
    local save_needed = false
    if result.outcomes and not Constants.FEATURES.DEMO_CUT then
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
    -- demo-end modal instead of the bust prestige flow. The
    -- player chooses Continue (resetRun + grind) or Exit to Title.
    if Constants.FEATURES.DEMO_CUT
       and not result.won
       and result.busted_at == 2
       and result.outcomes
       and result.outcomes[1] == true then
        self.demo_end_modal = DemoEndModal:new(self.game)
        return
    end

    if result.won then
        state.cleared = true
        -- The shove is resolved: drop the commit record so the save below
        -- can't route a later boot back into a finished gauntlet. The bust
        -- path leaves it for resetRun (quitting on the post-bust catalog
        -- resumes the same lost shove, not a fresh grind).
        state.shove_pending = nil
        -- Persist immediately: love.quit only saves from grind/shove, so
        -- quitting at the credits screen would otherwise lose the clear
        -- (and with it the deck-system unlock).
        self.game.save_service:saveAll(
            state:serializeMeta(), state:serializeRun())
        -- The last frame of the ending, so credits can fade in over the
        -- pile instead of cutting to a bare screen.
        local shot = self.view.snapshot and self.view:snapshot() or nil
        self.catalog_modal = nil
        self.gauntlet = nil
        self.view:resetTimeline()
        self.game.state_machine:switch("credits", { backdrop = shot })
    else
        -- The catalog was thrown onto the felt before the hold; the click
        -- that advanced the hold means "leave". If the throw never fired
        -- (skipped past), build it now so the shop is never missed.
        if not self.catalog_modal then self:throwCatalog() end
        if not self.deck_flyer then self:throwFlyer() end
        self:_dismissCatalogAndReturn()
    end
end

-- Demo-end resolution. "Continue Playing" routes through the
-- catalog (mirrors the standard post-bust flow — same chance to spend
-- banked chips before the next run starts). "Exit to Title" skips the
-- catalog and drops the player back at the start screen with their
-- current run reset.
function ShoveState:_resolveDemoEnd(choice)
    self.demo_end_modal = nil

    if choice == "exit" then
        local state = self.game.state
        state:resetRun()
        local meta_ctx = state:computeEffects(
            self.game.effects, self.game.catalog, self.game.run_upgrades)
        state:applyStartingPerks(meta_ctx)   -- silent: between screens
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
-- visit only (seen-flag set on dismiss).
function ShoveState:_catalogIntroPending()
    local seen = self.game.state.hints_seen
    return seen ~= nil
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

-- The dealer throws the deck flyer after the book, once decks exist. It
-- lands clear of the book (the book's resting rect is known ahead of its
-- landing) and starts folded. Only the felt's CONTINUE leaves.
function ShoveState:throwFlyer()
    if self.deck_flyer then return end
    if not Decks.systemUnlocked(self.game.state) then return end
    local W, H = love.graphics.getDimensions()
    self.deck_flyer = DeckFlyer:new(self.game, {
        on_felt   = true, scrim = false,
        throw_key = "flyer:" .. tostring(self:_nextThrowId()),
        avoid     = self.catalog_modal and self.catalog_modal:feltRect(W, H) or nil,
    })
    SoundService.playNamed("hole_card_flip")
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
    state:applyStartingPerks(meta_ctx)   -- silent: between screens
    self.catalog_modal = nil
    self:_finalizePostBustReturn()
end

-- Shared tail of the post-bust flow: the deck pick happened on the flyer
-- while the felt was still up, so there is no step after the book. Resets
-- the per-shove transient state and switches back to grind.
function ShoveState:_finalizePostBustReturn()
    FlightSystem.clear()
    self.gauntlet       = nil
    self.catalog_modal  = nil
    self.deck_flyer     = nil
    self._confirm       = nil
    self._deck_warned   = false
    self._ended_handled = false
    self.view:resetTimeline()
    self.game.state_machine:switch("grind")
end

function ShoveState:update(dt)
    -- A `pause` beat stops the shove's clock under the House's line: the
    -- buildup, the deal and the holds wait for the click.
    if self.game.sim_frozen then dt = 0 end
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
       and not self.demo_end_modal then
        self:_onGauntletEnded()
    end
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
    if self.demo_end_modal then
        self.demo_end_modal:draw()
    elseif self.catalog_modal or self.deck_flyer then
        -- Whatever is folded/closed sits on the felt; the open one draws
        -- last, on top of everything.
        local open_obj
        if self.catalog_modal then
            if self.catalog_modal:isOpen() then open_obj = self.catalog_modal
            else self.catalog_modal:draw() end
        end
        if self.deck_flyer then
            if self.deck_flyer:isOpen() then open_obj = self.deck_flyer
            else self.deck_flyer:draw() end
        end
        if open_obj then open_obj:draw() end
    end
    if self._confirm then
        self._confirm:draw(self.game.fonts)
        if self._confirm:resolved() then self._confirm = nil end
    end
    if self.settings_modal then
        self.settings_modal:draw()
    end
end

-- The object that is open on the felt, if any (only one ever is).
function ShoveState:_openObject()
    if self.deck_flyer and self.deck_flyer:isOpen() then return self.deck_flyer end
    if self.catalog_modal and self.catalog_modal:isOpen() then return self.catalog_modal end
    return nil
end

-- CONTINUE from the result hold. If the deck in play is maxed and another
-- deck could be levelling instead, ask once before leaving; "Change deck"
-- opens the flyer, "Leave anyway" goes.
function ShoveState:_continueFromHold()
    local state = self.game.state
    if not self._deck_warned and self.deck_flyer and Decks.systemUnlocked(state) then
        local active = Decks.specById(state.active_deck_id)
        local lvl    = active and state.deck_levels and state.deck_levels[active.id] or 0
        local maxed  = active and lvl >= (active.max_level or 5)
        local other  = false
        if maxed then
            for _, id in ipairs(state.unlocked_decks or {}) do
                local sp = Decks.specById(id)
                if sp and id ~= active.id and ((state.deck_levels and state.deck_levels[id]) or 0) < (sp.max_level or 5) then
                    other = true; break
                end
            end
        end
        if maxed and other then
            self._deck_warned = true
            self._confirm = ConfirmDialog:new{
                prompt        = active.name .. " is maxed and won't level again. Put another deck in play?",
                confirm_label = "Change deck",
                cancel_label  = "Leave anyway",
                on_confirm    = function()
                    if self.catalog_modal then self.catalog_modal:closeToFelt() end
                    self.deck_flyer:openFromFelt()
                end,
                on_cancel     = function() self.view:advance() end,
            }
            return
        end
    end
    self.view:advance()
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
    -- Modals consume input first; sequence is demo-end →
    -- prestige → catalog → grind.
    if self.demo_end_modal then
        self.demo_end_modal:consumeKey(key)
        local r = self.demo_end_modal:resolved()
        if r then self:_resolveDemoEnd(r) end
        return
    end
    if self._confirm then
        self._confirm:consumeKey(key)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end
    if self.catalog_modal or self.deck_flyer then
        local obj = self:_openObject() or self.catalog_modal
        if obj and obj:consumeKey(key) then
            if obj.resolved and obj:resolved() then self:_dismissCatalogAndReturn() end
            return
        end
        if key == "space" or key == "return" or key == "kpenter" then
            if self.view:isHolding() then self:_continueFromHold()
            else self:_dismissCatalogAndReturn() end
        end
        -- Swallow everything else: without this, ESC fell through and
        -- stacked Settings over the post-bust catalog, and dev keys reset
        -- the gauntlet underneath it.
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
    if button ~= 1 then return end
    -- Settings modal owns input first (ESC overlay).
    if self.settings_modal then
        local consumed = self.settings_modal:consumeMouse(mx, my, button)
        if not consumed then self:closeSettings() end
        return
    end
    -- Demo-end modal sits above the post-bust flow.
    if self.demo_end_modal then
        self.demo_end_modal:consumeMouse(mx, my, button)
        local r = self.demo_end_modal:resolved()
        if r then self:_resolveDemoEnd(r) end
        return
    end
    -- Prestige modal: click Continue to advance to catalog.
    -- Catalog modal owns mouse input while open — clicks land on item
    -- cards, not on the underlying shove view. The Continue button at
    -- the bottom resolves the modal so the host can advance.
    if self._confirm then
        self._confirm:consumeMouse(mx, my, button)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end
    if self.catalog_modal or self.deck_flyer then
        -- CONTINUE works whether the paper is open or closed, so it is
        -- tested before anything on the felt gets the click.
        if self.view:hitContinue(mx, my) then
            ClickFlash.flash("continue_btn", "continue_btn")
            self:_continueFromHold()
            return
        end
        -- The open one owns the click (dead space folds it back).
        local obj = self:_openObject()
        if obj then
            if obj:consumeMouse(mx, my, button) then return end
            if obj.resolved and obj:resolved() then self:_dismissCatalogAndReturn() end
            return
        end
        -- Both folded: the flyer landed last, so it is on top.
        if self.deck_flyer and self.deck_flyer:consumeMouse(mx, my, button) then return end
        if self.catalog_modal and self.catalog_modal:consumeMouse(mx, my, button) then return end
        if self.catalog_modal and self.catalog_modal:resolved() then
            self:_dismissCatalogAndReturn()
        end
        -- A stray click on the felt does nothing.
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
