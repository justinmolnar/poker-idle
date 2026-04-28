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
-- or for grid_shift:
--   { kind = "grid_shift", op = "lose_to_win" | "shift_downward",
--     amount = <number 0..1>,
--     skill = <skill_id>?, style = <style_id>?, gtype = <gtype_id>? }
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
        description = "Multiplies the $ delta on winning hands. Magnitude-only — does not reshape the outcome grid.",
        value_shape = "number, e.g. 1.10 for +10%",
        affects     = "ctx.earnings_mult",
    },

    -- Multiplicative scaling on losing-hand magnitudes.
    loss_mult = {
        description = "Multiplies the magnitude of losing-hand $ deltas. Magnitude-only — does not reshape the grid.",
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

    -- ── The grid-shift effect ────────────────────────────────────────────
    -- The single registered applicator pushes a transform descriptor onto
    -- ctx.grid_shifts. models/Table.lua:_buildGrid walks the list in
    -- registered order, applies each transform to the per-opponent grid,
    -- and renormalizes once at the end.
    --
    -- Recognized `op` values:
    --   • "lose_to_win" — moves `amount` mass from each Lose cell to the
    --     same-tier Win cell (TL→TW, SL→SW, ML→MW, JL→JW). When skill /
    --     style / gtype is set, the shift only applies if the sampled
    --     opponent / table game-type matches.
    --   • "shift_downward" — moves `amount` mass *downward* by one tier
    --     (Tiny → Small → Medium → Jackpot), splitting evenly between W
    --     and L columns. Targets the variance / pot-size axis.
    grid_shift = {
        description = "Reshapes the per-opponent outcome grid via a transform descriptor.",
        value_shape = "{ op = 'lose_to_win' | 'shift_downward', amount, skill?, style?, gtype? }",
        affects     = "ctx.grid_shifts (ordered list)",
    },

    -- ── Discovery / opponent reading ────────────────────────────────────

    reveal_chance_add = {
        description = "Bumps the per-showdown chance of flipping one opponent attribute.",
        value_shape = "number, e.g. 0.25 for +25 percentage points (clamped 0..1)",
        affects     = "ctx.reveal_chance_add",
    },
    revealed_at_start_count = {
        description = "Number of attributes pre-revealed when an opponent first sits.",
        value_shape = "integer, e.g. 1 to start with one attribute already known",
        affects     = "ctx.revealed_at_start_count",
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
