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
local Constants   = require("data.constants")

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
    local resolutions = self.pool:update(dt, self.ctx)
    if #resolutions == 0 then return end

    local state = self.game.state
    for _, r in ipairs(resolutions) do
        state.bankroll = state.bankroll + r.delta
        if state.bankroll > state.peak_bankroll then
            state.peak_bankroll = state.bankroll
        end
        -- Bankroll can dip below zero on bad streaks — that's fine; a few
        -- losing hands at NL10 can drop a fresh player into the red. Tables
        -- keep ticking; recovery is part of the loop.

        local label
        if r.delta >= 0 then
            label = string.format("+$%.2f", r.delta)
        else
            label = string.format("-$%.2f", -r.delta)
        end
        self.game.floating_text.emit(label, r.x, r.y)
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

return GrindController
