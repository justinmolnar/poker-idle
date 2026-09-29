-- models/TablePool.lua
--
-- Owns the player's currently-active Tables. Each Table writes its own
-- record (models/Table:serialize) and GameState holds the list of them in
-- `tables`; the pool builds the instances from those records on
-- construction and whenever something replaces them wholesale (a run
-- reset, a reload).
--
-- The pool does NOT mirror itself into GameState as it goes. It used to,
-- through sixteen parallel index-keyed arrays re-synced on every mutation
-- and every resolved hand, which between them still could not describe a
-- hand in flight. Now `serialize()` runs once, at save time.
--
-- Update tick collects resolutions from each table and returns them for the
-- controller to act on (apply to bankroll, emit floating text, etc.).

local Table     = require("models.Table")
local GameTypes = require("data.game_types")
local TableGrid = require("models.table_grid")

-- Fallback gtype for unknown ids in a saved spec (e.g. a deprecated mode
-- from a prior build). Six-max is the safe baseline — same buy-in, same
-- panel layout, no missing dist_shifts.
local StakesData = require("data.stakes")

local function stakeExists(id)
    for _, st in ipairs(StakesData) do
        if st.id == id then return true end
    end
    return false
end

local function findGtype(id)
    for _, gt in ipairs(GameTypes) do
        if gt.id == id then return gt end
    end
    return nil
end

local function gtypeExists(id)
    return findGtype(id) ~= nil
end

local TablePool = {}
TablePool.__index = TablePool

function TablePool:new(state, ctx, poker_events, effects_registry, bus)
    local self = setmetatable({
        state        = state,
        tables       = {},
        poker_events = poker_events,
        -- Threaded down to each Table so a status can be applied through
        -- the same registry every owned item uses (Table:effectiveCtx).
        effects_registry = effects_registry,
        -- Threaded down to each Table so it can announce its own changes.
        bus = bus,
    }, TablePool)
    self:restoreFromState(ctx)
    return self
end

-- Rebuild every Table from the records on GameState. A record is whatever
-- Table:serialize wrote, including a hand in flight; a record carrying
-- only a stake and a game type is a fresh table, which is what resetRun
-- and applyStartingPerks append.
function TablePool:restoreFromState(ctx)
    self.tables = {}
    self.rev = (self.rev or 0) + 1
    local records = self.state.tables or {}
    -- Cells for the records that have no slot of their own: every fresh
    -- one, since Table:new does not set it. Reading order, which is what
    -- the board's own layout means.
    local dense = TableGrid.denseSlots(#records)
    for i, rec in ipairs(records) do
        local stake_id, gtype_id = rec.stake_id, rec.game_type_id
        -- Save-safe degrade: a stake id that no longer exists (a retired
        -- ladder entry) cannot rebuild a playable table at all, and the old
        -- behaviour was a dead panel that never dealt. Drop it and refund
        -- whatever it was holding so the money is not stranded.
        local stake_ok = stake_id and stakeExists(stake_id)
        if stake_id and gtype_id and not stake_ok then
            local stranded = rec.stack
            if type(stranded) == "number" and stranded > 0 then
                self.state.bankroll = (self.state.bankroll or 0) + stranded
            end
            print(string.format("[TablePool] dropped saved table with unknown stake %q (refunded %s)",
                tostring(stake_id), tostring(stranded or 0)))
        end
        if stake_ok and gtype_id then
            -- An unknown gtype (a deprecated mode from a prior build)
            -- downgrades to six_max so the table can still be rebuilt.
            if not gtypeExists(gtype_id) then
                rec = setmetatable({ game_type_id = "six_max" }, { __index = rec })
            end
            local t = Table.restore(rec, ctx, self.poker_events,
                                    self.effects_registry, self.bus)
            t.slot = rec.slot or dense[i] or TableGrid.pack(0, 0)
            self.tables[#self.tables + 1] = t
        end
    end
    -- Repair what the save got wrong before trusting it: two tables in one
    -- cell render stacked with the buried panel eating the clicks, and
    -- nothing downstream ever un-stacks them. First claim on a cell wins;
    -- the offender moves to the first free cell (growing the board if the
    -- count's shape is somehow full). Same treatment for a slot that is
    -- not a whole non-negative number.
    local taken = {}
    for _, t in ipairs(self.tables) do
        local sl = t.slot
        local bad = type(sl) ~= "number" or sl < 0 or sl % 1 ~= 0
        if bad or taken[sl] then
            local cols, rows = TableGrid.shape(#self.tables)
            t.slot = TableGrid.firstFree(taken, cols, rows)
                     or TableGrid.placeNew(self:slots())
        end
        taken[t.slot] = true
    end
    -- A dropped record leaves a hole in the middle of the saved cells; that
    -- is fine, holes are legal. Re-sort so pool order is reading order
    -- regardless of what the save contained, then collapse a board bigger
    -- than the tables in it need.
    self:_sortBySlot()
    self:_reflow()
    -- Write the records back from what actually rebuilt: this is what
    -- purges a dropped table the moment its stack is refunded, so saving
    -- again cannot refund the same stack twice on the next load.
    self.state.tables = self:serialize()
end

-- Every table's own record. Called at save time only — the pool no longer
-- mirrors itself into GameState on every mutation, which used to run
-- sixteen parallel arrays several times a frame at a busy board.
function TablePool:serialize()
    local out = {}
    for i, t in ipairs(self.tables) do out[i] = t:serialize() end
    return out
end

function TablePool:count() return #self.tables end

function TablePool:get(idx) return self.tables[idx] end

-- The board's cells, in pool order.
function TablePool:slots()
    local out = {}
    for i, t in ipairs(self.tables) do out[i] = t.slot or 0 end
    return out
end

-- The board a view has to draw: the bounding box of occupied cells, so
-- trailing empty rows/columns collapse while interior holes stay.
function TablePool:boardShape()
    return TableGrid.bounds(self:slots())
end

-- Pool order IS reading order of the board. Keeping it that way means the
-- 12 index-keyed save arrays stay meaningful, and "the next table along"
-- means the same thing to the player and to the code.
function TablePool:_sortBySlot()
    table.sort(self.tables, function(a, b)
        return TableGrid.before(a.slot or 0, b.slot or 0)
    end)
end

function TablePool:addTable(stake_id, game_type_id, ctx)
    local t = Table:new(stake_id, game_type_id, ctx, self.poker_events,
                        self.effects_registry, self.bus)
    -- Takes a free cell if the board has one; otherwise the board grows a
    -- step and this table sits in the row/column that just appeared. No
    -- table already on the board moves.
    t.slot = TableGrid.placeNew(self:slots())
    self.tables[#self.tables + 1] = t
    self:_sortBySlot()
    self.rev = (self.rev or 0) + 1
    -- The caller cannot find the newcomer itself: _sortBySlot inserts it
    -- wherever its cell reads, not at the end of the array.
    return t
end

-- Pack the board tight: the shape the table COUNT needs, filled in reading
-- order. The only empty cells are the leftover ones at the end of the last
-- row, which is what "a hole that makes sense" means -- seven tables cannot
-- fill a 3x3, so two cells are over.
--
-- Returns whether anything actually moved, so a caller can skip the resync.
function TablePool:_packDense()
    local n = #self.tables
    self:_sortBySlot()
    local dense = TableGrid.denseSlots(n)
    local moved = false
    for i, t in ipairs(self.tables) do
        if t.slot ~= dense[i] then
            t.slot = dense[i]
            moved = true
        end
    end
    return moved
end

-- Collapse a board that is BIGGER than its count needs. Used on load,
-- where flattening a saved arrangement outright would throw away whatever
-- the player had dragged into place, but a board left oversized by an
-- older build (or by a spec dropped for an unknown stake) still has to
-- come back down.
function TablePool:_reflow()
    local n = #self.tables
    local want_cols, want_rows = TableGrid.shape(n)
    local have_cols, have_rows = TableGrid.bounds(self:slots())
    if have_cols <= want_cols and have_rows <= want_rows then return false end
    return self:_packDense()
end

function TablePool:removeTable(idx)
    if idx < 1 or idx > #self.tables then return end
    table.remove(self.tables, idx)
    -- A hole is legitimate only while the COUNT needs a board that size:
    -- eight tables cannot fill a 3x3, so closing one of nine leaves its
    -- cell empty where it stood. The moment the count fits a smaller
    -- board, everyone repacks -- otherwise "buy tables, close the top row"
    -- manufactures free spacers. _reflow is that exact test, and because
    -- bounds measures from the origin, a leading empty row (shut the top
    -- six of nine) reads as oversize and repacks like any other.
    self:_reflow()
    self.rev = (self.rev or 0) + 1
end

-- Put a table in a specific cell. An occupied target swaps the two tables;
-- an empty one just moves. Slot IS the persistence — _syncStateList writes
-- it alongside the other per-table arrays.
function TablePool:moveToSlot(from_idx, slot)
    local t = self.tables[from_idx]
    if not t or not slot then return false end
    if t.slot == slot then return false end
    for _, other in ipairs(self.tables) do
        if other ~= t and other.slot == slot then
            other.slot = t.slot           -- swap
            break
        end
    end
    t.slot = slot
    self:_sortBySlot()
    self.rev = (self.rev or 0) + 1
    return true
end

function TablePool:changeStake(idx, new_stake_id, ctx)
    local t = self.tables[idx]
    if not t then return end
    t:setStake(new_stake_id, ctx)
    self.rev = (self.rev or 0) + 1
end

-- ctx = player's computed effects rollup. Returns array of resolutions:
-- each entry { table, won, delta, x, y }. The TABLE REFERENCE is the
-- identity — an index would be stale by the time the controller consumes
-- the resolution (its pending-close sweep may table.remove tables in
-- between, shifting every index past the removed one, so a same-tick
-- payout landed on the neighbouring table).
function TablePool:update(dt, ctx)
    -- One array, wiped and refilled: the controller consumes it inside the
    -- same tick (its announcements dispatch synchronously), so nothing holds
    -- it past the frame and a fresh table per frame was pure garbage.
    local resolutions = self._resolutions
    if resolutions then
        for i = #resolutions, 1, -1 do resolutions[i] = nil end
    else
        resolutions = {}
        self._resolutions = resolutions
    end
    for _, t in ipairs(self.tables) do
        local r = t:update(dt, ctx)
        if r then
            r.table = t
            resolutions[#resolutions + 1] = r
        end
    end
    return resolutions
end

return TablePool
