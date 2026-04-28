-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Don't add items to the room.
--
-- Item schema (same effect shape as catalog.lua so the EffectsRegistry handles
-- both with the same applicators — that's the point):
--   {
--     id      = "snake_case_unique",
--     name    = "Display Name",
--     cost    = number,                       -- bankroll cost ($)
--     effects = { { kind = "...", value = ... }, ... }
--   }
--
-- NOTE: shove_rate_add is reserved for catalog items only. Run upgrades that
-- include it would violate the meta-progression north-star — the design doc
-- is explicit on this. Linter rule TBD; for now, just don't.

return {

    -- Empty for the skeleton. First entry will be "Energy Drink" per MVP doc.

}
