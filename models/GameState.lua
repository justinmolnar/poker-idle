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

    -- Run-side defaults (wiped on prestige).
    instance.bankroll            = Constants.GAMEPLAY.INITIAL_BANKROLL
    instance.peak_bankroll       = Constants.GAMEPLAY.INITIAL_BANKROLL
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
    instance.active_table_mutes  = {}
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
    self.peak_bankroll       = Constants.GAMEPLAY.INITIAL_BANKROLL
    self.current_stake_id    = "s001"
    self.run_upgrade_levels  = {}
    self.active_table_specs = {}
    for _ = 1, Constants.GAMEPLAY.INITIAL_ACTIVE_TABLES do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
    self.active_table_mutes  = {}
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

-- Serialize meta-only (PP, owned items, cleared flag). For meta.save.
function GameState:serializeMeta()
    return {
        pp          = self.pp,
        owned_items = self.owned_items,
        cleared     = self.cleared,
    }
end

-- Serialize run-only (bankroll, peak, stake, run upgrades, active tables,
-- per-run PP bookkeeping). For run.save. Wiped on prestige by `clearRun()`.
function GameState:serializeRun()
    return {
        bankroll                   = self.bankroll,
        peak_bankroll              = self.peak_bankroll,
        current_stake_id           = self.current_stake_id,
        run_upgrade_levels         = self.run_upgrade_levels,
        active_table_specs         = self.active_table_specs,
        active_table_mutes         = self.active_table_mutes,
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

    local owned_set = {}
    for _, id in ipairs(self.owned_items) do owned_set[id] = true end

    for _, item in ipairs(catalog) do
        if owned_set[item.id] then
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

    self.effects_cache = ctx
    return ctx
end

-- Apply meta-progression catalog perks that fire at run start.
-- Called by the prestige flow AFTER :resetRun() has cleared run state but
-- BEFORE the controller rebuilds the table pool. Reads the catalog-only
-- ctx (run_upgrade_levels is empty post-reset, so only owned_items feed in).
--
-- The two recognized fields:
--   ctx.start_bankroll_add — added to the fresh INITIAL_BANKROLL
--   ctx.start_table_count  — N s001:six_max tables auto-seeded (free, no buy-in)
--
-- Idempotency: this is meant to be called once per resetRun. Calling it
-- twice would double-apply, so don't.
function GameState:applyStartingPerks(ctx)
    if (ctx.start_bankroll_add or 0) > 0 then
        self.bankroll = self.bankroll + ctx.start_bankroll_add
        if self.bankroll > self.peak_bankroll then
            self.peak_bankroll = self.bankroll
        end
    end
    for _ = 1, (ctx.start_table_count or 0) do
        self.active_table_specs[#self.active_table_specs + 1] = "s001:six_max"
    end
end

return GameState
