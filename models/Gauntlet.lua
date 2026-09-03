-- models/Gauntlet.lua
--
-- The 3-runout cheating-dealer gauntlet. Stateful gameplay model — owns one
-- Deck, both sides' hole cards, the growing community board, and the
-- per-runout outcomes.
--
-- ─── Math contract ──────────────────────────────────────────────────────
-- Heads-up: player (2 hole) vs dealer (2 hole), shared 5+ community cards.
-- Each runout compares best5(player_hole + community) vs best5(dealer_hole
-- + community). A draw is a loss — the player must STRICTLY beat the
-- dealer.
--
-- The rate STRUCT (r1, r2, r3, clear) is the GROUND TRUTH — see
-- models/shove_rate.lua and docs/math.md for derivation. Each runout uses
-- its own rate; the dealer's two cheats halve different multiplicative
-- factors so r1 > r2 > r3. Outcomes are rolled up front:
--     outcomes[1] = chance(rates.r1)
--     outcomes[2] = (only rolled if outcomes[1])  chance(rates.r2)
--     outcomes[3] = (only rolled if outcomes[2])  chance(rates.r3)
-- Cards are then constructed JOINTLY — we redeal player_hole + dealer_hole
-- + 5-board until we can find a 6th community card AND (if needed) a 7th
-- that together produce all three rolled outcomes.
--
-- Per-runout rejection alone is biased: forcing a particular outcome can
-- be impossible at runout 2/3 if the existing cards lock both sides into
-- a result no single new community card can flip. Joint construction
-- redeals the whole hand instead of accepting bias.
--
-- The dealer's "cheat" is community-card-only — the dealer's HOLE cards
-- are dealt honestly. The cheat is community cards 6 and 7 chosen by the
-- dealer such that the rolled outcome lands; the dealer's own hole hand
-- isn't manipulated.
--
-- If the outer cap is exhausted we accept whatever the last deal produced
-- and override the recorded outcomes so cards and result agree.
--
-- ─── Engine-agnosticism ────────────────────────────────────────────────
-- Lives in models/ (not services/) because it's poker-specific stateful
-- gameplay logic. services/ is reserved for engine-agnostic infrastructure.
-- The deck / card / hand_eval primitives this builds on are themselves
-- focused single-responsibility models in models/.

local Deck      = require("models.Deck")
local HandEval  = require("models.HandEval")
local RNG       = require("utils.rng")
local Constants = require("data.constants")
local ShowdownRealism = require("data.showdown_realism")

local Gauntlet = {}
Gauntlet.__index = Gauntlet

-- `realism` (optional) overrides the gauntlet section of
-- data/showdown_realism.lua — threaded so a sim can test candidate
-- policies without touching the live data file.
function Gauntlet:new(game, rates, realism)
    return setmetatable({
        game        = game,
        rates       = rates or { r1 = 0, r2 = 0, r3 = 0, clear = 0 },
        realism     = realism or ShowdownRealism.gauntlet,
        state       = "idle",          -- idle | running | finished
        deck        = nil,
        player_hole = nil,             -- {Card, Card}
        dealer_hole = nil,             -- {Card, Card}
        board       = nil,             -- list, grows 5 → 6 → 7
        outcomes    = { nil, nil, nil },
        natural     = { nil, nil, nil },
        evals       = { nil, nil, nil },
        result      = nil,
    }, Gauntlet)
end

-- Roll the three runout outcomes against `rates`, act-gated by the save
-- flags (R2 only exists once Act 2 is open, R3 once Act 3 is). A module
-- function, callable without a gauntlet, because the shove COMMIT rolls
-- and PERSISTS these before the theater starts (ShoveState:enter stores
-- them in state.shove_pending): quitting mid-shove and reloading replays
-- the same result instead of granting a fresh roll.
function Gauntlet.rollOutcomes(state, rates)
    local current_unlocked_act = 1
    if state then
        if state.shove_r2_won then
            current_unlocked_act = 3
        elseif state.shove_r1_won then
            current_unlocked_act = 2
        end
    end
    local o = { false, false, false }
    o[1] = RNG.chance(rates.r1)
    if o[1] and current_unlocked_act >= 2 then
        o[2] = RNG.chance(rates.r2)
        if o[2] and current_unlocked_act >= 3 then
            o[3] = RNG.chance(rates.r3)
        end
    end
    return o
end

-- `forced_outcomes` (optional): a pre-rolled {bool,bool,bool} from
-- rollOutcomes, used by the resumable-shove path. Without it (debug F2 /
-- START_IN_SHOVE) the gauntlet rolls its own.
function Gauntlet:begin(forced_outcomes)
    self.state = "running"

    local o = forced_outcomes
        or Gauntlet.rollOutcomes(self.game.state, self.rates)
    self.outcomes[1] = o[1] and true or false
    self.outcomes[2] = o[2] and true or false
    self.outcomes[3] = o[3] and true or false

    self:_constructJointly()
    self:_evaluateAllRunouts()

    self.state  = "finished"
    self.result = self:_buildResult()
    return self.result
end

-- Player vs dealer on the current board: 1 the player wins, -1 the
-- dealer wins, 0 a tie. Also returns both rank tuples so callers that
-- need the categories (the plausibility floors) don't re-evaluate.
function Gauntlet:_compare()
    local p_cards, d_cards = {}, {}
    for _, c in ipairs(self.player_hole)  do table.insert(p_cards, c) end
    for _, c in ipairs(self.board)        do table.insert(p_cards, c) end
    for _, c in ipairs(self.dealer_hole)  do table.insert(d_cards, c) end
    for _, c in ipairs(self.board)        do table.insert(d_cards, c) end
    local p_rank = HandEval.bestFiveOfN(p_cards)
    local d_rank = HandEval.bestFiveOfN(d_cards)
    return HandEval.compare(p_rank, d_rank), p_rank, d_rank
end

-- Whether the player STRICTLY beats the dealer. Draw = loss.
function Gauntlet:_currentlyWinning()
    return self:_compare() > 0
end

-- Whether the board shows the rolled outcome with a clear winner: a win
-- is the player strictly ahead, a loss is the dealer strictly ahead. A
-- tie matches nothing, so the search keeps looking: the winner wins.
-- Stashes the two rank tuples for the plausibility check that follows.
function Gauntlet:_shows(outcome)
    local c, p_rank, d_rank = self:_compare()
    self._last_p_rank, self._last_d_rank = p_rank, d_rank
    if outcome then return c > 0 end
    return c < 0
end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = love.math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

-- The runout-1 winner has to show a hand worth the drama. The rank
-- tuples were stashed by the _shows call this always follows, so the
-- floor check costs nothing.
function Gauntlet:_r1Plausible(relax)
    local pol = self.realism
    if not pol then return true end
    local floor
    if relax then
        floor = (pol.relaxed and pol.relaxed.cat_floor) or 1
    else
        floor = self.outcomes[1] and pol.r1_win_cat_floor
                                  or pol.r1_loss_cat_floor
    end
    local rank = self.outcomes[1] and self._last_p_rank or self._last_d_rank
    if not rank then return true end
    return rank[1] >= (floor or 1)
end

-- Classify every candidate runner: appended to the board, does it keep
-- the player strictly ahead ("safe") or hand it to the dealer ("rob")?
-- Ties land in neither list — a tie card can never be a robbery card
-- (draw = loss is decided by _shows/_compare, untouched here) and never
-- a survival card. Bails out (returns nil) the moment the rob count
-- exceeds `rob_cap`: past the band there is no acceptable pick, so the
-- rest of the scan is wasted work.
function Gauntlet:_classifyRunnerCards(cands, rob_cap)
    local safe, rob = {}, {}
    local board = self.board
    local slot  = #board + 1
    for _, c in ipairs(cands) do
        board[slot] = c
        local cmp = self:_compare()
        board[slot] = nil
        if cmp > 0 then
            safe[#safe + 1] = c
        elseif cmp < 0 then
            rob[#rob + 1] = c
            if #rob > rob_cap then return nil end
        end
    end
    return safe, rob
end

-- After hole + 5-board are dealt and runout 1 matches, plan the (c6, c7)
-- runners. Unlike the old first-in-a-shuffle scan, this classifies EVERY
-- candidate first — the rob-count is the House's real out-count, and the
-- policy bands in data/showdown_realism.lua decide whether this deal's
-- outs tell an acceptable story:
--   * a robbery runner must come from a mid-sized out band (a real beat,
--     not a repeated one-outer),
--   * a survived runner must not have dodged a monster draw
--     (and drawing dead is fine — a locked-up win is real poker).
-- Rejecting the deal sends the outer loop back for a fresh one.
function Gauntlet:_planCheatCards(relax)
    self._outs_c6, self._outs_c7 = nil, nil
    if not self.outcomes[1] then return true end

    local pol       = self.realism
    local rob_band  = (relax and pol.relaxed and pol.relaxed.rob_outs)
                      or pol.rob_outs
    local max_sweat = (relax and pol.relaxed and pol.relaxed.max_sweat_outs)
                      or pol.max_sweat_outs

    -- ── Runout 2: robbed at c6 ──
    if self.outcomes[2] == false then
        local _, rob6 = self:_classifyRunnerCards(self.deck:remaining(),
                                                  rob_band[2])
        if not rob6 or #rob6 < rob_band[1] then return false end
        self._outs_c6 = #rob6
        local c6 = rob6[love.math.random(#rob6)]
        self.board[#self.board + 1] = c6
        self.deck:removeCard(c6)
        return true
    end

    -- ── Runout 2 survives: c6 must be safe, dealer outs within the sweat cap ──
    local safe6, rob6 = self:_classifyRunnerCards(self.deck:remaining(),
                                                  max_sweat)
    if not safe6 or #safe6 == 0 then return false end
    self._outs_c6 = #rob6
    shuffle(safe6)
    local c6_tries = math.min(#safe6, pol.survive_c6_tries or #safe6)
    for i = 1, c6_tries do
        local c6 = safe6[i]
        self.board[#self.board + 1] = c6
        local c7_cands = {}
        for _, c in ipairs(self.deck:remaining()) do
            if c ~= c6 then c7_cands[#c7_cands + 1] = c end
        end
        if self.outcomes[3] == false then
            -- Robbed at c7. This is also the Act-3-locked path (an R2 win
            -- with Act 3 closed rolls outcomes[3] = false): contract kept.
            local _, rob7 = self:_classifyRunnerCards(c7_cands, rob_band[2])
            if rob7 and #rob7 >= rob_band[1] then
                self._outs_c7 = #rob7
                local c7 = rob7[love.math.random(#rob7)]
                self.board[#self.board + 1] = c7
                self.deck:removeCard(c6)
                self.deck:removeCard(c7)
                return true
            end
        else
            -- Full win: c7 safe too.
            local safe7, rob7 = self:_classifyRunnerCards(c7_cands, max_sweat)
            if safe7 and #safe7 > 0 then
                self._outs_c7 = #rob7
                local c7 = safe7[love.math.random(#safe7)]
                self.board[#self.board + 1] = c7
                self.deck:removeCard(c6)
                self.deck:removeCard(c7)
                return true
            end
        end
        self.board[#self.board] = nil    -- pop c6, try the next safe card
    end
    return false
end

function Gauntlet:_constructJointly()
    local cap = Constants.GAUNTLET.REJECTION_RETRY_CAP
    local pol = self.realism
    local strict_until = (pol and pol.strict_attempts) or 0
    for attempt = 1, cap do
        local relax = attempt > strict_until
        self.deck = Deck:new()
        self.player_hole = { self.deck:draw(), self.deck:draw() }
        self.dealer_hole = { self.deck:draw(), self.deck:draw() }
        self.board       = {
            self.deck:draw(), self.deck:draw(), self.deck:draw(),
            self.deck:draw(), self.deck:draw(),
        }

        if self:_shows(self.outcomes[1])
           and self:_r1Plausible(relax)
           and self:_planCheatCards(relax) then
            self.natural[1] = true
            if self.outcomes[1] then self.natural[2] = true end
            if self.outcomes[2] then self.natural[3] = true end
            return
        end
    end

    -- Cap exhausted. Use the last deal as-is and override outcomes.
    self._outs_c6, self._outs_c7 = nil, nil    -- stale from failed attempts
    self.outcomes[1] = self:_currentlyWinning()
    self.natural[1]  = false
    if not self.outcomes[1] then
        self.outcomes[2], self.outcomes[3] = nil, nil
        return
    end
    table.insert(self.board, self.deck:draw())
    self.outcomes[2] = self:_currentlyWinning()
    self.natural[2]  = false
    if not self.outcomes[2] then
        self.outcomes[3] = nil
        return
    end
    table.insert(self.board, self.deck:draw())
    self.outcomes[3] = self:_currentlyWinning()
    self.natural[3]  = false
end

function Gauntlet:_evaluateAllRunouts()
    local full_board = self.board
    if #full_board >= 5 then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5] }
        self.evals[1] = self:_evaluateRunout()
    end
    if #full_board >= 6 and self.outcomes[1] then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5], full_board[6] }
        self.evals[2] = self:_evaluateRunout()
    end
    if #full_board >= 7 and self.outcomes[2] then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5], full_board[6], full_board[7] }
        self.evals[3] = self:_evaluateRunout()
    end
    self.board = full_board
end

function Gauntlet:_evaluateRunout()
    local p_cards, d_cards = {}, {}
    for _, c in ipairs(self.player_hole) do table.insert(p_cards, c) end
    for _, c in ipairs(self.board)       do table.insert(p_cards, c) end
    for _, c in ipairs(self.dealer_hole) do table.insert(d_cards, c) end
    for _, c in ipairs(self.board)       do table.insert(d_cards, c) end
    local p_rank, p_combo = HandEval.bestFiveOfN(p_cards)
    local d_rank, d_combo = HandEval.bestFiveOfN(d_cards)
    return {
        board_card_count = #self.board,
        player_rank      = p_rank,
        player_combo     = p_combo,
        dealer_rank      = d_rank,
        dealer_combo     = d_combo,
        won              = HandEval.compare(p_rank, d_rank) > 0,
    }
end

function Gauntlet:_buildResult()
    local won_all = self.outcomes[1] and self.outcomes[2] and self.outcomes[3]
    local busted_at = nil
    for i = 1, 3 do
        if self.outcomes[i] == false then busted_at = i; break end
    end
    return {
        won         = won_all and true or false,
        busted_at   = busted_at,
        outcomes    = { self.outcomes[1], self.outcomes[2], self.outcomes[3] },
        natural     = { self.natural[1],  self.natural[2],  self.natural[3]  },
        player_hole = self.player_hole,
        dealer_hole = self.dealer_hole,
        board       = self.board,
        evals       = self.evals,
        rates       = self.rates,
        -- Debug/analytics only (formatResult prints these; no view reads
        -- them): the House's live out-count when each runner was planned.
        outs        = {
            c6       = self._outs_c6,
            c7       = self._outs_c7,
            c6_total = 43,
            c7_total = 42,
        },
    }
end

-- ─── Debug formatting ────────────────────────────────────────────────

local function cardsStr(list)
    local out = {}
    for i, c in ipairs(list) do out[i] = tostring(c) end
    return table.concat(out, " ")
end

local function rankStr(rank_tuple)
    local cat = rank_tuple[1]
    local kickers = {}
    for i = 2, #rank_tuple do kickers[#kickers + 1] = tostring(rank_tuple[i]) end
    return string.format("%s (cat %d, kickers %s)",
        HandEval.categoryName(cat), cat,
        #kickers > 0 and table.concat(kickers, ",") or "—")
end

function Gauntlet.formatResult(result, attempt_n)
    local lines = {}
    local header
    local r = result.rates or {}
    if result.won then
        header = string.format(
            "[gauntlet #%d] r1=%.2f r2=%.2f r3=%.2f clear=%.2f  result=WON",
            attempt_n or 0, r.r1 or 0, r.r2 or 0, r.r3 or 0, r.clear or 0)
    else
        header = string.format(
            "[gauntlet #%d] r1=%.2f r2=%.2f r3=%.2f clear=%.2f  result=LOST@R%d",
            attempt_n or 0, r.r1 or 0, r.r2 or 0, r.r3 or 0, r.clear or 0,
            result.busted_at or 0)
    end
    lines[#lines + 1] = header
    lines[#lines + 1] = "  player hole: " .. cardsStr(result.player_hole)
    lines[#lines + 1] = "  dealer hole: " .. cardsStr(result.dealer_hole)

    local r1 = result.evals[1]
    if r1 then
        local board5 = { result.board[1], result.board[2], result.board[3], result.board[4], result.board[5] }
        lines[#lines + 1] = string.format("  R1 [5]:  %s", cardsStr(board5))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r1.player_rank))
        lines[#lines + 1] = string.format("    dealer: %s", rankStr(r1.dealer_rank))
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[1] and "WIN" or "LOSS",
            result.natural[1] == false and " (forced — rejection cap exhausted)" or " (natural)")
    end

    local r2 = result.evals[2]
    if r2 then
        lines[#lines + 1] = string.format("  R2 [+1]: %s", tostring(result.board[6]))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r2.player_rank))
        lines[#lines + 1] = string.format("    dealer: %s", rankStr(r2.dealer_rank))
        if result.outs and result.outs.c6 then
            lines[#lines + 1] = string.format("    house outs at c6: %d/%d",
                result.outs.c6, result.outs.c6_total)
        end
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[2] and "WIN" or "LOSS",
            result.natural[2] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    local r3 = result.evals[3]
    if r3 then
        lines[#lines + 1] = string.format("  R3 [+1]: %s", tostring(result.board[7]))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r3.player_rank))
        lines[#lines + 1] = string.format("    dealer: %s", rankStr(r3.dealer_rank))
        if result.outs and result.outs.c7 then
            lines[#lines + 1] = string.format("    house outs at c7: %d/%d",
                result.outs.c7, result.outs.c7_total)
        end
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[3] and "WIN" or "LOSS",
            result.natural[3] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    return table.concat(lines, "\n")
end

return Gauntlet
