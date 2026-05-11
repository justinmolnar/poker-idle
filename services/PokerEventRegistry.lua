-- services/PokerEventRegistry.lua
--
-- Same-shape registry as services/EffectsRegistry / XpRuleRegistry /
-- UnlockRegistry. Maps event-kind strings to applicator functions that
-- mutate a state table when the event fires.
--
-- Used by both the script writer (HandScript.lua) and the cinematic
-- playback walker — both consume the same event list and need the same
-- per-kind state mutations (pot grows on calls, in_seats shrinks on
-- folds, community_count bumps on deal_flop, etc.).
--
-- Engine-agnostic: knows nothing about poker. Game-specific kinds and
-- their applicators register from a model layer (see
-- models/poker_action_apply.lua) the same way models/poker_effects
-- registers EffectsRegistry kinds.
--
-- Dispatch contract:
--   reg:register("kind_name", function(event, state) ... end)
--   reg:apply(event, state) -> nothing (mutates state in-place)
--
-- THE RULE: there is no `if event.kind == "..." then ... elseif ...`
-- chain ANYWHERE. Register a function instead.

local PokerEventRegistry = {}
PokerEventRegistry.__index = PokerEventRegistry

function PokerEventRegistry:new()
    return setmetatable({ fns = {} }, PokerEventRegistry)
end

function PokerEventRegistry:register(kind, applicator)
    self.fns[kind] = applicator
end

function PokerEventRegistry:apply(event, state)
    if not event or not event.kind then return end
    local fn = self.fns[event.kind]
    if not fn then
        error("PokerEventRegistry: no applicator for kind '" .. tostring(event.kind) .. "'")
    end
    fn(event, state)
end

function PokerEventRegistry:has(kind)
    return self.fns[kind] ~= nil
end

return PokerEventRegistry
