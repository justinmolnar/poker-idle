-- services/Confetti.lua
--
-- Thin wrapper around services/FlightSystem.emitScatter that fires a spread
-- of small rotating colored quads outward from a point.
--
-- NOT CURRENTLY CALLED. The stack win it used to decorate now detonates
-- the pot's own chips instead (views/ChipFlight.explode), which reads as
-- "that pile just went off" rather than generic celebration. Kept because
-- the quads are a distinct, genuinely reusable look for a non-chip
-- celebration; delete it if nothing claims it.
--
-- Engine-neutral — knows nothing about poker. Caller passes:
--   center_xy { x, y }  — burst origin
--   count              — how many quads to spawn
--   options.palette    — list of {r, g, b} tuples; each quad picks one
--   options.duration   — seconds in flight
-- Scatter geometry (spread, arc, rise, stagger) is fixed here to the
-- confetti feel; FlightSystem.emitScatter owns the actual geometry.

local FlightSystem = require("services.FlightSystem")

local Confetti = {}

-- Quads vary in size between these in pixels. Big enough to actually
-- read as confetti at multi-table scale.
local MIN_SIZE = 10
local MAX_SIZE = 22

-- Spread radius. Each piece's "destination" is sampled in this
-- annulus around the origin so the burst fans out instead of converging.
-- Wider spread = the burst fills more of the panel area.
local MIN_SPREAD = 100
local MAX_SPREAD = 320

local function makeQuadFn(color, size, rot_speed)
    -- Each quad rotates over its lifetime. Closure captures color/size.
    local angle = 0
    return function(x, y)
        angle = angle + rot_speed * (love.timer and love.timer.getDelta() or 0.016)
        love.graphics.push()
        love.graphics.translate(x, y)
        love.graphics.rotate(angle)
        love.graphics.setColor(color[1], color[2], color[3], 1)
        love.graphics.rectangle("fill", -size * 0.5, -size * 0.5, size, size)
        love.graphics.pop()
    end
end

-- Default celebration palette. Caller can override per-burst.
local DEFAULT_PALETTE = {
    { 1.00, 0.85, 0.20 },   -- gold
    { 1.00, 0.45, 0.45 },   -- coral
    { 0.45, 0.85, 1.00 },   -- sky
    { 0.55, 1.00, 0.50 },   -- lime
    { 1.00, 0.55, 1.00 },   -- pink
    { 1.00, 1.00, 0.80 },   -- cream
}

-- Scatter geometry lives in FlightSystem.emitScatter, shared with the chip
-- explosion (views/ChipFlight.explode). This module now owns only the thing
-- that's actually confetti-specific: the rotating colored quads. The values
-- below are the confetti FEEL (slower, wider, more staggered than a chip
-- detonation) passed as overrides.
function Confetti.burst(center_xy, count, options)
    if not center_xy or not count or count <= 0 then return end
    options = options or {}
    local palette = options.palette or DEFAULT_PALETTE

    local render_fns = {}
    for i = 1, count do
        local size      = MIN_SIZE + love.math.random() * (MAX_SIZE - MIN_SIZE)
        local rot_speed = (love.math.random() * 2 - 1) * 8     -- -8..8 rad/s
        local color     = palette[((i - 1) % #palette) + 1]
        render_fns[#render_fns + 1] = makeQuadFn(color, size, rot_speed)
    end

    FlightSystem.emitScatter(center_xy, render_fns, {
        count      = count,
        min_spread = MIN_SPREAD,
        max_spread = MAX_SPREAD,
        rise       = 80,
        duration   = options.duration or 1.4,       -- linger longer
        arc_min    = 60,
        arc_max    = 200,
        stagger    = 0.20,                          -- wider stagger
    })
end

return Confetti
