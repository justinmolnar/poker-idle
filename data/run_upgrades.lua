-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Stacking — each entry can
-- be bought up to `max_level` times. Level N's effect block is applied N
-- times via EffectsRegistry:applyN, so each level pushes one more fill
-- descriptor onto ctx.win_chance_fills / ctx.win_dist_fills /
-- ctx.loss_dist_fills (or one more level of focus_capacity, etc).
--
-- Item schema:
--   {
--     id          = "snake_case_unique",
--     name        = "Display Name",
--     description = "Short blurb shown under the name (no level mention here)",
--     max_level   = integer,
--     costs       = { $L1, $L2, $L3, ... },        -- 1-indexed, length = max_level
--     effects     = { { kind = "...", ... }, ... } -- applied PER level
--   }
--
-- Pricing intent: final levels of every upgrade exceed the T6 buy-in
-- ($100k). The full lineup ($38M cumulative) is deliberately unaffordable
-- on a single run — multi-prestige climb mandatory, with Cheap Coaching
-- (catalog) compounding across cycles to make it tractable.
--
-- Outcome-model contribution: each level of SR/PB/PC pushes a fill
-- descriptor with strength=1 (universal). Patience / Iron Nerves push
-- strength=0.3 with a filter (style or skill) — they help fill targeted
-- opponents' windows faster but don't break the absolute 0.95 WC ceiling.
-- The stake's fill_window converts unit count → fill ratio → lerp toward
-- the stake's *_capped values.

return {

    -- ── 1. Sharper Reads — universal win-chance lift ────────────────────
    -- The grind upgrade. Every hand, every opponent. Pure WC fill.
    -- 18 levels; reaches T1-T5 fully, 60% of T6.
    {
        id          = "sharper_reads",
        name        = "Sharper Reads",
        description = "Read opponents better.",
        max_level   = 18,
        costs       = {
            0.25, 0.50, 1.50, 4, 10,
            25, 60, 150, 400, 1000,
            2500, 6000, 15000, 40000, 100000,
            250000, 600000, 1500000,
        },
        effects     = {
            { kind = "win_chance_fill", strength = 1.0 },
        },
    },

    -- ── 2. Pot Building — bigger wins ──────────────────────────────────
    -- Fills win_dist toward win_dist_capped. Doesn't change loss side.
    -- 14 levels; reaches T1-T4 fully, 40% of T5, none of T6.
    {
        id          = "pot_building",
        name        = "Pot Building",
        description = "Wins run bigger.",
        max_level   = 14,
        costs       = {
            1.50, 4.50, 14, 40, 113,
            375, 1100, 3000, 9000, 30000,
            90000, 263000, 800000, 2400000,
        },
        effects     = {
            { kind = "win_dist_fill", strength = 1.0 },
        },
    },

    -- ── 3. Pot Control — smaller losses ────────────────────────────────
    -- Fills loss_dist toward loss_dist_capped. Doesn't change win side.
    -- 14 levels, costs mirror Pot Building exactly.
    {
        id          = "pot_control",
        name        = "Pot Control",
        description = "Losses run smaller.",
        max_level   = 14,
        costs       = {
            1.50, 4.50, 14, 40, 113,
            375, 1100, 3000, 9000, 30000,
            90000, 263000, 800000, 2400000,
        },
        effects     = {
            { kind = "loss_dist_fill", strength = 1.0 },
        },
    },

    -- ── 4. Patience — vs predictable styles ────────────────────────────
    -- Adds 0.3-strength WC fill per level when opp is fish OR nit. Helps
    -- fill the WC window faster vs targeted opps but caps with universal
    -- lerp at run-cap; doesn't break the 0.95 absolute ceiling.
    -- 12 levels.
    {
        id          = "patience",
        name        = "Patience",
        description = "Patient against passive players.",
        max_level   = 12,
        costs       = {
            1, 3, 9, 27, 81,
            243, 729, 2200, 6600, 20000,
            59000, 177000,
        },
        effects     = {
            { kind = "win_chance_fill", strength = 0.3, style = "fish" },
            { kind = "win_chance_fill", strength = 0.3, style = "nit"  },
        },
    },

    -- ── 5. Iron Nerves — vs pros (endgame) ─────────────────────────────
    -- 0.3-strength WC fill per level when opp.skill is pro. $100 base
    -- gates this as a mid-T2+ purchase, becomes critical at T4+. 12 levels.
    {
        id          = "iron_nerves",
        name        = "Iron Nerves",
        description = "Cool head against pros.",
        max_level   = 12,
        costs       = {
            100, 300, 900, 2700, 8100,
            24000, 73000, 220000, 660000, 2000000,
            6000000, 18000000,
        },
        effects     = {
            { kind = "win_chance_fill", strength = 0.3, skill = "pro" },
        },
    },

    -- ── 6. Focus — throughput ──────────────────────────────────────────
    -- +1 focus capacity per level. Same effect kind as before. 10 levels.
    {
        id          = "focus",
        name        = "Focus",
        description = "Concentrate on more tables.",
        max_level   = 10,
        costs       = {
            5, 20, 80, 320, 1300,
            5000, 20000, 80000, 325000, 1300000,
        },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
    },

}
