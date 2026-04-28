-- states/ShoveState.lua
--
-- Shove mode: the all-in gauntlet. Owns the live Gauntlet model (one per
-- shove attempt), the always-on debug overlay, and a debug-mutable
-- `shove_rate` seeded from the player's computed effects on enter.
--
-- Phase B wiring: pressing SPACE rolls a fresh gauntlet synchronously and
-- records the result on the overlay. Cinematic per-card reveal lands in
-- Phase D.

local Theme        = require("views.Theme")
local ShoveView    = require("views.ShoveView")
local Overlay      = require("views.ShoveDebugOverlay")
local Gauntlet     = require("models.Gauntlet")
local Catalog      = require("data.catalog")
local RunUpgrades  = require("data.run_upgrades")
local Constants    = require("data.constants")

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
        game        = game,
        shove_rate  = 0,            -- debug-mutable; reseeded on enter
        gauntlet    = nil,
    }, ShoveState)
    self.view    = ShoveView:new(game, self)
    self.overlay = Overlay:new(game, self)
    return self
end

function ShoveState:enter()
    Theme.setActive("shove")
    -- Seed shove_rate from the player's currently-owned items + run upgrades.
    -- Catalog/run_upgrades are passed in (instead of required inside the
    -- model) so GameState stays testable without globals.
    local ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades)
    self.shove_rate = ctx.shove_rate or 0
end

function ShoveState:exit() end

function ShoveState:update(dt)
    self.view:update(dt)
end

function ShoveState:draw()
    self.view:draw()
    self.overlay:draw()
end

function ShoveState:keypressed(key)
    if key == "space" then
        -- Begin a new gauntlet. If one is already finished, replace it.
        if not self.gauntlet or self.gauntlet.state == "finished" then
            self.gauntlet = Gauntlet:new(self.game, self.shove_rate)
            local result = self.gauntlet:begin()
            self.overlay:recordAttempt(result)

            -- Console echo for hand-verification. The HUD has the live
            -- aggregate; this dump is the copy-pasteable record per attempt.
            print(Gauntlet.formatResult(result, self.overlay.attempts))
            print(string.format("  ↳ session: %d/%d wins (%.1f%%, expected %.1f%%)",
                self.overlay.wins, self.overlay.attempts,
                100 * self.overlay.wins / math.max(1, self.overlay.attempts),
                100 * (self.shove_rate ^ 3)))
        end

    elseif key == "r" then
        if isShiftDown() then
            self.overlay:resetStats()
            print("[shove] stats cleared")
        else
            self.gauntlet = nil
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
