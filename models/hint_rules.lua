-- models/hint_rules.lua
--
-- Condition kinds for the tutorial hint system, registered into a generic
-- services/UnlockRegistry instance (g.hint_rules — separate from
-- g.unlock_rules, whose deck kinds use a different check argument).
-- Mirrors models/deck_unlock_rules.lua's relationship with the registry:
-- the mechanism stays engine-agnostic; the game-specific kinds live here.
--
-- Dispatch contract: reg:check(cond, ctx) where ctx = { state, pool, grind }
-- (GameState instance, the live TablePool, the GrindController for derived
-- reads like tiedUp / focus / quick-reset). Adding a hint condition kind =
-- one entry here + usages in data/hints.lua. No `if kind ==` chain anywhere.
--
-- Numeric kinds compare their read against inclusive cond.min / cond.max
-- (either optional). `all` / `any` / `not` compose sub-conditions from
-- their array part.

local Decks         = require("models.Decks")
local Stakes        = require("data.stakes")
local RunUpgrades   = require("data.run_upgrades")
local BankrollTiers = require("data.bankroll_tiers")
local Lookups       = require("utils.lookups")

local HintRules = {}

local function inRange(v, cond)
    if cond.min and v < cond.min then return false end
    if cond.max and v > cond.max then return false end
    return true
end

-- Registers a {min,max} threshold kind reading one named GameState field.
local function stateField(reg, kind, field)
    reg:register(kind, function(cond, ctx)
        return inRange((ctx.state and ctx.state[field]) or 0, cond)
    end)
end

-- Registers a boolean kind reading one named GameState flag. Sibling of
-- stateField, and there for the same reason: data/hints.lua names a CONCEPT
-- ("act3_unlocked") while the engine field it reads ("shove_r2_won") stays in
-- here, so renaming the field never touches data.
local function stateFlag(reg, kind, field)
    reg:register(kind, function(_cond, ctx)
        return (ctx.state and ctx.state[field]) == true
    end)
end

-- Length of a named GameState list field, as a {min,max} kind.
local function stateCount(reg, kind, field)
    reg:register(kind, function(cond, ctx)
        local list = ctx.state and ctx.state[field]
        return inRange(list and #list or 0, cond)
    end)
end

function HintRules.registerAll(reg)
    -- ── Composition ──────────────────────────────────────────────────
    reg:register("all", function(cond, ctx)
        for _, sub in ipairs(cond) do
            if not reg:check(sub, ctx) then return false end
        end
        return true
    end)

    reg:register("any", function(cond, ctx)
        for _, sub in ipairs(cond) do
            if reg:check(sub, ctx) then return true end
        end
        return false
    end)

    reg:register("not", function(cond, ctx)
        return not reg:check(cond[1], ctx)
    end)

    -- ── Counters (all unconditional GameState fields — NOT the
    -- deck-gated lifetime_* family, which stays 0 pre-clear) ─────────
    stateField(reg, "hands_played",          "total_hands_played")
    stateField(reg, "shoves",                "shove_count")
    stateField(reg, "chips_this_run",        "chips_this_run")
    stateField(reg, "total_big_outcomes",    "total_big_outcomes")
    stateField(reg, "total_denied_stacks",   "total_denied_stacks")
    stateField(reg, "hands_since_last_bank", "hands_since_last_bank")
    stateField(reg, "bankroll",              "bankroll")
    stateField(reg, "total_chips_banked",    "total_chips_banked")
    stateField(reg, "highest_stake_idx",     "highest_stake_idx")
    stateField(reg, "anti_chips",            "anti_chips")
    stateField(reg, "anti_chips_this_run",   "anti_chips_this_run")
    stateField(reg, "total_rebuys",          "total_rebuys")
    stateField(reg, "total_busts",           "total_busts")
    stateField(reg, "total_stack_losses",    "total_stack_losses")

    -- ── Milestone flags ──────────────────────────────────────────────
    -- has_shoved is NOT shove_count. resetRun bumps shove_count, and
    -- quickReset routes through resetRun, so the rescue button raises the
    -- count without the player ever shoving (see GameState's note on the
    -- two fields). Any hint asking "do they know what SHOVE is" must read
    -- this flag; `shoves` above stays for questions about prestige COUNT.
    stateFlag(reg, "has_shoved",       "has_shoved")
    stateFlag(reg, "act2_unlocked",    "shove_r1_won")
    stateFlag(reg, "act3_unlocked",    "shove_r2_won")
    stateFlag(reg, "gauntlet_cleared", "cleared")

    stateCount(reg, "corrupted_count", "corrupted_items")

    -- ── Tables ───────────────────────────────────────────────────────
    reg:register("tables_open", function(cond, ctx)
        return inRange((ctx.pool and ctx.pool:count()) or 0, cond)
    end)

    -- Any table mid-hand (state left "idle"). Lets a hint complete the
    -- moment the player clicks DEAL instead of waiting out the playback.
    reg:register("hand_in_progress", function(_cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            if tbl and tbl.state ~= "idle" then return true end
        end
        return false
    end)

    -- A busted table waiting on REBUY (stack empty, hand not running).
    reg:register("any_table_busted", function(_cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            if tbl and tbl.state == "idle" and (tbl.stack or 0) <= 0 then
                return true
            end
        end
        return false
    end)

    -- Any open table of the given game type (cond.gtype). Structural twin of
    -- stake_table_open below; the game type is a parameter, not a branch.
    reg:register("gtype_table_open", function(cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            if tbl and tbl.game_type_id == cond.gtype then return true end
        end
        return false
    end)

    -- Any open table whose stake sits in the given band (cond.band: low /
    -- mid / high / ultra). Reads stake.band out of data, so adding a band
    -- needs no change here.
    reg:register("stake_band_table_open", function(cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            local stake = tbl and Lookups.findById(Stakes, tbl.stake_id)
            if stake and stake.band == cond.band then return true end
        end
        return false
    end)

    -- Any open table at the given stake id (cond.stake).
    reg:register("stake_table_open", function(cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            if tbl and tbl.stake_id == cond.stake then return true end
        end
        return false
    end)

    -- ── Money ────────────────────────────────────────────────────────
    reg:register("tied_up", function(cond, ctx)
        return inRange((ctx.grind and ctx.grind:tiedUp()) or 0, cond)
    end)

    -- Bankroll covers the buy-in of stake id cond.stake.
    reg:register("can_afford_stake", function(cond, ctx)
        local stake = Lookups.findById(Stakes, cond.stake)
        if not (stake and ctx.state) then return false end
        return (ctx.state.bankroll or 0) >= (stake.buy_in or 0)
    end)

    -- ── Run upgrades ─────────────────────────────────────────────────
    -- Bankroll covers the NEXT level of run upgrade cond.id (false at max).
    reg:register("can_afford_run_upgrade", function(cond, ctx)
        if not (ctx.grind and ctx.state) then return false end
        local up = Lookups.findById(RunUpgrades, cond.id)
        if not up then return false end
        local cost = ctx.grind:getRunUpgradeNextCost(up)
        return cost ~= nil and (ctx.state.bankroll or 0) >= cost
    end)

    -- Total run-upgrade levels owned this run (sum across all upgrades).
    reg:register("run_upgrades_owned", function(cond, ctx)
        local levels, total = ctx.state and ctx.state.run_upgrade_levels, 0
        if levels then
            for _, lvl in pairs(levels) do total = total + (lvl or 0) end
        end
        return inRange(total, cond)
    end)

    -- ── Focus ────────────────────────────────────────────────────────
    reg:register("focus_at_capacity", function(_cond, ctx)
        if not (ctx.grind and ctx.pool) then return false end
        local n = ctx.pool:count()
        return n > 0 and n >= ctx.grind:currentFocusCapacity()
    end)

    reg:register("focus_overloaded", function(_cond, ctx)
        return ctx.grind ~= nil and ctx.grind:currentFocusMult() < 1.0
    end)

    -- ── Meta / flow ──────────────────────────────────────────────────
    reg:register("can_quick_reset", function(_cond, ctx)
        return ctx.grind ~= nil and ctx.grind:canQuickReset() == true
    end)

    reg:register("catalog_seen", function(_cond, ctx)
        return (ctx.state and ctx.state.catalog_seen) == true
    end)

    -- Bankroll-tier index (data/bankroll_tiers row: highest threshold ≤
    -- bankroll + tied — same money the SHOVE % reads). cond.min/max on
    -- the 1-based row index.
    reg:register("bankroll_tier", function(cond, ctx)
        if not ctx.state then return false end
        local total = (ctx.state.bankroll or 0)
                      + ((ctx.grind and ctx.grind:tiedUp()) or 0)
        local idx = 1
        for i, row in ipairs(BankrollTiers) do
            if total >= (row.threshold or 0) then idx = i else break end
        end
        return inRange(idx, cond)
    end)

    -- ── Catalog ──────────────────────────────────────────────────────
    -- Owns the catalog item cond.id. Generic: the id is a parameter, so
    -- this is one kind rather than one kind per item.
    reg:register("owns_item", function(cond, ctx)
        local owned = ctx.state and ctx.state.owned_items
        if not owned then return false end
        for _, id in ipairs(owned) do
            if id == cond.id then return true end
        end
        return false
    end)

    -- ── Decks ────────────────────────────────────────────────────────
    -- The system as a whole (first gauntlet win), not an individual deck.
    reg:register("deck_system_unlocked", function(_cond, ctx)
        return Decks.systemUnlocked(ctx.state) == true
    end)

    stateCount(reg, "decks_unlocked_count", "unlocked_decks")

    -- Decks at max level. This is the master-deck gate (5) and therefore
    -- the R2 wall: the master deck is the only shove base that survives
    -- the dealer's first cheat.
    reg:register("decks_maxed_count", function(cond, ctx)
        return inRange(Decks.maxedCount(ctx.state) or 0, cond)
    end)

    reg:register("hint_seen", function(cond, ctx)
        local seen = ctx.state and ctx.state.hints_seen
        return (seen and seen[cond.hint]) == true
    end)
end

return HintRules
