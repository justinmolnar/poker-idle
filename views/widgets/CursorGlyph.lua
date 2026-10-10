-- views/widgets/CursorGlyph.lua
--
-- The cursors' own arrow, as a control's face: lit when the cursors deal
-- there, struck through with a heavy red slash when they don't. One look
-- for every cursor switch (a table's header, an add-table row, the Cursor
-- upgrade), the same arrow the swarm flies (services/CursorPool).

local Theme = require("views.Theme")

local CursorGlyph = {}

-- The swarm's arrow (services/CursorPool CURSOR_POLY), 15 x 24.
local POLY = { 0, 0, 15, 15, 8, 15, 12, 23, 9, 24, 5, 16, 0, 21 }
local TRIS = love.math.triangulate and love.math.triangulate(POLY) or { POLY }

-- Draw the glyph fitted into (x, y, w, h). `off` = the cursors don't deal
-- here; `alpha` scales it all.
function CursorGlyph.draw(x, y, w, h, off, alpha)
    alpha = alpha or 1
    local sc = math.min(w / 15, h / 24)
    local gx = x + (w - 15 * sc) / 2
    local gy = y + (h - 24 * sc) / 2
    love.graphics.push()
    love.graphics.translate(math.floor(gx), math.floor(gy))
    love.graphics.scale(sc, sc)
    Theme.setColor(off and Theme.fg.disabled or Theme.fg.heading, alpha)
    for _, tri in ipairs(TRIS) do love.graphics.polygon("fill", tri) end
    Theme.setColor(Theme.bg.window, alpha)
    love.graphics.setLineWidth(1 / sc)
    love.graphics.polygon("line", POLY)
    love.graphics.pop()
    if off then
        -- The slash, corner to corner across the whole face, thick enough
        -- to read at a glance on a busy board.
        local lw = math.max(2, math.floor(math.min(w, h) * 0.16))
        Theme.setColor(Theme.sem.lost, alpha)
        love.graphics.setLineWidth(lw)
        love.graphics.line(x + lw * 0.5, y + h - lw * 0.5, x + w - lw * 0.5, y + lw * 0.5)
        love.graphics.setLineWidth(1)
    end
end

return CursorGlyph
