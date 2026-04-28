-- data/catalog.lua
--
-- The PP-shop catalog. Each item:
--   • is bought with Poker Points (PP, the meta currency)
--   • appears visually in the room (deferred — list-only UI for VR)
--   • applies one or more effects via the EffectsRegistry
--   • persists across prestiges forever
--
-- Item schema:
--   {
--     id          = "snake_case_unique",       -- referenced by GameState.owned_items
--     name        = "Display Name",
--     description = "Short blurb shown under name in catalog UI",
--     sprite      = "sprite_name",              -- looked up via SpriteLoader (room viz, deferred)
--     cost_pp     = number,
--     position    = { x = px, y = px },         -- room placement (deferred)
--     effects     = { { kind = "...", value = ... }, ... }  -- see data/effects.lua
--   }

return {

    {
        id          = "teddy_bear",
        name        = "Teddy Bear",
        description = "+2% per-runout shove rate",
        sprite      = "teddy_bear",
        cost_pp     = 5,
        position    = { x = 100, y = 200 },
        effects     = { { kind = "shove_rate_add", value = 0.02 } },
    },
    {
        id          = "plant",
        name        = "Plant",
        description = "+5% bankroll earnings",
        sprite      = "plant",
        cost_pp     = 8,
        position    = { x = 200, y = 200 },
        effects     = { { kind = "earnings_mult", value = 1.05 } },
    },
    {
        id          = "mug",
        name        = "Mug",
        description = "+3% per-runout shove rate",
        sprite      = "mug",
        cost_pp     = 10,
        position    = { x = 300, y = 200 },
        effects     = { { kind = "shove_rate_add", value = 0.03 } },
    },
    {
        id          = "mousepad",
        name        = "Mousepad",
        description = "+5% vs fish opponents",
        sprite      = "mousepad",
        cost_pp     = 12,
        position    = { x = 500, y = 200 },
        effects     = { { kind = "vs_fish_mult", value = 1.05 } },
    },
    {
        id          = "lamp",
        name        = "Lamp",
        description = "+5% vs LAG opponents",
        sprite      = "lamp",
        cost_pp     = 15,
        position    = { x = 400, y = 200 },
        effects     = { { kind = "vs_lag_mult", value = 1.05 } },
    },
    {
        id          = "second_monitor",
        name        = "Second Monitor",
        description = "+1 concurrent table slot",
        sprite      = "second_monitor",
        cost_pp     = 20,
        position    = { x = 600, y = 200 },
        effects     = { { kind = "table_slots_add", value = 1 } },
    },
    {
        id          = "lucky_charm_pp",
        name        = "Lucky Charm",
        description = "+5% per-runout shove rate",
        sprite      = "lucky_charm",
        cost_pp     = 25,
        position    = { x = 100, y = 300 },
        effects     = { { kind = "shove_rate_add", value = 0.05 } },
    },
    {
        id          = "lucky_coin",
        name        = "Lucky Coin",
        description = "+10% per-runout shove rate",
        sprite      = "lucky_coin",
        cost_pp     = 50,
        position    = { x = 200, y = 300 },
        effects     = { { kind = "shove_rate_add", value = 0.10 } },
    },

}
