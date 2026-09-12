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
        -- Below this diameter a pile is drawn one COLUMN at a time (a bar
        -- with a disc on top, views/Chips.drawColumn) instead of one chip
        -- at a time. At that size a buried chip is a sliver a pixel tall,
        -- and the seven shading arcs it is painted with were the dearest
        -- thing on a 36-table board. Measured at 1600x900: the player's
        -- pile is 34px at 12 tables, 26 at 16, 20 at 24 and 12 at 36 (the
        -- pot pile is 22 at 12 tables and 17 at 16, and dropped by
        -- min_chip_d from 24 up). At 17 nothing changes through 16 tables
        -- or at 24; only the 12px stack at 36 draws as columns, which is
        -- where the chips were slivers anyway. One number; raise it to
        -- switch to columns sooner.
        micro_below_d = 17,
        -- ...but never below this many tables, whatever the size says. The
        -- diameter rule was measured on a Zoom felt at 1600x900; on a real
        -- board the pot chip sits at 16-17px from five tables up (the
        -- band solve shrinks the cards to fit the felt's height), so the
        -- size rule alone turned the pot into columns on a five-table
        -- board. The designer's rule is the theater's: nothing loses
        -- detail before 20 tables. Same count as anims.min_tables.
        micro_min_tables = 20,
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
    -- Backs have their own threshold. Below it a back is a flat plate in the
    -- deck's PRIMARY colour (services/SpriteLoader reads it off the art once
    -- at load), so the deck a player picked still shows as its colour on a
    -- 36-table board, where the pattern itself was a few pixels of noise
    -- costing a sprite draw, a mip lookup and a shadow apiece. Lower than
    -- the fronts' threshold: the designer wants the art wherever it is still
    -- art, and at 13 tables it still is. Measured at 1600x900 an opponent
    -- card is 22px at 12 tables, 16 at 16, 12 at 24 (all art) and 6 at 36
    -- (plate); the community and hole cards never cross it.
    card = {
        plate_below_w      = 16,
        back_plate_below_w = 10,
    },

    -- Per-hand animation, by how many tables are open. From `min_tables`
    -- up a table's hand plays with no theater at all: chips do not fly into
    -- the pot, folds do not muck, deals do not throw cards, the pot does not
    -- detonate on a stack win. At that density none of it reads as
    -- anything, and at 36 tables it was most of the frame; the hand still
    -- plays and its result still lands in the readouts. Counted, not
    -- measured: the board packs six wide in reading order, so 13 and 36
    -- tables share a panel width and only the count says how busy the
    -- screen is. The floating text ("+$0.04", the hand name) is the one
    -- piece of theater that stays at every count: the designer wants to
    -- see it always. `floaters_min_tables` is the knob if that changes;
    -- absent, it never fires.
    anims = {
        min_tables = 20,
    },

    -- Heads-up duel seat: the single opponent gets a bigger seat than the
    -- per-seat boxes used for 6-max / 9-max.
    hu_seat = {
        min_w     = 180,  -- floor seat width
        extra_w   = 80,   -- added to opp_w*2 when sizing the seat
        card_mult = 2,    -- HU opponent cards render at 2× the base size
    },
}
