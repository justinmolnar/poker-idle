-- data/constants.lua
--
-- Tunable numbers, scoped namespaces. NO logic — only values.
-- Anything that the player or designer might want to tweak lives here.

local C = {}

-- Build mode. false = the full game (dev default). true = the DEMO:
-- the same game, cut at the Act 1 cliffhanger — win Runout 1, forced
-- Runout 2 loss, demo-end modal. Continue loops Act 1 forever; the act
-- flags are never recorded, so nothing from Act 2+ (decks, mid/high
-- stakes, the act2 story beats) ever unlocks, and Act 2+ catalog items
-- are stripped at load.
--
-- Things that always run regardless of this flag: auto-save, the title
-- screen, the dealer-always-cheats outcome.
--
-- itch/web builds ship whatever is committed here — build_web.py is a
-- pure packager, it rewrites nothing. Set to true before building the
-- demo for itch.
C.DEMO = false

-- Per-feature flags derived from C.DEMO; override an individual entry
-- below the assignment if you need a non-default mix for testing.
C.FEATURES = {
    -- The demo cut. Hard-stops the gauntlet at the cliffhanger with the
    -- demo-end modal; suppresses the R2/R3 cinematic; collapses the
    -- result-chip strip to a single slot; keeps the act flags and the
    -- act-break milestone from being recorded. The coordinated effects
    -- exist together — flipping individual pieces produces broken UI.
    DEMO_CUT    = C.DEMO,

    -- Deck system. Belt over the real gate (the R1 win the demo never
    -- records); also keeps the top-bar DECK cell from reserving space.
    DECKS       = not C.DEMO,

    -- Wire the developer hotkeys (F2/F6/F7/backtick/-/=, H/J in grind,
    -- R/[/]/D in shove). Off in shipping builds.
    DEV_HOTKEYS = not C.DEMO,
}

-- Stake band → the state flag that unlocks it (false = always available).
-- Milestone-gated ladder: low is always on; mid opens on the first shove
-- win, high on the second, ultra once it's bought with anti-chips. The
-- demo never records the shove wins, so it ships low stakes only through
-- this same gate. Consumed by GrindController:stakeAvailable — the single
-- source of truth for which stakes the add-table UI offers.
C.STAKE_BAND_GATE = {
    low   = false,
    mid   = "shove_r1_won",
    high  = "shove_r2_won",
    ultra = "ultra_unlocked",
}

-- Which GAME TYPES the add-table UI offers, same shape as the band gate:
-- false = always open, a string = the GameState flag that opens it. The
-- opening is zoom-first — fast, un-stackable, click-to-deal — and the
-- other modes arrive as taught moments: HU when a second table is
-- affordable (the {chip} intro; hu_unlocked latches in GrindController),
-- 6-max after the first shove, the tournament room with Act 2. Consumed
-- by GrindController:gtypeAvailable — the single source of truth.
C.GTYPE_GATE = {
    zoom    = false,
    hu      = "hu_unlocked",
    six_max = "six_max_unlocked",   -- bought: the Desk Plant catalog item
    ko     = "shove_r1_won",
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
    -- Records every hand (duration, delta, tier, stake, game type) to
    -- hand_analytics.json on quit. Used to tune hand length vs. $/min.
    HAND_ANALYTICS = true,
}

C.GAMEPLAY = {
    INITIAL_BANKROLL       = 2,        -- starting $ each run (just barely covers a $0.01/$0.02 buy-in)
    INITIAL_CHIP           = 0,        -- meta currency (Gold Chips) starts at zero
    -- TUTORIAL builds: SHOVE (button + top-bar %) doesn't exist until the
    -- first-ever run has banked this many chips — the prestige reveals
    -- itself with something worth banking. Later runs are ungated.
    SHOVE_UNLOCK_CHIPS     = 3,
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
    UNDERFLOW_THRESHOLD    = -100000000000, -- Act 3 negative bankroll threshold to overflow
    -- CHIP_AWARD_DIVISOR removed — chips come from per-stake first-win
    -- bounties, not from a peak-bankroll formula on bust.
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
    -- Bumping VERSION no longer wipes saves: SaveService applies a
    -- mismatched file anyway; migrations are field-level in
    -- GameState:applySaved.
    VERSION           = 1,
}

C.FLOATING_TEXT = {
    DURATION   = 1.6,               -- seconds visible
    DRIFT_Y    = -42,                -- pixels rise over duration
    MAX_ITEMS  = 50,
}

C.HOVER = {
    -- Seconds the pointer must rest on a target before its hover
    -- treatment appears. Applies to TOOLTIPS (services/Tooltip's
    -- pointer-rest gate) and to big AREA-sized washes (the deal felt) —
    -- sweeping the mouse across the board must not fire a lightshow.
    -- Actual buttons highlight instantly (HoverService.is, or .rest with
    -- secs 0).
    DWELL = 0.25,
}

C.ANIMATIONS = {
    -- Frame rate (FPS) for isometric object ambient animations (room items & catalog previews).
    -- 4 FPS gives a relaxed, ambient, retro pixel-art cadence.
    DEFAULT_FPS = 4,
    ITEM_FPS    = {
        -- Optional per-item overrides (e.g. ["lava_lamp"] = 3)
    },
}

-- The shader a corrupted catalog item wears in the room (shaders/corrupted.frag).
C.CORRUPT_ROOM_SHADER = "corrupted"

return C
