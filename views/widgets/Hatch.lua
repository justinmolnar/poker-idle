-- views/widgets/Hatch.lua
--
-- Faint diagonal hatching over a rect, in the theme's disabled ink: the
-- quiet "nobody presses this for you" mark. A table's DEAL button wears
-- it while the cursors don't deal there, and so does an add-table row or
-- the Cursor upgrade whose tables they don't deal at (views/TablePanel,
-- views/ComponentRenderer). Clipped by geometry, so it draws the same
-- inside a scrolled or cached panel. Still: it never moves.

local Theme = require("views.Theme")

local Hatch = {}

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

-- Hatch (x, y, w, h): lines at 45 degrees, `spacing` apart and `width`
-- thick, in Theme.fg.disabled at `alpha`.
function Hatch.draw(x, y, w, h, alpha, spacing, width)
    spacing = spacing or 8
    width   = width or 1.5
    Theme.setColor(Theme.fg.disabled, alpha or 0.22)
    for o = x - h, x + w, spacing do
        local poly = clip({ o, y + h, o + width, y + h, o + width + h, y, o + h, y },
                          x, y, x + w, y + h)
        if #poly >= 6 then love.graphics.polygon("fill", poly) end
    end
end

return Hatch
