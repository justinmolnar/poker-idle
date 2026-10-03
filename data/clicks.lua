-- data/clicks.lua
--
-- Every click answers where it lands (services/ClickFX; the design is
-- docs/sound-checklist.md section 8). A surface is a material, registered
-- per frame by whatever draws it (services/ClickSurfaces); a click on it
-- plays the material's sound, throws its specks (services/Sparks) and pokes
-- the thing it hit (services/Poke). All the numbers live here.
--
-- Per material:
--   sound    a sound name (a preset in data/sounds.lua, or a file the loader
--            pairs by name: assets/audio/ui/click_felt.ogg plays as
--            "click_felt" the moment it is placed; silent until then)
--   volume   volume_mult for that sound
--   pitch    playback pitch (1 = as recorded)
--   specks   how many squares a dead click throws
--   colors   their palette, picked at random per speck; nil = the surface's
--            own tint (a table's felt)
--   speed    launch speed, px/s (each speck takes 50-100% of it)
--   up       upward bias on the launch, 0 = all directions, 1 = straight up
--   gravity  px/s^2
--   life     seconds before a speck is gone (it fades over the last half)
--   size     speck side in px, min and max
--   ring     an expanding square outline at the point (a press into cloth)
--   poke     the reaction a registered poke key gets (services/Poke kinds)

local DUST   = { { 0.78, 0.74, 0.66 }, { 0.62, 0.58, 0.50 }, { 0.90, 0.86, 0.78 } }
local GLINT  = { { 0.95, 0.95, 0.98 }, { 0.80, 0.82, 0.88 }, { 1.00, 0.96, 0.80 } }
local PAPER  = { { 0.96, 0.94, 0.88 }, { 0.88, 0.85, 0.76 }, { 1.00, 1.00, 0.96 } }
local GREY   = { { 0.42, 0.42, 0.44 }, { 0.30, 0.30, 0.32 }, { 0.55, 0.55, 0.56 } }
local DARK   = { { 0.20, 0.16, 0.14 }, { 0.32, 0.22, 0.18 }, { 0.12, 0.10, 0.10 } }
local GOLD   = { { 1.00, 0.84, 0.30 }, { 0.98, 0.70, 0.20 }, { 1.00, 0.95, 0.60 } }
local WOOD   = { { 0.52, 0.38, 0.24 }, { 0.40, 0.28, 0.18 }, { 0.66, 0.50, 0.32 } }

return {
    materials = {
        felt    = { sound = "click_felt",    volume = 0.55, pitch = 1.0,  specks = 12, colors = nil,
                    speed = 105,  up = 0.35, gravity = 260, life = 0.416, size = { 3, 5 }, ring = true },
        chrome  = { sound = "click_chrome",  volume = 0.50, pitch = 1.0,  specks = 6, colors = GLINT,
                    speed = 165, up = 0.0,  gravity = 0,   life = 0.208, size = { 2, 4 } },
        rail    = { sound = "click_rail",    volume = 0.60, pitch = 1.0,  specks = 10, colors = WOOD,
                    speed = 90,  up = 0.6,  gravity = 300, life = 0.442, size = { 3, 5 }, poke = "jostle" },
        empty   = { sound = "click_empty",   volume = 0.55, pitch = 1.0,  specks = 10, colors = GREY,
                    speed = 82,  up = 0.3,  gravity = 220, life = 0.468, size = { 3, 5 } },
        wall    = { sound = "click_wall",    volume = 0.40, pitch = 1.0,  specks = 6, colors = GREY,
                    speed = 60,  up = 0.2,  gravity = 180, life = 0.39, size = { 2, 4 } },
        paper   = { sound = "click_paper",   volume = 0.55, pitch = 1.0,  specks = 8, colors = PAPER,
                    speed = 98,  up = 0.4,  gravity = 200, life = 0.442, size = { 3, 5 }, poke = "swing" },
        card    = { sound = "click_card",    volume = 0.45, pitch = 1.25, specks = 6, colors = PAPER,
                    speed = 90,  up = 0.5,  gravity = 240, life = 0.338, size = { 2, 4 }, poke = "jump" },
        chips   = { sound = "click_chips",   volume = 0.50, pitch = 1.0,  specks = 0, colors = GOLD,
                    speed = 0,   up = 0,    gravity = 0,   life = 0,    size = { 2, 3 }, poke = "hop" },
        -- The House's intercom: its key-up static, and the grille rattles.
        speaker = { sound = "click_speaker", volume = 0.40, pitch = 1.0,  specks = 6, colors = GREY,
                    speed = 68,  up = 0.3,  gravity = 200, life = 0.364, size = { 2, 4 }, poke = "rattle" },
        -- A room item plays its own foley (services/ItemFoley) and bobs.
        item    = { sound = nil,             volume = 0.70, pitch = 1.0,  specks = 8, colors = DUST,
                    speed = 82,  up = 0.5,  gravity = 220, life = 0.39, size = { 3, 5 }, poke = "bob" },
        -- A button that can't act.
        denied  = { sound = "click_denied",  volume = 0.60, pitch = 1.0,  specks = 8, colors = DARK,
                    speed = 75,  up = 0.2,  gravity = 260, life = 0.39, size = { 3, 5 }, poke = "shake" },
    },

    -- A click that did something: the button click already plays (ClickFlash),
    -- the surface sound goes under it at this share, and a gold burst rides
    -- over the material's specks.
    result = { surface_volume = 0.45, specks = 10, colors = GOLD, speed = 180, up = 0.2,
               gravity = 120, life = 0.312, size = { 3, 5 } },

    -- Rapid clicks build: each click inside `window` seconds of the last one
    -- steps the pitch up and the specks out, up to `cap` steps; a pause lets
    -- it settle.
    streak = { window = 0.45, cap = 8, pitch_step = 0.035, specks_step = 0.15 },

    -- A cursor's click: the same surface, higher, quieter, smaller.
    cursor = { pitch = 1.3, volume = 0.35, specks = 0.4 },

    -- The House poster earns a faint static tick from its speaker now and
    -- then, as if he noticed.
    poster_notice_chance = 0.125,

    -- Spark pool bound (specks alive at once).
    max_specks = 1200,
}
