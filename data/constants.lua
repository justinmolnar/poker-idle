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
    INITIAL_BANKROLL       = 2,        -- starting $ each run (just barely covers a $0.01/$0.02 buy-in)
    INITIAL_PP             = 0,        -- meta currency starts at zero
    INITIAL_ACTIVE_TABLES  = 0,        -- fresh save / resetRun: no tables opened. Player buys first for the buy-in ($2 at $0.01/$0.02).
    SHOVE_RATE_CAP         = 0.90,     -- 90% per-shove ceiling (design doc §)
    MAX_TABLES             = 32,       -- hard cap on concurrent tables (visual / sanity bound)

    -- Focus / efficiency mechanic. Multi-tabling beyond your capacity scales
    -- the per-hand $ delta down — split attention costs you value. Upgrades
    -- raise the capacity (focus_capacity_add) and / or reduce the per-extra
    -- penalty (focus_penalty_reduce_mult) so larger multi-tabling becomes
    -- viable as the player progresses.
    FOCUS_BASE_CAPACITY    = 4,        -- below this many tables, no penalty
    FOCUS_BASE_PENALTY     = 0.05,     -- per extra table over capacity
    FOCUS_FLOOR            = 0.05,     -- floor on focus_mult; running too many is actively bad
    -- PP_AWARD_DIVISOR removed — PP comes from per-stake first-win bounties,
    -- not from a peak-bankroll formula on bust.
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
