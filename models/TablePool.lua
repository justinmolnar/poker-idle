-- models/TablePool.lua
--
-- Owns the player's currently-active Tables. The list of *which stakes are
-- active* is persisted on GameState (`active_table_specs`); the Table
-- instances themselves are transient — rebuilt from that list on construction.
-- Mutations (add, remove, change-stake) sync back to the GameState list.
--
-- Update tick collects resolutions from each table and returns them for the
-- controller to act on (apply to bankroll, emit floating text, etc.).

-- FEATURES.MTT_KO gates the post-1617f0d chip-flow MTT system. When off
-- (prototype builds), we route ALL tables through Table_legacy — the
-- pre-refactor snapshot of Table.lua that still carries the binary_outcome
-- code path the old MTT uses. Cash-table behavior is unchanged between
-- the two files for prototype-mode purposes; this isn't a per-table swap.
local Constants = require("data.constants")
local Table     = Constants.FEATURES.MTT_KO
                  and require("models.Table")
                  or  require("models.Table_legacy")
local GameTypes = require("data.game_types")

-- Fallback gtype for unknown ids in a saved spec (e.g. a deprecated mode
-- from a prior build). Six-max is the safe baseline — same buy-in, same
-- panel layout, no missing dist_shifts.
local function gtypeExists(id)
    for _, gt in ipairs(GameTypes) do
        if gt.id == id then return true end
    end
    return false
end

local TablePool = {}
TablePool.__index = TablePool

-- Specs are saved as composite strings "<stake_id>:<game_type_id>" so a
-- single flat string-array survives JSON round-trip cleanly. Helpers
-- below pack and unpack the format.
local function packSpec(stake_id, game_type_id)
    return stake_id .. ":" .. game_type_id
end

local function unpackSpec(spec)
    local stake_id, gtype_id = spec:match("^([^:]+):(.+)$")
    return stake_id, gtype_id
end

function TablePool:new(state, ctx, poker_events)
    local self = setmetatable({
        state        = state,
        tables       = {},
        poker_events = poker_events,
    }, TablePool)
    self:rebuildFromState(ctx)
    return self
end

function TablePool:rebuildFromState(ctx)
    self.tables = {}
    local mutes        = self.state.active_table_mutes or {}
    local rebuy_mutes  = self.state.active_table_rebuy_mutes or {}
    local hands        = self.state.active_table_mtt_hands_won or {}
    local mstate       = self.state.active_table_mtt_state or {}
    -- Chip-stack tournament continuity: parallel arrays carry per-seat
    -- state across save / reload. Cash tables leave them nil.
    local seat_stacks  = self.state.active_table_seat_stacks or {}
    local seat_busted  = self.state.active_table_seat_busted or {}
    local p_seats      = self.state.active_table_player_seat or {}
    local b_seats      = self.state.active_table_button_seat or {}
    local b_orders     = self.state.active_table_bust_order  or {}
    local mtt_plans    = self.state.active_table_mtt_plans   or {}
    local stack_vals   = self.state.active_table_stack       or {}
    for i, spec in ipairs(self.state.active_table_specs or {}) do
        local stake_id, gtype_id = unpackSpec(spec)
        if stake_id and gtype_id then
            -- Save-safe degrade: an unknown gtype (e.g. a deprecated mode
            -- from a pre-rip build) silently downgrades to six_max so the
            -- table can still be reconstructed.
            if not gtypeExists(gtype_id) then gtype_id = "six_max" end
            local t = Table:new(stake_id, gtype_id, ctx, self.poker_events)
            t.cursor_muted        = mutes[i] == true
            t.cursor_rebuy_muted  = rebuy_mutes[i] == true
            -- Tournament continuity: reload-mid-run drops the player back
            -- at "table idle, click DEAL to fire the next hand of N".
            -- Cash tables ignore these.
            t.mtt.hands_won  = hands[i] or 0
            t.mtt.state      = mstate[i]
            t.mtt.plan       = mtt_plans[i]
            if seat_stacks[i] then
                t.seat_stacks       = seat_stacks[i]
                t.seat_busted       = seat_busted[i] or {}
                t.player_seat_fixed = p_seats[i]
                t.button_seat       = b_seats[i]
                t.bust_order        = b_orders[i] or {}
                if stack_vals[i] then t.stack = stack_vals[i] end
            end
            self.tables[#self.tables + 1] = t
        end
    end
end

function TablePool:_syncStateList()
    local specs, mutes, rebuy_mutes = {}, {}, {}
    local hands, mstate, mtt_plans = {}, {}, {}
    local seat_stacks, seat_busted = {}, {}
    local p_seats, b_seats, b_orders, stack_vals = {}, {}, {}, {}
    for i, t in ipairs(self.tables) do
        specs[i]        = packSpec(t.stake_id, t.game_type_id)
        mutes[i]        = t.cursor_muted == true
        rebuy_mutes[i]  = t.cursor_rebuy_muted == true
        hands[i]        = (t.mtt and t.mtt.hands_won) or 0
        mstate[i]       = t.mtt and t.mtt.state
        mtt_plans[i]    = t.mtt and t.mtt.plan       -- nil for cash tables
        seat_stacks[i]  = t.seat_stacks              -- may be nil for cash tables
        seat_busted[i]  = t.seat_busted
        p_seats[i]      = t.player_seat_fixed
        b_seats[i]      = t.button_seat
        b_orders[i]     = t.bust_order
        stack_vals[i]   = t.stack
    end
    self.state.active_table_specs         = specs
    self.state.active_table_mutes         = mutes
    self.state.active_table_rebuy_mutes   = rebuy_mutes
    self.state.active_table_mtt_hands_won = hands
    self.state.active_table_mtt_state     = mstate
    self.state.active_table_mtt_plans     = mtt_plans
    self.state.active_table_seat_stacks   = seat_stacks
    self.state.active_table_seat_busted   = seat_busted
    self.state.active_table_player_seat   = p_seats
    self.state.active_table_button_seat   = b_seats
    self.state.active_table_bust_order    = b_orders
    self.state.active_table_stack         = stack_vals
end

function TablePool:count() return #self.tables end

function TablePool:get(idx) return self.tables[idx] end

function TablePool:addTable(stake_id, game_type_id, ctx)
    self.tables[#self.tables + 1] = Table:new(stake_id, game_type_id, ctx, self.poker_events)
    self:_syncStateList()
end

function TablePool:removeTable(idx)
    if idx < 1 or idx > #self.tables then return end
    table.remove(self.tables, idx)
    self:_syncStateList()
end

function TablePool:changeStake(idx, new_stake_id, ctx)
    local t = self.tables[idx]
    if not t then return end
    t:setStake(new_stake_id, ctx)
    self:_syncStateList()
end

-- ctx = player's computed effects rollup. Returns array of resolutions:
-- each entry { table_idx, won, delta, x, y }.
function TablePool:update(dt, ctx)
    local resolutions = {}
    for i, t in ipairs(self.tables) do
        local r = t:update(dt, ctx)
        if r then
            r.table_idx = i
            resolutions[#resolutions + 1] = r
        end
    end
    return resolutions
end

return TablePool
