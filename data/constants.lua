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
}

C.GAMEPLAY = {
    INITIAL_BANKROLL = 100,         -- starting $ each run
    INITIAL_PP       = 0,           -- meta currency starts at zero
    SHOVE_RATE_CAP   = 0.90,        -- 90% per-shove ceiling (design doc §)
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
