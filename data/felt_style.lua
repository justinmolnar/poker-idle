-- data/felt_style.lua
--
-- Decorative knobs for the poker-table felt: the rail, the community plate,
-- card drop shadows, seat plates, the dealer button, and the vignette.
-- Sibling of data/felt_layout.lua, which owns the STRUCTURAL layout
-- (band sizes, card fractions, shed thresholds). Split so "where does a card
-- go" and "what does the table look like" are separate files: the first is
-- load-bearing, the second is taste.
--
-- Tables only: no functions and no requires (data/ stays logic-free per the
-- architecture rules). Consumed by views/FeltLayout (which makes every gate
-- decision and publishes the result) and views/FeltDecor (which draws it).
--
-- ── The gate rule ────────────────────────────────────────────────────
-- Every ornament here has a MINIMUM, and it is measured against the dimension
-- that actually constrains that ornament -- not against a tier enum, and not
-- against the panel count. A rail is bounded by felt HEIGHT (it is the scarce
-- axis, and steps 1-4 of the felt work fought to reclaim it); shadows and the
-- community plate by CARD width; the dealer button by its own diameter.
--
-- This is what keeps 32 tables from turning to mud. At the fixed 1600x900 base
-- resolution the felt runs from 635x444 (1 table) down to 139x91 (32), and an
-- ornament drawn unconditionally at 139x91 is a smear that costs pixels the
-- cards need. Below its gate an ornament is ABSENT, not shrunk -- the same
-- shrink-then-drop discipline the names, the pot pile and the card plates
-- already follow.
--
-- Roughly what each threshold buys, in tables (see views/FeltLayout for the
-- authoritative decisions):
--   rail          1-16      comm plate  1-16
--   card shadow   comm 1-9 / hole 1-32 / opp 1-4
--   seat plate    1-4 (tied to the NAME flag, not a size of its own)
--   button        1-9       vignette every size
return {
    -- Felt color derivation (views/TablePanel.feltForStake): every room
    -- is constructed at the SAME luminance and the SAME chroma, and takes
    -- only its HUE from the stake's felt chip (a hueless chip = the
    -- classic green room). Uniform by construction: no room can be
    -- brighter or louder than another, and no knob setting can collapse
    -- two hues into the same mud. Audit with `lua sim/felt_check.lua`,
    -- which flags any pair of rooms that read alike.
    color = {
        -- Room brightness: base felt luma × this. One value for ALL
        -- stakes — "early stakes brighter than late" was never a design
        -- rule; the tier reads from hue alone.
        luma       = 1.10,
        -- Room color-strength. The normalizer: every room carries exactly
        -- this much color away from neutral, so they mute together as one
        -- family. Raise for louder rooms, lower for grayer — hue spacing
        -- is unaffected either way.
        chroma     = 0.06,
        -- Below this chip chroma the chip is considered hueless (white,
        -- black) and the room falls back to the base green's hue.
        min_chroma = 0.06,
    },

    -- Felt vignette. A radial alpha ramp darkening the felt toward its edges
    -- so the centre reads lit instead of the surface reading as one flat fill.
    -- Always on: it is a single stretched texture, so it costs one batched
    -- draw per panel at any size and it is the only thing 32 tables gain.
    vignette = {
        -- Mask resolution. Small on purpose -- it is stretched to the felt
        -- rect, and bilinear magnification of a smooth ramp is exactly what
        -- gives a band-free gradient. Bigger buys nothing.
        mask_px      = 64,
        -- Normalised radius (centre = 0, edge = 1, corner ~= 1.41) where the
        -- darkening starts and where it saturates.
        inner        = 0.55,
        outer        = 1.30,
        -- Ramp shape. >1 keeps the middle of the felt clean and pushes the
        -- falloff out toward the rail.
        power        = 1.60,
        -- Resting darkness at the corners. Deliberately subtle: this sits
        -- under every card and chip on the table.
        static_alpha = 0.22,
        -- The win/loss flash (views/TablePanelEffects) reuses the same mask.
        -- It keeps a flat wash so a big result is unmissable at a glance, and
        -- adds the mask on top so the edges bloom. flash_flat + flash_mask is
        -- what replaces the old flat-only wash.
        flash_flat   = 0.35,
        flash_mask   = 1.00,
    },

    -- The rail: RETIRED (2026-08-28). The game type's color moved to the
    -- header chrome (data/game_type_themes.lua `chrome_color`, consumed in
    -- TablePanel.drawHeader) — a ring spent card pixels to say what one
    -- painted bar says for free at any panel size. The gate below is
    -- pinned unreachable rather than the code ripped, so re-enabling it
    -- is one number; if it ever comes back it needs a color key again.
    rail = {
        min_felt_h = 1e9,   -- pinned: no felt is ever this tall (retired)
        frac       = 0.035, -- width as a fraction of the felt's SHORT side
        min_w      = 2,
        max_w      = 10,
        -- FALLBACK ONLY. The ring's colour is game_type_themes' `rail_color`,
        -- an authored material per game type; this multiplier only applies when
        -- the type has none, where the default border token stands in and needs
        -- pulling down so it reads as a ring instead of a trim line.
        darken     = 0.45,
        -- Inner edge line at the surface boundary, so the felt reads as sunk
        -- into the ring instead of painted on it.
        edge_alpha = 0.55,
        -- Corner radius = min(radius_max, short_side / radius_div). A big felt
        -- gets a visibly rounded table; a small one stays crisp.
        radius_div = 12,
        radius_max = 8,
    },

    -- (A betting arc lived here and was cut. It anchored to the top of the pot
    -- band, which is exactly where the pot pile grows UP over the community
    -- row, so the line ran through the board cards -- and on a rectangular
    -- felt an arc has no silhouette to belong to, so it read as a stray
    -- scratch rather than the edge of a table.)

    -- Recessed strip behind the five community slots, so empty slots read as
    -- places at the table rather than holes in the felt.
    -- Gated on COMMUNITY CARD width -- it is that row's backing.
    comm_plate = {
        min_card_w = 20,
        pad_x      = 6,
        pad_y      = 4,
        darken     = 0.55,
        alpha      = 0.30,
    },

    -- Card drop shadows. The cheapest thing that makes a card sit ON the table
    -- instead of floating over it.
    --
    -- Gated on CARD width, decided once per band (community / hole / opponent)
    -- rather than per draw, so the showdown pop -- which redraws the winning
    -- cards up to 1.26x larger -- cannot hand a shadow to a card that did not
    -- have one. Same reason the card-art `plate` flag is decided per band.
    shadow = {
        min_card_w = 24,
        -- Offset in px at a 1.0 panel scale, floored at 1: below 1px there is
        -- no shadow to draw, only a darker card edge.
        offset     = 2,
        alpha      = 0.30,
    },

    -- Seat plate: the backing behind an opponent's name + cards, so a seat
    -- reads as a position rather than two cards floating in space.
    --
    -- NOT gated on a size of its own -- it is gated on the seat NAME flag
    -- (views/FeltLayout's show_names). The plate IS the nameplate, so one flag
    -- governs one idea and there is no felt size where a plate frames nothing.
    seat_plate = {
        pad_x  = 3,
        pad_y  = 2,
        darken = 0.60,
        alpha  = 0.26,
    },

    -- Dealer button. Moves seat to seat every hand, which is the clearest
    -- signal on the felt that a hand is actually being played here.
    -- Gated on its own DIAMETER: under min_d it is an indistinct dot.
    button = {
        min_d     = 8,
        card_frac = 0.45,   -- diameter as a fraction of the seat's card width
        max_d     = 22,
        gap       = 3,      -- gap between the button and the cards it marks
    },

    -- Last-hand residue: the finished hand held on an idle felt until the
    -- next deal. The whole scene draws through the desaturate shader —
    -- desat is the greyscale mix at rest (0 = full color, 1 = grey), and
    -- ease_secs is how long the scene takes to "go cold" after the hand
    -- ends. The affordance on top (rim + label) stays full-color.
    residue = {
        desat       = 0.85,
        ease_secs   = 0.35,
        rim_alpha   = 0.25,  -- felt-edge rim at rest
        rim_hover   = 0.90,  -- rim while the pointer is on the felt
        wash_hover  = 0.10,  -- felt-wide color wash while hovered
    },
}
