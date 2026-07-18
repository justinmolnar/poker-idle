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
--   { kind = "lifetime_xxx", threshold = N, text = "Display copy" }

local Decks = require("models.Decks")

local DeckUnlockRules = {}

function DeckUnlockRules.registerAll(reg)
    reg:register("lifetime_money_won", function(cond, state)
        return (state and state.lifetime_money_won or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_money_lost", function(cond, state)
        return (state and state.lifetime_money_lost or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_jackpot_count", function(cond, state)
        return (state and state.lifetime_jackpot_count or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_mtt_hands_won", function(cond, state)
        return (state and state.lifetime_mtt_hands_won or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_hands_played", function(cond, state)
        return (state and state.lifetime_hands_played or 0) >= (cond.threshold or 0)
    end)

    reg:register("lifetime_hands_at_4plus_tables", function(cond, state)
        return (state and state.lifetime_hands_at_4plus_tables or 0) >= (cond.threshold or 0)
    end)

    -- Number of decks at max level. Gates the master deck (threshold 5).
    -- Not a state field — computed from deck_levels vs each spec's cap.
    reg:register("decks_maxed", function(cond, state)
        return Decks.maxedCount(state) >= (cond.threshold or 0)
    end)
end

return DeckUnlockRules
