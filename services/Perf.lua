-- services/Perf.lua
--
-- The dev HUD's meters (F4). Counters for the calls an optimization pass
-- cares about, a rolling frame-time window, an update/draw split, and a
-- crude allocation-rate proxy.
--
-- OFF BY DEFAULT and free when off: every entry point early-outs on a
-- boolean, so the call sites scattered through the hot paths cost a table
-- index, a test and a return when the HUD is closed. Nothing here is
-- gameplay; nothing reads it back except the HUD.
--
-- Engine-agnostic apart from love.timer, so it lives in services/.
--
-- Usage:
--   Perf.count("evStats")             -- one tick of a named counter
--   Perf.enter("draw") ... Perf.exit("draw")   -- coarse section timing
--   Perf.beginFrame(dt)               -- once per love.update, first thing
--   Perf.snapshot()                   -- what the HUD prints

local Perf = {}

local _on      = false
local _counts  = {}     -- name -> ticks this frame
local _last    = {}     -- name -> ticks the frame just ended
local _scopes  = {}     -- name -> seconds accumulated this frame
local _scope_t = {}     -- name -> wall time the open scope started
local _scope_last = {}  -- name -> seconds the frame just ended

-- Frame-time ring, one second wide at 240 fps.
local RING_N   = 240
local _ring    = {}
local _ring_i  = 0
local _ring_n  = 0

-- Allocation proxy: Lua heap in KB, sampled per frame. A GC step makes the
-- delta negative, so only the rises are summed — this reads as "KB churned
-- per frame", not as a true allocation count.
local _heap_prev  = 0
local _heap_rise  = 0
local _heap_last  = 0
local _heap_now   = 0

local function now()
    return (love and love.timer and love.timer.getTime()) or 0
end

function Perf.setEnabled(on)
    on = on and true or false
    if on == _on then return end
    _on = on
    -- Leaving the HUD open across a toggle would print a frozen frame's
    -- numbers; clear so the first frame back is honest.
    _counts, _last = {}, {}
    _scopes, _scope_t, _scope_last = {}, {}, {}
    _ring, _ring_i, _ring_n = {}, 0, 0
    _heap_prev, _heap_rise, _heap_last = 0, 0, 0
end

function Perf.enabled() return _on end

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

-- Called first thing in love.update. Rolls the previous frame's tallies
-- into the readable set and starts a fresh one.
function Perf.beginFrame(dt)
    if not _on then return end

    _last, _counts = _counts, {}
    _scope_last, _scopes = _scopes, {}
    _scope_t = {}

    if dt and dt > 0 then
        _ring_i = (_ring_i % RING_N) + 1
        _ring[_ring_i] = dt
        if _ring_n < RING_N then _ring_n = _ring_n + 1 end
    end

    _heap_now = collectgarbage("count")
    local d = _heap_now - _heap_prev
    _heap_last = (d > 0) and d or 0
    _heap_rise = _heap_rise + _heap_last
    _heap_prev = _heap_now
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

function Perf.counter(name)  return _last[name] or 0 end
function Perf.scopeMs(name)  return (_scope_last[name] or 0) * 1000 end
function Perf.heapKB()       return _heap_now end
function Perf.heapDeltaKB()  return _heap_last end

return Perf
