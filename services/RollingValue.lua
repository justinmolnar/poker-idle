-- services/RollingValue.lua
--
-- A self-clocked number that eases toward a target every time it's queried —
-- the "money rolls up smoothly" feel from the top bar, but with no manual
-- per-value state or per-frame update wiring. Pass a stable id + the live
-- target each frame; get back the smoothly-catching-up display value.
--
-- Engine-agnostic infrastructure (mirrors services/Pop): knows nothing about
-- poker or rendering. Reusable for any number that should roll to its new
-- value instead of snapping -- a focus %, a bankroll, an XP bar, etc.
--
-- ~95% catch-up in ~0.4s (k = dt * RATE). First sight of an id snaps to the
-- target so a fresh value doesn't roll up from zero. Snaps to the target once
-- within SNAP so it doesn't jitter forever near the end.

local RollingValue = {}

local Motion = require("services.Motion")
local RATE = 8
local SNAP = 0.005

local function now() return (love.timer and love.timer.getTime()) or 0 end

local _v = {}   -- id -> { curr = number, t = last query time }

-- Current eased value for `id`, easing toward `target`. `rate` overrides the
-- catch-up speed (higher = snappier).
-- `group` (default "text"): a services/Motion group. Medium rolls twice
-- as fast; Low and None snap.
function RollingValue.get(id, target, rate, group)
    target = target or 0
    local lvl = Motion.level(group or "text")
    local e = _v[id]
    local tnow = now()
    if not e or lvl <= Motion.LOW then
        _v[id] = { curr = target, t = tnow }
        return target
    end
    if lvl == Motion.MEDIUM then rate = (rate or RATE) * 2 end
    local k = math.min(1, (tnow - e.t) * (rate or RATE))
    e.t    = tnow
    e.curr = e.curr + (target - e.curr) * k
    if math.abs(target - e.curr) < SNAP then e.curr = target end
    return e.curr
end

-- Drop an id's cached state (e.g. on a hard reset so the next get snaps).
function RollingValue.reset(id) _v[id] = nil end

-- Seed (or overwrite) an id's current value so the next get eases FROM
-- here toward its target — e.g. a dropped drag panel gliding home from
-- wherever it was released.
function RollingValue.set(id, value)
    _v[id] = { curr = value, t = now() }
end

-- Drop every rolled value (hard resets / new game): stale entries otherwise
-- animate from the previous game's numbers.
function RollingValue.clear() _v = {} end

return RollingValue
