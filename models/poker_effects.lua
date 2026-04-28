-- models/poker_effects.lua
--
-- Poker-specific effect kind registrations. Lives in models/ (not services/)
-- because the kind names (`shove_rate_add`, `vs_aggressive_mult`, etc.) are
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

    reg:register("vs_aggressive_mult", function(e, ctx)
        ctx.vs_aggressive = (ctx.vs_aggressive or 1) * e.value
    end)

    reg:register("rep_decay_slow", function(e, ctx)
        ctx.rep_decay = (ctx.rep_decay or 1) * e.value
    end)

    -- Additive integer slots beyond the base of 1. Catalog item Second
    -- Monitor adds +1; subsequent +slot items can stack up to MAX_TABLES.
    reg:register("table_slots_add", function(e, ctx)
        ctx.table_slots = (ctx.table_slots or 0) + e.value
    end)
end

return PokerEffects
