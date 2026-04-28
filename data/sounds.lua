-- data/sounds.lua
--
-- Named procedural-tone presets. The SoundService implements the actual
-- waveform synthesis; this file is the registry of which named sounds are
-- in use for which event in the game.
--
-- Sound entry schema (the SoundService reads `kind` to pick its synth path):
--   {
--     kind   = "beep" | "chime" | "warning" | "success" | "fail" | "horn",
--     volume = 0..1,           -- per-sound mix
--   }
--
-- Adding a new sound name = one entry here. The synth `kind`s themselves are
-- closed (defined in the SoundService); add a new synth path there if a
-- never-before-heard tone is needed.

return {

    -- Grind / room
    hand_resolved      = { kind = "beep",    volume = 0.4 },
    hand_won           = { kind = "chime",   volume = 0.6 },
    stake_unlocked     = { kind = "success", volume = 0.8 },
    upgrade_purchased  = { kind = "chime",   volume = 0.5 },

    -- Catalog / prestige
    pp_awarded         = { kind = "success", volume = 0.7 },
    item_placed        = { kind = "chime",   volume = 0.5 },

    -- Shove
    shove_initiated    = { kind = "horn",    volume = 0.8 },
    runout_resolved    = { kind = "beep",    volume = 0.6 },
    cheat_card_dealt   = { kind = "warning", volume = 0.7 },
    gauntlet_lost      = { kind = "fail",    volume = 0.9 },
    gauntlet_won       = { kind = "success", volume = 1.0 },

}
