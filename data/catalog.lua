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
        id          = "better_mouse",
        name        = "Better Mouse",
        description = "+1 focus capacity",
        sprite      = "better_mouse",
        cost_pp     = 8,
        position    = { x = 150, y = 220 },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
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
        description = "+2 focus capacity",
        sprite      = "second_monitor",
        cost_pp     = 20,
        position    = { x = 600, y = 200 },
        effects     = { { kind = "focus_capacity_add", value = 2 } },
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
        id          = "ergonomic_chair",
        name        = "Ergonomic Chair",
        description = "+2 focus capacity",
        sprite      = "ergonomic_chair",
        cost_pp     = 25,
        position    = { x = 250, y = 300 },
        effects     = { { kind = "focus_capacity_add", value = 2 } },
    },
    {
        id          = "hotkeys_mastery",
        name        = "Hotkeys Mastery",
        description = "-15% focus penalty per extra table",
        sprite      = "hotkeys_mastery",
        cost_pp     = 30,
        position    = { x = 400, y = 300 },
        effects     = { { kind = "focus_penalty_reduce_mult", value = 0.85 } },
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
    {
        id          = "dual_monitors",
        name        = "Dual Monitors",
        description = "+4 focus capacity",
        sprite      = "dual_monitors",
        cost_pp     = 60,
        position    = { x = 550, y = 300 },
        effects     = { { kind = "focus_capacity_add", value = 4 } },
    },
    {
        id          = "pokertracker_hud",
        name        = "PokerTracker HUD",
        description = "+6 focus capacity",
        sprite      = "pokertracker_hud",
        cost_pp     = 120,
        position    = { x = 700, y = 300 },
        effects     = { { kind = "focus_capacity_add", value = 6 } },
    },

}
