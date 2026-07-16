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

local AnchorRegistry = {}

local _anchors = {}
local _frame   = 0

-- Advance the frame stamp. Called once per frame (main.lua love.draw)
-- BEFORE any view draws, so anchors :set during the frame read age 0.
function AnchorRegistry.tick()
    _frame = _frame + 1
end

function AnchorRegistry.set(name, x, y, w, h)
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

-- Wipe all anchors. Called on hard resets (F7, prestige) so stale positions
-- from a prior layout don't leak into the new run.
function AnchorRegistry.clear()
    _anchors = {}
end

return AnchorRegistry
