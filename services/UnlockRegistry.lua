-- services/UnlockRegistry.lua
--
-- Same-shape registry as services/EffectsRegistry and services/XpRuleRegistry,
-- but for *unlock conditions* — kind-keyed predicates that decide whether
-- a gated piece of content (deck spec, future achievement, etc.) is
-- currently unlocked given the player's persistent state.
--
-- Engine-agnostic: knows nothing about poker. Game-specific kinds register
-- from a model layer (see models/deck_unlock_rules.lua) the same way
-- models/poker_effects registers EffectsRegistry kinds.
--
-- Dispatch contract:
--   reg:register("kind_name", function(condition, state) return bool end)
--   reg:check(condition, state) -> bool
-- where `condition` is the spec's `unlock` table (carries a `kind` and
-- the threshold / parameter knobs the applicator reads), `state` is the
-- player's GameState instance.
--
-- THE RULE: there is no `if condition.kind == "..." then ... elseif ...`
-- chain ANYWHERE. Register a function instead.

local UnlockRegistry = {}
UnlockRegistry.__index = UnlockRegistry

function UnlockRegistry:new()
    return setmetatable({ fns = {} }, UnlockRegistry)
end

function UnlockRegistry:register(kind, applicator)
    self.fns[kind] = applicator
end

function UnlockRegistry:check(condition, state)
    if not condition or not condition.kind then return false end
    local fn = self.fns[condition.kind]
    if not fn then
        error("UnlockRegistry: no applicator for kind '" .. tostring(condition.kind) .. "'")
    end
    return fn(condition, state) and true or false
end

function UnlockRegistry:has(kind)
    return self.fns[kind] ~= nil
end

return UnlockRegistry
