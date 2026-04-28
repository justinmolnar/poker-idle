-- models/Table.lua
--
-- A single ticking poker table. Per-hand state machine: the player clicks
-- DEAL, the outcome (win/loss + delta) is rolled at deal-time using the
-- table's stake distributions and the player's effects ctx, then cards are
-- constructed via rejection sampling so what's drawn matches the rolled
-- outcome. The animation timeline plays out over ~2.2 seconds, ending in
-- a settling phase that returns the resolution to the controller.
--
-- ─── State machine ─────────────────────────────────────────────────────
--   idle      — waiting for click; DEAL button shown
--   dealing   — hole cards landing  (0.00 → 0.40)
--   flop      — three community cards landing (0.40 → 0.80)
--   turn      — fourth community card (0.80 → 1.10)
--   river     — fifth community card (1.10 → 1.40)
--   showdown  — opponent flips face-up (1.40 → 1.80)
--   settling  — pot moves to winner; resolution returned to controller
--               on the transition INTO this state (1.80 → 2.20)
--   → idle
--
-- ─── Math layer ────────────────────────────────────────────────────────
--   1. Sample one opponent uniformly from the 5 seated opponents.
--   2. base_wr = OPP.BASE_WIN_RATE
--      penalty = skills[opp.skill].penalty
--      style_mod = playstyles[opp.style].modifier
--      style_mult = ctx[playstyles[opp.style].ctx_key] or 1
--      win_rate = clamp((base_wr + penalty + style_mod) * style_mult, 0.01, 0.99)
--   3. won = rng.chance(win_rate)
--   4. pot_bb / bet_bb sampled from a four-tier categorical (small / medium
--      / large / huge) for real poker variance, not flat per-stake numbers.
--   5. delta = won and pot_bb*bb*earnings_mult or -bet_bb*bb
--   6. Cards constructed (rejection sampling on a fresh deck) so that
--      best5(player_hole + community) strictly beats / strictly loses to
--      best5(opponent_hole + community), matching the rolled outcome.

local RNG        = require("utils.rng")
local Deck       = require("models.Deck")
local Opponent   = require("models.Opponent")
local HandEval   = require("utils.hand_eval")
local StakesData = require("data.stakes")
local NameData   = require("data.opponent_names")
local OpTypes    = require("data.opponent_types")

local Table = {}
Table.__index = Table

local LAST_RESULTS_CAP    = 5
local OPPONENT_COUNT      = 5     -- 6-max → 5 opponents around the player
local CONSTRUCTION_CAP    = 200   -- rejection-sample retries before accepting natural

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

-- Sample a key from a {key=weight} distribution. Weights sum to 1 (or any
-- positive total — we re-normalise via the running sum).
local function sampleDist(dist)
    if not dist then return nil end
    local total = 0
    for _, p in pairs(dist) do total = total + p end
    if total <= 0 then
        for k in pairs(dist) do return k end  -- fallback
    end
    local r = love.math.random() * total
    local acc = 0
    for k, p in pairs(dist) do
        acc = acc + p
        if r <= acc then return k end
    end
    -- Numerical fallback (FP error on the last bucket).
    for k in pairs(dist) do return k end
end

-- Per-hand pot/bet roll. Returns (pot_bb, bet_bb) — both in big-blinds
-- units, multiplied by stake.bb at the call site to convert to dollars.
local function rollPotBet()
    local roll = love.math.random()
    local pot_bb
    if     roll < 0.40 then pot_bb = 1.5 + love.math.random() * 1.5    -- small  [1.5, 3]
    elseif roll < 0.75 then pot_bb = 3.0 + love.math.random() * 5.0    -- medium [3, 8]
    elseif roll < 0.95 then pot_bb = 8.0 + love.math.random() * 17.0   -- large  [8, 25]
    else                    pot_bb = 25.0 + love.math.random() * 75.0  -- huge   [25, 100]
    end
    local bet_bb = pot_bb * (0.4 + love.math.random() * 0.2)           -- player's risk: 40-60% of pot
    return pot_bb, bet_bb
end

local function pickRandomName()
    return NameData[love.math.random(1, #NameData)]
end

-- ─── Construction ─────────────────────────────────────────────────────

function Table:new(stake_id)
    local self = setmetatable({
        stake_id      = stake_id,
        opponents     = {},
        state         = "idle",
        state_timer   = 0,
        hands_played  = 0,
        last_results  = {},     -- ring buffer of recent {won, delta} pairs

        -- Per-hand state — populated on :deal(), cleared on returning to idle.
        player_hole         = nil,
        opponent_hole       = nil,
        opponent_idx        = nil,    -- which seat plays back at the player this hand
        community           = nil,    -- list, populated to 5 by river
        outcome_won         = nil,
        outcome_delta       = nil,
        natural_outcome     = true,   -- false if construction-cap exhausted

        -- Layout. Filled by the view each frame so floating text spawns
        -- at the right place when a resolution fires.
        x = 0, y = 0,

        -- Set on the transition into "settling"; consumed by :update() once.
        _pending_resolution = nil,
    }, Table)
    self:fillOpponents()
    return self
end

-- Re-roll the 5 opponents from the table's stake distributions. Called on
-- construction and after a stake change so the seated players match the
-- new tier.
function Table:fillOpponents()
    self.opponents = {}
    local stake = findStake(self.stake_id)
    if not stake then return end
    for i = 1, OPPONENT_COUNT do
        local skill = sampleDist(stake.skill_distribution) or "rec"
        local style = sampleDist(stake.playstyle_distribution) or "fish"
        local name  = pickRandomName()
        local stack = stake.buy_in or 0
        self.opponents[i] = Opponent:new(skill, style, name, stack)
    end
end

function Table:setStake(stake_id)
    self.stake_id = stake_id
    self.state = "idle"
    self.state_timer = 0
    self:fillOpponents()
end

-- ─── Per-hand math ────────────────────────────────────────────────────

local function winRateAgainst(opp, ctx)
    local skill_data = OpTypes.skills[opp.skill]      or {}
    local style_data = OpTypes.playstyles[opp.style]  or {}
    local skill_pen  = skill_data.penalty   or 0
    local style_mod  = style_data.modifier  or 0
    local style_mult = 1
    if style_data.ctx_key and ctx and ctx[style_data.ctx_key] then
        style_mult = ctx[style_data.ctx_key]
    end
    local raw = (OpTypes.BASE_WIN_RATE + skill_pen + style_mod) * style_mult
    if raw < 0.01 then raw = 0.01 end
    if raw > 0.99 then raw = 0.99 end
    return raw
end

-- Construct a hand layout consistent with `want_win`. Fresh deck each
-- attempt. Returns (player_hole, opponent_hole, community).
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
    -- Cap exhausted — accept whatever the last attempt produced.
    return p_hole, o_hole, board, false
end

-- Initiate a new hand. Only valid in idle state. Returns true if the deal
-- started; false if the state is busy.
function Table:deal(ctx)
    if self.state ~= "idle" then return false end
    ctx = ctx or {}

    local stake = findStake(self.stake_id)
    if not stake then return false end

    -- Sample which seated opponent plays back this hand.
    self.opponent_idx = love.math.random(1, OPPONENT_COUNT)
    local opp = self.opponents[self.opponent_idx]
    if not opp then return false end

    local win_rate = winRateAgainst(opp, ctx)
    self.outcome_won = RNG.chance(win_rate)

    local pot_bb, bet_bb = rollPotBet()
    local earnings_mult = ctx.earnings_mult or 1
    if self.outcome_won then
        self.outcome_delta = pot_bb * stake.bb * earnings_mult
    else
        self.outcome_delta = -bet_bb * stake.bb
    end

    local p_hole, o_hole, board, natural = constructHand(self.outcome_won)
    self.player_hole     = p_hole
    self.opponent_hole   = o_hole
    self.community       = board
    self.natural_outcome = natural

    self.state       = "dealing"
    self.state_timer = 0
    return true
end

-- Step animation. Returns a resolution table on the transition INTO
-- settling, else nil. The caller (controller) consumes it and applies
-- the bankroll delta + emits floating text.
function Table:update(dt, _ctx)
    if self.state == "idle" then return nil end

    self.state_timer = self.state_timer + (dt or 0)

    if     self.state == "dealing"  and self.state_timer >= PHASE_DEAL_END     then self.state = "flop"
    elseif self.state == "flop"     and self.state_timer >= PHASE_FLOP_END     then self.state = "turn"
    elseif self.state == "turn"     and self.state_timer >= PHASE_TURN_END     then self.state = "river"
    elseif self.state == "river"    and self.state_timer >= PHASE_RIVER_END    then self.state = "showdown"
    elseif self.state == "showdown" and self.state_timer >= PHASE_SHOWDOWN_END then
        self.state = "settling"
        -- Stash the resolution so the next return surfaces it.
        self._pending_resolution = {
            won   = self.outcome_won,
            delta = self.outcome_delta,
            x     = self.x,
            y     = self.y,
        }
    elseif self.state == "settling" and self.state_timer >= PHASE_SETTLE_END then
        self.last_results[#self.last_results + 1] = {
            won   = self.outcome_won,
            delta = self.outcome_delta,
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
-- The `win_rate / pot_size / bet_size / hands_per_min` fields are legacy
-- pass-throughs from `data/stakes.lua` for the placeholder pill panel that
-- still ships in `views/GrindView`. Phase 3 replaces that panel with a
-- real TablePanel and these fields can come out.
function Table:liveStats(_ctx)
    local stake = findStake(self.stake_id)
    if not stake then return nil end
    return {
        stake_display = stake.display_name,
        bb            = stake.bb,
        buy_in        = stake.buy_in,
        win_rate      = stake.win_rate      or 0,
        pot_size      = stake.pot_size      or 0,
        bet_size      = stake.bet_size      or 0,
        hands_per_min = stake.hands_per_min or 0,
    }
end

-- True iff a hand is currently animating.
function Table:isBusy()
    return self.state ~= "idle"
end

return Table
