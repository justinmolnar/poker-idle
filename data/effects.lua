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

    -- ── Win-rate / pot math (the difficulty-curve hooks) ──────────────────

    win_rate_add = {
        description = "Flat additive bonus to per-hand win rate before clamp.",
        value_shape = "number, e.g. 0.015 for +1.5 percentage points",
        affects     = "ctx.win_rate_add",
    },
    loss_mult = {
        description = "Multiplier on the magnitude of losing-hand $ deltas (lower = smaller losses).",
        value_shape = "number <1, e.g. 0.90 for 10% softer losses",
        affects     = "ctx.loss_mult",
    },
    -- Skill-tier penalty multipliers. Skills are now targetable just like
    -- playstyles via a ctx_key on the skill entry; these multiply the raw
    -- penalty value before it folds into the win-rate sum. Lower values
    -- soften the per-skill penalty (so calm_hands lowers vs_pro_penalty
    -- to 0.67, making pros 33% less brutal).
    vs_pro_penalty_mult = {
        description = "Multiplier on the win-rate penalty from pro-tier opponents.",
        value_shape = "number, e.g. 0.67 to soften pros by 33%",
        affects     = "ctx.vs_pro_penalty",
    },
    vs_grind_penalty_mult = {
        description = "Multiplier on the win-rate penalty from grinder-tier opponents.",
        value_shape = "number, e.g. 0.75 to soften grinds by 25%",
        affects     = "ctx.vs_grind_penalty",
    },
    -- Multiplier on the game-type win_rate_offset. HU's harsh -0.15 baseline
    -- gets cut in half by hu_specialist (gtype_offset_mult: 0.50).
    gtype_offset_mult = {
        description = "Multiplier on the game-type win_rate_offset (HU/Zoom baseline shift).",
        value_shape = "number, e.g. 0.50 to halve HU's penalty",
        affects     = "ctx.gtype_offset_mult",
    },

    -- ── Discovery / opponent reading ──────────────────────────────────────

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

    -- ── Meta-progression perks (catalog only, applied at run start) ───────

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

}

return Effects
