-- data/constants.lua
--
-- Tunable numbers, scoped namespaces. NO logic — only values.
-- Anything that the player or designer might want to tweak lives here.

local C = {}

-- Master build-mode preset. Toggling this flips every entry in
-- C.FEATURES below. New systems should each declare their own flag in
-- C.FEATURES and reference it directly — don't add new branches on
-- C.PROTOTYPE_MODE.
--
-- Things that always run regardless of this flag: auto-save, the title
-- screen, the dealer-always-cheats outcome.
C.PROTOTYPE_MODE = false

-- Per-feature flags. Default values follow C.PROTOTYPE_MODE; override an
-- individual entry below the assignment if you need a non-default mix
-- for testing (e.g. develop the deck system with HIGH_TIER_STAKES = true
-- but DEMO_CUT still on so the modal-end is still wired up).
C.FEATURES = {
    -- Demo cut. Hard-stops the gauntlet at win-R1/lose-R2 with the
    -- Prototype Complete modal; suppresses the R2/R3 cinematic; collapses
    -- the result-chip strip to a single slot. The three coordinated
    -- effects exist together — flipping individual pieces produces
    -- broken UI (e.g. modal off + single-slot = no end + no R2 reveal).
    DEMO_CUT          = C.PROTOTYPE_MODE,

    -- Show T4-T6 stakes in the grind view's add-table buttons. Existing
    -- T4-T6 tables in a save still render; this only gates the +ADD-TABLE
    -- buttons.
    HIGH_TIER_STAKES  = not C.PROTOTYPE_MODE,

    -- Wire the developer hotkeys (F2/F6/F7/backtick/-/=, H/J in grind,
    -- R/[/]/D in shove). Off in shipping builds.
    DEV_HOTKEYS       = not C.PROTOTYPE_MODE,

    -- Deck system. Off in the prototype build (the demo cut wraps before
    -- the long-tail progression that decks live on); on in the dev build
    -- where the full roster + unlock gating live.
    DECKS             = not C.PROTOTYPE_MODE,
}

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
    -- Dev HUD over the shove view. Shows r1/r2/r3, session win-rate
    -- aggregates, the hotkey legend. Off by default — it spoils the
    -- gauntlet's three-runout structure and the dealer's two cheats by
    -- exposing every internal in plain text. Press `D` in shove mode to
    -- bring it back for development / debugging.
    SHOW_DEBUG_OVERLAY = false,
}

C.GAMEPLAY = {
    INITIAL_BANKROLL       = 2,        -- starting $ each run (just barely covers a $0.01/$0.02 buy-in)
    INITIAL_PP             = 0,        -- meta currency starts at zero
    INITIAL_ACTIVE_TABLES  = 0,        -- fresh save / resetRun: no tables opened. Player buys first for the buy-in ($2 at $0.01/$0.02).
    -- The old 0.90 shove-rate soft cap is gone. Shove rate now multi-
    -- plies catalog × bankroll-tier (see models/shove_rate.lua) with a
    -- single math-reality clamp at 1.0. The curve is the ceiling.
    MAX_TABLES             = 32,       -- hard cap on concurrent tables (visual / sanity bound)

    -- Focus / efficiency mechanic. Multi-tabling beyond your capacity scales
    -- the per-hand $ delta down — split attention costs you value. Upgrades
    -- raise the capacity (focus_capacity_add) and / or reduce the per-extra
    -- penalty (focus_penalty_reduce_mult) so larger multi-tabling becomes
    -- viable as the player progresses.
    FOCUS_BASE_CAPACITY    = 4,        -- below this many tables, no penalty
    FOCUS_BASE_PENALTY     = 0.15,     -- per extra table over capacity (5 over → floor)
    FOCUS_FLOOR            = 0.05,     -- floor on focus_mult; running too many is actively bad
    -- PP_AWARD_DIVISOR removed — PP comes from per-stake first-win bounties,
    -- not from a peak-bankroll formula on bust.
}

C.GAUNTLET = {
    CARD_DEAL_INTERVAL  = 0.35,     -- seconds between successive card flips during a runout
    RUNOUT_PAUSE        = 1.2,      -- pause after a runout resolves before the next deals
    CHEAT_REVEAL_PAUSE  = 1.8,      -- extra pause before the cheat card slides in (runouts 2/3)
    REJECTION_RETRY_CAP = 500,      -- max joint-construction retries (deal hole+5-board AND find satisfying c6/c7) before accepting natural outcome
    CARD_BACK_SPRITE    = "cards/backs/06-nature",  -- shown on hole cards during deal, before runout 1 reveal (02-castle is .gif which LÖVE can't decode)
}

C.SAVE = {
    AUTOSAVE_INTERVAL = 30,         -- seconds between auto-save ticks
    META_FILE         = "meta.save",
    RUN_FILE          = "run.save",
    SETTINGS_FILE     = "settings.save",
    VERSION           = 1,
}

C.FLOATING_TEXT = {
    DURATION   = 1.6,               -- seconds visible
    DRIFT_Y    = -42,                -- pixels rise over duration
    MAX_ITEMS  = 50,
}

return C
