-- data/sounds.lua
--
-- Named sound presets. Each entry is one of:
--   { file = "path",                  volume = v }   single file
--   { files = { "p1", "p2", ... },    volume = v }   random pick per play
--   { kind = "beep" | ...,            volume = v }   built-in synth
-- Any may carry `layer = { ...sub-entry... }` for a secondary sound played
-- alongside (e.g. coin rattle layered over a chip drop on a stack).
--
-- Every file comes from the uVegas Authentic Casino Chips & Cards Sounds pack
-- (54 WAVs recorded on a real felt poker table) or assets/audio/room and felt.
-- The legacy fanfare, game-over and buzz MP3s were dropped 2026-09-17: a win
-- is coins, a loss is one chip pitched down.

local expand = require("utils.sample_set")

local UVEGAS = "assets/audio/uVegas Authentic Casino Chips & Cards Sounds/"

-- ── Pack-rooted sample sets ─────────────────────────────────────────────
local CARD_GIVE        = expand(UVEGAS .. "Cards/Give/give_",                    10)
-- The deal and the flip are the same pack set split in two, so a card
-- turning over never sounds like a card landing: takes 1-7 deal, 8-10
-- (pitched down in the preset) flip.
local CARD_DEAL        = { CARD_GIVE[1], CARD_GIVE[2], CARD_GIVE[3], CARD_GIVE[4], CARD_GIVE[5], CARD_GIVE[6], CARD_GIVE[7] }
local CARD_FLIP        = { CARD_GIVE[8], CARD_GIVE[9], CARD_GIVE[10] }
local CARD_RIFFLE      = expand(UVEGAS .. "Cards/Shuffle/Riffle/riffle_",         5)
local CHIP_1ON1        = expand(UVEGAS .. "Chips/1on1/1on1_",                     5)
local CHIP_2ON1        = expand(UVEGAS .. "Chips/2on1/2on1_",                     5)
local CHIP_3ON2        = expand(UVEGAS .. "Chips/3on2/3on2_",                     5)
local CHIP_DROP_2      = expand(UVEGAS .. "Chips/Drops/2onStaple_",               3)
local CHIP_DROP_3      = expand(UVEGAS .. "Chips/Drops/3onStaple_",               3)
local CHIP_DROP_4      = expand(UVEGAS .. "Chips/Drops/4onStaple_",               3)
local COINS            = expand(UVEGAS .. "Coins/coins_",                         5)
-- Rendered from the pack's card deal (build-tools/render_felt_sounds.py):
-- the same sound degraded three ways, for the ending flood.
local FELT             = "assets/audio/felt/"
-- Freesound CC0 picks (tools/place_sounds.py; credited in each folder's MANIFEST).
local UI               = "assets/audio/ui/"

return {
    -- ── Mix rules (read by SoundService; not sound names) ─────────────
    _mix = {
        -- Nothing repeats identically: every play is detuned by up to this.
        pitch_jitter = 0.03,
        -- An item doing its job in play: its own sound, under the felt,
        -- and never the same sound twice within `min_gap` seconds (the
        -- cursor and clock items would otherwise chatter).
        item_fire = { volume = 0.55, min_gap = 0.2 },
        -- The damage bus. On for a corrupted item's sound, or for
        -- everything once the bankroll has underflowed. Cheap version
        -- that works everywhere: the pitch wanders, some plays drop out,
        -- the rest are quieter and dirtier. Where OpenAL EFX exists the
        -- distortion effect is layered on too.
        damage = {
            pitch_wobble = 0.18,    -- +/- pitch, random per play
            dropout      = 0.12,    -- chance a play is swallowed
            volume       = 0.8,
            efx = { type = "distortion", gain = 0.35, edge = 0.6, lowcut = 300, center = 2400, bandwidth = 2000 },
        },
        -- The focus strain. Over the focus cap the tables play slower and
        -- so does everything the player hears: every play drops in pitch
        -- toward pitch_min at the focus floor, and where OpenAL EFX exists
        -- the distortion below is sent in proportion to the amount. Fed
        -- from GrindController:focusStrain by main.lua each frame; the
        -- music takes the same number (services/MusicDirector).
        strain = {
            pitch_min = 0.5,
            efx = { type = "distortion", gain = 0.3, edge = 0.5, lowcut = 200, center = 2000, bandwidth = 2500 },
        },
    },


    -- ── Card events (deal beats + showdown flip) ────────────────────────
    -- The deal picks from the first seven gives; the flip from the last
    -- three, pitched down, louder, so the reveal is not the deal.
    -- min_gap: fires once per hand per table, so a wide grid of fast
    -- tables (or a cascade resolving several at once) would otherwise
    -- stack a dozen identical card sounds on the same frame.
    card_dealt          = { files = CARD_DEAL,    volume = 0.40, min_gap = 0.05 },
    hole_card_flip      = { files = CARD_FLIP,    volume = 0.55, pitch = 0.85 },

    -- ── Shove-state events ──────────────────────────────────────────────
    shove_initiated     = { files = CARD_RIFFLE,  volume = 0.70 },
    -- The cheat card is a card slapped on felt, not a chip: the heavier
    -- takes of the pack's deal, dry.
    cheat_card_dealt    = { files = CARD_GIVE,    volume = 0.95 },
    runout_won          = { files = COINS,        volume = 0.70 },
    -- The ending flood: the deal sound, degrading every dozen cards.
    deck_card_degraded_1 = { file = FELT .. "card_degraded_1.ogg", volume = 0.9 },
    deck_card_degraded_2 = { file = FELT .. "card_degraded_2.ogg", volume = 0.9 },
    deck_card_degraded_3 = { file = FELT .. "card_degraded_3.ogg", volume = 0.9 },
    -- The room's lights (assets/audio/room, credited in its MANIFEST):
    -- on = the switch with the tube coming on over it; off = the switch.
    lights_on           = { file = "assets/audio/room/light_switch.ogg", volume = 0.8,
                            layer = { file = "assets/audio/room/fluorescent.ogg", volume = 0.12 } },
    lights_off          = { file = "assets/audio/room/light_switch.ogg", volume = 0.8 },
    -- The win sting: coins, with a four-chip drop under them for the full
    -- clear. The loss: one chip pitched down, no jingle. The grind's
    -- tournament win and bust are the same two sounds by their own names.
    gauntlet_won        = { files = COINS,        volume = 0.80,
                            layer = { files = CHIP_DROP_4, volume = 0.60 } },
    gauntlet_lost       = { files = CHIP_1ON1,    volume = 0.70, pitch = 0.70 },
    tournament_won      = { files = COINS,        volume = 0.65,
                            layer = { files = CHIP_DROP_4, volume = 0.45 } },
    table_busted        = { files = CHIP_1ON1,    volume = 0.60, pitch = 0.70 },

    -- ── Pot resolution by tier (8 entries) ──────────────────────────────
    -- Controller passes pot_won_<tier> / pot_lost_<tier> at settling, where
    -- tier ∈ {small, medium, large, stack}. Magnitude scales chip-stack
    -- sample size: 1on1 → 2on1 → 3on2 → Drops/4onStaple. Stacks layer in
    -- coins (win) or the same drop pitched down to a thud (loss).
    -- Small pots are the overwhelming majority of resolutions on a fast
    -- mode; gap them so the win/loss cue stays a cue.
    pot_won_small        = { files = CHIP_1ON1,    volume = 0.55, min_gap = 0.05 },
    pot_won_medium       = { files = CHIP_2ON1,    volume = 0.60 },
    pot_won_large      = { files = CHIP_3ON2,    volume = 0.65 },
    pot_won_stack     = {
        files = CHIP_DROP_4, volume = 0.80,
        layer = { files = COINS, volume = 0.70 },
    },
    pot_lost_small       = { files = CHIP_1ON1,    volume = 0.40, min_gap = 0.05 },
    pot_lost_medium      = { files = CHIP_2ON1,    volume = 0.45 },
    pot_lost_large     = { files = CHIP_3ON2,    volume = 0.50 },
    pot_lost_stack    = {
        files = CHIP_DROP_4, volume = 0.30,
        layer = { files = CHIP_DROP_4, volume = 0.30, pitch = 0.70 },
    },

    -- ── Chip-flight arrival thunks (one per burst, fired by FlightSystem) ──
    -- Destination dictates the weight: pot/YOU = light click, bankroll = heavy.
    chip_land_pot       = { files = CHIP_1ON1,    volume = 0.25 },
    chip_land_you       = { files = CHIP_2ON1,    volume = 0.30 },
    chip_land_bankroll  = { files = CHIP_DROP_2,  volume = 0.45 },

    -- ── Cursor swarm (distinct from human mouse path) ───────────────────
    -- The button click, quiet: a cursor presses the same buttons you do.
    cursor_tap          = { file = UI .. "button_click.ogg", volume = 0.12, min_gap = 0.02 },

    -- ── Player-action feedback (purchases, rebuys, stake-ups, table adds) ─
    upgrade_purchased   = { files = CHIP_DROP_3,  volume = 0.60 },
    rebuy_clack         = { files = CHIP_DROP_2,  volume = 0.55 },
    -- A tournament knockout: a whole stack going in and dying. The
    -- heaviest drop in the set, one per eliminated seat.
    seat_ko             = { files = CHIP_DROP_3,  volume = 0.55 },
    stake_up_flourish   = {
        files = CHIP_DROP_4, volume = 0.65,
        layer = { files = COINS, volume = 0.55 },
    },
    table_added         = { files = CHIP_DROP_2,  volume = 0.50 },

    -- ── Juice-pass additions (J3/J4) ────────────────────────────────────
    -- card_snap fires once per individual card-deal animation (not once
    -- per state transition like card_dealt). Lower volume so 5×
    -- community-card snaps don't overwhelm the per-hand mix.
    card_snap           = { files = CARD_GIVE,    volume = 0.18 },
    -- ITEMS and BANK lifting off the room toward their slots: the whoosh.
    number_lift         = { file = "assets/audio/whoosh.mp3", volume = 0.50 },

    -- Border-pulse marker fires alongside the colored panel-border flash
    -- on every resolution. Tier-scaled volume (multiplier passed in at
    -- the call site so Small is barely audible, Stack is a full ding).
    border_pulse_win    = { files = CHIP_1ON1,    volume = 0.25 },
    border_pulse_loss   = { files = CHIP_DROP_2,  volume = 0.30 },

    -- ── Interface (assets/audio/ui) ─────────────────────────────────────
    -- One click for every press (services/ClickFlash.press).
    button_click        = { file = UI .. "button_click.ogg", volume = 0.35, min_gap = 0.03 },
    -- A modal, the glossary, a confirm, the book and the pamphlet.
    modal_open          = { file = UI .. "modal_open.ogg",   volume = 0.45, min_gap = 0.05 },
    modal_close         = { file = UI .. "modal_close.ogg",  volume = 0.45, min_gap = 0.05 },
    page_turn           = { file = UI .. "page_turn.ogg",    volume = 0.50 },
    -- ORDERED on a bought item; a corrupt purchase plays it damaged.
    stamp               = { file = UI .. "stamp.ogg",        volume = 0.60 },

    -- ── The felt and the grind (assets/audio/felt) ──────────────────────
    -- The book and the pamphlet landing on the felt in the shove.
    catalog_thud        = { file = FELT .. "catalog_thud.ogg", volume = 0.70 },
    flyer_slap          = { file = FELT .. "flyer_slap.ogg",   volume = 0.60 },
    -- Each step further over the focus cap (pitched down per step).
    focus_overload      = { file = FELT .. "focus_overload.ogg", volume = 0.50, min_gap = 0.25 },
    -- A heater as it appears on a table (with the fist, when a punch
    -- carried it). One per burst of tables, whatever the count.
    heater_lands        = { file = FELT .. "heater_lands.ogg", volume = 0.50, min_gap = 0.15 },
    -- A slam's fist landing; a neighbour shove plays it at half.
    punch               = { file = FELT .. "punch.ogg",        volume = 0.60, min_gap = 0.08 },
    -- A deck levelling up or unlocking.
    deck_up             = { file = FELT .. "deck_up.ogg",      volume = 0.55, min_gap = 0.3 },
    -- The Act 3 underflow, once.
    underflow           = { file = FELT .. "underflow.ogg",    volume = 0.80 },

    -- ── Clicks on things that already have a sound (data/clicks.lua) ────
    -- The other click_* names are files to place (assets/audio/ui), silent
    -- until then. A card flicked, a chip tapped, the House's intercom keyed.
    click_card          = { files = CARD_DEAL,   volume = 0.40, min_gap = 0.02 },
    click_chips         = { files = CHIP_1ON1,   volume = 0.45, min_gap = 0.02 },
    click_speaker       = { file = "assets/audio/radio/open/noise9.wav", volume = 0.35, min_gap = 0.08 },
}
