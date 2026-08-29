-- data/game_type_themes.lua
--
-- Per-game-type visual identity: the HEADER CHROME. The panel's top bar
-- wears the game type's color; the felt below says the stake (derived
-- from its big-blind chip, views/TablePanel.feltForStake). Two axes, two
-- surfaces, so a glance reads "oxblood header on gold felt = HU 1k"
-- without touching the text.
--
-- This color lived on the felt's outer RAIL first; the rail was retired
-- (data/felt_style.lua) because a ring spends card pixels to say what a
-- painted header says for free at any panel size. The materials survive:
-- oak, oxblood, slate, teal.
--
-- Schema (per game_type_id, all optional; the header falls back to the
-- stake theme's header_bg, then Theme.bg.chrome):
--   chrome_color = { r, g, b }   -- header-bar fill (views/TablePanel)

-- Values are pulled well toward their own luminance and kept dark: with a
-- board of mixed tables these sit side by side, and four saturated bars
-- read as a rainbow instead of four materials. A stain, not a paint.
return {
    six_max = { chrome_color = { 0.29, 0.24, 0.18 } },   -- worn oak: the standard table
    hu      = { chrome_color = { 0.26, 0.15, 0.15 } },   -- oxblood leather: the duel
    zoom    = { chrome_color = { 0.18, 0.20, 0.25 } },   -- slate lacquer: fast and cool
    mtt     = { chrome_color = { 0.15, 0.24, 0.24 } },   -- teal lacquer: the tournament room
}
