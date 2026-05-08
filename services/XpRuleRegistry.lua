-- services/XpRuleRegistry.lua
--
-- Same-shape registry as services/EffectsRegistry, but for *XP rules* —
-- kind-keyed functions that consume an event descriptor and return an XP
-- delta. Used by deck-style progression where each track's XP source
-- differs (volume, win-magnitude, time, loss-count, etc.).
--
-- Engine-agnostic: knows nothing about poker. Game-specific kinds are
-- registered from a model layer (see models/deck_xp_rules.lua) the same
-- way models/poker_effects registers EffectsRegistry kinds.
--
-- Dispatch contract:
--   reg:register("kind_name", function(rule, event) return delta end)
--   reg:apply(rule, event) -> number
-- where `rule` is the deck spec's xp_rule table (carries a `kind` and
-- optional knobs), `event` is the event descriptor emitted by gameplay
-- code (shape decided by the game side — registry does not interpret).
--
-- THE RULE: there is no `if rule.kind == "..." then ... elseif ...` chain
-- ANYWHERE. Register a function instead.

local XpRuleRegistry = {}
XpRuleRegistry.__index = XpRuleRegistry

function XpRuleRegistry:new()
    return setmetatable({ fns = {} }, XpRuleRegistry)
end

function XpRuleRegistry:register(kind, applicator)
    self.fns[kind] = applicator
end

function XpRuleRegistry:apply(rule, event)
    if not rule or not rule.kind then return 0 end
    local fn = self.fns[rule.kind]
    if not fn then
        error("XpRuleRegistry: no applicator for kind '" .. tostring(rule.kind) .. "'")
    end
    return fn(rule, event) or 0
end

function XpRuleRegistry:has(kind)
    return self.fns[kind] ~= nil
end

return XpRuleRegistry
