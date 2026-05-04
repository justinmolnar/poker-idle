-- states/ShoveState.lua
--
-- Shove mode: the all-in gauntlet. Owns the live Gauntlet model (one per
-- shove attempt), the always-on debug overlay, the per-shove debug-mutable
-- `shove_rates` struct (r1/r2/r3/clear) seeded from the player's computed
-- effects on enter, and the prestige flow that fires when a gauntlet
-- finishes:
--
--   • Gauntlet busts (any runout LOSS) → award PP based on peak_bankroll,
--     show the PrestigeModal. SPACE dismisses it and opens the
--     CatalogModal. SPACE again dismisses the catalog → resetRun → grind.
--   • Gauntlet clears (3 of 3 runouts WON) → award PP, set state.cleared,
--     switch to CreditsState. The win-condition path.
--
-- The state auto-starts a gauntlet on enter when none exists. Switching to
-- this state via the SHOVE button (or F2 from grind for testing) just plays
-- the gauntlet. SPACE during animation skips the cinematic.

local Theme         = require("views.Theme")
local ShoveView     = require("views.ShoveView")
local Overlay       = require("views.ShoveDebugOverlay")
local PrestigeModal = require("views.PrestigeModal")
local CatalogModal  = require("views.CatalogModal")
local Gauntlet      = require("models.Gauntlet")
local Catalog       = require("data.catalog")
local RunUpgrades   = require("data.run_upgrades")
local Constants     = require("data.constants")
local ShoveRate     = require("models.shove_rate")

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
        prestige_modal  = nil,    -- bust step 1: run-end summary
        catalog_modal   = nil,    -- bust step 2: post-run PP shop
        _ended_handled  = false,  -- guard so _onGauntletEnded fires once per gauntlet
    }, ShoveState)
    self.view    = ShoveView:new(game, self)
    self.overlay = Overlay:new(game, self)
    return self
end

-- Wipe all per-shove transient state. Called by the F6/F7 debug hotkeys
-- (reload-from-disk and wipe-saves) so a stale gauntlet from before the
-- reload doesn't pop back when the player next enters shove.
function ShoveState:fullReset()
    self.gauntlet       = nil
    self.prestige_modal = nil
    self.catalog_modal  = nil
    self._ended_handled = false
    self.view:resetTimeline()
    self.overlay:resetStats()
end

function ShoveState:enter()
    Theme.setActive("shove")
    -- Lock in the shove rate from the current catalog ctx + bankroll
    -- snapshot. This is the freeze moment — once the gauntlet begins,
    -- mutating bankroll doesn't affect rolls. Catalog purchases between
    -- shoves count toward the next attempt because computeEffects
    -- rebuilds ctx fresh each :enter.
    local state = self.game.state
    local ctx = state:computeEffects(self.game.effects, Catalog, RunUpgrades)
    self.shove_rates = ShoveRate.compute(ctx, state.bankroll or 0)

    -- Auto-start a gauntlet on entry when none is active. Carries the
    -- player straight into the cinematic instead of requiring SPACE.
    if not self.gauntlet then
        self:_beginGauntlet()
    end
end

function ShoveState:exit() end

function ShoveState:_beginGauntlet()
    self.gauntlet = Gauntlet:new(self.game, self.shove_rates)
    local result = self.gauntlet:begin()
    self.overlay:recordAttempt(result)
    self.view:onGauntletBegin()
    self._ended_handled = false

    -- Console echo for hand-verification. The HUD has the live aggregate;
    -- this dump is the copy-pasteable record per attempt.
    print(Gauntlet.formatResult(result, self.overlay.attempts))
    print(string.format("  ↳ session: %d/%d wins (%.1f%%, expected %.1f%%)",
        self.overlay.wins, self.overlay.attempts,
        100 * self.overlay.wins / math.max(1, self.overlay.attempts),
        100 * (self.shove_rates and self.shove_rates.clear or 0)))
end

function ShoveState:_onGauntletEnded()
    self._ended_handled = true
    local result = self.gauntlet.result
    local state  = self.game.state

    -- PP isn't computed at bust anymore. It was banked into state.pp during
    -- the run via GrindController on each first-win-at-stake. The modal just
    -- reads state.pp_this_run for the display total.
    local pp_banked = state.pp_this_run or 0

    if result.won then
        state.cleared = true
        -- No auto-save. F5 to commit progress to disk.
        self.prestige_modal = nil
        self.gauntlet = nil
        self.view:resetTimeline()
        self.game.state_machine:switch("credits")
    else
        self.prestige_modal = PrestigeModal:new(
            self.game, state.peak_bankroll, pp_banked, result.busted_at)
        -- No auto-save. PP is in memory only until F5.
    end
end

-- Step 1 of the post-bust flow: prestige summary modal closes, catalog
-- modal opens. Run state stays put — the player still has their
-- pp_this_run banked to state.pp at this point and can spend it.
function ShoveState:_advanceToCatalog()
    self.prestige_modal = nil
    self.catalog_modal  = CatalogModal:new(self.game)
end

-- Step 2 of the post-bust flow: catalog modal closes, run resets, control
-- returns to grind. New owned_items (Poker Poster + whatever was bought)
-- propagate via computeEffects → applyStartingPerks.
function ShoveState:_dismissCatalogAndReturn()
    local state = self.game.state
    state:resetRun()
    -- Apply meta-progression perks owned in the catalog (Pocket Cash,
    -- Free Sit, ...). Run-side state was just reset, so the ctx is
    -- catalog-only here. GrindState:enter will rebuild the pool with
    -- the freshly seeded specs.
    local meta_ctx = state:computeEffects(
        self.game.effects, self.game.catalog, self.game.run_upgrades)
    state:applyStartingPerks(meta_ctx)
    -- No auto-save. The reset run state lives in memory only until F5.
    self.gauntlet       = nil
    self.prestige_modal = nil
    self.catalog_modal  = nil
    self._ended_handled = false
    self.view:resetTimeline()
    self.game.state_machine:switch("grind")
end

function ShoveState:update(dt)
    self.view:update(dt)

    -- After the cinematic finishes, fire the prestige flow once. No-op if
    -- already handled, mid-animation, no gauntlet, or any modal is showing.
    if self.gauntlet
       and self.gauntlet.state == "finished"
       and not self.view:isAnimating()
       and not self._ended_handled
       and not self.prestige_modal
       and not self.catalog_modal then
        self:_onGauntletEnded()
    end
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
    if self.prestige_modal then
        self.prestige_modal:draw()
    elseif self.catalog_modal then
        self.catalog_modal:draw()
    end
end

function ShoveState:keypressed(key)
    -- Modals consume input first; sequence is prestige → catalog → grind.
    if self.prestige_modal and self.prestige_modal:consumeKey(key) then
        self:_advanceToCatalog()
        return
    end
    if self.catalog_modal and self.catalog_modal:consumeKey(key) then
        self:_dismissCatalogAndReturn()
        return
    end

    if key == "space" then
        if self.view:isAnimating() then
            self.view:skip()
        elseif not self.gauntlet or self.gauntlet.state == "finished" then
            -- Manual restart path (mostly used during dev / debugging via
            -- the [/] hotkeys). The auto-start in :enter handles the
            -- player-triggered SHOVE flow.
            self:_beginGauntlet()
        end

    elseif key == "r" then
        if isShiftDown() then
            self.overlay:resetStats()
            print("[shove] stats cleared")
        else
            self.gauntlet       = nil
            self.prestige_modal = nil
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
    -- Catalog modal owns mouse input while open — clicks land on item
    -- cards, not on the underlying shove view.
    if self.catalog_modal then
        self.catalog_modal:consumeMouse(mx, my, button)
    end
end

function ShoveState:wheelmoved(dx, dy)
    -- Forward scroll wheel to the catalog modal so a catalog longer than
    -- the viewport can be browsed.
    if self.catalog_modal and self.catalog_modal.wheelmoved then
        self.catalog_modal:wheelmoved(dx, dy)
    end
end

return ShoveState
