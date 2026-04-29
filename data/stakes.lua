-- data/stakes.lua
--
-- Stake tier definitions. Six tiers stepping ~10× per stake — each climb
-- is genuinely dramatic ($2 buy-in → $100k buy-in across the run). The
-- 10× jumps mean each stake is its own "scratch card": the prior stake
-- feels maxed out, the next stake feels brutal, until you grind upgrades
-- that reshape the outcome grid.
--
-- Difficulty model (post-refactor):
--   Each stake owns a `difficulty` list of grid_shifts that the buildGrid
--   pipeline applies to the universal base grid (data/base_grid.lua).
--   This is the dominant source of stake-to-stake difficulty variance —
--   opponents are uniform across stakes (same pool, same distribution).
--   Curve targets (naked, no upgrades, no game-type modifier):
--     s001 ≈ 50% Win  s002 ≈ 30%  s003 ≈ 10%
--     s004 ≈  5%      s005 ≈  2%  s006 ≈  0.5%
--   The win_to_lose amount X collapses base W mass to 0.50 × (1-X), so
--   X ladders 0 / 0.40 / 0.80 / 0.90 / 0.96 / 0.99 hits those targets
--   approximately. Tune in playtest.
--
-- Tier schema:
--   {
--     id              = "s00N",         -- semantic, ordered
--     name            = "long display",  -- "$0.01/$0.02 NLHE"
--     display_name    = "$0.01/$0.02",   -- compact label for table panel headers
--     sb              = number ($),
--     bb              = number ($),
--     buy_in          = number ($)       -- 100bb, the cash you need to sit
--     pp_award        = integer          -- one-time per-run PP bounty for first jackpot win
--     difficulty      = { {op="...", amount=...}, ... }  -- empty for s001
--   }

return {

    {
        id           = "s001",
        name         = "$0.01/$0.02 NLHE",
        display_name = "$0.01/$0.02",
        sb           = 0.01,
        bb           = 0.02,
        buy_in       = 2.00,
        pp_award     = 1,
        difficulty   = {},
    },
    {
        id           = "s002",
        name         = "$0.10/$0.25 NLHE",
        display_name = "$0.10/$0.25",
        sb           = 0.10,
        bb           = 0.25,
        buy_in       = 25.00,
        pp_award     = 2,
        difficulty   = {
            { op = "win_to_lose", amount = 0.40 },
        },
    },
    {
        id           = "s003",
        name         = "$0.50/$1.00 NLHE",
        display_name = "$0.50/$1.00",
        sb           = 0.50,
        bb           = 1.00,
        buy_in       = 100.00,
        pp_award     = 3,
        difficulty   = {
            { op = "win_to_lose", amount = 0.80 },
        },
    },
    {
        id           = "s004",
        name         = "$5/$10 NLHE",
        display_name = "$5/$10",
        sb           = 5,
        bb           = 10,
        buy_in       = 1000,
        pp_award     = 4,
        difficulty   = {
            { op = "win_to_lose", amount = 0.90 },
        },
    },
    {
        id           = "s005",
        name         = "$50/$100 NLHE",
        display_name = "$50/$100",
        sb           = 50,
        bb           = 100,
        buy_in       = 10000,
        pp_award     = 5,
        difficulty   = {
            { op = "win_to_lose", amount = 0.96 },
        },
    },
    {
        id           = "s006",
        name         = "$500/$1000 NLHE",
        display_name = "$500/$1000",
        sb           = 500,
        bb           = 1000,
        buy_in       = 100000,
        pp_award     = 6,
        difficulty   = {
            { op = "win_to_lose", amount = 0.99 },
        },
    },

}
