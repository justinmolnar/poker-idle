-- models/catalog_unlock_rules.lua
--
-- Catalog-item unlock predicates, registered into the SAME generic
-- services/UnlockRegistry instance the decks use (g.unlock_rules). Mirrors
-- models/deck_unlock_rules.lua exactly — each kind reads ONE named field on
-- the GameState and compares it to the spec's threshold. No `if kind ==`
-- chain anywhere.
--
-- The deck rules already register the lifetime_* kinds (lifetime_money_won,
-- lifetime_hands_overwhelmed, lifetime_hands_at_4plus_tables, ...), so a
-- catalog item can gate on any of those too. This module only adds the
-- extra kinds catalog items want that decks don't already register.
--
-- Condition shape on a catalog entry:
--   unlock = { kind = "...", threshold = N, text = "Shown while locked" }

local CatalogUnlockRules = {}

function CatalogUnlockRules.registerAll(reg)
    reg:register("total_hands_played", function(cond, state)
        return (state and state.total_hands_played or 0) >= (cond.threshold or 0)
    end)

    reg:register("total_big_outcomes", function(cond, state)
        return (state and state.total_big_outcomes or 0) >= (cond.threshold or 0)
    end)

    reg:register("total_denied_stacks", function(cond, state)
        return (state and state.total_denied_stacks or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_chips_banked", function(cond, state)
        return (state and state.lifetime_chips_banked or 0) >= (cond.threshold or 0)
    end)
end

return CatalogUnlockRules
