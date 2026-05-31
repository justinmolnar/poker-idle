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
        instance.deck_levels[starter.id] = 1
        instance.deck_xp[starter.id]     = 0
    end
    instance.active_deck_id = starter and starter.id or nil

    -- Lifetime counters (persist forever; drive deck unlocks). Bumped
    -- by GrindController on each resolution. Read by deck_unlock_rules
    -- via the UnlockRegistry threshold-check kinds.
    instance.lifetime_money_won             = 0
    instance.lifetime_money_lost            = 0
    instance.lifetime_jackpot_count         = 0
    instance.lifetime_mtt_hands_won         = 0
    instance.lifetime_hands_played          = 0
    instance.lifetime_hands_at_4plus_tables = 0

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
    self.effects_cache       = nil
end

-- Resets BOTH meta and run sides to fresh-game defaults. Called from the
-- credits screen's reset action — wipes the player's progress entirely so
-- they can play through again from zero. Caller is responsible for
-- save_service:saveAll() afterwards to overwrite the disk slots.
function GameState:wipeAll()
    self.chips       = Constants.GAMEPLAY.INITIAL_CHIP
    self.owned_items = {}
    self.cleared     = false
    -- Deck state resets to starter-only with all unlock progress lost.
    -- Mirrors the fresh-:new defaults exactly.
    local starter = DeckSpecs[1]
    self.unlocked_decks = {}
    self.deck_levels    = {}
    self.deck_xp        = {}
    if starter then
        self.unlocked_decks[1]      = starter.id
        self.deck_levels[starter.id] = 1
        self.deck_xp[starter.id]     = 0
    end
    self.active_deck_id = starter and starter.id or nil

    -- Lifetime counters reset too — the unlock conditions need a fresh
    -- start when the player wipes their game.
    self.lifetime_money_won             = 0
    self.lifetime_money_lost            = 0
    self.lifetime_jackpot_count         = 0
    self.lifetime_mtt_hands_won         = 0
    self.lifetime_hands_played          = 0
    self.lifetime_hands_at_4plus_tables = 0

    self:resetRun()
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
    self:_migrateDeckState()

    -- Lifetime counters added later than the deck-state fields. Older
    -- saves don't have them — backfill to 0 so unlock checks have a
    -- well-defined zero baseline.
    self.lifetime_money_won             = self.lifetime_money_won             or 0
    self.lifetime_money_lost            = self.lifetime_money_lost            or 0
    self.lifetime_jackpot_count         = self.lifetime_jackpot_count         or 0
    self.lifetime_mtt_hands_won         = self.lifetime_mtt_hands_won         or 0
    self.lifetime_hands_played          = self.lifetime_hands_played          or 0
    self.lifetime_hands_at_4plus_tables = self.lifetime_hands_at_4plus_tables or 0
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

    if self.deck_levels then
        for id in pairs(self.deck_levels) do
            if not known[id] then self.deck_levels[id] = nil end
        end
    end
    if self.deck_xp then
        for id in pairs(self.deck_xp) do
            if not known[id] then self.deck_xp[id] = nil end
        end
    end

    if not self.active_deck_id or not known[self.active_deck_id] then
        self.active_deck_id = self.unlocked_decks[1]
                              or (DeckSpecs[1] and DeckSpecs[1].id)
                              or nil
    end
end

-- Serialize meta-only (chips, owned items, cleared flag, deck progression,
-- lifetime counters that drive unlock checks). For meta.save.
function GameState:serializeMeta()
    return {
        chips                           = self.chips,
        owned_items                     = self.owned_items,
        cleared                         = self.cleared,
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
    }
end

-- ── Stat rollup via EffectsRegistry ─────────────────────────────────
-- Computes the player's current effective stats by walking owned items
-- and run upgrades through the EffectsRegistry. NO if/elseif on item ids
-- or effect kinds — pure data + registry dispatch.
--
-- `registry` is the EffectsRegistry; `catalog` and `run_upgrades` are the
-- data tables (passed in instead of required so this stays testable).
function GameState:computeEffects(registry, catalog, run_upgrades)
    local ctx = {}

    -- Pass 1: seed owned_set from explicit owned_items, plus any
    -- `granted_at_start` phantoms (handicap, future debuffs).
    local owned_set = {}
    for _, id in ipairs(self.owned_items) do owned_set[id] = true end
    for _, item in ipairs(catalog) do
        if item.granted_at_start then
            owned_set[item.id] = true
        end
    end

    -- Pass 2: apply effects. `removed_by` is enforced HERE, uniformly —
    -- it doesn't matter whether the entry got into owned_set via owned_items
    -- or via granted_at_start. The handicap's removed_by="poker_poster"
    -- always wins as soon as the Poster is owned. (Engine-neutral mechanism
    -- — handicaps / debuffs / anti-perks / lift to a service unchanged.)
    for _, item in ipairs(catalog) do
        if owned_set[item.id]
           and not (item.removed_by and owned_set[item.removed_by]) then
            registry:applyAll(item, ctx)
        end
    end

    -- Run upgrades stack: each level applies the item's effect block once.
    -- additive applicators sum to N×value, multiplicative to value^N.
    for _, item in ipairs(run_upgrades) do
        local lvl = self.run_upgrade_levels[item.id] or 0
        if lvl > 0 then
            registry:applyN(item, ctx, lvl)
        end
    end

    -- Decks stack: every unlocked deck contributes its banked passive at
    -- the current level via the same registry pipeline. Active vs.
    -- inactive doesn't matter here — only XP accrual cares about that.
    -- Gated on the feature flag so the prototype build's stat ctx stays
    -- exactly as it was before the deck system existed.
    if Constants.FEATURES and Constants.FEATURES.DECKS then
        Decks.applyEffects(self, registry, ctx)
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
--
-- Order: flat add applies first, then the percentage multiplies the result.
-- "+$5 + 50%" on a $2 base = ($2 + $5) × 1.5 = $10.50, not $2 + $5 + $1 = $8.
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
    for _ = 1, (ctx.start_table_count or 0) do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
end

return GameState
