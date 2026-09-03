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
--   3. Drawing reads HoverService.is(ns, id) — instant — or
--      HoverService.dwell(ns, id) — true only once the pointer has RESTED
--      on the target (Constants.HOVER.DWELL). Area-sized treatments (the
--      deal felt wash) read dwell so sweeping the mouse across the board
--      doesn't fire a lightshow; small precise controls stay on `is`.
--
-- Stateless from the caller's POV — caller passes (namespace, id) tuples.
-- Engine-agnostic apart from the wall clock: no idea what a "button" is.

local Constants = require("data.constants")

local HoverService = {}

local _hovered = {}   -- { [namespace] = { [id] = true, ... }, ... }
local _first   = {}   -- { [ns.."\0"..id] = first-seen wall time }
local _live    = {}   -- keys set() since the last clear(); prunes _first

local function now()
    return (love and love.timer and love.timer.getTime()) or 0
end

function HoverService.set(ns, id)
    local bucket = _hovered[ns]
    if not bucket then
        bucket = {}
        _hovered[ns] = bucket
    end
    bucket[id] = true
    local key = ns .. "\0" .. tostring(id)
    if not _first[key] then _first[key] = now() end
    _live[key] = true
end

function HoverService.is(ns, id)
    local bucket = _hovered[ns]
    return bucket ~= nil and bucket[id] == true
end

-- Hover that has RESTED: true only after the pointer has been on the
-- target continuously for `secs` (default Constants.HOVER.DWELL). The
-- continuity clock starts at set() and survives across frames until a
-- clear() passes without a set() for that key.
function HoverService.dwell(ns, id, secs)
    if not HoverService.is(ns, id) then return false end
    local t0 = _first[ns .. "\0" .. tostring(id)]
    return t0 ~= nil and (now() - t0) >= (secs or Constants.HOVER.DWELL)
end

-- register + query in one call, for sites that do their own rect test:
--   local hovered = Hover.rest("ui", "cashout", mouseInRect(...))
-- `hit` false is a no-op returning false, so the call can replace an
-- inline `mx >= x and ...` expression 1:1 and pick up the shared dwell.
-- `secs` overrides the dwell: pass 0 for an ACTUAL BUTTON whose highlight
-- should be instant (it still registers through the service, so flipping
-- a button between instant and dwell is a one-number change at its site).
function HoverService.rest(ns, id, hit, secs)
    if not hit then return false end
    HoverService.set(ns, id)
    return HoverService.dwell(ns, id, secs)
end

function HoverService.clear()
    _hovered = {}
    -- A key not re-set since the previous clear() lost its hover; its
    -- dwell clock restarts on the next visit.
    for k in pairs(_first) do
        if not _live[k] then _first[k] = nil end
    end
    _live = {}
end

function HoverService.clearNamespace(ns)
    _hovered[ns] = nil
end

return HoverService
