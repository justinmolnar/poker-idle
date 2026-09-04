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

local Stakes        = require("data.stakes")
local RunUpgrades   = require("data.run_upgrades")
local Lookups       = require("utils.lookups")
local Anchors       = require("services.AnchorRegistry")

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
    stateField(reg, "total_heaters",         "total_heaters")
    stateField(reg, "total_cursor_deals",    "total_cursor_deals")
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
    stateFlag(reg, "ultra_unlocked",   "ultra_unlocked")
    stateFlag(reg, "hu_unlocked",      "hu_unlocked")
    stateFlag(reg, "six_max_unlocked", "six_max_unlocked")
    stateFlag(reg, "act2_unlocked",    "shove_r1_won")
    stateFlag(reg, "act3_unlocked",    "shove_r2_won")
    stateFlag(reg, "gauntlet_cleared", "cleared")

    stateCount(reg, "corrupted_count", "corrupted_items")

    -- ── Tables ───────────────────────────────────────────────────────
    reg:register("tables_open", function(cond, ctx)
        return inRange((ctx.pool and ctx.pool:count()) or 0, cond)
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

    -- Any open table of the given game type (cond.gtype) — the game type
    -- is a parameter, not a branch.
    reg:register("gtype_table_open", function(cond, ctx)
        local pool = ctx.pool
        if not pool then return false end
        for i = 1, pool:count() do
            local tbl = pool:get(i)
            if tbl and tbl.game_type_id == cond.gtype then return true end
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
    -- Optional `safe = true`: the buy must also pass the shop's own strand
    -- check (GrindController:wouldStrandRun: with no live table, a buy that
    -- drops the bankroll under the cheapest buy-in is refused). The House's
    -- "I'd grab it" uses the same rule as the button it points at.
    reg:register("can_afford_run_upgrade", function(cond, ctx)
        if not (ctx.grind and ctx.state) then return false end
        local up = Lookups.findById(RunUpgrades, cond.id)
        if not up then return false end
        local cost = ctx.grind:getRunUpgradeNextCost(up)
        if cost == nil or (ctx.state.bankroll or 0) < cost then return false end
        if cond.safe and ctx.grind.wouldStrandRun and ctx.grind:wouldStrandRun(cost) then
            return false
        end
        return true
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
    reg:register("focus_overloaded", function(_cond, ctx)
        return ctx.grind ~= nil and ctx.grind:currentFocusMult() < 1.0
    end)

    -- ── Meta / flow ──────────────────────────────────────────────────
    reg:register("can_quick_reset", function(_cond, ctx)
        return ctx.grind ~= nil and ctx.grind:canQuickReset() == true
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
    stateCount(reg, "decks_unlocked_count", "unlocked_decks")

    -- ── Pointer ──────────────────────────────────────────────────────
    -- The mouse is over one of the named anchors right now (cond.anchor,
    -- a name or a list). This is how a beat forces a hover — the wait
    -- passes the moment the pointer reaches the widget. Only fresh
    -- anchors count (the widget drew this frame).
    reg:register("hovering", function(cond, ctx)
        if not (love and love.mouse) then return false end
        local names = cond.anchor
        if type(names) ~= "table" then names = { names } end
        local fresh = ctx.anchor_fresh
        local mx, my = love.mouse.getPosition()
        for _, n in ipairs(names) do
            if not fresh or fresh(n) then
                local a = Anchors.get(n)
                if a and a[3] and mx >= a[1] and mx < a[1] + a[3]
                   and my >= a[2] and my < a[2] + a[4] then
                    return true
                end
            end
        end
        return false
    end)

    -- ── Screens ──────────────────────────────────────────────────────
    -- These read facts the host injects through HintController.ctx_extra:
    -- which state is up, where the shove's beat machine is, whether a modal
    -- that doubles as a teaching surface is open. None of it belongs to a
    -- controller, so none of it is on ctx.grind.
    reg:register("screen", function(cond, ctx)
        return ctx.screen == cond.name
    end)

    reg:register("shove_phase", function(cond, ctx)
        return ctx.shove_phase == cond.phase
    end)

    -- The shove is paused on a named hold (cond.id), waiting for the player.
    reg:register("shove_beat", function(cond, ctx)
        return ctx.shove_hold ~= nil and ctx.shove_hold == cond.id
    end)

    -- How many cheat cards the dealer has dealt THIS shove. A hint gated on
    -- min = 1 cannot fire until the card is on the felt, which is what keeps
    -- it from spoiling the structure.
    reg:register("cheat_dealt", function(cond, ctx)
        return inRange(ctx.shove_cheats or 0, cond)
    end)

    reg:register("catalog_open", function(_cond, ctx)
        return ctx.catalog_open == true
    end)

    reg:register("deck_select_open", function(_cond, ctx)
        return ctx.deck_select_open == true
    end)

    -- (screen_visits and hint_seen were kinds here. Both let a popup know
    -- where the story is, which is what story beats are for; removing them
    -- is how the harness enforces that no popup depends on story progress.
    -- The screen_visits FIELD stays on GameState for save-shape stability.)
end

return HintRules
