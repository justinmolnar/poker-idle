-- models/deck_xp_rules.lua
--
-- Poker-specific XP rule applicators registered into a generic
-- services/XpRuleRegistry. Mirrors the relationship between
-- models/poker_effects.lua and services/EffectsRegistry — the registry
-- mechanism stays engine-agnostic; the game-specific kinds and their
-- behavior live here.
--
-- Adding a new XP rule kind:
--   1. Add an entry to data/decks.lua with `xp_rule = { kind = "...", ... }`.
--   2. Register the applicator here. The applicator consumes an event
--      table emitted by GrindController on every resolved hand and
--      returns an XP delta.
--
-- Event shape (decided here on the game side; the registry doesn't
-- interpret):
--   { won = bool, bb_delta = number (cash only; binary_outcome MTT = 0),
--     delta = number (raw $) }
--
-- THERE IS NO if/elseif chain on rule.kind anywhere. If you find
-- yourself writing one, register a function instead.

local DeckXpRules = {}

function DeckXpRules.registerAll(reg)
    -- +1 per resolved hand. Volume rule — bread-and-butter idle curve.
    reg:register("hands_played", function(_rule, _event)
        return 1
    end)

    -- bb-scaled XP on wins. Tournament binary_outcome hands have
    -- bb_delta = 0 and contribute nothing — the rule is for cash-side
    -- volume, not tournament wins. Optional `mult` lets a deck spec
    -- re-tune without touching this code.
    reg:register("bb_won", function(rule, event)
        if not event or not event.won then return 0 end
        local mult = rule.mult or 1
        return math.max(0, (event.bb_delta or 0) * mult)
    end)

    -- +1 per resolved hand the player lost. Lets a "soak" deck level on
    -- the rate the player busts hands rather than wins them.
    reg:register("hands_lost", function(_rule, event)
        if not event or event.won then return 0 end
        return 1
    end)
end

return DeckXpRules
