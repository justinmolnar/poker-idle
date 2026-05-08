-- models/GameState.lua
--
-- The single root model for player progression. Holds the dual-slot state:
--   meta-side: pp, owned_items (persists forever)
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
    instance.pp          = Constants.GAMEPLAY.INITIAL_PP
    instance.owned_items = {}
    instance.cleared     = false   -- true once the gauntlet is beaten — gates the credits screen on boot

    -- Deck-system meta state (persists forever; never reset by prestige).
    -- All decks unlocked from the start in this build; later unlock
    -- conditions plug in by appending to this list rather than seeding it.
    -- deck_levels / deck_xp default to L1 / 0 for every spec so the
    -- effects pipeline has a clean baseline (L1 contributes one stack).
    instance.unlocked_decks = {}
    instance.deck_levels    = {}
    instance.deck_xp        = {}
    for _, spec in ipairs(DeckSpecs) do
        instance.unlocked_decks[#instance.unlocked_decks + 1] = spec.id
        instance.deck_levels[spec.id] = 1
        instance.deck_xp[spec.id]     = 0
    end
    instance.active_deck_id = (DeckSpecs[1] and DeckSpecs[1].id) or nil

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
    instance.stakes_won_this_run = {}           -- set keyed by stake_id; locks in PP bounties per run
    instance.pp_this_run         = 0            -- running counter for the prestige modal display

    -- Transient stat cache, recomputed lazily.
    instance.effects_cache = nil

    if saved then
        instance:applySaved(saved)
    end

    return instance
end

-- Wipes run-side fields back to defaults. Called by the prestige flow after
-- a gauntlet bust. Meta-side (pp, owned_items, cleared) is left untouched —
-- PP earned during the run was already banked to state.pp during play.
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
    self.stakes_won_this_run = {}
    self.pp_this_run         = 0
    self.effects_cache       = nil
end

-- Resets BOTH meta and run sides to fresh-game defaults. Called from the
-- credits screen's reset action — wipes the player's progress entirely so
-- they can play through again from zero. Caller is responsible for
-- save_service:saveAll() afterwards to overwrite the disk slots.
function GameState:wipeAll()
    self.pp          = Constants.GAMEPLAY.INITIAL_PP
    self.owned_items = {}
    self.cleared     = false
    -- Deck state resets to all-decks-unlocked, all at L1, no XP, default
    -- active. Mirrors the fresh-:new defaults so a fresh game starts
    -- identical regardless of whether it boots into an empty save or a
    -- cleared one.
    self.unlocked_decks = {}
    self.deck_levels    = {}
    self.deck_xp        = {}
    for _, spec in ipairs(DeckSpecs) do
        self.unlocked_decks[#self.unlocked_decks + 1] = spec.id
        self.deck_levels[spec.id] = 1
        self.deck_xp[spec.id]     = 0
    end
    self.active_deck_id = (DeckSpecs[1] and DeckSpecs[1].id) or nil
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
end

-- Serialize meta-only (PP, owned items, cleared flag, deck progression).
-- For meta.save.
function GameState:serializeMeta()
    return {
        pp              = self.pp,
        owned_items     = self.owned_items,
        cleared         = self.cleared,
        unlocked_decks  = self.unlocked_decks,
        deck_levels     = self.deck_levels,
        deck_xp         = self.deck_xp,
        active_deck_id  = self.active_deck_id,
    }
end

-- Serialize run-only (bankroll, stake, run upgrades, active tables,
-- per-run PP bookkeeping). For run.save. Wiped on prestige by `clearRun()`.
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
        stakes_won_this_run        = self.stakes_won_this_run,
        pp_this_run                = self.pp_this_run,
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

-- Spend PP on a catalog item: validates affordability + non-duplicate +
-- requires-prereq, applies the mutation, invalidates the effects cache.
-- Returns true on success. Centralised so both grind-time and post-bust
-- catalog UIs route through one mutation point — no view mutates state.pp
-- directly. Caller-side concerns (sound, ctx recompute) remain on the
-- caller; this is just the model-side guarded write.
function GameState:tryBuyCatalogItem(item)
    if not item or item.cost_pp == nil then return false end
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
    if self.pp < item.cost_pp then return false end
    self.pp = self.pp - item.cost_pp
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
--   ctx.start_bankroll_pct  — additive % on INITIAL_BANKROLL (Lucky Coin)
--   ctx.start_table_count   — N s001:six_max tables auto-seeded (free)
--
-- Idempotency: this is meant to be called once per resetRun. Calling it
-- twice would double-apply, so don't.
function GameState:applyStartingPerks(ctx)
    if (ctx.start_bankroll_add or 0) > 0 then
        self.bankroll = self.bankroll + ctx.start_bankroll_add
    end
    if (ctx.start_bankroll_pct or 0) > 0 then
        self.bankroll = self.bankroll
            + Constants.GAMEPLAY.INITIAL_BANKROLL * ctx.start_bankroll_pct
    end
    for _ = 1, (ctx.start_table_count or 0) do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
end

return GameState
