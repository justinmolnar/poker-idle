-- models/poker_effects.lua
--
-- Poker-specific effect kind registrations. Lives in models/ (not services/)
-- because the kind names (`shove_rate_add`, `win_chance_fill`, etc.) are
-- poker-specific data — services/EffectsRegistry stays generic, just owning
-- the registry mechanism.
--
-- Adding a new effect kind:
--   1. Add an entry to data/effects.lua (documentation).
--   2. Register here with a single :register() call. The applicator reads
--      effect.value (or other fields) and mutates ctx.
--   3. Use the kind in data/catalog.lua, data/run_upgrades.lua, or any
--      effect-emitting source.
--
-- THERE IS NO if/elseif chain on `kind` strings ANYWHERE. If you find
-- yourself writing one, you're doing it wrong — register a function instead.

local OutcomeMath = require("models.outcome_math")

local PokerEffects = {}

function PokerEffects.registerAll(reg)
    reg:register("shove_rate_add", function(e, ctx)
        ctx.shove_rate = (ctx.shove_rate or 0) + e.value
    end)

    -- Magnitude scaling on the win column (Pot Odds Master). Magnitude-only
    -- — does not reshape win_dist.
    reg:register("earnings_mult", function(e, ctx)
        ctx.earnings_mult = (ctx.earnings_mult or 1) * e.value
    end)

    -- Magnitude scaling on the lose column (Damage Control, Headphones).
    -- Magnitude-only — does not reshape loss_dist.
    reg:register("loss_mult", function(e, ctx)
        ctx.loss_mult = (ctx.loss_mult or 1) * e.value
    end)

    reg:register("hands_per_min_add", function(e, ctx)
        ctx.hands_per_min = (ctx.hands_per_min or 0) + e.value
    end)

    -- Multiplicative pace boost composed into effective_dt at the table
    -- level (Energy Drink). Stacks with gtype.pace_mult.
    reg:register("hand_pace_mult", function(e, ctx)
        ctx.hand_pace_mult = (ctx.hand_pace_mult or 1) * (e.value or 1)
    end)

    reg:register("rep_decay_slow", function(e, ctx)
        ctx.rep_decay = (ctx.rep_decay or 1) * e.value
    end)

    -- ── Outcome-model effects ───────────────────────────────────────────
    -- Three "fill" kinds (run upgrades) and one "shift" kind (catalog).
    -- Each fill applicator pushes one descriptor per application. With
    -- EffectsRegistry:applyN, an N-level upgrade pushes N descriptors —
    -- buildOutcome sums their strengths into "fill units" then lerps
    -- naked → run-capped via the stake's fill_window.

    -- WC fill: each level adds `strength` units toward closing the WC gap.
    -- Optional tier_min / tier_max (1-based stake index) scope the fill to
    -- certain stakes only — High Roller fills WC at T4+ exclusively.
    reg:register("win_chance_fill", function(e, ctx)
        ctx.win_chance_fills = ctx.win_chance_fills or {}
        ctx.win_chance_fills[#ctx.win_chance_fills + 1] = {
            strength = e.strength or 1,
            gtype    = e.gtype,
            tier_min = e.tier_min,
            tier_max = e.tier_max,
        }
    end)

    -- win_dist fill: closes the gap from naked to win_dist_capped.
    reg:register("win_dist_fill", function(e, ctx)
        ctx.win_dist_fills = ctx.win_dist_fills or {}
        ctx.win_dist_fills[#ctx.win_dist_fills + 1] = {
            strength = e.strength or 1,
            gtype    = e.gtype,
        }
    end)

    -- loss_dist fill: closes the gap from naked to loss_dist_capped.
    reg:register("loss_dist_fill", function(e, ctx)
        ctx.loss_dist_fills = ctx.loss_dist_fills or {}
        ctx.loss_dist_fills[#ctx.loss_dist_fills + 1] = {
            strength = e.strength or 1,
            gtype    = e.gtype,
        }
    end)

    -- Catalog flat additive on WC. Applied AFTER the lerp in buildOutcome
    -- — the only mechanism for pushing WC beyond run-capped.
    reg:register("win_chance_shift", function(e, ctx)
        ctx.win_chance_shifts = ctx.win_chance_shifts or {}
        ctx.win_chance_shifts[#ctx.win_chance_shifts + 1] = {
            amount = e.amount or e.value or 0,
            gtype  = e.gtype,
        }
    end)

    -- Final-WC multiplier. Applied AFTER all additive shifts in buildOutcome.
    -- Used by the no-poster handicap (×0.4 knocks T1 50% → 20%) and any
    -- future multiplicative WC modifier.
    reg:register("wc_mult", function(e, ctx)
        ctx.wc_mult = (ctx.wc_mult or 1) * (e.value or 1)
    end)

    -- Catalog additive shape on loss_dist (mirror of win_chance_shift's
    -- distributional cousin). Each entry pushes a delta-table; buildOutcome
    -- sums them on top of the gtype dist shape and renormalizes.
    reg:register("loss_dist_shift", function(e, ctx)
        ctx.loss_dist_shifts = ctx.loss_dist_shifts or {}
        ctx.loss_dist_shifts[#ctx.loss_dist_shifts + 1] = {
            shift = e.shift or {},
            gtype = e.gtype,
        }
    end)

    -- Win-side mirror of loss_dist_shift — additive shape on the win
    -- distribution. Optional `tier_min` / `tier_max` bounds (1-based stake
    -- index) let scope-targeted decks reshape the win-tier dist only at
    -- certain stakes (e.g. Low Stakes Hero shifts win_dist toward jackpot
    -- but only at T1-T3). Renormalized by buildOutcome at the end of the
    -- dist pipeline.
    reg:register("win_dist_shift", function(e, ctx)
        ctx.win_dist_shifts = ctx.win_dist_shifts or {}
        ctx.win_dist_shifts[#ctx.win_dist_shifts + 1] = {
            shift    = e.shift or {},
            gtype    = e.gtype,
            tier_min = e.tier_min,
            tier_max = e.tier_max,
        }
    end)

    -- Flat additive chance to auto-win a hand BEFORE the WC roll fires.
    -- Each entry contributes its `amount` (0..1) to the per-hand auto-win
    -- probability; sampleOutcome rolls once against the summed total per
    -- gtype filter. Doesn't reshape distributions or fills — it's a
    -- top-of-pipeline override that turns "would have lost" hands into
    -- forced wins at the configured rate. Used by MTT Pro to cash MTT
    -- hands more often without depending on per-stake fill_window math.
    reg:register("auto_win_chance", function(e, ctx)
        ctx.auto_win_chances = ctx.auto_win_chances or {}
        ctx.auto_win_chances[#ctx.auto_win_chances + 1] = {
            amount = e.amount or e.value or 0,
            gtype  = e.gtype,
        }
    end)

    -- Post-sample win-tier upgrade (Self-Help Book, Lava Lamp). Each entry
    -- describes a (from → to) re-roll with a chance. Table.lua fires after
    -- sampleOutcome, before magnitude roll.
    reg:register("win_tier_shift", function(e, ctx)
        ctx.win_tier_shifts = ctx.win_tier_shifts or {}
        ctx.win_tier_shifts[#ctx.win_tier_shifts + 1] = {
            from   = e.from,
            to     = e.to,
            chance = e.chance or 0,
            gtype  = e.gtype,
        }
    end)

    -- Post-sample loss-tier downgrade (Stress Ball, Worry Stone). Same
    -- mechanism on the loss path — reduces damage by bumping the tier
    -- DOWN one step.
    reg:register("loss_tier_shift", function(e, ctx)
        ctx.loss_tier_shifts = ctx.loss_tier_shifts or {}
        ctx.loss_tier_shifts[#ctx.loss_tier_shifts + 1] = {
            from   = e.from,
            to     = e.to,
            chance = e.chance or 0,
            gtype  = e.gtype,
        }
    end)

    -- Jackpot-only payout multiplier (Branded Hat). Stacks with
    -- earnings_mult — that scales every win; this scales only jackpots.
    reg:register("jackpot_mult", function(e, ctx)
        ctx.jackpot_mult = (ctx.jackpot_mult or 1) * (e.value or 1)
    end)

    -- Percentage bonus on starting bankroll seed (Lucky Coin). Sits next
    -- to start_bankroll_add (flat $); both feed applyStartingPerks.
    reg:register("start_bankroll_pct", function(e, ctx)
        ctx.start_bankroll_pct = (ctx.start_bankroll_pct or 0) + (e.value or 0)
    end)

    -- ── Meta-progression perks ──────────────────────────────────────────
    reg:register("start_bankroll_add", function(e, ctx)
        ctx.start_bankroll_add = (ctx.start_bankroll_add or 0) + e.value
    end)
    reg:register("start_table_count", function(e, ctx)
        ctx.start_table_count = (ctx.start_table_count or 0) + e.value
    end)
    -- Buy-in cost multiplier. Unbounded entries fold into the scalar
    -- ctx.buy_in_mult (applies at every stake). Tier-bounded entries
    -- (tier_min / tier_max, 1-based stake index) go on a descriptor list
    -- so the buy site can apply them only at matching stakes — High
    -- Roller halves buy-ins at T4+ only. See GrindController.buyInMultFor.
    reg:register("buy_in_mult", function(e, ctx)
        if e.tier_min or e.tier_max then
            ctx.buy_in_mult_tiered = ctx.buy_in_mult_tiered or {}
            ctx.buy_in_mult_tiered[#ctx.buy_in_mult_tiered + 1] = {
                value    = e.value or 1,
                tier_min = e.tier_min,
                tier_max = e.tier_max,
            }
        else
            ctx.buy_in_mult = (ctx.buy_in_mult or 1) * (e.value or 1)
        end
    end)
    reg:register("run_upgrade_cost_mult", function(e, ctx)
        ctx.run_upgrade_cost_mult = (ctx.run_upgrade_cost_mult or 1) * e.value
    end)
    reg:register("chip_award_mult", function(e, ctx)
        ctx.chip_award_mult = (ctx.chip_award_mult or 1) * e.value
    end)
    reg:register("jackpot_chip_add", function(e, ctx)
        ctx.jackpot_chip_add = (ctx.jackpot_chip_add or 0) + (e.value or 0)
    end)

    -- ── Cursor swarm (autonomous DEAL-clickers) ────────────────────────
    -- Flag perk: presence in owned_items sets ctx.cursor_unlocked = true.
    reg:register("cursor_unlocked", function(_e, ctx)
        ctx.cursor_unlocked = true
    end)
    -- Flag perk that promotes cursors to also click REBUY hit_boxes.
    -- Default off — opt-in upgrade. Per-table opt-out via the [R]
    -- header toggle (see views/TablePanel + models/Table.cursor_rebuy_muted).
    reg:register("cursor_rebuy_unlocked", function(_e, ctx)
        ctx.cursor_rebuy_unlocked = true
    end)
    reg:register("cursor_count_add", function(e, ctx)
        ctx.cursor_count = (ctx.cursor_count or 0) + (e.value or 0)
    end)
    reg:register("cursor_speed_mult", function(e, ctx)
        ctx.cursor_speed_mult = (ctx.cursor_speed_mult or 1) * (e.value or 1)
    end)

    -- ── Focus mechanic ──────────────────────────────────────────────────
    reg:register("focus_capacity_add", function(e, ctx)
        ctx.focus_capacity = (ctx.focus_capacity or 0) + e.value
    end)
    reg:register("focus_penalty_reduce_mult", function(e, ctx)
        ctx.focus_penalty_reduce_mult = (ctx.focus_penalty_reduce_mult or 1) * e.value
    end)

    -- ── Tournament payout boost ─────────────────────────────────────────
    -- Integer level; max-stacks rather than compounding so a perk pair
    -- (Plastic Trophy lvl=1, Engraved Plaque lvl=2) selects the highest
    -- tier in data/mtt_payouts.lua, not their sum.
    reg:register("mtt_payout_boost", function(e, ctx)
        ctx.mtt_payout_boost = math.max(ctx.mtt_payout_boost or 0, e.value or 0)
    end)

    -- ── Deck effect kinds (generic capabilities) ───────────────────────
    -- These are CAPABILITY kinds — none names a deck. Decks compose them
    -- from data/decks.lua (numbers live there, not here). Tier floors/
    -- ceilings clamp the sampled tier in outcome_math.sampleOutcome
    -- (stored as ranks, combined by max/min); the rest set ctx fields
    -- their consumer sites read with `if ctx.<field>` — the same flag
    -- pattern as cursor_unlocked.

    -- Wins can't roll below this tier (Standard capstone: medium).
    reg:register("win_tier_floor", function(e, ctx)
        local idx = OutcomeMath.TIER_INDEX[e.tier]
        if idx then ctx.win_tier_floor = math.max(ctx.win_tier_floor or 0, idx) end
    end)
    -- Losses can't roll ABOVE this tier (Nit capstone: large — bans the
    -- jackpot "stack" loss entirely).
    reg:register("loss_tier_ceiling", function(e, ctx)
        local idx = OutcomeMath.TIER_INDEX[e.tier]
        if idx then ctx.loss_tier_ceiling = math.min(ctx.loss_tier_ceiling or math.huge, idx) end
    end)

    -- Per-resolve chance to bump the sampled tier one step (win or loss).
    -- Consumed via a NEXT_TIER lookup in models/Table.lua (Maniac capstone).
    reg:register("tier_bump_chance", function(e, ctx)
        ctx.tier_bump_chance = math.max(ctx.tier_bump_chance or 0, e.value or 0)
    end)
    -- Per-resolve chance to double the payout magnitude (Maniac capstone).
    reg:register("payout_double_chance", function(e, ctx)
        ctx.payout_double_chance = math.max(ctx.payout_double_chance or 0, e.value or 0)
    end)

    -- Additive rebuy-cost discount fraction (Short Stack). Consumed in
    -- GrindController:rebuyTable as cost = buy_in * (1 - discount).
    reg:register("rebuy_discount", function(e, ctx)
        ctx.rebuy_discount = (ctx.rebuy_discount or 0) + (e.value or 0)
    end)
    -- Chance for a rebuy to be free (Short Stack capstone).
    reg:register("free_rebuy_chance", function(e, ctx)
        ctx.free_rebuy_chance = math.max(ctx.free_rebuy_chance or 0, e.value or 0)
    end)

    -- Additive earnings bonus per stake tier index (The Bank). Consumed in
    -- models/Table.lua as earnings_mult *= (1 + value * tier_idx).
    reg:register("earnings_per_tier", function(e, ctx)
        ctx.earnings_per_tier = (ctx.earnings_per_tier or 0) + (e.value or 0)
    end)
    -- Scale every hand's magnitude by a bankroll-log multiplier (The Bank
    -- capstone). Magnitude-only flag; applied at resolve time in
    -- GrindController where live bankroll is available.
    reg:register("earnings_scale_by_bankroll", function(_e, ctx)
        ctx.earnings_scale_by_bankroll = true
    end)

    -- Removes the multi-table focus penalty (Multitasker capstone).
    reg:register("focus_penalty_immune", function(_e, ctx)
        ctx.focus_penalty_immune = true
    end)

    -- Multiplies the strength of every run-upgrade effect (Investor).
    -- Additive accumulation from 1.0; consumed in GameState:computeEffects.
    reg:register("run_upgrade_strength_mult", function(e, ctx)
        ctx.run_upgrade_strength_mult = (ctx.run_upgrade_strength_mult or 1.0) + (e.value or 0)
    end)
    -- Adds extra purchasable levels to run upgrades (Investor capstone).
    reg:register("run_upgrade_bonus_levels", function(e, ctx)
        ctx.run_upgrade_bonus_levels = (ctx.run_upgrade_bonus_levels or 0) + (e.value or 0)
    end)

    -- Widens every stake's fill_window (Tier Manipulator). Consumed in
    -- outcome_math.fillRatio.
    reg:register("fill_window_widen", function(e, ctx)
        ctx.fill_window_widen = (ctx.fill_window_widen or 0) + (e.value or 1)
    end)
    -- Ignores tier bounds and completes fills regardless of stake (Tier
    -- Manipulator capstone). Consumed in outcome_math sumFills + fillRatio.
    reg:register("fill_cascade", function(_e, ctx)
        ctx.fill_cascade = true
    end)

    -- Single-table bonus (Specialist): magnitudes and win-chance shift that
    -- only apply while exactly one table is open. active_tables_count is a
    -- transient param seeded into ctx by GrindController:invalidateEffects.
    reg:register("solo_table_bonus", function(e, ctx)
        if ctx.active_tables_count == 1 then
            ctx.earnings_mult = (ctx.earnings_mult or 1) * (e.earnings_mult or 1)
            if e.wc_bonus then
                ctx.win_chance_shifts = ctx.win_chance_shifts or {}
                ctx.win_chance_shifts[#ctx.win_chance_shifts + 1] = { amount = e.wc_bonus }
            end
        end
    end)
    -- Single-table pace boost (Specialist capstone).
    reg:register("solo_table_pace", function(e, ctx)
        if ctx.active_tables_count == 1 then
            ctx.hand_pace_mult = (ctx.hand_pace_mult or 1) * (e.value or 1)
        end
    end)

    -- Cursor swarm: zero the per-click delay (Swarm capstone). Companion to
    -- the generic cursor_speed_mult, which the same capstone also uses.
    reg:register("cursor_instant_click", function(_e, ctx)
        ctx.cursor_zero_click_delay = true
    end)

    -- Shove base restored per total deck level (master deck). Reads the
    -- ctx.total_deck_levels transient seeded in GameState:computeEffects.
    -- MAX-idempotent: Decks.applyEffects runs numeric effects min(level,4)
    -- times via applyN, so `max` keeps re-application from multiplying by
    -- the master deck's own level — the level scaling comes through
    -- total_deck_levels (which includes it), not through the repetition.
    reg:register("shove_base_per_deck_level", function(e, ctx)
        ctx.shove_base = math.max(ctx.shove_base or 0,
                                  (e.value or 0) * (ctx.total_deck_levels or 0))
    end)
    -- Doubles the restored shove base (master deck capstone).
    reg:register("shove_base_double", function(_e, ctx)
        ctx.shove_base_double = true
    end)

    -- ── Catalog once-per-run item flags ─────────────────────────────────
    -- Each is a flag/value consumed at an event the resolution loop already
    -- fires; the "first per run" gating lives in run-scoped state flags.
    -- Rubber Duck: void the first losing hand each run.
    reg:register("void_first_loss", function(_e, ctx)
        ctx.void_first_loss = true
    end)
    -- The Fridge: void the first jackpot-tier (stack) loss each run.
    reg:register("void_first_stack_loss", function(_e, ctx)
        ctx.void_first_stack_loss = true
    end)
    -- Copy Machine: the first denied {chip} bounty each run banks anyway.
    reg:register("copy_first_denied", function(_e, ctx)
        ctx.copy_first_denied = true
    end)
    -- Dogs Playing Poker: the first {chip} bounty each run pays +value.
    reg:register("first_bounty_bonus", function(e, ctx)
        ctx.first_bounty_bonus = (ctx.first_bounty_bonus or 0) + (e.value or 0)
    end)

    -- ── Catalog appliances ──────────────────────────────────────────────
    -- The Sink: a busted table hands part of its buy-in back. Additive,
    -- clamped at 1 so stacking can never mint money on a bust.
    reg:register("bust_refund_pct", function(e, ctx)
        ctx.bust_refund_pct = math.min(1, (ctx.bust_refund_pct or 0) + (e.value or 0))
    end)
    -- Tori Gate: the active deck learns faster. Consumed in Decks.gainXp
    -- via GrindController:_grantDeckXp.
    reg:register("deck_xp_mult", function(e, ctx)
        ctx.deck_xp_mult = (ctx.deck_xp_mult or 1) * (e.value or 1)
    end)
    -- The Dishwasher: a slice of last run's losses comes back as next run's
    -- seed. Consumed in GameState:applyStartingPerks.
    reg:register("loss_recycle_pct", function(e, ctx)
        ctx.loss_recycle_pct = (ctx.loss_recycle_pct or 0) + (e.value or 0)
    end)

    -- Unlocks s010 Ultra stake.
    reg:register("ultra_unlock_effect", function(_e, ctx)
        ctx.ultra_unlocked = true
    end)
end

return PokerEffects
