-- states/ShoveState.lua
--
-- Shove mode: the all-in gauntlet. Owns the live Gauntlet model (one per
-- shove attempt), the always-on debug overlay, the per-shove debug-mutable
-- `shove_rate` seeded from the player's computed effects on enter, and the
-- prestige flow that fires when a gauntlet finishes:
--
--   • Gauntlet busts (any runout LOSS) → award PP based on peak_bankroll,
--     show the PrestigeModal, SPACE to dismiss → resetRun → switch to grind.
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
local Gauntlet      = require("models.Gauntlet")
local Catalog       = require("data.catalog")
local RunUpgrades   = require("data.run_upgrades")
local Constants     = require("data.constants")

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
        shove_rate      = 0,
        gauntlet        = nil,
        prestige_modal  = nil,    -- non-nil during the bust → dismiss flow
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
    self._ended_handled = false
    self.view:resetTimeline()
    self.overlay:resetStats()
end

function ShoveState:enter()
    Theme.setActive("shove")
    -- Reseed shove_rate from current effects every enter (catalog purchases
    -- between shoves count toward the next attempt).
    local ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades)
    self.shove_rate = ctx.shove_rate or 0

    -- Auto-start a gauntlet on entry when none is active. Carries the
    -- player straight into the cinematic instead of requiring SPACE.
    if not self.gauntlet then
        self:_beginGauntlet()
    end
end

function ShoveState:exit() end

function ShoveState:_beginGauntlet()
    self.gauntlet = Gauntlet:new(self.game, self.shove_rate)
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
        100 * (self.shove_rate ^ 3)))
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

function ShoveState:_dismissPrestigeAndReturn()
    local state = self.game.state
    state:resetRun()
    -- No auto-save. The reset run state lives in memory only until F5.
    self.gauntlet       = nil
    self.prestige_modal = nil
    self._ended_handled = false
    self.view:resetTimeline()
    self.game.state_machine:switch("grind")
end

function ShoveState:update(dt)
    self.view:update(dt)

    -- After the cinematic finishes, fire the prestige flow once. No-op if
    -- already handled, mid-animation, no gauntlet, or modal already showing.
    if self.gauntlet
       and self.gauntlet.state == "finished"
       and not self.view:isAnimating()
       and not self._ended_handled
       and not self.prestige_modal then
        self:_onGauntletEnded()
    end
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
    if self.prestige_modal then
        self.prestige_modal:draw()
    end
end

function ShoveState:keypressed(key)
    -- Modal consumes input first.
    if self.prestige_modal and self.prestige_modal:consumeKey(key) then
        self:_dismissPrestigeAndReturn()
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

    elseif key == "[" then
        self.shove_rate = clamp(self.shove_rate - 0.05, 0, 1)
        print(string.format("[shove] shove_rate=%.2f  (expected gauntlet clear: %.1f%%)",
            self.shove_rate, 100 * (self.shove_rate ^ 3)))

    elseif key == "]" then
        self.shove_rate = clamp(self.shove_rate + 0.05, 0, 1)
        print(string.format("[shove] shove_rate=%.2f  (expected gauntlet clear: %.1f%%)",
            self.shove_rate, 100 * (self.shove_rate ^ 3)))

    elseif key == "d" then
        self.overlay.visible = not self.overlay.visible
    end
end

function ShoveState:mousepressed(_, _, _) end

return ShoveState
