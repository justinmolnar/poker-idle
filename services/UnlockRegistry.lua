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
--   reg:register("kind_name", function(condition, state) return bool end,
--                             function(condition, state) return cur, target end)
--   reg:check(condition, state)    -> bool
--   reg:progress(condition, state) -> fraction 0..1, current, target
-- where `condition` is the spec's `unlock` table (carries a `kind` and
-- the threshold / parameter knobs the applicator reads), `state` is the
-- player's GameState instance.
--
-- The progress function is OPTIONAL and purely for presentation — a UI that
-- wants to show "how close am I" rather than a bare locked/unlocked. A kind
-- registered without one is not an error: it reports 0 or 1 off its own
-- predicate, which is the honest answer for a condition that is a flag rather
-- than a count. `current` / `target` come back nil in that case so the caller
-- can tell "no meaningful ratio" from "0 of N".
--
-- The registry stays ignorant of what any counter MEANS. It never reads a
-- state field itself; the reads live in the game-side rules modules.
--
-- THE RULE: there is no `if condition.kind == "..." then ... elseif ...`
-- chain ANYWHERE. Register a function instead.

local UnlockRegistry = {}
UnlockRegistry.__index = UnlockRegistry

function UnlockRegistry:new()
    return setmetatable({ fns = {}, progress_fns = {} }, UnlockRegistry)
end

function UnlockRegistry:register(kind, applicator, progress_fn)
    self.fns[kind] = applicator
    self.progress_fns[kind] = progress_fn   -- may be nil (flag-style condition)
end

function UnlockRegistry:check(condition, state)
    if not condition or not condition.kind then return false end
    local fn = self.fns[condition.kind]
    if not fn then
        error("UnlockRegistry: no applicator for kind '" .. tostring(condition.kind) .. "'")
    end
    return fn(condition, state) and true or false
end

-- How far along the condition is, for display. Returns:
--   fraction — 0..1, always safe to multiply a bar width by
--   current, target — the raw pair, or nil/nil when the kind has no progress
--                     function (a flag: there is no "2 of 3" to show)
function UnlockRegistry:progress(condition, state)
    if not condition or not condition.kind then return 0 end
    local fn = self.progress_fns[condition.kind]
    if not fn then
        -- Flag-style condition: all or nothing, and no ratio to report.
        return self:check(condition, state) and 1 or 0
    end
    local current, target = fn(condition, state)
    current, target = current or 0, target or 0
    if target <= 0 then
        -- Degenerate threshold — treat any progress at all as complete rather
        -- than dividing by zero.
        return (current > 0) and 1 or 0, current, nil
    end
    local frac = current / target
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return frac, current, target
end

function UnlockRegistry:has(kind)
    return self.fns[kind] ~= nil
end

return UnlockRegistry
