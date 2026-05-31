-- data/stakes.lua
--
-- Stake tier definitions. Six tiers stepping ~10× per stake — each climb
-- is genuinely dramatic ($2 buy-in → $100k buy-in across the run). The
-- 10× jumps mean each stake is its own "scratch card": the prior stake
-- feels maxed out, the next stake feels brutal, until you grind upgrades
-- that reshape win_chance / win_dist / loss_dist.
--
-- Outcome model — three independent dimensions per stake, each with a
-- *naked* and *run-capped* value. Run upgrades fill the gap between them.
-- Catalog perks layer ON TOP of run-capped (additive), pushing toward an
-- absolute 0.95 WC ceiling enforced in buildOutcome.
--
--   win_chance        — naked probability ∈ [0, 1] of a Win
--   win_chance_capped — value reached when run-upgrade fill = 1
--   win_dist          — naked tier dist sampled when winning (sums to 1)
--   win_dist_capped   — fully-filled tier dist (also sums to 1)
--   loss_dist         — naked tier dist sampled when losing
--   loss_dist_capped  — fully-filled loss tier dist
--   fill_window       — { start, complete } level window for run upgrades
--                       at fill_units < start: dimension stays naked
--                       at fill_units >= complete: dimension at run-capped
--                       linear in between
--
--   Span 5, offset 3 across stakes — predictable progression. T1 fills in
--   levels 1-5; T2 starts at L4 (warmup), completes at L8; T6 starts at
--   L16, completes at L20 (PB/PC max=14 cannot reach T6, SR max=18 reaches
--   60% of the way — catalog perks bridge the rest).
--
-- Tier schema:
--   {
--     id              = "s00N",
--     name            = "long display",
--     display_name    = "$0.01/$0.02",
--     sb              = number ($),
--     bb              = number ($),
--     buy_in          = number ($)            -- 100bb
--     chip_award        = integer               -- one-time per-run chip bounty
--     win_chance      = number 0..1           -- naked
--     win_chance_capped = number 0..1
--     win_dist        = { small, medium, large, jackpot }  -- naked, sums to 1
--     win_dist_capped = same shape, sums to 1
--     loss_dist       = same shape, naked
--     loss_dist_capped= same shape
--     fill_window     = { start = N, complete = M }
--   }

return {

    {
        id           = "s001",
        name         = "$0.01/$0.02 NLHE",
        display_name = "$0.01/$0.02",
        sb           = 0.01,
        bb           = 0.02,
        buy_in       = 2.00,
        chip_award     = 1,
        -- T1 naked WC stays at 0.50 (it's the demo's coinflip baseline).
        -- Loss tail is intentionally squashed at T1: Large losses are
        -- rare and Jackpot losses are basically a unicorn (0.1%). The
        -- annoying thing about T1 is busting before the bankroll has a
        -- chance to compound; muting big-loss variance keeps players
        -- in the seat. Avg win 13.3bb vs avg loss ~6.0bb at 50/50 → EV
        -- ≈ +3.65 bb/hand at T1.
        win_chance        = 0.50,
        win_chance_capped = 0.75,
        win_dist          = { small = 0.40, medium = 0.36, large = 0.22, jackpot = 0.02 },
        win_dist_capped   = { small = 0.10, medium = 0.15, large = 0.25, jackpot = 0.50 },
        loss_dist         = { small = 0.70, medium = 0.23, large = 0.069, jackpot = 0.001 },
        -- loss_dist_capped MUST be a strict improvement on the naked dist
        -- in this stake's loss-tail tiers: capped jackpot ≤ naked jackpot,
        -- capped large ≤ naked large. Otherwise Pot Control fills will
        -- LERP loss toward a *worse* tail than the naked baseline.
        loss_dist_capped  = { small = 0.92, medium = 0.07, large = 0.009, jackpot = 0.001 },
        fill_window       = { start = 0, complete = 5 },
    },
    {
        id           = "s002",
        name         = "$0.10/$0.25 NLHE",
        display_name = "$0.10/$0.25",
        sb           = 0.10,
        bb           = 0.25,
        buy_in       = 25.00,
        chip_award     = 2,
        win_chance        = 0.30,
        win_chance_capped = 0.65,
        win_dist          = { small = 0.50, medium = 0.30, large = 0.18, jackpot = 0.02 },
        win_dist_capped   = { small = 0.10, medium = 0.15, large = 0.25, jackpot = 0.50 },
        loss_dist         = { small = 0.35, medium = 0.30, large = 0.30, jackpot = 0.05 },
        loss_dist_capped  = { small = 0.80, medium = 0.12, large = 0.05, jackpot = 0.03 },
        fill_window       = { start = 3, complete = 8 },
    },
    {
        id           = "s003",
        name         = "$0.50/$1.00 NLHE",
        display_name = "$0.50/$1.00",
        sb           = 0.50,
        bb           = 1.00,
        buy_in       = 100.00,
        chip_award     = 3,
        win_chance        = 0.15,
        win_chance_capped = 0.55,
        win_dist          = { small = 0.55, medium = 0.30, large = 0.13, jackpot = 0.02 },
        win_dist_capped   = { small = 0.10, medium = 0.15, large = 0.25, jackpot = 0.50 },
        loss_dist         = { small = 0.25, medium = 0.30, large = 0.35, jackpot = 0.10 },
        loss_dist_capped  = { small = 0.75, medium = 0.13, large = 0.05, jackpot = 0.07 },
        fill_window       = { start = 6, complete = 11 },
    },
    {
        id           = "s004",
        name         = "$5/$10 NLHE",
        display_name = "$5/$10",
        sb           = 5,
        bb           = 10,
        buy_in       = 1000,
        chip_award     = 4,
        win_chance        = 0.10,
        win_chance_capped = 0.45,
        win_dist          = { small = 0.40, medium = 0.40, large = 0.20, jackpot = 0.00 },
        win_dist_capped   = { small = 0.15, medium = 0.20, large = 0.20, jackpot = 0.45 },
        loss_dist         = { small = 0.15, medium = 0.25, large = 0.40, jackpot = 0.20 },
        loss_dist_capped  = { small = 0.65, medium = 0.15, large = 0.07, jackpot = 0.13 },
        fill_window       = { start = 9, complete = 14 },
    },
    {
        id           = "s005",
        name         = "$50/$100 NLHE",
        display_name = "$50/$100",
        sb           = 50,
        bb           = 100,
        buy_in       = 10000,
        chip_award     = 5,
        win_chance        = 0.05,
        win_chance_capped = 0.35,
        win_dist          = { small = 0.50, medium = 0.40, large = 0.10, jackpot = 0.00 },
        win_dist_capped   = { small = 0.20, medium = 0.20, large = 0.20, jackpot = 0.40 },
        loss_dist         = { small = 0.10, medium = 0.20, large = 0.40, jackpot = 0.30 },
        loss_dist_capped  = { small = 0.50, medium = 0.15, large = 0.15, jackpot = 0.20 },
        fill_window       = { start = 12, complete = 17 },
    },
    {
        id           = "s006",
        name         = "$500/$1000 NLHE",
        display_name = "$500/$1000",
        sb           = 500,
        bb           = 1000,
        buy_in       = 100000,
        chip_award     = 6,
        win_chance        = 0.005,
        win_chance_capped = 0.25,
        win_dist          = { small = 0.60, medium = 0.40, large = 0.00, jackpot = 0.00 },
        win_dist_capped   = { small = 0.20, medium = 0.25, large = 0.20, jackpot = 0.35 },
        loss_dist         = { small = 0.05, medium = 0.15, large = 0.30, jackpot = 0.50 },
        loss_dist_capped  = { small = 0.35, medium = 0.20, large = 0.10, jackpot = 0.35 },
        fill_window       = { start = 15, complete = 20 },
    },

}
