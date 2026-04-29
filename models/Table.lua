-- models/Table.lua
--
-- A single ticking poker table. Per-hand state machine: the player clicks
-- DEAL, the outcome is rolled at deal-time from the 3-distribution outcome
-- model, then cards are constructed via rejection sampling so what's drawn
-- matches the rolled win/lose. Animation timeline plays over ~2.2 seconds,
-- ending in settling that returns the resolution to the controller.
--
-- ─── State machine ─────────────────────────────────────────────────────
--   idle / dealing / flop / turn / river / showdown / settling → idle.
--   Resolution returns on the transition INTO settling.
--
-- ─── Math layer (3-distribution outcome model) ─────────────────────────
-- Each hand resolves through three independent dimensions:
--
--   • win_chance — single probability ∈ [0, 1] that the hand is a Win
--   • win_dist   — { tiny, small, medium, jackpot } sums to 1; sampled
--                  when winning
--   • loss_dist  — { tiny, small, medium, jackpot } sums to 1; sampled
--                  when losing
--
-- Each stake declares both naked AND run-capped values for these three.
-- Run upgrades push fill descriptors onto ctx lists; the sum of matching
-- descriptor strengths becomes "fill units" that lerp the dimension from
-- naked toward run-capped via the stake's fill_window. Catalog perks add
-- flat additive bumps on top — the only mechanism for crossing run-capped
-- toward the absolute 0.95 WC ceiling.
--
-- Pipeline (buildOutcome(opp, ctx, gtype, stake)):
--   1. Sum fill units per dimension (only descriptors that match opp/gtype).
--   2. Convert units → fill ratio via stake.fill_window {start, complete}.
--   3. Lerp naked → run-capped per dimension.
--   4. Skill bump on WC (additive).
--   5. Style additive shape on dists.
--   6. Gtype additive shape on dists.
--   7. Catalog ctx.win_chance_shifts (additive on top of lerp).
--   8. Clamp WC to [0, 0.95]. Clamp dist cells ≥0 and renormalize.
--
-- Per hand:
--   1. Pick opponent uniformly from seated.
--   2. buildOutcome → (win_chance, win_dist, loss_dist).
--   3. sampleOutcome → (won, tier).
--   4. magnitude_bb = uniform(tier_bb_ranges[tier]).
--   5. delta = ±magnitude × stake.bb × (earnings_mult on win, loss_mult on lose).
--   6. Construct cards (rejection sampling) so best5(player) beats / loses
--      to best5(opp), matching the rolled `won`.

local RNG           = require("utils.rng")
local Deck          = require("models.Deck")
local Opponent      = require("models.Opponent")
local HandEval      = require("utils.hand_eval")
local StakesData    = require("data.stakes")
local GameTypesData = require("data.game_types")
local NameData      = require("data.opponent_names")
local OpTypes       = require("data.opponent_types")

local Table = {}
Table.__index = Table

local LAST_RESULTS_CAP = 5
local CONSTRUCTION_CAP = 200

-- State timeline (cumulative seconds since :deal()).
local PHASE_DEAL_END     = 0.40
local PHASE_FLOP_END     = 0.80
local PHASE_TURN_END     = 1.10
local PHASE_RIVER_END    = 1.40
local PHASE_SHOWDOWN_END = 1.80
local PHASE_SETTLE_END   = 2.20

-- ─── Helpers ──────────────────────────────────────────────────────────

local function findStake(id)
    for _, s in ipairs(StakesData) do
        if s.id == id then return s end
    end
end

local function findGameType(id)
    for _, gt in ipairs(GameTypesData) do
        if gt.id == id then return gt end
    end
end

local function sampleDist(dist)
    if not dist then return nil end
    local total = 0
    for _, p in pairs(dist) do total = total + p end
    if total <= 0 then
        for k in pairs(dist) do return k end
    end
    local r = love.math.random() * total
    local acc = 0
    for k, p in pairs(dist) do
        acc = acc + p
        if r <= acc then return k end
    end
    for k in pairs(dist) do return k end
end

local function pickRandomName()
    return NameData[love.math.random(1, #NameData)]
end

-- ─── Outcome model ────────────────────────────────────────────────────

local TIER_KEYS = { "tiny", "small", "medium", "jackpot" }

-- ── Distribution helpers ──
local function distCopy(src)
    local d = {}
    if src then
        for _, t in ipairs(TIER_KEYS) do d[t] = src[t] or 0 end
    else
        for _, t in ipairs(TIER_KEYS) do d[t] = 0 end
    end
    return d
end

local function distAddInPlace(dst, delta)
    if not delta then return end
    for k, v in pairs(delta) do
        dst[k] = (dst[k] or 0) + v
    end
end

local function distClampAndNormalize(d)
    for _, t in ipairs(TIER_KEYS) do
        if (d[t] or 0) < 0 then d[t] = 0 end
    end
    local s = 0
    for _, t in ipairs(TIER_KEYS) do s = s + (d[t] or 0) end
    if s <= 0 then
        d.tiny, d.small, d.medium, d.jackpot = 1, 0, 0, 0
        return
    end
    for _, t in ipairs(TIER_KEYS) do d[t] = d[t] / s end
end

-- ── Pipeline helpers ──

local WC_ABSOLUTE_CAP = 0.95   -- final WC ceiling regardless of fill/shifts

-- Returns true if the descriptor's filters match (opp, gtype). Shared by
-- fill descriptors AND legacy shift descriptors (both carry skill/style/gtype).
local function shiftApplies(shift, opp, gtype)
    if shift.skill and shift.skill ~= opp.skill then return false end
    if shift.style and shift.style ~= opp.style then return false end
    if shift.gtype and shift.gtype ~= gtype.id   then return false end
    return true
end

-- Sum strength across descriptors matching this (opp, gtype).
local function sumFills(list, opp, gtype)
    if not list then return 0 end
    local total = 0
    for _, d in ipairs(list) do
        if shiftApplies(d, opp, gtype) then
            total = total + (d.strength or 1)
        end
    end
    return total
end

-- Convert fill units to a [0, 1] ratio via the stake's fill_window.
-- Below window.start: 0 (warmup). At window.complete: 1. Linear in between.
local function fillRatio(units, window)
    if not window then return 1 end
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)
    local span     = complete - start
    if span <= 0 then return units >= complete and 1 or 0 end
    local r = (units - start) / span
    if r < 0 then return 0 end
    if r > 1 then return 1 end
    return r
end

-- Linear interpolation between two distributions (per-tier).
local function lerpDist(naked, capped, t)
    local d = {}
    for _, k in ipairs(TIER_KEYS) do
        local a = (naked  and naked[k])  or 0
        local b = (capped and capped[k]) or a
        d[k] = a + (b - a) * t
    end
    return d
end

-- Build the effective (win_chance, win_dist, loss_dist) tuple for one
-- opponent, given the player ctx. Returns three fresh values; caller may
-- mutate the dist tables freely.
local function buildOutcome(opp, ctx, gtype, stake)
    -- 1. Sum fill units per dimension (filtered by opp/gtype).
    local wc_units = sumFills(ctx and ctx.win_chance_fills, opp, gtype)
    local wd_units = sumFills(ctx and ctx.win_dist_fills,   opp, gtype)
    local ld_units = sumFills(ctx and ctx.loss_dist_fills,  opp, gtype)

    -- 2. Convert to fill ratio via stake's window.
    local window = stake and stake.fill_window
    local wc_fill = fillRatio(wc_units, window)
    local wd_fill = fillRatio(wd_units, window)
    local ld_fill = fillRatio(ld_units, window)

    -- 3. Lerp naked → run-capped on each dimension.
    local naked_wc  = (stake and stake.win_chance)        or 0
    local capped_wc = (stake and stake.win_chance_capped) or naked_wc
    local win_chance = naked_wc + (capped_wc - naked_wc) * wc_fill
    local win_dist   = lerpDist(stake and stake.win_dist,  stake and stake.win_dist_capped,  wd_fill)
    local loss_dist  = lerpDist(stake and stake.loss_dist, stake and stake.loss_dist_capped, ld_fill)

    -- 4. Per-skill win_chance bump (rec / reg / pro — small flavor).
    win_chance = win_chance + (OpTypes.skill_shifts[opp.skill] or 0)

    -- 5. Per-style additive shape on win_dist / loss_dist.
    local style_shift = OpTypes.style_dist_shifts[opp.style]
    if style_shift then
        distAddInPlace(win_dist,  style_shift.win_dist)
        distAddInPlace(loss_dist, style_shift.loss_dist)
    end

    -- 6. Per-gtype additive shape on both dists (depth/pace texture).
    if gtype and gtype.dist_shifts then
        distAddInPlace(win_dist,  gtype.dist_shifts.win_dist)
        distAddInPlace(loss_dist, gtype.dist_shifts.loss_dist)
    end

    -- 7. Catalog ctx.win_chance_shifts — flat additive ON TOP of the lerp.
    --    The only mechanism for crossing run-capped toward the absolute cap.
    if ctx and ctx.win_chance_shifts then
        for _, shift in ipairs(ctx.win_chance_shifts) do
            if shiftApplies(shift, opp, gtype) then
                win_chance = win_chance + (shift.amount or 0)
            end
        end
    end

    -- 8. Final clamps. Absolute WC ceiling (no 100% wins).
    if     win_chance < 0                 then win_chance = 0
    elseif win_chance > WC_ABSOLUTE_CAP   then win_chance = WC_ABSOLUTE_CAP end
    distClampAndNormalize(win_dist)
    distClampAndNormalize(loss_dist)

    return win_chance, win_dist, loss_dist
end

-- Sample (won, tier) from the 3-distribution outcome.
local function sampleOutcome(win_chance, win_dist, loss_dist)
    local won = love.math.random() < win_chance
    local tier = sampleDist(won and win_dist or loss_dist) or "tiny"
    return won, tier
end

-- Roll a magnitude (in bb) within the cell's tier range.
local function rollTierMagnitude(tier)
    local r = OpTypes.tier_bb_ranges[tier]
    if not r then return 0 end
    return r.lo + love.math.random() * (r.hi - r.lo)
end

-- ─── Construction ─────────────────────────────────────────────────────

function Table:new(stake_id, game_type_id, ctx)
    local stake = findStake(stake_id)
    local self = setmetatable({
        stake_id      = stake_id,
        game_type_id  = game_type_id or "six_max",
        opponents     = {},
        state         = "idle",
        state_timer   = 0,
        hands_played  = 0,
        last_results  = {},

        stack = (stake and stake.buy_in) or 0,

        player_hole         = nil,
        opponent_hole       = nil,
        opponent_idx        = nil,
        community           = nil,
        outcome_won         = nil,
        outcome_delta       = nil,
        outcome_tier        = nil,    -- "tiny" / "small" / "medium" / "jackpot"
        natural_outcome     = true,

        x = 0, y = 0,
        -- Animation state for the per-table EV gauge in TablePanel. Lerps
        -- toward target each render frame; nil = snap on first read.
        gauge_pos = nil,
        _pending_resolution = nil,
    }, Table)
    self:fillOpponents(ctx)
    return self
end

-- Pre-flip up to `count` attributes per opponent. count=2 reveals both.
local function preRevealOpponents(opponents, count)
    count = math.max(0, math.floor(count or 0))
    if count <= 0 then return end
    for _, opp in ipairs(opponents) do
        for _ = 1, count do
            if opp.revealed_skill and opp.revealed_style then break end
            if not opp.revealed_skill and not opp.revealed_style then
                if love.math.random() < 0.5 then opp.revealed_skill = true
                else                            opp.revealed_style = true end
            elseif not opp.revealed_skill then
                opp.revealed_skill = true
            else
                opp.revealed_style = true
            end
        end
    end
end

function Table:fillOpponents(ctx)
    self.opponents = {}
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return end

    -- Uniform pool across all stakes — opponents are flavor + the targets
    -- upgrades latch onto, NOT the source of per-stake difficulty.
    local skill_dist = OpTypes.default_distributions.skills
    local style_dist = OpTypes.default_distributions.playstyles

    for i = 1, gtype.seats do
        local skill = sampleDist(skill_dist) or "reg"
        local style = sampleDist(style_dist) or "tag"
        local name  = pickRandomName()
        local stack = stake.buy_in or 0
        self.opponents[i] = Opponent:new(skill, style, name, stack)
    end

    preRevealOpponents(self.opponents, (ctx and ctx.revealed_at_start_count) or 0)
end

function Table:setStake(stake_id, ctx)
    self.stake_id = stake_id
    local stake = findStake(stake_id)
    self.stack = (stake and stake.buy_in) or 0
    self.state = "idle"
    self.state_timer = 0
    self:fillOpponents(ctx)
end

-- ─── Per-hand math ────────────────────────────────────────────────────

local function constructHand(want_win)
    local p_hole, o_hole, board
    for _ = 1, CONSTRUCTION_CAP do
        local deck = Deck:new()
        p_hole = { deck:draw(), deck:draw() }
        o_hole = { deck:draw(), deck:draw() }
        board  = { deck:draw(), deck:draw(), deck:draw(), deck:draw(), deck:draw() }

        local p_cards, o_cards = {}, {}
        for _, c in ipairs(p_hole) do table.insert(p_cards, c) end
        for _, c in ipairs(board)  do table.insert(p_cards, c) end
        for _, c in ipairs(o_hole) do table.insert(o_cards, c) end
        for _, c in ipairs(board)  do table.insert(o_cards, c) end

        local p_rank = HandEval.bestFiveOfN(p_cards)
        local o_rank = HandEval.bestFiveOfN(o_cards)
        local p_wins = HandEval.compare(p_rank, o_rank) > 0
        if p_wins == want_win then
            return p_hole, o_hole, board, true
        end
    end
    return p_hole, o_hole, board, false
end

function Table:deal(ctx)
    if self.state ~= "idle" then return false end
    ctx = ctx or {}

    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return false end

    if gtype.rerolls_opponents then
        self:fillOpponents(ctx)
    end

    local n_opps = #self.opponents
    if n_opps <= 0 then return false end
    self.opponent_idx = love.math.random(1, n_opps)
    local opp = self.opponents[self.opponent_idx]
    if not opp then return false end

    -- Build this opponent's outcome and sample.
    local wc, wd, ld = buildOutcome(opp, ctx, gtype, stake)
    local won, tier = sampleOutcome(wc, wd, ld)
    local magnitude_bb = rollTierMagnitude(tier)

    self.outcome_won  = won
    self.outcome_tier = tier

    -- earnings_mult / loss_mult scale magnitude only — they don't reshape
    -- the dists (Pot Odds Master, Damage Control, Headphones).
    local earnings_mult = ctx.earnings_mult or 1
    local loss_mult     = ctx.loss_mult     or 1
    if won then
        self.outcome_delta = magnitude_bb * stake.bb * earnings_mult
    else
        self.outcome_delta = -magnitude_bb * stake.bb * loss_mult
    end

    local p_hole, o_hole, board, natural = constructHand(won)
    self.player_hole     = p_hole
    self.opponent_hole   = o_hole
    self.community       = board
    self.natural_outcome = natural

    self.state       = "dealing"
    self.state_timer = 0
    return true
end

-- ─── Animation tick ───────────────────────────────────────────────────

local function maybeRevealAttribute(opp, ctx)
    if not opp then return end
    if opp.revealed_skill and opp.revealed_style then return end
    local chance = 0.5 + ((ctx and ctx.reveal_chance_add) or 0)
    if chance < 0 then chance = 0 end
    if chance > 1 then chance = 1 end
    if love.math.random() >= chance then return end
    if not opp.revealed_skill and not opp.revealed_style then
        if love.math.random() < 0.5 then opp.revealed_skill = true
        else                            opp.revealed_style = true end
    elseif not opp.revealed_skill then
        opp.revealed_skill = true
    else
        opp.revealed_style = true
    end
end

function Table:update(dt, ctx)
    if self.state == "idle" then return nil end

    local gtype = findGameType(self.game_type_id)
    local pace_mult = (gtype and gtype.pace_mult) or 1
    local effective_dt = (dt or 0) * pace_mult

    self.state_timer = self.state_timer + effective_dt

    if     self.state == "dealing"  and self.state_timer >= PHASE_DEAL_END     then self.state = "flop"
    elseif self.state == "flop"     and self.state_timer >= PHASE_FLOP_END     then self.state = "turn"
    elseif self.state == "turn"     and self.state_timer >= PHASE_TURN_END     then self.state = "river"
    elseif self.state == "river"    and self.state_timer >= PHASE_RIVER_END    then
        self.state = "showdown"
        maybeRevealAttribute(self.opponents[self.opponent_idx], ctx)
    elseif self.state == "showdown" and self.state_timer >= PHASE_SHOWDOWN_END then
        self.state = "settling"
        self._pending_resolution = {
            won   = self.outcome_won,
            delta = self.outcome_delta,
            tier  = self.outcome_tier,
            x     = self.x,
            y     = self.y,
        }
    elseif self.state == "settling" and self.state_timer >= PHASE_SETTLE_END then
        self.last_results[#self.last_results + 1] = {
            won   = self.outcome_won,
            delta = self.outcome_delta,
            tier  = self.outcome_tier,
        }
        if #self.last_results > LAST_RESULTS_CAP then
            table.remove(self.last_results, 1)
        end
        self.hands_played = self.hands_played + 1
        self.state         = "idle"
        self.state_timer   = 0
        self.player_hole   = nil
        self.opponent_hole = nil
        self.community     = nil
    end

    if self._pending_resolution then
        local r = self._pending_resolution
        self._pending_resolution = nil
        return r
    end
    return nil
end

-- Read-only summary the view header pulls each frame.
function Table:liveStats(_ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake then return nil end
    return {
        stake_display   = stake.display_name,
        bb              = stake.bb,
        buy_in          = stake.buy_in,
        game_type_id    = self.game_type_id,
        game_type_short = (gtype and gtype.short) or "",
        seats           = (gtype and gtype.seats) or #self.opponents,
    }
end

function Table:isBusy()
    return self.state ~= "idle"
end

-- ─── Estimation (UI gauge) ────────────────────────────────────────────
-- Build the *expected* outcome tuple for this (stake, game_type, ctx) — the
-- weighted average over the stake's skill × playstyle joint distribution
-- (after the game-type's modifiers). We deliberately do NOT use the
-- actually-seated opponents: with only a few seats sampled from the pool,
-- the per-skill EV swing is enormous and the gauge would jump 0%↔100%
-- across fresh tables at the same stake. The gauge is meant to read "how
-- is this stake/gtype going for me with my current upgrades" — stake-stable
-- — not "what random seat composition did I draw this time."

-- Average bb magnitude inside a tier (uniform over [lo, hi]).
local function tierAvgBB(tier)
    local r = OpTypes.tier_bb_ranges[tier]
    if not r then return 0 end
    return (r.lo + r.hi) * 0.5
end

function Table:tableOutcome(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end

    local skill_dist = OpTypes.default_distributions.skills
    local style_dist = OpTypes.default_distributions.playstyles

    local wc_acc = 0
    local wd_acc = { tiny = 0, small = 0, medium = 0, jackpot = 0 }
    local ld_acc = { tiny = 0, small = 0, medium = 0, jackpot = 0 }
    local total_w = 0
    for skill, sp in pairs(skill_dist) do
        for style, yp in pairs(style_dist) do
            local w = sp * yp
            if w > 0 then
                local proxy = { skill = skill, style = style }
                local wc, wd, ld = buildOutcome(proxy, ctx or {}, gtype, stake)
                wc_acc = wc_acc + wc * w
                for _, t in ipairs(TIER_KEYS) do
                    wd_acc[t] = wd_acc[t] + (wd[t] or 0) * w
                    ld_acc[t] = ld_acc[t] + (ld[t] or 0) * w
                end
                total_w = total_w + w
            end
        end
    end
    if total_w <= 0 then return nil end
    wc_acc = wc_acc / total_w
    for _, t in ipairs(TIER_KEYS) do
        wd_acc[t] = wd_acc[t] / total_w
        ld_acc[t] = ld_acc[t] / total_w
    end
    return wc_acc, wd_acc, ld_acc
end

-- Debug-only: pool-average + per-seated-opponent breakdown of the
-- (win_chance, win_dist, loss_dist, ev_per_hand) tuple. Used by the
-- backtick debug tooltip in views/TablePanel. Not on the per-frame path.
function Table:debugStats(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end

    ctx = ctx or {}
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb

    local function evFor(wc, wd, ld)
        local win_avg, loss_avg = 0, 0
        for _, t in ipairs(TIER_KEYS) do
            win_avg  = win_avg  + (wd[t] or 0) * tierAvgBB(t)
            loss_avg = loss_avg + (ld[t] or 0) * tierAvgBB(t)
        end
        local ev = wc * win_avg * bb * em - (1 - wc) * loss_avg * bb * lm
        return ev, win_avg, loss_avg
    end

    local pool_wc, pool_wd, pool_ld = self:tableOutcome(ctx)
    if not pool_wc then return nil end
    local pool_ev, pool_win_avg, pool_loss_avg = evFor(pool_wc, pool_wd, pool_ld)

    local opps = {}
    for i, opp in ipairs(self.opponents) do
        local wc, wd, ld = buildOutcome(opp, ctx, gtype, stake)
        local ev, win_avg, loss_avg = evFor(wc, wd, ld)
        opps[i] = {
            name           = opp.name,
            skill          = opp.skill,
            style          = opp.style,
            revealed_skill = opp.revealed_skill,
            revealed_style = opp.revealed_style,
            win_chance     = wc,
            win_dist       = wd,
            loss_dist      = ld,
            ev_per_hand    = ev,
            win_avg_bb     = win_avg,
            loss_avg_bb    = loss_avg,
        }
    end

    return {
        stake = stake,
        gtype = gtype,
        pool = {
            win_chance  = pool_wc,
            win_dist    = pool_wd,
            loss_dist   = pool_ld,
            ev_per_hand = pool_ev,
            win_avg_bb  = pool_win_avg,
            loss_avg_bb = pool_loss_avg,
        },
        opponents = opps,
    }
end

function Table:estimateStats(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end
    if #self.opponents == 0 then return nil end

    ctx = ctx or {}
    local wc, wd, ld = self:tableOutcome(ctx)
    if not wc then return nil end

    -- EV per hand. win_chance × E[win_magnitude] - (1-win_chance) × E[loss_magnitude].
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb

    local win_avg, loss_avg = 0, 0
    for _, t in ipairs(TIER_KEYS) do
        win_avg  = win_avg  + (wd[t] or 0) * tierAvgBB(t)
        loss_avg = loss_avg + (ld[t] or 0) * tierAvgBB(t)
    end

    local ev = wc * win_avg * bb * em - (1 - wc) * loss_avg * bb * lm

    return {
        ev_per_hand = ev,
        win_chance  = wc,
        win_dist    = wd,
        loss_dist   = ld,
    }
end

return Table
