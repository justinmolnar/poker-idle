-- models/GameState.lua
--
-- The single root model for player progression. Holds the dual-slot state:
--   meta-side: pp, owned_items (persists forever)
--   run-side:  bankroll, current_stake_id, run_upgrade_ids (wiped on prestige)
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
GameState.REFS = {}         -- nothing yet — owned_items / run_upgrade_ids are
                            -- already plain string ids, no ref resolution needed

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
    instance.run_upgrade_ids     = {}
    instance.active_table_stakes = { "s001" }   -- player starts with one $0.01/$0.02 table
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
    self.run_upgrade_ids     = {}
    self.active_table_stakes = { "s001" }
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
        bankroll             = self.bankroll,
        peak_bankroll        = self.peak_bankroll,
        current_stake_id     = self.current_stake_id,
        run_upgrade_ids      = self.run_upgrade_ids,
        active_table_stakes  = self.active_table_stakes,
        stakes_won_this_run  = self.stakes_won_this_run,
        pp_this_run          = self.pp_this_run,
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

    local upgrade_set = {}
    for _, id in ipairs(self.run_upgrade_ids) do upgrade_set[id] = true end

    for _, item in ipairs(run_upgrades) do
        if upgrade_set[item.id] then
            registry:applyAll(item, ctx)
        end
    end

    self.effects_cache = ctx
    return ctx
end

return GameState
