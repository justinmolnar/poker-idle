-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake's base outcome model:
--
--   • seats              — number of opponents at the felt
--   • pace_mult          — multiplier on the per-hand cinematic. >1 = faster.
--                          The base timeline (PHASE_*_END constants in
--                          models/Table.lua) is what plays at pace_mult=1;
--                          6-max is intentionally below 1 to anchor the
--                          baseline so multi-tabling is the way to scale
--                          throughput, not single-table click-spam.
--   • dist_shifts        — additive deltas on win_dist / loss_dist (see
--                          models/Table.lua:buildOutcome). Same shape as
--                          opponent_types.style_dist_shifts: an entry with
--                          optional `win_dist` and `loss_dist` 4-tier delta
--                          tables. Each gtype here applies to BOTH dists
--                          (depth/pace texture, not W/L bias). nil = no
--                          shift (6-max baseline).
--   • rerolls_opponents  — true for Zoom; opponents reroll per hand and
--                          their revealed-skill / revealed-style flags reset
--                          (you never learn a Zoom pool).
--
-- The post-refactor model deliberately drops per-gtype skill_modifier and
-- playstyle_modifier — pool reweighting through game type is what caused HU
-- to become a pro-only nightmare at any stake. Per-gtype texture now lives
-- ONLY in dist_shifts (shaping tier variance, not win_chance) and pace_mult
-- (throughput, not per-hand EV).
--
-- Pure data — no logic.

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pace_mult = 0.5,        -- baseline slow — 4.4s/hand. Anchors all multi-tabling math.
        dist_shifts = nil,      -- baseline; no shift
        rerolls_opponents = false,
    },
    {
        id   = "nine_max",
        name = "9-max",
        short = "9-MAX",
        seats = 8,
        pace_mult = 0.30,       -- meaningfully slower — more decisions per hand
        -- Tighter ranges, more pre-flop folds. Mass moves into Tiny and out
        -- of Medium/Jackpot on both dists. Less drama per hand than 6-max.
        dist_shifts = {
            win_dist  = { tiny = 0.05, medium = -0.03, jackpot = -0.02 },
            loss_dist = { tiny = 0.05, medium = -0.03, jackpot = -0.02 },
        },
        rerolls_opponents = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 1.0,        -- fast — 2.2s/hand
        -- Heads-up depth = every hand goes deeper. Mass moves slightly *out*
        -- of Tiny/Small and *into* Medium/Jackpot on both dists. Bigger
        -- pots in both directions; doesn't change W/L balance.
        dist_shifts = {
            win_dist  = { tiny = -0.04, small = -0.025, medium = 0.04, jackpot = 0.025 },
            loss_dist = { tiny = -0.04, small = -0.025, medium = 0.04, jackpot = 0.025 },
        },
        rerolls_opponents = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pace_mult = 1.4,        -- very fast — ~1.57s/hand
        -- Zoom = fold-button-spam. Pool insta-folds bad hands. Mass into
        -- Tiny on both dists, out of bigger pots. Lots of small ±1bb
        -- decisions, rare big hands.
        dist_shifts = {
            win_dist  = { tiny = 0.08, small = -0.02, medium = -0.03, jackpot = -0.03 },
            loss_dist = { tiny = 0.08, small = -0.02, medium = -0.03, jackpot = -0.03 },
        },
        rerolls_opponents = true,
    },

}
