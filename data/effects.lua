-- data/effects.lua
--
-- The CANONICAL list of effect kinds. Documentation only — no logic.
-- Application functions live in models/poker_effects.lua (the registry
-- mechanism itself lives in services/EffectsRegistry.lua but the
-- poker-specific registrations are in the model layer).
--
-- Adding a new effect kind:
--   1. Add an entry to this table with a short description and the value shape.
--   2. Add a single `:register(kind, fn)` call in models/poker_effects.lua.
--   3. Use the kind in a catalog item, run upgrade, or anywhere that emits effects.
--
-- THERE IS NO if/elseif chain on `kind` strings ANYWHERE. If you find yourself
-- writing one, you're doing it wrong — register a function instead.
--
-- Effect entry shape that callers (catalog.lua, run_upgrades.lua) emit:
--   { kind = "<kind>", value = <number> }
-- or for the outcome-model effects (run upgrades — fill kinds):
--   { kind = "win_chance_fill" | "win_dist_fill" | "loss_dist_fill",
--     strength = <number>,
--     gtype    = <gtype_id>? }
-- or for catalog flat additive on WC:
--   { kind = "win_chance_shift",
--     amount = <number>,
--     gtype  = <gtype_id>? }
--
-- The applicator function signature is:
--   function(effect_entry, ctx)
-- where `ctx` is a mutable table holding whatever stat group is being computed.

local Effects = {}

Effects.kinds = {

    -- Direct shove-rate additions. The most expensive effect type — only
    -- catalog items grant these (run upgrades cannot).
    shove_rate_add = {
        description = "Adds a flat amount to the per-shove all-in win rate.",
        value_shape = "number, e.g. 0.02 for +2 percentage points",
        affects     = "ctx.shove_rate",
    },

    -- Multiplicative bankroll earnings on winning hands.
    earnings_mult = {
        description = "Multiplies the $ delta on winning hands. Magnitude-only — does not reshape the outcome model.",
        value_shape = "number, e.g. 1.10 for +10%",
        affects     = "ctx.earnings_mult",
    },

    -- Multiplicative scaling on losing-hand magnitudes.
    loss_mult = {
        description = "Multiplies the magnitude of losing-hand $ deltas. Magnitude-only — does not reshape the outcome model.",
        value_shape = "number <1, e.g. 0.90 for 10% softer losses",
        affects     = "ctx.loss_mult",
    },

    -- Additive hands-per-minute bonus. (Held over from earlier design;
    -- nothing currently consumes this — pace is governed by game_type.pace_mult.)
    hands_per_min_add = {
        description = "Adds to the table's hands-per-minute rate.",
        value_shape = "number, e.g. 5 for +5 hands/min",
        affects     = "ctx.hands_per_min",
    },

    -- ── Outcome-model effects ────────────────────────────────────────────
    -- The outcome model has three independent dimensions per hand:
    --   • win_chance — single probability ∈ [0, 1] that the hand is a Win
    --   • win_dist   — { tiny, small, medium, jackpot }, sums to 1, sampled
    --                  when winning
    --   • loss_dist  — same shape, sampled when losing
    --
    -- Each stake declares both a *naked* and *run-capped* value for these
    -- dimensions. Run upgrades fill the gap between them via the three
    -- *_fill kinds below — each level pushes one fill descriptor; the sum
    -- of matching descriptor strengths becomes "fill units" that lerp the
    -- dimension toward run-capped. Filters (skill / style / gtype) gate
    -- which descriptors count for a given (opp, gtype).
    --
    -- Catalog perks use win_chance_shift (flat additive) — applied AFTER
    -- the lerp, the only mechanism for crossing run-capped toward the
    -- absolute 0.95 WC ceiling.

    -- Run-upgrade WC fill. Each application contributes `strength` units
    -- (1.0 universal) to the WC fill total. Optional gtype filter.
    win_chance_fill = {
        description = "Pushes a win_chance fill descriptor onto ctx.win_chance_fills.",
        value_shape = "{ strength, gtype? }",
        affects     = "ctx.win_chance_fills (ordered list)",
    },

    -- Run-upgrade win_dist fill — same mechanism on the win-tier dist.
    win_dist_fill = {
        description = "Pushes a win_dist fill descriptor onto ctx.win_dist_fills.",
        value_shape = "{ strength, gtype? }",
        affects     = "ctx.win_dist_fills (ordered list)",
    },

    -- Run-upgrade loss_dist fill — same mechanism on the loss-tier dist.
    loss_dist_fill = {
        description = "Pushes a loss_dist fill descriptor onto ctx.loss_dist_fills.",
        value_shape = "{ strength, gtype? }",
        affects     = "ctx.loss_dist_fills (ordered list)",
    },

    -- Catalog flat additive on WC. Layered AFTER the lerp; pushes WC
    -- beyond run-capped toward the absolute 0.95 ceiling.
    win_chance_shift = {
        description = "Pushes a win_chance shift descriptor onto ctx.win_chance_shifts.",
        value_shape = "{ amount, gtype? }",
        affects     = "ctx.win_chance_shifts (ordered list)",
    },

    -- ── Meta-progression perks (catalog only, applied at run start) ─────

    start_bankroll_add = {
        description = "Bonus bankroll seeded at the start of every run.",
        value_shape = "number $, e.g. 5 to start with $7 instead of $2",
        affects     = "ctx.start_bankroll_add",
    },
    start_table_count = {
        description = "Number of $0.01/$0.02 6-max tables auto-opened at run start (free).",
        value_shape = "integer, e.g. 1 to start with one table already seated",
        affects     = "ctx.start_table_count",
    },
    buy_in_mult = {
        description = "Multiplier on table buy-in costs (lower = cheaper sits).",
        value_shape = "number <1, e.g. 0.85 for 15% off buy-ins",
        affects     = "ctx.buy_in_mult",
    },
    run_upgrade_cost_mult = {
        description = "Multiplier on run-upgrade level-up costs.",
        value_shape = "number <1, e.g. 0.80 for 20% cheaper run upgrades",
        affects     = "ctx.run_upgrade_cost_mult",
    },
    pp_award_mult = {
        description = "Multiplier on PP earned from per-(stake, game_type) bounties.",
        value_shape = "number, e.g. 2.0 to double PP awards",
        affects     = "ctx.pp_award_mult",
    },

    -- ── Slows rep / burn meter rise during a run. (Held over.)
    rep_decay_slow = {
        description = "Multiplies the rate at which rep accumulates.",
        value_shape = "number, e.g. 0.85 for 15% slower decay",
        affects     = "ctx.rep_decay",
    },

    -- ── Cursor swarm (autonomous DEAL-clickers) ─────────────────────────
    -- The cursor system is gated by a flag perk; without `cursor_unlocked`
    -- the CursorPool runs no cursors regardless of count. Catalog and run
    -- upgrades both feed `cursor_count_add` (additive) and may scale speed
    -- via `cursor_speed_mult`. See services/CursorPool.lua.

    cursor_unlocked = {
        description = "Flag perk — unlocks the autonomous cursor swarm system.",
        value_shape = "no field (presence sets ctx.cursor_unlocked = true)",
        affects     = "ctx.cursor_unlocked",
    },
    cursor_count_add = {
        description = "Adds N to the autonomous cursor pool size.",
        value_shape = "integer, e.g. 1 for +1 cursor",
        affects     = "ctx.cursor_count",
    },
    cursor_speed_mult = {
        description = "Multiplies the cursor pool's travel speed.",
        value_shape = "number, e.g. 1.25 for +25% per level",
        affects     = "ctx.cursor_speed_mult",
    },

    -- ── Focus / efficiency mechanic ─────────────────────────────────────
    focus_capacity_add = {
        description = "Raises focus capacity (tables you can run before the focus penalty kicks in).",
        value_shape = "integer, e.g. 1 for +1 capacity",
        affects     = "ctx.focus_capacity",
    },
    focus_penalty_reduce_mult = {
        description = "Multiplies the focus penalty per extra table (lower = softer curve).",
        value_shape = "number <1, e.g. 0.85 for 15% softer penalty",
        affects     = "ctx.focus_penalty_reduce_mult",
    },

}

return Effects
