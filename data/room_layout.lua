-- data/room_layout.lua
--
-- Grid placement and dimensions for isometric room objects.
-- Edited via the in-game Room Editor and saved/pasted here.
--
-- Schema:
--   [item_id] = {
--     gx       = number,  -- grid x (0..9)
--     gy       = number,  -- grid y (0..9)
--     w        = number,  -- width in grid tiles (default 1)
--     h        = number,  -- height in grid tiles (default 1)
--     z_offset = number,  -- vertical height offset in screen px (default 0)
--     sh       = number,  -- visual box height/thickness in screen px (default 16)
--     color    = {r,g,b}, -- fallback shaded block color (graybox representation)
--   }
return {
    poker_poster        = { gx = 0, gy = 3, w = 1, h = 1, z_offset = 35, sh = 20, color = { 0.82, 0.42, 0.38 } },
    branded_hat         = { gx = 2, gy = 2, w = 1, h = 1, z_offset = 0,  sh = 10, color = { 0.40, 0.55, 0.75 } },
    whiteboard          = { gx = 4, gy = 1, w = 2, h = 1, z_offset = 25, sh = 30, color = { 0.90, 0.90, 0.90 } },
    lava_lamp           = { gx = 3, gy = 4, w = 1, h = 1, z_offset = 12, sh = 15, color = { 0.85, 0.30, 0.85 } },
    self_help_book      = { gx = 2, gy = 4, w = 1, h = 1, z_offset = 12, sh = 8,  color = { 0.45, 0.78, 0.45 } },
    mirror              = { gx = 0, gy = 1, w = 1, h = 1, z_offset = 30, sh = 24, color = { 0.55, 0.72, 0.85 } },
    energy_drink        = { gx = 3, gy = 3, w = 1, h = 1, z_offset = 12, sh = 8,  color = { 0.92, 0.72, 0.32 } },
    stress_ball         = { gx = 4, gy = 3, w = 1, h = 1, z_offset = 12, sh = 6,  color = { 0.80, 0.35, 0.35 } },
    lucky_coin          = { gx = 4, gy = 4, w = 1, h = 1, z_offset = 12, sh = 4,  color = { 0.92, 0.85, 0.30 } },
}
