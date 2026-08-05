-- models/GameState.lua
--
-- The single root model for player progression. Holds the dual-slot state:
--   meta-side: chips, owned_items (persists forever)
--   run-side:  bankroll, current_stake_id, run_upgrade_levels (wiped on prestige)
--
-- AutoSerializer-driven. Adding a new persistent field = adding the field;
-- everything that's not in TRANSIENTS or REFS saves automatically.

local AutoSerializer = require("services.AutoSerializer")
local Constants      = require("data.constants")
local Decks          = require("models.Decks")
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
    effects_cache = true,   -- rolled-up stat ctx, recomputed from owned_items
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
    -- Triggered-but-unread info hints (id list, queue order) — the [i]
    -- strip. Persisted so an unread hint survives a reload.
    instance.hints_queued = {}
    -- Analytics identity. save_id is stable for the lifetime of a save slot;
    -- shove_count increments each prestige so analytics can track power level.
    instance.save_id    = genSaveId()
    instance.shove_count = 0

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

    -- Hands resolved over the save's whole life, unconditional. The
    -- lifetime_* counters below only accrue once decks unlock; these
    -- always tick — they pace the tutorial hints.
    instance.total_hands_played  = 0
    instance.total_big_outcomes  = 0   -- resolutions with a large/jackpot tier (wins AND losses)
    instance.total_denied_stacks = 0   -- jackpot wins whose {chip} bounty was already banked this run
    -- The rest of the ungated family. Catalog unlock gates read THESE, never
    -- the lifetime_* fields below: lifetime_* only start accruing once decks
    -- unlock (post-R1-win), so an Act 1 item gated on one would stay a
    -- silhouette until Act 2. Several deliberately mirror a lifetime_*
    -- counter — same event, no deck gate.
    instance.total_busts             = 0   -- cash tables busted (stack hit 0)
    instance.total_stack_losses      = 0   -- jackpot-tier LOSSES taken
    instance.total_jackpots          = 0   -- jackpot-tier WINS hit
    instance.total_rebuys            = 0
    instance.total_upgrade_levels    = 0   -- run-upgrade levels bought, ever
    instance.total_hands_overwhelmed = 0   -- hands played over the focus cap
    instance.total_hands_at_4plus    = 0
    instance.total_chips_banked      = 0   -- sum of bounty AWARDS (lifetime_chips_banked counts events)
    instance.total_mtt_wins          = 0   -- tournaments finished 1st
    instance.total_hands_by_gtype    = {}  -- game_type_id → hands resolved there
    instance.highest_stake_idx       = 0   -- highest 1-based stake index ever played

    -- Lifetime counters (persist forever; drive deck unlocks). Bumped
    -- by GrindController on each resolution. Read by deck_unlock_rules
    -- via the UnlockRegistry threshold-check kinds.
    instance.lifetime_money_won             = 0
    instance.lifetime_money_lost            = 0
    instance.lifetime_jackpot_count         = 0
    instance.lifetime_mtt_hands_won         = 0
    instance.lifetime_hands_played          = 0
    instance.lifetime_hands_at_4plus_tables = 0
    instance.lifetime_rebuys                = 0
    instance.lifetime_upgrades_bought       = 0
    instance.lifetime_hands_overwhelmed     = 0   -- hands played over the focus cap (Multitasker unlock)
    instance.lifetime_chips_banked          = 0   -- {chip} bounties banked, ever (Dogs Playing Poker unlock)

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
        instance.active_table_specs[#instance.active_table_specs + 1] = "s001:six_max"
    end
    -- Parallel array to active_table_specs — cursor mute flag per table.
    -- Indexed identically; true = autonomous cursor swarm skips this table.
    -- Persisted across saves; reset on prestige (since tables die anyway).
    instance.active_table_mutes        = {}
    -- Same shape — per-table rebuy-mute. Only consulted when the catalog
    -- perk `cursor_rebuy_unlocked` is owned.
    instance.active_table_rebuy_mutes  = {}
    -- Parallel arrays to active_table_specs — per-tournament-table state
    -- so a save mid-MTT-sequence resumes at the right hand on reload.
    -- Both are runtime-resilient: cash-game tables write 0 / nil and
    -- ignore them on read.
    instance.active_table_mtt_hands_won = {}
    instance.active_table_mtt_state     = {}
    -- Chip-stack tournament arrays (8-max KO). Each entry is per-seat
    -- (array indexed by script seat 1..n_seats) or a scalar. Cash tables
    -- store nil.
    instance.active_table_seat_stacks   = {}
    instance.active_table_seat_busted   = {}
    instance.active_table_player_seat   = {}
    instance.active_table_button_seat   = {}
    instance.active_table_bust_order    = {}
    -- Tournament plan (models/MttSession): the full pre-rolled
    -- finish_position + n_hands + bust schedule + per-hand outcome list.
    -- Persisted so a mid-tournament reload resumes at next_hand_idx and
    -- delivers the same finish position the plan committed to.
    instance.active_table_mtt_plans     = {}
    -- Per-table stack value, so a chip-stack table's current $-stack
    -- (which can grow beyond 100bb as chips are won) survives reload.
    -- Cash tables write their stack here too; on reload they restore
    -- without re-charging the buy-in.
    instance.active_table_stack         = {}
    instance.stakes_won_this_run = {}           -- set keyed by stake_id; locks in chip bounties per run
    instance.chips_this_run      = 0            -- running counter for the prestige modal display
    instance.anti_stakes_won_this_run = {}
    instance.anti_chips_this_run      = 0
    -- Once-per-run catalog-item flags (Rubber Duck / Fridge / Copy Machine /
    -- Dogs Playing Poker). Reset each run; the item only fires its first time.
    instance.first_loss_voided_this_run       = false
    instance.first_stack_loss_voided_this_run = false
    instance.denied_copied_this_run           = false
    instance.first_bounty_this_run            = false
    -- Hands resolved since a {chip} bounty last banked (0 on a banking
    -- hand). Run-scoped; drives the tutorial's shove-stall nudge.
    instance.hands_since_last_bank = 0
    -- Total $ lost this run, and the value it froze at when the run ended.
    -- The Dishwasher seeds a percentage of the frozen figure into the next
    -- run's bankroll (see applyStartingPerks).
    instance.run_money_lost      = 0
    instance.last_run_money_lost = 0

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
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
    self.active_table_mutes        = {}
    self.active_table_rebuy_mutes  = {}
    self.active_table_mtt_hands_won = {}
    self.active_table_mtt_state     = {}
    self.active_table_seat_stacks   = {}
    self.active_table_seat_busted   = {}
    self.active_table_player_seat   = {}
    self.active_table_button_seat   = {}
    self.active_table_bust_order    = {}
    self.active_table_mtt_plans     = {}
    self.active_table_stack         = {}
    self.stakes_won_this_run = {}
    self.chips_this_run      = 0
    self.anti_stakes_won_this_run = {}
    self.anti_chips_this_run      = 0
    self.first_loss_voided_this_run       = false
    self.first_stack_loss_voided_this_run = false
    self.denied_copied_this_run           = false
    self.first_bounty_this_run            = false
    self.hands_since_last_bank = 0
    -- Freeze the run's losses before wiping them — the Dishwasher spends
    -- the frozen figure at the next applyStartingPerks.
    self.last_run_money_lost = self.run_money_lost or 0
    self.run_money_lost      = 0
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
    self.hints_queued = {}
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

    -- Lifetime counters reset too — the unlock conditions need a fresh
    -- start when the player wipes their game.
    self.total_hands_played             = 0
    self.total_big_outcomes             = 0
    self.total_denied_stacks            = 0
    self.lifetime_money_won             = 0
    self.lifetime_money_lost            = 0
    self.lifetime_jackpot_count         = 0
    self.lifetime_mtt_hands_won         = 0
    self.lifetime_hands_played          = 0
    self.lifetime_hands_at_4plus_tables = 0
    self.lifetime_rebuys                = 0
    self.lifetime_upgrades_bought       = 0
    self.lifetime_hands_overwhelmed     = 0
    self.lifetime_chips_banked          = 0
    -- The ungated family the catalog gates read.
    self.total_busts             = 0
    self.total_stack_losses      = 0
    self.total_jackpots          = 0
    self.total_rebuys            = 0
    self.total_upgrade_levels    = 0
    self.total_hands_overwhelmed = 0
    self.total_hands_at_4plus    = 0
    self.total_chips_banked      = 0
    self.total_mtt_wins          = 0
    self.total_hands_by_gtype    = {}
    self.highest_stake_idx       = 0
    self.last_run_money_lost     = 0

    -- New save identity — fresh game, fresh analytics file.
    self.save_id    = genSaveId()
    self.shove_count = 0
    self:resetRun()
    -- resetRun incremented shove_count to 1; wipeAll is shove 0 (first run).
    self.shove_count = 0
end

-- Apply both meta and run payloads. Called from SaveService:loadAll wrapper
-- (saved = { meta = ..., run = ... }).
function GameState:applySaved(saved)
    if saved.meta then
        AutoSerializer.apply(self, saved.meta, GameState.REFS, function() return nil end)
    end
    if saved.run then
        AutoSerializer.apply(self, saved.run, GameState.REFS, function() return nil end)
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
    self.lifetime_jackpot_count         = self.lifetime_jackpot_count         or 0
    self.lifetime_mtt_hands_won         = self.lifetime_mtt_hands_won         or 0
    self.lifetime_hands_played          = self.lifetime_hands_played          or 0
    self.lifetime_hands_at_4plus_tables = self.lifetime_hands_at_4plus_tables or 0
    self.lifetime_rebuys                = self.lifetime_rebuys or 0
    self.lifetime_upgrades_bought       = self.lifetime_upgrades_bought or 0
    self.lifetime_hands_overwhelmed     = self.lifetime_hands_overwhelmed or 0
    self.lifetime_chips_banked          = self.lifetime_chips_banked or 0
    -- total_hands_played postdates the (gated) deck counters. Old saves
    -- accrued lifetime_hands_played ungated, so it's the best backfill.
    self.total_hands_played             = self.total_hands_played
                                          or self.lifetime_hands_played or 0
    self.total_big_outcomes             = self.total_big_outcomes    or 0
    self.total_denied_stacks            = self.total_denied_stacks   or 0
    -- Ungated counters added with the catalog expansion. The three that
    -- mirror a lifetime_* field backfill from it — an existing save already
    -- earned those, and the mirror only differs going forward (it keeps
    -- ticking before the deck gate opens, where lifetime_* does not).
    self.total_busts             = self.total_busts             or 0
    self.total_stack_losses      = self.total_stack_losses      or 0
    self.total_jackpots          = self.total_jackpots          or self.lifetime_jackpot_count or 0
    self.total_rebuys            = self.total_rebuys            or self.lifetime_rebuys or 0
    self.total_upgrade_levels    = self.total_upgrade_levels    or self.lifetime_upgrades_bought or 0
    self.total_hands_overwhelmed = self.total_hands_overwhelmed or self.lifetime_hands_overwhelmed or 0
    self.total_hands_at_4plus    = self.total_hands_at_4plus    or self.lifetime_hands_at_4plus_tables or 0
    self.total_chips_banked      = self.total_chips_banked      or 0
    self.total_mtt_wins          = self.total_mtt_wins          or 0
    self.total_hands_by_gtype    = self.total_hands_by_gtype    or {}
    self.highest_stake_idx       = self.highest_stake_idx       or 0
    self.run_money_lost          = self.run_money_lost          or 0
    self.last_run_money_lost     = self.last_run_money_lost     or 0
    self.hands_since_last_bank          = self.hands_since_last_bank or 0
    -- Analytics identity — backfill for saves predating this field.
    self.save_id    = self.save_id    or genSaveId()
    self.shove_count = self.shove_count or 0
    -- catalog_seen added with the tutorial redesign. A save that has
    -- shoved has been through the post-shove catalog — count it as seen
    -- so existing players keep their top-bar CATALOG button.
    if self.catalog_seen == nil then
        self.catalog_seen = (self.shove_count or 0) > 0
    end
    -- Saves predating the hint system start with an empty seen-set; no
    -- deeper migration needed — HintController silently retires any hint
    -- whose done-condition the save already satisfies.
    self.hints_seen   = self.hints_seen   or {}
    self.hints_queued = self.hints_queued or {}
    self.anti_stakes_won_this_run = self.anti_stakes_won_this_run or {}
    self.anti_chips_this_run      = self.anti_chips_this_run or 0
    self.first_loss_voided_this_run       = self.first_loss_voided_this_run or false
    self.first_stack_loss_voided_this_run = self.first_stack_loss_voided_this_run or false
    self.denied_copied_this_run           = self.denied_copied_this_run or false
    self.first_bounty_this_run            = self.first_bounty_this_run or false
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
        hints_queued                    = self.hints_queued,
        unlocked_decks                  = self.unlocked_decks,
        deck_levels                     = self.deck_levels,
        deck_xp                         = self.deck_xp,
        active_deck_id                  = self.active_deck_id,
        lifetime_money_won              = self.lifetime_money_won,
        lifetime_money_lost             = self.lifetime_money_lost,
        lifetime_jackpot_count          = self.lifetime_jackpot_count,
        lifetime_mtt_hands_won          = self.lifetime_mtt_hands_won,
        lifetime_hands_played           = self.lifetime_hands_played,
        lifetime_hands_at_4plus_tables  = self.lifetime_hands_at_4plus_tables,
        lifetime_rebuys                 = self.lifetime_rebuys,
        lifetime_upgrades_bought        = self.lifetime_upgrades_bought,
        lifetime_hands_overwhelmed      = self.lifetime_hands_overwhelmed,
        lifetime_chips_banked           = self.lifetime_chips_banked,
        total_hands_played              = self.total_hands_played,
        total_big_outcomes              = self.total_big_outcomes,
        total_denied_stacks             = self.total_denied_stacks,
        total_busts                     = self.total_busts,
        total_stack_losses              = self.total_stack_losses,
        total_jackpots                  = self.total_jackpots,
        total_rebuys                    = self.total_rebuys,
        total_upgrade_levels            = self.total_upgrade_levels,
        total_hands_overwhelmed         = self.total_hands_overwhelmed,
        total_hands_at_4plus            = self.total_hands_at_4plus,
        total_chips_banked              = self.total_chips_banked,
        total_mtt_wins                  = self.total_mtt_wins,
        total_hands_by_gtype            = self.total_hands_by_gtype,
        highest_stake_idx               = self.highest_stake_idx,
        last_run_money_lost             = self.last_run_money_lost,
    }
end

-- Serialize run-only (bankroll, stake, run upgrades, active tables,
-- per-run chip bookkeeping). For run.save. Wiped on prestige by `clearRun()`.
function GameState:serializeRun()
    return {
        bankroll                   = self.bankroll,
        current_stake_id           = self.current_stake_id,
        run_upgrade_levels         = self.run_upgrade_levels,
        active_table_specs         = self.active_table_specs,
        active_table_mutes         = self.active_table_mutes,
        active_table_rebuy_mutes   = self.active_table_rebuy_mutes,
        active_table_mtt_hands_won = self.active_table_mtt_hands_won,
        active_table_mtt_state     = self.active_table_mtt_state,
        active_table_seat_stacks   = self.active_table_seat_stacks,
        active_table_seat_busted   = self.active_table_seat_busted,
        active_table_player_seat   = self.active_table_player_seat,
        active_table_button_seat   = self.active_table_button_seat,
        active_table_bust_order    = self.active_table_bust_order,
        active_table_mtt_plans     = self.active_table_mtt_plans,
        active_table_stack         = self.active_table_stack,
        stakes_won_this_run        = self.stakes_won_this_run,
        chips_this_run             = self.chips_this_run,
        anti_stakes_won_this_run   = self.anti_stakes_won_this_run,
        anti_chips_this_run        = self.anti_chips_this_run,
        first_loss_voided_this_run       = self.first_loss_voided_this_run,
        first_stack_loss_voided_this_run = self.first_stack_loss_voided_this_run,
        denied_copied_this_run           = self.denied_copied_this_run,
        first_bounty_this_run            = self.first_bounty_this_run,
        hands_since_last_bank      = self.hands_since_last_bank,
        run_money_lost             = self.run_money_lost,
    }
end

-- ── Stat rollup via EffectsRegistry ─────────────────────────────────
-- Computes the player's current effective stats by walking owned items
-- and run upgrades through the EffectsRegistry. NO if/elseif on item ids
-- or effect kinds — pure data + registry dispatch.
--
-- `registry` is the EffectsRegistry; `catalog` and `run_upgrades` are the
-- data tables (passed in instead of required so this stays testable).
function GameState:computeEffects(registry, catalog, run_upgrades, transient_params)
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
    -- or via granted_at_start. The handicap's removed_by="poker_poster"
    -- always wins as soon as the Poster is owned. (Engine-neutral mechanism
    -- — handicaps / debuffs / anti-perks / lift to a service unchanged.)
    for _, item in ipairs(catalog) do
        if owned_set[item.id]
           and not (item.removed_by and owned_set[item.removed_by]) then
            if corrupted_set[item.id] and item.corrupt and item.corrupt.effects then
                local temp_item = { effects = item.corrupt.effects }
                registry:applyAll(temp_item, ctx)
            else
                registry:applyAll(item, ctx)
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
        Decks.applyEffects(self, registry, ctx)
    end

    -- Run upgrades stack: each level applies the item's effect block once.
    -- additive applicators sum to N×value, multiplicative to value^N.
    -- The Investor deck scales every upgrade's strength by
    -- run_upgrade_strength_mult. How to scale a field is data (each kind's
    -- `scale` in data/effects.lua) — no dispatch on the kind string here.
    local upgrade_mult = ctx.run_upgrade_strength_mult or 1.0
    for _, item in ipairs(run_upgrades) do
        local lvl = self.run_upgrade_levels[item.id] or 0
        if lvl > 0 then
            if upgrade_mult ~= 1.0 then
                local scaled_effects = {}
                for _, e in ipairs(item.effects) do
                    local copy = {}
                    for k, v in pairs(e) do copy[k] = v end
                    if copy.strength then
                        copy.strength = copy.strength * upgrade_mult
                    elseif copy.value then
                        local kind_meta = EffectKinds[copy.kind]
                        if kind_meta and kind_meta.scale == "value_mult1" then
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

    self.effects_cache = ctx
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
function GameState:applyStartingPerks(ctx)
    if (ctx.start_bankroll_add or 0) > 0 then
        self.bankroll = self.bankroll + ctx.start_bankroll_add
    end
    if (ctx.start_bankroll_pct or 0) > 0 then
        self.bankroll = self.bankroll * (1 + ctx.start_bankroll_pct)
    end
    if (ctx.loss_recycle_pct or 0) > 0 then
        self.bankroll = self.bankroll
                        + (self.last_run_money_lost or 0) * ctx.loss_recycle_pct
    end
    for _ = 1, (ctx.start_table_count or 0) do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
end

return GameState
