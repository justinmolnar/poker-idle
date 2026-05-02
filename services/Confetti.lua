-- services/Confetti.lua
--
-- Thin wrapper around services/FlightSystem.emitBurst that fires a spread
-- of small colored quads outward from a point. Used by GrindController to
-- decorate jackpot wins; could be reused for any "celebration burst"
-- moment later.
--
-- Engine-neutral — knows nothing about poker. Caller passes:
--   center_xy { x, y }  — burst origin
--   count              — how many quads to spawn
--   palette            — list of {r, g, b} tuples; each quad picks one
--   options            — passthrough to FlightSystem.emitBurst
--                        (max_per_event, duration, arc_height, etc.)

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

local function makeQuadFn(color, size, rot_speed, spawn_t)
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

    -- Each piece's destination is a random point in an annulus around
    -- the origin so the burst spreads outward instead of converging.
    -- FlightSystem accepts a single dest per burst — we sidestep that by
    -- emitting individually so each piece can target its own offset.
    for _, fn in ipairs(render_fns) do
        local theta  = love.math.random() * math.pi * 2
        local radius = MIN_SPREAD + love.math.random() * (MAX_SPREAD - MIN_SPREAD)
        local dest = {
            center_xy[1] + math.cos(theta) * radius,
            center_xy[2] + math.sin(theta) * radius - 80,        -- bias upward more
        }
        FlightSystem.emit(center_xy, dest, fn, {
            duration   = options.duration   or 1.4,              -- linger longer
            arc_height = options.arc_height or (60 + love.math.random() * 140),
            delay      = love.math.random() * 0.20,              -- wider stagger
        })
    end
end

return Confetti
