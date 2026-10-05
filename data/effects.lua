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
        affects     = "ctx.hand_pace_mult (multiplicative), or ctx.hand_pace_mult_by_gtype[gtype] when the effect names a gtype (Firehose)",
    },

    -- High Roller Pass. The value is win chance per completed tournament,
    -- granted to CASH games at that stake, summed over the finish counts
    -- of the open tournament tables there — derived at rollup, so closing
    -- a tournament retires its share and cash tables opened later get the
    -- current total at once.
    tourney_backing = {
        description = "Win chance for cash games at a stake, per tournament a still-open tournament table there has finished.",
        value_shape = "number, e.g. 0.01 for +1% per finish",
        affects     = "ctx.tourney_backing (rate); derived per-stake cash-only win_chance_shifts at rollup",
    },

    -- Chance an arriving bad-polarity status (a tilt) simply doesn't stick
    -- (Dish Soap). Rolled once per application in Table:applyStatus.
    tilt_resist_chance = {
        description = "Chance an arriving tilt doesn't stick.",
        value_shape = "number 0..1, e.g. 0.4 for 40%",
        affects     = "ctx.tilt_resist_chance (additive)",
    },

    -- Run-ratchets land at a multiple (Whiteboard). Consumed by the
    -- `ratchet` proc payload at grant time.
    ratchet_gain_mult = {
        description = "Multiplies what each run-ratchet grant is worth.",
        value_shape = "number, e.g. 2.0 for double",
        affects     = "ctx.ratchet_gain_mult (multiplicative)",
    },

    -- The zoom cascade deals the empty tables it finds (Copy Machine).
    loss_reroll_chance = {
        description = "Stack of Books: a loss rolls the whole outcome again this often and keeps the better (a win beats any loss; sampleOutcome).",
        value_shape = "0..1, a printable fraction (1/6)",
        affects     = "ctx.loss_reroll_chance",
    },
    odds_per_lane_seated = {
        description = "Wall Hanger: every distinct table type in play (a stake at a game type) adds this to every table's win chance (buildOutcome x ctx.lanes_seated).",
        value_shape = "fraction per lane, e.g. 0.01",
        affects     = "ctx.odds_per_lane_seated",
    },
    lonely_winnings_mult = {
        description = "Throw Pillow: a table with no table on any side (t._lonely, stamped per frame) multiplies its winnings by this.",
        value_shape = "number, e.g. 1.5",
        affects     = "ctx.lonely_winnings_mult",
    },
    odds_per_empty_adjacent = {
        description = "Yellow Sticky Note: each empty cell inside the board beside a table adds this to that table's win chance (t._empty_adjacent).",
        value_shape = "fraction per empty cell, e.g. 0.05",
        affects     = "ctx.odds_per_empty_adjacent",
    },
    six_max_counts_empty = {
        description = "Flag perk — Comfort Bed: a 6-Max table reads as an empty cell to the empty-space items.",
        value_shape = "no field (presence sets ctx.six_max_counts_empty = true)",
        affects     = "ctx.six_max_counts_empty",
    },
    held_odds = {
        description = "Lava Lamp: the table in the player's hand (t._held, stamped by GrindView while dragging) has this much more win chance.",
        value_shape = "fraction, e.g. 0.10",
        affects     = "ctx.held_odds",
    },
    held_pace = {
        description = "Lava Lamp: the table in the player's hand (t._held) deals this many times faster while held.",
        value_shape = "multiplier, e.g. 3.0",
        affects     = "ctx.held_pace",
    },
    manual_hand_mult = {
        description = "Tally Book: a hand the player deals themself (not a cursor) pays this many times its winnings.",
        value_shape = "multiplier, e.g. 1.5",
        affects     = "ctx.manual_hand_mult",
    },
    odds_per_item = {
        description = "Corkboard: this much more win chance at every table per item owned, up to cap (computeEffects adds it as a win_chance_shift).",
        value_shape = "value = fraction per item, cap = the most it adds, e.g. 0.01 / 0.10",
        affects     = "ctx.odds_per_item",
    },
    age_pace = {
        description = "Wall Clock: a table deals faster the longer it has been open this run, 1 + value per minute up to cap (Table:paceParts, t._age_min).",
        value_shape = "value = pace per minute, cap = the most, e.g. 0.10 / 2.0",
        affects     = "ctx.age_pace",
    },
    zoom_tilt_pace = {
        description = "Headset: a tilted Zoom table deals this many times faster while the tilt lasts (Table:paceParts).",
        value_shape = "multiplier, e.g. 2.0",
        affects     = "ctx.zoom_tilt_pace",
    },
    manual_combo = {
        description = "Cutting Board: wins in a row on hands the player dealt (not a cursor, not a punch) multiply the next player-dealt hand's winnings by 1 + value x streak, capped at cap (GrindController.manual_combo).",
        value_shape = "value = fraction per win, cap = the multiplier's ceiling",
        affects     = "ctx.manual_combo",
    },
    zoom_fast_fold = {
        description = "Flag perk — Handheld: a loss at Zoom deals the next hand now (the controller's resolution loop).",
        value_shape = "no field (presence sets ctx.zoom_fast_fold = true)",
        affects     = "ctx.zoom_fast_fold",
    },
    zoom_tilt_one_hand = {
        description = "Flag perk — Headset: a tilt that ends a Zoom hand does not latch the next one (Table:_finalizeHand).",
        value_shape = "no field (presence sets ctx.zoom_tilt_one_hand = true)",
        affects     = "ctx.zoom_tilt_one_hand",
    },
    zoom_hands_count_twice = {
        description = "Flag perk — Copy Machine: a Zoom hand counts as two in every hand counter and hand-based deck XP rule.",
        value_shape = "no field (presence sets ctx.zoom_hands_count_twice = true)",
        affects     = "ctx.zoom_hands_count_twice",
    },
    zoom_block_pace = {
        description = "Receipt Printer: a Zoom table deals this much faster per adjacent Zoom table (the controller stamps t._zoom_neighbours).",
        value_shape = "fraction per neighbour, e.g. 0.10",
        affects     = "ctx.zoom_block_pace",
    },
    zoom_combo_pace = {
        description = "Washing Machine: wins in a row at a Zoom table deal `value` faster each, up to `cap` (Table:update; t._combo).",
        value_shape = "value = fraction per win, cap = fraction",
        affects     = "ctx.zoom_combo_pace",
    },
    odds_per_hand_per_second = {
        description = "Framed Diploma: every hand per second the board plays adds this to Zoom tables' win chance (buildOutcome x ctx.hands_per_second).",
        value_shape = "fraction per hand/s, e.g. 0.02",
        affects     = "ctx.odds_per_hand_per_second",
    },

    -- The board's top-left cell plays better (Red Rug). Consumed in
    -- Table:deal against the table's packed slot.
    corner_win_chance = {
        description = "Win chance for whichever table sits in the board's top-left cell.",
        value_shape = "number, e.g. 0.02 for +2%",
        affects     = "ctx.corner_win_chance",
    },

    -- ── Outcome-model effects ────────────────────────────────────────────
    -- The outcome model has three independent dimensions per hand:
    --   • win_chance — single probability ∈ [0, 1] that the hand is a Win
    --   • win_dist   — { small, medium, large, stack }, sums to 1, sampled
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
        value_shape = "{ shift = { small=±X, medium=±X, large=±X, stack=±X }, gtype? }",
        affects     = "ctx.loss_dist_shifts (ordered list)",
    },

    -- Win-side mirror. Optional `tier_min` / `tier_max` (1-based stake
    -- index) bound the shift to specific tiers — used by deck specs that
    -- only reshape outcomes at certain stakes (e.g. Low Stakes Hero
    -- shifts mass toward stack at T1-T3 only).
    win_dist_shift = {
        description = "Pushes a win_dist additive-shape descriptor onto ctx.win_dist_shifts.",
        value_shape = "{ shift = { small=±X, medium=±X, large=±X, stack=±X }, gtype?, tier_min?, tier_max? }",
        affects     = "ctx.win_dist_shifts (ordered list)",
    },

    -- Pre-roll auto-win override. Each entry's `amount` (0..1) sums into
    -- a per-hand auto-win probability filtered by gtype. sampleOutcome
    -- rolls once before the natural WC roll; success forces won=true.
    -- Top-of-pipeline — bypasses fill_window / distribution shifts.
    -- Used by KO Pro to flat-bump KO cash rate at every tier.
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
        value_shape = "{ from = 'small'|'medium'|'large', to = 'medium'|'large'|'stack', chance = 0..1, gtype? }",
        affects     = "ctx.win_tier_shifts (ordered list)",
    },

    loss_tier_shift = {
        description = "Push a post-sample loss-tier downgrade descriptor onto ctx.loss_tier_shifts.",
        value_shape = "{ from = 'medium'|'large'|'stack', to = 'small'|'medium'|'large', chance = 0..1, gtype? }",
        affects     = "ctx.loss_tier_shifts (ordered list)",
    },

    -- Multiplies stack-tier WIN magnitudes (Branded Hat). Magnitude-only;
    -- doesn't reshape the dist. Pairs with earnings_mult — earnings_mult
    -- scales every win, stack_mult scales only stacks.
    stack_mult = {
        description = "Multiplies the magnitude of stack-tier wins.",
        value_shape = "number, e.g. 1.20 for +20% stack payouts",
        affects     = "ctx.stack_mult (multiplicative)",
    },
    hu_stack_odds_per_hu_table = {
        description = "The Mirror: each Heads-Up table open adds this to the stack share of every Heads-Up table's win dist (buildOutcome x ctx.hu_table_count).",
        value_shape = "fraction per table, e.g. 0.02",
        affects     = "ctx.stack_odds_per_hu_table",
    },
    bounty_double_chance = {
        description = "A bounty rolls this to pay x2 (max of owners; GrindController:bountyAward).",
        value_shape = "0..1, a printable fraction (1/4)",
        affects     = "ctx.bounty_double_chance",
    },
    tilted_loss_dist_shift = {
        description = "Desk Plant: a tilt's forced hands at `gtype` sample a loss dist with this shape added (Table:deal); 'smaller losses' with no number.",
        value_shape = "shift = { small, medium, large, stack } deltas, gtype = id",
        affects     = "ctx.tilted_loss_dist_shifts (list)",
    },
    tank_absorb_bumps = {
        description = "Flag perk — Space Heater: a table a 6-Max took a tilt for (taunt / intercept routers) gets its next win one size up.",
        value_shape = "no field (presence sets ctx.tank_absorb_bumps = true)",
        affects     = "ctx.tank_absorb_bumps",
    },
    odds_per_heater = {
        description = "Desk Speakers: every heater burning on the board adds this to every table's win chance (buildOutcome x ctx.heater_count).",
        value_shape = "fraction per heater, e.g. 0.01",
        affects     = "ctx.odds_per_heater",
    },
    punch_extra_hands = {
        description = "Gas Stove: a punch status of `status` buys itself this many more forced hands before it expires (Table:_finalizeHand).",
        value_shape = "status = \"heater\" | \"tilt\", value = integer",
        affects     = "ctx.punch_extra_hands[status]",
    },
    heat_shrugs_tilt = {
        description = "Flag perk — Cast Iron Pan: a tilt landing on a table on a heater is announced and counted but never applied; the heater keeps its hand.",
        value_shape = "no field (presence sets ctx.heat_shrugs_tilt = true)",
        affects     = "ctx.heat_shrugs_tilt",
    },
    stack_loss_rerolls = {
        description = "Standard: a stack loss is rerolled this many times and the smallest loss kept (OutcomeMath.sampleOutcome). One per deck level.",
        value_shape = "integer, e.g. 1",
        affects     = "ctx.stack_loss_rerolls",
        scale       = "integer",
    },
    stack_loss_reroll_wins = {
        description = "Flag perk — Standard's capstone: each reroll first rolls the win chance, and a win beats any loss.",
        value_shape = "no field (presence sets ctx.stack_loss_reroll_wins = true)",
        affects     = "ctx.stack_loss_reroll_wins",
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

    -- Flat chips granted on every stack-tier WIN (Pen). Independent of the
    -- per-(stake, gtype) bounty system — fires every time, not just first.
    stack_chip_add = {
        description = "Flat chips added to chips_this_run on every stack-tier win.",
        value_shape = "integer, e.g. 1 for +1 chip per stack",
        affects     = "ctx.stack_chip_add",
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
    -- The swarm's weather (2026-09-07). Two cursors CLASH whenever they
    -- touch; nothing stops it. The clash rolls Balance.CURSOR_CLASH.chance
    -- to punch the table under it. services/CursorPool reports, the
    -- controller applies (GrindController:onCursorClash / onLitCursorDeal).
    cursor_clash_status = {
        description = "What a clash leaves on the table under it: \"tilt\" is the default, the Cleaning Robot says \"heater\".",
        value_shape = "status = \"heater\" | \"tilt\"",
        affects     = "ctx.cursor_clash_status",
    },
    cursor_clash_chance = {
        description = "How often a clash lands (max of owners; 1 = every clash, the robot's corrupt line). Absent = Balance.CURSOR_CLASH.chance.",
        value_shape = "0..1",
        affects     = "ctx.cursor_clash_chance",
    },
    cursor_ignite_chance = {
        description = "A cursor entering a panel with a heater on it rolls this to catch fire; its next DEAL lights that table (the Desk Lamp).",
        value_shape = "0..1, a printable fraction (1/4)",
        affects     = "ctx.cursor_ignite_chance",
    },
    cursor_fire_persists = {
        description = "Flag perk — a lit cursor stays lit after the deal that spends its fire (the lamp's corrupt line).",
        value_shape = "no field (presence sets ctx.cursor_fire_persists = true)",
        affects     = "ctx.cursor_fire_persists",
    },
    cursor_fire_spreads = {
        description = "Flag perk — a lit cursor lights the cursor it clashes with (the Glass Partition).",
        value_shape = "no field (presence sets ctx.cursor_fire_spreads = true)",
        affects     = "ctx.cursor_fire_spreads",
    },
    cursor_clash_deals = {
        description = "Flag perk — a clash deals the idle table under it, before the clash's punch rolls (the Old Keyboard).",
        value_shape = "no field (presence sets ctx.cursor_clash_deals = true)",
        affects     = "ctx.cursor_clash_deals",
    },

    -- ── Focus / efficiency mechanic ─────────────────────────────────────
    focus_capacity_add = {
        description = "Raises focus capacity (tables you can run before the focus penalty kicks in).",
        value_shape = "integer, e.g. 1 for +1 capacity",
        affects     = "ctx.focus_capacity",
        scale       = "integer",   -- run_upgrade_strength_mult leaves it alone
    },
    focus_level_worth = {
        description = "The Swarm deck: each level of the Focus UPGRADE is worth this many MORE tables (GrindController:currentFocusCapacity adds level x worth).",
        value_shape = "integer per deck level, e.g. 1",
        affects     = "ctx.focus_level_worth",
        scale       = "integer",
    },
    focus_penalty_reduce_mult = {
        description = "Multiplies the focus penalty per extra table (lower = softer curve).",
        value_shape = "number <1, e.g. 0.85 for 15% softer penalty",
        affects     = "ctx.focus_penalty_reduce_mult",
    },

    -- ── Tournament payouts ──────────────────────────────────────────────
    -- Integer-level boost into data/ko_payouts.lua. Max-stacks (the
    -- higher-tier perk wins outright; doesn't compound on the lower one).
    ko_payout_boost = {
        description = "Bumps KO cash-tier multipliers (max-stacking, not multiplicative).",
        value_shape = "integer 1 or 2 — selects the tier in data/ko_payouts.lua",
        affects     = "ctx.ko_payout_boost",
    },

    -- ── Deck capability kinds ───────────────────────────────────────────
    -- Generic capabilities composed by decks in data/decks.lua (numbers
    -- live there). None names a deck. Tier floors/ceilings clamp the
    -- sampled tier in outcome_math.sampleOutcome (1-based ranks; max for
    -- floors, min for ceilings). The rest set ctx fields their consumer
    -- reads with `if ctx.<field>` — same flag pattern as cursor_unlocked.

    win_tier_floor = {
        description = "Wins can't roll below this tier (Standard capstone: medium).",
        value_shape = "{ tier = 'small'|'medium'|'large'|'stack' }",
        affects     = "ctx.win_tier_floor (rank, max-combined)",
    },
    loss_tier_ceiling = {
        description = "Losses can't roll above this tier (Nit capstone: large — bans stack 'stack' losses).",
        value_shape = "{ tier = 'small'|'medium'|'large'|'stack' }",
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
        description = "Raises every stake's ceiling on the fill upgrades (Sharper Reads, Pot Control) by N levels (Bookshelf): the level after a stake's window, which the next stake's window already sells, counts for this stake too. Only owned levels count; nothing is free and nothing extra is sold. Consumed in outcome_math.fillRatio (the ceiling) and GrindView's filled check.",
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
        description = "Flag — voids the first stack-tier (stack) loss each run (The Fridge).",
        value_shape = "no field (presence sets ctx.void_first_stack_loss = true)",
        affects     = "ctx.void_first_stack_loss",
    },
    copy_first_denied = {
        description = "Flag — the first denied {chip} bounty each run banks anyway. Granted by no item since the Receipt Printer became the cascade; the denied-bounty branch still reads it.",
        value_shape = "no field (presence sets ctx.copy_first_denied = true)",
        affects     = "ctx.copy_first_denied",
    },
    proc = {
        description = "Grants a proc — 'when X happens, do Y to Z'. The named descriptor lives in data/procs.lua; services/ProcRegistry dispatches it. The applicator only collects the id, because an applicator can only write to ctx and a proc has to reach other tables.",
        value_shape = "proc = \"<id in data/procs.lua>\"",
        affects     = "ctx.procs (list of proc ids)",
    },
    router = {
        description = "Grants a router — 'something is about to land on that table; send it elsewhere, or change what it is'. The named descriptor lives in data/routers.lua and is consulted on every delivery while the item is owned. The applicator only collects the id, for the same reason a proc's does.",
        value_shape = "router = \"<id in data/routers.lua>\"",
        affects     = "ctx.routers (list of router ids)",
    },
    first_bounty_bonus = {
        description = "The first {chip} bounty each run pays +value extra (Dogs Playing Poker).",
        value_shape = "integer, e.g. 1 for +1 {chip} on the run's first bounty",
        affects     = "ctx.first_bounty_bonus (additive)",
    },

    -- ── Catalog appliances ──────────────────────────────────────────────
    -- All three are consumed in the controller / model layer, never in
    -- the outcome roll.

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

    start_biggest_pot = {
        description = "Next run starts with last run's biggest pot: scope \"t1\" (the first stake's) or \"any\" (any stake's). Cereal Shelf. Read by GameState:applyStartingPerks.",
        value_shape = "{ scope = \"t1\" | \"any\" }",
        affects     = "ctx.start_biggest_pot",
    },

    -- ── Deck kinds (2026-09 roster, models/UpgradePricing-era) ────────────
    -- hand_pace_mult also accepts `gtype`: scoped pace lands in
    -- ctx.hand_pace_mult_by_gtype[gtype] and Table:update multiplies it in
    -- for that table's type only (Firehose).
    win_tier_bump_chance = {
        description = "Per-resolve chance to bump a WIN's tier one step. Wins only — the two-sided tier_bump_chance stays for items (Toaster). Maniac capstone.",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.win_tier_bump_chance (max)",
    },
    win_payout_double_chance = {
        description = "Per-resolve chance to double a WIN's payout. Wins only. Maniac capstone.",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.win_payout_double_chance (max)",
    },
    pure_board_bonus = {
        description = "While every open table is one game type (ctx.board_pure_gtype, a controller transient), multiplies winning $ deltas. Specialist.",
        value_shape = "{ earnings_mult = number }",
        affects     = "ctx.earnings_mult (multiplicative, conditional)",
    },
    pure_board_pace = {
        description = "While the board is pure, multiplies hand pace. Specialist capstone.",
        value_shape = "{ value = number }",
        affects     = "ctx.hand_pace_mult (multiplicative, conditional)",
    },
    tilted_loss_mult = {
        description = "A tilt's forced hands on a table of this game type lose this much less (both the landing hand and the forced next hand). Anchor.",
        value_shape = "{ value = number <1, gtype = <gtype_id>? }",
        affects     = "ctx.tilted_loss_mults (list; OutcomeMath.tiltedLossMult)",
    },
    heater_win_mult = {
        description = "The heater's forced hand pays this much more. Hot Hand.",
        value_shape = "{ value = number >1 }",
        affects     = "ctx.heater_win_mult (multiplicative)",
    },
    ko_targets_add = {
        description = "A knockout's proc lands on this many extra tables: selectors with pick_n_field = \"ko_targets_add\" sample 1 + this. Circuit Pro.",
        value_shape = "{ value = integer }",
        affects     = "ctx.ko_targets_add (additive)",
    },
    unbanked_stack_shift = {
        description = "Stack share up (Small down) on wins at lanes whose {chip} bounty is unbanked this run (ctx.unbanked, a controller transient). Bounty Hunter.",
        value_shape = "{ value = 0..1 }",
        affects     = "ctx.unbanked_stack_shift (additive)",
    },
    six_max_unlocked = {
        description = "Flag perk — the Bonsai: opens the 6-Max game type (the controller latches it into state.six_max_unlocked; Constants.GTYPE_GATE).",
        value_shape = "no field (presence sets ctx.six_max_unlocked = true)",
        affects     = "ctx.six_max_unlocked",
    },
    bounty_gtype_mult = {
        description = "Per-game-type bounty multiplier (Fight Night: Heads-Up bounties pay double). GrindController:bountyAward multiplies by the entry for the table's game type.",
        value_shape = "{ value = number, gtype = id }",
        affects     = "ctx.bounty_gtype_mult[gtype] (multiplicative)",
    },

}

return Effects
