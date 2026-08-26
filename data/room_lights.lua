-- data/room_lights.lua
--
-- How the player's room is lit (views/RoomLighting.lua). Edited in the
-- room editor's LIGHT tab and written by EXPORT. See models/room_placement
-- for the layout; this file is the light: a fixture (fluorescent: blooms
-- then settles; cone: a hanging bulb) and the things that make light, by
-- catalog id (radius in sprite widths; pulse breathes the glow). Tables only.

return {
    fixture = {
        kind    = "fluorescent",
        color   = { 1.00, 0.97, 0.90 },
        ambient = { 0.10, 0.10, 0.14 },
        bloom   = { peak = 1.35, peak_at = 0.12, settle_at = 0.60 },
        base    = 0.70,
        pool    = { w = 1.60, h = 1.25, alpha = 0.45 },
        cone    = { w = 0.90, h = 0.70, alpha = 0.90, base = 0.15 },
    },
    emitters = {
        console_tv       = { color = { 0.70, 0.85, 1.00 }, radius = 1.40, alpha = 0.50, pulse = { secs = 0.90, amount = 0.08 } },
        corkboard        = { color = { 0.50, 0.95, 0.80 }, radius = 0.60, alpha = 0.15, pulse = { secs = 2.00, amount = 0.15 } },
        curved_monitor   = { color = { 0.75, 0.88, 1.00 }, radius = 1.30, alpha = 0.45 },
        laptop           = { color = { 0.80, 0.90, 1.00 }, radius = 1.10, alpha = 0.35 },
        lava_lamp        = { color = { 0.55, 1.00, 0.45 }, radius = 1.60, alpha = 0.55, pulse = { secs = 2.40, amount = 0.15 } },
        pc_tower         = { color = { 0.40, 0.80, 1.00 }, radius = 0.50, alpha = 0.30, pulse = { secs = 1.60, amount = 0.30 } },
        second_monitor   = { color = { 0.75, 0.88, 1.00 }, radius = 1.20, alpha = 0.40 },
        window           = { color = { 0.85, 0.92, 1.00 }, radius = 1.80, alpha = 0.35 },
    },
}
