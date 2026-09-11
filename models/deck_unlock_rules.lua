-- models/deck_unlock_rules.lua
--
-- Poker-specific unlock applicators registered into a generic
-- services/UnlockRegistry. Mirrors models/poker_effects.lua's
-- relationship with EffectsRegistry: registry mechanism stays
-- engine-agnostic; the game-specific kinds and the named state fields
-- they read live here.
--
-- Each registered kind reads ONE named field on the GameState instance
-- and compares it against the spec's threshold. Adding a new unlock
-- kind = one entry here + one usage in data/decks.lua. No `if kind ==`
-- chain anywhere.
--
-- Condition shape (decided here on the game side; the registry doesn't
-- interpret):
--   { kind = "total_xxx", threshold = N, text = "Display copy" }

local Decks = require("models.Decks")

local DeckUnlockRules = {}

-- Every deck gate is the same shape: one named GameState counter compared to
-- a threshold, where the kind name IS the field name. Listing them as data
-- rather than writing nine near-identical closures means a new gate is one
-- line, and it lets the predicate and the progress reporter be generated
-- together (see services/UnlockRegistry:progress).
local COUNTER_KINDS = {
    "total_money_won",
    "total_stacks",
    -- Ungated totals the 2026-09 roster gates on (they tick in Act 1 too,
    -- which is fine: a deck opening the moment decks exist is a feature).
    "total_tilts",
    "total_heaters",
    "total_ko_wins",
    "total_chips_banked",
    "total_hands_at_4plus",
    "total_cursor_deals",
}

function DeckUnlockRules.registerAll(reg)
    for _, field in ipairs(COUNTER_KINDS) do
        reg:register(field,
            function(cond, state)
                return (state and state[field] or 0) >= (cond.threshold or 0)
            end,
            function(cond, state)
                return (state and state[field] or 0), (cond.threshold or 0)
            end)
    end

    -- Hands at one game type (total_hands_by_gtype), the catalog rule's
    -- twin: { kind = "hands_at_gtype", gtype = "zoom", threshold = N }.
    local function handsAt(cond, state)
        local by = state and state.total_hands_by_gtype
        return (by and cond.gtype and by[cond.gtype]) or 0
    end
    reg:register("hands_at_gtype",
        function(cond, state) return handsAt(cond, state) >= (cond.threshold or 0) end,
        function(cond, state) return handsAt(cond, state), (cond.threshold or 0) end)

    -- Number of decks at max level. Gates the master deck (threshold 5).
    -- Not a state field — computed from deck_levels vs each spec's cap.
    reg:register("decks_maxed",
        function(cond, state) return Decks.maxedCount(state) >= (cond.threshold or 0) end,
        function(cond, state) return Decks.maxedCount(state), (cond.threshold or 0) end)
end

return DeckUnlockRules
