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
--     tier           = "small"|"medium"|"large"|"stack",
--     bb_delta       = number,                 -- delta / stake.bb
--     gtype          = "six_max"|"hu"|"zoom"|"ko",
--     stake_tier_idx = 1..10,                  -- 1-based stake position
--     stake_buy_in   = number,                 -- the table's buy-in in $
--     n_tables       = integer,                -- concurrent open tables
--   }
--
-- Count-shaped rules earn the table's BUY-IN IN DOLLARS per event: a hand
-- at NL10K is worth a hundred NL100 hands, so the ladder's own steps pace
-- the decks and nothing needs a stake gate
-- (data/decks.lua sizes the curves to that). Money-shaped rules are
-- already in dollars. The parameterized rules accept optional filter
-- knobs on the spec's xp_rule (money_won: tier_min / tier_max;
-- hands_played: min_tables; hands_won: gtype). Each rule is one
-- registered function; filter checks live inline. NO if/elseif chain on
-- rule.kind anywhere.

local DeckXpRules = {}

-- Helper: what one counted event is worth — the table's BUY-IN in
-- dollars. NL2 pays 2, NL10 pays 10, NL10K pays 10,000. No floor, no
-- special case; the ladder is the whole rule.
local function buyInWeight(event)
    return (event and event.stake_buy_in) or 0
end

-- Helper: tier-bounds check for the money_won rule's tier filters.
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
        if rule.gtype and event.gtype ~= rule.gtype then return 0 end
        if rule.pure_only and not event.board_pure then return 0 end
        return math.max(0, event.delta or 0)
    end)

    -- The Bank: XP is the highest bankroll ever seen. `absolute = true` on
    -- the rule tells Decks.gainXp the return is a level, not a delta.
    reg:register("bankroll_peak", function(_rule, event)
        return (event and event.bankroll) or 0
    end)

    -- Event-shaped rules: one counted moment each, emitted by the
    -- controller with `type` and `n`.
    reg:register("knockouts", function(_rule, event)
        if not event or event.type ~= "ko" then return 0 end
        return event.n or 1
    end)
    reg:register("heaters_caught", function(_rule, event)
        if not event or event.type ~= "heater" then return 0 end
        return event.n or 1
    end)
    reg:register("tilts_absorbed", function(_rule, event)
        if not event or event.type ~= "tilt_absorbed" then return 0 end
        return event.n or 1
    end)
    reg:register("chips_banked", function(_rule, event)
        if not event or event.type ~= "bounty" then return 0 end
        return event.n or 0
    end)

    -- Money lost. Counts the absolute magnitude of losing-resolution
    -- deltas. Self-extinguishing curve when paired with loss_mult bonuses.
    reg:register("money_lost", function(_rule, event)
        if not event or event.won then return 0 end
        local d = event.delta or 0
        return d < 0 and -d or 0
    end)

    -- Stack dollars. Only stack-tier wins contribute their delta.
    reg:register("stack_dollars", function(_rule, event)
        if not event or not event.won then return 0 end
        if event.tier ~= "stack" then return 0 end
        return math.max(0, event.delta or 0)
    end)

    -- The big blind, per resolved hand. Optional `min_tables` filter
    -- (only counts hands played while at >= N tables open).
    reg:register("hands_played", function(rule, event)
        if not event then return 0 end
        if rule.min_tables and (event.n_tables or 0) < rule.min_tables then
            return 0
        end
        return buyInWeight(event)
    end)

    -- The big blind, per resolved win. Optional `gtype` filter for
    -- game-type-scoped decks.
    reg:register("hands_won", function(rule, event)
        if not event or not event.won then return 0 end
        if rule.gtype and event.gtype ~= rule.gtype then return 0 end
        return buyInWeight(event)
    end)

    -- Specialist XP rule: won hand on a single table, 2 × the big blind
    reg:register("hands_won_single_table", function(_rule, event)
        if not event or not event.won then return 0 end
        if event.n_tables ~= 1 then return 0 end
        return 2 * buyInWeight(event)
    end)

    -- Multitasker XP rule: won hand while overwhelmed, the big blind per
    -- table over the cap
    reg:register("hands_won_overwhelmed", function(_rule, event)
        if not event or not event.won then return 0 end
        local cap = event.focus_capacity or 3
        local extra = event.n_tables - cap
        if extra <= 0 then return 0 end
        return extra * buyInWeight(event)
    end)

    -- Investor XP rule: dollars spent on a run upgrade
    reg:register("upgrades_bought", function(_rule, event)
        if not event or event.type ~= "run_upgrade" then return 0 end
        return math.max(0, event.cost_dollars or 0)
    end)

    -- Tier Manipulator XP rule: won hand at T2+, the big blind
    reg:register("hands_won_above_t1", function(_rule, event)
        if not event or not event.won then return 0 end
        if (event.stake_tier_idx or 1) <= 1 then return 0 end
        return buyInWeight(event)
    end)

    -- Short Stack XP rule: rebought a table stack, 10 × the big blind
    reg:register("table_rebuys", function(_rule, event)
        if not event or event.type ~= "table_rebuy" then return 0 end
        return 10 * buyInWeight(event)
    end)
end

return DeckXpRules
