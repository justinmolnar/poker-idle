-- views/widgets/Caution.lua
--
-- Caution tape: a border of yellow and black diagonal stripes, crawling
-- slowly along. It marks a thing the cursors don't deal at: a table, an
-- add-table row, the Cursor upgrade (views/GrindView, views/
-- ComponentRenderer). The stripes are clipped by geometry, not a scissor,
-- so it draws the same inside a scrolled or cached panel.

local Motion = require("services.Motion")

local Caution = {}

Caution.YELLOW = { 0.96, 0.78, 0.12 }
Caution.BLACK  = { 0.09, 0.08, 0.07 }

-- Clip a convex polygon (flat {x1, y1, ...}) to an axis-aligned rect.
local function clip(poly, x0, y0, x1, y1)
    local function edge(pts, inside, cross)
        local out, n = {}, #pts
        if n == 0 then return out end
        local px, py = pts[n - 1], pts[n]
        for i = 1, n, 2 do
            local cx, cy = pts[i], pts[i + 1]
            local cin, pin = inside(cx, cy), inside(px, py)
            if cin then
                if not pin then local ix, iy = cross(px, py, cx, cy); out[#out + 1] = ix; out[#out + 1] = iy end
                out[#out + 1] = cx; out[#out + 1] = cy
            elseif pin then
                local ix, iy = cross(px, py, cx, cy); out[#out + 1] = ix; out[#out + 1] = iy
            end
            px, py = cx, cy
        end
        return out
    end
    local function atX(xv) return function(ax, ay, bx, by)
        local t = (xv - ax) / (bx - ax); return xv, ay + (by - ay) * t end end
    local function atY(yv) return function(ax, ay, bx, by)
        local t = (yv - ay) / (by - ay); return ax + (bx - ax) * t, yv end end
    poly = edge(poly, function(x) return x >= x0 end, atX(x0))
    poly = edge(poly, function(x) return x <= x1 end, atX(x1))
    poly = edge(poly, function(_, y) return y >= y0 end, atY(y0))
    poly = edge(poly, function(_, y) return y <= y1 end, atY(y1))
    return poly
end

-- One strip of tape filling the rect (x, y, w, h); stripes at 45 degrees,
-- `period` apart, shifted by `phase` pixels.
local function strip(x, y, w, h, period, phase, alpha)
    love.graphics.setColor(Caution.YELLOW[1], Caution.YELLOW[2], Caution.YELLOW[3], alpha)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(Caution.BLACK[1], Caution.BLACK[2], Caution.BLACK[3], alpha)
    local half = period / 2
    local start = x - h - period + (phase % period)
    for o = start, x + w, period do
        local poly = clip({ o, y + h, o + half, y + h, o + half + h, y, o + h, y }, x, y, x + w, y + h)
        if #poly >= 6 then love.graphics.polygon("fill", poly) end
    end
end

-- The phase the tape crawls at, in pixels; still under reduced motion.
function Caution.phase(speed)
    if not Motion.at("ui", Motion.MEDIUM) then return 0 end
    return (love.timer.getTime() * (speed or 14))
end

-- A full frame of tape `thick` wide just inside (x, y, w, h).
function Caution.frame(x, y, w, h, thick, alpha, phase)
    alpha = alpha or 1
    phase = phase or Caution.phase()
    local period = thick * 2
    strip(x, y, w, thick, period, phase, alpha)                       -- top
    strip(x, y + h - thick, w, thick, period, -phase, alpha)          -- bottom
    strip(x, y + thick, thick, h - thick * 2, period, phase, alpha)   -- left
    strip(x + w - thick, y + thick, thick, h - thick * 2, period, -phase, alpha) -- right
end

-- One edge of tape: a strip down the left side (a partial "some of these").
function Caution.edge(x, y, h, thick, alpha, phase)
    strip(x, y, thick, h, thick * 2, phase or Caution.phase(), alpha or 1)
end

-- A plate of tape with a label in black on it, centred at (cx, y).
function Caution.plate(text, font, cx, y, alpha, phase)
    alpha = alpha or 1
    local pad_x = math.floor(font:getHeight() * 0.7)
    local tw = font:getWidth(text)
    local w, h = tw + pad_x * 2, font:getHeight() + math.floor(font:getHeight() * 0.35)
    local x = math.floor(cx - w / 2)
    local band = math.max(3, math.floor(h * 0.22))
    strip(x, y, w, band, band * 2, phase or Caution.phase(), alpha)
    strip(x, y + h - band, w, band, band * 2, -(phase or Caution.phase()), alpha)
    love.graphics.setColor(Caution.YELLOW[1], Caution.YELLOW[2], Caution.YELLOW[3], alpha)
    love.graphics.rectangle("fill", x, y + band, w, h - band * 2)
    love.graphics.setColor(Caution.BLACK[1], Caution.BLACK[2], Caution.BLACK[3], alpha)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    love.graphics.setFont(font)
    love.graphics.print(text, x + pad_x, y + math.floor((h - font:getHeight()) / 2))
    return w, h
end

return Caution
