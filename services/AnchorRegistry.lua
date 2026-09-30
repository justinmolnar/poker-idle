-- services/AnchorRegistry.lua
--
-- Stateless module — named screen-space anchor points. Same convention as
-- HoverService / Tooltip: file-local upvalues, no instance, no constructor.
--
-- Views set anchors during draw (a sidebar widget's pile, a panel's
-- focal point); other layers (controllers, services) read them when they
-- need a target/source coord and don't have access to the view that knows
-- where things landed. 1-frame stale by design — the next frame's :set
-- overwrites.
--
-- Anchors are points by default; pass w, h to store a rect (the hint
-- system highlights whole widgets). Point readers only touch [1]/[2],
-- so rect entries are backward-compatible.
--
-- Engine-agnostic: anchor names are opaque strings.

local Perf = require("services.Perf")

local AnchorRegistry = {}

local _anchors = {}
local _frame   = 0

-- Advance the frame stamp. Called once per frame (main.lua love.draw)
-- BEFORE any view draws, so anchors :set during the frame read age 0.
function AnchorRegistry.tick()
    _frame = _frame + 1
end

-- Rewrites the existing entry in place rather than allocating a fresh one:
-- a 36-table board sets ~1000 anchors per frame, and this was ~1000 tables
-- per frame straight into the GC.
--
-- The contract that makes that safe: an entry read from :get is valid for
-- THIS frame only. Anything that holds a position past the frame it read
-- it (a chip flight's landing point) copies the numbers out — see
-- views/PokerEventAnims frozenXY.
-- Recording: while a list is open, every set() also appends
-- (name, x, y, w, h) to it as five flat entries, so a render done once
-- into a cache can have its anchors replayed each frame without running
-- the draw again (the panel cache). No per-anchor table. The list keeps
-- its own count (list.n): a point anchor records nil for w and h, and a
-- flat list with holes has no length.
local _rec = nil
function AnchorRegistry.beginRecord(list)
    _rec = list
    if list then
        for i = (list.n or #list), 1, -1 do list[i] = nil end
        list.n = 0
    end
end
function AnchorRegistry.endRecord()
    local list = _rec
    _rec = nil
    return list
end

-- Replay a recorded list, shifted by (dx, dy).
function AnchorRegistry.replay(list, dx, dy)
    if not list then return end
    for i = 1, list.n or 0, 5 do
        AnchorRegistry.set(list[i], list[i + 1] + dx, list[i + 2] + dy, list[i + 3], list[i + 4])
    end
end

function AnchorRegistry.set(name, x, y, w, h)
    Perf.count("anchor_set")
    local rec = _rec
    if rec then
        local n = rec.n
        rec[n + 1], rec[n + 2], rec[n + 3], rec[n + 4], rec[n + 5] = name, x, y, w, h
        rec.n = n + 5
    end
    local a = _anchors[name]
    if a then
        a[1], a[2], a[3], a[4] = x, y, w, h
        a.frame = _frame
        return
    end
    _anchors[name] = { x, y, w, h, frame = _frame }
end

-- Returns the {x, y[, w, h]} table or nil if no anchor was ever set under
-- this name. May be arbitrarily stale — the widget that registered it can
-- be long gone. Use age() when that matters.
function AnchorRegistry.get(name)
    return _anchors[name]
end

-- Frames since this anchor was last set (math.huge if never). An anchor
-- whose widget is still being drawn reads 0-1; anything older means the
-- widget stopped rendering (closed table, hidden button, swapped layout).
function AnchorRegistry.age(name)
    local a = _anchors[name]
    if not a then return math.huge end
    return _frame - (a.frame or 0)
end

-- Drop every name in `keys` (a slot -> name map, the shape Table.anchorKey
-- memoizes on a table): a closed table's thirty-odd anchors otherwise stay
-- registered, stale, for the rest of the session.
function AnchorRegistry.forgetAll(keys)
    if not keys then return end
    for _, name in pairs(keys) do _anchors[name] = nil end
end

-- How many anchors are held (tests).
function AnchorRegistry.count()
    local n = 0
    for _ in pairs(_anchors) do n = n + 1 end
    return n
end

-- Wipe all anchors. Called on hard resets (F7, prestige) so stale positions
-- from a prior layout don't leak into the new run.
function AnchorRegistry.clear()
    _anchors = {}
end

return AnchorRegistry
