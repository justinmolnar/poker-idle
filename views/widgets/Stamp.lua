-- views/widgets/Stamp.lua
--
-- A rubber stamp: ink pressed INTO the page. Outlined box, no fill, the paper
-- showing through, banged down at an angle.
--
-- The opposite of views/widgets/Sticker, which is a separate piece of stock
-- laid ON the page. Keep the two distinct: a stamp has no background and no
-- edge of its own, a sticker has both.
--
-- Stateless — call Stamp.draw(...) per frame. The caller owns the rect, the
-- angle (see services/Decal for hand-applied placement) and the impact
-- progress (see services/Pop, which is exactly the 1→0 eased value this
-- wants).
--
-- opts:
--   x, y          (required)        — where the stamp's CENTRE lands
--   hw, hh        (required)        — half-width / half-height, already scaled
--   label         (string, required)
--   fonts / font  — DI'd font set; `font` overrides fonts.md
--   color_token   (token, default Theme.status.error) — ink
--   angle         (radians, default 0)
--   radius        (px, default 3)   — box corner
--   line_width    (px, default 2)
--   impact        (0..1, default 0) — 1 the instant it lands, easing to 0.
--                                     Drives the slam: the stamp arrives
--                                     oversized and pale, then settles to
--                                     full size and full ink.
--
-- The impact curve is deliberately "big and faint → true size and solid",
-- which is how a stamp reads coming down at the page. Scaling UP on arrival
-- would read as a stamp being lifted away instead.

local Theme = require("views.Theme")

local Stamp = {}

-- How much larger the stamp is at the moment of impact, and how transparent.
local IMPACT_SCALE = 0.85
local IMPACT_FADE  = 0.55

function Stamp.draw(opts)
    local font = opts.font or (opts.fonts and opts.fonts.md)
    if not font then return end

    local label  = opts.label or ""
    local ink    = opts.color_token or Theme.status.error
    local hit    = math.max(0, math.min(1, opts.impact or 0))
    local scale  = 1 + IMPACT_SCALE * hit
    local alpha  = (ink[4] or 1) * (1 - IMPACT_FADE * hit)

    local hw, hh = opts.hw or 0, opts.hh or 0
    local radius = opts.radius or 3
    local lw     = opts.line_width or 2

    love.graphics.push()
    love.graphics.translate(opts.x or 0, opts.y or 0)
    love.graphics.rotate(opts.angle or 0)
    love.graphics.scale(scale, scale)

    Theme.setColor(ink, alpha)
    love.graphics.setLineWidth(lw)
    love.graphics.rectangle("line", -hw, -hh, hw * 2, hh * 2, radius)
    love.graphics.setLineWidth(1)

    love.graphics.setFont(font)
    love.graphics.print(label, -font:getWidth(label) * 0.5, -font:getHeight() * 0.5)

    love.graphics.pop()
end

return Stamp
