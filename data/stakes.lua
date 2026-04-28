-- data/stakes.lua
--
-- Stake tier definitions. Six tiers stepping ~10× per stake — each climb is
-- genuinely dramatic ($2 buy-in → $100k buy-in across the run). The 10×
-- jumps mean each stake is its own "scratch card": the prior stake feels
-- maxed out, the next stake feels brutal, until you grind upgrades that
-- reshape the outcome grid.
--
-- Difficulty per-stake comes from the skill_distribution shifting from
-- rec-heavy at s001 to pro-heavy at s006. The outcome-grid model
-- (models/Table.lua + data/opponent_types.lua) reads each opponent's grid;
-- there's no separate win_rate_offset on stakes.
--
-- Tier schema:
--   {
--     id              = "s00N",         -- semantic, ordered
--     name            = "long display",  -- "$0.01/$0.02 NLHE 6-max"
--     display_name    = "$0.01/$0.02",   -- compact label for table panel headers
--     sb              = number ($),
--     bb              = number ($),
--     buy_in          = number ($)       -- 100bb, the cash you need to sit
--     pp_award        = integer          -- one-time per-run PP bounty for first win at this stake
--
--     skill_distribution     = { rec=p, reg=p, grind=p, pro=p }    -- sum to 1
--     playstyle_distribution = { fish=p, tag=p, lag=p, nit=p }     -- sum to 1
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
        skill_distribution     = { rec = 0.60, reg = 0.25, grind = 0.12, pro = 0.03 },
        playstyle_distribution = { fish = 0.55, tag = 0.20, lag = 0.10, nit = 0.15 },
    },
    {
        id              = "s002",
        name            = "$0.10/$0.25 NLHE 6-max",
        display_name    = "$0.10/$0.25",
        sb              = 0.10,
        bb              = 0.25,
        buy_in          = 25.00,
        pp_award        = 2,
        skill_distribution     = { rec = 0.40, reg = 0.35, grind = 0.20, pro = 0.05 },
        playstyle_distribution = { fish = 0.45, tag = 0.28, lag = 0.10, nit = 0.17 },
    },
    {
        id              = "s003",
        name            = "$0.50/$1.00 NLHE 6-max",
        display_name    = "$0.50/$1.00",
        sb              = 0.50,
        bb              = 1.00,
        buy_in          = 100.00,
        pp_award        = 3,
        skill_distribution     = { rec = 0.25, reg = 0.35, grind = 0.30, pro = 0.10 },
        playstyle_distribution = { fish = 0.35, tag = 0.35, lag = 0.12, nit = 0.18 },
    },
    {
        id              = "s004",
        name            = "$5/$10 NLHE 6-max",
        display_name    = "$5/$10",
        sb              = 5,
        bb              = 10,
        buy_in          = 1000,
        pp_award        = 4,
        skill_distribution     = { rec = 0.12, reg = 0.30, grind = 0.38, pro = 0.20 },
        playstyle_distribution = { fish = 0.28, tag = 0.40, lag = 0.14, nit = 0.18 },
    },
    {
        id              = "s005",
        name            = "$50/$100 NLHE 6-max",
        display_name    = "$50/$100",
        sb              = 50,
        bb              = 100,
        buy_in          = 10000,
        pp_award        = 5,
        skill_distribution     = { rec = 0.05, reg = 0.22, grind = 0.38, pro = 0.35 },
        playstyle_distribution = { fish = 0.22, tag = 0.45, lag = 0.15, nit = 0.18 },
    },
    {
        id              = "s006",
        name            = "$500/$1000 NLHE 6-max",
        display_name    = "$500/$1000",
        sb              = 500,
        bb              = 1000,
        buy_in          = 100000,
        pp_award        = 6,
        skill_distribution     = { rec = 0.02, reg = 0.13, grind = 0.35, pro = 0.50 },
        playstyle_distribution = { fish = 0.18, tag = 0.50, lag = 0.15, nit = 0.17 },
    },

}
