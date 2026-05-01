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
--   1. Sum fill units per dimension (only descriptors whose gtype filter
--      matches the table's game_type).
--   2. Convert units → fill ratio via stake.fill_window {start, complete}.
--   3. Lerp naked → run-capped per dimension.
--   4. Gtype additive shape on dists.
--   5. Catalog ctx.win_chance_shifts (additive on top of lerp).
--   6. Clamp WC to [0, 0.95]. Clamp dist cells ≥0 and renormalize.
--
-- Per hand:
--   1. Pick opponent uniformly from seated.
--   2. buildOutcome → (win_chance, win_dist, loss_dist).
--   3. sampleOutcome → (won, tier).
--   4. magnitude_bb = uniform(PotTiers[tier]).
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
local PotTiers      = require("data.pot_tiers")
local Timelines     = require("data.cinematic_timelines")
local MttPayouts    = require("data.mtt_payouts")

local Table = {}
Table.__index = Table

local LAST_RESULTS_CAP = 5
local CONSTRUCTION_CAP = 200

-- Cinematic timeline lookup. Per-(gtype, tier) lists of {state, duration}
-- live in data/cinematic_timelines.lua; we resolve at deal-time and walk
-- the list by index in :update.
local function resolveTimeline(gtype_id, tier)
    local key = (gtype_id or "") .. ":" .. (tier or "")
    return Timelines.overrides[key]
        or Timelines.overrides[gtype_id]
        or Timelines.default
end

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
-- Returns true if the descriptor's gtype filter matches the table's
-- game-type. (Skill / style filters were removed when player types were
-- ripped — the only filter dimension that survived is gtype.)
local function shiftApplies(shift, gtype)
    if shift.gtype and shift.gtype ~= gtype.id then return false end
    return true
end

-- Sum strength across descriptors that match this gtype.
local function sumFills(list, gtype)
    if not list then return 0 end
    local total = 0
    for _, d in ipairs(list) do
        if shiftApplies(d, gtype) then
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

-- Build the effective (win_chance, win_dist, loss_dist) tuple for the
-- table, given the player ctx. Returns three fresh values; caller may
-- mutate the dist tables freely. (Opponents no longer carry per-seat
-- mechanical traits, so this no longer needs an `opp` argument.)
local function buildOutcome(ctx, gtype, stake)
    -- 1. Sum fill units per dimension (filtered by gtype).
    local wc_units = sumFills(ctx and ctx.win_chance_fills, gtype)
    local wd_units = sumFills(ctx and ctx.win_dist_fills,   gtype)
    local ld_units = sumFills(ctx and ctx.loss_dist_fills,  gtype)

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

    -- 4. Per-gtype additive shape on both dists (depth/pace texture).
    if gtype and gtype.dist_shifts then
        distAddInPlace(win_dist,  gtype.dist_shifts.win_dist)
        distAddInPlace(loss_dist, gtype.dist_shifts.loss_dist)
    end

    -- 4b. Catalog ctx.loss_dist_shifts — additive shape on the loss
    --     distribution (mirror of gtype dist_shifts on the loss side).
    --     Used by the no-poster handicap to skew Run-0 losses toward
    --     Medium+. Renormalized at step 7.
    if ctx and ctx.loss_dist_shifts then
        for _, sh in ipairs(ctx.loss_dist_shifts) do
            if shiftApplies(sh, gtype) then
                distAddInPlace(loss_dist, sh.shift)
            end
        end
    end

    -- 5. Catalog ctx.win_chance_shifts — flat additive ON TOP of the lerp.
    --    The only mechanism for crossing run-capped toward the absolute cap.
    if ctx and ctx.win_chance_shifts then
        for _, shift in ipairs(ctx.win_chance_shifts) do
            if shiftApplies(shift, gtype) then
                win_chance = win_chance + (shift.amount or 0)
            end
        end
    end

    -- 6. Per-gtype WC shift — gives modes a real win-rate identity (Zoom
    --    higher, HU lower) instead of only shaping dists. Treated as
    --    additive on top of catalog shifts so HU Specialist still works.
    if gtype and gtype.win_chance_shift then
        win_chance = win_chance + gtype.win_chance_shift
    end

    -- 6b. Multiplicative final-WC modifier (no-poster handicap, future
    --     skill discounts). Applied AFTER all additive shifts so the
    --     handicap multiplies the *effective* WC, not the lerped baseline.
    if ctx and ctx.wc_mult then
        win_chance = win_chance * ctx.wc_mult
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

-- Walk the shift list, bumping the current tier whenever (a) the gtype
-- filter matches, (b) the descriptor's `from` equals the current tier, and
-- (c) the chance roll succeeds. Bumps chain by design: Self-Help Book
-- (Tiny→Small @25%) + Lava Lamp (Small→Medium @15%) can take a hand from
-- Tiny → Small → Medium in one resolve. Walk order = registration order
-- in poker_effects.lua; deterministic per build.
local function applyTierShift(tier, shifts, gtype)
    if not shifts then return tier end
    for _, sh in ipairs(shifts) do
        if shiftApplies(sh, gtype) and tier == sh.from
           and love.math.random() < (sh.chance or 0) then
            tier = sh.to
        end
    end
    return tier
end

-- Roll a magnitude (in bb) within the cell's tier range.
local function rollTierMagnitude(tier)
    local r = PotTiers[tier]
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

        -- When true, the autonomous cursor swarm (services/CursorPool)
        -- ignores this table's DEAL button. Mouse clicks still work.
        -- Persisted parallel to active_table_specs in GameState.
        cursor_muted        = false,

        x = 0, y = 0,
        _pending_resolution = nil,

        -- Jackpot FX state. shake_trauma uses the trauma² model — per-frame
        -- amplitude = SHAKE_MAX × trauma² × random — so the shake feels
        -- organic and decays smoothly. vignette_kind ∈ {"good", "bad", nil}
        -- with vignette_alpha decaying alongside. All three are 0 / nil
        -- by default; GrindController bumps them on jackpot resolutions
        -- and Table:update decays them.
        shake_trauma   = 0,
        vignette_kind  = nil,
        vignette_alpha = 0,

        -- Cash-out gate. Set to true by GrindController:removeTable /
        -- :cashOutAll when the player asks to close a table that's mid-
        -- hand. The controller's update loop finalises the close (chip
        -- flight + pool removal) once the table returns to idle.
        pending_close  = false,

        -- Tournament bookkeeping (only meaningful when the gtype carries
        -- binary_outcome=true — i.e. MTT). hands_won counts cleared hands
        -- this run; mtt_state ∈ {nil, "playing"} marks "currently inside
        -- a tournament sequence" so :_finalizeHand knows whether to
        -- auto-deal the next one. mtt_pending_payout is a one-shot $
        -- amount drained by GrindController:update on tournament end.
        mtt_hands_won       = 0,
        mtt_state           = nil,
        mtt_pending_payout  = nil,
    }, Table)
    self:fillOpponents(ctx)
    return self
end

function Table:fillOpponents(_ctx)
    self.opponents = {}
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return end

    -- Opponents are pure visual flavour now: a name + a stack at the
    -- table's buy-in. No per-seat mechanical traits.
    for i = 1, gtype.seats do
        self.opponents[i] = Opponent:new(pickRandomName(), stake.buy_in or 0)
    end

    -- Visible cue when an anonymous-pool gtype rerolls between hands —
    -- the seat row briefly fades in so the player sees "the pool changed."
    -- Decayed in :update; consumed by drawOpponentSeat for an alpha multi.
    self.reroll_flash_t = 0.4
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
    -- Stash ctx so the timeline walker's tournament auto-advance hook
    -- (in :_finalizeHand → :deal / :_endTournament) has the latest
    -- effects rollup without needing to thread ctx through every call.
    self._last_ctx = ctx

    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return false end

    if gtype.rerolls_opponents then
        self:fillOpponents(ctx)
    end

    local n_opps = #self.opponents
    if n_opps <= 0 then return false end
    self.opponent_idx = love.math.random(1, n_opps)
    if not self.opponents[self.opponent_idx] then return false end

    -- Build the table's outcome and sample. Opponents no longer affect
    -- the math — they're cosmetic seats.
    local wc, wd, ld = buildOutcome(ctx, gtype, stake)
    local won, tier = sampleOutcome(wc, wd, ld)

    -- Post-sample tier re-rolls (Self-Help Book / Lava Lamp on the win
    -- side; Stress Ball / Worry Stone on the loss side). Each shift fires
    -- independently and can chain — see applyTierShift comment.
    if won then
        tier = applyTierShift(tier, ctx.win_tier_shifts, gtype)
    else
        tier = applyTierShift(tier, ctx.loss_tier_shifts, gtype)
    end

    local magnitude_bb = rollTierMagnitude(tier)

    self.outcome_won  = won
    self.outcome_tier = tier

    -- Binary-outcome (MTT): magnitude doesn't matter; only the win/loss
    -- bit affects state. Skip the $-delta math entirely and force the
    -- delta to 0 so the controller's stack/bankroll mutators no-op.
    if gtype.binary_outcome then
        self.outcome_delta = 0
        if not self.mtt_state then self.mtt_state = "playing" end
    else
        -- earnings_mult / loss_mult scale magnitude only — they don't reshape
        -- the dists (Pot Odds Master, Damage Control, Headphones).
        local earnings_mult = ctx.earnings_mult or 1
        local loss_mult     = ctx.loss_mult     or 1
        -- jackpot_mult (Branded Hat) stacks on top of earnings_mult — only
        -- jackpot-tier WINS get the extra boost.
        local jackpot_mult  = (won and tier == "jackpot")
                              and (ctx.jackpot_mult or 1) or 1
        if won then
            local raw_win = magnitude_bb * stake.bb * earnings_mult * jackpot_mult
            -- Pot cap: a hand's pot is at most 2× your at-table stack
            -- (your contribution + opponent matching it). So the most
            -- you can WIN from a hand is 2× stack. A $0.05 stack tops
            -- out at $0.10; a full $2 stack at $4. Keeps low-stack
            -- jackpots from feeling like free money while still letting
            -- a healthy stack catch a real haul.
            self.outcome_delta = math.min(raw_win, 2 * (self.stack or 0))
        else
            -- Loss side already capped downstream: GrindController clamps
            -- stack at 0 (controllers/GrindController.lua:171-173).
            self.outcome_delta = -magnitude_bb * stake.bb * loss_mult
        end
    end

    local p_hole, o_hole, board, natural = constructHand(won)
    self.player_hole     = p_hole
    self.opponent_hole   = o_hole
    self.community       = board
    self.natural_outcome = natural

    -- Resolve the cinematic shape for this (gtype, tier). Walker advances
    -- index in :update; phase[1] is the entry state ("dealing" by default).
    self.timeline    = resolveTimeline(gtype.id, tier)
    self.phase_idx   = 1
    self.state       = self.timeline[1][1]
    self.state_timer = 0
    return true
end

-- ─── Animation tick ───────────────────────────────────────────────────

-- Decay rates for jackpot FX (per-second). Tuned to fade over ~0.5 s so the
-- punch is visible without lingering or fighting the next hand's animation.
local SHAKE_DECAY_RATE    = 1.6
local VIGNETTE_DECAY_RATE = 1.5

function Table:update(dt, ctx)
    -- Stash latest ctx for the auto-deal path on tournament tables.
    if ctx then self._last_ctx = ctx end

    -- Decay jackpot FX every frame regardless of table state.
    if (self.shake_trauma or 0) > 0 then
        self.shake_trauma = math.max(0, self.shake_trauma - (dt or 0) * SHAKE_DECAY_RATE)
    end
    if (self.vignette_alpha or 0) > 0 then
        self.vignette_alpha = math.max(0, self.vignette_alpha - (dt or 0) * VIGNETTE_DECAY_RATE)
        if self.vignette_alpha <= 0 then self.vignette_kind = nil end
    end

    -- Reroll flash decay (Zoom's anonymous-seat fade-in). Linear over 0.4s.
    if (self.reroll_flash_t or 0) > 0 then
        self.reroll_flash_t = math.max(0, self.reroll_flash_t - (dt or 0))
    end

    if self.state == "idle" then return nil end

    local gtype = findGameType(self.game_type_id)
    local pace_mult = (gtype and gtype.pace_mult) or 1
    -- ctx.hand_pace_mult (Energy Drink, future pace items) compounds on
    -- top of the gtype baseline.
    local ctx_pace = (self._last_ctx and self._last_ctx.hand_pace_mult) or 1
    local effective_dt = (dt or 0) * pace_mult * ctx_pace

    self.state_timer = self.state_timer + effective_dt

    -- Walk the cinematic timeline. Each entry is {state_name, duration};
    -- when the timer crosses the current phase's duration we advance and
    -- spend the leftover on the next phase (preserves smoothness when a
    -- single dt exceeds a short phase). Past the last phase, finalize.
    local phase = self.timeline and self.timeline[self.phase_idx]
    while phase and self.state_timer >= phase[2] do
        self.state_timer = self.state_timer - phase[2]
        self.phase_idx   = self.phase_idx + 1
        local next_phase = self.timeline[self.phase_idx]
        if next_phase then
            self.state = next_phase[1]
            -- Resolution dict pushed on entering "settling", regardless
            -- of which phases preceded it (Zoom+tiny skips most phases).
            if next_phase[1] == "settling" then
                self._pending_resolution = {
                    won   = self.outcome_won,
                    delta = self.outcome_delta,
                    tier  = self.outcome_tier,
                    x     = self.x,
                    y     = self.y,
                }
            end
            phase = next_phase
        else
            self:_finalizeHand()
            phase = nil
        end
    end

    if self._pending_resolution then
        local r = self._pending_resolution
        self._pending_resolution = nil
        return r
    end
    return nil
end

-- Settling-phase end: log the result, increment hands_played, drop hole
-- and community cards, return to idle. Extracted so the timeline walker
-- has one tidy call site at end-of-list.
function Table:_finalizeHand()
    self.last_results[#self.last_results + 1] = {
        won   = self.outcome_won,
        delta = self.outcome_delta,
        tier  = self.outcome_tier,
    }
    if #self.last_results > LAST_RESULTS_CAP then
        table.remove(self.last_results, 1)
    end
    self.hands_played  = self.hands_played + 1
    self.state         = "idle"
    self.state_timer   = 0
    self.timeline      = nil
    self.phase_idx     = nil
    self.player_hole   = nil
    self.opponent_hole = nil
    self.community     = nil

    -- Tournament auto-advance. Win = bump hands_won and re-deal; loss
    -- = end the tournament. Cleared all 8 = end with the top payout.
    -- We re-use the latest ctx stashed on :update / :deal so the new
    -- hand samples WC against the player's current effects rollup —
    -- magnitudes don't matter (binary_outcome forces delta=0).
    local gtype = findGameType(self.game_type_id)
    if gtype and gtype.auto_deal and self.mtt_state == "playing" then
        if self.outcome_won then
            self.mtt_hands_won = (self.mtt_hands_won or 0) + 1
            if self.mtt_hands_won >= (gtype.hand_count or 0) then
                self:_endTournament()
            else
                self:deal(self._last_ctx)
            end
        else
            self:_endTournament()
        end
    end
end

-- Compute the tournament payout for the current mtt_hands_won and stash
-- it on self.mtt_pending_payout for GrindController:update to drain into
-- bankroll on the next tick. Resets mtt_state to nil so the next :deal
-- starts a fresh tournament. Sets stack=0 so the panel renders REBUY.
function Table:_endTournament()
    local stake = findStake(self.stake_id)
    local boost = (self._last_ctx and self._last_ctx.mtt_payout_boost) or 0
    local tier  = MttPayouts[boost] or MttPayouts[0]
    local mult  = (tier and tier[self.mtt_hands_won]) or 0
    local buy_in = (stake and stake.buy_in) or 0
    self.mtt_pending_payout = mult * buy_in
    self.mtt_state          = nil
    self.stack              = 0  -- triggers REBUY rendering in TablePanel
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
-- Build the expected outcome tuple for this (stake, game_type, ctx). With
-- player types ripped, every hand at a given (stake, gtype, ctx) draws from
-- the same outcome — no per-seat variance to average over — so this is
-- just a single buildOutcome call.

-- Average bb magnitude inside a tier (uniform over [lo, hi]).
local function tierAvgBB(tier)
    local r = PotTiers[tier]
    if not r then return 0 end
    return (r.lo + r.hi) * 0.5
end

function Table:tableOutcome(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end
    return buildOutcome(ctx or {}, gtype, stake)
end

-- Debug-only: pool stats for the backtick debug tooltip. Without per-seat
-- mechanical variance, there's no per-opponent breakdown to compute — every
-- seat at a given (stake, gtype, ctx) shares the same outcome.
function Table:debugStats(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end

    ctx = ctx or {}
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb

    local wc, wd, ld = self:tableOutcome(ctx)
    if not wc then return nil end

    local win_avg, loss_avg = 0, 0
    for _, t in ipairs(TIER_KEYS) do
        win_avg  = win_avg  + (wd[t] or 0) * tierAvgBB(t)
        loss_avg = loss_avg + (ld[t] or 0) * tierAvgBB(t)
    end
    local ev = wc * win_avg * bb * em - (1 - wc) * loss_avg * bb * lm

    return {
        stake = stake,
        gtype = gtype,
        pool = {
            win_chance  = wc,
            win_dist    = wd,
            loss_dist   = ld,
            ev_per_hand = ev,
            win_avg_bb  = win_avg,
            loss_avg_bb = loss_avg,
        },
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
