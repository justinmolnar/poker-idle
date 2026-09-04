-- tools/sim_bridge.lua
--
-- The catalog designer's Lua-side bridge, executed by fengari inside
-- tools/catalog_designer.html and headlessly by tools/balance_sweep.js.
-- NOT part of the game — the game never loads this file.
--
-- Design rule: this file contains NO outcome math. It orchestrates the
-- game's own modules (models/outcome_math.lua, models/poker_effects.lua,
-- services/EffectsRegistry.lua) so the simulator can never diverge from
-- the game on EV. The only mirrored logic, kept deliberately tiny:
--
--   • buildCtx      mirrors models/GameState.lua:computeEffects (:728)
--                   minus decks / run-ratchets / save-state
--   • focusMult     mirrors controllers/GrindController.lua:currentFocusMult (:536)
--   • bountyAward   mirrors controllers/GrindController.lua:bountyAward (:1444)
--
-- If any of those three change in the game, change them here too.
-- All requests/responses are JSON strings (vendor/json.lua, rxi).
--
-- Request shape (all fields optional except stake_id/gtype_id):
--   { equipped = {ids}, corrupted = {ids}, upgrades = {id = level},
--     extra_effects = { {kind=..., ...}, ... },   -- synthetic item applied LAST
--     transient = { active_tables_count = n },
--     opts = { bankroll = $, use_focus = bool, corner = bool },
--     stake_id = "s001", gtype_id = "six_max" }

love = love or { math = { random = math.random } }

local json = require("json")

local Constants = require("data.constants")
-- The tool always simulates the FULL catalog; the demo cut is a build
-- concern, not a balance concern.
Constants.FEATURES.DEMO_CUT = false

local Catalog        = require("data.catalog")
local CatalogPages   = require("data.catalog_pages")
local RunUpgrades    = require("data.run_upgrades")
local EffectKinds    = require("data.effects").kinds
local Stakes         = require("data.stakes")
local GTypes         = require("data.game_types")
local Procs          = require("data.procs")
local Routers        = require("data.routers")
local Balance        = require("data.balance")
local OutcomeMath    = require("models.outcome_math")
local PokerEffects   = require("models.poker_effects")
local EffectsRegistry= require("services.EffectsRegistry")
local Lookups        = require("utils.lookups")
local Decks          = require("models.Decks")
local DeckSpecs      = require("data.decks")

local reg = EffectsRegistry:new()
PokerEffects.registerAll(reg)
-- Same derivation the game runs at boot, so the tool reports the game's
-- upgrade prices.
require("models.UpgradePricing").apply(RunUpgrades, reg)

local function toSet(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

-- ── mirror of GameState:computeEffects (models/GameState.lua:728-853) ──
-- Differences on purpose: no decks, no run ratchets, no sources tally,
-- no cache; run-upgrade levels come from the request, not save state.
-- `extra_effects` is a tool-only addition: a synthetic effect block applied
-- after everything else, used to value one-shot proc payloads (a marked
-- pot, a sharp stack, a ratchet) through the same registry.
local function buildCtx(req, exclude)
    local ctx = {}
    -- Every transient the controller would seed (active_tables_count,
    -- board_pure_gtype, unbanked…) comes straight from the request.
    for k, v in pairs(req.transient or {}) do ctx[k] = v end
    ctx.active_tables_count = ctx.active_tables_count or 1

    local owned = toSet(req.equipped)
    for _, item in ipairs(Catalog) do
        if item.granted_at_start then owned[item.id] = true end
    end
    local corrupted = toSet(req.corrupted)

    for _, item in ipairs(Catalog) do
        if owned[item.id]
           and not (exclude and exclude[item.id])
           and not (item.removed_by and owned[item.removed_by]) then
            if corrupted[item.id] and item.corrupt and item.corrupt.effects then
                reg:applyAll({ effects = item.corrupt.effects }, ctx)
            else
                reg:applyAll(item, ctx)
            end
        end
    end

    -- Run upgrades: level N applies the effect block N times; the
    -- Calculator's strength mult scales per the kind's `scale` metadata.
    -- (Same block as GameState.lua:806-841.)
    local upgrade_mult = ctx.run_upgrade_strength_mult or 1.0
    for _, item in ipairs(RunUpgrades) do
        local lvl = (req.upgrades and req.upgrades[item.id]) or 0
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
                        -- untouched: floored downstream / per-level gain
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
                reg:applyN({ effects = scaled_effects }, ctx, lvl)
            else
                reg:applyN(item, ctx, lvl)
            end
        end
    end

    -- (Decks are applied by the wrapper below, in the game's order.)
    if req.extra_effects and #req.extra_effects > 0 then
        reg:applyAll({ effects = req.extra_effects }, ctx)
    end
    return ctx
end

-- Wrapper that puts decks in the game's order (catalog → decks → run
-- upgrades → extra). buildCtx above is kept as the catalog+upgrades core;
-- this rebuilds when decks are present so the Investor deck's strength
-- mult reaches the upgrade loop exactly as GameState:computeEffects does.
local buildCtxCore = buildCtx
buildCtx = function(req, exclude)
    local decks = req.decks
    if not decks or next(decks) == nil then return buildCtxCore(req, exclude) end
    -- 1. catalog only
    local ctx = buildCtxCore({ equipped = req.equipped, corrupted = req.corrupted,
                               transient = req.transient }, exclude)
    -- 2. decks (game code)
    local unlocked, levels, total = {}, {}, 0
    for id, lvl in pairs(decks) do
        if (lvl or 0) > 0 then
            unlocked[#unlocked + 1] = id; levels[id] = lvl; total = total + lvl
        end
    end
    table.sort(unlocked)
    ctx.total_deck_levels = total
    Decks.applyEffects({ unlocked_decks = unlocked, deck_levels = levels }, reg, ctx)
    -- 3. run upgrades + extra, on top of the deck-bearing ctx
    local upgrade_mult = ctx.run_upgrade_strength_mult or 1.0
    for _, item in ipairs(RunUpgrades) do
        local lvl = (req.upgrades and req.upgrades[item.id]) or 0
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
                reg:applyN({ effects = scaled_effects }, ctx, lvl)
            else
                reg:applyN(item, ctx, lvl)
            end
        end
    end
    if req.extra_effects and #req.extra_effects > 0 then
        reg:applyAll({ effects = req.extra_effects }, ctx)
    end
    return ctx
end

-- ── mirror of GrindController:currentFocusMult (:536) + capacity (:563) ──
local function focusMult(ctx, n_tables)
    if ctx.focus_penalty_immune then return 1.0 end
    local cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
              + math.floor(ctx.focus_capacity or 0)
    local extra = (n_tables or 1) - cap
    if extra <= 0 then return 1.0 end
    local mult = 1 - Constants.GAMEPLAY.FOCUS_BASE_PENALTY
                   * (ctx.focus_penalty_reduce_mult or 1) * extra
    if mult < Constants.GAMEPLAY.FOCUS_FLOOR then
        mult = Constants.GAMEPLAY.FOCUS_FLOOR
    end
    return mult
end

-- One evaluation. Returns (response_table, ctx).
local function evalOne(req, exclude)
    local ctx   = buildCtx(req, exclude)
    local stake = Lookups.findById(Stakes, req.stake_id)
    local gtype = Lookups.findById(GTypes, req.gtype_id)
    if not stake or not gtype then
        error("unknown stake/gtype: " .. tostring(req.stake_id) .. "/" .. tostring(req.gtype_id))
    end
    -- What-ifs: `stake_override[stake_id] = { <any stake field> }`
    -- evaluates a copy of the stake with those fields replaced (money
    -- units, win_chance, dists, fill_window…). Index lookups go by id, so
    -- a copy is safe.
    local ov = req.stake_override and req.stake_override[req.stake_id]
    if ov then
        local copy = {}
        for k, v in pairs(stake) do copy[k] = v end
        for k, v in pairs(ov) do copy[k] = v end   -- any stake field: bb, buy_in, win_chance, dists…
        if ov.bb and not ov.sb then copy.sb = ov.bb / 2 end
        stake = copy
    end
    local opts = {}
    local o = req.opts or {}
    if o.use_focus then opts.focus_mult = focusMult(ctx, ctx.active_tables_count) end
    if o.bankroll then opts.bankroll = o.bankroll end

    local stats = OutcomeMath.evStats(ctx, gtype, stake, opts)
    local p = stats.pool
    -- E[$ | win] and E[$ | loss], multipliers included (the evStats
    -- internals win_cash / loss_cash, recovered from per_tier).
    local w_cash, l_cash = 0, 0
    for _, t in pairs(stats.per_tier) do
        w_cash = w_cash + t.win_p * t.win_cash
        l_cash = l_cash + t.loss_p * t.loss_cash
    end
    -- corner_win_chance is added OUTSIDE buildOutcome in Table:deal (:492,
    -- slot 0 only) and is invisible to evStats; report it separately.
    local corner = (o.corner and ctx.corner_win_chance) or 0
    local resp = {
        wc = p.win_chance, wd = p.win_dist, ld = p.loss_dist,
        ev_per_hand = p.ev_per_hand,
        ev_bb       = p.ev_per_hand / (stake.bb ~= 0 and stake.bb or 1),
        win_avg_bb  = p.win_avg_bb, loss_avg_bb = p.loss_avg_bb,
        w_cash = w_cash, l_cash = l_cash,
        stack_pct      = p.win_chance * (p.win_dist.stack or 0) * 100,
        loss_stack_pct = (1 - p.win_chance) * (p.loss_dist.stack or 0) * 100,
        hand_pace_mult = (ctx.hand_pace_mult or 1)
                         * ((ctx.hand_pace_mult_by_gtype or {})[gtype.id] or 1),
        focus_mult     = opts.focus_mult,
        corner_add     = corner,
        bb = stake.bb, buy_in = stake.buy_in,
    }
    if gtype.chip_stack_table then
        resp.ko = {
            net_ev_run = p.net_ev_run, roi_pct = p.roi_pct,
            exp_payout = p.exp_payout, exp_hands = p.exp_hands,
            buy_in = p.buy_in, pos_probs = p.pos_probs,
        }
    end
    return resp, ctx
end

Bridge = {}

function Bridge.info(_)
    local stakes, gtypes, upgrades, catalog = {}, {}, {}, {}
    for i, s in ipairs(Stakes) do
        stakes[i] = { id = s.id, display_name = s.display_name, bb = s.bb,
                      buy_in = s.buy_in, chip_award = s.chip_award, band = s.band,
                      win_chance = s.win_chance, win_chance_capped = s.win_chance_capped,
                      fill_window = s.fill_window }
    end
    for i, g in ipairs(GTypes) do
        gtypes[i] = { id = g.id, name = g.name,
                      chip_stack_table = g.chip_stack_table or false,
                      seats = g.seats, pace_mult = g.pace_mult }
    end
    for i, u in ipairs(RunUpgrades) do
        upgrades[i] = { id = u.id, name = u.name, max_level = u.max_level or 1,
                        fill_scaled = u.fill_scaled or false, costs = u.costs,
                        effects = u.effects }
    end
    local decks = {}
    for i, d in ipairs(DeckSpecs) do
        decks[i] = { id = d.id, name = d.name, max_level = d.max_level or 5,
                     xp_rule = d.xp_rule, xp_curve = d.xp_curve,
                     effects = d.effects, capstone = d.capstone and d.capstone.effects or nil }
    end
    for i, c in ipairs(Catalog) do
        catalog[i] = { id = c.id, name = c.name, cost_chip = c.cost_chip,
                       phase = c.phase, act = c.act, hidden = c.hidden or false,
                       gate = c.gate or false, requires = c.requires,
                       granted_at_start = c.granted_at_start or false,
                       effects = c.effects or {},
                       corrupt = c.corrupt and { cost_achip = c.corrupt.cost_achip,
                                                 effects = c.corrupt.effects or {} } or nil,
                       effect_text = c.effect_text }
    end
    return json.encode({
        stakes = stakes, gtypes = gtypes, upgrades = upgrades, catalog = catalog, decks = decks,
        pages = CatalogPages, procs = Procs, routers = Routers,
        balance = {
            RUN_MINUTES = Balance.RUN_MINUTES, K_SHOVE_PER_ITEM = Balance.K_SHOVE_PER_ITEM,
            ACT1_RUNS_TO_CLEAR = Balance.ACT1_RUNS_TO_CLEAR,
            ACT1_SHOVE_TARGET = Balance.ACT1_SHOVE_TARGET,
            ACT1_ITEM_COUNT = Balance.ACT1_ITEM_COUNT,
        },
        focus = {
            base_capacity = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY,
            base_penalty  = Constants.GAMEPLAY.FOCUS_BASE_PENALTY,
            floor         = Constants.GAMEPLAY.FOCUS_FLOOR,
            max_tables    = Constants.GAMEPLAY.MAX_TABLES,
        },
    })
end

function Bridge.eval(jreq)
    local req = json.decode(jreq)
    local resp = evalOne(req)
    return json.encode(resp)
end

-- Many evaluations in one round-trip. Each entry is a full request; a
-- failing entry yields { err = "..." } instead of aborting the batch.
function Bridge.batch(jreq)
    local reqs = json.decode(jreq)
    local out = {}
    for i, req in ipairs(reqs) do
        local ok, res = pcall(evalOne, req)
        out[i] = ok and res or { err = tostring(res) }
    end
    return json.encode(out)
end

-- Leave-one-out for equipped items, add-one-in for the rest. Mirrors the
-- attribution idea in models/payout_breakdown.lua:164 (exclude-and-recompute).
function Bridge.marginals(jreq)
    local req  = json.decode(jreq)
    local base = evalOne(req)
    local equipped = toSet(req.equipped)
    local rows = {}
    for _, item in ipairs(Catalog) do
        if not item.hidden then
            local row = { id = item.id, equipped = equipped[item.id] or false }
            local ok, res
            if equipped[item.id] then
                ok, res = pcall(evalOne, req, { [item.id] = true })
                if ok then
                    row.delta_ev    = base.ev_per_hand - res.ev_per_hand
                    row.delta_stack = base.stack_pct - res.stack_pct
                end
            else
                local req2 = { equipped = {}, corrupted = req.corrupted,
                               upgrades = req.upgrades, transient = req.transient,
                               opts = req.opts, stake_id = req.stake_id,
                               gtype_id = req.gtype_id, extra_effects = req.extra_effects }
                for _, id in ipairs(req.equipped or {}) do table.insert(req2.equipped, id) end
                table.insert(req2.equipped, item.id)
                ok, res = pcall(evalOne, req2)
                if ok then
                    row.delta_ev    = res.ev_per_hand - base.ev_per_hand
                    row.delta_stack = res.stack_pct - base.stack_pct
                end
            end
            if not ok then row.err = tostring(res) end
            table.insert(rows, row)
        end
    end
    return json.encode({ base_ev = base.ev_per_hand, rows = rows })
end

-- ── mirror of GrindController:bountyAward (:1444-1455) ──
function Bridge.bounty(jreq)
    local req = json.decode(jreq)
    local ctx = buildCtx(req)
    local out = {}
    for i, lane in ipairs(req.lanes or {}) do
        local stake = Lookups.findById(Stakes, lane.stake_id)
        local mult = ctx.chip_award_mult or 1
        if ctx.bounty_gtype_mult and ctx.bounty_gtype_mult[lane.gtype_id] then
            mult = mult * ctx.bounty_gtype_mult[lane.gtype_id]
        end
        local award = math.floor((stake.chip_award or 0) * mult + 0.5)
                    + (ctx.stack_chip_add or 0)
        -- Odds of the stack-tier win that banks the bounty, for the
        -- hands-to-first estimate. Lane-specific ctx is the same build.
        local lreq = { equipped = req.equipped, corrupted = req.corrupted,
                       upgrades = req.upgrades, transient = req.transient,
                       opts = req.opts, stake_id = lane.stake_id,
                       gtype_id = lane.gtype_id }
        local ok, res = pcall(evalOne, lreq)
        local stack_odds = ok and (res.wc * (res.wd.stack or 0)) or 0
        out[i] = { stake_id = lane.stake_id, gtype_id = lane.gtype_id,
                   award = award, stack_per_hand = stack_odds,
                   hands_to_stack = (stack_odds > 0) and (1 / stack_odds) or nil }
    end
    return json.encode({ lanes = out,
                         first_bounty_bonus = ctx.first_bounty_bonus or 0 })
end

return Bridge
