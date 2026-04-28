-- models/Table.lua
--
-- A single ticking poker table. Per-hand state machine: the player clicks
-- DEAL, the outcome is rolled at deal-time from the table's outcome grid,
-- then cards are constructed via rejection sampling so what's drawn matches
-- the rolled win/lose. Animation timeline plays over ~2.2 seconds, ending
-- in settling that returns the resolution to the controller.
--
-- ─── State machine ─────────────────────────────────────────────────────
--   idle / dealing / flop / turn / river / showdown / settling → idle.
--   Resolution returns on the transition INTO settling.
--
-- ─── Math layer (outcome grid) ─────────────────────────────────────────
-- Per opponent there is an 8-cell grid (4 pot tiers × win/lose):
--
--       LOSE                   WIN
--   Tiny    (tl)            Tiny    (tw)
--   Small   (sl)            Small   (sw)
--   Medium  (ml)            Medium  (mw)
--   Jackpot (jl)            Jackpot (jw)
--
-- Each cell holds a probability; the grid sums to 1.0. The base grid is
-- looked up by opp.skill in data/opponent_types.lua. A small additive
-- per-style shift is applied next, then the game-type's grid_modifier,
-- then any ctx.grid_shifts pushed by run upgrades / catalog perks. Any
-- negative cells clamp at 0 and the grid renormalizes to sum=1.
--
-- Per hand:
--   1. Pick opponent uniformly from seated.
--   2. _buildGrid(opp, ctx) → grid.
--   3. _sampleGrid(grid) → { tier, won, magnitude_bb }.
--   4. delta = ±magnitude × stake.bb × (earnings_mult on win, loss_mult on lose).
--   5. Construct cards (rejection sampling) so best5(player) beats / loses
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

-- ─── Outcome grid ─────────────────────────────────────────────────────

local CELL_KEYS = { "tl", "sl", "ml", "jl", "tw", "sw", "mw", "jw" }
local LOSE_KEYS = { "tl", "sl", "ml", "jl" }
local WIN_KEYS  = { "tw", "sw", "mw", "jw" }
local TIER_KEYS = { "tiny", "small", "medium", "jackpot" }

-- (tier → { lose_cell, win_cell }) — used by tier-row shifts and tooltip.
local TIER_PAIRS = {
    tiny    = { l = "tl", w = "tw" },
    small   = { l = "sl", w = "sw" },
    medium  = { l = "ml", w = "mw" },
    jackpot = { l = "jl", w = "jw" },
}

-- Cascading order for shift_downward. tier_below[t] is where mass flows.
local SHIFT_DOWN_CHAIN = {
    { from = TIER_PAIRS.tiny,   to = TIER_PAIRS.small   },
    { from = TIER_PAIRS.small,  to = TIER_PAIRS.medium  },
    { from = TIER_PAIRS.medium, to = TIER_PAIRS.jackpot },
}

-- Grid utility helpers.
local function gridCopy(src)
    local g = {}
    for _, k in ipairs(CELL_KEYS) do g[k] = src[k] or 0 end
    return g
end

local function gridSum(g)
    local s = 0
    for _, k in ipairs(CELL_KEYS) do s = s + (g[k] or 0) end
    return s
end

local function gridClampAndNormalize(g)
    for _, k in ipairs(CELL_KEYS) do
        if (g[k] or 0) < 0 then g[k] = 0 end
    end
    local s = gridSum(g)
    if s <= 0 then return end
    for _, k in ipairs(CELL_KEYS) do g[k] = g[k] / s end
end

-- Apply an additive shift table {cell_key=delta, ...} to the grid in place.
local function applyAdditiveShift(g, shift)
    if not shift then return end
    for k, v in pairs(shift) do
        g[k] = (g[k] or 0) + v
    end
end

-- Apply a game-type's grid_modifier ({ tiny, small, medium, jackpot } row
-- shifts). Each tier's amount is split evenly between its L and W cells.
local function applyGtypeModifier(g, modifier)
    if not modifier then return end
    for tier, amount in pairs(modifier) do
        local pair = TIER_PAIRS[tier]
        if pair then
            g[pair.l] = (g[pair.l] or 0) + amount * 0.5
            g[pair.w] = (g[pair.w] or 0) + amount * 0.5
        end
    end
end

-- ── Grid-shift operations ──────────────────────────────────────────────
-- Each op is a function. Dispatched by name from a table — no kind chain.

-- Move `amount` × (current L cell mass) from each Lose cell to the same-tier
-- Win cell. Sharper Reads / Calm Hands / Patience / Calculator.
local function shiftLoseToWin(g, amount)
    if amount <= 0 then return end
    for _, t in ipairs(TIER_KEYS) do
        local pair = TIER_PAIRS[t]
        local moved = (g[pair.l] or 0) * amount
        g[pair.l] = g[pair.l] - moved
        g[pair.w] = (g[pair.w] or 0) + moved
    end
end

-- Cascade `amount` × (current tier mass) downward: Tiny → Small → Medium →
-- Jackpot. Donor mass scales L and W proportionally; receiver gets the
-- moved mass split evenly between L and W. Big Pots.
local function shiftDownward(g, amount)
    if amount <= 0 then return end
    for _, link in ipairs(SHIFT_DOWN_CHAIN) do
        local from_l, from_w = link.from.l, link.from.w
        local to_l,   to_w   = link.to.l,   link.to.w
        local from_total = (g[from_l] or 0) + (g[from_w] or 0)
        local moved = from_total * amount
        if moved > 0 then
            g[from_l] = g[from_l] * (1 - amount)
            g[from_w] = g[from_w] * (1 - amount)
            g[to_l]   = (g[to_l] or 0) + moved * 0.5
            g[to_w]   = (g[to_w] or 0) + moved * 0.5
        end
    end
end

local SHIFT_OPS = {
    lose_to_win    = shiftLoseToWin,
    shift_downward = shiftDownward,
}

-- Returns true if the shift descriptor applies to (opp, gtype).
local function shiftApplies(shift, opp, gtype)
    if shift.skill and shift.skill ~= opp.skill then return false end
    if shift.style and shift.style ~= opp.style then return false end
    if shift.gtype and shift.gtype ~= gtype.id   then return false end
    return true
end

-- Build the effective 8-cell grid for one opponent, given the player ctx.
-- Returns a fresh table; caller may mutate freely.
local function buildGrid(opp, ctx, gtype)
    local base = OpTypes.skill_grids[opp.skill] or OpTypes.skill_grids.rec
    local g = gridCopy(base)

    -- Style shift (additive table; missing entries treated as 0).
    applyAdditiveShift(g, OpTypes.style_shifts[opp.style])

    -- Game-type tier shift (per-row, split evenly L/W).
    applyGtypeModifier(g, gtype and gtype.grid_modifier)

    -- ctx.grid_shifts (run upgrades + catalog perks), in order.
    if ctx and ctx.grid_shifts then
        for _, shift in ipairs(ctx.grid_shifts) do
            if shiftApplies(shift, opp, gtype) then
                local op = SHIFT_OPS[shift.op]
                if op then op(g, shift.amount or 0) end
            end
        end
    end

    gridClampAndNormalize(g)
    return g
end

-- Sample one cell from the grid. Returns (cell_key) — caller decodes
-- tier / won / magnitude.
local function sampleCell(g)
    local total = gridSum(g)
    if total <= 0 then return "tl" end
    local r = love.math.random() * total
    local acc = 0
    for _, k in ipairs(CELL_KEYS) do
        acc = acc + (g[k] or 0)
        if r <= acc then return k end
    end
    return CELL_KEYS[#CELL_KEYS]
end

-- Decode a cell key to { tier, won }.
local CELL_DECODE = {
    tl = { tier = "tiny",    won = false },
    sl = { tier = "small",   won = false },
    ml = { tier = "medium",  won = false },
    jl = { tier = "jackpot", won = false },
    tw = { tier = "tiny",    won = true  },
    sw = { tier = "small",   won = true  },
    mw = { tier = "medium",  won = true  },
    jw = { tier = "jackpot", won = true  },
}

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

    -- Build this opponent's outcome grid and sample one cell.
    local grid = buildGrid(opp, ctx, gtype)
    local cell = sampleCell(grid)
    local decoded = CELL_DECODE[cell] or { tier = "tiny", won = false }
    local magnitude_bb = rollTierMagnitude(decoded.tier)

    self.outcome_won  = decoded.won
    self.outcome_tier = decoded.tier

    -- earnings_mult / loss_mult scale magnitude only — they don't reshape
    -- the grid (Pot Odds Master, Damage Control, Headphones).
    local earnings_mult = ctx.earnings_mult or 1
    local loss_mult     = ctx.loss_mult     or 1
    if self.outcome_won then
        self.outcome_delta = magnitude_bb * stake.bb * earnings_mult
    else
        self.outcome_delta = -magnitude_bb * stake.bb * loss_mult
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
-- Build the *expected* 8-cell grid for this (stake, game_type, ctx) — the
-- weighted average over the stake's skill × playstyle joint distribution
-- (after the game-type's modifiers). We deliberately do NOT use the
-- actually-seated opponents: with only 5 seats sampled from a 4-skill
-- distribution, the per-skill EV swing is enormous (rec ≈ +6 bb, pro ≈
-- -30 bb at s001 grids) and the gauge would jump 0%↔100% across fresh
-- tables at the same stake. The gauge is meant to read "how is this
-- stake/gtype going for me with my current upgrades" — stake-stable —
-- not "what random seat composition did I draw this time."

-- Average bb magnitude inside a tier (uniform over [lo, hi]).
local function tierAvgBB(tier)
    local r = OpTypes.tier_bb_ranges[tier]
    if not r then return 0 end
    return (r.lo + r.hi) * 0.5
end

function Table:tableGrid(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end

    local skill_dist = mergeDist(stake.skill_distribution,     gtype.skill_modifier)
    local style_dist = mergeDist(stake.playstyle_distribution, gtype.playstyle_modifier)
    if not skill_dist or not style_dist then return nil end

    local out = {}
    for _, k in ipairs(CELL_KEYS) do out[k] = 0 end
    local total_w = 0
    for skill, sp in pairs(skill_dist) do
        for style, yp in pairs(style_dist) do
            local w = sp * yp
            if w > 0 then
                local proxy = { skill = skill, style = style }
                local g = buildGrid(proxy, ctx or {}, gtype)
                for _, k in ipairs(CELL_KEYS) do
                    out[k] = out[k] + (g[k] or 0) * w
                end
                total_w = total_w + w
            end
        end
    end
    if total_w <= 0 then return nil end
    for _, k in ipairs(CELL_KEYS) do out[k] = out[k] / total_w end
    return out
end

function Table:estimateStats(ctx)
    local stake = findStake(self.stake_id)
    local gtype = findGameType(self.game_type_id)
    if not stake or not gtype then return nil end
    if #self.opponents == 0 then return nil end

    ctx = ctx or {}
    local grid = self:tableGrid(ctx)
    if not grid then return nil end

    -- Win chance = sum of the W column.
    local win_chance = 0
    for _, k in ipairs(WIN_KEYS) do win_chance = win_chance + (grid[k] or 0) end

    -- Per-tier total mass (L+W).
    local tier_pcts = {}
    for _, t in ipairs(TIER_KEYS) do
        local pair = TIER_PAIRS[t]
        tier_pcts[t] = (grid[pair.l] or 0) + (grid[pair.w] or 0)
    end

    -- Headline jackpot-win % — the "watch it tick up" number.
    local jackpot_win_pct = grid.jw or 0

    -- EV per hand. Each cell contributes p × magnitude × (em or lm) × bb.
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb
    local ev = 0
    for _, t in ipairs(TIER_KEYS) do
        local pair = TIER_PAIRS[t]
        local avg = tierAvgBB(t)
        ev = ev + (grid[pair.w] or 0) * avg * bb * em
        ev = ev - (grid[pair.l] or 0) * avg * bb * lm
    end

    return {
        win_chance      = win_chance,
        tier_pcts       = tier_pcts,
        jackpot_win_pct = jackpot_win_pct,
        ev_per_hand     = ev,
        grid            = grid,
    }
end

return Table
