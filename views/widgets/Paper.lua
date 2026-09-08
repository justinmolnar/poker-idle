-- views/widgets/Paper.lua
--
-- The shared mechanics of the game's paper surfaces: the catalog book
-- (views/CatalogModal), the deck flyer (views/DeckFlyer) and the receipt
-- (views/CatalogReceipt).
--
-- Those three grew independently and ended up with the same code under
-- different names — the hinge flip was byte-identical in two of them, down
-- to the cull threshold, and the scrim was the same two lines in three
-- places. The throw itself was already shared (services/Throw); this is the
-- rest of it.
--
-- Nothing here owns state. Each surface keeps its own timers and content
-- and calls these for the parts that are common, which keeps the change
-- additive: no surface has to hand over its layout to adopt one piece.

local Theme = require("views.Theme")

local Paper = {}

-- Below this much horizontal squash a page is a hairline and drawing it
-- costs more than it shows.
local FLIP_CULL = 0.02

-- Draw `fn` horizontally squashed about a vertical hinge — a page caught
-- mid-turn. `sx` is 1 flat-open and 0 edge-on.
--
-- This was `drawFlipped` in CatalogModal and `hinged` in DeckFlyer, the
-- same seven lines twice.
function Paper.hinge(hinge_x, sx, fn)
    if sx <= FLIP_CULL then return end
    love.graphics.push()
    love.graphics.translate(hinge_x, 0)
    love.graphics.scale(sx, 1)
    love.graphics.translate(-hinge_x, 0)
    fn()
    love.graphics.pop()
end

-- A page turn runs in two halves: the leaving face closes to edge-on, then
-- the arriving face opens flat. `t` is the turn's progress, 0 to 1.
-- Returns which half, and that half's own 0..1 squash — the
-- `1 - t*2` / `(t - 0.5) * 2` pair that was written out eight times between
-- the two files.
--
--   local half, sx = Paper.turnHalf(t)
--   if half == "closing" then ... else ... end
function Paper.turnHalf(t)
    if t < 0.5 then return "closing", 1 - t * 2 end
    return "opening", (t - 0.5) * 2
end

-- The dimming wash behind an open surface. One token, one rect — and the
-- same two lines that appeared in the catalog, the flyer and the modal
-- frame.
function Paper.scrim(alpha)
    local W, H = love.graphics.getDimensions()
    Theme.setColor(Theme.debug.hud_bg, alpha)
    love.graphics.rectangle("fill", 0, 0, W, H)
end

-- Is (mx, my) inside a rect list entry? Every paper surface keeps a list of
-- per-frame rects (`_cells`, `_tiles`, `_row_rects`) and walks it with the
-- same predicate written out longhand.
function Paper.hit(rects, mx, my)
    for i = 1, #(rects or {}) do
        local r = rects[i]
        local x, w = r.x or -math.huge, r.w or math.huge
        if mx >= x and mx < x + w and my >= r.y and my < r.y + r.h then
            return r
        end
    end
    return nil
end

return Paper
