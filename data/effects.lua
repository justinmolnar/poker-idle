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

    -- Multiplicative speedup on hand-cinematic pace, composing with the
    -- gtype.pace_mult baseline. Used by Energy Drink (×1.25). Bigger =
    -- faster hands. Sits in models/Table.lua's effective_dt computation.
    hand_pace_mult = {
        description = "Multiplies the hand-cinematic pace (composes with gtype.pace_mult).",
        value_shape = "number >1 for faster, e.g. 1.25 for +25% pace",
        affects     = "ctx.hand_pace_mult (multiplicative)",
    },

    -- ── Outcome-model effects ────────────────────────────────────────────
    -- The outcome model has three independent dimensions per hand:
    --   • win_chance — single probability ∈ [0, 1] that the hand is a Win
    --   • win_dist   — { small, medium, large, jackpot }, sums to 1, sampled
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

    -- Multiplicative scaling on the FINAL win chance (after fills, shifts,
    -- and gtype shift). Used by the no-poster handicap to knock T1's 50%
    -- naked WC down to ~20% before the player owns the Poker Poster. Stays
    -- engine-neutral — any future "skill discount" effect could reuse it.
    wc_mult = {
        description = "Multiplies the final win_chance after all additive shifts.",
        value_shape = "number, e.g. 0.4 for a 60% knockdown",
        affects     = "ctx.wc_mult (multiplicative)",
    },

    -- Catalog additive shape on the loss_dist (mirror of gtype.dist_shifts
    -- on the loss side). Pushes mass between buckets — applied alongside
    -- gtype dist_shifts, before the final clamp/normalize. Used by the
    -- no-poster handicap to skew Run-0 losses toward Medium+.
    loss_dist_shift = {
        description = "Pushes a loss_dist additive-shape descriptor onto ctx.loss_dist_shifts.",
        value_shape = "{ shift = { small=±X, medium=±X, large=±X, jackpot=±X }, gtype? }",
        affects     = "ctx.loss_dist_shifts (ordered list)",
    },

    -- Win-side mirror. Optional `tier_min` / `tier_max` (1-based stake
    -- index) bound the shift to specific tiers — used by deck specs that
    -- only reshape outcomes at certain stakes (e.g. Low Stakes Hero
    -- shifts mass toward jackpot at T1-T3 only).
    win_dist_shift = {
        description = "Pushes a win_dist additive-shape descriptor onto ctx.win_dist_shifts.",
        value_shape = "{ shift = { small=±X, medium=±X, large=±X, jackpot=±X }, gtype?, tier_min?, tier_max? }",
        affects     = "ctx.win_dist_shifts (ordered list)",
    },

    -- Pre-roll auto-win override. Each entry's `amount` (0..1) sums into
    -- a per-hand auto-win probability filtered by gtype. sampleOutcome
    -- rolls once before the natural WC roll; success forces won=true.
    -- Top-of-pipeline — bypasses fill_window / distribution shifts.
    -- Used by MTT Pro to flat-bump MTT cash rate at every tier.
    auto_win_chance = {
        description = "Pushes an auto-win-probability descriptor onto ctx.auto_win_chances.",
        value_shape = "{ amount = 0..1, gtype? }",
        affects     = "ctx.auto_win_chances (ordered list)",
    },

    -- ── Tier re-roll shifts ─────────────────────────────────────────────
    -- After sampleOutcome picks a tier, an optional re-roll bumps the tier
    -- up (win path) or down (loss path) with a configured chance. Different
    -- mechanism from win_dist_fill / loss_dist_fill (which reshape the
    -- pre-sample distribution); these fire AFTER the sample, conditional
    -- on the picked tier. Used by Self-Help Book / Lava Lamp (win-side)
    -- and Stress Ball / Worry Stone (loss-side).

    win_tier_shift = {
        description = "Push a post-sample win-tier upgrade descriptor onto ctx.win_tier_shifts.",
        value_shape = "{ from = 'small'|'medium'|'large', to = 'medium'|'large'|'jackpot', chance = 0..1, gtype? }",
        affects     = "ctx.win_tier_shifts (ordered list)",
    },

    loss_tier_shift = {
        description = "Push a post-sample loss-tier downgrade descriptor onto ctx.loss_tier_shifts.",
        value_shape = "{ from = 'medium'|'large'|'jackpot', to = 'small'|'medium'|'large', chance = 0..1, gtype? }",
        affects     = "ctx.loss_tier_shifts (ordered list)",
    },

    -- Multiplies jackpot-tier WIN magnitudes (Branded Hat). Magnitude-only;
    -- doesn't reshape the dist. Pairs with earnings_mult — earnings_mult
    -- scales every win, jackpot_mult scales only jackpots.
    jackpot_mult = {
        description = "Multiplies the magnitude of jackpot-tier wins.",
        value_shape = "number, e.g. 1.20 for +20% jackpot payouts",
        affects     = "ctx.jackpot_mult (multiplicative)",
    },

    -- Additive percentage on starting bankroll (Lucky Coin = +50%). Sits
    -- next to start_bankroll_add: that's a flat $ add, this is a %.
    -- Computed against Constants.GAMEPLAY.INITIAL_BANKROLL in
    -- GameState:applyStartingPerks.
    start_bankroll_pct = {
        description = "Adds (pct × initial bankroll) to the seeded bankroll at run start.",
        value_shape = "number, e.g. 0.5 for +50% of the base seed",
        affects     = "ctx.start_bankroll_pct (additive)",
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

    -- Flat PP granted on every jackpot-tier WIN (Pen). Independent of the
    -- per-(stake, gtype) bounty system — fires every time, not just first.
    jackpot_pp_add = {
        description = "Flat PP added to pp_this_run on every jackpot-tier win.",
        value_shape = "integer, e.g. 1 for +1 PP per jackpot",
        affects     = "ctx.jackpot_pp_add",
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
    cursor_rebuy_unlocked = {
        description = "Flag perk — cursors also click REBUY (not just DEAL). Per-table opt-out via the [R] header toggle.",
        value_shape = "no field (presence sets ctx.cursor_rebuy_unlocked = true)",
        affects     = "ctx.cursor_rebuy_unlocked",
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

    -- ── Tournament payouts ──────────────────────────────────────────────
    -- Integer-level boost into data/mtt_payouts.lua. Max-stacks (the
    -- higher-tier perk wins outright; doesn't compound on the lower one).
    mtt_payout_boost = {
        description = "Bumps MTT cash-tier multipliers (max-stacking, not multiplicative).",
        value_shape = "integer 1 or 2 — selects the tier in data/mtt_payouts.lua",
        affects     = "ctx.mtt_payout_boost",
    },

}

return Effects
