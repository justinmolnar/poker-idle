-- services/ChipFlightSystem.lua
--
-- Self-contained flying-projectile system. Mirrors services/FloatingTextSystem
-- — stateless module, file-local queue, emit/update/draw/clear.
--
-- Each emission is a procedural projectile travelling along a quadratic
-- bezier from a start to an end point with a random arc height. Bursts
-- (e.g., a payout) stagger N projectiles over ~30 ms each so they FLOW
-- visually rather than teleport-as-one.
--
-- Engine-agnostic — operates on opaque render callbacks. Each flying
-- entity stores a `render_fn(x, y)` closure; the system invokes it at the
-- entity's bezier-interpolated position. No domain knowledge: the chip
-- breakdown / colour palette / sprite atlas all live caller-side. The
-- caller wraps each individual chip (or coin, or particle, or whatever)
-- in a closure and hands the array to emitBurst.
--
-- Soft cap: MAX_IN_FLIGHT entities total. Drop-oldest at overflow so the
-- chaos endgame (32 tables, cursors clicking, payouts firing) can't
-- balloon frame time without bound.

local SoundService = require("services.SoundService")

local ChipFlightSystem = {}

local _flying           = {}
-- Parallel queue of pending arrival-sound playbacks. Each burst can schedule
-- exactly one entry (see emitBurst); we play it just before the last entity
-- in the burst lands, so the player hears one thunk per emission, regardless
-- of entity count.
local _scheduled_sounds = {}

-- ── Tunables ────────────────────────────────────────────────────────
local MAX_IN_FLIGHT       = 300     -- soft cap; drop-oldest beyond
local MAX_PER_EVENT       = 7       -- a $50k win shows 7 chips, not 500
local DEFAULT_DURATION    = 0.55    -- seconds from launch to arrival
local DEFAULT_STAGGER     = 0.03    -- 30 ms between staggered launches
local DEFAULT_ARC         = 60      -- baseline arc height in px
local ARC_JITTER          = 30      -- ± px of arc-height jitter

-- ── Helpers ────────────────────────────────────────────────────────
local function bezierAt(p0, p1, p2, t)
    local u  = 1 - t
    local uu = u * u
    local tt = t * t
    return uu * p0[1] + 2 * u * t * p1[1] + tt * p2[1],
           uu * p0[2] + 2 * u * t * p1[2] + tt * p2[2]
end

-- Push one entity onto the flight queue.
--   start_xy / end_xy: { x, y } tables in screen coords
--   render_fn:         function(x, y) — opaque render callback. Called
--                      once per draw-frame at the entity's interpolated
--                      bezier position.
--   options.delay:     seconds before this entity "launches" (renders at
--                      start until then)
--   options.arc_height: bezier control-point Y-offset
--   options.duration:  seconds in flight after launch
function ChipFlightSystem.emit(start_xy, end_xy, render_fn, options)
    options = options or {}
    if not render_fn then return end
    if #_flying >= MAX_IN_FLIGHT then
        table.remove(_flying, 1)
    end

    local arc = options.arc_height or (DEFAULT_ARC + (love.math.random() * 2 - 1) * ARC_JITTER)
    local mid = {
        (start_xy[1] + end_xy[1]) * 0.5,
        (start_xy[2] + end_xy[2]) * 0.5 - arc,
    }

    _flying[#_flying + 1] = {
        p0        = { start_xy[1], start_xy[2] },
        p1        = mid,
        p2        = { end_xy[1],   end_xy[2]   },
        t         = 0,
        duration  = options.duration or DEFAULT_DURATION,
        delay     = options.delay    or 0,
        render_fn = render_fn,
        x         = start_xy[1],
        y         = start_xy[2],
    }
end

-- Convenience: emit a list of render callbacks as a staggered burst.
-- Caps total entities at MAX_PER_EVENT — a payout of ANY value
-- renders as ≤ 7 entities so high-stakes wins don't fountain 1000+
-- at once. Caller is responsible for the breakdown that produced the
-- list; we just sample it.
--
-- options.arrival_sound (string, optional) — semantic name dispatched
-- through SoundService.playNamed at burst-end time. One thunk per burst,
-- regardless of entity count.
function ChipFlightSystem.emitBurst(start_xy, end_xy, render_fns, options)
    if not render_fns or #render_fns == 0 then return end
    options = options or {}
    local stagger  = options.stagger  or DEFAULT_STAGGER
    local duration = options.duration or DEFAULT_DURATION

    -- Sample down to MAX_PER_EVENT, preserving the original order
    -- so the showcase entity (always at index 1 from breakdown) leads.
    local count = math.min(#render_fns, MAX_PER_EVENT)
    local step  = #render_fns / count
    for i = 1, count do
        local src_idx = math.max(1, math.floor((i - 1) * step + 1))
        ChipFlightSystem.emit(start_xy, end_xy, render_fns[src_idx], {
            delay      = (i - 1) * stagger,
            duration   = duration,
            arc_height = options.arc_height,
        })
    end

    -- Schedule a single arrival thunk just before the last entity lands.
    if options.arrival_sound then
        local at = (count - 1) * stagger + duration - 0.04
        if at < 0 then at = 0 end
        _scheduled_sounds[#_scheduled_sounds + 1] = {
            t    = at,
            name = options.arrival_sound,
        }
    end
end

function ChipFlightSystem.update(dt)
    for i = #_flying, 1, -1 do
        local f = _flying[i]
        if f.delay > 0 then
            f.delay = f.delay - dt
            -- Stay parked at p0 while delaying.
            f.x, f.y = f.p0[1], f.p0[2]
        else
            f.t = f.t + dt / f.duration
            if f.t >= 1 then
                table.remove(_flying, i)
            else
                f.x, f.y = bezierAt(f.p0, f.p1, f.p2, f.t)
            end
        end
    end

    -- Advance scheduled arrival sounds; play and pop on expiry.
    for i = #_scheduled_sounds, 1, -1 do
        local s = _scheduled_sounds[i]
        s.t = s.t - dt
        if s.t <= 0 then
            SoundService.playNamed(s.name)
            table.remove(_scheduled_sounds, i)
        end
    end
end

function ChipFlightSystem.draw()
    if #_flying == 0 then return end
    for _, f in ipairs(_flying) do
        f.render_fn(f.x, f.y)
    end
end

function ChipFlightSystem.clear()
    _flying           = {}
    _scheduled_sounds = {}
end

-- For debug overlays / introspection.
function ChipFlightSystem.count()
    return #_flying
end

return ChipFlightSystem
