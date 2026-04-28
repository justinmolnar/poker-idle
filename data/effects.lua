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
--
-- The applicator function signature is:
--   function(effect_entry, ctx)
-- where `ctx` is a mutable table holding whatever stat group is being computed
-- (e.g. ctx.shove_rate, ctx.earnings_mult). Applicators read effect.value and
-- mutate ctx.

local Effects = {}

Effects.kinds = {

    -- Direct shove-rate additions. The most expensive effect type — only
    -- catalog items grant these (run upgrades cannot).
    shove_rate_add = {
        description = "Adds a flat amount to the per-shove all-in win rate.",
        value_shape = "number, e.g. 0.02 for +2 percentage points",
        affects     = "ctx.shove_rate",
    },

    -- Multiplicative bankroll earnings.
    earnings_mult = {
        description = "Multiplies bankroll-per-hand earnings.",
        value_shape = "number, e.g. 1.10 for +10%",
        affects     = "ctx.earnings_mult",
    },

    -- Additive hands-per-minute bonus.
    hands_per_min_add = {
        description = "Adds to the table's hands-per-minute rate.",
        value_shape = "number, e.g. 5 for +5 hands/min",
        affects     = "ctx.hands_per_min",
    },

    -- Situational multiplier vs aggressive opponents.
    vs_aggressive_mult = {
        description = "Multiplier on win chance versus aggressive table types.",
        value_shape = "number, e.g. 1.05 for +5%",
        affects     = "ctx.vs_aggressive",
    },

    -- Slows rep / burn meter rise during a run.
    rep_decay_slow = {
        description = "Multiplies the rate at which rep accumulates.",
        value_shape = "number, e.g. 0.85 for 15% slower decay",
        affects     = "ctx.rep_decay",
    },

    -- Additive integer table-slot bonus. Base is 1; each +1 from this kind
    -- raises the cap on concurrent tables (clamped to MAX_TABLES = 6).
    -- Catalog only — Second Monitor is the canonical source.
    table_slots_add = {
        description = "Adds extra concurrent table slots beyond the base of 1.",
        value_shape = "integer, e.g. 1 for +1 slot",
        affects     = "ctx.table_slots",
    },

}

return Effects
