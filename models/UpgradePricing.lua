-- models/UpgradePricing.lua
--
-- Prices the fill-scaled run upgrades (Sharper Reads, Pot Control) in
-- TIME, from the game's own outcome math, once at boot. Nothing here knows
-- how many levels or stakes exist; add a stake, move a buy-in, retune a
-- stake's win numbers, and the prices follow.
--
-- Fixed-length upgrades (Cursor, Cursor Speed, Focus) declare `maxes_at`
-- and ride the same curve: see the loop at the bottom.
--
-- The rule, for level L of a fill-scaled upgrade:
--
--   cost(L) = EV$/hand(best table at fill L-1, reference board)
--             × tables_ref × HANDS(L) × upgrade.cost_mult
--   HANDS(L) = Balance.UPGRADE_HANDS_FIRST × Balance.UPGRADE_HANDS_GROWTH ^ (L-1)
--
-- HANDS(L) is the pacing curve: how many rounds of the whole board the
-- player waits for the next level. It only ever grows, so the game starts
-- fast and slows down. "Best table at fill L-1" is the most profitable
-- stake × game type the previous level made playable, so a level is
-- priced against the table the player is actually sitting at; the
-- ladder's steps enter through EV$/hand, never through a typed ratio.
--
-- The reference board (Balance.UPGRADE_REFERENCE, keyed by the stake's
-- `band`) is a deliberately item-less player with that band's expected
-- table count and decks: items are the real player's edge, decks are the
-- intended accelerator from Act 2 on and without them the high stakes
-- are −EV even capped. The band for level L is the band of the stake
-- that OWNS L: the stake whose fill window L completes (the level after
-- the previous stake's window completes up to this one's completion).
-- So NL10K's three levels are priced against an Act 2 board, NL100's
-- against an Act 1 board, and the ladder's step between them shows up
-- as the income step between those boards.
--
-- The raw per-level prices spike wherever the best table changes; the
-- final curve is those prices with the log-steps Gaussian-smoothed
-- (Balance.UPGRADE_RAMP_SMOOTHING) so the climb is a ramp, not stairs.
--
-- EV comes from GameState:computeEffects → OutcomeMath.evStats, the same
-- path the live game and the balance tool use, so the three never diverge.

local GameState   = require("models.GameState")
local OutcomeMath = require("models.outcome_math")
local Balance     = require("data.balance")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local Catalog     = require("data.catalog")

local UpgradePricing = {}

-- owner[L] = the stake whose window L belongs to (Ultra has no window).
local function ownersByLevel(refs)
    local owner, prev = {}, 0
    for _, s in ipairs(Stakes) do
        local fw = s.fill_window
        if fw and refs[s.band] then
            for L = prev + 1, fw.complete do owner[L] = s end
            prev = math.max(prev, fw.complete)
        end
    end
    return owner, prev
end

local function gtypesFor(ref)
    if type(ref.gtypes) == "table" then return ref.gtypes end
    local ids = {}
    for _, gt in ipairs(GameTypes) do
        if not gt.chip_stack_table then ids[#ids + 1] = gt.id end
    end
    return ids
end

local function tablesFor(ref, level)
    local n = ref.tables or 1
    if ref.tables_ramp then n = math.min(n, level) end
    return math.max(1, n)
end

-- A throwaway state shaped like the reference player at fill `fill`.
local function referenceState(fill, run_upgrades, ref)
    local st = GameState:new()
    st.owned_items = {}
    st.run_upgrade_levels = {}
    for _, u in ipairs(run_upgrades) do
        if u.fill_scaled then st.run_upgrade_levels[u.id] = fill end
    end
    st.unlocked_decks, st.deck_levels, st.deck_xp = {}, {}, {}
    if ref.decks and next(ref.decks) then
        st.shove_r1_won = true   -- the deck system exists for this player
        for id, lvl in pairs(ref.decks) do
            st.unlocked_decks[#st.unlocked_decks + 1] = id
            st.deck_levels[id] = lvl
            st.deck_xp[id] = 0
        end
        table.sort(st.unlocked_decks)
    end
    return st
end

-- Most profitable stake × game type for this reference at this fill.
local function bestTable(fill, level, run_upgrades, registry, ref)
    local st  = referenceState(fill, run_upgrades, ref)
    local n   = tablesFor(ref, level)
    local ctx = st:computeEffects(registry, Catalog, run_upgrades, { active_tables_count = n })
    local best = nil
    for _, stake in ipairs(Stakes) do
        -- Only tables the fill has begun to shape are candidates: a stake
        -- whose window hasn't started is not something the previous level
        -- made playable, whatever the decks do to its naked numbers.
        local fw = stake.fill_window
        local started = fw and fw.start <= fill
        for _, gid in ipairs(started and gtypesFor(ref) or {}) do
            local gtype
            for _, gt in ipairs(GameTypes) do if gt.id == gid then gtype = gt end end
            local stats = gtype and OutcomeMath.evStats(ctx, gtype, stake, {})
            local ev = stats and stats.pool and stats.pool.ev_per_hand
            if ev and (not best or ev > best.ev) then
                best = { ev = ev, stake = stake, gtype = gtype, tables = n }
            end
        end
    end
    return best
end

-- Fill `costs` and `max_level` on every fill-scaled upgrade in place.
function UpgradePricing.apply(run_upgrades, registry)
    local refs = Balance.UPGRADE_REFERENCE
    assert(refs, "UpgradePricing: Balance.UPGRADE_REFERENCE missing")
    local owner, max_level = ownersByLevel(refs)
    assert(max_level > 0, "UpgradePricing: no windowed stake with a priced band")

    local base = {}
    local prev = 0
    for L = 1, max_level do
        local ref  = refs[owner[L].band]
        local best = bestTable(L - 1, L, run_upgrades, registry, ref)
        assert(best and best.ev > 0,
            ("UpgradePricing: nothing profitable at fill %d on the %s board"):format(L - 1, tostring(owner[L].band)))
        local hands = Balance.UPGRADE_HANDS_FIRST * Balance.UPGRADE_HANDS_GROWTH ^ (L - 1)
        local cost  = best.ev * best.tables * hands
        assert(cost > prev, ("UpgradePricing: L%d ($%.4g) not above L%d ($%.4g)"):format(L, cost, L - 1, prev))
        base[L] = cost
        prev = cost
    end

    -- Ramp smoothing. The loop above prices each level against the table
    -- the player is on, so the per-level ratio spikes wherever the best
    -- table changes (a ×100 stake step arrives all at once). A ramp does
    -- not do that: the same distance is travelled, but the ratio drifts
    -- there over neighbouring levels. Gaussian-smooth the log-steps with
    -- Balance.UPGRADE_RAMP_SMOOTHING as sigma (in levels; 0 = off), then
    -- rescale so the total climb from L1 to the last level is unchanged.
    local sigma = Balance.UPGRADE_RAMP_SMOOTHING or 0
    if sigma > 0 and max_level > 2 then
        local steps = {}
        for L = 2, max_level do steps[L] = math.log(base[L] / base[L - 1]) end
        local total = 0
        for L = 2, max_level do total = total + steps[L] end
        local smooth, smooth_total = {}, 0
        for L = 2, max_level do
            local acc, wsum = 0, 0
            for M = 2, max_level do
                local w = math.exp(-((M - L) ^ 2) / (2 * sigma * sigma))
                acc, wsum = acc + w * steps[M], wsum + w
            end
            smooth[L] = acc / wsum
            smooth_total = smooth_total + smooth[L]
        end
        local scale = total / smooth_total
        for L = 2, max_level do base[L] = base[L - 1] * math.exp(smooth[L] * scale) end
    end

    -- Rounded here so the sweep and the workbench see clean numbers; the
    -- price the player sees and pays is rounded again AFTER discounts by
    -- GrindController (UpgradePricing.roundPrice), which is the one that
    -- matters — a 15% discount on a round number is not a round number.
    local roundSig = UpgradePricing.roundPrice

    for _, u in ipairs(run_upgrades) do
        if u.fill_scaled then
            local mult = u.cost_mult or 1
            u.costs = {}
            for L = 1, max_level do u.costs[L] = roundSig(base[L] * mult) end
            u.max_level = max_level
        elseif u.maxes_at then
            -- A fixed-length upgrade that should max at `maxes_at`: its M
            -- levels span the fill curve from L1 to that stake's last
            -- owned level, log-interpolated, × cost_mult. Follows the
            -- ladder and the outcome model like everything above.
            local top
            for _, s in ipairs(Stakes) do
                if s.id == u.maxes_at and s.fill_window then top = s.fill_window.complete end
            end
            assert(top and top <= max_level,
                ("UpgradePricing: %s maxes_at %s has no priced window"):format(u.id, tostring(u.maxes_at)))
            local M = u.max_level or 1
            local mult = u.cost_mult or 1
            u.costs = {}
            for k = 1, M do
                local pos = (M > 1) and (1 + (k - 1) / (M - 1) * (top - 1)) or top
                local lo, hi = math.floor(pos), math.ceil(pos)
                local c
                if lo == hi then c = base[lo]
                else
                    local f = pos - lo
                    c = math.exp(math.log(base[lo]) * (1 - f) + math.log(base[hi]) * f)
                end
                u.costs[k] = roundSig(c * mult)
            end
        end
    end
    return base
end

-- Round a price to Balance.UPGRADE_PRICE_SIG_FIGS significant figures
-- (2: 535,323,234.44 → 540,000,000; 1.19 → 1.2; 0.136 → 0.14). Applied to
-- every derived price and again to the final discounted price, so what the
-- sidebar shows is exactly what is charged. Monotone, so a ramp keeps its
-- order.
function UpgradePricing.roundPrice(x)
    if not (x and x > 0) then return x end
    local sig = Balance.UPGRADE_PRICE_SIG_FIGS or 2
    local e = math.floor(math.log(x) / math.log(10) + 1e-9) - (sig - 1)
    local m = 10 ^ e
    return math.floor(x / m + 0.5) * m
end

return UpgradePricing
