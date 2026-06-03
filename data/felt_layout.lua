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

    -- Heads-up duel seat: the single opponent gets a bigger seat than the
    -- per-seat boxes used for 6-max / 9-max.
    hu_seat = {
        min_w     = 180,  -- floor seat width
        extra_w   = 80,   -- added to opp_w*2 when sizing the seat
        card_mult = 2,    -- HU opponent cards render at 2× the base size
    },
}
