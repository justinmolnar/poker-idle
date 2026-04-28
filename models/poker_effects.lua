-- models/poker_effects.lua
--
-- Poker-specific effect kind registrations. Lives in models/ (not services/)
-- because the kind names (`shove_rate_add`, `grid_shift`, etc.) are
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

local PokerEffects = {}

function PokerEffects.registerAll(reg)
    reg:register("shove_rate_add", function(e, ctx)
        ctx.shove_rate = (ctx.shove_rate or 0) + e.value
    end)

    -- Magnitude scaling on the win column (Pot Odds Master, Big Pots
    -- legacy slot — kept as magnitude-only since it scales $ not grid mass).
    reg:register("earnings_mult", function(e, ctx)
        ctx.earnings_mult = (ctx.earnings_mult or 1) * e.value
    end)

    -- Magnitude scaling on the lose column (Damage Control, Headphones).
    reg:register("loss_mult", function(e, ctx)
        ctx.loss_mult = (ctx.loss_mult or 1) * e.value
    end)

    reg:register("hands_per_min_add", function(e, ctx)
        ctx.hands_per_min = (ctx.hands_per_min or 0) + e.value
    end)

    reg:register("rep_decay_slow", function(e, ctx)
        ctx.rep_decay = (ctx.rep_decay or 1) * e.value
    end)

    -- ── Outcome-grid shift ──────────────────────────────────────────────
    -- Pushes a transform descriptor onto ctx.grid_shifts. models/Table.lua's
    -- :_buildGrid walks this list in order, applying each shift before the
    -- final renormalization. The descriptor's `op` field is read by the
    -- single shift-applicator inside _buildGrid (no kind chain — `op` is a
    -- data field, dispatched via a small applicator table).
    --
    -- Effect entry shape:
    --   { kind = "grid_shift", op = "lose_to_win" | "shift_downward",
    --     amount = 0..1,
    --     skill = "<id>"?, style = "<id>"?, gtype = "<id>"? }
    reg:register("grid_shift", function(e, ctx)
        ctx.grid_shifts = ctx.grid_shifts or {}
        ctx.grid_shifts[#ctx.grid_shifts + 1] = {
            op     = e.op,
            amount = e.amount or e.value or 0,
            skill  = e.skill,
            style  = e.style,
            gtype  = e.gtype,
        }
    end)

    -- ── Discovery / opponent-reading ────────────────────────────────────
    reg:register("reveal_chance_add", function(e, ctx)
        ctx.reveal_chance_add = (ctx.reveal_chance_add or 0) + e.value
    end)
    reg:register("revealed_at_start_count", function(e, ctx)
        ctx.revealed_at_start_count = (ctx.revealed_at_start_count or 0) + e.value
    end)

    -- ── Meta-progression perks ──────────────────────────────────────────
    reg:register("start_bankroll_add", function(e, ctx)
        ctx.start_bankroll_add = (ctx.start_bankroll_add or 0) + e.value
    end)
    reg:register("start_table_count", function(e, ctx)
        ctx.start_table_count = (ctx.start_table_count or 0) + e.value
    end)
    reg:register("buy_in_mult", function(e, ctx)
        ctx.buy_in_mult = (ctx.buy_in_mult or 1) * e.value
    end)
    reg:register("run_upgrade_cost_mult", function(e, ctx)
        ctx.run_upgrade_cost_mult = (ctx.run_upgrade_cost_mult or 1) * e.value
    end)
    reg:register("pp_award_mult", function(e, ctx)
        ctx.pp_award_mult = (ctx.pp_award_mult or 1) * e.value
    end)

    -- ── Focus mechanic ──────────────────────────────────────────────────
    reg:register("focus_capacity_add", function(e, ctx)
        ctx.focus_capacity = (ctx.focus_capacity or 0) + e.value
    end)
    reg:register("focus_penalty_reduce_mult", function(e, ctx)
        ctx.focus_penalty_reduce_mult = (ctx.focus_penalty_reduce_mult or 1) * e.value
    end)
end

return PokerEffects
