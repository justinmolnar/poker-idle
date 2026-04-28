-- services/HoverService.lua
--
-- Per-frame hover state, namespace-keyed. Panel and ComponentRenderer write
-- to this in their `:updateHover(mx, my)` / `hitTest` passes; their `draw`
-- functions read it to render hover treatments (button highlights, tab
-- underlines, scrollbar-thumb tint).
--
-- The cycle each frame is:
--   1. Caller invokes HoverService.clear() at the top of update.
--   2. Things that own hit-testable regions call HoverService.set(ns, id).
--   3. Drawing reads HoverService.is(ns, id) and styles accordingly.
--
-- Stateless from the caller's POV — caller passes (namespace, id) tuples.
-- Engine-agnostic: no idea what a "button" or "tab" is.

local HoverService = {}

local _hovered = {}   -- { [namespace] = { [id] = true, ... }, ... }

function HoverService.set(ns, id)
    local bucket = _hovered[ns]
    if not bucket then
        bucket = {}
        _hovered[ns] = bucket
    end
    bucket[id] = true
end

function HoverService.is(ns, id)
    local bucket = _hovered[ns]
    return bucket ~= nil and bucket[id] == true
end

function HoverService.clear()
    _hovered = {}
end

function HoverService.clearNamespace(ns)
    _hovered[ns] = nil
end

return HoverService
