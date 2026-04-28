-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake:
--
--   • seats              — number of opponents at the felt
--   • pace_mult          — multiplier on the per-hand cinematic. >1 = faster.
--                          The base timeline (PHASE_*_END constants in
--                          models/Table.lua) is what plays at pace_mult=1;
--                          6-max is intentionally below 1 to anchor the
--                          baseline so multi-tabling is the way to scale
--                          throughput, not single-table click-spam.
--   • grid_modifier      — additive shifts on the 8-cell outcome grid (see
--                          models/Table.lua:_buildGrid). Positive value on
--                          a tier moves probability mass *into* that row,
--                          split evenly between the W and L columns; the
--                          grid is renormalized to sum=1 afterward. nil =
--                          no shift (6-max baseline). Used to make HU feel
--                          like an all-in fest, Zoom feel like fold city,
--                          9-max feel tighter than 6-max.
--   • skill_modifier     — multiplicative offsets into stake.skill_distribution
--                          (then renormalized). nil = use stake's as-is.
--   • playstyle_modifier — same shape, but for stake.playstyle_distribution.
--   • rerolls_opponents  — true for Zoom; opponents reroll per hand and
--                          their revealed-skill / revealed-style flags reset
--                          (you never learn a Zoom pool).
--
-- Pure data — no logic.

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pace_mult = 0.5,        -- baseline slow — 4.4s/hand. Anchors all multi-tabling math.
        grid_modifier = nil,    -- baseline grid; no shift
        skill_modifier     = nil,
        playstyle_modifier = nil,
        rerolls_opponents  = false,
    },
    {
        id   = "nine_max",
        name = "9-max",
        short = "9-MAX",
        seats = 8,
        pace_mult = 0.30,       -- meaningfully slower — more decisions per hand
        -- Tighter ranges, more pre-flop folds. Mass moves into Tiny rows
        -- and out of Medium/Jackpot. Less drama per hand than 6-max.
        grid_modifier = { tiny = 0.05, small = 0.00, medium = -0.03, jackpot = -0.02 },
        skill_modifier     = nil,
        playstyle_modifier = { fish = 0.7, tag = 1.3, lag = 0.6, nit = 1.6 },
        rerolls_opponents  = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 1.0,        -- fast — 2.2s/hand
        -- Heads-up depth = every hand goes deeper. Mass moves *out* of
        -- Tiny (no folding around the table) and *into* Medium and
        -- Jackpot rows. Each hand is a real hand.
        grid_modifier = { tiny = -0.10, small = -0.05, medium = 0.08, jackpot = 0.07 },
        -- HU pool is brutally pro-heavy. Recreationals don't sit at HU.
        skill_modifier     = { rec = 0.1, reg = 0.3, grind = 2.5, pro = 5.0 },
        playstyle_modifier = nil,
        rerolls_opponents  = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pace_mult = 1.4,        -- very fast — ~1.57s/hand
        -- Zoom = fold-button-spam. Pool insta-folds bad hands. Mass into
        -- Tiny, out of bigger pots. Lots of small ±1bb decisions, rare
        -- big hands.
        grid_modifier = { tiny = 0.08, small = -0.02, medium = -0.03, jackpot = -0.03 },
        -- Recreational + fishy pool. Easier than 6-max at the same stake.
        skill_modifier     = { rec = 1.5, reg = 1.0, grind = 0.6, pro = 0.3 },
        playstyle_modifier = { fish = 1.4, tag = 0.7, lag = 0.6, nit = 1.2 },
        rerolls_opponents  = true,
    },

}
