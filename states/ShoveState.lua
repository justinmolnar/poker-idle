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
local HoldPress = require("services.HoldPress")
local ShoveView          = require("views.ShoveView")
local Overlay            = require("views.ShoveDebugOverlay")
local CatalogModal       = require("views.CatalogModal")
local DeckFlyer          = require("views.DeckFlyer")
local ChipTake           = require("views.ChipTake")
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
        _ended_handled       = false,  -- guard so _onGauntletEnded fires once per gauntlet
    }, ShoveState)
    self.view    = ShoveView:new(game, self)
    self.overlay = Overlay:new(game, self)
    return self
end

function ShoveState:openSettings()
    if not self.settings_modal then
        self.settings_modal = SettingsModal:new(self.game)
        require("services.SoundService").playNamed("modal_open")
    end
end

function ShoveState:closeSettings()
    if self.settings_modal then require("services.SoundService").playNamed("modal_close") end
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
        self.game.save()
    end
    self._settled = false

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
    -- Copied before shuffling: countedItems hands back a cached list that
    -- the room screen's counter also reads, and shuffling it in place would
    -- reorder someone else's data.
    local source = self.game.state:countedItems(Catalog)
    local ids = {}
    for i = 1, #source do ids[i] = source[i] end
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
-- settings is a menu.
function ShoveState:hintsBlocked()
    return self.settings_modal ~= nil
end

function ShoveState:_beginGauntlet()
    HandAnalytics.recordShoveStart(self.shove_rates)
    local pending = self.game.state.shove_pending
    self.gauntlet = Gauntlet:new(self.game, self.shove_rates)
    -- The outcomes were rolled and persisted at :enter (shove_pending);
    -- the gauntlet just constructs cards for them. nil on the debug
    -- entries, where begin rolls its own.
    local result = self.gauntlet:begin(pending and pending.outcomes)
    -- One settle per gauntlet, not per visit: the debug re-roll (F2) runs
    -- a second one without leaving the screen.
    self._settled = false
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

-- Bank the shove and start the next run, once per gauntlet.
--
-- Called from the cinematic's settle beat (views/ShoveView), which sits
-- right after the summary — the moment the player has seen the result.
-- Everything the run owed is already decided by then: the chips were
-- banked into the meta when the shove was committed
-- (GrindController:initiateShove) and the gauntlet evaluated its whole
-- result synchronously at :begin. So this records what happened, resets
-- the run, and saves.
--
-- The starting perks do NOT run here. They must come after the catalog
-- browse the cinematic is about to open, because an item bought there
-- seeds the run it was bought for. `perks_pending` marks the debt;
-- whoever reaches it first (the catalog dismissal, the credits, or the
-- next grind entry if the player quits) pays it.
function ShoveState:settleRun()
    if self._settled then return end
    local state  = self.game.state
    local result = self.gauntlet and self.gauntlet.result
    if not result then return end
    self._settled = true

    -- What the shove banked, kept where the summary lines and the
    -- analytics can still read it after shove_pending is gone.
    local pending = state.shove_pending
    state.last_shove = {
        chips      = (pending and pending.chips) or 0,
        anti_chips = (pending and pending.anti_chips) or 0,
        won        = result.won == true,
        busted_at  = result.busted_at,
    }
    self:_recordActFlags()
    if result.won then state.cleared = true end
    -- The demo's ending. Its R1 win opens nothing (the act flags stay
    -- unrecorded, R2 is forced lost: models/shove_rate), but it ends the
    -- demo: from here the flyer lands with the ending inside (throwFlyer).
    if Constants.FEATURES.DEMO_CUT and result.outcomes and result.outcomes[1] == true and not result.won then
        state.demo_ended = true
    end

    state:resetRun()             -- clears shove_pending
    state.perks_pending = true
    if self.game.grind then self.game.grind:reloadPool() end
    self.game.save()
end

-- The act flags, from the gauntlet's result: R1 won opens Act 2 (decks,
-- mid stakes), R2 won opens Act 3. Called once, from the settle, which
-- runs at the summary beat — before the deck flyer is thrown, so
-- Decks.systemUnlocked is already true when it lands. Returns true when a
-- flag changed.
function ShoveState:_recordActFlags()
    local result = self.gauntlet and self.gauntlet.result
    local state  = self.game.state
    if not (result and result.outcomes) or Constants.FEATURES.DEMO_CUT then return false end
    local changed = false
    if result.outcomes[1] == true and not state.shove_r1_won then
        state.shove_r1_won = true
        changed = true
        print("[shove] Won Runout 1 of the gauntlet: unlocked Act 2!")
    end
    if result.outcomes[2] == true and not state.shove_r2_won then
        state.shove_r2_won = true
        changed = true
        print("[shove] Won Runout 2 of the gauntlet: unlocked Act 3!")
    end
    if changed then self._act_flags_changed = true end
    return changed
end

function ShoveState:_onGauntletEnded()
    self._ended_handled = true
    local result = self.gauntlet.result
    local state  = self.game.state

    -- Chips aren't computed at bust anymore. They were banked into
    -- state.chips at the shove commit, and the settle moved the count to
    -- last_shove (shove_pending is gone by now; its absence is what stops
    -- a reload routing back into a finished gauntlet).
    local chips_banked = (state.last_shove and state.last_shove.chips)
                         or (state.shove_pending and state.shove_pending.chips)
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
    -- The act flags and the run reset both happened at the settle beat,
    -- back at the summary, along with the save. Nothing here writes
    -- progress: this is the click that dismisses the felt. The call is a
    -- no-op unless the timeline was skipped past its settle.
    --
    -- (Under DEMO_CUT the flags are never recorded at all: the gauntlet
    -- stays Act 1 shaped forever, R2 is forced lost, every R1 win repeats
    -- the same cliffhanger, and nothing downstream unlocks. The flyer
    -- that lands after it is the demo's ending: state.demo_ended.)
    self:settleRun()

    if result.won then
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
        if self.view and not self.view.take then self:throwChips() end
        self:_dismissCatalogAndReturn()
    end
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

-- The dealer throws the run's chips onto the felt, one per chip banked,
-- before the book (views/ChipTake). Called by the view as a timeline
-- beat with the BANKED line's rect to stay clear of and the pour's tumble
-- preset. A resumed shove replays from the buildup, so the beat simply
-- fires again; nothing here to restore.
function ShoveState:throwChips(summary_rect, preset)
    local view = self.view
    if not view or view.take then return end
    local n = view.chips_banked or 0
    if n <= 0 then return end
    local W, H = love.graphics.getDimensions()
    -- Clear of the BANKED line, the book and the flyer (both have their
    -- spots before they land; the beat fires after both throws).
    local avoid = { summary_rect }
    if self.catalog_modal and self.catalog_modal.feltRect then
        avoid[#avoid + 1] = self.catalog_modal:feltRect(W, H)
    end
    if self.deck_flyer and self.deck_flyer.feltRect then
        avoid[#avoid + 1] = self.deck_flyer:feltRect(W, H)
    end
    view.take = ChipTake.begin(n, "take:" .. tostring(self:_nextThrowId()),
                               W, H, self.game.ui_scale or 1, avoid, preset)
end

-- The dealer throws the deck flyer after the book, once decks exist. It
-- lands clear of the book (the book's resting rect is known ahead of its
-- landing) and starts folded. Only the felt's CONTINUE leaves.
--
-- In the demo decks never exist; the flyer lands once the demo has ended
-- (settleRun) and its inside is the demo's ending (views/DeckFlyer, demo).
function ShoveState:throwFlyer()
    if self.deck_flyer then return end
    local state = self.game.state
    local demo  = Constants.FEATURES.DEMO_CUT and state.demo_ended == true
    if not (demo or Decks.systemUnlocked(state)) then return end
    local W, H = love.graphics.getDimensions()
    self.deck_flyer = DeckFlyer:new(self.game, {
        on_felt   = true, scrim = false, demo = demo,
        throw_key = "flyer:" .. tostring(self:_nextThrowId()),
        avoid     = self.catalog_modal and self.catalog_modal:feltRect(W, H) or nil,
    })
    -- The pamphlet slapping down on the felt.
    SoundService.playNamed("flyer_slap")
end

-- A different key every throw, persisted so it keeps varying across
-- sessions. Its own field: it used to live in hints_seen as a number
-- among booleans, which made that map impossible to type.
function ShoveState:_nextThrowId()
    local state = self.game.state
    local n = (tonumber(state.catalog_throws) or 0) + 1
    state.catalog_throws = n
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
    -- The run was reset and saved at the settle beat. What is owed now is
    -- the starting perks, and they wait until here on purpose: an item
    -- bought on the book that just closed (Pocket Cash, Free Sit) seeds
    -- the run it was bought for.
    self:settleRun()
    if self.game.grind then self.game.grind:applyPendingPerks() end
    self.game.save()
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
       and not self._ended_handled then
        self:_onGauntletEnded()
    end
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
    if self.catalog_modal or self.deck_flyer then
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
    -- Modals consume input first; sequence is prestige → catalog → grind.
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
            -- Held, not clicked (services/HoldPress).
            HoldPress.begin("continue", function()
                ClickFlash.press("continue_btn", "continue_btn")
                self:_continueFromHold()
            end, function(px, py) return self.view:hitContinue(px, py) end)
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
            HoldPress.begin("continue", function()
                ClickFlash.press("continue_btn", "continue_btn")
                self.view:advance()
            end, function(px, py) return self.view:hitContinue(px, py) end)
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
