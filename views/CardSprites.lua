-- views/CardSprites.lua
--
-- Card-sprite primitives shared by the grind table panels and the shove
-- gauntlet. Both screens draw cards into rects the same way: tinted sprite
-- from the atlas, recoloured Theme fallback when the atlas is missing,
-- empty-slot placeholder for not-yet-dealt cards, optional horizontal
-- squash for flip animations, and a stroke-outline helper for the best-5
-- highlight pass. Centralized here so the visual treatment stays in lockstep.
--
-- ── The small-card plate (FRONTS only) ───────────────────────────────
-- Card fronts are 56x80 native and their rank sits in a ~6px corner glyph, so
-- at some point the sprite cannot show a rank at ANY filtering. Below
-- `card.plate_below_w` (data/felt_layout) a front is replaced by a PLATE: a
-- card-shaped rect with the rank as a single 8px character (10 renders as T,
-- the poker shorthand, so every rank is one glyph) in the suit's colour. It
-- carries strictly more information than the shrunk sprite did, and it stays
-- legible until the card is too small to hold a glyph at all, at which point
-- the plate keeps the suit colour and drops the letter.
--
-- That threshold is deliberately LOW. The sprite is the nicer thing to look
-- at and the plate is a last resort, so a front keeps its art well past the
-- point where its rank stops being readable.
--
-- BACKS never plate, at any size. The deck a player picked and levelled is
-- bought content and has to be visible on every table, so services/SpriteLoader
-- keeps a mip chain for backs and hands back a level sized for the draw:
-- ugly-but-recognisable beats hidden.
--
-- Callers may FORCE a front's decision with the trailing `plate` argument.
-- views/TablePanel does: its showdown pass redraws the winning cards up to
-- 1.26x larger, and a per-call size test would flip a card near the threshold
-- between art and plate mid-animation.

local Theme          = require("views.Theme")
local SpriteRenderer = require("services.SpriteRenderer")
local FontService    = require("services.FontService")
local FeltData       = require("data.felt_layout")

local CardSprites = {}

-- Every rank as ONE character, so a plate never has to fit two glyphs.
-- "T" for ten is the standard poker shorthand.
local RANK_GLYPH = {
    ["10"] = "T", j = "J", q = "Q", k = "K", a = "A",
}

local RED_SUIT = { hearts = true, diamonds = true }

-- Set by CardSprites.configure at boot / resize. Nil until then, in which
-- case a plate draws its suit bar and skips the rank glyph.
local _font = nil

-- DI hook, same convention as views/Chips.configureFont and
-- views/Panel.configureFromFonts. Wired in main.lua.
function CardSprites.configure(fonts)
    _font = fonts and (fonts.sm or fonts.xs) or nil
end

-- Width below which a card is drawn as a plate instead of its sprite.
function CardSprites.plateBelow()
    return (FeltData.card and FeltData.card.plate_below_w) or 0
end

-- `plate` is tri-state: nil decides by width, true/false forces.
local function usePlate(w, plate)
    if plate ~= nil then return plate end
    return w < CardSprites.plateBelow()
end

-- Corner radius that still reads as a corner on a 14px card.
local function plateRadius(w, h)
    return math.min(Theme.space.radius, math.floor(math.min(w, h) / 4))
end

-- The shared plate body: fill + 1px outline. Returns nothing; callers add
-- whatever mark goes on top.
local function plateBody(x, y, w, h, fill, edge, alpha)
    local r = plateRadius(w, h)
    Theme.setColor(fill, alpha)
    love.graphics.rectangle("fill", x, y, w, h, r)
    love.graphics.setLineWidth(1)
    Theme.setColor(edge, alpha)
    love.graphics.rectangle("line", x, y, w, h, r)
end

-- Face-up plate: bone card, suit-coloured edge, rank glyph in the suit
-- colour. When the card is too small to hold a glyph the suit colour moves
-- to a bar across the lower half, so the card still says red or black.
local function frontPlate(card, x, y, w, h, alpha)
    local suit_color = RED_SUIT[card.suit] and Theme.card.red or Theme.card.black
    plateBody(x, y, w, h, Theme.card.face, suit_color, alpha)

    local glyph = RANK_GLYPH[card.rank] or tostring(card.rank):upper()
    if _font then
        local gw = _font:getWidth(glyph)
        local gh = FontService.inkHeight(_font)
        -- Measured against the INK, not the line box: an 8px face draws a
        -- 1.25em glyph inside a 2.625em box, so the box test would reject
        -- glyphs that fit the card with room to spare.
        if gw + 2 <= w and gh + 2 <= h then
            local prev = love.graphics.getFont()
            love.graphics.setFont(_font)
            Theme.setColor(suit_color, alpha)
            -- Centred on the LINE box, the convention every other view here
            -- uses (views/Panel, views/CatalogModal, views/Chips).
            love.graphics.print(glyph,
                math.floor(x + (w - gw) * 0.5),
                math.floor(y + (h - _font:getHeight()) * 0.5))
            if prev then love.graphics.setFont(prev) end
            return
        end
    end

    -- No room for a letter: the suit colour is the whole message.
    local bar_h = math.max(1, math.floor(h * 0.35))
    Theme.setColor(suit_color, alpha)
    love.graphics.rectangle("fill", x + 1, y + h - bar_h - 1,
                            math.max(1, w - 2), bar_h)
end

-- Card back. ALWAYS the deck's art, however small the card gets -- the deck is
-- something the player picked and levelled, so it stays on screen even when
-- it is nine pixels wide. services/SpriteLoader keeps a mip chain for backs so
-- those nine pixels are an average of the art rather than one sampled texel.
--
-- Atlas-missing fallback is a dark sunken rect with a default-border outline
-- so the table still reads as "cards in a slot."
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
function CardSprites.front(atlas, card, x, y, w, h, alpha, plate)
    if not card then return end
    alpha = alpha or 1
    if usePlate(w, plate) then
        frontPlate(card, x, y, w, h, alpha)
        return
    end
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
    love.graphics.rectangle("fill", x, y, w, h, plateRadius(w, h))
    Theme.setColor(Theme.border.soft, 0.6)
    love.graphics.rectangle("line", x, y, w, h, plateRadius(w, h))
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
