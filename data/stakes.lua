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
--     name            = "blind-structure descriptor (data doc; not rendered)",
--     display_name    = "NL10",               -- player-facing: NL + buy-in.
--                       Blinds are tooltip flavor only (bb line in the EV
--                       breakdown); sb never renders anywhere.
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
        display_name = "NL2",
        sb           = 0.01,
        bb           = 0.02,
        buy_in       = 2.00,
        chip_award     = 1,
        band              = "low",
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
        name         = "$0.05/$0.10 NLHE",
        display_name = "NL10",
        sb           = 0.05,
        bb           = 0.10,
        buy_in       = 10.00,
        chip_award     = 2,
        band              = "low",
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
        display_name = "NL100",
        sb           = 0.50,
        bb           = 1.00,
        buy_in       = 100.00,
        chip_award     = 3,
        band              = "low",
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
        display_name = "NL1K",
        sb           = 5,
        bb           = 10,
        buy_in       = 1000,
        chip_award     = 4,
        band              = "mid",
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
        display_name = "NL10K",
        sb           = 50,
        bb           = 100,
        buy_in       = 10000,
        chip_award     = 5,
        band              = "mid",
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
        display_name = "NL100K",
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
        band              = "mid",
    },

    -- ── High band (T7-T9) — unlocked by the R2 shove win. Fill windows
    --    keep widening (span 5, offset 3) so these stay near-naked even
    --    with a strong deck stack; naked WC ~0 and losses skew to jackpot.
    --    This is where stack losses (and anti-chips, Act 3) come from.
    --    PLACEHOLDER numbers — balance is a later pass.
    {
        id           = "s007",
        name         = "$5,000/$10,000 NLHE",
        display_name = "NL1M",
        sb           = 5000,
        bb           = 10000,
        buy_in       = 1000000,
        chip_award     = 7,
        band              = "high",
        win_chance        = 0.002,
        win_chance_capped = 0.20,
        win_dist          = { small = 0.65, medium = 0.35, large = 0.00, jackpot = 0.00 },
        win_dist_capped   = { small = 0.20, medium = 0.25, large = 0.20, jackpot = 0.35 },
        loss_dist         = { small = 0.04, medium = 0.11, large = 0.25, jackpot = 0.60 },
        loss_dist_capped  = { small = 0.30, medium = 0.22, large = 0.13, jackpot = 0.35 },
        fill_window       = { start = 18, complete = 23 },
    },
    {
        id           = "s008",
        name         = "$50,000/$100,000 NLHE",
        display_name = "NL10M",
        sb           = 50000,
        bb           = 100000,
        buy_in       = 10000000,
        chip_award     = 8,
        band              = "high",
        win_chance        = 0.001,
        win_chance_capped = 0.15,
        win_dist          = { small = 0.70, medium = 0.30, large = 0.00, jackpot = 0.00 },
        win_dist_capped   = { small = 0.20, medium = 0.25, large = 0.20, jackpot = 0.35 },
        loss_dist         = { small = 0.03, medium = 0.09, large = 0.20, jackpot = 0.68 },
        loss_dist_capped  = { small = 0.28, medium = 0.22, large = 0.15, jackpot = 0.35 },
        fill_window       = { start = 21, complete = 26 },
    },
    {
        id           = "s009",
        name         = "$500,000/$1,000,000 NLHE",
        display_name = "NL100M",
        sb           = 500000,
        bb           = 1000000,
        buy_in       = 100000000,
        chip_award     = 9,
        band              = "high",
        win_chance        = 0.0005,
        win_chance_capped = 0.10,
        win_dist          = { small = 0.75, medium = 0.25, large = 0.00, jackpot = 0.00 },
        win_dist_capped   = { small = 0.20, medium = 0.25, large = 0.20, jackpot = 0.35 },
        loss_dist         = { small = 0.02, medium = 0.08, large = 0.15, jackpot = 0.75 },
        loss_dist_capped  = { small = 0.25, medium = 0.25, large = 0.15, jackpot = 0.35 },
        fill_window       = { start = 24, complete = 29 },
    },

    -- ── Ultra (T10) — bought with anti-chips in Act 3. Astronomical
    --    buy-in (magnitudes above High), ~0 win chance, unreachable fill
    --    window, near-certain jackpot loss: a loss sink, not a grind tier.
    --    Buying it begins the endgame (bankroll bleeds negative → underflow).
    --    PLACEHOLDER numbers.
    {
        id           = "s010",
        name         = "ULTRA — no limit",
        display_name = "ULTRA",
        sb           = 5000000,
        bb           = 10000000,
        buy_in       = 100000000000,
        chip_award     = 10,
        band              = "ultra",
        win_chance        = 0.0001,
        win_chance_capped = 0.001,
        win_dist          = { small = 0.90, medium = 0.10, large = 0.00, jackpot = 0.00 },
        win_dist_capped   = { small = 0.50, medium = 0.30, large = 0.15, jackpot = 0.05 },
        loss_dist         = { small = 0.00, medium = 0.00, large = 0.10, jackpot = 0.90 },
        loss_dist_capped  = { small = 0.05, medium = 0.10, large = 0.05, jackpot = 0.80 },
        fill_window       = { start = 999, complete = 1000 },
    },

}
