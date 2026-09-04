-- models/TablePool.lua
--
-- Owns the player's currently-active Tables. The list of *which stakes are
-- active* is persisted on GameState (`active_table_specs`); the Table
-- instances themselves are transient — rebuilt from that list on construction.
-- Mutations (add, remove, change-stake) sync back to the GameState list.
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
    self:rebuildFromState(ctx)
    return self
end

function TablePool:rebuildFromState(ctx)
    self.tables = {}
    local mutes        = self.state.active_table_mutes or {}
    local rebuy_mutes  = self.state.active_table_rebuy_mutes or {}
    local hands        = self.state.active_table_ko_hands_won or {}
    local finishes     = self.state.active_table_ko_finishes or {}
    local last_fins    = self.state.active_table_last_finish or {}
    local mstate       = self.state.active_table_ko_state or {}
    -- Chip-stack tournament continuity: parallel arrays carry per-seat
    -- state across save / reload. Cash tables leave them nil.
    local seat_stacks  = self.state.active_table_seat_stacks or {}
    local seat_busted  = self.state.active_table_seat_busted or {}
    local p_seats      = self.state.active_table_player_seat or {}
    local b_seats      = self.state.active_table_button_seat or {}
    local b_orders     = self.state.active_table_bust_order  or {}
    local ko_plans    = self.state.active_table_ko_plans   or {}
    local stack_vals   = self.state.active_table_stack       or {}
    -- Board cells. A save written before slots existed (or one whose spec
    -- list grew behind the pool's back — applyStartingPerks appends specs
    -- directly) has no entry here; those tables fall back to dense reading
    -- order, which reproduces the pre-slot layout exactly.
    local slot_vals    = self.state.active_table_slot        or {}
    local status_vals  = self.state.active_table_statuses    or {}
    local dense        = TableGrid.denseSlots(#(self.state.active_table_specs or {}))
    for i, spec in ipairs(self.state.active_table_specs or {}) do
        local stake_id, gtype_id = unpackSpec(spec)
        -- Save-safe degrade #2: a stake id that no longer exists (renamed or
        -- retired ladder entry) can't rebuild a playable table at all — the
        -- old behavior was a permanently dead panel that never deals. Skip
        -- the spec and refund its persisted stack so the money isn't
        -- stranded.
        local stake_ok = stake_id and stakeExists(stake_id)
        if stake_id and gtype_id and not stake_ok then
            local stranded = (self.state.active_table_stack or {})[i]
            if type(stranded) == "number" and stranded > 0 then
                self.state.bankroll = (self.state.bankroll or 0) + stranded
            end
            print(string.format("[TablePool] dropped saved table with unknown stake %q (refunded %s)",
                tostring(stake_id), tostring(stranded or 0)))
        end
        if stake_ok and gtype_id then
            -- Save-safe degrade: an unknown gtype (e.g. a deprecated mode
            -- from a pre-rip build) silently downgrades to six_max so the
            -- table can still be reconstructed.
            if not gtypeExists(gtype_id) then gtype_id = "six_max" end
            local t = Table:new(stake_id, gtype_id, ctx, self.poker_events,
                                self.effects_registry, self.bus)
            t.cursor_muted        = mutes[i] == true
            t.cursor_rebuy_muted  = rebuy_mutes[i] == true
            -- Tournament continuity: reload-mid-run drops the player back
            -- at "table idle, click DEAL to fire the next hand of N".
            -- Cash tables ignore these.
            t.ko.hands_won    = hands[i] or 0
            t.ko.finish_count = finishes[i] or 0
            t.ko.state        = mstate[i]
            t.ko.plan         = ko_plans[i]
            -- The FINISH readout on a settled tournament survives reload.
            t.last_finish      = last_fins[i]
            -- A tournament marked mid-run without its per-seat state is a
            -- cross-build save (the old binary-KO prototype wrote
            -- state="playing" but never seat_stacks/plans). Restoring it
            -- as "playing" nil-indexes seat_busted on the first deal —
            -- restart the tournament cleanly instead.
            if t.ko.state == "playing" and not (seat_stacks[i] and ko_plans[i]) then
                t.ko.hands_won = 0
                t.ko.state     = nil
                t.ko.plan      = nil
            end
            if seat_stacks[i] then
                t.seat_stacks       = seat_stacks[i]
                t.seat_busted       = seat_busted[i] or {}
                t.player_seat_fixed = p_seats[i]
                t.button_seat       = b_seats[i]
                t.bust_order        = b_orders[i] or {}
                if stack_vals[i] then t.stack = stack_vals[i] end
            end
            t.slot = slot_vals[i] or dense[i] or TableGrid.pack(0, 0)
            -- Heaters and tilts survive a reload with their remaining
            -- time intact. An empty list restores as no statuses at all,
            -- which is also what a save written before statuses existed
            -- looks like.
            local saved_statuses = status_vals[i]
            if saved_statuses and #saved_statuses > 0 then
                t.statuses = saved_statuses
                t._status_rev = (t._status_rev or 0) + 1
            end
            self.tables[#self.tables + 1] = t
        end
    end
    -- Repair what the save got wrong before trusting it: two tables in one
    -- cell render stacked with the buried panel eating the clicks, and
    -- nothing downstream ever un-stacks them. First claim on a cell wins;
    -- the offender moves to the first free cell (growing the board if the
    -- count's shape is somehow full). Same treatment for a slot that is
    -- not a whole non-negative number. Only a corrupt or hand-edited save
    -- produces either — no in-game writer does.
    local taken = {}
    for _, t in ipairs(self.tables) do
        local s = t.slot
        local bad = type(s) ~= "number" or s < 0 or s % 1 ~= 0
        if bad or taken[s] then
            local cols, rows = TableGrid.shape(#self.tables)
            t.slot = TableGrid.firstFree(taken, cols, rows)
                     or TableGrid.placeNew(self:slots())
        end
        taken[t.slot] = true
    end
    -- A dropped spec (unknown stake) leaves a hole in the middle of the
    -- saved cells; that is fine, holes are legal. Re-sort so pool order is
    -- reading order regardless of what the save contained.
    self:_sortBySlot()
    -- ...and collapse the board if the save describes one bigger than the
    -- tables in it need. Covers a save written before the board reflowed on
    -- close, and a spec dropped here for an unknown stake.
    self:_reflow()
    -- Write the state arrays back from what actually rebuilt. This is what
    -- purges a dropped spec the moment its stack is refunded — leaving it
    -- until the first grind tick's sync left a window where saving again
    -- would refund the same stack twice on the next load.
    self:_syncStateList()
end

function TablePool:_syncStateList()
    local specs, mutes, rebuy_mutes = {}, {}, {}
    local hands, finishes, last_fins, mstate, ko_plans = {}, {}, {}, {}, {}
    local seat_stacks, seat_busted = {}, {}
    local p_seats, b_seats, b_orders, stack_vals = {}, {}, {}, {}
    local slots, statuses = {}, {}
    for i, t in ipairs(self.tables) do
        slots[i] = t.slot or 0
        -- A REFERENCE to the live list, not a copy: the entries tick down
        -- in place, so whatever is serialised later is automatically
        -- current without re-syncing every frame.
        statuses[i] = t.statuses
        specs[i]        = packSpec(t.stake_id, t.game_type_id)
        mutes[i]        = t.cursor_muted == true
        rebuy_mutes[i]  = t.cursor_rebuy_muted == true
        hands[i]        = (t.ko and t.ko.hands_won) or 0
        finishes[i]     = (t.ko and t.ko.finish_count) or 0
        last_fins[i]    = t.last_finish              -- nil mid-run / cash
        mstate[i]       = t.ko and t.ko.state
        ko_plans[i]    = t.ko and t.ko.plan       -- nil for cash tables
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
    self.state.active_table_ko_hands_won = hands
    self.state.active_table_ko_finishes  = finishes
    self.state.active_table_last_finish   = last_fins
    self.state.active_table_ko_state     = mstate
    self.state.active_table_ko_plans     = ko_plans
    self.state.active_table_seat_stacks   = seat_stacks
    self.state.active_table_seat_busted   = seat_busted
    self.state.active_table_player_seat   = p_seats
    self.state.active_table_button_seat   = b_seats
    self.state.active_table_bust_order    = b_orders
    self.state.active_table_stack         = stack_vals
    self.state.active_table_slot          = slots
    self.state.active_table_statuses      = statuses
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
    self:_syncStateList()
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
    self:_syncStateList()
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
    self:_syncStateList()
    return true
end

function TablePool:changeStake(idx, new_stake_id, ctx)
    local t = self.tables[idx]
    if not t then return end
    t:setStake(new_stake_id, ctx)
    self:_syncStateList()
end

-- ctx = player's computed effects rollup. Returns array of resolutions:
-- each entry { table, won, delta, x, y }. The TABLE REFERENCE is the
-- identity — an index would be stale by the time the controller consumes
-- the resolution (its pending-close sweep may table.remove tables in
-- between, shifting every index past the removed one, so a same-tick
-- payout landed on the neighbouring table).
function TablePool:update(dt, ctx)
    local resolutions = {}
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
