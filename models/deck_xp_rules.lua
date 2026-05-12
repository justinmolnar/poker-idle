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
--   {
--     won            = bool,
--     delta          = number,                 -- raw $ (positive on win)
--     tier           = "small"|"medium"|"large"|"jackpot",
--     bb_delta       = number,                 -- delta / stake.bb
--     gtype          = "six_max"|"hu"|"zoom"|"mtt",
--     stake_tier_idx = 1..6,                   -- T1-T6 stake position
--     n_tables       = integer,                -- concurrent open tables
--   }
--
-- The parameterized rules (money_won / hands_played / hands_won) accept
-- optional filter knobs on the spec's xp_rule. Each rule is one
-- registered function; filter checks live inline. NO if/elseif chain on
-- rule.kind anywhere.

local DeckXpRules = {}

-- Helper: tier-bounds check for money_won rule.
local function tierBoundsOk(rule, event)
    local idx = event and event.stake_tier_idx
    if rule.tier_min and (not idx or idx < rule.tier_min) then return false end
    if rule.tier_max and (not idx or idx > rule.tier_max) then return false end
    return true
end

function DeckXpRules.registerAll(reg)
    -- Money won. Optional tier_min / tier_max filter for tier-scoped decks.
    reg:register("money_won", function(rule, event)
        if not event or not event.won then return 0 end
        if not tierBoundsOk(rule, event) then return 0 end
        return math.max(0, event.delta or 0)
    end)

    -- Money lost. Counts the absolute magnitude of losing-resolution
    -- deltas. Self-extinguishing curve when paired with loss_mult bonuses.
    reg:register("money_lost", function(_rule, event)
        if not event or event.won then return 0 end
        local d = event.delta or 0
        return d < 0 and -d or 0
    end)

    -- Jackpot dollars. Only jackpot-tier wins contribute their delta.
    reg:register("jackpot_dollars", function(_rule, event)
        if not event or not event.won then return 0 end
        if event.tier ~= "jackpot" then return 0 end
        return math.max(0, event.delta or 0)
    end)

    -- +1 per resolved hand. Optional `min_tables` filter (Multi-Tabler
    -- only counts hands played while at >= N tables open).
    reg:register("hands_played", function(rule, event)
        if not event then return 0 end
        if rule.min_tables and (event.n_tables or 0) < rule.min_tables then
            return 0
        end
        return 1
    end)

    -- +1 per resolved win. Optional `gtype` filter for game-type-scoped
    -- decks (Tournament Pro counts MTT wins only).
    reg:register("hands_won", function(rule, event)
        if not event or not event.won then return 0 end
        if rule.gtype and event.gtype ~= rule.gtype then return 0 end
        return 1
    end)
end

return DeckXpRules
