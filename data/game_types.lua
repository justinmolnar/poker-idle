-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake's base difficulty:
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
--                          no shift (6-max baseline). Used to give each
--                          game type its tier shape — HU = deeper, Zoom =
--                          fold city, 9-max = tighter than 6-max.
--   • rerolls_opponents  — true for Zoom; opponents reroll per hand and
--                          their revealed-skill / revealed-style flags reset
--                          (you never learn a Zoom pool).
--
-- The post-refactor model deliberately drops the per-gtype skill_modifier
-- and playstyle_modifier — pool reweighting through game type is what
-- caused HU to become a pro-only nightmare at any stake. Per-gtype texture
-- now lives ONLY in grid_modifier (which doesn't change W/L balance, just
-- tier shape) and pace_mult (which changes throughput, not per-hand EV).
--
-- Pure data — no logic.

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pace_mult = 0.5,        -- baseline slow — 4.4s/hand. Anchors all multi-tabling math.
        grid_modifier = nil,    -- baseline; no shift
        rerolls_opponents = false,
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
        rerolls_opponents = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 1.0,        -- fast — 2.2s/hand
        -- Heads-up depth = every hand goes deeper. Mass moves slightly
        -- *out* of Tiny/Small and *into* Medium/Jackpot. Amplifies the
        -- per-stake difficulty modestly because the bigger tiers carry
        -- the bulk of the magnitude. Halved from the pre-refactor values
        -- so HU is "slightly harder" not "two stakes harder."
        grid_modifier = { tiny = -0.04, small = -0.025, medium = 0.04, jackpot = 0.025 },
        rerolls_opponents = false,
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
        rerolls_opponents = true,
    },

}
