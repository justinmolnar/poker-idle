-- services/AnchorRegistry.lua
--
-- Stateless module — named screen-space anchor points. Same convention as
-- HoverService / Tooltip: file-local upvalues, no instance, no constructor.
--
-- Views set anchors during draw ("the bankroll pile is at (x, y)"); other
-- layers (controllers, services) read them when they need a target/source
-- coord and don't have access to the view that knows where things landed.
-- 1-frame stale by design — the next frame's :set overwrites.
--
-- Engine-agnostic: anchor names are opaque strings.

local AnchorRegistry = {}

local _anchors = {}

function AnchorRegistry.set(name, x, y)
    _anchors[name] = { x, y }
end

-- Returns the {x, y} table or nil if no anchor was ever set under this name.
function AnchorRegistry.get(name)
    return _anchors[name]
end

-- Wipe all anchors. Called on hard resets (F7, prestige) so stale positions
-- from a prior layout don't leak into the new run.
function AnchorRegistry.clear()
    _anchors = {}
end

return AnchorRegistry
