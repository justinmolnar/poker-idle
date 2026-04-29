-- data/sounds.lua
--
-- Named sound presets. Each entry is one of:
--   { file = "path",                  volume = v }   single file
--   { files = { "p1", "p2", ... },    volume = v }   random pick per play
--   { kind = "beep" | ...,            volume = v }   built-in synth
-- Any may carry `layer = { ...sub-entry... }` for a secondary sound played
-- alongside (e.g. coin rattle layered over a chip drop on a jackpot).
--
-- Most files come from the uVegas Authentic Casino Chips & Cards Sounds pack
-- (54 WAVs recorded on a real felt poker table). The legacy fanfare /
-- game-over MP3s are kept where the pack has no equivalent.

local UVEGAS = "assets/audio/uVegas Authentic Casino Chips & Cards Sounds/"

-- Helper for the "<prefix>_NN.<ext>" sample-set pattern. Builds a list of N
-- file paths so playEntry can random-pick one per play.
local function expand(prefix, count, ext)
    ext = ext or "wav"
    local t = {}
    for i = 1, count do
        t[i] = string.format("%s%02d.%s", prefix, i, ext)
    end
    return t
end

-- ── Pack-rooted sample sets ─────────────────────────────────────────────
local CARD_GIVE        = expand(UVEGAS .. "Cards/Give/give_",                    10)
local CARD_RIFFLE      = expand(UVEGAS .. "Cards/Shuffle/Riffle/riffle_",         5)
local CHIP_1ON1        = expand(UVEGAS .. "Chips/1on1/1on1_",                     5)
local CHIP_2ON1        = expand(UVEGAS .. "Chips/2on1/2on1_",                     5)
local CHIP_3ON2        = expand(UVEGAS .. "Chips/3on2/3on2_",                     5)
local CHIP_DROP_2      = expand(UVEGAS .. "Chips/Drops/2onStaple_",               3)
local CHIP_DROP_3      = expand(UVEGAS .. "Chips/Drops/3onStaple_",               3)
local CHIP_DROP_4      = expand(UVEGAS .. "Chips/Drops/4onStaple_",               3)
local COINS            = expand(UVEGAS .. "Coins/coins_",                         5)

return {

    -- ── Card events (deal beats + showdown flip) ────────────────────────
    -- Both random-pick from the 10-sample give set; flip is louder so it
    -- stands out as the single per-hand cue.
    card_dealt          = { files = CARD_GIVE,    volume = 0.40 },
    hole_card_flip      = { files = CARD_GIVE,    volume = 0.55 },

    -- ── Shove-state events ──────────────────────────────────────────────
    shove_initiated     = { files = CARD_RIFFLE,  volume = 0.70 },
    cheat_card_dealt    = { files = CHIP_DROP_3,  volume = 0.85 },
    runout_won          = { files = COINS,        volume = 0.70 },
    -- Pack has no fanfare / game-over equivalents — keep the legacy assets.
    gauntlet_won        = { file  = "assets/audio/victory_fanfare.mp3", volume = 1.0  },
    gauntlet_lost       = { file  = "assets/audio/game_over.mp3",       volume = 0.85 },

    -- ── Pot resolution by tier (8 entries) ──────────────────────────────
    -- Controller passes pot_won_<tier> / pot_lost_<tier> at settling, where
    -- tier ∈ {tiny, small, medium, jackpot}. Magnitude scales chip-stack
    -- sample size: 1on1 → 2on1 → 3on2 → Drops/4onStaple. Jackpots layer in
    -- coins (win) or the legacy buzz (loss) for emphasis.
    pot_won_tiny        = { files = CHIP_1ON1,    volume = 0.55 },
    pot_won_small       = { files = CHIP_2ON1,    volume = 0.60 },
    pot_won_medium      = { files = CHIP_3ON2,    volume = 0.65 },
    pot_won_jackpot     = {
        files = CHIP_DROP_4, volume = 0.80,
        layer = { files = COINS, volume = 0.70 },
    },
    pot_lost_tiny       = { files = CHIP_1ON1,    volume = 0.40 },
    pot_lost_small      = { files = CHIP_2ON1,    volume = 0.45 },
    pot_lost_medium     = { files = CHIP_3ON2,    volume = 0.50 },
    pot_lost_jackpot    = {
        files = CHIP_DROP_4, volume = 0.70,
        layer = { file = "assets/audio/negative_buzz.mp3", volume = 0.55 },
    },

    -- ── Chip-flight arrival thunks (one per burst, fired by ChipFlightSystem) ─
    -- Destination dictates the weight: pot/YOU = light click, bankroll = heavy.
    chip_land_pot       = { files = CHIP_1ON1,    volume = 0.25 },
    chip_land_you       = { files = CHIP_2ON1,    volume = 0.30 },
    chip_land_bankroll  = { files = CHIP_DROP_2,  volume = 0.45 },

    -- ── Cursor swarm (distinct from human mouse path) ───────────────────
    cursor_tap          = { files = CHIP_1ON1,    volume = 0.18 },

    -- ── Player-action feedback (purchases, rebuys, stake-ups, table adds) ─
    upgrade_purchased   = { files = CHIP_DROP_3,  volume = 0.60 },
    rebuy_clack         = { files = CHIP_DROP_2,  volume = 0.55 },
    stake_up_flourish   = {
        files = CHIP_DROP_4, volume = 0.65,
        layer = { files = COINS, volume = 0.55 },
    },
    table_added         = { files = CHIP_DROP_2,  volume = 0.50 },

    -- ── Legacy synth entries (no current call sites; left in place for
    --    future polish wiring without re-defining the names).
    hand_resolved       = { kind = "beep",    volume = 0.40 },
    hand_won            = { kind = "chime",   volume = 0.60 },
    stake_unlocked      = { kind = "success", volume = 0.80 },
    pp_awarded          = { kind = "success", volume = 0.70 },
    item_placed         = { kind = "chime",   volume = 0.50 },

    -- ── Aliases used by older call sites (kept so nothing breaks if we
    --    forget to update one) — both fall through to the medium tier.
    pot_won             = { files = CHIP_2ON1,    volume = 0.60 },
    pot_lost            = { files = CHIP_2ON1,    volume = 0.45 },

}
