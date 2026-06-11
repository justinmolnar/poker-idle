-- services/Pop.lua
--
-- Reusable "pop" — a one-shot grow/scale bump that eases out to rest. The same
-- treatment the showdown winning cards use, lifted out so any element can draw
-- attention to itself when it changes (a freshly-opened table, a stat whose
-- value just shifted, etc).
--
-- Engine-agnostic: pure scale math + a tiny global registry for event-triggered
-- pops keyed by an opaque id. Knows nothing about poker or rendering.
--
-- Two ways to drive it:
--   • Caller owns the clock (e.g. a per-state timer):  Pop.fromTimer(elapsed, dur)
--   • Event-triggered (shared clock):                  Pop.trigger(id)
--                                                       Pop.progress(id, dur)
-- Both return eased progress in [0,1] (1 at the peak, 0 at rest). Convert that
-- to a scale with Pop.scale(progress, base, bump): `base` at rest, `base + bump`
-- at the peak.

local Pop = {}

local DEFAULT_DURATION = 0.28

local function now() return (love.timer and love.timer.getTime()) or 0 end

local _fired = {}   -- id -> trigger timestamp (shared clock)

-- Eased progress: 1 at trigger -> 0 at/after `duration` (quadratic ease-out, so
-- the bump snaps in and settles). elapsed/duration share a unit (seconds).
function Pop.fromTimer(elapsed, duration)
    duration = duration or DEFAULT_DURATION
    if not elapsed or elapsed < 0 or elapsed >= duration then return 0 end
    local p = 1 - elapsed / duration
    return p * p
end

-- Fire a pop for `id` (stamps the shared clock). Re-triggering restarts it.
function Pop.trigger(id)
    if id then _fired[id] = now() end
end

-- Eased progress for a triggered id; auto-clears once finished.
function Pop.progress(id, duration)
    local t0 = id and _fired[id]
    if not t0 then return 0 end
    local p = Pop.fromTimer(now() - t0, duration)
    if p <= 0 then _fired[id] = nil end
    return p
end

-- Scale from progress: `base` at rest up to `base + bump` at the peak.
function Pop.scale(progress, base, bump)
    return (base or 1) + (bump or 0.22) * (progress or 0)
end

-- ── Change-watch ─────────────────────────────────────────────────────
-- Watch a value and pop the moment it changes. Reusable for ANY number that
-- should flag its own changes when redrawn each frame -- a table count, an
-- upgrade level, a bankroll tier, etc. The caller just passes the live value
-- every frame under a stable id.

local _seen = {}   -- id -> last observed value

-- Fire a pop the frame `value` differs from last time (but NOT on first sight,
-- so a value that's been steady doesn't pop on the first render). Returns the
-- current eased progress for `id`.
function Pop.onChange(id, value, duration)
    if id == nil then return 0 end
    local prev = _seen[id]
    _seen[id] = value
    if prev ~= nil and value ~= prev then Pop.trigger(id) end
    return Pop.progress(id, duration)
end

-- onChange + scale in one call (the common case for a popping stat number).
function Pop.changeScale(id, value, base, bump, duration)
    return Pop.scale(Pop.onChange(id, value, duration), base, bump)
end

return Pop
