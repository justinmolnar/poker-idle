-- models/GameState.lua
--
-- The single root model for player progression. Holds the dual-slot state:
--   meta-side: chips, owned_items (persists forever)
--   run-side:  bankroll, current_stake_id, run_upgrade_levels (wiped on prestige)
--
-- Persistence is allowlist-driven: a new persistent field must be added to
-- serializeMeta()/serializeRun() by hand (AutoSerializer only handles the
-- LOAD side). TRANSIENTS lists the fields deliberately left out, and the
-- save suite's coverage test fails on any field in neither place.

local AutoSerializer = require("services.AutoSerializer")
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

-- ── Serializer declarations ─────────────────────────────────────────
-- TRANSIENTS: not persisted (computed/runtime caches, registry refs).
-- REFS:       entity references serialized as ids and resolved on load.
GameState.TRANSIENTS = {
    effects_cache     = true,  -- rolled-up stat ctx, recomputed from owned_items
    current_stake_id  = true,  -- runtime-only; persisted copies were never read back
    highest_stake_idx = true,  -- persisted as highest_stake_id (stable across ladder inserts)
}
GameState.REFS = {}         -- nothing yet — owned_items (list) and
                            -- run_upgrade_levels (id→level table) are already
                            -- AutoSerializer-compatible plain data

-- ── Construction ────────────────────────────────────────────────────

function GameState:new(saved)
    local instance = setmetatable({}, GameState)

    -- Meta-side defaults (persisted forever).
    instance.chips       = Constants.GAMEPLAY.INITIAL_CHIP
    instance.owned_items = {}
    instance.cleared     = false   -- true once the gauntlet is beaten — gates the credits screen on boot
    instance.shove_r1_won = false  -- true once the player has won at least Runout 1 of the shove gauntlet
    instance.shove_r2_won = false  -- true once the player has won at least Runout 2 of the shove gauntlet
    instance.anti_chips  = 0
    instance.corrupted_items = {}
    -- Item ids whose COMING SOON sticker the player has physically peeled off.
    -- An item that meets its unlock condition keeps wearing the sticker until
    -- this happens: the reveal is a thing you do, not a thing that happens to
    -- you while you are looking elsewhere. Owned items never show one, so no
    -- migration is needed for saves made before peeling existed.
    instance.peeled_items    = {}
    instance.ultra_unlocked = false
    instance.deck_overhaul_migrated = false -- true once the level-0, 5-level deck migration has run once
    instance.onboarded   = false   -- true once the intro how-to-play modal has been dismissed
    instance.catalog_seen = false  -- true once the post-shove catalog has opened — gates the top-bar CATALOG button (TUTORIAL builds)
    -- Tutorial hints already delivered (hint id → true). Meta-side so a
    -- prestige doesn't re-teach; see controllers/HintController.lua.
    instance.hints_seen = {}
    -- Entries per screen the player has entered (room, credits, ...). Meta,
    -- so a first-visit hint stays first-visit across runs. Bumped by the
    -- state's :enter, read by the `screen_visits` hint kind.
    instance.screen_visits = {}
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

    -- Hands resolved over the save's whole life, unconditional. The
    -- lifetime_* counters below only accrue once decks unlock; these
    -- always tick — they pace the tutorial hints.
    instance.total_hands_played  = 0
    -- Hands the player WON, as opposed to played. Nothing counted this
    -- before; the counter items ('every N hands won') are stateless and
    -- read it modulo N, so it has to be a running total that survives a
    -- reload rather than a per-run tally.
    instance.total_hands_won     = 0
    instance.total_big_outcomes  = 0   -- resolutions with a large/stack tier (wins AND losses)
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
    instance.total_tilts_absorbed    = 0   -- tilts a six-max took for a neighbour (Anchor deck)
    instance.total_hands_by_gtype    = {}  -- game_type_id → hands resolved there
    instance.highest_stake_idx       = 0   -- highest 1-based stake index ever played

    -- Lifetime counters (persist forever; drive deck unlocks). Bumped
    -- by GrindController on each resolution. Read by deck_unlock_rules
    -- via the UnlockRegistry threshold-check kinds.
    instance.lifetime_money_won             = 0
    instance.lifetime_money_lost            = 0
    instance.lifetime_stack_count         = 0
    instance.lifetime_ko_hands_won         = 0
    instance.lifetime_hands_played          = 0
    instance.lifetime_hands_at_4plus_tables = 0
    instance.lifetime_rebuys                = 0
    instance.lifetime_upgrades_bought       = 0
    instance.lifetime_hands_overwhelmed     = 0   -- hands played over the focus cap (Multitasker unlock)
    instance.lifetime_chips_banked          = 0   -- {chip} bounties banked, ever (Dogs Playing Poker unlock)
    -- One-shot save migration flag for the 2026-09-03 stake break. A fresh
    -- game needs none, so it starts true; applySaved decides from the RAW
    -- save whether an old one has to run (see there).
    instance.stake_break_migrated           = true
    -- Same shape for the 2026-09 deck roster swap (retired ids pruned).
    instance.deck_roster_migrated           = true

    -- Run-side defaults (wiped on prestige).
    instance.bankroll            = Constants.GAMEPLAY.INITIAL_BANKROLL
    instance.current_stake_id    = "s001"
    -- Stacking run upgrades: id → integer level. Absent / 0 = not owned.
    -- Each level applies the item's effect block once (see EffectsRegistry:applyN).
    instance.run_upgrade_levels  = {}
    -- active_table_specs: list of composite "<stake_id>:<game_type_id>"
    -- strings — one per active table. INITIAL_ACTIVE_TABLES = 0 by
    -- default (player buys their first table for the buy-in).
    instance.active_table_specs = {}
    for _ = 1, Constants.GAMEPLAY.INITIAL_ACTIVE_TABLES do
        instance.active_table_specs[#instance.active_table_specs + 1] = "s001:zoom"
    end
    -- Parallel array to active_table_specs — cursor mute flag per table.
    -- Indexed identically; true = autonomous cursor swarm skips this table.
    -- Persisted across saves; reset on prestige (since tables die anyway).
    instance.active_table_mutes        = {}
    -- Same shape — per-table rebuy-mute. Only consulted when the catalog
    -- perk `cursor_rebuy_unlocked` is owned.
    instance.active_table_rebuy_mutes  = {}
    -- Parallel arrays to active_table_specs — per-tournament-table state
    -- so a save mid-KO-sequence resumes at the right hand on reload.
    -- Both are runtime-resilient: cash-game tables write 0 / nil and
    -- ignore them on read.
    instance.active_table_ko_hands_won = {}
    -- Tournaments each table has completed (any finish). High Roller Pass
    -- derives its per-stake backing from these while the table stays open.
    instance.active_table_ko_finishes  = {}
    -- Most recent finish position per table (nil mid-run / cash) — keeps
    -- the FINISH readout on a settled tournament across a reload.
    instance.active_table_last_finish   = {}
    instance.active_table_ko_state     = {}
    -- Chip-stack tournament arrays (8-max KO). Each entry is per-seat
    -- (array indexed by script seat 1..n_seats) or a scalar. Cash tables
    -- store nil.
    instance.active_table_seat_stacks   = {}
    instance.active_table_seat_busted   = {}
    instance.active_table_player_seat   = {}
    instance.active_table_button_seat   = {}
    instance.active_table_bust_order    = {}
    -- Tournament plan (models/KoSession): the full pre-rolled
    -- finish_position + n_hands + bust schedule + per-hand outcome list.
    -- Persisted so a mid-tournament reload resumes at next_hand_idx and
    -- delivers the same finish position the plan committed to.
    instance.active_table_ko_plans     = {}
    -- Per-table stack value, so a chip-stack table's current $-stack
    -- (which can grow beyond 100bb as chips are won) survives reload.
    -- Cash tables write their stack here too; on reload they restore
    -- without re-charging the buy-in.
    instance.active_table_stack         = {}
    -- Which cell on the board each table occupies, packed row*100+col
    -- (models/table_grid.lua). The board is not derived from the table
    -- count any more: tables keep their cell when others come and go, and
    -- a closed table leaves a hole while the count still needs a board
    -- that size (the board repacks when it can shrink). A save without
    -- this array falls back to dense reading order, the pre-slot layout.
    instance.active_table_slot          = {}
    -- Live heaters / tilts per table (data/statuses.lua). Persisted so a
    -- reload doesn't silently wipe whatever is currently running.
    instance.active_table_statuses      = {}
    instance.stakes_won_this_run = {}           -- set keyed by stake_id; locks in chip bounties per run
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
    instance.shove_pending       = nil
    -- Once-per-run catalog-item flags (Rubber Duck / Fridge / Copy Machine /
    -- Dogs Playing Poker). Reset each run; the item only fires its first time.
    instance.first_loss_voided_this_run       = false
    instance.first_stack_loss_voided_this_run = false
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
    instance.zoom_sharp_banked                = 0
    -- Hands resolved since a {chip} bounty last banked (0 on a banking
    -- hand). Run-scoped; drives the tutorial's shove-stall nudge.
    instance.hands_since_last_bank = 0
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

    -- Transient stat cache, recomputed lazily.
    instance.effects_cache = nil

    if saved then
        instance:applySaved(saved)
    end

    return instance
end

-- Wipes run-side fields back to defaults. Called by the prestige flow after
-- a gauntlet bust. Meta-side (chips, owned_items, cleared) is left untouched —
-- chips earned during the run were already banked to state.chips during play.
function GameState:resetRun()
    self.bankroll            = Constants.GAMEPLAY.INITIAL_BANKROLL
    self.current_stake_id    = "s001"
    self.run_upgrade_levels  = {}
    self.active_table_specs = {}
    for _ = 1, Constants.GAMEPLAY.INITIAL_ACTIVE_TABLES do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:zoom"
    end
    self.active_table_mutes        = {}
    self.active_table_rebuy_mutes  = {}
    self.active_table_ko_hands_won = {}
    self.active_table_ko_finishes  = {}
    self.active_table_last_finish   = {}
    self.active_table_ko_state     = {}
    self.active_table_seat_stacks   = {}
    self.active_table_seat_busted   = {}
    self.active_table_player_seat   = {}
    self.active_table_button_seat   = {}
    self.active_table_bust_order    = {}
    self.active_table_ko_plans     = {}
    self.active_table_stack         = {}
    self.active_table_slot          = {}
    self.active_table_statuses      = {}
    self.stakes_won_this_run = {}
    self.chips_this_run      = 0
    self.anti_stakes_won_this_run = {}
    self.anti_chips_this_run      = 0
    self.shove_pending       = nil
    self.first_loss_voided_this_run       = false
    self.first_stack_loss_voided_this_run = false
    self.denied_copied_this_run           = false
    self.first_bounty_this_run            = false
    self.first_anti_this_run              = false
    self.run_ratchets                     = {}
    self.zoom_sharp_banked                = 0
    self.hands_since_last_bank = 0
    -- Freeze the run's losses before wiping them — the Dishwasher spends
    -- the frozen figure at the next applyStartingPerks.
    self.last_run_money_lost = self.run_money_lost or 0
    self.run_money_lost      = 0
    self.last_run_biggest_pot_t1 = self.run_biggest_pot_t1 or 0
    self.last_run_biggest_pot    = self.run_biggest_pot or 0
    self.run_biggest_pot_t1      = 0
    self.run_biggest_pot         = 0
    self.effects_cache       = nil
    self.shove_count         = (self.shove_count or 0) + 1
end

-- Resets BOTH meta and run sides to fresh-game defaults. Called from the
-- credits screen's reset action — wipes the player's progress entirely so
-- they can play through again from zero. Caller is responsible for
-- save_service:saveAll() afterwards to overwrite the disk slots.
function GameState:wipeAll()
    self.chips       = Constants.GAMEPLAY.INITIAL_CHIP
    self.owned_items = {}
    self.cleared     = false
    self.shove_r1_won = false
    self.shove_r2_won = false
    self.anti_chips  = 0
    self.corrupted_items = {}
    self.peeled_items    = {}
    self.ultra_unlocked = false
    self.onboarded   = false
    self.catalog_seen = false
    self.hints_seen   = {}
    self.screen_visits = {}
    self.story_seen   = {}
    self.story_armed  = {}
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

    -- Lifetime counters reset too — the unlock conditions need a fresh
    -- start when the player wipes their game.
    self.total_hands_played             = 0
    self.total_hands_won                = 0
    self.total_big_outcomes             = 0
    self.total_denied_stacks            = 0
    self.lifetime_money_won             = 0
    self.lifetime_money_lost            = 0
    self.lifetime_stack_count         = 0
    self.lifetime_ko_hands_won         = 0
    self.lifetime_hands_played          = 0
    self.lifetime_hands_at_4plus_tables = 0
    self.lifetime_rebuys                = 0
    self.lifetime_upgrades_bought       = 0
    self.lifetime_hands_overwhelmed     = 0
    self.lifetime_chips_banked          = 0
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
    self.total_tilts_absorbed    = 0
    self.total_hands_by_gtype    = {}
    self.highest_stake_idx       = 0
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
    -- resetRun incremented shove_count to 1; wipeAll is shove 0 (first run).
    self.shove_count = 0
end

-- Apply both meta and run payloads. Called from SaveService:loadAll wrapper
-- (saved = { meta = ..., run = ... }).
function GameState:applySaved(saved)
    -- Presence in the RAW save decides the promotions further down:
    -- AutoSerializer only writes keys the save actually has, and the
    -- constructor defaults are false, so a post-apply `== nil` test can
    -- never fire (the old guards were dead code).
    local had_has_shoved   = saved.meta ~= nil and saved.meta.has_shoved   ~= nil
    local had_catalog_seen = saved.meta ~= nil and saved.meta.catalog_seen ~= nil
    if saved.meta then
        AutoSerializer.apply(self, saved.meta, GameState.REFS, function() return nil end)
    end
    -- Backfill for saves from before the unseen-deck nudge (2026-09).
    if type(self.decks_unseen) ~= "table" then self.decks_unseen = {} end
    if saved.run then
        AutoSerializer.apply(self, saved.run, GameState.REFS, function() return nil end)
    end
    -- Identifiers renamed after saves went public: catalog item ids
    -- (data/catalog_id_migrations) and every other namespace
    -- (data/id_migrations: gtype, run_upgrade, deck, tier, field). Runs on
    -- every load and must stay idempotent. Ordering matters: this sits
    -- after AutoSerializer.apply (the raw keys are on self) and BEFORE the
    -- `or 0` backfills and the deck prune below, so a renamed key or id is
    -- carried across instead of being zeroed or dropped.
    do
        local Migrations   = require("data.catalog_id_migrations")
        local IdMigrations = require("data.id_migrations")

        -- An old id that is LIVE again in its data file must not be
        -- remapped: whiteboard and copy_machine were retired, mapped, and
        -- later reused for new items. The map keeps its lines (never
        -- remove one); the live check makes them inert.
        local function liveIds(list)
            local s = {}
            for _, e in ipairs(list) do s[e.id] = true end
            return s
        end
        local function remapListValues(list, map, live)
            if type(list) ~= "table" then return end
            for i, id in ipairs(list) do
                local new = map[id]
                if new and not live[id] then list[i] = new end
            end
        end
        local function remapKeys(tbl, map, live)
            if type(tbl) ~= "table" then return end
            for old, new in pairs(map) do
                if tbl[old] ~= nil and not live[old] then
                    if tbl[new] == nil then
                        tbl[new] = tbl[old]
                    elseif type(tbl[new]) == "number" and type(tbl[old]) == "number" then
                        tbl[new] = math.max(tbl[new], tbl[old])
                    end
                    tbl[old] = nil
                end
            end
        end

        -- Catalog items: owned, corrupted, and peeled (the sticker state
        -- was missed by the original loop, so a rename re-covered the card).
        local item_live = liveIds(require("data.catalog"))
        for _, key in ipairs{ "owned_items", "corrupted_items", "peeled_items" } do
            remapListValues(self[key], Migrations, item_live)
        end

        -- Serialized field names (meta or run): move the value, drop the
        -- old key. Same shape as the pp → chips block below. Whether the
        -- NEW key already holds a real value is decided from the raw save
        -- (the constructor defaults every field, so `self[new] == nil`
        -- would never be true and the old value would be dropped).
        local raw_meta, raw_run = saved.meta or {}, saved.run or {}
        for old, new in pairs(IdMigrations.field or {}) do
            if self[old] ~= nil then
                local raw_has_new = raw_meta[new] ~= nil or raw_run[new] ~= nil
                if not raw_has_new then self[new] = self[old] end
                self[old] = nil
            end
        end

        -- Game-type ids live inside "<stake>:<gtype>" composites (table
        -- specs and bounty keys) and as keys of two counters.
        local gmap = IdMigrations.gtype or {}
        if next(gmap) then
            local glive = liveIds(GameTypesData)
            local function remapSpec(spec)
                local stake_id, g = tostring(spec):match("^([^:]+):(.+)$")
                if stake_id and g and gmap[g] and not glive[g] then
                    return stake_id .. ":" .. gmap[g]
                end
                return spec
            end
            if type(self.active_table_specs) == "table" then
                for i, spec in ipairs(self.active_table_specs) do
                    self.active_table_specs[i] = remapSpec(spec)
                end
            end
            for _, key in ipairs{ "stakes_won_this_run", "anti_stakes_won_this_run" } do
                local t = self[key]
                if type(t) == "table" then
                    local moved = {}
                    for k, v in pairs(t) do
                        local nk = remapSpec(k)
                        if nk ~= k then moved[nk] = v; t[k] = nil end
                    end
                    for k, v in pairs(moved) do
                        if t[k] == nil then t[k] = v end
                    end
                end
            end
            remapKeys(self.total_hands_by_gtype, gmap, glive)
            remapKeys(self.gtype_announced,      gmap, glive)
        end

        -- Run-upgrade ids key the level table.
        local umap = IdMigrations.run_upgrade or {}
        if next(umap) then
            remapKeys(self.run_upgrade_levels, umap, liveIds(require("data.run_upgrades")))
        end

        -- Deck ids: the unlock list, the two progress tables, the active
        -- pointer. Must precede _migrateDeckState, which prunes unknowns.
        local dmap = IdMigrations.deck or {}
        if next(dmap) then
            local dlive = liveIds(DeckSpecs)
            remapListValues(self.unlocked_decks, dmap, dlive)
            remapKeys(self.deck_levels, dmap, dlive)
            remapKeys(self.deck_xp,     dmap, dlive)
            local a = self.active_deck_id
            if a and dmap[a] and not dlive[a] then self.active_deck_id = dmap[a] end
        end

        -- Outcome-tier keys ride inside saved tournament plans (per-hand
        -- outcomes) and pending shove outcomes as `tier` strings.
        local tmap = IdMigrations.tier or {}
        if next(tmap) then
            local function walk(v, depth)
                if type(v) ~= "table" or depth > 8 then return end
                if type(v.tier) == "string" and tmap[v.tier] then v.tier = tmap[v.tier] end
                for _, child in pairs(v) do walk(child, depth + 1) end
            end
            -- (the field map above has already moved any legacy-named plans here)
            walk(self.active_table_ko_plans, 0)
            walk(self.shove_pending, 0)
        end
    end
    self.effects_cache = nil

    -- Currency rename pp → chips (2026-05, post public launch). Old saves
    -- serialized pp / pp_this_run; remap so existing players keep their
    -- banked currency, then drop the stray legacy fields. Idempotent —
    -- new saves never set self.pp, so this no-ops after one rewrite.
    if self.pp ~= nil then self.chips = self.pp; self.pp = nil end
    if self.pp_this_run ~= nil then
        self.chips_this_run = self.pp_this_run; self.pp_this_run = nil
    end

    -- Migration pass: prior builds shipped a different deck roster
    -- (fish/acorns/patterns instead of the current seven). Drop unknown
    -- ids from unlocked_decks, prune their dangling level/xp entries,
    -- and ensure active_deck_id points at something real.
    if not self.deck_overhaul_migrated then
        self:_migrateDeckState()
        self.deck_overhaul_migrated = true
    end

    self.shove_r1_won                   = self.shove_r1_won or false
    self.shove_r2_won                   = self.shove_r2_won or false
    self.anti_chips                     = self.anti_chips or 0
    self.corrupted_items                = self.corrupted_items or {}
    self.peeled_items                   = self.peeled_items or {}
    self.ultra_unlocked                 = self.ultra_unlocked or false

    -- Lifetime counters added later than the deck-state fields. Older
    -- saves don't have them — backfill to 0 so unlock checks have a
    -- well-defined zero baseline.
    self.lifetime_money_won             = self.lifetime_money_won             or 0
    self.lifetime_money_lost            = self.lifetime_money_lost            or 0
    self.lifetime_stack_count         = self.lifetime_stack_count         or 0
    self.lifetime_ko_hands_won         = self.lifetime_ko_hands_won         or 0
    self.lifetime_hands_played          = self.lifetime_hands_played          or 0
    self.lifetime_hands_at_4plus_tables = self.lifetime_hands_at_4plus_tables or 0
    self.lifetime_rebuys                = self.lifetime_rebuys or 0
    self.lifetime_upgrades_bought       = self.lifetime_upgrades_bought or 0
    self.lifetime_hands_overwhelmed     = self.lifetime_hands_overwhelmed or 0
    self.lifetime_chips_banked          = self.lifetime_chips_banked or 0

    -- One-shot (2026-09-03 stake break): T4+ blinds and buy-ins moved
    -- (×100 per Act 2 stake, ×1000 per Act 3 stake) and the deck XP
    -- curves were re-denominated. Decided from the raw save: a save
    -- written before the flag existed has to migrate, a fresh game never
    -- does (constructor starts it true).
    --   • An open T4+ table saved at the old money can't be rebuilt at the
    --     new: its spec is retagged with a dead stake id so TablePool's
    --     unknown-stake path refunds the persisted stack and drops it.
    --   • Deck levels are kept; XP snaps to the current level's threshold
    --     in the new units so nobody is mid-bar on a curve that no longer
    --     exists.
    if not ((saved.meta or {}).stake_break_migrated) then
        local StakesData = require("data.stakes")
        local Lookups    = require("utils.lookups")
        for i, spec in ipairs(self.active_table_specs or {}) do
            local stake_id = type(spec) == "string" and spec:match("^([^:]+):") or nil
            local idx = stake_id and Lookups.indexById(StakesData, stake_id) or nil
            if idx and idx >= 4 then
                self.active_table_specs[i] = "retired_" .. spec
            end
        end
        for _, spec in ipairs(DeckSpecs) do
            local lvl = self.deck_levels and self.deck_levels[spec.id]
            if lvl and self.deck_xp then
                self.deck_xp[spec.id] = (lvl > 0 and spec.xp_curve[math.min(lvl, #spec.xp_curve)]) or 0
            end
        end
        self.stake_break_migrated = true
    end

    -- One-shot (2026-09 deck roster): six decks retired, six new. The
    -- original pruner (_migrateDeckState) is already consumed on every
    -- save, so retired ids would linger — inert for effects, but a retired
    -- ACTIVE deck would silently stop all XP. Prune, repair the active
    -- pointer, snap surviving XP to the current curve. Decided from the
    -- raw save; a fresh game starts the flag true.
    if not ((saved.meta or {}).deck_roster_migrated) then
        local known = {}
        for _, spec in ipairs(DeckSpecs) do known[spec.id] = true end
        local kept = {}
        for _, id in ipairs(self.unlocked_decks or {}) do
            if known[id] then kept[#kept + 1] = id end
        end
        self.unlocked_decks = kept
        for id in pairs(self.deck_levels or {}) do
            if not known[id] then self.deck_levels[id] = nil end
        end
        for id in pairs(self.deck_xp or {}) do
            if not known[id] then self.deck_xp[id] = nil end
        end
        if not (self.active_deck_id and known[self.active_deck_id]) then
            self.active_deck_id = self.unlocked_decks[1] or (DeckSpecs[1] and DeckSpecs[1].id) or nil
        end
        for _, spec in ipairs(DeckSpecs) do
            local lvl = self.deck_levels and self.deck_levels[spec.id]
            if lvl and self.deck_xp then
                self.deck_xp[spec.id] = (lvl > 0 and spec.xp_curve[math.min(lvl, #spec.xp_curve)]) or 0
            end
        end
        self.deck_roster_migrated = true
    end
    -- total_hands_played postdates the (gated) deck counters. Old saves
    -- accrued lifetime_hands_played ungated, so it's the best backfill.
    self.total_hands_played             = self.total_hands_played
                                          or self.lifetime_hands_played or 0
    -- Nothing ever counted wins, so there is no honest backfill: an old
    -- save starts this at zero and the counter items simply take a while
    -- to come round the first time.
    self.total_hands_won                = self.total_hands_won or 0
    self.total_big_outcomes             = self.total_big_outcomes    or 0
    self.total_denied_stacks            = self.total_denied_stacks   or 0
    -- Ungated counters added with the catalog expansion. The three that
    -- mirror a lifetime_* field backfill from it — an existing save already
    -- earned those, and the mirror only differs going forward (it keeps
    -- ticking before the deck gate opens, where lifetime_* does not).
    self.total_busts             = self.total_busts             or 0
    self.total_stack_losses      = self.total_stack_losses      or 0
    self.total_stacks          = self.total_stacks          or self.lifetime_stack_count or 0
    self.total_rebuys            = self.total_rebuys            or self.lifetime_rebuys or 0
    self.total_upgrade_levels    = self.total_upgrade_levels    or self.lifetime_upgrades_bought or 0
    self.total_hands_overwhelmed = self.total_hands_overwhelmed or self.lifetime_hands_overwhelmed or 0
    self.total_hands_at_4plus    = self.total_hands_at_4plus    or self.lifetime_hands_at_4plus_tables or 0
    self.total_chips_banked      = self.total_chips_banked      or 0
    self.total_ko_wins          = self.total_ko_wins          or 0
    self.total_tilts             = self.total_tilts             or 0
    self.total_heaters           = self.total_heaters           or 0   -- backfill: key added 2026-09
    self.total_cursor_deals      = self.total_cursor_deals      or 0   -- backfill: key added 2026-09
    self.total_tilts_absorbed    = self.total_tilts_absorbed    or 0   -- backfill: key added 2026-09
    self.total_hands_by_gtype    = self.total_hands_by_gtype    or {}
    self.highest_stake_idx       = self.highest_stake_idx       or 0
    self.run_money_lost          = self.run_money_lost          or 0
    self.last_run_money_lost     = self.last_run_money_lost     or 0
    self.run_biggest_pot_t1      = self.run_biggest_pot_t1      or 0
    self.run_biggest_pot         = self.run_biggest_pot         or 0
    self.last_run_biggest_pot_t1 = self.last_run_biggest_pot_t1 or 0
    self.last_run_biggest_pot    = self.last_run_biggest_pot    or 0
    self.hands_since_last_bank          = self.hands_since_last_bank or 0
    -- Analytics identity — backfill for saves predating this field.
    self.save_id    = self.save_id    or genSaveId()
    self.shove_count = self.shove_count or 0
    -- catalog_seen added with the tutorial redesign. A save that has
    -- shoved has been through the post-shove catalog — count it as seen
    -- so existing players keep their top-bar CATALOG button.
    -- Saves predating has_shoved: anything with a shove_count had almost
    -- certainly shoved, so keep their SHOVE button. Guarded on the key
    -- being ABSENT from the save rather than falsy, or a current save
    -- that merely quick-reset would be promoted every time it loads.
    if not had_has_shoved then
        self.has_shoved = (self.shove_count or 0) > 0
    end
    -- Saves PREDATING the game-type gates (no hu_unlocked key at all):
    -- anyone with shove progress had every mode open — never re-lock a
    -- table a player has already sat. Guarded on the key being ABSENT,
    -- exactly like had_has_shoved above: a save written UNDER the gate
    -- system keeps its false flags, or merely shoving would hand out
    -- 6-max without the Bonsai.
    if saved.meta ~= nil and saved.meta.hu_unlocked == nil then
        self.hu_unlocked      = self.has_shoved
        self.six_max_unlocked = self.has_shoved
    end
    self.hu_unlocked      = self.hu_unlocked == true
    self.six_max_unlocked = self.six_max_unlocked == true
    self.gtype_announced  = self.gtype_announced or {}
    -- ...and a mode that is ALREADY open gets no retroactive fanfare
    -- (three flourishes on load is noise, not news).
    for gtype_id, gate in pairs(Constants.GTYPE_GATE or {}) do
        if gate and self[gate] == true then
            self.gtype_announced[gtype_id] = true
        end
    end
    if not had_catalog_seen then
        self.catalog_seen = (self.shove_count or 0) > 0
    end
    -- highest stake rides in the save as an id; resolve to the runtime
    -- index (unlock gates compare numerically). Saves from before the
    -- rename carry the raw index and keep it as-is.
    if type(self.highest_stake_id) == "string" then
        for i, s in ipairs(StakesData) do
            if s.id == self.highest_stake_id then
                self.highest_stake_idx = i
                break
            end
        end
        self.highest_stake_id = nil
    end
    -- Saves predating the hint system start with an empty seen-set; no
    -- deeper migration needed — HintController silently retires any hint
    -- whose done-condition the save already satisfies.
    -- A NaN bankroll (a save written while a log of a negative bankroll
    -- was poisoning it) is repaired to the underflowed value in Act 3, the
    -- starting bankroll otherwise. NaN is the only number not equal to
    -- itself; a JSON round trip may also turn it into nil.
    if self.bankroll == nil or self.bankroll ~= self.bankroll then
        self.bankroll = self.shove_r2_won
            and ((Constants.GAMEPLAY.UNDERFLOW_THRESHOLD or -100000000000) - 1)
            or  Constants.GAMEPLAY.INITIAL_BANKROLL
    end
    self.hints_seen   = self.hints_seen   or {}
    -- The [i] info-hint queue is retired (teaching lives in story beats
    -- and the glossary). Drop anything an old save still carries.
    self.hints_queued = nil
    self.screen_visits = self.screen_visits or {}
    -- Saves predating the story hear each beat when its trigger next
    -- passes; that is the rule for every save, so no migration.
    self.story_seen    = self.story_seen or {}
    self.story_armed   = self.story_armed or {}
    self.anti_stakes_won_this_run = self.anti_stakes_won_this_run or {}
    self.anti_chips_this_run      = self.anti_chips_this_run or 0
    self.first_loss_voided_this_run       = self.first_loss_voided_this_run or false
    self.first_stack_loss_voided_this_run = self.first_stack_loss_voided_this_run or false
    self.denied_copied_this_run           = self.denied_copied_this_run or false
    self.first_bounty_this_run            = self.first_bounty_this_run or false
    self.first_anti_this_run              = self.first_anti_this_run or false
    self.run_ratchets                     = self.run_ratchets or {}
    self.zoom_sharp_banked                = self.zoom_sharp_banked or 0
end

-- Drop unknown deck ids from unlocked_decks / deck_levels / deck_xp and
-- repair active_deck_id if it points at an id no longer in the spec
-- list. Called from applySaved.
function GameState:_migrateDeckState()
    local known = {}
    for _, spec in ipairs(DeckSpecs) do known[spec.id] = true end

    if self.unlocked_decks then
        local kept = {}
        for _, id in ipairs(self.unlocked_decks) do
            if known[id] then kept[#kept + 1] = id end
        end
        self.unlocked_decks = kept
    else
        self.unlocked_decks = {}
    end

    -- The deck overhaul changed the level scheme (10 levels → 5, and a
    -- level-0 start). No shipped player has deck progress (decks ship OFF
    -- in the prototype build), so the safe, simple migration is to reset
    -- every surviving deck to L0 / 0 XP rather than reinterpret old
    -- levels against the new curve. The starter is re-seeded at L0.
    local starter = DeckSpecs[1]
    local has_starter = false
    if starter then
        for _, id in ipairs(self.unlocked_decks) do
            if id == starter.id then has_starter = true; break end
        end
        if not has_starter then
            self.unlocked_decks[#self.unlocked_decks + 1] = starter.id
        end
    end
    self.deck_levels = {}
    self.deck_xp     = {}
    for _, id in ipairs(self.unlocked_decks) do
        self.deck_levels[id] = 0
        self.deck_xp[id]     = 0
    end

    if not self.active_deck_id or not known[self.active_deck_id] then
        self.active_deck_id = self.unlocked_decks[1]
                              or (starter and starter.id)
                              or nil
    end
end

-- Serialize meta-only (chips, owned items, cleared flag, deck progression,
-- lifetime counters that drive unlock checks). For meta.save.
function GameState:serializeMeta()
    return {
        save_id                         = self.save_id,
        shove_count                     = self.shove_count,
        has_shoved                      = self.has_shoved,
        hu_unlocked                     = self.hu_unlocked,
        six_max_unlocked                = self.six_max_unlocked,
        gtype_announced                 = self.gtype_announced,
        chips                           = self.chips,
        owned_items                     = self.owned_items,
        cleared                         = self.cleared,
        shove_r1_won                    = self.shove_r1_won,
        shove_r2_won                    = self.shove_r2_won,
        anti_chips                      = self.anti_chips,
        corrupted_items                 = self.corrupted_items,
        peeled_items                    = self.peeled_items,
        ultra_unlocked                  = self.ultra_unlocked,
        deck_overhaul_migrated          = self.deck_overhaul_migrated,
        onboarded                       = self.onboarded,
        catalog_seen                    = self.catalog_seen,
        hints_seen                      = self.hints_seen,
        screen_visits                   = self.screen_visits,
        story_seen                      = self.story_seen,
        story_armed                     = self.story_armed,
        unlocked_decks                  = self.unlocked_decks,
        deck_levels                     = self.deck_levels,
        deck_xp                         = self.deck_xp,
        active_deck_id                  = self.active_deck_id,
        decks_unseen                    = self.decks_unseen,
        lifetime_money_won              = self.lifetime_money_won,
        lifetime_money_lost             = self.lifetime_money_lost,
        lifetime_stack_count          = self.lifetime_stack_count,
        lifetime_ko_hands_won          = self.lifetime_ko_hands_won,
        lifetime_hands_played           = self.lifetime_hands_played,
        lifetime_hands_at_4plus_tables  = self.lifetime_hands_at_4plus_tables,
        lifetime_rebuys                 = self.lifetime_rebuys,
        lifetime_upgrades_bought        = self.lifetime_upgrades_bought,
        lifetime_hands_overwhelmed      = self.lifetime_hands_overwhelmed,
        lifetime_chips_banked           = self.lifetime_chips_banked,
        stake_break_migrated            = self.stake_break_migrated,
        deck_roster_migrated            = self.deck_roster_migrated,
        total_hands_played              = self.total_hands_played,
        total_hands_won                 = self.total_hands_won,
        total_big_outcomes              = self.total_big_outcomes,
        total_denied_stacks             = self.total_denied_stacks,
        total_busts                     = self.total_busts,
        total_stack_losses              = self.total_stack_losses,
        total_stacks                  = self.total_stacks,
        total_rebuys                    = self.total_rebuys,
        total_upgrade_levels            = self.total_upgrade_levels,
        total_hands_overwhelmed         = self.total_hands_overwhelmed,
        total_hands_at_4plus            = self.total_hands_at_4plus,
        total_chips_banked              = self.total_chips_banked,
        total_ko_wins                  = self.total_ko_wins,
        total_tilts                     = self.total_tilts,
        total_heaters                   = self.total_heaters,
        total_cursor_deals              = self.total_cursor_deals,
        total_tilts_absorbed            = self.total_tilts_absorbed,
        total_hands_by_gtype            = self.total_hands_by_gtype,
        -- Persisted as the stake ID, not the positional index: inserting a
        -- stake mid-ladder must not silently re-gate every existing save.
        highest_stake_id                = (self.highest_stake_idx or 0) > 0
                                          and StakesData[self.highest_stake_idx]
                                          and StakesData[self.highest_stake_idx].id
                                          or nil,
        last_run_money_lost             = self.last_run_money_lost,
        last_run_biggest_pot_t1         = self.last_run_biggest_pot_t1,
        last_run_biggest_pot            = self.last_run_biggest_pot,
    }
end

-- Serialize run-only (bankroll, stake, run upgrades, active tables,
-- per-run chip bookkeeping). For run.save. Wiped on prestige by `clearRun()`.
function GameState:serializeRun()
    return {
        bankroll                   = self.bankroll,
        run_upgrade_levels         = self.run_upgrade_levels,
        active_table_specs         = self.active_table_specs,
        active_table_mutes         = self.active_table_mutes,
        active_table_rebuy_mutes   = self.active_table_rebuy_mutes,
        active_table_ko_hands_won = self.active_table_ko_hands_won,
        active_table_ko_finishes  = self.active_table_ko_finishes,
        active_table_last_finish   = self.active_table_last_finish,
        active_table_ko_state     = self.active_table_ko_state,
        active_table_seat_stacks   = self.active_table_seat_stacks,
        active_table_seat_busted   = self.active_table_seat_busted,
        active_table_player_seat   = self.active_table_player_seat,
        active_table_button_seat   = self.active_table_button_seat,
        active_table_bust_order    = self.active_table_bust_order,
        active_table_ko_plans     = self.active_table_ko_plans,
        active_table_stack         = self.active_table_stack,
        active_table_slot          = self.active_table_slot,
        active_table_statuses      = self.active_table_statuses,
        stakes_won_this_run        = self.stakes_won_this_run,
        chips_this_run             = self.chips_this_run,
        anti_stakes_won_this_run   = self.anti_stakes_won_this_run,
        anti_chips_this_run        = self.anti_chips_this_run,
        shove_pending              = self.shove_pending,
        first_loss_voided_this_run       = self.first_loss_voided_this_run,
        first_stack_loss_voided_this_run = self.first_stack_loss_voided_this_run,
        denied_copied_this_run           = self.denied_copied_this_run,
        first_bounty_this_run            = self.first_bounty_this_run,
        first_anti_this_run              = self.first_anti_this_run,
        run_ratchets                     = self.run_ratchets,
        zoom_sharp_banked                = self.zoom_sharp_banked,
        hands_since_last_bank      = self.hands_since_last_bank,
        run_money_lost             = self.run_money_lost,
        run_biggest_pot_t1         = self.run_biggest_pot_t1,
        run_biggest_pot            = self.run_biggest_pot,
    }
end

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
    for _, item in ipairs(catalog) do
        if owned_set[item.id]
           and not (exclude and exclude[item.id])
           and not (item.removed_by and owned_set[item.removed_by]) then
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
    self.effects_cache = nil
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
        self.active_table_specs[#self.active_table_specs + 1] = "s001:" .. gid
    end
    if (ctx.start_table_count or 0) > 0 then fired[#fired + 1] = "start_table_count" end
    return fired
end

return GameState
