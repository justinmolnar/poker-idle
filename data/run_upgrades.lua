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
-- Outcome-model contribution: each level of Sharper Reads pushes a WC
-- fill descriptor (strength=1, universal); each level of Pot Control
-- pushes BOTH a win_dist fill AND a loss_dist fill (also strength=1) —
-- one upgrade reshapes both magnitude tracks together. The stake's
-- fill_window converts unit count → fill ratio → lerp toward the
-- stake's *_capped values.

return {

    -- ── 1. Sharper Reads — universal win-chance lift ────────────────────
    -- The grind upgrade. Every hand, every opponent. Pure WC fill.
    -- 18 levels; reaches T1-T5 fully, 60% of T6.
    {
        id          = "sharper_reads",
        name        = "Sharper Reads",
        description = "Higher win chance",
        icon        = "sharper_reads",
        -- Drives a per-stake range tooltip (win chance, current → next level).
        tooltip_metric = "win_chance",
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

    -- ── 2. Pot Control — bigger wins, smaller losses ──────────────────
    -- Pushes BOTH win_dist and loss_dist fills per level. Was previously
    -- two upgrades (Pot Building + Pot Control); consolidated into one
    -- because the player buys them in lockstep anyway and the doubled
    -- per-level cost reflects the doubled outcome-model fill.
    -- 14 levels; reaches T1-T4 fully, 40% of T5, none of T6.
    {
        id          = "pot_control",
        name        = "Pot Control",
        description = "Bigger wins, smaller losses. Drives {chip}",
        icon        = "pot_control",
        -- Drives a per-stake range tooltip (Stack rate, current → next level).
        tooltip_metric = "win_dist",
        max_level   = 14,
        costs       = {
            1.50, 4.50, 14, 40, 113,
            375, 1100, 3000, 9000, 30000,
            90000, 263000, 800000, 2400000,
        },
        effects     = {
            { kind = "win_dist_fill",  strength = 1.0 },
            { kind = "loss_dist_fill", strength = 1.0 },
        },
    },

    -- (Patience and Iron Nerves were removed when player types were
    -- ripped — both relied on style/skill filtering. If a future "Pro"
    -- mechanic returns as an opt-in variant, deliberate replacement
    -- upgrades can come with it.)

    -- ── Box of Mice — more cursors in the swarm ──────────────────────
    -- Adds 1 cursor per level. Requires the catalog `cursor_pool` unlock
    -- + at least one cursor (catalog or run) to do anything visible.
    -- 12 levels.
    {
        id            = "box_of_mice",
        name          = "Cursor",
        description   = "+1 Cursor (auto-clicker)",
        icon          = "cursor",
        requires      = "cursor_pool",
        requires_hide = true,
        max_level     = 12,
        costs       = {
            3, 10, 30, 100, 300,
            900, 3000, 9000, 27000, 80000,
            240000, 720000,
        },
        effects     = { { kind = "cursor_count_add", value = 1 } },
    },

    -- ── 7. Cursor Speed — they click faster ────────────────────────────
    -- 8 levels, +25% multiplicative each. Caps at ~6× base speed.
    {
        id            = "cursor_speed",
        name          = "Cursor Speed",
        description   = "Cursors move faster",
        icon          = "cursor_speed",
        requires      = "cursor_pool",
        requires_hide = true,
        max_level     = 8,
        costs       = {
            5, 25, 125, 625, 3000,
            15000, 75000, 375000,
        },
        effects     = { { kind = "cursor_speed_mult", value = 1.25 } },
    },

    -- ── 8. Focus — throughput ──────────────────────────────────────────
    -- +1 focus capacity per level. Same effect kind as before. 10 levels.
    {
        id          = "focus",
        name        = "Focus",
        description = "Increase table limit before penalty",
        icon        = "focus",
        max_level   = 10,
        costs       = {
            5, 20, 80, 320, 1300,
            5000, 20000, 80000, 325000, 1300000,
        },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
    },

}
