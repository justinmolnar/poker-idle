-- data/stakes.lua
--
-- Stake tier definitions. Six tiers from $0.01/$0.02 up to $0.50/$1.00,
-- using real blind notation. Late-game stakes (up to $1k/$2k+) come later.
--
-- Tier schema:
--   {
--     id              = "s00N",         -- semantic, ordered
--     name            = "long display",  -- "$0.01/$0.02 NLHE 6-max"
--     display_name    = "$0.01/$0.02",   -- compact label for table panel headers
--     sb              = number ($),
--     bb              = number ($),
--     buy_in          = number ($)       -- 100bb, the cash you need to sit
--     unlock_bankroll = retired — buy_in (100bb) is the only gate. If you can sit, you can play.
--     pp_award        = integer          -- one-time per-run PP bounty for first win at this stake
--     win_rate_offset = number           -- additive shift on the per-hand win rate at this stake
--                                         (negative = harder; stratifies the curve so climbing
--                                          stakes is genuinely harder than just "different distribution")
--
--     -- Distributions for the new opponent-driven win-rate model:
--     skill_distribution     = { rec=p, reg=p, grind=p, pro=p }    -- sum to 1
--     playstyle_distribution = { fish=p, tag=p, lag=p, nit=p }     -- sum to 1
--
--     -- Legacy fields used by the placeholder Table model. Phase 2 of the
--     -- rebuild replaces Table with a real per-hand mini-game; these will
--     -- be derived from the distributions and removed at that point.
--     bet_size, pot_size, win_rate, hands_per_min
--   }

return {

    {
        id              = "s001",
        name            = "$0.01/$0.02 NLHE 6-max",
        display_name    = "$0.01/$0.02",
        sb              = 0.01,
        bb              = 0.02,
        buy_in          = 2.00,
        pp_award        = 1,
        win_rate_offset = 0.00,
        skill_distribution     = { rec = 0.60, reg = 0.25, grind = 0.12, pro = 0.03 },
        playstyle_distribution = { fish = 0.55, tag = 0.20, lag = 0.10, nit = 0.15 },
        -- Legacy
        bet_size      = 0.06,
        pot_size      = 0.10,
        win_rate      = 0.55,
        hands_per_min = 60,
    },
    {
        id              = "s002",
        name            = "$0.02/$0.05 NLHE 6-max",
        display_name    = "$0.02/$0.05",
        sb              = 0.02,
        bb              = 0.05,
        buy_in          = 5.00,
        pp_award        = 2,
        win_rate_offset = -0.02,
        skill_distribution     = { rec = 0.40, reg = 0.35, grind = 0.20, pro = 0.05 },
        playstyle_distribution = { fish = 0.45, tag = 0.28, lag = 0.10, nit = 0.17 },
        -- Legacy
        bet_size      = 0.15,
        pot_size      = 0.25,
        win_rate      = 0.54,
        hands_per_min = 50,
    },
    {
        id              = "s003",
        name            = "$0.05/$0.10 NLHE 6-max",
        display_name    = "$0.05/$0.10",
        sb              = 0.05,
        bb              = 0.10,
        buy_in          = 10.00,
        pp_award        = 3,
        win_rate_offset = -0.04,
        skill_distribution     = { rec = 0.25, reg = 0.35, grind = 0.30, pro = 0.10 },
        playstyle_distribution = { fish = 0.35, tag = 0.35, lag = 0.12, nit = 0.18 },
        -- Legacy
        bet_size      = 0.30,
        pot_size      = 0.50,
        win_rate      = 0.53,
        hands_per_min = 40,
    },
    {
        id              = "s004",
        name            = "$0.10/$0.25 NLHE 6-max",
        display_name    = "$0.10/$0.25",
        sb              = 0.10,
        bb              = 0.25,
        buy_in          = 25.00,
        pp_award        = 4,
        win_rate_offset = -0.06,
        skill_distribution     = { rec = 0.12, reg = 0.30, grind = 0.38, pro = 0.20 },
        playstyle_distribution = { fish = 0.28, tag = 0.40, lag = 0.14, nit = 0.18 },
        -- Legacy
        bet_size      = 0.75,
        pot_size      = 1.25,
        win_rate      = 0.52,
        hands_per_min = 30,
    },
    {
        id              = "s005",
        name            = "$0.25/$0.50 NLHE 6-max",
        display_name    = "$0.25/$0.50",
        sb              = 0.25,
        bb              = 0.50,
        buy_in          = 50.00,
        pp_award        = 5,
        win_rate_offset = -0.08,
        skill_distribution     = { rec = 0.05, reg = 0.22, grind = 0.38, pro = 0.35 },
        playstyle_distribution = { fish = 0.22, tag = 0.45, lag = 0.15, nit = 0.18 },
        -- Legacy
        bet_size      = 1.50,
        pot_size      = 2.50,
        win_rate      = 0.51,
        hands_per_min = 25,
    },
    {
        id              = "s006",
        name            = "$0.50/$1.00 NLHE 6-max",
        display_name    = "$0.50/$1.00",
        sb              = 0.50,
        bb              = 1.00,
        buy_in          = 100.00,
        pp_award        = 6,
        win_rate_offset = -0.10,
        skill_distribution     = { rec = 0.02, reg = 0.13, grind = 0.35, pro = 0.50 },
        playstyle_distribution = { fish = 0.18, tag = 0.50, lag = 0.15, nit = 0.17 },
        -- Legacy
        bet_size      = 3.00,
        pot_size      = 5.00,
        win_rate      = 0.50,
        hands_per_min = 20,
    },

}
