-- services/Throw.lua
--
-- Something THROWN onto the felt: the dealer's catalog, the deck flyer. One
-- arc, one landing, one resting spot, so every piece of paper he tosses
-- flies the same way. Lifted out of views/CatalogModal, which used to own
-- the math; it now calls here and keeps only its drawing.
--
-- A throw is a cfg table (the catalog's CLOSED, the flyer's FOLDED):
--   rest_x, rest_y      landing zone centre, as fractions of W, H
--   jitter_x, jitter_y  how far the hashed spot strays from that centre
--   jitter_angle        rest tilt spread (radians), around base_angle
--   throw_dx            where it comes from: +ve = from the left, -ve = right
--   throw_arc           height of the arc, px before ui_scale
--   throw_spin          radians of tumble that settle out on landing
--   flutter             (optional) paper wobble on y, px; flutter_cycles
--   impact_squash       (optional, 0.08) the landing squash
--
-- Engine-agnostic: arithmetic only. services/Decal supplies the hashed
-- placement so a given key lands in the same spot every frame and session.

local Decal = require("services.Decal")

local Throw = {}

-- Where `key` comes to rest: x, y (top-left of a w×h object whose landing
-- zone is centred at rest_x/rest_y) and its rest angle.
function Throw.spot(key, cfg, W, H)
    local dx, dy, angle = Decal.place(key, {
        dx = cfg.jitter_x, dy = cfg.jitter_y,
        angle = cfg.jitter_angle, base_angle = cfg.base_angle,
    })
    return math.floor(W * cfg.rest_x) + dx, math.floor(H * cfg.rest_y) + dy, angle
end

-- The pose at progress t (0..1) of an object resting at rx, ry with height
-- ch: its x, y, the extra spin still to settle (add the rest angle), the
-- impact squash (1 at rest) and its height off the felt (0 at rest; drives
-- the airborne shadow).
function Throw.pose(t, cfg, s, rx, ry, ch)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local e  = 1 - (1 - t) ^ 3
    local fx = rx - (cfg.throw_dx or 0) * s
    local fy = -(ch or 0)
    local x  = fx + (rx - fx) * e
    local y  = fy + (ry - fy) * e - math.sin(math.pi * t) * (cfg.throw_arc or 0) * s
    if cfg.flutter and cfg.flutter > 0 then
        y = y + math.sin(t * math.pi * 2 * (cfg.flutter_cycles or 3)) * cfg.flutter * s * (1 - e)
    end
    local spin   = (cfg.throw_spin or 0) * (1 - e)
    local impact = (t >= 1) and 0 or math.max(0, 1 - math.abs(t - 0.92) / 0.08)
    local squash = 1 + (cfg.impact_squash or 0.08) * impact
    local height = math.sin(math.pi * t)
    return x, y, spin, squash, height
end

-- Does (mx, my) fall inside a rect that is rotated by rect.angle about its
-- centre? Rotate the point back and test the plain box.
function Throw.hitsRotated(r, mx, my)
    local cx, cy = r.x + r.w * 0.5, r.y + r.h * 0.5
    local c, sn  = math.cos(-(r.angle or 0)), math.sin(-(r.angle or 0))
    local dx, dy = mx - cx, my - cy
    local lx, ly = dx * c - dy * sn, dx * sn + dy * c
    return math.abs(lx) <= r.w * 0.5 and math.abs(ly) <= r.h * 0.5
end

local function overlaps(ax, ay, aw, ah, b)
    return ax < b.x + b.w and ax + aw > b.x and ay < b.y + b.h and ay + ah > b.y
end

-- Keep a w×h object at (x, y) off `other` ({x, y, w, h}): if they overlap,
-- slide it sideways in the direction `key` hashes to, by the overlap plus
-- `gap`, clamped inside [0, W]. Two things thrown on a table don't land on
-- each other.
function Throw.avoid(x, y, w, h, other, key, gap, W)
    if not other or not overlaps(x, y, w, h, other) then return x, y end
    local left = Decal.unit(key, 3) < 0.5
    local nx
    if left then nx = other.x - w - gap else nx = other.x + other.w + gap end
    if nx < 0 then nx = other.x + other.w + gap end
    if W and nx + w > W then nx = other.x - w - gap end
    return math.max(0, nx), y
end

return Throw
