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
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 1.0,        -- fast — 2.6s/hand (longer showdown beat)
        -- HU = the duel. WIN side compresses (small wins, less reach for
        -- jackpot); LOSS side fans out (deeper losses, real jackpot risk).
        -- Identity: "small wins, big losses." Pairs with the duel visual:
        -- one rival, they take big pots off you, you scrape together small.
        dist_shifts = {
            win_dist  = { tiny =  0.20, small =  0.10, medium = -0.10, jackpot = -0.20 },
            loss_dist = { tiny = -0.20, small = -0.05, medium =  0.10, jackpot =  0.15 },
        },
        rerolls_opponents = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pace_mult = 1.4,        -- very fast — most hands ~0.57s with the
                                -- zoom:tiny cinematic-skip in cinematic_timelines.
        -- Zoom = fold-spam. Hard shift toward tiny on both sides — most
        -- Zoom hands are 1-2 bb preflop spats. Jackpot mass is nearly
        -- extinct. The cinematic-skip on tiny outcomes (data/cinematic_
        -- timelines.lua) makes most hands resolve in <1s.
        dist_shifts = {
            win_dist  = { tiny = 0.40, small =  0.05, medium = -0.10, jackpot = -0.35 },
            loss_dist = { tiny = 0.10, small = -0.02, medium = -0.03, jackpot = -0.05 },
        },
        rerolls_opponents = true,
        anonymous_opponents = true,
    },
    {
        id   = "mtt",
        name = "Tournament",
        short = "MTT",
        seats = 5,
        pace_mult = 1.0,        -- 6-max-baseline cinematics, 8 hands in sequence
        -- MTT inherits 6-max baseline distributions. Magnitudes don't
        -- matter under binary_outcome — only the per-hand win/lose roll
        -- decides advance vs end. Identity is structural (auto-deal +
        -- 8-hand cap + payout ladder), not magnitude-shaped.
        dist_shifts       = nil,
        rerolls_opponents = false,
        -- Tournament knobs:
        --   hand_count      — auto-deal stops at this many cleared hands
        --   auto_deal       — fire :deal again on settling-end (no clicks)
        --   binary_outcome  — outcome_delta forced to 0 in :deal; only
        --                     `won` matters for advance-or-end
        hand_count     = 8,
        auto_deal      = true,
        binary_outcome = true,
    },

}
