-- services/FlightSystem.lua
--
-- Self-contained flying-projectile system. Mirrors services/FloatingTextSystem
-- — stateless module, file-local queue, emit/update/draw/clear.
--
-- Each emission is a procedural projectile travelling along a quadratic
-- bezier from a start to an end point with a random arc height. Bursts
-- stagger N projectiles over ~30 ms each so they FLOW visually rather
-- than teleport-as-one.
--
-- Engine-agnostic — operates on opaque render callbacks. Each flying
-- entity stores a `render_fn(x, y, t)` closure; the system invokes it at the
-- entity's bezier-interpolated position. No domain knowledge: the visual
-- breakdown / colour palette / sprite atlas all live caller-side. The
-- caller wraps each individual entity (chip, coin, particle, droplet,
-- whatever) in a closure and hands the array to emitBurst.
--
-- Soft cap: MAX_IN_FLIGHT entities total. Drop-oldest at overflow so
-- many simultaneous bursts can't balloon frame time without bound.

local SoundService = require("services.SoundService")

local Motion       = require("services.Motion")
local FlightSystem = {}

-- Every emission carries a motion group (options.motion, default "chips")
-- and services/Motion decides how far it flies: as authored at Full and
-- High (High drops the landing scatter), shortened with no stagger at
-- Medium, and not at all below that — the entity lands the instant it is
-- emitted (on_arrive fires, the arrival sound still plays) so whatever it
-- was carrying is where it belongs and the view fades it in.
local function levelFor(options)
    return Motion.level((options and options.motion) or "chips")
end
local _flying           = {}
-- Parallel queue of pending arrival-sound playbacks. Each burst can schedule
-- exactly one entry (see emitBurst); we play it just before the last entity
-- in the burst lands, so the player hears one thunk per emission, regardless
-- of entity count.
local _scheduled_sounds = {}

-- ── Tunables ────────────────────────────────────────────────────────
local MAX_IN_FLIGHT       = 800     -- soft cap; drop-oldest beyond.
                                    -- Bumped to accommodate stack confetti
                                    -- fountains (120+ pieces) overlapping
                                    -- with chip bursts.
local MAX_PER_EVENT       = 7       -- a burst shows ≤ 7 entities, never hundreds
local DEFAULT_DURATION    = 0.55    -- seconds from launch to arrival
local DEFAULT_STAGGER     = 0.03    -- 30 ms between staggered launches
local DEFAULT_ARC         = 60      -- baseline arc height in px
local ARC_JITTER          = 30      -- ± px of arc-height jitter

-- Per-projectile variance for directed bursts. Without these every chip in
-- a burst flies an identical curve to an identical pixel and lands in
-- lockstep — the burst reads as one rigid object with beads on it rather
-- than a handful of separate chips. Small numbers; the point is to break
-- the formation, not to scatter it.
local DEFAULT_LAND_SPREAD = 14      -- px radius of per-chip landing jitter
local DEFAULT_DUR_JITTER  = 0.12    -- ± fraction of flight duration

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
--   render_fn:         function(x, y, t) — opaque render callback. Called
--                      once per draw-frame at the entity's interpolated
--                      bezier position. `t` is flight progress 0..1 (0
--                      while still delayed); ignore it unless the entity
--                      animates along its flight.
--   options.delay:     seconds before this entity "launches" (renders at
--                      start until then)
--   options.arc_height: bezier control-point Y-offset
--   options.duration:  seconds in flight after launch
--   options.on_arrive: function(x, y) — fired ONCE as the entity leaves
--                      the queue, given the point it arrived at. The seam
--                      a caller needs to hand the entity over to whatever
--                      it was flying into (views/ChipPile fills the
--                      destination slot with the chip that just landed),
--                      or to launch a SECOND leg from where this one ended
--                      (scattered debris regrouping toward a pile). Also
--                      fired on the drop-oldest overflow path below, so an
--                      entity the cap discards still completes its
--                      handover and the destination is never left
--                      permanently short.
function FlightSystem.emit(start_xy, end_xy, render_fn, options)
    options = options or {}
    if not render_fn then return end
    local lvl = levelFor(options)
    if lvl <= Motion.LOW then
        if options.on_arrive then options.on_arrive(end_xy[1], end_xy[2]) end
        return
    end
    if #_flying >= MAX_IN_FLIGHT then
        local dropped = table.remove(_flying, 1)
        if dropped and dropped.on_arrive then
            dropped.on_arrive(dropped.p2[1], dropped.p2[2])
        end
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
        duration  = (options.duration or DEFAULT_DURATION) * ((lvl == Motion.MEDIUM) and 0.6 or 1),
        delay     = (lvl == Motion.MEDIUM) and 0 or (options.delay or 0),
        render_fn = render_fn,
        on_arrive = options.on_arrive,
        x         = start_xy[1],
        y         = start_xy[2],
    }
end

-- Convenience: emit a list of render callbacks as a staggered burst.
-- Caps total entities at options.max_per_event (default MAX_PER_EVENT) —
-- a burst of ANY input size renders as ≤ cap entities so spammy callers
-- don't fountain 1000+ at once. Stack bursts override the cap upward
-- for the fountain feel; everything else uses the default 7.
--
-- options.arrival_sound (string, optional) — semantic name dispatched
-- through SoundService.playNamed at burst-end time. One thunk per burst,
-- regardless of entity count.
-- options.max_per_event (number, optional) — override the cap.
function FlightSystem.emitBurst(start_xy, end_xy, render_fns, options)
    if not render_fns or #render_fns == 0 then return end
    options = options or {}
    local lvl = levelFor(options)
    if lvl <= Motion.LOW then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    local stagger  = options.stagger  or DEFAULT_STAGGER
    local duration = options.duration or DEFAULT_DURATION
    local cap      = options.max_per_event or MAX_PER_EVENT

    -- Per-projectile variance. Each chip gets its own landing point in a
    -- small disc around the destination and its own flight time, so the
    -- burst arrives as a scatter of separate objects instead of a rigid
    -- formation collapsing onto one pixel. Pass 0 for either to restore
    -- the old lockstep behaviour. Gone at High and below.
    local land_spread = options.land_spread or DEFAULT_LAND_SPREAD
    local dur_jitter  = options.duration_jitter or DEFAULT_DUR_JITTER
    if lvl <= Motion.HIGH then land_spread, dur_jitter = 0, 0 end
    if lvl == Motion.MEDIUM then stagger = 0 end

    -- Sample down to cap, preserving the original order so the showcase
    -- entity (always at index 1 from breakdown) leads.
    local count = math.min(#render_fns, cap)
    local step  = #render_fns / count
    for i = 1, count do
        local src_idx = math.max(1, math.floor((i - 1) * step + 1))

        local dest = end_xy
        if land_spread > 0 then
            local theta  = love.math.random() * math.pi * 2
            local radius = love.math.random() * land_spread
            dest = {
                end_xy[1] + math.cos(theta) * radius,
                end_xy[2] + math.sin(theta) * radius,
            }
        end

        local dur = duration
        if dur_jitter > 0 then
            dur = duration * (1 + (love.math.random() * 2 - 1) * dur_jitter)
        end

        FlightSystem.emit(start_xy, dest, render_fns[src_idx], {
            delay      = (i - 1) * stagger,
            duration   = dur,
            arc_height = options.arc_height,
            motion     = options.motion,
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

-- Omnidirectional burst — N projectiles thrown outward from ONE origin to
-- scattered destinations sampled in an annulus around it. The sibling of
-- emitBurst: that one flies A → B, this one has no destination, only a
-- direction. Use it for explosion / fountain / spray moments.
--
-- render_fns is CYCLED when options.count exceeds it, so a caller holding
-- 12 distinct render callbacks can throw 120 projectiles and every one is a
-- real entity rather than a generic particle.
--
-- Deliberately does NOT route through emitBurst — that caps at
-- MAX_PER_EVENT (7) because a directed chip flight should read as a handful
-- of chips. A scatter is a spectacle and wants its full count.
--
-- options:
--   count        — projectiles to throw (default #render_fns)
--   min_spread   — inner annulus radius in px (default 90)
--   max_spread   — outer annulus radius in px (default 300)
--   rise         — upward bias added to every destination (default 90)
--   duration     — seconds in flight (default 1.1)
--   arc_min/max  — bezier arc-height range (default 80..220)
--   stagger      — max random launch delay (default 0.06; 0 = all at once)
function FlightSystem.emitScatter(origin, render_fns, options)
    if not origin or not render_fns or #render_fns == 0 then return end
    options = options or {}
    local count = options.count or #render_fns
    -- Build one entity per projectile, all sharing the single origin.
    local entities = {}
    for i = 1, count do
        entities[i] = {
            x         = origin[1],
            y         = origin[2],
            render_fn = render_fns[((i - 1) % #render_fns) + 1],
        }
    end
    FlightSystem.emitScatterEach(entities, options)
end

-- The general form: every entity flies outward from ITS OWN position.
--
-- This is what "the arrangement comes apart" needs — a pile of chips
-- disintegrating in place, each chip leaving from exactly where it was
-- sitting, rather than N copies spawning at one point and fanning out.
-- The single-origin emitScatter above is just this with every entity
-- starting from the same spot.
--
-- entities: array of { x, y, render_fn [, on_arrive] }. Each entity may
-- carry its OWN on_arrive — the scatter picks the destinations, so this is
-- the only way a caller learns where a given piece of debris came to rest,
-- and therefore the hook a second leg launches from (see
-- views/ChipFlight.explodeTaken's gather).
-- options: as emitScatter (min_spread, max_spread, rise, duration,
--          arc_min, arc_max, stagger, arrival_sound). `count` is ignored
--          here — the entity list IS the count.
function FlightSystem.emitScatterEach(entities, options)
    if not entities or #entities == 0 then return end
    options = options or {}
    -- A scatter is a spectacle: at High one piece flies, below that none
    -- (each entity lands where it is, so a gather still completes).
    local lvl = levelFor(options)
    if lvl <= Motion.MEDIUM then
        for _, e in ipairs(entities) do
            if e.on_arrive then e.on_arrive(e.x, e.y) end
        end
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    if lvl == Motion.HIGH and #entities > 1 then
        local first = entities[1]
        for i = 2, #entities do
            if entities[i].on_arrive then entities[i].on_arrive(entities[i].x, entities[i].y) end
        end
        entities = { first }
    end
    local min_spread = options.min_spread or 90
    local max_spread = options.max_spread or 300
    local rise       = options.rise       or 90
    local duration   = options.duration   or 1.1
    local arc_min    = options.arc_min    or 80
    local arc_max    = options.arc_max    or 220
    local stagger    = options.stagger    or 0.06

    for _, e in ipairs(entities) do
        if e.render_fn then
            local start  = { e.x, e.y }
            local theta  = love.math.random() * math.pi * 2
            local radius = min_spread + love.math.random() * (max_spread - min_spread)
            local dest   = {
                e.x + math.cos(theta) * radius,
                e.y + math.sin(theta) * radius - rise,
            }
            FlightSystem.emit(start, dest, e.render_fn, {
                duration   = duration,
                arc_height = arc_min + love.math.random() * (arc_max - arc_min),
                delay      = love.math.random() * stagger,
                on_arrive  = e.on_arrive,
                motion     = options.motion,
            })
        end
    end

    if options.arrival_sound then
        _scheduled_sounds[#_scheduled_sounds + 1] = {
            t    = math.max(0, duration * 0.35),
            name = options.arrival_sound,
        }
    end
end

-- Queue a one-shot sound to play `at` seconds from now. Exposed so
-- callers that emit their own per-entity flights (rather than going
-- through emitBurst) still get the single arrival thunk.
function FlightSystem.scheduleSound(name, at)
    if not name then return end
    _scheduled_sounds[#_scheduled_sounds + 1] = {
        t    = math.max(0, at or 0),
        name = name,
    }
end

function FlightSystem.update(dt)
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
                if f.on_arrive then f.on_arrive(f.p2[1], f.p2[2]) end
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

function FlightSystem.draw()
    if #_flying == 0 then return end
    for _, f in ipairs(_flying) do
        -- Third arg is flight progress, 0..1. Callbacks that don't care
        -- (every plain chip / quad) simply ignore it; motion decorators
        -- like services/Tumble use it to drive spin so the animation is
        -- tied to the flight rather than to wall-clock frames.
        f.render_fn(f.x, f.y, f.t)
    end
end

-- Teardown. Deliberately does NOT fire on_arrive — this is a state wipe,
-- not an arrival, and the destinations are being cleared in the same
-- sweep (see GrindState:fullReset).
function FlightSystem.clear()
    _flying           = {}
    _scheduled_sounds = {}
end

-- For debug overlays / introspection.
function FlightSystem.count()
    return #_flying
end

return FlightSystem
