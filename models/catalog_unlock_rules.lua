-- models/catalog_unlock_rules.lua
--
-- Catalog-item unlock predicates, registered into the SAME generic
-- services/UnlockRegistry instance the decks use (g.unlock_rules). Mirrors
-- models/deck_unlock_rules.lua exactly — each kind reads ONE named field on
-- the GameState and compares it to the spec's threshold. No `if kind ==`
-- chain anywhere.
--
-- WHY THESE READ total_* AND NOT lifetime_*: the lifetime_* counters only
-- start accruing once the deck system unlocks (GrindController gates them on
-- Decks.systemUnlocked, i.e. the first R1 win = the end of Act 1). A catalog
-- item gated on one of those would sit as a silhouette through all of Act 1
-- no matter how the player played. The total_* family ticks from hand one.
-- Deck rules keep using lifetime_* — their thresholds are balanced against
-- an Act-2 start on purpose.
--
-- The deck rules register the lifetime_* kinds onto the same registry, so a
-- catalog item CAN still gate on one where that's the intent (an item meant
-- to appear only in Act 2).
--
-- Condition shape on a catalog entry:
--   unlock = { kind = "...", threshold = N, text = "Shown while locked" }
-- plus, for total_hands_at_gtype only:
--   unlock = { kind = "total_hands_at_gtype", gtype = "zoom", threshold = N, ... }

local CatalogUnlockRules = {}

-- Every predicate below is the same shape: read one counter, compare to the
-- threshold. Declared as data so adding a gate is one line, not a function.
local COUNTER_KINDS = {
    "total_hands_played",
    "total_hands_won",
    "total_big_outcomes",
    "total_denied_stacks",
    "lifetime_chips_banked",
    "total_busts",
    "total_stack_losses",
    "total_stacks",
    "total_rebuys",
    "total_upgrade_levels",
    "total_hands_overwhelmed",
    "total_hands_at_4plus",
    "total_chips_banked",
    "total_ko_wins",
    "total_tilts",
    "total_cursor_deals",
    "highest_stake_idx",
}

-- Each kind registers a predicate AND a progress reporter reading the same
-- counter, so a locked item can show how close it is instead of a bare
-- "locked". The progress reporter returns (current, target); the registry
-- turns that into a 0..1 fraction. See services/UnlockRegistry:progress.
function CatalogUnlockRules.registerAll(reg)
    for _, field in ipairs(COUNTER_KINDS) do
        reg:register(field,
            function(cond, state)
                return (state and state[field] or 0) >= (cond.threshold or 0)
            end,
            function(cond, state)
                return (state and state[field] or 0), (cond.threshold or 0)
            end)
    end

    -- Hands resolved at one game type. Same single-field read, one level
    -- deeper: the counter is a table keyed by game_type_id.
    local function handsAtGtype(cond, state)
        local by_gtype = state and state.total_hands_by_gtype
        return (by_gtype and cond.gtype and by_gtype[cond.gtype]) or 0
    end
    reg:register("total_hands_at_gtype",
        function(cond, state) return handsAtGtype(cond, state) >= (cond.threshold or 0) end,
        function(cond, state) return handsAtGtype(cond, state), (cond.threshold or 0) end)

    -- How many decks the player has unlocked (Study Chart). Reads the same
    -- list Decks maintains; deck_unlock_rules owns `decks_maxed`.
    local function decksUnlocked(_cond, state)
        local decks = state and state.unlocked_decks
        return decks and #decks or 0
    end
    reg:register("decks_unlocked_count",
        function(cond, state) return decksUnlocked(cond, state) >= (cond.threshold or 0) end,
        function(cond, state) return decksUnlocked(cond, state), (cond.threshold or 0) end)

    -- Milestone booleans. `threshold` is unused — the flag is the gate, and
    -- there is no "2 of 3 shoves won" to report, so NO progress function is
    -- registered on purpose: the registry falls back to 0-or-1 and the UI
    -- knows to omit the counter.
    reg:register("shove_r1_won", function(_cond, state)
        return (state and state.shove_r1_won) == true
    end)

    -- Zoom-first opening flags: items that only mean something once a
    -- game type exists gate on the same flags Constants.GTYPE_GATE reads.
    reg:register("has_shoved", function(_cond, state)
        return (state and state.has_shoved) == true
    end)
    reg:register("hu_unlocked", function(_cond, state)
        return (state and state.hu_unlocked) == true
    end)
end

return CatalogUnlockRules
