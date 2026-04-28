-- data/constants.lua
--
-- Tunable numbers, scoped namespaces. NO logic — only values.
-- Anything that the player or designer might want to tweak lives here.

local C = {}

C.WINDOW = {
    title  = "Poker Idle",
    width  = 1280,
    height = 720,
}

C.DEBUG = {
    -- Set to true to boot directly into the shove screen.
    -- The MVP plan calls for shove to be prototyped first; this lets the
    -- skeleton route there immediately without needing a state-switch hotkey.
    START_IN_SHOVE = false,
    -- Always-on HUD during the shove prototype. Surfaces shove_rate, hotkey
    -- legend, attempt counter, per-runout pass rates so verification doesn't
    -- depend on the console. Toggled live with `D` in shove mode.
    SHOW_DEBUG_OVERLAY = true,
}

C.GAMEPLAY = {
    INITIAL_BANKROLL    = 100,         -- starting $ each run
    INITIAL_PP          = 0,           -- meta currency starts at zero
    SHOVE_RATE_CAP      = 0.90,        -- 90% per-shove ceiling (design doc §)
    MAX_TABLES          = 6,           -- hard cap on concurrent tables
    PP_AWARD_DIVISOR    = 50,          -- PP = floor(peak_bankroll / 50)
    SHOVE_MIN_BANKROLL  = 5,           -- can't shove with effectively-zero bankroll
}

C.GAUNTLET = {
    CARD_DEAL_INTERVAL  = 0.35,     -- seconds between successive card flips during a runout
    RUNOUT_PAUSE        = 1.2,      -- pause after a runout resolves before the next deals
    CHEAT_REVEAL_PAUSE  = 1.8,      -- extra pause before the cheat card slides in (runouts 2/3)
    REJECTION_RETRY_CAP = 500,      -- max joint-construction retries (deal hole+5-board AND find satisfying c6/c7) before accepting natural outcome
    CARD_BACK_SPRITE    = "cards/backs/03-fish",  -- shown on hole cards during deal, before runout 1 reveal
}

C.SAVE = {
    AUTOSAVE_INTERVAL = 30,         -- seconds between auto-save ticks
    META_FILE         = "meta.save",
    RUN_FILE          = "run.save",
    VERSION           = 1,
}

C.FLOATING_TEXT = {
    DURATION   = 1.6,               -- seconds visible
    DRIFT_Y    = -42,                -- pixels rise over duration
    MAX_ITEMS  = 50,
}

return C
