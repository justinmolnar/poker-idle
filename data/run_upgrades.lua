-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Don't add items to the room.
--
-- Item schema (same effect shape as catalog.lua so the EffectsRegistry handles
-- both with the same applicators):
--   {
--     id          = "snake_case_unique",
--     name        = "Display Name",
--     description = "Short blurb shown under the name in the upgrades panel",
--     cost        = number,                       -- bankroll cost ($)
--     effects     = { { kind = "...", value = ... }, ... }
--   }
--
-- NOTE: shove_rate_add is reserved for catalog items only. Run upgrades that
-- include it would violate the meta-progression north-star.
--
-- Costs scaled to the new $2-bankroll economy. Lucky Charm is the cheap
-- early buy; Concentration is the late-run grind reward.

return {

    {
        id          = "lucky_charm",
        name        = "Lucky Charm",
        description = "+5% vs fish opponents",
        cost        = 0.50,
        effects     = { { kind = "vs_fish_mult", value = 1.05 } },
    },
    {
        id          = "coffee",
        name        = "Coffee",
        description = "+3% earnings (run)",
        cost        = 0.30,
        effects     = { { kind = "earnings_mult", value = 1.03 } },
    },
    {
        id          = "energy_drink",
        name        = "Energy Drink",
        description = "+10% earnings (run)",
        cost        = 1.00,
        effects     = { { kind = "earnings_mult", value = 1.10 } },
    },
    {
        id          = "focus_drink",
        name        = "Focus Drink",
        description = "+2 focus capacity (this run)",
        cost        = 1.00,
        effects     = { { kind = "focus_capacity_add", value = 2 } },
    },
    {
        id          = "single_session",
        name        = "Single Session",
        description = "-10% focus penalty per extra table (this run)",
        cost        = 2.50,
        effects     = { { kind = "focus_penalty_reduce_mult", value = 0.90 } },
    },
    {
        id          = "concentration",
        name        = "Concentration",
        description = "+5% vs TAG opponents",
        cost        = 3.00,
        effects     = { { kind = "vs_tag_mult", value = 1.05 } },
    },

}
