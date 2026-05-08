-- views/CardSprites.lua
--
-- Card-sprite primitives shared by the grind table panels and the shove
-- gauntlet. Both screens draw cards into rects the same way: tinted sprite
-- from the atlas, recoloured Theme fallback when the atlas is missing,
-- empty-slot placeholder for not-yet-dealt cards, optional horizontal
-- squash for flip animations, and a stroke-outline helper for the best-5
-- highlight pass. Centralized here so the visual treatment stays in lockstep.

local Theme          = require("views.Theme")
local SpriteRenderer = require("services.SpriteRenderer")

local CardSprites = {}

-- Card back. Atlas-missing fallback is a dark sunken rect with a default-
-- border outline so the table still reads as "cards in a slot."
function CardSprites.back(atlas, sprite_name, x, y, w, h, alpha)
    alpha = alpha or 1
    if atlas then
        SpriteRenderer.draw(atlas, sprite_name, x, y, w, h, { 1, 1, 1, alpha })
    else
        Theme.setColor(Theme.bg.sunken, alpha)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
        Theme.setColor(Theme.border.default, alpha)
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    end
end

-- Card front from a Card model. Skips draw if `card` is nil.
function CardSprites.front(atlas, card, x, y, w, h, alpha)
    if not card then return end
    alpha = alpha or 1
    if atlas then
        SpriteRenderer.draw(atlas, card:spriteName(), x, y, w, h, { 1, 1, 1, alpha })
    else
        Theme.setColor(Theme.bg.widget_hover, alpha)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    end
end

-- Empty-slot placeholder for cards not yet dealt.
function CardSprites.slot(x, y, w, h)
    Theme.setColor(Theme.bg.sunken, 0.5)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.soft, 0.6)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
end

-- Sprite-by-name with optional horizontal squash (for flip animations).
-- `scale_x ∈ [0, 1]` shrinks horizontally; the squashed sprite is
-- recentered on the original slot's center so the flip stays anchored.
function CardSprites.sprite(atlas, sprite_name, x, y, w, h, scale_x, alpha)
    scale_x = scale_x or 1
    alpha   = alpha   or 1
    local effective_w = w * scale_x
    local actual_x    = x + (w - effective_w) / 2
    SpriteRenderer.draw(atlas, sprite_name, actual_x, y, effective_w, h, { 1, 1, 1, alpha })
end

-- Outline a card slot. `inset > 0` draws inside the card, `inset < 0`
-- draws outside. Used for the player/dealer best-5 highlights.
function CardSprites.strokeSlot(x, y, w, h, inset, lw)
    love.graphics.setLineWidth(lw)
    love.graphics.rectangle("line",
        x + inset, y + inset, w - 2 * inset, h - 2 * inset,
        Theme.space.radius)
    love.graphics.setLineWidth(1)
end

return CardSprites
