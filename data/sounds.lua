-- data/sounds.lua
--
-- Named sound presets. Each entry is either a file-based asset or a synth
-- kind handled procedurally by SoundService.
--
-- Schema (one of file or kind, not both):
--   {
--     file   = "assets/audio/<name>.mp3",   -- preferred when an asset exists
--     kind   = "beep" | "chime" | "warning" | "success" | "fail" | "horn",
--     volume = 0..1,                         -- per-sound mix
--   }
--
-- Shove assets lifted from 10000-games (sfx/games/memory + sfx/shared/default).
-- The grind-state sounds remain on synth for now — they'll get real assets
-- when grind tables ship.

return {

    -- Grind / room (still synth — placeholder pending grind feature work)
    hand_resolved      = { kind = "beep",    volume = 0.4 },
    hand_won           = { kind = "chime",   volume = 0.6 },
    stake_unlocked     = { kind = "success", volume = 0.8 },
    upgrade_purchased  = { kind = "chime",   volume = 0.5 },

    -- Catalog / prestige
    pp_awarded         = { kind = "success", volume = 0.7 },
    item_placed        = { kind = "chime",   volume = 0.5 },

    -- Shove (real audio files)
    shove_initiated    = { file = "assets/audio/shuffle.mp3",         volume = 0.7 },
    card_dealt         = { file = "assets/audio/whoosh.mp3",          volume = 0.4 },
    hole_card_flip     = { file = "assets/audio/flip_card.mp3",       volume = 0.7 },
    cheat_card_dealt   = { file = "assets/audio/impact_heavy.mp3",    volume = 0.85 },
    runout_won         = { file = "assets/audio/positive_ding.mp3",   volume = 0.7 },
    gauntlet_won       = { file = "assets/audio/victory_fanfare.mp3", volume = 1.0 },
    gauntlet_lost      = { file = "assets/audio/game_over.mp3",       volume = 0.85 },

}
