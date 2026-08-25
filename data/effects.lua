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
        description = "Pushes a win_chance fill descriptor onto ctx.win_chance_fills. Optional tier_min/tier_max (1-based stake index) scope the fill to certain stakes (High Roller fills WC at T4+ only).",
        value_shape = "{ strength, gtype?, tier_min?, tier_max? }",
        affects     = "ctx.win_chance_fills (ordered list)",
        scale       = "fill",      -- one level = one unit; run_upgrade_strength_mult is applied in the outcome model, not here
    },

    -- Run-upgrade win_dist fill — same mechanism on the win-tier dist.
    win_dist_fill = {
        description = "Pushes a win_dist fill descriptor onto ctx.win_dist_fills.",
        value_shape = "{ strength, gtype? }",
        affects     = "ctx.win_dist_fills (ordered list)",
        scale       = "fill",      -- one level = one unit; run_upgrade_strength_mult is applied in the outcome model, not here
    },

    -- Run-upgrade loss_dist fill — same mechanism on the loss-tier dist.
    loss_dist_fill = {
        description = "Pushes a loss_dist fill descriptor onto ctx.loss_dist_fills.",
        value_shape = "{ strength, gtype? }",
        affects     = "ctx.loss_dist_fills (ordered list)",
        scale       = "fill",      -- one level = one unit; run_upgrade_strength_mult is applied in the outcome model, not here
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
    -- Applied AFTER start_bankroll_add in GameState:applyStartingPerks,
    -- so the percentage multiplies the post-add bankroll. "+$5 + 50%" on
    -- a $2 base = ($2 + $5) × 1.5 = $10.50.
    start_bankroll_pct = {
        description = "Multiplies the bankroll seed (after flat adds) by (1 + pct).",
        value_shape = "number, e.g. 0.5 for +50%",
        affects     = "ctx.start_bankroll_pct (additive)",
    },

    -- ── Meta-progression perks (catalog only, applied at run start) ─────

    start_bankroll_add = {
        description = "Bonus bankroll seeded at the start of every run.",
        value_shape = "number $, e.g. 5 to start with $7 instead of $2",
        affects     = "ctx.start_bankroll_add",
    },
    start_table_count = {
        description = "Number of NL2 6-max tables auto-opened at run start (free).",
        value_shape = "integer, e.g. 1 to start with one table already seated",
        affects     = "ctx.start_table_count",
    },
    buy_in_mult = {
        description = "Multiplier on table buy-in costs (lower = cheaper sits). Optional tier_min/tier_max (1-based stake index) scope the discount to certain stakes (High Roller halves T4+ buy-ins); tier-bounded entries go on ctx.buy_in_mult_tiered and are folded per-stake by GrindController:buyInMultFor.",
        value_shape = "number <1, e.g. 0.85 for 15% off; { value, tier_min?, tier_max? } for tier-scoped",
        affects     = "ctx.buy_in_mult (scalar) or ctx.buy_in_mult_tiered (list)",
    },
    run_upgrade_cost_mult = {
        description = "Multiplier on run-upgrade level-up costs.",
        value_shape = "number <1, e.g. 0.80 for 20% cheaper run upgrades",
        affects     = "ctx.run_upgrade_cost_mult",
    },
    chip_award_mult = {
        description = "Multiplier on chips earned from per-(stake, game_type) bounties.",
        value_shape = "number, e.g. 2.0 to double chip awards",
        affects     = "ctx.chip_award_mult",
    },

    -- Flat chips granted on every jackpot-tier WIN (Pen). Independent of the
    -- per-(stake, gtype) bounty system — fires every time, not just first.
    jackpot_chip_add = {
        description = "Flat chips added to chips_this_run on every jackpot-tier win.",
        value_shape = "integer, e.g. 1 for +1 chip per jackpot",
        affects     = "ctx.jackpot_chip_add",
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
        scale       = "integer",   -- run_upgrade_strength_mult leaves it alone
    },
    cursor_speed_mult = {
        description = "Multiplies the cursor pool's travel speed.",
        value_shape = "number, e.g. 1.25 for +25% per level",
        affects     = "ctx.cursor_speed_mult",
        scale       = "value_mult1",
    },
    cursor_sync_unlocked = {
        description = "Flag perk — cursors coordinate so no two race to the same table.",
        value_shape = "no field (presence sets ctx.cursor_sync_unlocked = true)",
        affects     = "ctx.cursor_sync_unlocked",
    },
    cursor_memory_unlocked = {
        description = "Flag perk — cursors never forget their target on long journeys.",
        value_shape = "no field (presence sets ctx.cursor_memory_unlocked = true)",
        affects     = "ctx.cursor_memory_unlocked",
    },
    cursor_collision_phasing = {
        description = "Flag perk — cursors phase through each other without bumping or recoil.",
        value_shape = "no field (presence sets ctx.cursor_collision_phasing = true)",
        affects     = "ctx.cursor_collision_phasing",
    },
    cursor_optical_sensor = {
        description = "Flag perk — eliminates trackball cleaning pauses.",
        value_shape = "no field (presence sets ctx.cursor_optical_sensor = true)",
        affects     = "ctx.cursor_optical_sensor",
    },

    -- ── Focus / efficiency mechanic ─────────────────────────────────────
    focus_capacity_add = {
        description = "Raises focus capacity (tables you can run before the focus penalty kicks in).",
        value_shape = "integer, e.g. 1 for +1 capacity",
        affects     = "ctx.focus_capacity",
        scale       = "integer",   -- run_upgrade_strength_mult leaves it alone
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

    -- ── Deck capability kinds ───────────────────────────────────────────
    -- Generic capabilities composed by decks in data/decks.lua (numbers
    -- live there). None names a deck. Tier floors/ceilings clamp the
    -- sampled tier in outcome_math.sampleOutcome (1-based ranks; max for
    -- floors, min for ceilings). The rest set ctx fields their consumer
    -- reads with `if ctx.<field>` — same flag pattern as cursor_unlocked.

    win_tier_floor = {
        description = "Wins can't roll below this tier (Standard capstone: medium).",
        value_shape = "{ tier = 'small'|'medium'|'large'|'jackpot' }",
        affects     = "ctx.win_tier_floor (rank, max-combined)",
    },
    loss_tier_ceiling = {
        description = "Losses can't roll above this tier (Nit capstone: large — bans jackpot 'stack' losses).",
        value_shape = "{ tier = 'small'|'medium'|'large'|'jackpot' }",
        affects     = "ctx.loss_tier_ceiling (rank, min-combined)",
    },
    tier_bump_chance = {
        description = "Per-resolve chance to bump the sampled tier one step, win or loss (Maniac capstone). Consumed via a NEXT_TIER lookup in models/Table.lua.",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.tier_bump_chance (max-combined)",
    },
    payout_double_chance = {
        description = "Per-resolve chance to double the payout magnitude (Maniac capstone).",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.payout_double_chance (max-combined)",
    },
    rebuy_discount = {
        description = "Additive rebuy-cost discount fraction (Short Stack). Consumed in GrindController:rebuyTable.",
        value_shape = "number, e.g. 0.15 for 15% off per level",
        affects     = "ctx.rebuy_discount (additive)",
    },
    free_rebuy_chance = {
        description = "Chance for a rebuy to be completely free (Short Stack capstone).",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.free_rebuy_chance (max-combined)",
    },
    earnings_per_tier = {
        description = "Additive earnings bonus per stake tier index (The Bank). earnings_mult *= (1 + value * tier_idx) in models/Table.lua.",
        value_shape = "number, e.g. 0.15 for +15% per tier per level",
        affects     = "ctx.earnings_per_tier (additive)",
    },
    earnings_scale_by_bankroll = {
        description = "Flag — scales every hand's magnitude by a bankroll-log multiplier (The Bank capstone). Applied at resolve time in GrindController where live bankroll is available.",
        value_shape = "no field (presence sets ctx.earnings_scale_by_bankroll = true)",
        affects     = "ctx.earnings_scale_by_bankroll",
    },
    focus_penalty_immune = {
        description = "Flag — removes the multi-table focus penalty (Multitasker capstone).",
        value_shape = "no field (presence sets ctx.focus_penalty_immune = true)",
        affects     = "ctx.focus_penalty_immune",
    },
    run_upgrade_strength_mult = {
        description = "Makes run upgrades stronger (Investor, Calculator). Additive from 1.0. For the fill upgrades (Sharper Reads, Pot Control) it multiplies each stake's per-level gain in the outcome model, so 5 levels that added 25% add 28.75% and MAX stays at level 5. For value kinds it is applied in GameState:computeEffects per the kind's `scale`; integer kinds are left alone.",
        value_shape = "number, e.g. 0.15 for +15% per level",
        affects     = "ctx.run_upgrade_strength_mult (additive from 1.0)",
    },
    run_upgrade_bonus_levels = {
        description = "Adds extra purchasable levels to run upgrades (Investor capstone, Bookshelf). For the fill upgrades each extra level is one more level's worth of gain at every stake: 5 levels that added 25% become 6 that add 30%. Consumed in GrindController:getRunUpgradeMaxLevel (the shop) and outcome_math.fillRatio (the cap).",
        value_shape = "integer, e.g. 1 for +1 level",
        affects     = "ctx.run_upgrade_bonus_levels (additive)",
    },
    fill_window_widen = {
        description = "Widens every stake's fill_window symmetrically (Tier Manipulator). Consumed in outcome_math.fillRatio.",
        value_shape = "integer, e.g. 1 per level",
        affects     = "ctx.fill_window_widen (additive)",
    },
    fill_cascade = {
        description = "Flag — fills ignore tier bounds and complete regardless of stake (Tier Manipulator capstone). Consumed in outcome_math sumFills + fillRatio.",
        value_shape = "no field (presence sets ctx.fill_cascade = true)",
        affects     = "ctx.fill_cascade",
    },
    solo_table_bonus = {
        description = "Earnings mult + win-chance shift that only apply while exactly one table is open (Specialist). active_tables_count is a transient param seeded by GrindController:invalidateEffects.",
        value_shape = "{ earnings_mult = number, wc_bonus? = 0..1 }",
        affects     = "ctx.earnings_mult / ctx.win_chance_shifts (only at 1 table)",
    },
    solo_table_pace = {
        description = "Hand-pace mult that only applies at exactly one table (Specialist capstone).",
        value_shape = "{ value = number, e.g. 2.0 }",
        affects     = "ctx.hand_pace_mult (only at 1 table)",
    },
    cursor_instant_click = {
        description = "Flag — zeroes the cursor per-click delay (Swarm capstone). Companion to cursor_speed_mult.",
        value_shape = "no field (presence sets ctx.cursor_zero_click_delay = true)",
        affects     = "ctx.cursor_zero_click_delay",
    },
    shove_base_per_deck_level = {
        description = "Restores shove base per TOTAL deck level (master deck). Reads ctx.total_deck_levels (seeded in GameState:computeEffects); max-combined so applyN re-application doesn't multiply by the master deck's own level. The base that survives the R2 cheat — see models/shove_rate.lua.",
        value_shape = "number, e.g. 0.01 for +1% base per total deck level",
        affects     = "ctx.shove_base (max-combined)",
    },
    shove_base_double = {
        description = "Flag — doubles the restored shove base (master deck capstone).",
        value_shape = "no field (presence sets ctx.shove_base_double = true)",
        affects     = "ctx.shove_base_double",
    },
    ultra_unlock_effect = {
        description = "Flag — unlocks T10 Ultra stake.",
        value_shape = "no field (presence sets ctx.ultra_unlocked = true)",
        affects     = "ctx.ultra_unlocked",
    },

    -- ── Catalog once-per-run item flags ─────────────────────────────────
    -- Consumed in GrindController's resolution loop; the "first per run"
    -- gating lives in run-scoped GameState flags.
    void_first_loss = {
        description = "Flag — voids the first losing hand each run (Rubber Duck).",
        value_shape = "no field (presence sets ctx.void_first_loss = true)",
        affects     = "ctx.void_first_loss",
    },
    void_first_stack_loss = {
        description = "Flag — voids the first jackpot-tier (stack) loss each run (The Fridge).",
        value_shape = "no field (presence sets ctx.void_first_stack_loss = true)",
        affects     = "ctx.void_first_stack_loss",
    },
    copy_first_denied = {
        description = "Flag — the first denied {chip} bounty each run banks anyway (Receipt Printer).",
        value_shape = "no field (presence sets ctx.copy_first_denied = true)",
        affects     = "ctx.copy_first_denied",
    },
    first_bounty_bonus = {
        description = "The first {chip} bounty each run pays +value extra (Dogs Playing Poker).",
        value_shape = "integer, e.g. 1 for +1 {chip} on the run's first bounty",
        affects     = "ctx.first_bounty_bonus (additive)",
    },

    -- ── Catalog appliances ──────────────────────────────────────────────
    -- All three are consumed in the controller / model layer, never in the
    -- outcome roll — so they behave identically under both per-hand models
    -- (Table.lua and Table_legacy.lua).

    bust_refund_pct = {
        description = "Fraction of the buy-in refunded to bankroll when a cash table busts (The Sink).",
        value_shape = "number 0..1, e.g. 0.30 for 30% back",
        affects     = "ctx.bust_refund_pct (additive; may exceed 1 for a corrupt block)",
    },
    deck_xp_mult = {
        description = "Multiplies XP granted to the active deck (Tori Gate). Applied in models/Decks.gainXp.",
        value_shape = "number, e.g. 1.50 for +50% XP",
        affects     = "ctx.deck_xp_mult (multiplicative)",
    },
    loss_recycle_pct = {
        description = "Fraction of the previous run's total losses seeded into the next run's starting bankroll (The Dishwasher).",
        value_shape = "number 0..1, e.g. 0.10 for 10%",
        affects     = "ctx.loss_recycle_pct (additive)",
    },

    -- ── Act 3 corruptions ────────────────────────────────────────────────
    -- Kinds that only corrupt blocks use. Consumed in the controller's
    -- resolution loop, so they behave identically under both table models.
    anti_award_mult = {
        description = "Multiplies the {achip} paid for a stack loss (corrupted Worry Stone). Consumed at the anti award site in GrindController.",
        value_shape = "number, e.g. 2 for double",
        affects     = "ctx.anti_award_mult (multiplicative)",
    },
    first_anti_mult = {
        description = "Multiplies the run's FIRST {achip} award (corrupted Fridge); state.first_anti_this_run latches it.",
        value_shape = "number, e.g. 3",
        affects     = "ctx.first_anti_mult (max)",
    },
    overcap_loss_mult = {
        description = "Multiplies losses while more tables are open than the focus capacity (corrupted Gaming Chair). Consumed beside the focus multiplier in GrindController.",
        value_shape = "number > 1, e.g. 3",
        affects     = "ctx.overcap_loss_mult (multiplicative)",
    },
    copy_denied_chance = {
        description = "Chance that a denied {chip} bounty banks anyway (corrupted Receipt Printer). Consumed at the denied-bounty site beside copy_first_denied.",
        value_shape = "number 0..1, e.g. 0.5",
        affects     = "ctx.copy_denied_chance (max)",
    },

}

return Effects
