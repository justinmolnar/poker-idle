-- models/payout_breakdown.lua
--
-- "Where does 166× come from?"
--
-- By the time anything can be displayed, provenance is gone: every
-- catalog item, deck and run upgrade pours its effects into one flat ctx
-- table, and ctx.earnings_mult = 4.2 doesn't remember who made it 4.2.
-- Worse, several sources don't touch a multiplier at all — they move
-- probability between tiers, or raise win chance — so "list the
-- multipliers" would miss them entirely and still be wrong.
--
-- ─── How a source is priced ─────────────────────────────────────────────
--
-- By LEAVE-ONE-OUT. Compute the world as it is, then compute it again
-- without this one source, and compare. Whatever changed is what the
-- source is doing.
--
-- That's the only method that stays honest across the kinds of effect
-- this game actually has. It needs nothing declared on the item, so a new
-- perk is priced correctly the day it's added, and it prices a tier-shift
-- perk and a flat multiplier on the same axis without knowing the
-- difference between them.
--
-- ─── The metric ─────────────────────────────────────────────────────────
--
-- Per tier, expected dollars per hand from that tier:
--
--   win  tier T  →  P(win) × P(T | win) × avg_bb(T) × bb × payout_mult(T)
--   loss tier T  →  P(loss) × P(T | loss) × avg_bb(T) × bb × loss_mult(T)
--
-- Distribution AND multiplier are both inside it, which is what lets one
-- number describe both kinds of source. An item that turns a quarter of
-- Small wins into Medium reads as Small ×0.75, Medium ×1.4 — the truth,
-- and invisible to any multiplier-only readout.
--
-- ─── The caveat, stated plainly ─────────────────────────────────────────
--
-- Leave-one-out contributions do NOT compose into the total whenever
-- sources interact, and here they do: win chance is capped at 0.95, tier
-- shifts feed each other, dist cells renormalize. Two perks that each add
-- +0.1 win chance into a cap that only has room for 0.1 are each worth
-- almost nothing when removed alone, because the other one covers for it
-- — yet together they're worth the full 0.1. Neither number is wrong;
-- they answer different questions.
--
-- The TOTAL row is measured against a world with no sources at all, so it
-- is exact. The rows answer "what is this one doing for me", which is the
-- question worth asking of an item you're deciding whether to buy.

local OutcomeMath  = require("models.outcome_math")
local ShoveRate = require("models.shove_rate")
local Catalog      = require("data.catalog")
local RunUpgrades  = require("data.run_upgrades")
local Decks        = require("models.Decks")

local PayoutBreakdown = {}

local TIER_KEYS = OutcomeMath.TIER_KEYS

-- A ratio only means something when there's something to divide by. Below
-- this, expected dollars from a tier are rounding noise (a jackpot cell
-- pinned at zero, a tier the player structurally can't roll) and the
-- ratio would be an artifact.
local EPS = 1e-9

-- ─── Sources ────────────────────────────────────────────────────────────
-- Everything currently contributing to the rollup, with a display name.
-- Order is the order they're applied in computeEffects, so the list reads
-- the way the game builds it.
function PayoutBreakdown.sources(state)
    local out = {}

    local owned = {}
    for _, id in ipairs(state.owned_items or {}) do owned[id] = true end
    for _, item in ipairs(Catalog) do
        if item.granted_at_start then owned[item.id] = true end
    end
    for _, item in ipairs(Catalog) do
        if owned[item.id]
           and not (item.removed_by and owned[item.removed_by]) then
            out[#out + 1] = {
                id = item.id, kind = "catalog",
                name = item.display_name or item.name or item.id,
            }
        end
    end

    if Decks.systemUnlocked(state) then
        for _, id in ipairs(state.unlocked_decks or {}) do
            local spec  = Decks.specById(id)
            local level = (state.deck_levels and state.deck_levels[id]) or 0
            if spec and level > 0 then
                out[#out + 1] = {
                    id = id, kind = "deck", level = level,
                    name = (spec.display_name or spec.name or id),
                }
            end
        end
    end

    for _, item in ipairs(RunUpgrades) do
        local lvl = (state.run_upgrade_levels and state.run_upgrade_levels[item.id]) or 0
        if lvl > 0 then
            out[#out + 1] = {
                id = item.id, kind = "upgrade", level = lvl,
                name = (item.display_name or item.name or item.id),
            }
        end
    end

    return out
end

-- ─── Per-tier expected dollars ──────────────────────────────────────────
-- The metric described at the top, for one ctx.
local function profile(ctx, gtype, stake, opts)
    local wc, wd, ld = OutcomeMath.resolvedOutcome(ctx, gtype, stake)
    local bb = (stake and stake.bb) or 1
    local p  = { win = {}, loss = {}, win_total = 0, loss_total = 0 }
    -- Per-gtype bands + the seats-rule caps, mirroring evStats: the
    -- attribution must profile the same dollars the table can pay.
    local stack_bb = (bb > 0) and (((stake and stake.buy_in) or 0) / bb) or 0
    local win_cap, loss_cap
    if gtype and not gtype.chip_stack_table and stack_bb > 0 then
        win_cap  = OutcomeMath.maxWinBB(gtype, stack_bb)
        loss_cap = stack_bb
    end
    for _, t in ipairs(TIER_KEYS) do
        local w = wc * (wd[t] or 0) * OutcomeMath.tierAvgBB(t, gtype, true, win_cap) * bb
                  * OutcomeMath.payoutMult(ctx, stake, t, true, opts)
        local l = (1 - wc) * (ld[t] or 0) * OutcomeMath.tierAvgBB(t, gtype, false, loss_cap) * bb
                  * OutcomeMath.payoutMult(ctx, stake, t, false, opts)
        p.win[t], p.loss[t] = w, l
        p.win_total  = p.win_total  + w
        p.loss_total = p.loss_total + l
    end
    p.win_chance = wc
    p.ev         = p.win_total - p.loss_total
    return p
end
PayoutBreakdown.profile = profile

local function ratio(full, without)
    if math.abs(without) < EPS then
        if math.abs(full) < EPS then return 1, false, 0 end
        return nil, true, full
    end
    return full / without, false, full - without
end

-- ─── The breakdown ──────────────────────────────────────────────────────
-- `game` supplies state + the effects registry; gtype/stake pick the
-- table being described. `opts` goes to payoutMult (focus_mult, bankroll).
--
-- Returns:
--   { tiers = TIER_KEYS,
--     full  = <profile>,
--     base  = <profile with every source removed>,
--     total = { win = {[tier]=ratio}, loss = {...}, win_val = {...}, loss_val = {...}, ev = number },
--     rows  = { { name, kind, level,
--                 win = {[tier]=ratio|nil}, loss = {...},
--                 win_delta = {[tier]=number}, loss_delta = {...},
--                 ev_delta = number, matters = bool }, ... } }
function PayoutBreakdown.compute(game, gtype, stake, opts)
    if not game or not gtype or not stake then return nil end
    local state    = game.state
    local registry = game.effects
    if not state or not registry then return nil end

    local function ctxWithout(exclude)
        return state:computeEffects(registry, Catalog, RunUpgrades, nil, exclude)
    end

    local full_ctx = state.effects_cache or ctxWithout(nil)
    local full     = profile(full_ctx, gtype, stake, opts)

    local sources  = PayoutBreakdown.sources(state)

    local all = {}
    for _, s in ipairs(sources) do all[s.id] = true end
    local base = profile(ctxWithout(all), gtype, stake, opts)

    local rows = {}
    for _, s in ipairs(sources) do
        local without = profile(ctxWithout({ [s.id] = true }), gtype, stake, opts)
        local row = {
            name = s.name, kind = s.kind, level = s.level, id = s.id,
            win = {}, loss = {}, win_delta = {}, loss_delta = {},
            ev_delta = full.ev - without.ev,
        }
        local matters = math.abs(row.ev_delta) > EPS
        for _, t in ipairs(TIER_KEYS) do
            local wr, wnew, wdelta = ratio(full.win[t],  without.win[t])
            local lr, lnew, ldelta = ratio(full.loss[t], without.loss[t])
            row.win[t], row.loss[t] = wr, lr
            row.win_delta[t], row.loss_delta[t] = wdelta, ldelta
            if wnew or lnew then matters = true end
            if wr and math.abs(wr - 1) > 1e-6 then matters = true end
            if lr and math.abs(lr - 1) > 1e-6 then matters = true end
        end
        row.matters = matters
        rows[#rows + 1] = row
    end

    local total = { win = {}, loss = {}, win_val = {}, loss_val = {}, full_win = full.win, full_loss = full.loss, ev = full.ev - base.ev }
    for _, t in ipairs(TIER_KEYS) do
        local wr, wnew, wdelta = ratio(full.win[t],  base.win[t])
        local lr, lnew, ldelta = ratio(full.loss[t], base.loss[t])
        total.win[t], total.loss[t] = wr, lr
        total.win_val[t], total.loss_val[t] = wdelta, ldelta
    end

    return {
        tiers = TIER_KEYS,
        full  = full,
        base  = base,
        total = total,
        rows  = rows,
    }
end

-- Cached wrapper. The computation is O(sources²) applicator calls, which
-- is cheap but not free, and nothing about it changes until the rollup
-- does — so it's keyed on the effects_cache identity plus the table being
-- described. invalidateEffects replaces that table, which invalidates
-- this for free.
local _cache = { key = nil, value = nil }

function PayoutBreakdown.cached(game, gtype, stake, opts)
    if not game or not gtype or not stake then return nil end
    -- Bankroll enters through earnings_scale_by_bankroll as the BANK
    -- multiplier, so the cache is bucketed by that multiplier's value: the
    -- displayed number moves when the multiplier does, and a bankroll
    -- ticking up every hand doesn't rebuild the whole thing every frame.
    local br  = (opts and opts.bankroll) or 0
    local key = tostring(game.state and game.state.effects_cache)
                .. "|" .. tostring(gtype.id) .. "|" .. tostring(stake.id)
                .. "|" .. string.format("%.4f", (opts and opts.focus_mult) or 1)
                .. "|" .. string.format("%.3f", ShoveRate.bankrollMultiplier(br))
    if _cache.key == key then return _cache.value end
    _cache.key   = key
    _cache.value = PayoutBreakdown.compute(game, gtype, stake, opts)
    return _cache.value
end

return PayoutBreakdown
