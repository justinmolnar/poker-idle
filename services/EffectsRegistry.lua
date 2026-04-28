-- services/EffectsRegistry.lua
--
-- The registry that turns effect-kind strings into application functions.
--
-- This is the load-bearing piece of the data-driven architecture. Catalog
-- items, run upgrades, and anything else that grants stat bonuses emits
-- entries shaped:
--   { kind = "<kind_string>", value = <number> }
--
-- Game code that wants to roll up "what does the player's collection give
-- me right now?" calls EffectsRegistry:applyAll(item, ctx) — the registry
-- looks up the applicator function for each effect's kind and lets it
-- mutate ctx.
--
-- THE RULE: there is no `if kind == "shove_rate_add" then ... elseif ...`
-- chain ANYWHERE in the codebase. If you find yourself writing one, you're
-- doing it wrong. Register a function instead.
--
-- ── Registering ──────────────────────────────────────────────────────────
--
-- The skeleton bootstrap calls `EffectsRegistry.registerDefaults(reg)` which
-- wires up every kind listed in data/effects.lua. Adding a new effect = one
-- entry in data/effects.lua + one .register() call here. Two-touch.

local EffectsRegistry = {}
EffectsRegistry.__index = EffectsRegistry

function EffectsRegistry:new()
    return setmetatable({ fns = {} }, EffectsRegistry)
end

-- Register an applicator. `applicator(effect_entry, ctx)` mutates ctx.
function EffectsRegistry:register(kind, applicator)
    self.fns[kind] = applicator
end

-- Apply a single effect to ctx.
function EffectsRegistry:apply(effect, ctx)
    local fn = self.fns[effect.kind]
    if not fn then
        error("EffectsRegistry: no applicator for kind '" .. tostring(effect.kind) .. "'")
    end
    fn(effect, ctx)
end

-- Apply every effect on an item (catalog item, run upgrade, etc.).
function EffectsRegistry:applyAll(item, ctx)
    if not item or not item.effects then return end
    for _, e in ipairs(item.effects) do
        self:apply(e, ctx)
    end
end

-- Returns true if an applicator is registered for this kind.
function EffectsRegistry:has(kind)
    return self.fns[kind] ~= nil
end

-- ── Default applicators ──────────────────────────────────────────────────
-- One function per kind. Each reads `effect.value` and mutates ctx.
-- Adding a new kind:
--   1. Document it in data/effects.lua.
--   2. Add a .register() line below.

function EffectsRegistry.registerDefaults(reg)
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
end

return EffectsRegistry
