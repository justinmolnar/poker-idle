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
-- THE RULE: there is no `if kind == "..." then ... elseif kind == "..."`
-- chain ANYWHERE in the codebase. If you find yourself writing one, you're
-- doing it wrong. Register a function instead.
--
-- ── Registering ──────────────────────────────────────────────────────────
--
-- The registry mechanism is engine-agnostic — it lives here in services/.
-- Poker-specific kind registrations live in `models/poker_effects.lua` and
-- are wired in `main.lua` via `PokerEffects.registerAll(reg)`. Two-touch:
-- one entry in data/effects.lua (documentation) + one .register() call in
-- models/poker_effects.lua.

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

return EffectsRegistry
