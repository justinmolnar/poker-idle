-- data/felt_layout.lua
--
-- Pure-table structural layout config for the poker-table felt. Consumed by
-- views/FeltLayout (the layout calculator) and, through it, views/TablePanel.
-- Sibling of data/history_bars.lua — same "layout knobs as a data table" role.
--
-- Tables only: no functions and no pulling in code layers (data/ stays logic-
-- free per the architecture rules). All pixel values are 1× design-space;
-- views/FeltLayout scales them by the per-panel scale `s` at compute time.
return {
    -- Card WIDTH as a fraction of panel width (migrated verbatim from the
    -- *_CARD_W_FRAC locals that used to live in views/TablePanel). Heights
    -- derive from the 56:80 card-sprite aspect.
    card_frac = {
        player    = 0.130,
        community = 0.085,
        opponent  = 0.055,
    },

    -- Spacing knobs (scaled by the per-panel `s`).
    space = {
        edge_pad   = 6,   -- felt left/right inset for edge-anchored elements
        bottom_pad = 6,   -- gap between the bottom row and the felt border
        band_gap   = 4,   -- vertical gap between layout bands
        name_gap   = 2,   -- gap between an opponent's name and their cards
        comm_gap   = 6,   -- gap between community cards (a touch of breathing room)
        hole_gap   = 4,   -- gap between the two hole cards
        pot_gap    = 6,   -- gap between the community row and the pot pile/text
        you_pad    = 8,   -- inner padding flanking the centered EV readout
    },

    -- Chip-pile bounds, in COLUMNS (a column is up to 6 chips tall).
    -- A pile that runs out of room wraps onto staggered rows behind
    -- itself rather than throwing chips away, so these control how WIDE
    -- a pile gets, not how much of it you see.
    --
    -- Three across is what fits beside the community row without the pot
    -- pile creeping under the cards; the player's pile matches so the two
    -- read as the same object.
    pile = {
        -- The pot spreads as ONE long row for as much width as the felt
        -- gives it. No column cap here on purpose — an absent cap means
        -- unbounded, and the pixel budget (max_w) is what stops it.
        pot_rows     = 1,
        -- The player's pile is boxed in beside the hole cards, so it is
        -- capped narrow and wraps onto a second row behind itself.
        player_cols  = 3,
        player_rows  = 2,

        -- Chip DIAMETER as a fraction of the card it sits beside: the pot
        -- pile measures against a community card, the player's pile against
        -- a hole card. A real chip is about two thirds of a card's width.
        --
        -- Sizing the piles off card_scale instead (what this used to do) tied
        -- them to the chip's own base radius, so growing the chip art shrank
        -- every card on the felt and a chip ended up wider than the community
        -- card it was sitting on.
        chip_frac    = 0.65,
        -- Below this diameter a chip is a featureless dot, so the pot drops
        -- its pile entirely and the felt shows only "Pot: $X".
        min_chip_d   = 12,
    },

    -- Opponent seats. The name is pure flavor, and there is no font smaller
    -- than 8px to fall back on (FontService's xs tier resolves to the same
    -- 8px as sm at the fixed base resolution), so a name that doesn't fit
    -- its seat is DROPPED rather than truncated to a 4-character stub.
    opp = {
        name_min_chars = 8,   -- seat must afford this many chars or no name
        name_pad       = 6,   -- side padding flanking the name inside its seat
    },

    -- Card art. Below this drawn WIDTH a front drops its 56×80 sprite for a
    -- plate carrying its rank as one letter (views/CardSprites).
    --
    -- Kept low on purpose: the sprite is the nicer thing to look at, so a front
    -- holds its art well past the point where its corner rank (~6px native) is
    -- readable, and the plate only takes over where the card is too few pixels
    -- to be anything at all.
    --
    -- Card BACKS ignore this entirely and always draw the deck's art -- decks
    -- are bought content and belong on screen at every table size.
    -- services/SpriteLoader keeps a mip chain for them so the small ones
    -- average the art instead of sampling one texel of it.
    card = {
        plate_below_w = 16,
    },

    -- Heads-up duel seat: the single opponent gets a bigger seat than the
    -- per-seat boxes used for 6-max / 9-max.
    hu_seat = {
        min_w     = 180,  -- floor seat width
        extra_w   = 80,   -- added to opp_w*2 when sizing the seat
        card_mult = 2,    -- HU opponent cards render at 2× the base size
    },
}
