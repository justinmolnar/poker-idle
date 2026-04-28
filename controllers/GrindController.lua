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

-- PP-bounty key: a (stake, game_type) combo locks one bounty per run.
-- 4 game types × 6 stakes = 24 distinct bounty slots — total ~84 PP for
-- a perfect climb across all combos.
local function bountyKey(stake_id, game_type_id)
    return stake_id .. ":" .. game_type_id
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

-- Maximum concurrent tables. The catalog no longer gates *how many* tables
-- you can open — it gates how many you can open *efficiently*. The hard cap
-- is the visual / sanity bound; the focus mechanic shapes the actual
-- viability curve via currentFocusMult().
function GrindController:tableSlotsCap()
    return Constants.GAMEPLAY.MAX_TABLES
end

-- Focus / efficiency penalty applied to every per-hand $ delta. See the
-- design discussion in the plan file. n_tables beyond capacity gets shaved
-- by base_penalty * penalty_reduce_mult, floored at FOCUS_FLOOR.
function GrindController:currentFocusMult()
    local n        = self.pool:count()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    local cap      = base_cap + ((self.ctx and self.ctx.focus_capacity) or 0)
    local reduce   = (self.ctx and self.ctx.focus_penalty_reduce_mult) or 1
    local penalty  = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * reduce
    local floor_v  = Constants.GAMEPLAY.FOCUS_FLOOR

    local extra = n - cap
    if extra <= 0 then return 1.0 end
    local mult = 1 - penalty * extra
    if mult < floor_v then mult = floor_v end
    return mult
end

-- Effective capacity for the UI — base + ctx bonus (no penalty math).
function GrindController:currentFocusCapacity()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    return base_cap + ((self.ctx and self.ctx.focus_capacity) or 0)
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

    local state      = self.game.state
    local focus_mult = self:currentFocusMult()
    for _, r in ipairs(resolutions) do
        -- Apply focus penalty to the actual $ delta — split attention
        -- means smaller wins and harsher relative losses. Floor in
        -- currentFocusMult prevents zero, so a tiny positive delta is
        -- still positive and counts as a win for the PP bounty.
        r.delta = r.delta * focus_mult

        -- Wins/losses land on the table's stack first. Above the 100bb
        -- cap (= stake.buy_in) the surplus spills to bankroll; below
        -- zero the loss clamps to whatever's actually on the table so
        -- the player can't go negative just from a brutal hand.
        local tbl   = self.pool.tables[r.table_idx]
        local stake = tbl and findStake(tbl.stake_id)
        local cap   = (stake and stake.buy_in) or 0
        if tbl then
            local new_stack = tbl.stack + r.delta
            if new_stack > cap then
                local overflow = new_stack - cap
                tbl.stack = cap
                state.bankroll = state.bankroll + overflow
            elseif new_stack < 0 then
                r.delta = -tbl.stack
                tbl.stack = 0
            else
                tbl.stack = new_stack
            end
        else
            -- Defensive fallback: no table found, route to bankroll
            -- with the same negative clamp.
            local new_bankroll = state.bankroll + r.delta
            if new_bankroll < 0 then
                r.delta = -state.bankroll
                new_bankroll = 0
            end
            state.bankroll = new_bankroll
        end

        local total_wealth = state.bankroll + self:tiedUp()
        if total_wealth > state.peak_bankroll then
            state.peak_bankroll = total_wealth
        end

        local label
        if r.delta >= 0 then
            label = string.format("+$%.2f", r.delta)
        else
            label = string.format("-$%.2f", -r.delta)
        end
        self.game.floating_text.emit(label, r.x, r.y)

        -- PP-bounty: first won hand at this (stake, game_type) combo
        -- this run awards the stake's pp_award. Locked in until prestige
        -- clears it. Losing hands and subsequent wins at the same combo
        -- do nothing.
        if r.delta > 0 then
            local tbl = self.pool.tables[r.table_idx]
            if tbl then
                local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                if not state.stakes_won_this_run[key] then
                    state.stakes_won_this_run[key] = true
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

-- Bankroll-cost-to-open. Adding a table deducts the stake's buy-in (100bb)
-- from bankroll. Game type doesn't change the buy-in. Returns false if
-- not affordable / pool full / unknown stake-or-gametype.
function GrindController:addTable(stake_id, game_type_id)
    if self.pool:count() >= self:tableSlotsCap() then return false end
    local stake = findStake(stake_id)
    if not stake then return false end
    local cost = stake.buy_in or 0
    if self.game.state.bankroll < cost then return false end
    self.game.state.bankroll = self.game.state.bankroll - cost
    self.pool:addTable(stake_id, game_type_id or "six_max")
    return true
end

-- Sum of live stacks at active tables. The "TIED UP" reading on the
-- top bar — money that's not gone, just locked on the felt. Tracks the
-- *current* stack value (which fluctuates with wins/losses), not the
-- buy-in paid to sit. Cashing out (see :removeTable) refunds whatever
-- the stack is worth at that moment.
function GrindController:tiedUp()
    local total = 0
    for _, t in ipairs(self.pool.tables) do
        total = total + (t.stack or 0)
    end
    return total
end

-- Removing a table refunds the *current stack* (cash-out semantics).
-- Lost it all? You get $0 back. Sitting on a freshly bought-in table
-- with no hands played? Full buy-in returns.
function GrindController:removeTable(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    local refund = t.stack or 0
    self.pool:removeTable(idx)
    self.game.state.bankroll = self.game.state.bankroll + refund
    return true
end

-- Stake-up: cash out the current stack and pay the new buy-in. Net
-- cost = new.buy_in - current_stack. Bankroll must cover that delta.
-- Table:setStake then resets the table's stack to the new buy-in.
function GrindController:changeTableStake(idx, new_stake_id)
    local t = self.pool.tables[idx]
    if not t then return false end
    local new_stake = findStake(new_stake_id)
    if not new_stake then return false end
    local refund = t.stack or 0
    local cost   = new_stake.buy_in or 0
    local diff   = cost - refund
    if diff > 0 and self.game.state.bankroll < diff then return false end
    self.game.state.bankroll = self.game.state.bankroll - diff
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
