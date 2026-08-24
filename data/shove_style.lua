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
    house = {
        enabled     = true,
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

    -- What the loser's cards fade to once a runout resolves. The winner's
    -- stay at full alpha with the best-5 stroke; the loser gets neither.
    cards = {
        loser_alpha = 0.45,
    },

    -- The run summary on the felt: BANKED THIS RUN and the {chip} count,
    -- drawn under the result chips once the summary beat fires.
    summary = {
        enabled = true,
        gap     = 10,
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
}
