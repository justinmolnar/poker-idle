-- controllers/GrindController.lua
--
-- Sits between GrindState and the model layer. Owns the TablePool, applies
-- per-tick resolutions to bankroll, tracks peak_bankroll, and routes
-- floating-text emission. Validates and applies purchase intents from the
-- view (run-upgrade and catalog buys).
--
-- The view doesn't mutate state directly — it dispatches intents to this
-- controller. Effects context is cached and only recomputed when an item is
-- bought or run state changes (cheap, since we're not doing it per-frame).

local TablePool   = require("models.TablePool")
local Catalog     = require("data.catalog")
local RunUpgrades = require("data.run_upgrades")
local Stakes      = require("data.stakes")
local Constants   = require("data.constants")

local function findStake(id)
    for _, s in ipairs(Stakes) do
        if s.id == id then return s end
    end
end

local GrindController = {}
GrindController.__index = GrindController

function GrindController:new(game)
    local self = setmetatable({ game = game }, GrindController)
    self.pool = TablePool:new(game.state)
    self:invalidateEffects()
    return self
end

-- Recompute the effects context from the player's owned items + run upgrades.
-- Called on construction and after any purchase / prestige reset.
function GrindController:invalidateEffects()
    self.ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades)
end

function GrindController:tableSlotsCap()
    local extra = (self.ctx and self.ctx.table_slots) or 0
    local cap   = 1 + extra
    if cap > Constants.GAMEPLAY.MAX_TABLES then cap = Constants.GAMEPLAY.MAX_TABLES end
    return cap
end

function GrindController:update(dt)
    -- Snapshot per-table state BEFORE the pool ticks so we can detect
    -- transitions afterwards and play the right sound on each.
    local prev_states = {}
    for i, t in ipairs(self.pool.tables) do
        prev_states[i] = t.state
    end

    local resolutions = self.pool:update(dt, self.ctx)

    -- Sound triggers on state transitions.
    for i, t in ipairs(self.pool.tables) do
        local prev = prev_states[i]
        if prev and prev ~= t.state then
            self:_playStateTransitionSound(prev, t.state, t)
        end
    end

    if #resolutions == 0 then return end

    local state = self.game.state
    for _, r in ipairs(resolutions) do
        state.bankroll = state.bankroll + r.delta
        if state.bankroll > state.peak_bankroll then
            state.peak_bankroll = state.bankroll
        end
        -- Bankroll can dip below zero on bad streaks — that's fine. Tables
        -- keep ticking; recovery is part of the loop.

        local label
        if r.delta >= 0 then
            label = string.format("+$%.2f", r.delta)
        else
            label = string.format("-$%.2f", -r.delta)
        end
        self.game.floating_text.emit(label, r.x, r.y)

        -- PP-bounty: first won hand at this stake this run awards the
        -- stake's pp_award. Locked in until prestige clears it. Losing
        -- hands and subsequent wins at the same stake do nothing.
        if r.delta > 0 then
            local tbl = self.pool.tables[r.table_idx]
            if tbl and not state.stakes_won_this_run[tbl.stake_id] then
                state.stakes_won_this_run[tbl.stake_id] = true
                local stake = findStake(tbl.stake_id)
                local award = stake and stake.pp_award or 0
                if award > 0 then
                    state.pp          = state.pp          + award
                    state.pp_this_run = state.pp_this_run + award
                    self.game.floating_text.emit(
                        string.format("+%d PP", award),
                        r.x, (r.y or 0) - 28)
                end
            end
        end
    end
end

-- ─── Purchase intents (called from view button handlers) ─────────────────────

function GrindController:buyRunUpgrade(upgrade_id)
    local state = self.game.state
    -- Already owned?
    for _, owned in ipairs(state.run_upgrade_ids) do
        if owned == upgrade_id then return false end
    end
    -- Find by id.
    local upgrade
    for _, u in ipairs(RunUpgrades) do
        if u.id == upgrade_id then upgrade = u; break end
    end
    if not upgrade then return false end
    if state.bankroll < upgrade.cost then return false end
    state.bankroll = state.bankroll - upgrade.cost
    state.run_upgrade_ids[#state.run_upgrade_ids + 1] = upgrade_id
    self:invalidateEffects()
    return true
end

function GrindController:buyCatalogItem(item_id)
    local state = self.game.state
    for _, owned in ipairs(state.owned_items) do
        if owned == item_id then return false end
    end
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    if not item then return false end
    if state.pp < item.cost_pp then return false end
    state.pp = state.pp - item.cost_pp
    state.owned_items[#state.owned_items + 1] = item_id
    self:invalidateEffects()
    return true
end

function GrindController:addTable(stake_id)
    if self.pool:count() >= self:tableSlotsCap() then return false end
    self.pool:addTable(stake_id)
    return true
end

function GrindController:removeTable(idx)
    if self.pool:count() <= 1 then return false end  -- always keep at least one
    self.pool:removeTable(idx)
    return true
end

function GrindController:changeTableStake(idx, new_stake_id)
    self.pool:changeStake(idx, new_stake_id)
    return true
end

-- Click-to-deal entry point. Triggers the per-hand state machine on a
-- specific table. Returns false if the table is already animating a hand
-- or doesn't exist.
function GrindController:dealHand(idx)
    local t = self.pool:get(idx)
    if not t or t:isBusy() then return false end
    return t:deal(self.ctx)
end

-- Map per-hand state-machine transitions to sound names. Called from
-- update() with (prev_state, new_state, table). Tables share a single
-- audio queue (sounds clone-on-play), so multiple tables' transitions in
-- the same frame don't cut each other off.
function GrindController:_playStateTransitionSound(_prev, new_state, t)
    local sounds = self.game.sounds
    if not sounds or not sounds.playNamed then return end

    if new_state == "dealing" or new_state == "flop"
       or new_state == "turn" or new_state == "river" then
        sounds.playNamed("card_dealt")
    elseif new_state == "showdown" then
        sounds.playNamed("hole_card_flip")
    elseif new_state == "settling" then
        sounds.playNamed(t.outcome_won and "pot_won" or "pot_lost")
    end
end

-- Convenience: deal every idle table in one call. Useful as a future
-- "auto-play" upgrade hook and as a debug shortcut.
function GrindController:dealAll()
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if not t:isBusy() then
            if t:deal(self.ctx) then n = n + 1 end
        end
    end
    return n
end

return GrindController
