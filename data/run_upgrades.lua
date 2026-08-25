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
--     tooltip_blurb = "Plain-language 'what it does' line(s) shown at the TOP
--                      of the hover tooltip, above any per-stake range grid.
--                      String or list-of-strings (one row each). May use
--                      {icon} markers — rendered through IconText.",
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
--
-- Fill upgrades (Sharper Reads, Pot Control) are `fill_scaled`: the
-- controller caps their buyable level to the top currently-buyable stake's
-- fill_window.complete (GrindController:getRunUpgradeMaxLevel), so they
-- never offer a dead level and need no build-flag special-case — with the
-- high-tier bands locked, only T1-T3 are buyable and the cap lands at T3's
-- 11 on its own; it follows the ladder as bands unlock.

return {

    -- ── 1. Sharper Reads — universal win-chance lift ────────────────────
    -- The grind upgrade. Every hand, every opponent. Pure WC fill.
    -- 18 levels; reaches T1-T5 fully, 60% of T6.
    {
        id          = "sharper_reads",
        name        = "Sharper Reads",
        description = "Higher win chance",
        tooltip_blurb = {
            "Raises your odds of winning across all stakes",
            "and game types. Graph shows next level increases.",
        },
        icon        = "sharper_reads",
        -- Drives a per-stake range tooltip (win chance, current → next level).
        tooltip_metric = "win_chance",
        -- Cap is DYNAMIC (fill_scaled): the controller sets the buyable max
        -- to the top currently-buyable stake's fill_window.complete, so it
        -- grows/shrinks with the ladder + band gating on its own (T3→11 in
        -- Act 1, T6→20 once mid unlocks, T9→29 once high unlocks). max_level
        -- is only the absolute ceiling matching the cost array. Costs past
        -- ~L18 are placeholder pending the cost-curve pass.
        fill_scaled = true,
        max_level   = 29,
        -- Fast-early / slow-late idle curve: cheap opening (L1 ~$0.20, a few
        -- T1 hands) ramping ~x2.5/level to ~$28B at L29. The `fill_scaled`
        -- cap keeps you to your tier's window, and the expensive high levels
        -- give the through-game depth — so the early levels stay cheap.
        -- Placeholder — tune against the §1 earning table.
        costs       = {
            0.20, 0.50, 1.25, 3, 8,
            20, 50, 125, 300, 750,
            1800, 4500, 11000, 28000, 70000,
            175000, 440000, 1100000, 2800000, 7000000,
            18000000, 45000000, 110000000, 280000000, 700000000,
            1800000000, 4500000000, 11000000000, 28000000000,
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
        description = "More {w:stack} Less {l:stack} - Drives {chip}",
        tooltip_blurb = {
            "Raises chance of smaller losses and bigger wins.",
            "Graph shows {w:stack}% increase, used to earn {chip}.",
        },
        icon        = "pot_control",
        -- Drives a per-stake range tooltip (Stack rate, current → next level).
        tooltip_metric = "win_dist",
        -- Cap is DYNAMIC (fill_scaled), same as Sharper Reads: the buyable
        -- max tracks the top currently-buyable stake's fill_window.complete,
        -- so Pot Control reaches exactly as deep as the ladder currently
        -- exposes (and no further — no dead levels). This is what fixes the
        -- old "can't touch T6" bug without hardcoding T6. Costs past ~L20 are
        -- placeholder pending the cost-curve pass.
        fill_scaled = true,
        max_level   = 29,
        -- Same fast-early / slow-late shape as Sharper Reads, ~2x its cost
        -- per level (Pot Control pushes TWO fills — win_dist + loss_dist).
        -- L1 ~$0.40 → ~$55B at L29. Placeholder, tune against §1.
        costs       = {
            0.40, 1, 2.5, 6, 16,
            40, 100, 250, 600, 1500,
            3600, 9000, 22000, 55000, 140000,
            350000, 900000, 2200000, 5600000, 14000000,
            36000000, 90000000, 220000000, 560000000, 1400000000,
            3600000000, 9000000000, 22000000000, 55000000000,
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
    -- Adds 1 cursor per level. Requires the catalog `box_of_mice` unlock
    -- + at least one cursor (catalog or run) to do anything visible.
    -- 12 levels.
    {
        id            = "box_of_mice",
        name          = "Cursor",
        description   = "+1 Cursor (auto-clicker)",
        tooltip_blurb = {
            "Adds an autoclicking cursor that clicks DEAL /",
            "REBUY (if purchased in catalog) buttons automatically.",
        },
        icon          = "cursor",
        requires      = "box_of_mice",
        requires_hide = true,
        max_level     = 12,
        -- Steepened so cursor investment spans the game (tops ~$40M ≈ T6),
        -- not a first-hour dump. Placeholder.
        costs       = {
            3, 12, 45, 170, 650,
            2500, 10000, 45000, 220000, 1200000,
            8000000, 40000000,
        },
        effects     = { { kind = "cursor_count_add", value = 1 } },
    },

    -- ── 7. Cursor Speed — they click faster ────────────────────────────
    -- 8 levels, +25% multiplicative each. Caps at ~6× base speed.
    {
        id            = "cursor_speed",
        name          = "Cursor Speed",
        description   = "Cursors move faster",
        tooltip_blurb = {
            "+25% cursor movement speed.",
        },
        icon          = "cursor_speed",
        requires      = "box_of_mice",
        requires_hide = true,
        max_level     = 8,
        -- Steepened (8 levels, tops ~$30M). Placeholder.
        costs       = {
            5, 40, 350, 3000, 25000,
            220000, 2000000, 30000000,
        },
        effects     = { { kind = "cursor_speed_mult", value = 1.25 } },
    },

    -- ── 8. Focus — throughput ──────────────────────────────────────────
    -- +1 focus capacity per level. Same effect kind as before. 10 levels.
    {
        id          = "focus",
        name        = "Focus",
        description = "Increase table limit before penalty",
        tooltip_blurb = {
            "Run more tables at once before your",
            "FOCUS multiplier starts dropping.",
        },
        icon        = "focus",
        max_level   = 10,
        -- Steepened (10 levels, tops ~$30M ≈ T6). Placeholder.
        costs       = {
            5, 25, 130, 650, 3300,
            16000, 85000, 450000, 3000000, 30000000,
        },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
    },

}
