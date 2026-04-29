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
    reg:register("win_chance_fill", function(e, ctx)
        ctx.win_chance_fills = ctx.win_chance_fills or {}
        ctx.win_chance_fills[#ctx.win_chance_fills + 1] = {
            strength = e.strength or 1,
            gtype    = e.gtype,
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

    -- ── Cursor swarm (autonomous DEAL-clickers) ────────────────────────
    -- Flag perk: presence in owned_items sets ctx.cursor_unlocked = true.
    reg:register("cursor_unlocked", function(_e, ctx)
        ctx.cursor_unlocked = true
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
end

return PokerEffects
