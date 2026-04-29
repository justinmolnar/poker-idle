-- services/ChipFlightSystem.lua
--
-- Self-contained flying-chip system. Mirrors services/FloatingTextSystem
-- — stateless module, file-local queue, emit/update/draw/clear.
--
-- Each emission is a procedural chip travelling along a quadratic
-- bezier from a start to an end point with a random arc height. Bursts
-- (e.g., a payout) stagger N chips over ~30 ms each so they FLOW
-- visually rather than teleport-as-one.
--
-- Engine-agnostic — operates on opaque denomination indices passed in
-- from the poker layer (via views/Chips and data/chips).
--
-- Soft cap: MAX_IN_FLIGHT chips total. Drop-oldest at overflow so the
-- chaos endgame (32 tables, cursors clicking, payouts firing) can't
-- balloon frame time without bound.

local Chips = require("views.Chips")

local ChipFlightSystem = {}

local _flying = {}

-- ── Tunables ────────────────────────────────────────────────────────
local MAX_IN_FLIGHT       = 300     -- soft cap; drop-oldest beyond
local MAX_CHIPS_PER_EVENT = 7       -- a $50k win shows 7 chips, not 500
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

-- Push one chip onto the flight queue.
--   start_xy / end_xy: { x, y } tables in screen coords
--   denom_idx:         index into data/chips.lua denominations
--   options.delay:     seconds before this chip "launches" (renders at
--                      start until then)
--   options.arc_height: bezier control-point Y-offset
--   options.duration:   seconds in flight after launch
function ChipFlightSystem.emit(start_xy, end_xy, denom_idx, options)
    options = options or {}
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
        denom_idx = denom_idx,
        x         = start_xy[1],
        y         = start_xy[2],
    }
end

-- Convenience: emit a list of denominations as a staggered burst.
-- Caps total chips at MAX_CHIPS_PER_EVENT — a payout of ANY value
-- renders as ≤ 7 chips so high-stakes wins don't fountain 1000+
-- chips at once. Caller is responsible for the breakdown that produced
-- the list; we just sample it.
function ChipFlightSystem.emitBurst(start_xy, end_xy, chip_indices, options)
    if not chip_indices or #chip_indices == 0 then return end
    options = options or {}
    local stagger = options.stagger or DEFAULT_STAGGER

    -- Sample down to MAX_CHIPS_PER_EVENT, preserving the original order
    -- so the showcase chip (always at index 1 from breakdown) leads.
    local count = math.min(#chip_indices, MAX_CHIPS_PER_EVENT)
    local step  = #chip_indices / count
    for i = 1, count do
        local src_idx = math.max(1, math.floor((i - 1) * step + 1))
        ChipFlightSystem.emit(start_xy, end_xy, chip_indices[src_idx], {
            delay      = (i - 1) * stagger,
            duration   = options.duration,
            arc_height = options.arc_height,
        })
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
end

function ChipFlightSystem.draw()
    if #_flying == 0 then return end
    -- Each flying chip is solitary, so always draw with its label visible.
    for _, f in ipairs(_flying) do
        Chips.drawChip(f.x, f.y, f.denom_idx, 1, true)
    end
end

function ChipFlightSystem.clear()
    _flying = {}
end

-- For debug overlays / introspection.
function ChipFlightSystem.count()
    return #_flying
end

return ChipFlightSystem
