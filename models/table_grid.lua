-- models/table_grid.lua
--
-- The table board: which cell each table sits in, and how the board grows.
-- Pure functions over (row, col) — no rendering, no love, no game state.
-- Engine-agnostic like models/room_placement.lua.
--
-- ─── WHY SLOTS EXIST ────────────────────────────────────────────────────
-- The grid used to derive every table's cell from its position in the pool
-- array, row-major, recomputed each frame. That meant the board reshuffled
-- whenever the table count crossed a shape boundary: going from 9 tables to
-- 10 moved six of them into a different row. Anything positional — a
-- formation, a ranged effect, a player's muscle memory — was destroyed by
-- opening one table.
--
-- So a table OWNS its cell. Adding a table fills a free cell, and only when
-- none is free does the board grow one step and the newcomer take a cell in
-- the row or column that just appeared. Nobody already seated ever moves.
--
-- A cell is (row, col), NOT a linear index: a linear index addresses a
-- different cell the moment the board widens, which is the exact
-- renumbering this module exists to prevent.
--
-- ─── THE SHAPE LADDER ───────────────────────────────────────────────────
-- Boards grow one axis at a time, widest-first:
--   1x1 → 2x1 → 2x2 → 3x2 → 3x3 → 4x3 → 4x4 → 5x4 → ...
-- which is exactly `cols = ceil(sqrt(n)), rows = ceil(n / cols)`. That
-- reproduces, for every n in 1..MAX_TABLES, the shape the old
-- area-maximising search produced at the fixed 1600x900 canvas — so this is
-- a behaviour-preserving change that also makes the shape deterministic
-- instead of a function of pixel headroom (the old search sat 9px from
-- flipping n=2 to a different shape).

local TableGrid = {}

-- Cells pack into one integer so a slot is one value in one save array.
-- Stride is far above MAX_TABLES' 6x6 board, leaving room to grow.
local STRIDE = 100

function TableGrid.pack(row, col) return row * STRIDE + col end

function TableGrid.unpack(slot)
    slot = slot or 0
    local row = math.floor(slot / STRIDE)
    return row, slot - row * STRIDE
end

-- The board shape that holds n tables, per the ladder above.
function TableGrid.shape(n)
    if not n or n <= 0 then return 0, 0 end
    local cols = math.ceil(math.sqrt(n))
    return cols, math.ceil(n / cols)
end

-- One step bigger. Square boards gain a column; wide boards gain a row.
function TableGrid.growStep(cols, rows)
    if cols <= 0 or rows <= 0 then return 1, 1 end
    if cols == rows then return cols + 1, rows end
    return cols, rows + 1
end

-- The board a set of occupied cells actually needs: the bounding box, so
-- trailing empty rows and columns collapse on their own while interior
-- holes persist. `slots` is a list of packed cells.
function TableGrid.bounds(slots)
    local cols, rows = 0, 0
    for _, s in ipairs(slots or {}) do
        local r, c = TableGrid.unpack(s)
        if c + 1 > cols then cols = c + 1 end
        if r + 1 > rows then rows = r + 1 end
    end
    return cols, rows
end

-- First unoccupied cell in reading order within a cols x rows board, or nil
-- when the board is full. `taken` is a set keyed by packed cell.
function TableGrid.firstFree(taken, cols, rows)
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local s = TableGrid.pack(r, c)
            if not taken[s] then return s end
        end
    end
    return nil
end

-- Where a new table goes: a free cell if the board has one, otherwise the
-- board grows a step and the newcomer takes the first cell that opened up.
-- Returns the packed cell (never nil — the board can always grow).
function TableGrid.placeNew(slots)
    local taken = {}
    for _, s in ipairs(slots or {}) do taken[s] = true end
    local cols, rows = TableGrid.bounds(slots)
    if cols <= 0 or rows <= 0 then return TableGrid.pack(0, 0) end

    local free = TableGrid.firstFree(taken, cols, rows)
    if free then return free end

    local gc, gr = TableGrid.growStep(cols, rows)
    return TableGrid.firstFree(taken, gc, gr) or TableGrid.pack(0, 0)
end

-- Reading order (top-to-bottom, left-to-right). Pool order is kept in this
-- order so the save arrays and the 1-D "neighbouring table" relation both
-- read the way the board looks.
function TableGrid.before(slot_a, slot_b)
    local ra, ca = TableGrid.unpack(slot_a)
    local rb, cb = TableGrid.unpack(slot_b)
    if ra ~= rb then return ra < rb end
    return ca < cb
end

-- Dense reading-order cells for n tables, the pre-slot layout. Used to
-- migrate saves written before slots existed, and to seed a fresh board.
function TableGrid.denseSlots(n)
    local cols = TableGrid.shape(n)
    local out = {}
    for i = 1, (n or 0) do
        out[i] = TableGrid.pack(math.floor((i - 1) / cols), (i - 1) % cols)
    end
    return out
end

return TableGrid
