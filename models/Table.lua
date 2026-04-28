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
--   1. Sample one opponent uniformly from the seated opponents.
--   2. base_wr     = OPP.BASE_WIN_RATE
--      skill_pen   = skills[opp.skill].penalty * (ctx[skill.ctx_key] or 1)
--      style_mod   = playstyles[opp.style].modifier
--      style_mult  = ctx[playstyles[opp.style].ctx_key] or 1
--      stake_off   = stake.win_rate_offset
--      gt_off      = gtype.win_rate_offset * (ctx.gtype_offset_mult or 1)
--      bonus       = ctx.win_rate_add
--      win_rate    = clamp((base_wr + skill_pen + style_mod + stake_off + gt_off + bonus) * style_mult, 0.01, 0.99)
--   3. won = rng.chance(win_rate)
--   4. pot_bb / bet_bb sampled from a four-tier categorical (small / medium
--      / large / huge) for real poker variance, not flat per-stake numbers.
--   5. delta = won and pot_bb*bb*earnings_mult or -bet_bb*bb*loss_mult
--   6. Cards constructed (rejection sampling on a fresh deck) so that
--      best5(player_hole + community) strictly beats / strictly loses to
--      best5(opponent_hole + community), matching the rolled outcome.

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

local LAST_RESULTS_CAP    = 5
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

local function findGameType(id)
    for _, gt in ipairs(GameTypesData) do
        if gt.id == id then return gt end
    end
end

-- Multiply each weight in `dist` by the matching `modifier` entry (or 1
-- when missing) and renormalize to sum=1. modifier=nil → return dist
-- unchanged. Used to layer game-type tilts onto a stake's distribution.
local function mergeDist(dist, modifier)
    if not dist then return nil end
    if not modifier then return dist end
    local out = {}
    local total = 0
    for k, v in pairs(dist) do
        local nv = v * (modifier[k] or 1)
        out[k] = nv
        total = total + nv
    end
    if total <= 0 then return dist end
    for k, v in pairs(out) do out[k] = v / total end
    return out
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

function Table:new(stake_id, game_type_id, ctx)
    local stake = findStake(stake_id)
    local self = setmetatable({
        stake_id      = stake_id,
        game_type_id  = game_type_id or "six_max",
        opponents     = {},
        state         = "idle",
        state_timer   = 0,
        hands_played  = 0,
        last_results  = {},     -- ring buffer of recent {won, delta} pairs

        -- Per-table stack ($). Initialized to the stake's buy-in (100bb).
        -- Wins push it up to the buy-in cap; overflow goes to bankroll.
        -- Losses come out of the stack (clamped at 0). Removing a table
        -- refunds whatever is currently here.
        stack = (stake and stake.buy_in) or 0,

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
    self:fillOpponents(ctx)
    return self
end

-- Pre-flip up to `count` attributes per opponent. `count` is the catalog
-- ctx.revealed_at_start_count; the order (skill vs style) for the first
-- reveal is random so the player gets variety. count=2 reveals both.
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

-- Re-roll the seated opponents from the stake's distributions, layered
-- with the game type's modifiers. The game type also dictates how many
-- opponents fill the felt (1 for HU, 5 for 6-max/Zoom, 8 for 9-max). If
-- ctx.revealed_at_start_count is set (Cold Read), seats start with that
-- many attributes pre-revealed.
function Table:fillOpponents(ctx)
    self.opponents = {}
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return end

    local skill_dist = mergeDist(stake.skill_distribution,     gtype.skill_modifier)
    local style_dist = mergeDist(stake.playstyle_distribution, gtype.playstyle_modifier)

    for i = 1, gtype.seats do
        local skill = sampleDist(skill_dist) or "rec"
        local style = sampleDist(style_dist) or "fish"
        local name  = pickRandomName()
        local stack = stake.buy_in or 0
        self.opponents[i] = Opponent:new(skill, style, name, stack)
    end

    preRevealOpponents(self.opponents, (ctx and ctx.revealed_at_start_count) or 0)
end

function Table:setStake(stake_id, ctx)
    self.stake_id = stake_id
    -- Stake change = leave the old table, sit at a new one. Stack resets
    -- to the new buy-in. The controller handles the bankroll math
    -- (refund old stack, charge new buy-in) before calling this.
    local stake = findStake(stake_id)
    self.stack = (stake and stake.buy_in) or 0
    self.state = "idle"
    self.state_timer = 0
    self:fillOpponents(ctx)  -- new opponents at the new tier; same game type
end

-- ─── Per-hand math ────────────────────────────────────────────────────

local function winRateAgainst(opp, ctx, gtype, stake)
    local skill_data = OpTypes.skills[opp.skill]      or {}
    local style_data = OpTypes.playstyles[opp.style]  or {}
    local skill_pen  = skill_data.penalty   or 0
    local style_mod  = style_data.modifier  or 0
    ctx = ctx or {}

    -- Per-skill penalty multiplier (Calm Hands etc.). Skills now carry a
    -- ctx_key just like playstyles, so a value <1 in ctx softens the tier
    -- without an `if opp.skill == "pro"` chain.
    if skill_data.ctx_key and ctx[skill_data.ctx_key] then
        skill_pen = skill_pen * ctx[skill_data.ctx_key]
    end

    -- Playstyle ctx_key — vs_fish, vs_tag, etc. Existing mechanism.
    local style_mult = 1
    if style_data.ctx_key and ctx[style_data.ctx_key] then
        style_mult = ctx[style_data.ctx_key]
    end

    -- Per-stake difficulty offset. Climbing tiers means a harder baseline
    -- on top of the steeper skill distribution.
    local stake_offset = (stake and stake.win_rate_offset) or 0

    -- Game-type baseline shift, optionally softened by hu_specialist etc.
    local gt_offset = (gtype and gtype.win_rate_offset) or 0
    gt_offset = gt_offset * (ctx.gtype_offset_mult or 1)

    local bonus = ctx.win_rate_add or 0

    local raw = (OpTypes.BASE_WIN_RATE + skill_pen + style_mod
                 + stake_offset + gt_offset + bonus) * style_mult
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
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return false end

    -- Zoom: rerolls opponents per hand. The point of Zoom is unreadable
    -- pool — fresh players every hand mean revealed_skill / revealed_style
    -- never accumulate, so you can't soul-read across hands.
    if gtype.rerolls_opponents then
        self:fillOpponents(ctx)
    end

    -- Sample which seated opponent plays back this hand.
    local n_opps = #self.opponents
    if n_opps <= 0 then return false end
    self.opponent_idx = love.math.random(1, n_opps)
    local opp = self.opponents[self.opponent_idx]
    if not opp then return false end

    local win_rate = winRateAgainst(opp, ctx, gtype, stake)
    self.outcome_won = RNG.chance(win_rate)

    local pot_bb, bet_bb = rollPotBet()
    -- pot_mult tilts the absolute pot/bet size for the game type. 9-max =
    -- bigger pots; HU and Zoom = smaller. Ratio between pot and bet stays.
    local pot_mult = gtype.pot_mult or 1
    pot_bb = pot_bb * pot_mult
    bet_bb = bet_bb * pot_mult

    -- earnings_mult scales winning deltas (Big Pots run upgrade, Pot Odds
    -- Master catalog item). loss_mult shrinks losing deltas (Damage Control).
    local earnings_mult = ctx.earnings_mult or 1
    local loss_mult     = ctx.loss_mult     or 1
    if self.outcome_won then
        self.outcome_delta = pot_bb * stake.bb * earnings_mult
    else
        self.outcome_delta = -bet_bb * stake.bb * loss_mult
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
-- Reveal one unrevealed attribute (skill or style) on the opponent. Base
-- 50% per showdown; Eagle Eyes (ctx.reveal_chance_add) bumps it. Discovery
-- feels like reads, not a bullet-pointed cheat sheet.
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

    -- Per-game-type pacing. pace_mult > 1 = faster (HU/Zoom). 6-max sits
    -- at 0.5 so the per-hand cinematic takes 4.4s rather than 2.2s — that
    -- anchors the multi-tabling math (a single 6-max table is intentionally
    -- slow enough that running 4 of them feels meaningfully better).
    local gtype = findGameType(self.game_type_id)
    local pace_mult = (gtype and gtype.pace_mult) or 1
    local effective_dt = (dt or 0) * pace_mult

    self.state_timer = self.state_timer + effective_dt

    if     self.state == "dealing"  and self.state_timer >= PHASE_DEAL_END     then self.state = "flop"
    elseif self.state == "flop"     and self.state_timer >= PHASE_FLOP_END     then self.state = "turn"
    elseif self.state == "turn"     and self.state_timer >= PHASE_TURN_END     then self.state = "river"
    elseif self.state == "river"    and self.state_timer >= PHASE_RIVER_END    then
        self.state = "showdown"
        -- Showdown lets the player learn something about the opponent
        -- they faced this hand. Base 50% chance to flip one hidden
        -- attribute; Eagle Eyes (ctx.reveal_chance_add) bumps it.
        maybeRevealAttribute(self.opponents[self.opponent_idx], ctx)
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
    local gtype = findGameType(self.game_type_id)
    if not stake then return nil end
    return {
        stake_display = stake.display_name,
        bb            = stake.bb,
        buy_in        = stake.buy_in,
        game_type_id    = self.game_type_id,
        game_type_short = (gtype and gtype.short) or "",
        seats           = (gtype and gtype.seats) or #self.opponents,
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
