-- views/widgets/Tentacles.lua
--
-- Something with too many arms comes out from behind a stamp. Procedural:
-- N thin, ribbed tentacles rooted on the stamp's (rotated) edge, each a
-- wandering path built by integrating a heading whose turn rate is a sum
-- of slow sines plus a bias, so they meander, double back and loop the way
-- a real tentacle drapes, instead of radiating like spokes. Everything is
-- hashed from a seed, so a stamp always grows the same arms.
--
-- `grow` (0..1) is how much of each arm has been drawn. They grow out and
-- then hold still: there is no clock term, so once grown a card is static.
--
-- Stateless: Tentacles.draw(...) per frame. The caller clips to whatever
-- the arms are consuming.
--
-- opts:
--   x, y, hw, hh   (required)  the stamp's centre and half extents
--   angle          radians     the stamp's rotation (default 0)
--   seed           (required)  anything stable (the item id)
--   grow           0..1        (default 1)
--   reach          px          length of the longest arm (default 260)
--   count          integer     arms (default 7)
--   color          {r,g,b}     ink (default violet)
--   alpha          0..1        (default 0.9)

local Theme = require("views.Theme")
local Decal = require("services.Decal")

local Tentacles = {}

local INK    = { 0.36, 0.12, 0.58 }
local CORE   = { 0.62, 0.40, 0.82 }   -- a lighter line down the middle: a tube, not a smear
local SEG    = 48

-- LuaJIT's math.atan takes ONE argument (the second is ignored), which
-- put every heading in the right half-plane and made every arm lean
-- right. atan2 where it exists, two-argument atan (Lua 5.4) otherwise.
local atan2 = math.atan2 or function(y, x)
    if x > 0 then return math.atan(y / x) end
    if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    return (y >= 0) and (math.pi / 2) or (-math.pi / 2)
end

local function unit(seed, i, salt)
    return Decal.unit(tostring(seed) .. ":" .. i, salt)
end

-- One arm's centreline: positions and widths from the root to the tip.
local function armPath(o, i, len)
    local cx, cy, hw, hh = o.x, o.y, o.hw, o.hh
    local rot = o.angle or 0
    -- Root: a point on the stamp's perimeter, in the stamp's own frame,
    -- then rotated with it. Spread the arms around the perimeter with
    -- jitter, biased to the long edges (there is more edge there).
    local per = (i - 0.5) / (o.count or 7) + (unit(o.seed, i, 1) - 0.5) * 0.25
    per = per % 1
    local lx, ly, nx, ny
    local top_w = 2 * hw / (2 * hw + 2 * hh) / 2     -- share of the perimeter per long edge
    if per < top_w then                                -- top edge
        lx, ly, nx, ny = -hw + (per / top_w) * 2 * hw, -hh, 0, -1
    elseif per < 0.5 then                              -- right edge
        lx, ly, nx, ny = hw, -hh + ((per - top_w) / (0.5 - top_w)) * 2 * hh, 1, 0
    elseif per < 0.5 + top_w then                      -- bottom edge
        lx, ly, nx, ny = hw - ((per - 0.5) / top_w) * 2 * hw, hh, 0, 1
    else                                               -- left edge
        lx, ly, nx, ny = -hw, hh - ((per - 0.5 - top_w) / (0.5 - top_w)) * 2 * hh, -1, 0
    end
    local c, s = math.cos(rot), math.sin(rot)
    local rx = cx + lx * c - ly * s
    local ry = cy + lx * s + ly * c
    local heading = atan2(ny * c + nx * s, nx * c - ny * s)   -- outward normal, rotated
    heading = heading + (unit(o.seed, i, 2) - 0.5) * 1.2

    -- Turn profile: a bias (which way it tends to curl) plus two slow
    -- sines. Integrated over the arm's length this gives S-bends and, where
    -- the bias wins, a full loop near the end.
    local bias = (unit(o.seed, i, 3) - 0.5) * 2 * 7.0
    local a1, f1, p1 = 5.0 + 4.0 * unit(o.seed, i, 4), 1.2 + 1.6 * unit(o.seed, i, 5), unit(o.seed, i, 6) * 6.28
    local a2, f2, p2 = 2.0 + 3.0 * unit(o.seed, i, 7), 3.0 + 3.0 * unit(o.seed, i, 8), unit(o.seed, i, 9) * 6.28
    local w0 = 2.2 + 1.3 * unit(o.seed, i, 10)

    local pts = { { x = rx, y = ry, w = w0 } }
    local ds = len / SEG
    local x, y = rx, ry
    for k = 1, SEG do
        local u = k / SEG
        -- turn rate in radians per unit length; the bias grows along the
        -- arm so the loop, if any, is out at the tip
        local turn = (bias * u * u + a1 * math.sin(u * f1 * 6.28 + p1) + a2 * math.sin(u * f2 * 6.28 + p2)) / len
        heading = heading + turn * ds
        x = x + math.cos(heading) * ds
        y = y + math.sin(heading) * ds
        pts[#pts + 1] = { x = x, y = y, w = w0 * (1 - u) + 0.7 }
    end
    return pts
end

function Tentacles.draw(o)
    local n     = o.count or 7
    local grow  = o.grow == nil and 1 or o.grow
    if grow <= 0 then return end
    local reach = o.reach or 260
    local ink   = o.color or INK
    local alpha = o.alpha or 0.9
    -- grow fast, settle slow at the tips
    local g = 1 - (1 - grow) ^ 1.8

    for i = 1, n do
        local len = reach * (0.5 + 0.5 * unit(o.seed, i, 11))
        local pts = armPath(o, i, len)
        local last = math.max(1, math.floor(#pts * g))
        -- body: quads between consecutive points, up to the grown tip
        Theme.setColor(ink, alpha)
        for k = 1, last - 1 do
            local a, b = pts[k], pts[k + 1]
            local tx, ty = b.x - a.x, b.y - a.y
            local l = math.sqrt(tx * tx + ty * ty)
            if l > 1e-6 then
                local nx, ny = -ty / l, tx / l
                love.graphics.polygon("fill",
                    a.x + nx * a.w, a.y + ny * a.w,
                    b.x + nx * b.w, b.y + ny * b.w,
                    b.x - nx * b.w, b.y - ny * b.w,
                    a.x - nx * a.w, a.y - ny * a.w)
            end
        end
        local tip = pts[last]
        love.graphics.circle("fill", tip.x, tip.y, tip.w)
        -- the tube's highlight: a thin lighter line down the middle
        if last >= 2 then
            local line = {}
            for k = 1, last do line[#line + 1] = pts[k].x; line[#line + 1] = pts[k].y end
            Theme.setColor(CORE, alpha * 0.55)
            love.graphics.setLineWidth(1)
            love.graphics.line(line)
        end
        -- ribs: short ticks across the arm every few segments, the rings
        -- on the reference tentacles
        Theme.setColor(ink, alpha)
        love.graphics.setLineWidth(1)
        for k = 2, last - 1, 3 do
            local a, b = pts[k], pts[k + 1]
            local tx, ty = b.x - a.x, b.y - a.y
            local l = math.sqrt(tx * tx + ty * ty)
            if l > 1e-6 then
                local nx, ny = -ty / l, tx / l
                local r = a.w + 1.2
                love.graphics.line(a.x + nx * r, a.y + ny * r, a.x - nx * r, a.y - ny * r)
            end
        end
    end
    love.graphics.setLineWidth(1)
end

return Tentacles
