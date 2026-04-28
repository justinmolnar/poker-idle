-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Don't add items to the room.
--
-- Item schema (same effect shape as catalog.lua so the EffectsRegistry handles
-- both with the same applicators — that's the point):
--   {
--     id          = "snake_case_unique",
--     name        = "Display Name",
--     description = "Short blurb shown under the name in the upgrades panel",
--     cost        = number,                       -- bankroll cost ($)
--     effects     = { { kind = "...", value = ... }, ... }
--   }
--
-- NOTE: shove_rate_add is reserved for catalog items only. Run upgrades that
-- include it would violate the meta-progression north-star — the design doc
-- is explicit on this. Linter rule TBD; for now, just don't.

return {

    {
        id          = "lucky_charm",
        name        = "Lucky Charm",
        description = "+5% vs aggressive opponents",
        cost        = 20,
        effects     = { { kind = "vs_aggressive_mult", value = 1.05 } },
    },
    {
        id          = "coffee",
        name        = "Coffee",
        description = "+10 hands/minute",
        cost        = 30,
        effects     = { { kind = "hands_per_min_add", value = 10 } },
    },
    {
        id          = "energy_drink",
        name        = "Energy Drink",
        description = "+20% earnings this run",
        cost        = 50,
        effects     = { { kind = "earnings_mult", value = 1.20 } },
    },
    {
        id          = "concentration",
        name        = "Concentration",
        description = "+10% vs aggressive opponents",
        cost        = 120,
        effects     = { { kind = "vs_aggressive_mult", value = 1.10 } },
    },

}
