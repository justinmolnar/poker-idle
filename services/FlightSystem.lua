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
-- Two kinds of projectile share one queue:
--
--   * a CLOSURE: `render_fn(x, y, t)`, called at the entity's interpolated
--     position. No domain knowledge: cards, confetti and the currency
--     glyph fly this way, and the caller wraps whatever it is in a closure
--     (services/Tumble decorates it to spin).
--   * a CHIP: seven numbers (denomination, label, tint, scale, alpha and
--     the tumble Tumble.roll wrote onto the record) that a registered chip
--     renderer turns into sprites at draw, all chips in the air as one
--     batch. This module never requires a view: views/ChipFlight registers
--     views/Chips.flightRenderer once, and headless there simply is none.
--
-- Records are POOLED. Twenty-odd tables launch up to a thousand chips a
-- second, and each used to be four fresh tables (the record and three
-- points) plus the closures around it. A record now carries its endpoints
-- as plain numbers, comes off a free stack, and goes back on it when it
-- lands, scrubbed. A steady state allocates nothing.
--
-- Soft cap: MAX_IN_FLIGHT entities total. Past it the oldest lands at once
-- (its on_arrive fires, so whatever it carried still gets where it was
-- going) and its record carries the new emission.

local SoundService = require("services.SoundService")
local Motion       = require("services.Motion")
local Tumble       = require("services.Tumble")

local FlightSystem = {}

local KIND_FN, KIND_CHIP = 0, 1
FlightSystem.CHIP = KIND_CHIP

-- Every emission carries a motion group (options.motion, default "chips")
-- and services/Motion decides how far it flies: as authored at Full and
-- High (High drops the landing scatter), shortened with no stagger at
-- Medium, and not at all below that — the entity lands the instant it is
-- emitted (on_arrive fires, the arrival sound still plays) so whatever it
-- was carrying is where it belongs and the view fades it in.
local function levelFor(motion)
    return Motion.level(motion or "chips")
end

local _flying   = {}
local _free     = {}      -- retired records, ready to reuse
local _n_alloc  = 0       -- records ever made (tests: free + flying == this)
local _renderer = nil     -- the chip renderer: begin() / add(rec) / flush()
local _in_update = false
-- Pending arrival-sound playbacks, pooled the same way. Each burst
-- schedules one entry (see emitBurst), played just before the last entity
-- in the burst lands, so the player hears one thunk per emission
-- regardless of entity count.
local _sounds   = {}
local _sfree    = {}

local EMPTY = {}

-- ── Tunables ────────────────────────────────────────────────────────
local MAX_IN_FLIGHT       = 800     -- soft cap; land-oldest beyond.
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

-- ── The pool ────────────────────────────────────────────────────────
-- What a record holds. Numbers stay (they are overwritten on the next
-- emission); references are cleared so a retired record pins nothing.
local function scrub(r)
    r.kind      = nil
    r.render_fn = nil
    r.on_arrive = nil
    r.oa_a, r.oa_b = nil, nil
    r.tint      = nil
    r.denom     = nil
    r.tb_on     = false
end

local function fire(r)
    local fn = r.on_arrive
    if fn then fn(r.x1, r.y1, r, r.oa_a, r.oa_b) end
end

local function retire(r)
    scrub(r)
    _free[#_free + 1] = r
end

-- A record for a new emission: off the free stack, or a fresh one. At the
-- cap the OLDEST entity lands now (removed from the queue first, so an
-- on_arrive that emits cannot land it twice) and its record is the one
-- handed back. Inside update the queue is being compacted in place, so
-- the cap waits a frame rather than shift it under the loop.
local function acquire()
    local n = #_flying
    if n >= MAX_IN_FLIGHT and not _in_update then
        local r = _flying[1]
        for i = 1, n - 1 do _flying[i] = _flying[i + 1] end
        _flying[n] = nil
        fire(r)
        scrub(r)
        return r
    end
    local r = _free[#_free]
    if r then
        _free[#_free] = nil
        return r
    end
    _n_alloc = _n_alloc + 1
    return {}
end

-- Common fields of every emission. Returns the record, queued.
local function launch(r, x0, y0, x1, y1, delay, duration, arc, on_arrive, a, b, lvl)
    if arc == nil then
        arc = DEFAULT_ARC + (love.math.random() * 2 - 1) * ARC_JITTER
    end
    r.x0, r.y0, r.x1, r.y1 = x0, y0, x1, y1
    r.mx, r.my = (x0 + x1) * 0.5, (y0 + y1) * 0.5 - arc
    r.t        = 0
    r.duration = (duration or DEFAULT_DURATION) * ((lvl == Motion.MEDIUM) and 0.6 or 1)
    r.delay    = (lvl == Motion.MEDIUM) and 0 or (delay or 0)
    r.on_arrive, r.oa_a, r.oa_b = on_arrive, a, b
    r.x, r.y   = x0, y0
    _flying[#_flying + 1] = r
    return r
end

-- ── Emitting ────────────────────────────────────────────────────────
-- One closure projectile, allocation-free. Endpoints as numbers;
-- `on_arrive(x, y, rec, a, b)` fires ONCE as the entity leaves the queue,
-- given the point it arrived at, its record and the two values handed in
-- here — the seam a caller needs to hand the entity over to whatever it was
-- flying into (views/ChipPile fills the destination slot with the chip
-- that just landed), or to launch a SECOND leg from where this one ended
-- (scattered debris regrouping toward a pile). Also fired on the cap's
-- land-oldest path, so an entity the cap discards still completes its
-- handover and the destination is never left permanently short.
-- `arc` nil means the default with jitter. Returns the record, or nil when
-- the motion level landed it on the spot.
function FlightSystem.emitXY(x0, y0, x1, y1, render_fn, delay, duration, arc, on_arrive, a, b, motion)
    if not render_fn then return nil end
    local lvl = levelFor(motion)
    if lvl <= Motion.LOW then
        if on_arrive then on_arrive(x1, y1, nil, a, b) end
        return nil
    end
    local r = acquire()
    r.kind      = KIND_FN
    r.render_fn = render_fn
    return launch(r, x0, y0, x1, y1, delay, duration, arc, on_arrive, a, b, lvl)
end

-- The table form, for cards and confetti.
--   start_xy / end_xy: { x, y } tables in screen coords
--   render_fn:         function(x, y, t) — opaque render callback. `t` is
--                      flight progress 0..1 (0 while still delayed).
--   options.delay:     seconds before this entity "launches" (renders at
--                      start until then)
--   options.arc_height: bezier control-point Y-offset
--   options.duration:  seconds in flight after launch
--   options.on_arrive: function(x, y) — as emitXY
function FlightSystem.emit(start_xy, end_xy, render_fn, options)
    options = options or EMPTY
    return FlightSystem.emitXY(start_xy[1], start_xy[2], end_xy[1], end_xy[2], render_fn,
                               options.delay, options.duration, options.arc_height,
                               options.on_arrive, nil, nil, options.motion)
end

-- One chip, as a record the chip renderer draws. `tumble` is a
-- services/Tumble preset (or opts table) rolled onto the record, or false
-- to fly flat. `es` is the chip's on-screen scale (relative to the chip
-- radius), `alpha` its opacity. on_arrive / a / b as emitXY.
function FlightSystem.emitChip(x0, y0, x1, y1, denom, with_label, tint, es, alpha, tumble,
                               delay, duration, arc, on_arrive, a, b, motion)
    local lvl = levelFor(motion)
    if lvl <= Motion.LOW then
        if on_arrive then on_arrive(x1, y1, nil, a, b) end
        return nil
    end
    local r = acquire()
    r.kind  = KIND_CHIP
    r.denom = denom
    r.label = with_label and true or false
    r.tint  = tint
    r.es    = es or 1
    r.alpha = alpha or 1
    if tumble then
        Tumble.roll(tumble, r, motion)
    else
        r.tb_on = false
    end
    return launch(r, x0, y0, x1, y1, delay, duration, arc, on_arrive, a, b, lvl)
end

-- The renderer chip records draw through: begin(), add(rec), flush().
-- views/ChipFlight registers views/Chips.flightRenderer.
function FlightSystem.setChipRenderer(r) _renderer = r end

-- ── Bursts ──────────────────────────────────────────────────────────
-- A directed burst's plan at the current motion level: how many of `n`
-- entities fly (0 when none do), the sampling step over the input, and
-- the stagger, duration, landing spread and duration jitter to use.
-- Caps total entities at options.max_per_event (default MAX_PER_EVENT) —
-- a burst of ANY input size renders as ≤ cap entities so spammy callers
-- don't fountain 1000+ at once. Stack bursts override the cap upward for
-- the fountain feel; everything else uses the default 7.
function FlightSystem.burstPlan(n, options)
    options = options or EMPTY
    local lvl = levelFor(options.motion)
    if lvl <= Motion.LOW or n <= 0 then return 0 end
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

    local count = math.min(n, cap)
    return count, n / count, stagger, duration, land_spread, dur_jitter
end

-- The i-th entity of a planned burst: which input it samples (the original
-- order is preserved so the showcase entity, always first from a
-- breakdown, leads), its launch delay, its jittered duration and its
-- landing point around (ex, ey). The random draws happen in the order
-- emitBurst always made them.
function FlightSystem.burstParams(i, step, stagger, duration, land_spread, dur_jitter, ex, ey)
    local src_idx = math.max(1, math.floor((i - 1) * step + 1))
    local dx, dy = ex, ey
    if land_spread > 0 then
        local theta  = love.math.random() * math.pi * 2
        local radius = love.math.random() * land_spread
        dx = ex + math.cos(theta) * radius
        dy = ey + math.sin(theta) * radius
    end
    local dur = duration
    if dur_jitter > 0 then
        dur = duration * (1 + (love.math.random() * 2 - 1) * dur_jitter)
    end
    return src_idx, (i - 1) * stagger, dur, dx, dy
end

-- The single arrival thunk of a burst, just before its last entity lands.
function FlightSystem.burstSound(name, count, stagger, duration)
    if not name then return end
    local at = (count - 1) * stagger + duration - 0.04
    FlightSystem.scheduleSound(name, at)
end

-- Convenience: emit a list of render callbacks as a staggered burst.
--
-- options.arrival_sound (string, optional) — semantic name dispatched
-- through SoundService.playNamed at burst-end time. One thunk per burst,
-- regardless of entity count.
-- options.max_per_event (number, optional) — override the cap.
function FlightSystem.emitBurst(start_xy, end_xy, render_fns, options)
    if not render_fns or #render_fns == 0 then return end
    options = options or EMPTY
    local count, step, stagger, duration, land_spread, dur_jitter =
        FlightSystem.burstPlan(#render_fns, options)
    if count == 0 then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    for i = 1, count do
        local src, delay, dur, dx, dy =
            FlightSystem.burstParams(i, step, stagger, duration, land_spread, dur_jitter,
                                     end_xy[1], end_xy[2])
        FlightSystem.emitXY(start_xy[1], start_xy[2], dx, dy, render_fns[src],
                            delay, dur, options.arc_height, nil, nil, nil, options.motion)
    end
    FlightSystem.burstSound(options.arrival_sound, count, stagger, duration)
end

-- ── Scatters ────────────────────────────────────────────────────────
-- How many of `n` scattered entities fly at this motion level: all at
-- Full, one at High, none below (each lands where it is, so a gather
-- still completes). A scatter is a spectacle and wants its full count,
-- which is why it never goes through the directed burst's cap.
function FlightSystem.scatterCount(n, options)
    local lvl = levelFor(options and options.motion)
    if lvl <= Motion.MEDIUM then return 0 end
    if lvl == Motion.HIGH and n > 1 then return 1 end
    return n
end

-- One scattered destination out of (x, y): a point in the annulus
-- min_spread..max_spread lifted by `rise`, with its arc height and launch
-- delay. Random draws in the order emitScatterEach always made them.
--   min_spread   — inner annulus radius in px (default 90)
--   max_spread   — outer annulus radius in px (default 300)
--   rise         — upward bias added to every destination (default 90)
--   arc_min/max  — bezier arc-height range (default 80..220)
--   stagger      — max random launch delay (default 0.06; 0 = all at once)
function FlightSystem.scatterParams(x, y, options)
    options = options or EMPTY
    local min_spread = options.min_spread or 90
    local max_spread = options.max_spread or 300
    local rise       = options.rise       or 90
    local arc_min    = options.arc_min    or 80
    local arc_max    = options.arc_max    or 220
    local stagger    = options.stagger    or 0.06
    local theta  = love.math.random() * math.pi * 2
    local radius = min_spread + love.math.random() * (max_spread - min_spread)
    local dx = x + math.cos(theta) * radius
    local dy = y + math.sin(theta) * radius - rise
    local arc   = arc_min + love.math.random() * (arc_max - arc_min)
    local delay = love.math.random() * stagger
    return dx, dy, arc, delay
end

-- A scatter's arrival sound, a third of the way through its flight.
function FlightSystem.scatterSound(options)
    if not (options and options.arrival_sound) then return end
    local duration = options.duration or 1.1
    FlightSystem.scheduleSound(options.arrival_sound, math.max(0, duration * 0.35))
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
-- options: as scatterParams, plus count (default #render_fns), duration
-- (default 1.1) and arrival_sound.
function FlightSystem.emitScatter(origin, render_fns, options)
    if not origin or not render_fns or #render_fns == 0 then return end
    options = options or EMPTY
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
-- and therefore the hook a second leg launches from.
-- options: as emitScatter. `count` is ignored here — the entity list IS
-- the count.
function FlightSystem.emitScatterEach(entities, options)
    if not entities or #entities == 0 then return end
    options = options or EMPTY
    local n_fly = FlightSystem.scatterCount(#entities, options)
    for i = n_fly + 1, #entities do
        local e = entities[i]
        if e.on_arrive then e.on_arrive(e.x, e.y) end
    end
    if n_fly == 0 then
        if options.arrival_sound then FlightSystem.scheduleSound(options.arrival_sound, 0) end
        return
    end
    local duration = options.duration or 1.1
    for i = 1, n_fly do
        local e = entities[i]
        if e.render_fn then
            local dx, dy, arc, delay = FlightSystem.scatterParams(e.x, e.y, options)
            FlightSystem.emitXY(e.x, e.y, dx, dy, e.render_fn, delay, duration, arc,
                                e.on_arrive, nil, nil, options.motion)
        end
    end
    FlightSystem.scatterSound(options)
end

-- Queue a one-shot sound to play `at` seconds from now. Exposed so
-- callers that emit their own per-entity flights (rather than going
-- through emitBurst) still get the single arrival thunk.
function FlightSystem.scheduleSound(name, at)
    if not name then return end
    local s = _sfree[#_sfree]
    if s then _sfree[#_sfree] = nil else s = {} end
    s.t    = math.max(0, at or 0)
    s.name = name
    _sounds[#_sounds + 1] = s
end

-- ── Update ──────────────────────────────────────────────────────────
-- One forward pass, compacting in place: survivors slide down, landed
-- records fire their arrival and go back to the pool. The length is
-- snapshotted first because an on_arrive may EMIT (the gather leg of an
-- explosion launches from where the outward leg ended), and what it
-- appends past the snapshot is carried over untouched for next frame.
function FlightSystem.update(dt)
    _in_update = true
    local n = #_flying
    local w = 0
    for i = 1, n do
        local f = _flying[i]
        local landed = false
        if f.delay > 0 then
            f.delay = f.delay - dt
            -- Stay parked at the start while delaying.
            f.x, f.y = f.x0, f.y0
        else
            local t = f.t + dt / f.duration
            f.t = t
            if t >= 1 then
                landed = true
            else
                local u  = 1 - t
                local uu = u * u
                local tt = t * t
                local ut = 2 * u * t
                f.x = uu * f.x0 + ut * f.mx + tt * f.x1
                f.y = uu * f.y0 + ut * f.my + tt * f.y1
            end
        end
        if landed then
            f.x, f.y = f.x1, f.y1
            fire(f)
            retire(f)
        else
            w = w + 1
            _flying[w] = f
        end
    end
    local m = #_flying
    for i = n + 1, m do
        w = w + 1
        _flying[w] = _flying[i]
    end
    for i = w + 1, m do _flying[i] = nil end
    _in_update = false

    -- Advance scheduled arrival sounds; play and pop on expiry.
    local ns = #_sounds
    local ws = 0
    for i = 1, ns do
        local s = _sounds[i]
        s.t = s.t - dt
        if s.t <= 0 then
            SoundService.playNamed(s.name)
            s.name = nil
            _sfree[#_sfree + 1] = s
        else
            ws = ws + 1
            _sounds[ws] = s
        end
    end
    for i = ws + 1, ns do _sounds[i] = nil end
end

-- ── Draw ────────────────────────────────────────────────────────────
-- Closures draw where they are in the queue; chip records go to the
-- renderer and come out as one batch at the end, over the closures. With
-- no renderer registered (headless) chips are not drawn.
function FlightSystem.draw()
    local n = #_flying
    if n == 0 then return end
    local R = _renderer
    local began = false
    for i = 1, n do
        local f = _flying[i]
        if f.kind == KIND_CHIP then
            if R then
                if not began then R.begin(); began = true end
                R.add(f)
            end
        else
            -- Third arg is flight progress, 0..1. Callbacks that don't care
            -- (every plain quad) simply ignore it; motion decorators like
            -- services/Tumble use it to drive spin so the animation is tied
            -- to the flight rather than to wall-clock frames.
            f.render_fn(f.x, f.y, f.t)
        end
    end
    if began then R.flush() end
end

-- Teardown. Deliberately does NOT fire on_arrive — this is a state wipe,
-- not an arrival, and the destinations are being cleared in the same
-- sweep (see GrindState:fullReset). The records go back to the pool.
function FlightSystem.clear()
    for i = #_flying, 1, -1 do
        retire(_flying[i])
        _flying[i] = nil
    end
    for i = #_sounds, 1, -1 do
        _sounds[i].name = nil
        _sfree[#_sfree + 1] = _sounds[i]
        _sounds[i] = nil
    end
end

-- How many entities are in the air (the HUD's flights row).
function FlightSystem.count() return #_flying end

-- Pool accounting for the checks: records ever made, records free.
function FlightSystem.debugPool() return _n_alloc, #_free end

return FlightSystem
