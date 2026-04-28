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

    -- Situational multipliers vs specific opponent playstyles. Targeted by
    -- catalog and run upgrades — playstyle is the lateral axis (skill is
    -- additive only, not exploitable). The kind name encodes the playstyle.
    vs_fish_mult = {
        description = "Multiplier on win chance versus loose-passive (fish) opponents.",
        value_shape = "number, e.g. 1.05 for +5%",
        affects     = "ctx.vs_fish",
    },
    vs_tag_mult = {
        description = "Multiplier on win chance versus tight-aggressive (TAG) opponents.",
        value_shape = "number, e.g. 1.05 for +5%",
        affects     = "ctx.vs_tag",
    },
    vs_lag_mult = {
        description = "Multiplier on win chance versus loose-aggressive (LAG) opponents.",
        value_shape = "number, e.g. 1.05 for +5%",
        affects     = "ctx.vs_lag",
    },
    vs_nit_mult = {
        description = "Multiplier on win chance versus ultra-tight (Nit) opponents.",
        value_shape = "number, e.g. 1.05 for +5%",
        affects     = "ctx.vs_nit",
    },

    -- Slows rep / burn meter rise during a run.
    rep_decay_slow = {
        description = "Multiplies the rate at which rep accumulates.",
        value_shape = "number, e.g. 0.85 for 15% slower decay",
        affects     = "ctx.rep_decay",
    },

    -- Focus capacity — how many tables the player can run before the
    -- per-hand focus_mult starts shaving the $ delta down. Default base
    -- is FOCUS_BASE_CAPACITY (4). Upgrades stack additively. Catalog +
    -- run-upgrade items both target this kind.
    focus_capacity_add = {
        description = "Raises focus capacity (tables you can run before the focus penalty kicks in).",
        value_shape = "integer, e.g. 1 for +1 capacity",
        affects     = "ctx.focus_capacity",
    },

    -- Reduces the per-extra-table focus penalty multiplicatively. Effective
    -- penalty = FOCUS_BASE_PENALTY * ctx.focus_penalty_reduce_mult. Lower
    -- values = softer penalty curve = larger viable multi-tabling.
    focus_penalty_reduce_mult = {
        description = "Multiplies the focus penalty per extra table (lower = softer curve).",
        value_shape = "number <1, e.g. 0.85 for 15% softer penalty",
        affects     = "ctx.focus_penalty_reduce_mult",
    },

}

return Effects
