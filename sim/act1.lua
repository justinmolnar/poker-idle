-- sim/act1.lua
--
-- Act 1 playthrough simulator. Plays the REAL game headlessly, from a
-- genuine fresh save ($2, no tables, no chips) to the first Runout 1 win,
-- and reports how long it took and what it banked on the way.
--
--   lua sim/act1.lua                 -- sim/act1_policy.lua as written
--   lua sim/act1.lua --seeds=50
--   lua sim/act1.lua --six-max       -- the comparison run
--   lua sim/act1.lua --verbose
--
-- ─── What this file is allowed to decide ────────────────────────────────
--
-- Nothing about the game. Every rate, price, gate and outcome comes from
-- the engine: OutcomeMath.evStats for what a lane earns, ShoveRate.compute
-- for the shove percentage, GrindController for every purchase and every
-- gate, Gauntlet.rollOutcomes for the result. Where a number is wanted it
-- is measured off a running board (see calibrate), never assumed.
--
-- What it decides is what a PLAYER does, and even that is not its own:
-- sim/act1_policy.lua holds the lane order, the buy order, the caps and
-- the stopping rule. This file executes that policy and reports.
--
-- ─── The one piece of duplicated logic ──────────────────────────────────
--
-- `settle` below mirrors the state half of states/ShoveState.lua:248
-- (settleRun), because that function lives on a state object that needs a
-- view. It is twelve lines; if ShoveState's settle changes, change it here
-- too. Everything else in the shove path is a real call.

io.stdout:setvbuf("no")
package.path = package.path .. ";./?.lua"

local H           = require("sim.harness")
local Policy      = require("sim.act1_policy")
local OutcomeMath = require("models.outcome_math")
local ShoveRate   = require("models.shove_rate")
local Gauntlet    = require("models.Gauntlet")
local Lookups     = require("utils.lookups")
local Constants   = require("data.constants")
local Catalog     = require("data.catalog")
local RunUpgrades = require("data.run_upgrades")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")

-- ─── Arguments ──────────────────────────────────────────────────────────
local OPT = { seeds = Policy.seeds, six_max = Policy.six_max, verbose = Policy.verbose }
for _, a in ipairs(arg or {}) do
    local n = a:match("^%-%-seeds=(%d+)$")
    if n then OPT.seeds = tonumber(n) end
    if a == "--six-max" then OPT.six_max = true end
    if a == "--no-six-max" then OPT.six_max = false end
    if a == "--verbose" then OPT.verbose = true end
end

-- The lane plan, after the six-max toggle.
local LANES = {}
for _, l in ipairs(Policy.lanes) do LANES[#LANES + 1] = l end
if OPT.six_max then
    for _, l in ipairs(Policy.six_max_lanes or {}) do LANES[#LANES + 1] = l end
end

-- Items never bought. Six-max costs a two-item chain (Bonsai then Desk
-- Plant); with the mode off, buying it is 14 {chip} for nothing.
local EXCLUDE = {}
for _, id in ipairs(Policy.catalog_exclude or {}) do EXCLUDE[id] = true end
local PRIORITY = {}
for _, id in ipairs(Policy.catalog_priority or {}) do PRIORITY[#PRIORITY + 1] = id end
if OPT.six_max then
    EXCLUDE.bonsai, EXCLUDE.desk_plant = nil, nil
    table.insert(PRIORITY, 1, "desk_plant")
    table.insert(PRIORITY, 1, "bonsai")
end

local STEP = 1 / 60

-- ─── Small engine accessors ─────────────────────────────────────────────

local function stakeOf(id) return Lookups.findById(Stakes, id) end
local function gtypeOf(id) return Lookups.findById(GameTypes, id) end

local function upgradeOf(id)
    for _, u in ipairs(RunUpgrades) do if u.id == id then return u end end
end

-- The REAL focus formula at a hypothetical table count. currentFocusMult
-- reads pool:count(); swapping that one method is how a hypothetical board
-- gets priced without copying the penalty math out of the controller.
-- In the game the factor slows every table's pace rather than shaving
-- the money; on a rate it is the same number either way, so the sum of
-- $/hand x hands/min times it is the board's rate.
local function focusMultAt(ctrl, n)
    local pool = ctrl.pool
    local real = pool.count
    pool.count = function() return n end
    local ok, m = pcall(function() return ctrl:currentFocusMult() end)
    pool.count = real
    return ok and m or 1
end

-- Deal every idle table, the way a player clicking does: dealHand stamps
-- _dealt_by_player and announces on_deal, so deal-triggered procs (the
-- Energy Drink's spread) fire. GrindController:dealAll skips both.
local function dealBoard(ctrl)
    for i = 1, ctrl.pool:count() do
        local t = ctrl.pool:get(i)
        if t and not t:isBusy() and (t.stack or 0) > 0 then ctrl:dealHand(i) end
    end
end

local function stepFrame(w)
    dealBoard(w.ctrl)
    w:tick(STEP, STEP)
end

-- ─── Calibration: how fast does a lane actually deal? ───────────────────
-- evStats gives $ per HAND; the policy needs $ per MINUTE. Rather than
-- read pace_mult and rebuild the hand clock, run one table of each type
-- for five game-minutes and count. Measured, not assumed.
local HPM = {}
local function calibrate()
    for _, gid in ipairs({ "zoom", "hu", "six_max" }) do
        local w = H.world({ bankroll = 1e9, act2 = false, gates = true })
        w:open("s001", gid)
        local secs = 300
        for _ = 1, secs * 60 do
            local t = w.ctrl.pool:get(1)
            if t and (t.stack or 0) <= 0 then w.ctrl:rebuyTable(1) end
            stepFrame(w)
        end
        local t = w.ctrl.pool:get(1)
        HPM[gid] = (t and (t.hands_played or 0) or 0) / (secs / 60)
    end
end

-- ─── What the board earns, in $ per minute ──────────────────────────────
-- `extra` (optional) is a hypothetical table {stake, gtype} added to the
-- board; `n_override` the table count to price the focus penalty at.
local function boardRate(w, extra, n_override)
    local ctrl = w.ctrl
    local ctx  = ctrl.ctx
    local n    = n_override or ctrl.pool:count()
    local sum  = 0
    local function add(stake_id, gtype_id)
        local st, gt = stakeOf(stake_id), gtypeOf(gtype_id)
        if not (st and gt) then return end
        local s = OutcomeMath.evStats(ctx, gt, st)
        if s and s.pool then sum = sum + (s.pool.ev_per_hand or 0) * (HPM[gtype_id] or 0) end
    end
    for _, t in ipairs(ctrl.pool.tables) do add(t.stake_id, t.game_type_id) end
    if extra then add(extra.stake, extra.gtype) end
    return sum * focusMultAt(ctrl, n)
end

-- Price a hypothetical extra level of an upgrade by actually holding it,
-- asking the engine, and putting it back.
local function withUpgrade(w, id, fn)
    local levels = w.state.run_upgrade_levels
    local prev   = levels[id]
    levels[id] = (prev or 0) + 1
    w.ctrl:invalidateEffects()
    local v = fn()
    levels[id] = prev
    w.ctrl:invalidateEffects()
    return v
end

-- ─── Purchases ──────────────────────────────────────────────────────────

-- What one hand of this lane is worth right now, in dollars. The focus
-- penalty is not in here: it slows every table equally and the question
-- is whether THIS lane is worth sitting at.
local function laneEV(w, stake_id, gtype_id)
    local st, gt = stakeOf(stake_id), gtypeOf(gtype_id)
    if not (st and gt) then return -math.huge end
    local s = OutcomeMath.evStats(w.ctrl.ctx, gt, st)
    return (s and s.pool and s.pool.ev_per_hand) or -math.huge
end

-- Expected dollars to land one stack-tier win on this lane, which is what
-- a bounty costs when the stake is not yet filled. nil when the stack cell
-- is shut (Zoom below Pot Control 3 cannot produce one at all), which
-- means the bounty is unreachable at any price.
local function bountyCost(w, stake_id, gtype_id)
    local st, gt = stakeOf(stake_id), gtypeOf(gtype_id)
    if not (st and gt) then return nil end
    local s = OutcomeMath.evStats(w.ctrl.ctx, gt, st)
    if not (s and s.pool) then return nil end
    -- win_dist is conditional on winning; the per-hand rate is the product.
    local p = (s.pool.win_chance or 0) * ((s.pool.win_dist and s.pool.win_dist.stack) or 0)
    if p <= 0 then return nil end
    local ev = s.pool.ev_per_hand or 0
    if ev >= 0 then return 0 end
    return (-ev) / p
end

-- Is this lane worth sitting at: either it pays, or its bounty is cheap.
local function laneWorthOpening(w, stake_id, gtype_id)
    if laneEV(w, stake_id, gtype_id) >= (Policy.lane_open_min_ev or 0) then return true end
    if w.ctrl:bountyBanked(stake_id, gtype_id) then return false end
    local cost = bountyCost(w, stake_id, gtype_id)
    if not cost then return false end
    local stake = stakeOf(stake_id)
    local chips = (stake and stake.chip_award or 0)
        * (((w.ctrl.ctx.bounty_gtype_mult or {})[gtype_id]) or 1)
    if chips <= 0 then return false end
    if cost / chips > (Policy.bounty_max_per_chip or 10) then return false end
    return cost <= (w.state.bankroll or 0) * (Policy.bounty_max_bankroll_share or 0.25)
end

local function laneOpen(w, lane)
    for _, t in ipairs(w.ctrl.pool.tables) do
        if t.stake_id == lane.stake and t.game_type_id == lane.gtype then return true end
    end
    return false
end

local function laneCost(w, lane)
    local st = stakeOf(lane.stake)
    if not st then return math.huge end
    return (st.buy_in or 0) * w.ctrl:buyInMultFor(st)
end

-- Money check. `strand` applies GrindController:wouldStrandRun, which asks
-- "would this leave me with no felt and no way to buy any". That is the
-- right question for an UPGRADE and the wrong one for a table: opening the
-- first table spends the last $2 by design (INITIAL_BANKROLL is exactly one
-- s001 buy-in), and addTable itself only checks the price.
local function affordable(w, cost, strand)
    if not cost or cost > w.state.bankroll then return false end
    if strand and w.ctrl:wouldStrandRun(cost) then return false end
    return true
end

-- Planned lanes not yet on the board. Their seats are reserved: a stake
-- that is not worth opening YET still will be, and a board packed with
-- cheap duplicates has nowhere to seat it when it is. That is what walled
-- s003 off behind Focus L4 ($27,000) instead of a $100 buy-in.
local function plannedSeatsWanted(w)
    local n = 0
    for _, lane in ipairs(LANES) do
        if not laneOpen(w, lane) and w.ctrl:gtypeAvailable(lane.gtype)
           and w.ctrl:stakeAvailable(stakeOf(lane.stake)) then n = n + 1 end
    end
    return n
end

-- The next lane from the plan that is not yet on the board. These are
-- opened on affordability, not on payback: they are the bounty sweep, and
-- a bounty is a chip, which no $/minute score can see. Second return is
-- true when that lane's bounty is still unbanked this run, which is what
-- makes it worth taking a focus penalty for.
local function nextPlannedLane(w)
    for _, lane in ipairs(LANES) do
        if not laneOpen(w, lane) and w.ctrl:gtypeAvailable(lane.gtype)
           and w.ctrl:stakeAvailable(stakeOf(lane.stake)) then
            return lane, not w.ctrl:bountyBanked(lane.stake, lane.gtype)
        end
    end
end

-- One purchase, best-first. Returns a label when something was bought.
local function buyOnce(w)
    local ctrl, st = w.ctrl, w.state
    local n   = ctrl.pool:count()
    local cap = ctrl:currentFocusCapacity() + (Policy.tables_over_capacity or 0)

    -- 1. The plan's next lane -- but only once it is worth playing. A
    -- stake whose fill window has not opened is a hole in the bankroll,
    -- and the bounty on it is the most expensive chip in the game.
    local lane, unbanked = nextPlannedLane(w)
    if lane and not laneWorthOpening(w, lane.stake, lane.gtype) then
        lane, unbanked = nil, nil
    end
    if lane then
        local cost = laneCost(w, lane)
        if n >= cap then
            local up  = upgradeOf("focus")
            local fc  = (Policy.upgrade_caps or {}).focus or 0
            local lvl = ctrl:getRunUpgradeLevel("focus")
            if up and fc > 0 and lvl < math.min(fc, ctrl:getRunUpgradeMaxLevel(up) or 0) then
                local fcost = ctrl:getRunUpgradeNextCost(up)
                if affordable(w, (fcost or 0) + cost, true) and ctrl:buyRunUpgrade("focus") then
                    return ("focus L%d (room for %s %s)"):format(lvl + 1, lane.gtype, lane.stake)
                end
            end
        end
        if n < cap and affordable(w, cost) and n < ctrl:tableSlotsCap() then
            if ctrl:addTable(lane.stake, lane.gtype) then
                return ("open %s %s ($%.2f, ev %+.2f/hand)"):format(
                    lane.gtype, lane.stake, cost, laneEV(w, lane.stake, lane.gtype))
            end
        end
    end

    -- 2. The progression upgrades: bought whenever affordable, cheapest
    -- next first. Their return is a filled stake, not a better hourly.
    do
        local best_cost, best_id
        for _, id in ipairs(Policy.upgrade_always or {}) do
            local up  = upgradeOf(id)
            local lvl = ctrl:getRunUpgradeLevel(id)
            local capl = (Policy.upgrade_caps or {})[id] or 0
            if up and capl > 0 and lvl < math.min(capl, ctrl:getRunUpgradeMaxLevel(up) or 0) then
                local cost = ctrl:getRunUpgradeNextCost(up)
                if cost and affordable(w, cost, true) and (not best_cost or cost < best_cost) then
                    best_cost, best_id = cost, id
                end
            end
        end
        if best_id and ctrl:buyRunUpgrade(best_id) then
            return ("%s L%d ($%.2f)"):format(best_id, ctrl:getRunUpgradeLevel(best_id), best_cost)
        end
    end

    -- 3. Everything else competes on payback: cost / ($ per minute gained).
    local best
    local function offer(kind, id, cost, gain, label)
        if not cost or cost <= 0 or not gain or gain <= 0 then return end
        if not affordable(w, cost, kind == "upgrade") then return end
        local payback = cost / gain
        if payback > (Policy.upgrade_payback_minutes or 6) then return end
        if not best or payback < best.payback then
            best = { kind = kind, id = id, cost = cost, payback = payback, label = label }
        end
    end

    local base = boardRate(w)

    local ALWAYS = {}
    for _, id in ipairs(Policy.upgrade_always or {}) do ALWAYS[id] = true end
    for id, lvl_cap in pairs(Policy.upgrade_caps or {}) do
        if (lvl_cap or 0) > 0 and id ~= "focus" and not ALWAYS[id] then
            local up = upgradeOf(id)
            local lvl = ctrl:getRunUpgradeLevel(id)
            if up and lvl < math.min(lvl_cap, ctrl:getRunUpgradeMaxLevel(up) or 0) then
                local cost = ctrl:getRunUpgradeNextCost(up)
                local gain = withUpgrade(w, id, function() return boardRate(w) end) - base
                offer("upgrade", id, cost, gain, ("%s L%d ($%.2f)"):format(id, lvl + 1, cost or 0))
            end
        end
    end

    -- A duplicate lane: money only, no second bounty. Priced with the
    -- focus penalty the extra table would bring.
    if Policy.repeat_lanes and not lane and n < ctrl:tableSlotsCap()
       and (n + plannedSeatsWanted(w)) < cap then
        for _, l in ipairs(LANES) do
            if ctrl:gtypeAvailable(l.gtype) and ctrl:stakeAvailable(stakeOf(l.stake))
               and laneEV(w, l.stake, l.gtype) >= (Policy.lane_open_min_ev or 0) then
                local cost = laneCost(w, l)
                local gain = boardRate(w, l, n + 1) - base
                if n + 1 <= cap then
                    offer("lane", l, cost, gain, ("dup %s %s ($%.2f)"):format(l.gtype, l.stake, cost))
                end
            end
        end
    end

    -- Focus is only ever worth money because it lets another table on
    -- without the penalty, so it is priced together with that table.
    local fcap = Policy.upgrade_caps and Policy.upgrade_caps.focus or 0
    if fcap > 0 and n >= cap then
        local up  = upgradeOf("focus")
        local lvl = ctrl:getRunUpgradeLevel("focus")
        if up and lvl < math.min(fcap, ctrl:getRunUpgradeMaxLevel(up) or 0) then
            local fcost = ctrl:getRunUpgradeNextCost(up)
            local want  = lane or LANES[1]
            if fcost and want then
                local lcost = laneCost(w, want)
                local gain  = withUpgrade(w, "focus", function()
                    return boardRate(w, want, n + 1)
                end) - base
                offer("focus", "focus", fcost + lcost, gain,
                      ("focus L%d + %s %s ($%.2f)"):format(lvl + 1, want.gtype, want.stake, fcost + lcost))
            end
        end
    end

    if not best then return nil end
    if best.kind == "upgrade" then
        if ctrl:buyRunUpgrade(best.id) then return best.label end
    elseif best.kind == "focus" then
        if ctrl:buyRunUpgrade("focus") then return best.label end
    elseif best.kind == "lane" then
        if ctrl:addTable(best.id.stake, best.id.gtype) then return best.label end
    end
    return nil
end

-- ─── The catalog, between runs ──────────────────────────────────────────

local function owned(w, id)
    for _, o in ipairs(w.state.owned_items) do if o == id then return true end end
    return false
end

local function catalogItem(id)
    for _, it in ipairs(Catalog) do if it.id == id then return it end end
end

-- Same tests GrindController:buyCatalogItem and GameState:tryBuyCatalogItem
-- enforce; used only to RANK candidates. The purchase itself goes through
-- the controller, which is the authority.
local function canBuy(w, it)
    if not it or it.cost_chip == nil or it.cost_chip <= 0 then return false end
    if it.hidden or it.retired or it.granted_at_start then return false end
    if EXCLUDE[it.id] or owned(w, it.id) then return false end
    if it.requires and not owned(w, it.requires) then return false end
    if not require("models.catalog_loader").unlocked(it, w.state, w.game.unlock_rules) then return false end
    return w.state.chips >= it.cost_chip
end

local function spendChips(w, log)
    local bought = true
    while bought do
        bought = false
        for _, id in ipairs(PRIORITY) do
            local it = catalogItem(id)
            if canBuy(w, it) and w.ctrl:buyCatalogItem(id) then
                log[#log + 1] = id
                bought = true
                break
            end
        end
        if not bought then
            local cheapest
            for _, it in ipairs(Catalog) do
                if canBuy(w, it) and (not cheapest or it.cost_chip < cheapest.cost_chip) then
                    cheapest = it
                end
            end
            if cheapest and w.ctrl:buyCatalogItem(cheapest.id) then
                log[#log + 1] = cheapest.id
                bought = true
            end
        end
    end
end

-- ─── The shove ──────────────────────────────────────────────────────────

local function liveRates(w)
    -- At shove time every stack comes off the felt first, so the rate the
    -- player is deciding against is the one at bankroll + what is tied up.
    return ShoveRate.compute(w.ctrl.ctx, (w.state.bankroll or 0) + w.ctrl:tiedUp())
end

local function shove(w)
    local st, ctrl = w.state, w.ctrl
    local banked = st.chips_this_run or 0

    ctrl:initiateShove()          -- banks chips, sets has_shoved, writes shove_pending
    ctrl:cashOutAll(true)         -- ShoveState:enter does this before rating
    local ctx   = st:computeEffects(w.game.effects, Catalog, RunUpgrades)
    local rates = ShoveRate.compute(ctx, st.bankroll or 0)
    local outcomes = Gauntlet.rollOutcomes(st, rates)

    -- ── mirrors states/ShoveState.lua:248 settleRun ──
    local pending = st.shove_pending
    st.last_shove = {
        chips      = (pending and pending.chips) or 0,
        anti_chips = (pending and pending.anti_chips) or 0,
        won        = outcomes[1] == true,
    }
    if outcomes[1] and not st.shove_r1_won then st.shove_r1_won = true end
    if outcomes[2] and not st.shove_r2_won then st.shove_r2_won = true end
    st:resetRun()
    st.perks_pending = true
    ctrl:reloadPool()
    -- ── end mirror ──

    local log = {}
    spendChips(w, log)
    ctrl:applyPendingPerks()

    return { chips = banked, r1 = rates.r1, raw_r1 = rates.raw_r1,
             bankroll = rates.bankroll, won = outcomes[1] == true, bought = log }
end

-- ─── One run: grind until the policy says shove ─────────────────────────

local function playRun(w, shove_idx)
    local st, ctrl = w.state, w.ctrl
    local S = Policy.shove
    local t, last_progress = 0, 0
    local hist = {}            -- {t, r1} samples, one a second
    local limit = (Policy.max_run_minutes or 90) * 60

    while t < limit do
        -- one game-second of hands
        for _ = 1, 60 do stepFrame(w) end
        t = t + 1

        -- Bricked: no felt left and not enough for the cheapest buy-in.
        -- The engine offers a no-cost rescue for exactly this, and a player
        -- takes it rather than staring at a dead board. It banks the run's
        -- chips and reseeds WITHOUT a shove attempt.
        if ctrl:isStranded() and ctrl:canQuickReset() then return t, true end

        -- Close a table that has banked its bounty and is still losing
        -- money: it is a drain on the bankroll that gates the next stake.
        -- Rebuy the rest.
        for i = ctrl.pool:count(), 1, -1 do
            local tb = ctrl.pool:get(i)
            if tb and not tb.pending_close then
                local ev = laneEV(w, tb.stake_id, tb.game_type_id)
                if ev < (Policy.lane_close_ev or -0.01)
                   and ctrl:bountyBanked(tb.stake_id, tb.game_type_id) then
                    ctrl:removeTable(i)
                elseif (tb.stack or 0) <= 0 then
                    if ev >= (Policy.lane_close_ev or -0.01) then
                        local cost = ctrl:rebuyCostFor(i)
                        if affordable(w, cost) then ctrl:rebuyTable(i) end
                    else
                        ctrl:removeTable(i)   -- busted and not worth reseating
                    end
                end
            end
        end

        -- spend money while anything clears the bar
        local guard = 0
        while guard < 12 do
            local what = buyOnce(w)
            if not what then break end
            guard = guard + 1
            last_progress = t
            if OPT.verbose then print(("      %5ds  %s"):format(t, what)) end
        end

        -- shove check
        local rates = liveRates(w)
        hist[#hist + 1] = { t = t, r1 = rates.r1 }

        if t >= (S.min_run_minutes or 2) * 60 and ctrl:shoveUnlocked()
           and (st.chips_this_run or 0) > 0 then
            -- The opening run goes as soon as the board it already has is
            -- swept: the first shove is a tutorial beat, not an optimised
            -- one, and the ladder is not extended for it.
            if shove_idx == 1 and Policy.first_shove_asap then
                local done = true
                for _, tb in ipairs(ctrl.pool.tables) do
                    if not ctrl:bountyBanked(tb.stake_id, tb.game_type_id) then done = false end
                end
                if done then break end
            end
            -- every open lane has banked its bounty, and nothing planned is left
            local swept = (nextPlannedLane(w) == nil)
            for _, tb in ipairs(ctrl.pool.tables) do
                if not ctrl:bountyBanked(tb.stake_id, tb.game_type_id) then swept = false end
            end
            local patient = (t - last_progress) > (S.bounty_patience_minutes or 6) * 60
            if swept or patient then
                local win = (S.window_minutes or 3) * 60
                local old
                for i = #hist, 1, -1 do
                    if hist[i].t <= t - win then old = hist[i]; break end
                end
                if old then
                    local per_min = (rates.r1 - old.r1) / (S.window_minutes or 3)
                    if per_min < (S.r1_gain_per_minute_floor or 0.0015) then break end
                end
            end
        end
    end

    return t, false
end

-- ─── One playthrough ────────────────────────────────────────────────────

local function playthrough(seed)
    H.seed(seed)
    H.clock = 0
    local w = H.world({ bankroll = Constants.GAMEPLAY.INITIAL_BANKROLL,
                        act2 = false, gates = false })
    local shoves, elapsed, bails = {}, 0, 0
    while not w.state.shove_r1_won and #shoves < (Policy.max_shoves or 25) do
        local secs, stranded = playRun(w, #shoves + 1)
        -- A bail has no cinematic and no catalog spread to browse.
        elapsed = elapsed + secs + (stranded and 0 or (Policy.shove_overhead_seconds or 45))
        local n_tables = w.ctrl.pool:count()
        if stranded then
            local banked = w.state.chips_this_run or 0
            w.ctrl:quickReset()          -- banks the chips, reseeds, no gauntlet
            local log = {}
            spendChips(w, log)
            bails = bails + 1
            shoves[#shoves + 1] = { chips = banked, r1 = 0, won = false, bought = log,
                                    minutes = secs / 60, at = elapsed / 60,
                                    tables = n_tables, bail = true }
            if OPT.verbose then
                print(("   bail %d: bricked after %.1f min, %d {chip} kept"):format(#shoves, secs / 60, banked))
            end
            goto continue
        end
        local rec = shove(w)
        rec.minutes = secs / 60
        rec.at = elapsed / 60
        rec.tables = n_tables
        shoves[#shoves + 1] = rec
        if OPT.verbose then
            print(("   shove %d: %.1f min, %d {chip}, r1 %.1f%%, %s  [%s]"):format(
                #shoves, rec.minutes, rec.chips, rec.r1 * 100,
                rec.won and "WON" or "lost", table.concat(rec.bought, " ")))
        end
        ::continue::
    end
    return { seed = seed, shoves = shoves, minutes = elapsed / 60, bails = bails,
             cleared = w.state.shove_r1_won == true }
end

-- ─── Report ─────────────────────────────────────────────────────────────

local function minOf(t)
    local m = t[1]
    for _, v in ipairs(t) do if v < m then m = v end end
    return m or 0
end

local function maxOf(t)
    local m = t[1]
    for _, v in ipairs(t) do if v > m then m = v end end
    return m or 0
end

local function median(t)
    if #t == 0 then return 0 end
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    local m = math.floor(#s / 2)
    if #s % 2 == 1 then return s[m + 1] end
    return (s[m] + s[m + 1]) / 2
end

-- The designer's own Act 1, as reported: about an hour, banking 4, then
-- 7-9, then 15 a run (1+2+3 on Heads-Up doubled by the Fight Night Poster,
-- plus 1+2 on Zoom). The sim has to reproduce this before anything else it
-- prints is worth reading.
local OBSERVED = { chips = { 4, 8, 15, 15, 15 }, minutes = 60 }

local function run()
    print("Calibrating hands per minute off a live board...")
    calibrate()
    print(("  zoom %.0f/min   hu %.0f/min   six_max %.0f/min")
          :format(HPM.zoom or 0, HPM.hu or 0, HPM.six_max or 0))
    print(("Playing %d Act 1 seeds%s...\n"):format(OPT.seeds, OPT.six_max and " (six-max ON)" or ""))

    local runs, mins, counts = {}, {}, {}
    for s = 1, OPT.seeds do
        local r = playthrough(1000 + s)
        runs[#runs + 1] = r
        if r.cleared then
            mins[#mins + 1] = r.minutes
            counts[#counts + 1] = #r.shoves
        end
        io.write(("  seed %3d: %s in %.0f min over %d shoves   [%s]\n"):format(
            s, r.cleared and "CLEARED" or "gave up", r.minutes, #r.shoves,
            (function()
                local c = {}
                for i, sh in ipairs(r.shoves) do c[i] = tostring(sh.chips) end
                return table.concat(c, " ")
            end)()))
    end

    -- calibration: the median chip curve against the designer's own
    local curve = {}
    for i = 1, 5 do
        local col = {}
        for _, r in ipairs(runs) do if r.shoves[i] then col[#col + 1] = r.shoves[i].chips end end
        curve[i] = #col > 0 and median(col) or nil
    end

    local out = {}
    local function w(s) out[#out + 1] = s; print(s) end

    print("")
    w("# Act 1 simulation")
    w("")
    w(("> `lua sim/act1.lua --seeds=%d%s` on %s. Policy in `sim/act1_policy.lua`.")
      :format(OPT.seeds, OPT.six_max and " --six-max" or "", os.date("%Y-%m-%d")))
    w("")
    w("## Calibration")
    w("")
    w("The designer's own Act 1 banks 4, then 7-9, then 15 a run, takes about an hour, and then")
    w("keeps paying 15 a run for as long as it takes. The steady 15 is the load-bearing number:")
    w("it is 1+2+3 on Heads-Up doubled by the Fight Night Poster plus 1+2 on Zoom, so reproducing")
    w("it means the bounty model, the stake ladder and the Poster are all behaving.")
    w("")
    w("| shove | designer | sim (median) | |")
    w("|---|---|---|---|")
    local steady_ok, open_ok = true, true
    for i = 1, 5 do
        local d, g = OBSERVED.chips[i], curve[i]
        local hit = (d and g) and math.abs(g - d) <= math.max(2, d * 0.34) or false
        if i >= 3 then steady_ok = steady_ok and hit else open_ok = open_ok and hit end
        w(("| %d | %s | %s | %s |"):format(i, d and tostring(d) or "-",
            g and ("%.0f"):format(g) or "-", hit and "match" or "differs"))
    end
    local med_min = median(mins)
    local time_ok = med_min > 0 and med_min <= OBSERVED.minutes * 1.75
                    and med_min >= OBSERVED.minutes * 0.5
    w(("| total | ~%d min | %s | %s |"):format(OBSERVED.minutes,
        med_min > 0 and ("%.0f min"):format(med_min) or "-",
        time_ok and "match" or "differs"))
    w("")
    w(steady_ok
        and "- **Steady state (shoves 3+): matches.** The 15-a-run engine is reproduced."
        or  "- **Steady state (shoves 3+): DIFFERS.** This is the load-bearing check and it failed; the sim is not playing the game the designer plays, and no number below is worth reading.")
    w(open_ok
        and "- **Opening (shoves 1-2): matches.**"
        or  "- **Opening (shoves 1-2): differs.** The sim extends the stake ladder further before its first shoves than the designer does. `first_shove_asap` and the `lanes` order in `sim/act1_policy.lua` are the two knobs that move this.")
    w(time_ok
        and "- **Total time: matches.**"
        or  "- **Total time: differs.** Read the shove count and the r1 column before the minutes; a long total is usually variance in the gauntlet roll, not a slower grind.")
    w("")
    if not steady_ok then
        w("**Calibration FAILS on the check that matters.** Treat everything below as a bug report")
        w("about the policy, not as a fact about the game.")
    elseif open_ok and time_ok then
        w("**Calibration passes.**")
    else
        w("**Calibration partially passes**: the run engine is right, the opening policy is not the")
        w("designer's. Act 1 timings below are conditional on the policy as written.")
    end
    w("")
    w("## Result")
    w("")
    if #mins == 0 then
        w("No seed cleared Act 1 within the guards.")
    else
        w(("- Act 1 cleared in a median **%.0f minutes** (range %.0f-%.0f) over %d of %d seeds.")
          :format(med_min, minOf(mins), maxOf(mins), #mins, OPT.seeds))
        w(("- Median **%.0f shoves**."):format(median(counts)))
    end
    w("")
    w("## Per shove, seed 1")
    w("")
    w("| # | at | run | tables | {chip} | r1 | result | bought |")
    w("|---|---|---|---|---|---|---|---|")
    for i, sh in ipairs(runs[1].shoves) do
        w(("| %d | %.0f min | %.1f min | %d | %d | %.1f%% | %s | %s |"):format(
            i, sh.at, sh.minutes, sh.tables, sh.chips, sh.r1 * 100,
            sh.won and "**WON**" or "lost", table.concat(sh.bought, ", ")))
    end
    w("")

    local f = io.open("docs/act1-sim.md", "w")
    if f then f:write(table.concat(out, "\n") .. "\n"); f:close()
        print("\nWritten to docs/act1-sim.md")
    end
end

run()
