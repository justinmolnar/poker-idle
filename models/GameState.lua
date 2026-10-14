-- models/GameState.lua
--
-- The single root model for player progression. Two halves:
--   meta-side: chips, owned_items, the counters (persist forever)
--   run-side:  bankroll, run upgrades, the open tables (wiped on prestige)
--
-- Persistence is three lists, further down: META_KEYS, RUN_KEYS and
-- RUNTIME_KEYS. Between them they must name every field the constructor
-- sets, and sim/verify_save_roundtrip fails when one is missing — which
-- is what stops a new field being silently left out of the save.
--
-- There are no migrations. A save from another version of the game is
-- refused whole by services/SaveService rather than coerced into this one.

local Constants      = require("data.constants")
local Decks          = require("models.Decks")
local StakesData     = require("data.stakes")
local GameTypesData  = require("data.game_types")
local DeckSpecs      = require("data.decks")
local EffectKinds    = require("data.effects").kinds

local function genSaveId()
    return string.format("%d_%05d", os.time(), math.random(10000, 99999))
end

local GameState = {}
GameState.__index = GameState

-- ── Construction ────────────────────────────────────────────────────

function GameState:new(saved)
    local instance = setmetatable({}, GameState)

    -- Meta-side defaults (persisted forever).
    instance.chips       = Constants.GAMEPLAY.INITIAL_CHIP
    instance.owned_items = {}
    instance.cleared     = false   -- true once the gauntlet is beaten — gates the credits screen on boot
    instance.shove_r1_won = false  -- true once the player has won at least Runout 1 of the shove gauntlet
    instance.shove_r2_won = false  -- true once the player has won at least Runout 2 of the shove gauntlet
    instance.demo_ended   = false  -- the demo: true once its first R1 win has been played out (states/ShoveState)
    instance.anti_chips  = 0
    instance.corrupted_items = {}
    -- Item ids whose COMING SOON sticker the player has physically peeled off.
    -- An item that meets its unlock condition keeps wearing the sticker until
    -- this happens: the reveal is a thing you do, not a thing that happens to
    -- you while you are looking elsewhere. Owned items never show one, so no
    -- migration is needed for saves made before peeling existed.
    instance.peeled_items    = {}
    instance.ultra_unlocked = false
    instance.onboarded   = false   -- true once the intro how-to-play modal has been dismissed
    instance.catalog_seen = false  -- true once the post-shove catalog has opened — gates the top-bar CATALOG button
    -- Tutorial hints already delivered (hint id → true). Meta-side so a
    -- prestige doesn't re-teach; see controllers/HintController.lua.
    instance.hints_seen = {}
    -- How many times the catalog has been thrown onto the felt. It lived
    -- inside hints_seen as a number among booleans, which made that field
    -- impossible to type.
    instance.catalog_throws = 0
    -- Entries per screen the player has entered (room, credits, ...). Meta,
    -- so a first-visit hint stays first-visit across runs. Bumped by the
    -- state's :enter, read by the `screen_visits` hint kind.
    -- Story beats the House has finished telling (beat id → true), plus
    -- "shove:<id>" for his once-lines on the felt. Meta-side: a beat is
    -- heard once per save, never once per run. See controllers/StoryDirector.
    instance.story_seen = {}
    -- Beats whose trigger has passed but which haven't played yet (beat
    -- id → true). A trigger can be transient (briefly affordable), so the
    -- director latches it here the moment it passes; cleared when the
    -- beat finishes. Persisted so a latched lesson survives a reload.
    instance.story_armed = {}
    -- Analytics identity. save_id is stable for the lifetime of a save slot;
    -- shove_count increments each prestige so analytics can track power level.
    instance.save_id    = genSaveId()
    instance.shove_count = 0
    -- True once the player has actually SHOVED. Distinct from shove_count,
    -- which counts run resets (resetRun bumps it) and so is already 1 after a
    -- single quick-reset bail-out. The tutorial's "SHOVE hides until you have
    -- banked 3 {chip} on your first run" gate reads this, because reading
    -- shove_count let the rescue button reveal the shove without shoving.
    instance.has_shoved = false
    -- The net result of the first hand this save ever resolved (money).
    -- nil until it happens; the first_hand beats read its sign.
    instance.first_hand_delta = nil
    -- What the last shove banked and how it went; written when the
    -- gauntlet settles. The summary lines and the analytics read it, which
    -- they used to do from shove_pending — a record that has to be gone by
    -- then, because its presence is what sends a reload back into the shove.
    instance.last_shove = nil
    instance.first_hand_tier  = nil   -- its pot tier: small / medium / large / stack
    -- How often each item has fired (item_fired events, by catalog id):
    -- this run, and over the save's life. The room's card reads both.
    instance.item_fires_run   = {}
    instance.item_fires_life  = {}
    -- Heaters each item put on a table this run (on_status_applied, by the
    -- status's source item), and the run before's fires and heaters,
    -- frozen at resetRun for the shove's recap and the catalog card.
    instance.item_heaters_run = {}
    instance.last_item_run    = false
    -- Zoom-first opening (Constants.GTYPE_GATE): HU latches open the
    -- moment a second table is affordable (GrindController update);
    -- 6-max latches from owning the Desk Plant (invalidateEffects).
    -- Both meta-side and one-way, like has_shoved.
    instance.hu_unlocked      = false
    instance.six_max_unlocked = false
    -- Which game-type unlocks have had their tab fanfare, so the flash
    -- fires exactly once per save rather than once per session.
    instance.gtype_announced  = {}

    -- Deck-system meta state (persists forever; never reset by prestige).
    -- Only the starter (DeckSpecs[1]) is unlocked at fresh start. The
    -- rest gate behind play-progress milestones — see each spec's
    -- `unlock` field and Decks.checkPendingUnlocks (called from the
    -- controller after lifetime counters bump).
    local starter = DeckSpecs[1]
    instance.unlocked_decks = {}
    instance.deck_levels    = {}
    instance.deck_xp        = {}
    if starter then
        instance.unlocked_decks[1]      = starter.id
        instance.deck_levels[starter.id] = 0
        instance.deck_xp[starter.id]     = 0
    end
    instance.active_deck_id = starter and starter.id or nil
    -- Decks that opened and have not been looked at in the roster yet: the
    -- top-bar cell pulses while this is non-empty. Cleared when the roster
    -- opens. Persisted so a restart doesn't lose the nudge.
    instance.decks_unseen   = {}
    -- Catalog items bought and not yet seen in the room: the ROOM button
    -- pulses while this is non-empty; each pops in on the next visit.
    instance.room_unseen    = {}

    -- Hands resolved over the save's whole life, unconditional. The
    -- lifetime_* counters below only accrue once decks unlock; these
    -- always tick — they pace the tutorial hints.
    instance.total_hands_played  = 0
    -- Hands the player WON, as opposed to played. Nothing counted this
    -- before; the counter items ('every N hands won') are stateless and
    -- read it modulo N, so it has to be a running total that survives a
    -- reload rather than a per-run tally.
    instance.total_hands_won     = 0
    instance.total_denied_stacks = 0   -- stack wins whose {chip} bounty was already banked this run
    -- The rest of the ungated family. Catalog unlock gates read THESE, never
    -- the lifetime_* fields below: lifetime_* only start accruing once decks
    -- unlock (post-R1-win), so an Act 1 item gated on one would stay a
    -- silhouette until Act 2. Several deliberately mirror a lifetime_*
    -- counter — same event, no deck gate.
    instance.total_busts             = 0   -- cash tables busted (stack hit 0)
    instance.total_stack_losses      = 0   -- stack-tier LOSSES taken
    instance.total_stacks          = 0   -- stack-tier WINS hit
    instance.total_rebuys            = 0
    instance.total_upgrade_levels    = 0   -- run-upgrade levels bought, ever
    instance.total_hands_overwhelmed = 0   -- hands played over the focus cap
    instance.total_hands_at_4plus    = 0
    instance.total_chips_banked      = 0   -- sum of bounty AWARDS (lifetime_chips_banked counts events)
    instance.total_ko_wins          = 0   -- tournaments finished 1st
    instance.total_tilts             = 0   -- fresh tilt statuses suffered, lifetime
    instance.total_heaters           = 0   -- fresh heaters caught, lifetime (story: first_heat)
    instance.total_cursor_deals      = 0   -- DEAL clicks made by cursors, lifetime (cursor item gates)
    instance.cursor_defaults         = {}  -- the cursor DEAL / REBUY settings, for tables opened later
    instance.total_hands_by_gtype    = {}  -- game_type_id → hands resolved there

    -- Lifetime counters (persist forever; drive deck unlocks). Bumped
    -- by GrindController on each resolution. Read by deck_unlock_rules
    -- via the UnlockRegistry threshold-check kinds.
    instance.total_money_won         = 0   -- $ won, ever (Investor deck unlock)
    -- One-shot save migration flag for the 2026-09-03 stake break. A fresh
    -- game needs none, so it starts true; applySaved decides from the RAW
    -- save whether an old one has to run (see there).
    -- Same shape for the 2026-09 deck roster swap (retired ids pruned).

    -- Run-side defaults (wiped on prestige). A fresh game starts with
    -- NOTHING: the two dollars arrive when the House hands them over
    -- (story beat arrival, `grant = "loan"` → GameState:grantLoan).
    instance.bankroll            = 0
    instance.loan_fresh          = false   -- runtime: the readout climbs from 0
    instance.current_stake_id    = "s001"
    -- Stacking run upgrades: id → integer level. Absent / 0 = not owned.
    -- Each level applies the item's effect block once (see EffectsRegistry:applyN).
    instance.run_upgrade_levels  = {}
    -- Every open table's own record (models/Table:serialize), hand and
    -- all. This was sixteen parallel index-keyed arrays that between them
    -- still could not describe a hand in flight.
    instance.tables = {}
    for _ = 1, Constants.GAMEPLAY.INITIAL_ACTIVE_TABLES do
        instance.tables[#instance.tables + 1] = { stake_id = "s001", game_type_id = "zoom" }
    end
    instance.stakes_won_this_run = {}           -- set keyed by stake_id; locks in chip bounties per run
    instance.bounty_paid_this_run = {}          -- same keys: what the bounty actually PAID (a Trophy Shelf double, the first-bounty bonus)
    instance.chips_this_run      = 0            -- running counter for the prestige modal display
    instance.anti_stakes_won_this_run = {}
    instance.anti_chips_this_run      = 0
    -- The shove COMMIT record: { chips, anti_chips, outcomes? }. Set by
    -- GrindController:initiateShove the instant the button is clicked
    -- (chips banked and zeroed in the same write), outcomes filled by
    -- ShoveState:enter (the three runouts are rolled ONCE and persisted).
    -- While this is non-nil the run is spent: a save written from the
    -- shove screen reloads INTO the shove with the same rolled result,
    -- so closing the game there can neither re-bank the run's chips nor
    -- re-roll the gauntlet. Cleared by resetRun / the gauntlet-clear path.
    -- Set when a shove settles, cleared when the next run's starting
    -- perks are applied (the catalog dismissal, the credits, or the next
    -- grind entry after a quit). Exactly one of those gets there first.
    instance.perks_pending = nil
    instance.shove_pending       = nil
    -- Once-per-run catalog-item flags (Rubber Duck / Fridge / Copy Machine /
    -- Dogs Playing Poker). Reset each run; the item only fires its first time.
    instance.first_loss_voided_this_run       = false
    instance.first_stack_loss_voided_this_run = false
    instance.stakes_opened_this_run = {}
    instance.denied_copied_this_run           = false
    instance.first_bounty_this_run            = false
    instance.first_anti_this_run              = false   -- corrupted Fridge latch
    -- Run-scoped ratchets granted by procs (winning a tournament lifts
    -- every table for the rest of the run). Plain effect entries, applied
    -- through the same registry as everything else in computeEffects.
    instance.run_ratchets                     = {}
    -- Run-scoped sharp accumulated by the Framed Diploma's bank proc
    -- (data/procs.lua millennium_bank). Zoom tables opened mid-run collect
    -- this at open so "for the run" includes them.
    -- Hands resolved since a {chip} bounty last banked (0 on a banking
    -- hand). Run-scoped; drives the tutorial's shove-stall nudge.
    -- Total $ lost this run, and the value it froze at when the run ended.
    -- The Dishwasher seeds a percentage of the frozen figure into the next
    -- run's bankroll (see applyStartingPerks).
    instance.run_money_lost      = 0
    instance.last_run_money_lost = 0
    -- The Cereal Shelf seeds last run's biggest pot (first stake, or any).
    instance.run_biggest_pot_t1      = 0
    instance.run_biggest_pot         = 0
    instance.last_run_biggest_pot_t1 = 0
    instance.last_run_biggest_pot    = 0
    -- The rail's earn rate (GrindController:boardRate): what the run's
    -- hands have netted, over how many seconds the board was actually
    -- playing (story pauses and other screens excluded), and the $/min
    -- the last run froze at when it ended.
    instance.run_hand_net  = 0
    instance.run_elapsed   = 0
    instance.last_run_rate = 0
    instance.run_rate_trace = false   -- the earn-rate graph's buckets (GrindController:_tickRateTrace)

    -- Transient stat cache, recomputed lazily.
    instance.effects_cache = nil

    if saved then
        instance:applySaved(saved)
    end

    return instance
end

-- The House hands over the loan: the starting bankroll, once, when the
-- arrival beat says so. Idempotent: a replayed line (a save quit mid-beat)
-- never pays twice, and nothing is paid over money already on a table.
function GameState:grantLoan()
    local amount = Constants.GAMEPLAY.INITIAL_BANKROLL
    if (self.bankroll or 0) >= amount then return false end
    if self.tables and #self.tables > 0 then return false end
    self.bankroll   = amount
    self.loan_fresh = true
    return true
end

-- Wipes run-side fields back to defaults. Called by the prestige flow after
-- a gauntlet bust. Meta-side (chips, owned_items, cleared) is left untouched —
-- chips earned during the run were already banked to state.chips during play.
function GameState:resetRun()
    self.bankroll            = Constants.GAMEPLAY.INITIAL_BANKROLL
    self.loan_fresh          = true   -- the loan renews: the readout climbs from 0

    -- What each item did this run, frozen for the shove's recap and the
    -- catalog card ({ [id] = { fires, heaters } }), then started over.
    do
        local frozen = {}
        for id, n in pairs(self.item_fires_run or {}) do
            frozen[id] = { fires = n, heaters = (self.item_heaters_run or {})[id] or 0 }
        end
        for id, n in pairs(self.item_heaters_run or {}) do
            if not frozen[id] then frozen[id] = { fires = 0, heaters = n } end
        end
        self.last_item_run = next(frozen) and frozen or false
    end
    self.item_fires_run      = {}     -- the room's per-run fire counts start over
    self.item_heaters_run    = {}
    self.current_stake_id    = "s001"
    self.run_upgrade_levels  = {}
    self.tables = {}
    for _ = 1, Constants.GAMEPLAY.INITIAL_ACTIVE_TABLES do
        self.tables[#self.tables + 1] = { stake_id = "s001", game_type_id = "zoom" }
    end
    self.stakes_won_this_run = {}
    self.bounty_paid_this_run = {}
    self.chips_this_run      = 0
    self.anti_stakes_won_this_run = {}
    self.anti_chips_this_run      = 0
    self.shove_pending       = nil
    -- Any starting-perk debt belonged to the run being replaced. The
    -- shove's settle calls this and THEN marks the new one, so clearing
    -- here cannot eat its own flag.
    self.perks_pending       = nil
    self.first_loss_voided_this_run       = false
    self.first_stack_loss_voided_this_run = false
    self.stakes_opened_this_run   = {}   -- Bottle of Wine: once per stake per run
    self.denied_copied_this_run           = false
    self.first_bounty_this_run            = false
    self.first_anti_this_run              = false
    self.run_ratchets                     = {}
    -- Freeze the run's losses before wiping them — the Dishwasher spends
    -- the frozen figure at the next applyStartingPerks.
    self.last_run_money_lost = self.run_money_lost or 0
    self.run_money_lost      = 0
    self.last_run_biggest_pot_t1 = self.run_biggest_pot_t1 or 0
    self.last_run_biggest_pot    = self.run_biggest_pot or 0
    self.run_biggest_pot_t1      = 0
    self.run_biggest_pot         = 0
    -- The run's actual $/min, frozen for the rail tooltip's "last run".
    local secs = self.run_elapsed or 0
    self.last_run_rate = (secs > 0) and ((self.run_hand_net or 0) / (secs / 60)) or 0
    self.run_hand_net  = 0
    self.run_elapsed   = 0
    self.run_rate_trace = false
    self.effects_cache       = nil
    self.shove_count         = (self.shove_count or 0) + 1
end

-- Resets BOTH meta and run sides to fresh-game defaults: the player's
-- progress, entirely, so they can play through again from zero. Reached
-- only through main.lua's Game.newGame, which is the one wipe path — it
-- deletes the save file, resets every state and the story, rebuilds the
-- pool and writes the wiped state back out.
function GameState:wipeAll()
    self.chips       = Constants.GAMEPLAY.INITIAL_CHIP
    self.owned_items = {}
    self.cleared     = false
    self.shove_r1_won = false
    self.shove_r2_won = false
    self.demo_ended  = false
    self.anti_chips  = 0
    self.corrupted_items = {}
    self.peeled_items    = {}
    self.ultra_unlocked = false
    self.onboarded   = false
    self.catalog_seen = false
    self.hints_seen   = {}
    self.catalog_throws = 0
    self.last_shove   = nil
    self.story_seen   = {}
    self.story_armed  = {}
    self.item_fires_run  = {}
    self.item_fires_life = {}
    self.item_heaters_run = {}
    self.last_item_run    = false
    -- Deck state resets to starter-only with all unlock progress lost.
    -- Mirrors the fresh-:new defaults exactly.
    local starter = DeckSpecs[1]
    self.unlocked_decks = {}
    self.deck_levels    = {}
    self.deck_xp        = {}
    if starter then
        self.unlocked_decks[1]      = starter.id
        self.deck_levels[starter.id] = 0
        self.deck_xp[starter.id]     = 0
    end
    self.active_deck_id = starter and starter.id or nil
    self.decks_unseen   = {}
    self.room_unseen    = {}

    -- Lifetime counters reset too — the unlock conditions need a fresh
    -- start when the player wipes their game.
    self.total_hands_played             = 0
    self.total_hands_won                = 0
    self.total_denied_stacks            = 0
    self.total_money_won         = 0
    -- The ungated family the catalog gates read.
    self.total_busts             = 0
    self.total_stack_losses      = 0
    self.total_stacks          = 0
    self.total_rebuys            = 0
    self.total_upgrade_levels    = 0
    self.total_hands_overwhelmed = 0
    self.total_hands_at_4plus    = 0
    self.total_chips_banked      = 0
    self.total_ko_wins          = 0
    self.total_tilts             = 0
    self.total_heaters           = 0
    self.total_cursor_deals      = 0
    self.total_hands_by_gtype    = {}
    self.last_run_money_lost     = 0
    self.last_run_biggest_pot_t1 = 0
    self.last_run_biggest_pot    = 0

    -- New save identity — fresh game, fresh analytics file.
    self.save_id    = genSaveId()
    self.shove_count = 0
    self.has_shoved  = false
    -- The zoom-first gates start closed on a NEW GAME. Without this, an
    -- old session's flags survive wipeAll and the HU unlock beat fires
    -- before the player has done anything.
    self.hu_unlocked      = false
    self.six_max_unlocked = false
    self.gtype_announced  = {}
    self:resetRun()
    self.last_run_rate = 0   -- resetRun derives it from the wiped run; a fresh game has none
    -- A wiped game is a FRESH game: no money until the loan is handed over,
    -- and no first hand yet (the first_hand beats read these).
    self.bankroll   = 0
    self.loan_fresh = false
    self.first_hand_delta = nil
    self.first_hand_tier  = nil
    -- resetRun incremented shove_count to 1; wipeAll is shove 0 (first run).
    self.shove_count = 0
    self:markCatalogDirty()
end

-- Apply a loaded payload, `{ meta = ..., run = ... }`. Only the keys in
-- META_KEYS and RUN_KEYS are read; anything else in the file is ignored,
-- and any listed key the file lacks keeps the constructor default.
--
-- This is the whole load path. It used to be four hundred lines of
-- migrations: id remaps for renamed items, decks, game types and outcome
-- tiers, eight serialized field renames, three one-shot conversion flags
-- carried in the save forever, fifty-odd `or` defaults, and a NaN repair.
-- All of it existed to make a file from an older game load in a newer one.
-- Old files are now refused whole by services/SaveService, so none of it
-- has anything left to do.
function GameState:applySaved(saved)
    if type(saved) ~= "table" then return end
    local function apply(payload, keys)
        if type(payload) ~= "table" then return end
        for _, k in ipairs(keys) do
            local v = payload[k]
            if v ~= nil then self[k] = v end
        end
    end
    apply(saved.meta, GameState.META_KEYS)
    apply(saved.run,  GameState.RUN_KEYS)
    self.effects_cache = nil
end

-- ─── What is persisted ────────────────────────────────────────────────
--
-- Two lists, and they are the schema. A key here is saved; a key not here
-- is not. The constructor above sets the default for every one of them, so
-- a save that predates a key simply keeps the default and a key that is
-- dropped from the game stops being written the moment it leaves this list.
--
-- There is no migration machinery behind this any more. There used to be
-- thirty backfill and remap paths, sixty-one id-map entries and three
-- one-shot flags carried in the save forever, all so a file from a
-- different game could be coerced into this one. A save from another
-- version is now refused whole (services/SaveService), which is the honest
-- version of what those paths were pretending to do.
--
-- RUNTIME_KEYS is the third category: fields the constructor sets that are
-- deliberately NOT saved. Listing them is what lets the round-trip check
-- (sim/verify_save_roundtrip) prove that every field is one of the three,
-- so a new field cannot be silently forgotten by the save.

-- What the items did in the run just played, most active first, at most
-- `n` rows: { id, fires, heaters }. Reads the live run while it still has
-- counts (the shove's summary shows before the run is settled), else the
-- frozen last run.
function GameState:itemRecap(n)
    local rows = {}
    local live = self.item_fires_run or {}
    if next(live) or next(self.item_heaters_run or {}) then
        for id, f in pairs(live) do
            rows[#rows + 1] = { id = id, fires = f, heaters = (self.item_heaters_run or {})[id] or 0 }
        end
        for id, h in pairs(self.item_heaters_run or {}) do
            if not live[id] then rows[#rows + 1] = { id = id, fires = 0, heaters = h } end
        end
    elseif self.last_item_run then
        for id, e in pairs(self.last_item_run) do
            rows[#rows + 1] = { id = id, fires = e.fires or 0, heaters = e.heaters or 0 }
        end
    end
    table.sort(rows, function(a, b)
        if a.fires + a.heaters ~= b.fires + b.heaters then return a.fires + a.heaters > b.fires + b.heaters end
        return a.id < b.id
    end)
    for i = #rows, (n or #rows) + 1, -1 do rows[i] = nil end
    return rows
end

GameState.META_KEYS = {
    -- identity and progress
    "save_id", "shove_count", "has_shoved", "onboarded", "catalog_seen",
    "cleared", "chips", "anti_chips",
    -- the catalog
    "owned_items", "corrupted_items", "peeled_items", "item_fires_life",
    -- acts and gates
    "shove_r1_won", "shove_r2_won", "ultra_unlocked", "demo_ended",
    "hu_unlocked", "six_max_unlocked", "gtype_announced",
    -- decks
    "unlocked_decks", "deck_levels", "deck_xp", "active_deck_id", "decks_unseen",
    -- the room, the story, the hints
    "room_unseen", "story_seen", "story_armed", "hints_seen", "catalog_throws",
    -- the first hand, for the story
    "first_hand_delta", "first_hand_tier",
    -- the last shove, for the summary lines and the analytics
    "last_shove",
    -- counters that gate catalog entries, decks and story beats
    "total_hands_played", "total_hands_won", "total_denied_stacks",
    "total_busts", "total_stack_losses", "total_stacks", "total_rebuys",
    "total_upgrade_levels", "total_hands_overwhelmed", "total_hands_at_4plus",
    "total_chips_banked", "total_ko_wins", "total_tilts", "total_heaters",
    "total_cursor_deals", "total_hands_by_gtype", "total_money_won",
    -- the cursor DEAL / REBUY settings, for tables opened later
    "cursor_defaults",
    -- what the last run left behind, for the starting perks
    "last_run_money_lost", "last_run_biggest_pot_t1", "last_run_biggest_pot",
    -- what the last run earned a minute, for the rail's earn-rate tooltip
    "last_run_rate",
    -- what each item did last run, for the shove's recap and the catalog
    "last_item_run",
}

GameState.RUN_KEYS = {
    "bankroll", "item_fires_run", "item_heaters_run", "run_upgrade_levels",
    -- every open table, hand and all (models/Table:serialize)
    "tables",
    "stakes_won_this_run", "bounty_paid_this_run", "chips_this_run",
    "anti_stakes_won_this_run", "anti_chips_this_run",
    "shove_pending", "perks_pending",
    "first_loss_voided_this_run", "first_stack_loss_voided_this_run",
    "stakes_opened_this_run",
    "denied_copied_this_run", "first_bounty_this_run", "first_anti_this_run",
    "run_ratchets", "run_money_lost", "run_biggest_pot_t1", "run_biggest_pot",
    -- the rail's earn rate: hand winnings and seconds on the felt this run
    "run_hand_net", "run_elapsed",
    -- the earn-rate graph: the run's hand winnings in time buckets
    -- ({ w = seconds a bucket, t = seconds into the last, b = { net } })
    "run_rate_trace",
}

-- Set by the constructor, never saved.
--   effects_cache     rebuilt on demand from what is owned
--   loan_fresh        a one-frame flag telling the view to roll the bankroll
--                     readout up from zero rather than snap it
--   current_stake_id  written once and read by two views; never varies
GameState.RUNTIME_KEYS = { "effects_cache", "loan_fresh", "current_stake_id" }

local function collect(self, keys)
    local out = {}
    for _, k in ipairs(keys) do out[k] = self[k] end
    return out
end

function GameState:serializeMeta() return collect(self, GameState.META_KEYS) end
function GameState:serializeRun()  return collect(self, GameState.RUN_KEYS)  end

-- ── Stat rollup via EffectsRegistry ─────────────────────────────────
-- Computes the player's current effective stats by walking owned items
-- and run upgrades through the EffectsRegistry. NO if/elseif on item ids
-- or effect kinds — pure data + registry dispatch.
--
-- `registry` is the EffectsRegistry; `catalog` and `run_upgrades` are the
-- data tables (passed in instead of required so this stays testable).
-- `exclude` (optional) is a set of ids — catalog items, decks, run
-- upgrades — to leave out of the rollup. It exists so the payout
-- breakdown can price a single source by computing the world without it
-- (models/payout_breakdown.lua). A probe like that must never be cached:
-- effects_cache is only written for the real, complete rollup.
function GameState:computeEffects(registry, catalog, run_upgrades, transient_params, exclude)
    local ctx = {}
    if transient_params then
        for k, v in pairs(transient_params) do
            ctx[k] = v
        end
    end

    -- Act-3 gate exposed to the rollup so shove_rate.compute (which only
    -- receives ctx + bankroll) can force the mult to 0 / underflow-999.
    ctx.shove_r2_won = self.shove_r2_won or false

    -- Pass 1: seed owned_set from explicit owned_items, plus any
    -- `granted_at_start` phantoms (handicap, future debuffs).
    local owned_set = {}
    for _, id in ipairs(self.owned_items) do owned_set[id] = true end
    for _, item in ipairs(catalog) do
        if item.granted_at_start then
            owned_set[item.id] = true
        end
    end

    local corrupted_set = {}
    if self.corrupted_items then
        for _, id in ipairs(self.corrupted_items) do corrupted_set[id] = true end
    end

    -- Pass 2: apply effects. `removed_by` is enforced HERE, uniformly —
    -- it doesn't matter whether the entry got into owned_set via owned_items
    -- or via granted_at_start. (The retired handicap used removed_by to
    -- switch itself off the moment its cure was owned.) Engine-neutral
    -- mechanism — handicaps / debuffs / anti-perks lift to a service unchanged.
    -- ctx.sources[kind] = { item_id, ... }: which owned items put each
    -- effect kind on the ctx. Read when an effect fires in play, so the
    -- item can be heard (and later seen) doing its job. Data only.
    ctx.sources = {}
    local function noteSources(item_id, effects)
        for _, eff in ipairs(effects or {}) do
            if eff.kind then
                local list = ctx.sources[eff.kind]
                if not list then list = {}; ctx.sources[eff.kind] = list end
                list[#list + 1] = item_id
            end
        end
    end
    local n_items = 0
    for _, item in ipairs(catalog) do
        if owned_set[item.id]
           and not (exclude and exclude[item.id])
           and not (item.removed_by and owned_set[item.removed_by]) then
            if item.cost_chip and item.cost_chip > 0 then n_items = n_items + 1 end
            if corrupted_set[item.id] and item.corrupt and item.corrupt.effects then
                local temp_item = { effects = item.corrupt.effects }
                registry:applyAll(temp_item, ctx)
                noteSources(item.id, item.corrupt.effects)
            else
                registry:applyAll(item, ctx)
                noteSources(item.id, item.effects)
            end
        end
    end

    -- Corkboard: so much more win chance per item owned, everywhere.
    if (ctx.odds_per_item or 0) > 0 and n_items > 0 then
        local add = ctx.odds_per_item * n_items
        if (ctx.odds_per_item_cap or 0) > 0 then add = math.min(add, ctx.odds_per_item_cap) end
        ctx.win_chance_shifts = ctx.win_chance_shifts or {}
        ctx.win_chance_shifts[#ctx.win_chance_shifts + 1] = { amount = add }
    end

    -- Decks stack: every unlocked deck contributes its banked passive at
    -- the current level via the same registry pipeline. Active vs.
    -- inactive doesn't matter here — only XP accrual cares about that.
    -- Gated on the system unlock (first gauntlet clear) so the stat ctx
    -- carries no deck passives before decks exist.
    if Decks.systemUnlocked(self) then
        -- Total deck levels feeds the master deck's shove-base capability
        -- (ctx.shove_base). Seeded before applyEffects so the applicator
        -- reads it. Transient — not persisted.
        ctx.total_deck_levels = Decks.totalLevels(self)
        Decks.applyEffects(self, registry, ctx, exclude)
    end

    -- Run upgrades stack: each level applies the item's effect block once.
    -- additive applicators sum to N×value, multiplicative to value^N.
    -- The Investor deck scales every upgrade's strength by
    -- run_upgrade_strength_mult. How to scale a field is data (each kind's
    -- `scale` in data/effects.lua) — no dispatch on the kind string here.
    local upgrade_mult = ctx.run_upgrade_strength_mult or 1.0
    for _, item in ipairs(run_upgrades) do
        local lvl = self.run_upgrade_levels[item.id] or 0
        -- Never more applications than the upgrade has levels: a save
        -- from before a ladder was shortened (Cursor twelve to five) keeps
        -- its number until the run resets, but it only ever counts to the
        -- max.
        if item.max_level and lvl > item.max_level then lvl = item.max_level end
        if exclude and exclude[item.id] then lvl = 0 end
        if lvl > 0 then
            if upgrade_mult ~= 1.0 then
                local scaled_effects = {}
                for _, e in ipairs(item.effects) do
                    local copy = {}
                    for k, v in pairs(e) do copy[k] = v end
                    local kind_meta = EffectKinds[copy.kind]
                    local scale     = kind_meta and kind_meta.scale
                    if scale == "integer" or scale == "fill" then
                        -- +1 focus / +1 cursor stays +1: a scaled integer
                        -- is floored downstream and reads as nothing. A
                        -- fill level stays one unit: the multiplier is
                        -- applied to the per-level gain in the outcome
                        -- model, so MAX stays where the level count is.
                    elseif copy.strength then
                        copy.strength = copy.strength * upgrade_mult
                    elseif copy.value then
                        if scale == "value_mult1" then
                            copy.value = (copy.value - 1) * upgrade_mult + 1
                        else
                            copy.value = copy.value * upgrade_mult
                        end
                    end
                    table.insert(scaled_effects, copy)
                end
                local temp_item = { effects = scaled_effects }
                registry:applyN(temp_item, ctx, lvl)
            else
                registry:applyN(item, ctx, lvl)
            end
        end
    end

    -- Run ratchets: permanent-for-this-run effects a proc granted. Plain
    -- effect entries, so they go through the registry like anything else.
    for _, entry in ipairs(self.run_ratchets or {}) do
        registry:apply(entry, ctx)
    end

    -- Only the complete rollup is the cache. A leave-one-out probe would
    -- otherwise poison every later read with a world missing an item.
    if not exclude then self.effects_cache = ctx end
    return ctx
end

-- Spend chips on a catalog item: validates affordability + non-duplicate +
-- requires-prereq, applies the mutation, invalidates the effects cache.
-- Whether an owned item is corrupted (corrupted_items is an array of ids).
-- Bumped whenever the catalog side of the save changes (bought, corrupted,
-- peeled, wiped, loaded). Views and caches that are keyed on "what the
-- player owns" read it instead of re-deriving sets every frame; the
-- corrupted lookup below invalidates off the same event.
function GameState:markCatalogDirty()
    self.owned_rev      = (self.owned_rev or 0) + 1
    self._corrupted_set = nil
end

-- Was a linear scan of corrupted_items, called from the frame: per catalog
-- card, per room item, per item-stream spawn. The set is derived lazily and
-- rebuilt when the list's length moves or markCatalogDirty fires, so a
-- missed invalidation upstream still cannot serve a stale answer for a
-- list that grew.
function GameState:isCorrupted(id)
    local list = self.corrupted_items
    if not list then return false end
    local set = self._corrupted_set
    if not set or self._corrupted_n ~= #list then
        set = {}
        for _, cid in ipairs(list) do set[cid] = true end
        self._corrupted_set = set
        self._corrupted_n   = #list
    end
    return set[id] == true
end

-- The things you own, in the order you bought them: every owned catalog
-- item that counts toward the shove's BASE (a nonzero shove_rate_add) and
-- is not removed by something else you own. #list is the number the
-- shove's count reaches and the room screen prints. `catalog` is the
-- data/catalog list (the model does not require data).
-- Cached on the catalog revision: the room screen prints this count every
-- frame, and deriving it walks the whole catalog building two maps and then
-- scans every owned item's effects.
function GameState:countedItems(catalog)
    local rev = self.owned_rev or 0
    local c = self._counted_cache
    if c and c.rev == rev and c.catalog == catalog then return c.ids end
    local ids = self:_buildCountedItems(catalog)
    self._counted_cache = { rev = rev, catalog = catalog, ids = ids }
    return ids
end

function GameState:_buildCountedItems(catalog)
    local by_id = {}
    for _, item in ipairs(catalog or {}) do by_id[item.id] = item end
    local owned_set = {}
    for _, id in ipairs(self.owned_items or {}) do owned_set[id] = true end
    local ids = {}
    for _, id in ipairs(self.owned_items or {}) do
        local item = by_id[id]
        if item and not (item.removed_by and owned_set[item.removed_by]) then
            local rate = 0
            for _, eff in ipairs(item.effects or {}) do
                if eff.kind == "shove_rate_add" then rate = eff.value or 0 end
            end
            if rate > 0 then ids[#ids + 1] = id end
        end
    end
    return ids
end

-- Returns true on success. Centralised so both grind-time and post-bust
-- catalog UIs route through one mutation point — no view mutates state.chips
-- directly. Caller-side concerns (sound, ctx recompute) remain on the
-- caller; this is just the model-side guarded write.
function GameState:tryBuyCatalogItem(item)
    if not item or item.cost_chip == nil then return false end
    for _, owned_id in ipairs(self.owned_items) do
        if owned_id == item.id then return false end
    end
    if item.requires then
        local met = false
        for _, owned_id in ipairs(self.owned_items) do
            if owned_id == item.requires then met = true; break end
        end
        if not met then return false end
    end
    if self.chips < item.cost_chip then return false end
    self.chips = self.chips - item.cost_chip
    self.owned_items[#self.owned_items + 1] = item.id
    self.room_unseen = self.room_unseen or {}
    self.room_unseen[#self.room_unseen + 1] = item.id   -- delivered on the next room visit
    self.effects_cache = nil
    self:markCatalogDirty()
    return true
end

-- Spend anti-chips on corrupting a catalog item: validates owned + corruptible +
-- affordable + not already corrupted, applies the mutation, invalidates cache.
function GameState:tryCorruptItem(item)
    if not item or not item.corrupt or item.corrupt.cost_achip == nil then return false end
    -- Must own the item first
    local owned = false
    for _, owned_id in ipairs(self.owned_items) do
        if owned_id == item.id then owned = true; break end
    end
    if not owned then return false end
    -- Must not already be corrupted
    for _, corrupted_id in ipairs(self.corrupted_items) do
        if corrupted_id == item.id then return false end
    end
    -- Must afford in anti-chips
    if self.anti_chips < item.corrupt.cost_achip then return false end

    self.anti_chips = self.anti_chips - item.corrupt.cost_achip
    self.corrupted_items[#self.corrupted_items + 1] = item.id
    self.effects_cache = nil
    self:markCatalogDirty()
    return true
end

-- Set the active deck for XP-accrual purposes. Validates that `id` is in
-- the player's unlocked_decks list. Returns true on success. Centralised
-- so the deck-select view stays out of the model's internals.
function GameState:setActiveDeck(id)
    if not id or not self.unlocked_decks then return false end
    for _, owned_id in ipairs(self.unlocked_decks) do
        if owned_id == id then
            self.active_deck_id = id
            return true
        end
    end
    return false
end

-- Apply meta-progression catalog perks that fire at run start.
-- Called by the prestige flow AFTER :resetRun() has cleared run state but
-- BEFORE the controller rebuilds the table pool. Reads the catalog-only
-- ctx (run_upgrade_levels is empty post-reset, so only owned_items feed in).
--
-- Recognized fields:
--   ctx.start_bankroll_add  — added to the fresh INITIAL_BANKROLL (flat $)
--   ctx.start_bankroll_pct  — additive % on the post-add bankroll (Lucky Coin)
--   ctx.start_table_count   — N s001:six_max tables auto-seeded (free)
--   ctx.start_upgrade_levels — { upgrade id = levels } already on the rack (Calculator)
--   ctx.loss_recycle_pct    — % of LAST run's losses seeded back (Dishwasher)
--
-- Order: flat add applies first, then the percentage multiplies the result.
-- "+$5 + 50%" on a $2 base = ($2 + $5) × 1.5 = $10.50, not $2 + $5 + $1 = $8.
-- The loss recycle lands last, so Lucky Coin's percentage doesn't compound
-- against a late-game run's losses.
--
-- Idempotency: this is meant to be called once per resetRun. Calling it
-- twice would double-apply, so don't.
-- Returns the effect kinds that did something, in order, so the caller
-- can announce them (the items are heard doing their job).
function GameState:applyStartingPerks(ctx)
    local fired = {}
    if (ctx.start_bankroll_add or 0) > 0 then
        self.bankroll = self.bankroll + ctx.start_bankroll_add
        fired[#fired + 1] = "start_bankroll_add"
    end
    if (ctx.start_bankroll_pct or 0) > 0 then
        self.bankroll = self.bankroll * (1 + ctx.start_bankroll_pct)
        fired[#fired + 1] = "start_bankroll_pct"
    end
    if (ctx.loss_recycle_pct or 0) > 0 and (self.last_run_money_lost or 0) > 0 then
        self.bankroll = self.bankroll
                        + (self.last_run_money_lost or 0) * ctx.loss_recycle_pct
        fired[#fired + 1] = "loss_recycle_pct"
    end
    -- Cereal Shelf: last run's biggest pot, at the first stake ("t1") or
    -- at any stake ("any", the corrupt read).
    if ctx.start_biggest_pot then
        local seed = (ctx.start_biggest_pot == "any") and (self.last_run_biggest_pot or 0)
                     or (self.last_run_biggest_pot_t1 or 0)
        if seed > 0 then
            self.bankroll = self.bankroll + seed
            fired[#fired + 1] = "start_biggest_pot"
        end
    end
    -- Each free table is a random T1 CASH game — the Desk seats you
    -- somewhere, it doesn't always deal you 6-max. Tournaments excluded:
    -- a free KO seat is a different promise than a free cash table.
    local cash_gtypes = {}
    for _, gt in ipairs(GameTypesData) do
        -- Only modes the player has actually unlocked (zoom-first gates,
        -- Constants.GTYPE_GATE) — the Desk must not deal a table from a
        -- mode the player hasn't met.
        local gate = Constants.GTYPE_GATE and Constants.GTYPE_GATE[gt.id]
        local open = (not gate) or self[gate] == true
        if not gt.chip_stack_table and open then
            cash_gtypes[#cash_gtypes + 1] = gt.id
        end
    end
    for _ = 1, (ctx.start_table_count or 0) do
        local gid = "zoom"   -- the always-open mode
        if #cash_gtypes > 0 and love and love.math then
            gid = cash_gtypes[love.math.random(1, #cash_gtypes)]
        end
        self.tables[#self.tables + 1] = { stake_id = "s001", game_type_id = gid }
    end
    if (ctx.start_table_count or 0) > 0 then fired[#fired + 1] = "start_table_count" end
    -- Calculator: the first levels of the named upgrades are already
    -- bought. Granted, not purchased: no counter moves, no money leaves.
    local granted = false
    for id, n in pairs(ctx.start_upgrade_levels or {}) do
        if (self.run_upgrade_levels[id] or 0) < n then
            self.run_upgrade_levels[id] = n
            granted = true
        end
    end
    if granted then fired[#fired + 1] = "start_upgrade_levels" end
    return fired
end

return GameState
