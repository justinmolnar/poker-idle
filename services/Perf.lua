-- services/Perf.lua
--
-- The dev HUD's meters (F4). Counters for the calls an optimization pass
-- cares about, a rolling frame-time window, named scopes (update, draw
-- and the sections inside draw), gauges, and the allocation meters.
--
-- OFF BY DEFAULT and free when off: every entry point early-outs on a
-- boolean, so the call sites scattered through the hot paths cost a table
-- index, a test and a return when the HUD is closed. Nothing here is
-- gameplay; nothing reads it back except the HUD.
--
-- Allocates nothing per frame while on: the two tally sets are swapped and
-- wiped in place, so the meter never charges the frame for measuring it.
--
-- Engine-agnostic apart from love.timer, so it lives in services/.
--
-- Usage:
--   Perf.count("evStats")                     -- one tick of a named counter
--   Perf.enter("draw") ... Perf.exit("draw")  -- section timing (nests)
--   Perf.gauge("sheet_mb", 2.1)               -- a value read at any time
--   Perf.beginFrame(dt)                       -- once per love.update, first thing
--   Perf.endFrame()                           -- once at the end of love.draw
--   Perf.setExact(on)                         -- true allocation per frame
--                                                (GC held across the frame)

local Perf = {}

local _on      = false
local _counts  = {}     -- name -> ticks this frame
local _last    = {}     -- name -> ticks the frame just ended
local _scopes  = {}     -- name -> seconds accumulated this frame
local _scope_t = {}     -- name -> wall time the open scope started
local _scope_last = {}  -- name -> seconds the frame just ended
local _gauges  = {}     -- name -> last value set

-- Frame-time ring, one second wide at 240 fps.
local RING_N   = 240
local _ring    = {}
local _ring_i  = 0
local _ring_n  = 0

-- Allocation meters: Lua heap in KB, sampled per frame.
--   heap/frame   the rise since the previous sample (0 when a GC step ran
--                and freed more than was allocated): a floor, not a count
--   alloc ema    an EMA of the rises, so a single quiet frame does not read
--                as no allocation
--   freed/s      what the collector gave back over the ring's span
--   gc cycles/s  how often the heap fell (a sweep ran), over the ring
--   exact        the GC is stopped for the frame, so the rise IS the
--                allocation; the collector then steps at frame end and the
--                time that takes is the "gc" scope. Perturbs timing; for
--                measuring, never for playing.
local EMA_ALPHA   = 0.05
local _heap_prev  = 0
local _heap_last  = 0
local _heap_now   = 0
local _alloc_ema  = 0
local _freed_ring = {}     -- KB freed per frame, ring-aligned
local _fell_ring  = {}     -- 1 when the heap fell that frame
local _exact      = false
local _exact_base = 0

local function now()
    return (love and love.timer and love.timer.getTime()) or 0
end

local function wipe(t)
    for k in pairs(t) do t[k] = nil end
end

function Perf.setEnabled(on)
    on = on and true or false
    if on == _on then return end
    _on = on
    -- Leaving the HUD open across a toggle would print a frozen frame's
    -- numbers; clear so the first frame back is honest.
    wipe(_counts); wipe(_last)
    wipe(_scopes); wipe(_scope_t); wipe(_scope_last)
    wipe(_gauges)
    _ring_i, _ring_n = 0, 0
    _heap_prev, _heap_last, _alloc_ema = 0, 0, 0
    if not on and _exact then Perf.setExact(false) end
end

function Perf.enabled() return _on end

-- Exact allocation mode. Off restarts the collector.
function Perf.setExact(on)
    on = on and true or false
    if on == _exact then return end
    _exact = on
    if not on then collectgarbage("restart") end
end

function Perf.exact() return _exact end

function Perf.count(name, n)
    if not _on then return end
    _counts[name] = (_counts[name] or 0) + (n or 1)
end

function Perf.enter(name)
    if not _on then return end
    _scope_t[name] = now()
end

function Perf.exit(name)
    if not _on then return end
    local t0 = _scope_t[name]
    if not t0 then return end
    _scope_t[name] = nil
    _scopes[name] = (_scopes[name] or 0) + (now() - t0)
end

function Perf.gauge(name, v)
    if not _on then return end
    _gauges[name] = v
end

-- Called first thing in love.update. Rolls the previous frame's tallies
-- into the readable set and starts a fresh one. The sets are swapped and
-- the new current wiped in place: no tables per frame.
function Perf.beginFrame(dt)
    if not _on then return end

    _last, _counts = _counts, _last
    wipe(_counts)
    _scope_last, _scopes = _scopes, _scope_last
    wipe(_scopes)
    wipe(_scope_t)

    if dt and dt > 0 then
        _ring_i = (_ring_i % RING_N) + 1
        _ring[_ring_i] = dt
        if _ring_n < RING_N then _ring_n = _ring_n + 1 end
    end

    _heap_now = collectgarbage("count")
    local d = _heap_now - _heap_prev
    if _exact then
        -- The frame's true allocation is the rise since endFrame's step.
        d = _heap_now - _exact_base
    end
    _heap_last = (d > 0) and d or 0
    _alloc_ema = _alloc_ema + (_heap_last - _alloc_ema) * EMA_ALPHA
    _freed_ring[_ring_i] = (d < 0) and -d or 0
    _fell_ring[_ring_i]  = (d < 0) and 1 or 0
    _heap_prev = _heap_now

    if _exact then collectgarbage("stop") end
end

-- Called at the very end of love.draw. In exact mode the collector runs
-- here, timed as the "gc" scope, so the frame's allocation reading above
-- is clean and the collector's cost is visible instead of smeared.
function Perf.endFrame()
    if not (_on and _exact) then return end
    local t0 = now()
    collectgarbage("restart")
    collectgarbage("step", 1)
    collectgarbage("stop")
    _scopes["gc"] = (_scopes["gc"] or 0) + (now() - t0)
    _exact_base = collectgarbage("count")
end

-- avg, worst (seconds) over the ring.
function Perf.frameTimes()
    if _ring_n == 0 then return 0, 0 end
    local sum, worst = 0, 0
    for i = 1, _ring_n do
        local v = _ring[i]
        sum = sum + v
        if v > worst then worst = v end
    end
    return sum / _ring_n, worst
end

-- KB the collector freed per second and how many times the heap fell per
-- second, over the ring's span.
function Perf.gcRates()
    if _ring_n == 0 then return 0, 0 end
    local span, freed, fell = 0, 0, 0
    for i = 1, _ring_n do
        span  = span + (_ring[i] or 0)
        freed = freed + (_freed_ring[i] or 0)
        fell  = fell + (_fell_ring[i] or 0)
    end
    if span <= 0 then return 0, 0 end
    return freed / span, fell / span
end

function Perf.counter(name)  return _last[name] or 0 end
function Perf.scopeMs(name)  return (_scope_last[name] or 0) * 1000 end
function Perf.gaugeValue(name) return _gauges[name] end
function Perf.heapKB()       return _heap_now end
function Perf.heapDeltaKB()  return _heap_last end
function Perf.allocEmaKB()   return _alloc_ema end

return Perf
