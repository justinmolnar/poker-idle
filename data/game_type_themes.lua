-- data/game_type_themes.lua
--
-- Per-game-type visual identity: the RAIL. The felt's outer ring is wood
-- or leather and it says what game is being played; the felt colour says
-- what stake (data/stake_themes.lua). Two axes, two surfaces, so a glance
-- at a panel reads both.
--
-- Rails used to climb with the stake, the same axis as the felt, so the two
-- could only ever say one thing. Materials are reused from the ones that
-- were authored for the stake ladder; only the axis changed.
--
-- Schema (per game_type_id, all optional; views fall back to darkened
-- border_color):
--   rail_color = { r, g, b }   -- the felt's outer ring (views/FeltDecor)

return {
    six_max = { rail_color = { 0.38, 0.27, 0.15 } },   -- worn oak: the standard table
    hu      = { rail_color = { 0.37, 0.15, 0.15 } },   -- oxblood leather: the duel
    zoom    = { rail_color = { 0.19, 0.23, 0.34 } },   -- slate lacquer: fast and cool
    mtt     = { rail_color = { 0.12, 0.30, 0.31 } },   -- teal lacquer: the tournament room
}
