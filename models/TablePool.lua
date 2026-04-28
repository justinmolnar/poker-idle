-- models/TablePool.lua
--
-- Owns the player's currently-active Tables. The list of *which stakes are
-- active* is persisted on GameState (`active_table_specs`); the Table
-- instances themselves are transient — rebuilt from that list on construction.
-- Mutations (add, remove, change-stake) sync back to the GameState list.
--
-- Update tick collects resolutions from each table and returns them for the
-- controller to act on (apply to bankroll, emit floating text, etc.).

local Table = require("models.Table")

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

function TablePool:new(state)
    local self = setmetatable({ state = state, tables = {} }, TablePool)
    self:rebuildFromState()
    return self
end

function TablePool:rebuildFromState()
    self.tables = {}
    for _, spec in ipairs(self.state.active_table_specs or {}) do
        local stake_id, gtype_id = unpackSpec(spec)
        if stake_id and gtype_id then
            self.tables[#self.tables + 1] = Table:new(stake_id, gtype_id)
        end
    end
end

function TablePool:_syncStateList()
    local list = {}
    for _, t in ipairs(self.tables) do
        list[#list + 1] = packSpec(t.stake_id, t.game_type_id)
    end
    self.state.active_table_specs = list
end

function TablePool:count() return #self.tables end

function TablePool:get(idx) return self.tables[idx] end

function TablePool:addTable(stake_id, game_type_id)
    self.tables[#self.tables + 1] = Table:new(stake_id, game_type_id)
    self:_syncStateList()
end

function TablePool:removeTable(idx)
    if idx < 1 or idx > #self.tables then return end
    table.remove(self.tables, idx)
    self:_syncStateList()
end

function TablePool:changeStake(idx, new_stake_id)
    local t = self.tables[idx]
    if not t then return end
    t:setStake(new_stake_id)
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
