-- data/shove_style.lua
--
-- Decorative knobs for the shove gauntlet's table: the felt band, its rim, the
-- spotlight, the recessed card slots, card shadows and the vignette. Sibling of
-- data/felt_style.lua, which does the same job for the grind felt.
--
-- Tables only: no functions and no requires (data/ stays logic-free per the
-- architecture rules). Consumed by views/ShoveView, which computes every rect
-- and hands it over, and views/ShoveDecor, which draws what it is handed.
--
-- ── There are no gates here, unlike data/felt_style ───────────────────
-- The felt runs from 635x444 down to 139x91 across 32 panels, so every ornament
-- there carries a MINIMUM measured against the dimension that constrains it.
-- The gauntlet is ONE full-screen view at a fixed base resolution: main.lua
-- pins 1600x900 and monkey-patches love.graphics.getDimensions, so ui_scale is
-- always 1.25 and ShoveView's recomputeLayout produces one answer forever. A
-- threshold here would be a branch that never fires, so these knobs are
-- dimensions and colours only. Copying the felt's shed ladder would be
-- cargo-culting the shape of that work without its reason.
--
-- ── `enabled` ─────────────────────────────────────────────────────────
-- Each ornament added after the ShoveDecor extraction carries one, so the
-- draw-trace harness can switch them all off and prove the op stream still
-- matches the pre-extraction capture byte for byte. They are authored values,
-- not runtime settings.
return {

    -- The felt band: a deep desaturated slab running the full width behind the
    -- card rows, so the cards land on a table instead of floating in a void.
    -- Deliberately NOT the grind table's green (Theme.bg.felt carries the
    -- colour per palette) so the gauntlet reads as a different, more serious
    -- room.
    band = {
        -- Soft fade above and below the slab, faked with one flat rect each
        -- rather than a mesh or a shader.
        fade_h     = 60,
        fade_alpha = 0.25,
        -- Thin rule at each edge, suggesting the rim of a table without
        -- committing to an elliptical felt sprite. Painted in the palette's
        -- strong border token, which is red under the shove palette.
        rule_alpha = 0.70,
    },

    -- The rail: a solid band along the top and bottom edge of the felt, with
    -- the playing surface recessed between them. Replaces the two 1px rules,
    -- which suggested a rim without ever reading as one.
    --
    -- Progresses by MATERIAL, not by brightness, and stays off gold -- the same
    -- call data/stake_themes made for the grind rails, because gold is the
    -- banked-bounty trim and nothing else should compete with it. This one is
    -- oxblood leather: it belongs to the shove palette's red without being the
    -- palette's alert red.
    rail = {
        enabled    = true,
        h          = 14,
        color      = { 0.21, 0.09, 0.09 },
        -- Inner edge at the surface boundary, so the felt reads as sunk into
        -- the rail rather than painted on it.
        edge_alpha = 0.55,
        edge_darken = 0.55,
    },

    -- Recessed slot behind a card position, so an empty slot reads as a place
    -- at the table rather than a hole cut in the felt. The slots used to paint
    -- Theme.bg.sunken, which is {0,0,0} in the shove palette -- literally black
    -- holes. Same fix data/felt_style's comm_plate made for the grind felt.
    slot = {
        enabled = true,
        darken  = 0.55,
        alpha   = 0.55,
    },

    -- Drop shadow under a card, so it sits ON the table instead of over it.
    -- views/CardSprites.shadow has existed since the felt pass and the gauntlet
    -- never called it. No size gate: cards here are a fixed 112px, far above
    -- the felt's 24px minimum.
    shadow = {
        enabled = true,
        offset  = 3,
    },

    -- Room vignette. Reuses the 64x64 alpha ramp views/FeltDecor builds at
    -- boot, stretched over the whole viewport rather than one panel, so the
    -- corners of the room fall away and the centre reads lit.
    vignette = {
        enabled = true,
        alpha   = 0.55,
    },

    -- Light over the card rows. Its own mask, ramping the opposite way to the
    -- vignette (opaque at the centre, transparent at the edges), which is the
    -- one thing FeltDecor's mask cannot be asked to do -- it is authored for
    -- darkening edges.
    --
    -- A texture rather than a shader for the same reasons FeltDecor gives:
    -- stretching a small smooth ramp is what bilinear magnification is good at,
    -- it costs one batched draw, it produces no banding, and it cannot fail to
    -- compile on the love.js web build the way services/ShaderRegistry entries
    -- can.
    glow = {
        enabled = true,
        mask_px = 64,
        -- Normalised radius (centre 0, edge 1) where the light starts falling
        -- off and where it reaches nothing.
        inner   = 0.10,
        outer   = 1.00,
        power   = 1.70,
        alpha   = 0.16,
        -- The glow is wider and taller than the band so it bleeds past it
        -- instead of stopping at an edge.
        w_frac  = 1.30,
        h_frac  = 1.55,
    },

    -- The board row: SEVEN positions in one line, read as two groups.
    --
    -- Left: the five community cards, with the hole cards centred under them.
    -- That whole group is THE TABLE, and everything belonging to it -- banner,
    -- pot pile, hole rows, result chips -- centres on the table, not on the
    -- screen.
    --
    -- Right: the stats panel. It occupies row positions 6 and 7, which is
    -- exactly where the dealer's cheat cards land. Until they do, those two
    -- positions carry BASE and MULT with a multiplication sign between them and
    -- the total underneath.
    --
    -- The section gap is what makes that work: wide enough that the right pair
    -- reads as a panel beside the table rather than as part of the board, so
    -- nothing announces that two more cards are coming. The reveal is that it
    -- was one row all along.
    --
    -- Critically: positions 6 and 7 get NO recessed slot, no plate, no outline.
    -- Positions 1-5 do. A card-shaped hole on the right would give the
    -- structure away before the first cheat is dealt.
    row = {
        -- TOTAL space between position 5 and position 6, replacing the card gap
        -- there rather than adding to it. Roughly 3x the card gap: enough that
        -- the panel reads as its own thing, not enough that the row stops being
        -- one line.
        section_gap = 48,
    },

    -- The stats panel: BASE x MULT, total underneath.
    --
    -- Text only, for the reason above. The equation frame (the x, the total's
    -- leading =) stays put when the cheat cards land; it is the VALUES that get
    -- buried, and the total rolling to zero underneath is the drama.
    stats = {
        -- TOTAL space between the BASE and MULT columns, replacing the card gap
        -- between positions 6 and 7. Holds the multiplication sign with room to
        -- breathe.
        op_gap    = 36,
        -- Where BASE / MULT sit inside the card row, as a fraction of card
        -- height. 0.5 centres them on the cards beside them.
        row_align = 0.5,
        -- The total sits just below the two card positions, in the band the
        -- hole cards no longer reach now that the table is centred to the left.
        total_gap = 8,
    },

    -- The dealer's cheat cards. They deal UPRIGHT into row positions 6 and 7,
    -- like any other community card -- that is the whole point of the single
    -- line. No rotation, no overhang, nothing to clear.
    cheat = {
        enabled = true,
    },

    -- The House. A poster above the dealer's hole cards, with a SLOT beneath
    -- it that every card is dealt out of, like the gap under the divider at
    -- a counter. The dealer is the House: cards come from under its poster.
    -- The poster registers the "house" anchor, so the tutorial's bubble
    -- speaks from it with its existing tail logic.
    -- OFF. A poster made of primitives earned nothing; the House gets real
    -- art in a later pass. The bubble falls back to floating beside its
    -- mark while there is no poster to speak from.
    house = {
        enabled     = false,
        -- Where dealt cards COME FROM, independent of whether the poster
        -- draws: off the top of the felt, above the dealer's seat. Motion
        -- used to be gated on the poster, so cutting the poster cut the
        -- deal to a fade.
        deal_from_y = -180,
        h           = 64,       -- poster height
        slot_h      = 14,       -- the gap the cards come out of
        frame_inset = 4,
        glyph_pad   = 12,
        -- Cards leave the slot and travel to their seat over the deal anim's
        -- own progress, eased out so they arrive rather than stop.
        deal_ease   = 3,
    },

    -- The drain bar under the readout. Fill is the live ALL-IN chance,
    -- eased, so when a cheat card buries a term the player WATCHES the
    -- number fall instead of reading that it did. Over 100% (the Act 3
    -- underflow) the bar pins full and turns violet, same signal the top
    -- bar's UNDERFLOW cell uses.
    -- The pot. Sits on the felt LEFT of the board, on the board row, big:
    -- neutral ground beside the hand while it plays. It used to sit above
    -- the dealer's cards in a small band, which read as the player handing
    -- everything over before a card was dealt.
    --
    -- At the end it is TAKEN: pushed slowly up to the dealer on a loss, or
    -- down to the player on a win. Slow on purpose; a burst reads as an
    -- effect, a slow push reads as someone reaching for the money.
    pot = {
        scale        = 1.6,     -- chip scale on the felt (drawStack under a transform)
        gap          = 44,      -- from the board's left edge
        max_cols     = 4,
        take_secs    = 1.6,     -- flight duration when it leaves
        take_stagger = 0.06,
        take_arc     = 40,
    },

    meter = {
        enabled     = true,
        h           = 6,
        gap         = 6,        -- below the ALL-IN label
        track_alpha = 0.90,
        radius      = 3,
        -- RollingValue rate: how fast the fill chases its target. Lower
        -- is a slower, more visible drain.
        rate        = 4.0,
    },

    -- The verdict lives in the CARDS. No label, no box, no stroke says who
    -- won; the winning five lift off the felt and warm, the losing five
    -- sink and go cold. Everything here is that motion.
    cards = {
        loser_alpha = 0.38,
        -- Winner's cards rise this many px over `lift_secs`, ease-out.
        lift_px     = 10,
        lift_secs   = 0.55,
        -- A soft warm halo behind each winning card, drawn as a stack of
        -- expanding rounded rects (same trick the old spotlight used). Alpha
        -- is the peak; it ramps in with the lift.
        glow_alpha  = 0.22,
        glow_grow   = 14,
        glow_steps  = 4,
    },

    -- The hand name, one line of plain text under the winning cards. A
    -- caption, not a label: no box, no border, muted ink, small.
    hand_caption = {
        gap = 10,
    },

    -- The run summary: the {chip} count, large, alone, on its own beat. It
    -- is the one thing on the felt that gets weight, because it is the one
    -- thing the player keeps. The caption above it is small and muted.
    summary = {
        enabled = true,
        gap     = 14,
    },

    -- Superseded by `glow`. Kept so the draw-trace harness can put the old
    -- lighting back and diff against the pre-extraction capture.
    spotlight = {
        enabled     = false,
        layers      = 6,
        alpha       = 0.06,
        w_frac      = 0.55,
        w_pad       = 200,
        h_frac      = 0.50,
        h_pad       = 60,
        radius_mult = 4,
    },

    -- The ending. After runout 3 is beaten the House keeps dealing: the
    -- rest of the deck, one card after another, every one still a win,
    -- until the felt and then the screen are buried, and credits fade in
    -- over the pile. Timing and reach are here; the sequence is
    -- views/ShoveView (onGauntletBegin, clear branch).
    ending = {
        enabled        = true,
        -- Seconds between cards, by card index (8 = the first extra card):
        -- a beat each while he still talks, then shrinking to a blur.
        intervals      = { { upto = 12, secs = 1.4 }, { upto = 20, secs = 0.8 },
                           { upto = 30, secs = 0.45 }, { upto = 52, secs = 0.18 } },
        flight_secs    = 0.55,   -- from the top of the screen to the felt
        flight_arc     = 120,
        spread_rows    = 12,     -- cards up to this index land on the board row, outward
        confetti_first = 17,     -- every landing bursts up to this index...
        confetti_every = 5,      -- ...then every Nth
        confetti_count = 14,
        curtain_secs   = 2.6,    -- silence over the pile before credits
        max_angle      = 0.6,    -- radians, cards landing off the board row
        deal_pitch     = { from = 1.0, to = 1.6 },   -- the flood rises as it speeds up
    },

    -- The room counts you in. Before the felt, the player's room comes up
    -- and every owned item lights in turn while a counter climbs to the
    -- number that becomes BASE. Cadence: seconds between items by item
    -- index, slow first then a blur, like the ending's deal.
    -- The chip pour into the pot before the deal.
    buildup = {
        land_pitch = { from = 1.0, to = 1.35 },   -- each landing a little higher than the last
    },

    room = {
        fade_in    = 0.6,     -- room comes up from black
        first_tick = 0.8,     -- first item lights after the fade
        intervals  = { { upto = 5, secs = 0.45 }, { upto = 12, secs = 0.25 },
                       { upto = 25, secs = 0.12 }, { upto = 80, secs = 0.05 } },
        flash_secs = 0.22,    -- the lit item's white flash: a pop
        lock_secs  = 1.2,     -- the final number sits before the cut
        empty_secs = 1.6,     -- nothing owned: the line, then the cut
        counter_y  = 0.19,    -- of H; the number, its label beside it on the same line
        -- Each counted item plays the sound that shares its name (assets/audio/items);
        -- pitch climbs with the index so the fill rises. No file: the chip tick.
        item_volume   = 0.8,
        item_pitch    = { from = 1.0, to = 1.5 },   -- rises across the count (SoundService.rampPitch)
        fallback_tick = "chip_land_pot",
        room_dy    = 0.06,    -- of H; the room sits this much lower so the counter clears its top corner
        -- After the cut the number flies from where it sat to the BASE
        -- readout on the felt, shrinking to that font on the way.
        fly_delay  = 0.45,    -- after the buildup starts (its fade-in first)
        fly_secs   = 0.9,
        fly_lift   = 2.2,     -- the number grows to this at the top of its arc (lifted toward you)
        fly_arc    = 2.0,     -- arc height in lg-font heights
        land_bump  = 0.5,     -- the landed number's pop (Pop.scale bump)
        land_secs  = 0.45,
        settle_secs = 0.4,    -- then the readout eases from the count to full BASE (deck included)
        bank_delay  = 0.15,   -- after the last chip lands, BANK lifts off the pile toward its slot
        bank_label_dy = -64,  -- the "$bankroll" figure sits this far above the pile centre, px; BANK lifts off it
        zoom       = 1.9,     -- the room drawn big for the intro
        -- Not yet counted: a dark silhouette. Counted: the sprite pops in
        -- and glows in its own shape (additive copies at these pixel
        -- offsets, scaled by ui_scale), breathing on `pulse_secs`.
        silhouette = { 0.06, 0.05, 0.08, 0.9 },
        halo = {
            color       = { 1.0, 0.85, 0.45 },
            alpha       = 0.45,   -- glow at the pop
            pulse       = 0.0,    -- no breathing; the glow is the pop and gone
            pulse_secs  = 1.0,
            glow_secs   = 0.35,   -- eased out over this; then the item just sits there
            flash_alpha = 0.45,   -- added at the peak of the flash
            offsets     = { { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
                            { 3, 3 }, { -3, 3 }, { 3, -3 }, { -3, -3 },
                            { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } },
        },
    },
}
