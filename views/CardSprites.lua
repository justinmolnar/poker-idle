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
-- BACKS plate only when the layout says so (`card.back_plate_below_w`, a
-- separate threshold, published per band as `back_plate`), and the plate is
-- the colour the deck's art reads as from afar, taken off the pixels once
-- at load by services/SpriteLoader. The deck a player picked and levelled
-- stays on screen as its colour where the pattern was a few pixels of
-- noise. Above the threshold the mip chain still hands back a level sized
-- for the draw.
-- A back called with no decision never plates, so flights and the deck
-- flyer draw art at any size.
--
-- Callers may FORCE a front's decision with the trailing `plate` argument.
-- views/TablePanel does: its showdown pass redraws the winning cards up to
-- 1.26x larger, and a per-call size test would flip a card near the threshold
-- between art and plate mid-animation.

local Theme          = require("views.Theme")
local SpriteRenderer = require("services.SpriteRenderer")
local FontService    = require("services.FontService")
local FeltData       = require("data.felt_layout")
local FeltStyle      = require("data.felt_style")

local CardSprites = {}

-- Every rank as ONE character, so a plate never has to fit two glyphs.
-- "T" for ten is the standard poker shorthand.
local RANK_GLYPH = {
    ["10"] = "T", j = "J", q = "Q", k = "K", a = "A",
}

local RED_SUIT = { hearts = true, diamonds = true }

-- Card drop shadow. Near-black rather than a theme token: it is a shadow cast
-- onto the felt, so it should not carry the palette's hue.
local SHADOW_COLOR = { 0, 0, 0 }
local SHADOW_ALPHA = (FeltStyle.shadow and FeltStyle.shadow.alpha) or 0.3

-- The white tint every sprite draw hands SpriteRenderer, with the alpha
-- written in: one table, not one per card per frame. SpriteRenderer reads
-- it at once and keeps no reference.
local _tint = { 1, 1, 1, 1 }
local function tintAlpha(a) _tint[4] = a; return _tint end

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

-- The shared plate body: an edge-coloured rect with the fill inset one
-- pixel, which reads as fill + 1px outline. Two fills rather than a fill
-- and a "line" rect: line mode tessellates joins and does not batch, and
-- a 36-table board draws hundreds of these. Returns nothing; callers add
-- whatever mark goes on top.
local function plateBody(x, y, w, h, fill, edge, alpha)
    local r = plateRadius(w, h)
    Theme.setColor(edge, alpha)
    love.graphics.rectangle("fill", x, y, w, h, r)
    if w > 2 and h > 2 then
        Theme.setColor(fill, alpha)
        love.graphics.rectangle("fill", x + 1, y + 1, w - 2, h - 2, math.max(0, r - 1))
    end
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

-- Drop shadow under a card: the same rect, offset down-right, near-black at
-- low alpha. The cheapest thing that makes a card sit ON the table instead of
-- floating over it.
--
-- `off` comes from the LAYOUT (views/FeltLayout publishes it per band), not
-- from a size test here — the showdown pop redraws the winning cards up to
-- 1.26x larger, and a per-call test would hand a shadow to a card that didn't
-- have one a moment earlier. off == 0 means this band is too small for a
-- shadow to be anything but a darker card edge, so nothing draws.
function CardSprites.shadow(x, y, w, h, alpha, off)
    off = off or 0
    if off <= 0 then return end
    Theme.setColor(SHADOW_COLOR, (alpha or 1) * SHADOW_ALPHA)
    love.graphics.rectangle("fill", x + off, y + off, w, h, plateRadius(w, h))
end

-- A seat that is out of the hand: folded, or busted in a chip-stack
-- tournament. A flat muted slab, no deck art and no rank.
--
-- This REPLACES the representation rather than only dimming it. A card back at
-- 30% opacity still carries every bit of detail a live one does, so telling
-- who is still in takes a second look; a live seat's deck art beside a flat
-- grey slab reads instantly, and keeps reading at nine pixels wide, which is
-- exactly where the alpha-only treatment failed hardest.
function CardSprites.folded(x, y, w, h, alpha)
    plateBody(x, y, w, h, Theme.bg.sunken, Theme.border.soft, alpha or 1)
end

-- ── Held cards: every shadow first, then every card ─────────────────
-- A band draws shadow, card, shadow, card, and every untextured rect
-- between two sprites breaks the sprite batch, so ten backs on one texture
-- were ten draw calls. While a batch is open, `back` and `front` record
-- their arguments instead of drawing and `batchEnd` replays them in call
-- order; the shadows, drawn immediately by the callers, all land first.
-- Deferring the cards rather than hoisting the shadows means no caller has
-- to repeat the state logic (folded, dealt, mid-flip, revealed) that
-- decides which cards exist this frame.
--
-- Records are pooled by index and overwritten, so a steady frame allocates
-- nothing here. The replay clears the flag FIRST so a replayed call cannot
-- re-enqueue itself.
local _batching = false
local _q, _qn = {}, 0

local function enqueue(kind, atlas, what, x, y, w, h, alpha, plate, flash)
    _qn = _qn + 1
    local r = _q[_qn]
    if not r then r = {}; _q[_qn] = r end
    r.kind, r.atlas, r.what = kind, atlas, what
    r.x, r.y, r.w, r.h = x, y, w, h
    r.alpha, r.plate, r.flash = alpha, plate, flash
end

function CardSprites.batchBegin()
    _batching = true
    _qn = 0
end

function CardSprites.batchEnd()
    if not _batching then return end
    _batching = false
    local n = _qn
    _qn = 0
    for i = 1, n do
        local r = _q[i]
        if r.kind == "back" then
            CardSprites.back(r.atlas, r.what, r.x, r.y, r.w, r.h, r.alpha, r.plate, r.flash)
        else
            CardSprites.front(r.atlas, r.what, r.x, r.y, r.w, r.h, r.alpha, r.plate)
        end
        -- Nothing pinned past the frame.
        r.atlas, r.what = nil, nil
    end
end

-- The back as a plate: the deck's distance colour with a darker edge of
-- the same hue. What a narrow back draws (see the header), and what the deal
-- flip's first half draws at the squashed width so a card does not turn
-- from a plate into art mid-turn.
local _edge = {}
function CardSprites.backPlate(atlas, sprite_name, x, y, w, h, alpha)
    local fill = atlas and atlas.backColor and atlas:backColor(sprite_name)
                 or Theme.bg.sunken
    plateBody(x, y, w, h, fill, Theme.darken(fill, 0.6, _edge), alpha or 1)
end

-- Card back. The deck's art through the mip chain, or its plate when the
-- layout has decided this band is too narrow for art (`plate == true`;
-- nil and false both draw art, so a caller with no layout decision gets
-- what it always got). `flash` is the deck level-up pulse, 0..1: a gold
-- wash over the back, drawn here so it stays on top when backs are held
-- for a batch (batchBegin below).
--
-- Atlas-missing fallback is a dark sunken rect with a default-border outline
-- so the table still reads as "cards in a slot."
function CardSprites.back(atlas, sprite_name, x, y, w, h, alpha, plate, flash)
    alpha = alpha or 1
    if _batching then
        enqueue("back", atlas, sprite_name, x, y, w, h, alpha, plate, flash)
        return
    end
    if plate == true then
        CardSprites.backPlate(atlas, sprite_name, x, y, w, h, alpha)
    elseif atlas then
        SpriteRenderer.draw(atlas, sprite_name, x, y, w, h, tintAlpha(alpha))
    else
        Theme.setColor(Theme.bg.sunken, alpha)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
        Theme.setColor(Theme.border.default, alpha)
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    end
    if flash and flash > 0 then
        local gold = Theme.currency and Theme.currency.chip or Theme.fg.heading
        Theme.setColor(gold, flash * 0.55 * alpha)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    end
end

-- Card front from a Card model. Skips draw if `card` is nil.
function CardSprites.front(atlas, card, x, y, w, h, alpha, plate)
    if not card then return end
    alpha = alpha or 1
    if _batching then
        enqueue("front", atlas, card, x, y, w, h, alpha, plate, nil)
        return
    end
    if usePlate(w, plate) then
        frontPlate(card, x, y, w, h, alpha)
        return
    end
    if atlas then
        SpriteRenderer.draw(atlas, card:spriteName(), x, y, w, h, tintAlpha(alpha))
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
-- `rot` (radians, optional) turns the card about its centre — a dealt card
-- settling square.
function CardSprites.sprite(atlas, sprite_name, x, y, w, h, scale_x, alpha, rot)
    scale_x = scale_x or 1
    alpha   = alpha   or 1
    local effective_w = w * scale_x
    local actual_x    = x + (w - effective_w) / 2
    if rot and rot ~= 0 then
        local cx, cy = x + w / 2, y + h / 2
        love.graphics.push()
        love.graphics.translate(cx, cy)
        love.graphics.rotate(rot)
        love.graphics.translate(-cx, -cy)
        SpriteRenderer.draw(atlas, sprite_name, actual_x, y, effective_w, h, tintAlpha(alpha))
        love.graphics.pop()
        return
    end
    SpriteRenderer.draw(atlas, sprite_name, actual_x, y, effective_w, h, tintAlpha(alpha))
end

-- A card with a letter on it: the plate body (bone face, black edge) and
-- one glyph of `font` centred on it, turned about the card's centre by
-- `rot` and squashed across by `scale_x` (a flip mid-turn). The title
-- deals its name as these.
function CardSprites.letter(x, y, w, h, glyph, font, alpha, rot, scale_x)
    alpha = alpha or 1
    scale_x = scale_x or 1
    local transformed = (rot and rot ~= 0) or scale_x ~= 1
    if transformed then
        local cx, cy = x + w / 2, y + h / 2
        love.graphics.push()
        love.graphics.translate(cx, cy)
        if rot and rot ~= 0 then love.graphics.rotate(rot) end
        love.graphics.scale(scale_x, 1)
        love.graphics.translate(-cx, -cy)
    end
    plateBody(x, y, w, h, Theme.card.face, Theme.card.black, alpha)
    if glyph and glyph ~= "" and font then
        local prev = love.graphics.getFont()
        love.graphics.setFont(font)
        Theme.setColor(Theme.card.black, alpha)
        love.graphics.print(glyph,
            math.floor(x + (w - font:getWidth(glyph)) * 0.5),
            math.floor(y + (h - font:getHeight()) * 0.5))
        if prev then love.graphics.setFont(prev) end
    end
    if transformed then love.graphics.pop() end
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
