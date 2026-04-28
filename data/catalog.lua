-- data/catalog.lua
--
-- The PP-shop catalog. Each item is a permanent room object that:
--   • is bought with Poker Points (PP, the meta currency)
--   • appears visually in the room
--   • applies one or more effects via the EffectsRegistry
--   • persists across prestiges forever
--
-- Item schema:
--   {
--     id       = "snake_case_unique",       -- referenced by GameState.owned_items
--     name     = "Display Name",
--     sprite   = "sprite_name",             -- looked up via SpriteLoader
--     cost_pp  = number,
--     position = { x = px, y = px },        -- room placement, top-left anchor
--     effects  = { { kind = "...", value = ... }, ... }  -- see data/effects.lua
--   }
--
-- The effects field is what the EffectsRegistry consumes. Adding a new
-- catalog item with an existing effect kind = pure data, no code change.

return {

    -- Canary entry, used by the verification round-trip in the plan. Safe to
    -- delete once the data→registry→effect pipeline is verified end-to-end.
    {
        id       = "canary",
        name     = "Canary (test)",
        sprite   = "canary",
        cost_pp  = 0,
        position = { x = 0, y = 0 },
        effects  = {
            { kind = "shove_rate_add", value = 0.5 },
        },
    },

}
