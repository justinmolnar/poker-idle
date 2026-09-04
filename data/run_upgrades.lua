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
-- Pricing (Sharper Reads / Pot Control): `costs` and `max_level` are
-- DERIVED at boot by models/UpgradePricing.lua from the ladder and the
-- outcome model, in hands of the board the player has at that level —
-- knobs in data/balance.lua (UPGRADE_HANDS_FIRST / _GROWTH /
-- _REFERENCE). Nothing in this file knows how many levels there are. An
-- upgrade's `cost_mult` scales its whole curve (Pot Control 2×).
-- Cursor / Cursor Speed / Focus below are still hand-typed against the
-- pre-2026-09 ladder (tops ~$30-40M, which is now mid-NL1M money) and
-- want the same treatment in a later pass.
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

local RunUpgrades = {

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
        -- grows/shrinks with the ladder + band gating on its own. max_level
        -- and costs are derived at boot (models/UpgradePricing.lua).
        fill_scaled = true,
        max_level   = nil,   -- derived
        costs       = nil,   -- derived
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
        description = "More {w:stack}, fewer {l:stack}. Where {chip} come from.",
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
        -- exposes (and no further — no dead levels). max_level and costs
        -- are derived at boot (models/UpgradePricing.lua); cost_mult 2×
        -- because Pot Control pushes TWO fills.
        fill_scaled = true,
        cost_mult   = 2.0,
        max_level   = nil,   -- derived
        costs       = nil,   -- derived
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
        id            = "cursor",
        name          = "Cursor",
        description   = "+1 cursor. It deals for you.",
        tooltip_blurb = {
            "Adds an autoclicking cursor that clicks DEAL /",
            "REBUY (if purchased in catalog) buttons automatically.",
        },
        icon          = "cursor",
        requires      = "box_of_mice",
        requires_hide = true,
        -- This row carries the GLOBAL cursor toggles (deal / rebuy, scoped
        -- to every open table). It hangs here because this is the upgrade
        -- that made cursors exist, so it is where a player looks for their
        -- master switch. Authored rather than matched on id in the view.
        cursor_master_controls = true,
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
        description = "Watch more tables without slipping.",
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

return RunUpgrades
