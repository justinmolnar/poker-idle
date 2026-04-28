-- models/poker_effects.lua
--
-- Poker-specific effect kind registrations. Lives in models/ (not services/)
-- because the kind names (`shove_rate_add`, `vs_fish_mult`, etc.) are
-- poker-specific data — services/EffectsRegistry stays generic, just owning
-- the registry mechanism.
--
-- Adding a new effect kind:
--   1. Add an entry to data/effects.lua (documentation).
--   2. Register here with a single :register() call. The applicator reads
--      effect.value and mutates ctx.
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

    reg:register("earnings_mult", function(e, ctx)
        ctx.earnings_mult = (ctx.earnings_mult or 1) * e.value
    end)

    reg:register("hands_per_min_add", function(e, ctx)
        ctx.hands_per_min = (ctx.hands_per_min or 0) + e.value
    end)

    -- Per-playstyle situational multipliers. Each style targeted independently
    -- by catalog/run-upgrade items. Skill levels are not targetable — they're
    -- a flat additive penalty per opponent (see opponent_types.lua).
    reg:register("vs_fish_mult", function(e, ctx)
        ctx.vs_fish = (ctx.vs_fish or 1) * e.value
    end)
    reg:register("vs_tag_mult", function(e, ctx)
        ctx.vs_tag = (ctx.vs_tag or 1) * e.value
    end)
    reg:register("vs_lag_mult", function(e, ctx)
        ctx.vs_lag = (ctx.vs_lag or 1) * e.value
    end)
    reg:register("vs_nit_mult", function(e, ctx)
        ctx.vs_nit = (ctx.vs_nit or 1) * e.value
    end)

    reg:register("rep_decay_slow", function(e, ctx)
        ctx.rep_decay = (ctx.rep_decay or 1) * e.value
    end)

    -- Focus / efficiency mechanic. focus_capacity_add raises the table
    -- count below which no focus penalty applies (default base is
    -- Constants.GAMEPLAY.FOCUS_BASE_CAPACITY, seeded by GrindController
    -- when it reads ctx). focus_penalty_reduce_mult shrinks the
    -- per-extra-table penalty so capacity-light / penalty-light builds
    -- diverge.
    reg:register("focus_capacity_add", function(e, ctx)
        ctx.focus_capacity = (ctx.focus_capacity or 0) + e.value
    end)
    reg:register("focus_penalty_reduce_mult", function(e, ctx)
        ctx.focus_penalty_reduce_mult = (ctx.focus_penalty_reduce_mult or 1) * e.value
    end)
end

return PokerEffects
