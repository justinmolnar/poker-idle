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
-- generic and live in models/ + utils/.

local Deck      = require("models.Deck")
local HandEval  = require("utils.hand_eval")
local RNG       = require("utils.rng")
local Constants = require("data.constants")

local Gauntlet = {}
Gauntlet.__index = Gauntlet

function Gauntlet:new(game, rates)
    return setmetatable({
        game        = game,
        rates       = rates or { r1 = 0, r2 = 0, r3 = 0, clear = 0 },
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

function Gauntlet:begin()
    self.state = "running"

    self.outcomes[1] = RNG.chance(self.rates.r1)
    if self.outcomes[1] then
        self.outcomes[2] = RNG.chance(self.rates.r2)
        if self.outcomes[2] then
            self.outcomes[3] = RNG.chance(self.rates.r3)
        end
    end

    self:_constructJointly()
    self:_evaluateAllRunouts()

    self.state  = "finished"
    self.result = self:_buildResult()
    return self.result
end

-- Whether the player STRICTLY beats the dealer given the current
-- player_hole, dealer_hole, and board. Draw = loss.
function Gauntlet:_currentlyWinning()
    local p_cards, d_cards = {}, {}
    for _, c in ipairs(self.player_hole)  do table.insert(p_cards, c) end
    for _, c in ipairs(self.board)        do table.insert(p_cards, c) end
    for _, c in ipairs(self.dealer_hole)  do table.insert(d_cards, c) end
    for _, c in ipairs(self.board)        do table.insert(d_cards, c) end
    local p_rank = HandEval.bestFiveOfN(p_cards)
    local d_rank = HandEval.bestFiveOfN(d_cards)
    return HandEval.compare(p_rank, d_rank) > 0
end

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = love.math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

-- After hole + 5-board are dealt and runout 1 matches, search the deck
-- for a (c6, c7) pair that satisfies runouts 2 and 3.
function Gauntlet:_findCheatCards()
    if not self.outcomes[1] then return true end

    local c6_candidates = self.deck:remaining()
    shuffle(c6_candidates)

    for _, c6 in ipairs(c6_candidates) do
        table.insert(self.board, c6)
        if self:_currentlyWinning() == self.outcomes[2] then
            if not self.outcomes[2] then
                self.deck:removeCard(c6)
                return true
            end
            local c7_candidates = {}
            for _, c in ipairs(self.deck:remaining()) do
                if c ~= c6 then table.insert(c7_candidates, c) end
            end
            shuffle(c7_candidates)
            for _, c7 in ipairs(c7_candidates) do
                table.insert(self.board, c7)
                if self:_currentlyWinning() == self.outcomes[3] then
                    self.deck:removeCard(c6)
                    self.deck:removeCard(c7)
                    return true
                end
                table.remove(self.board)
            end
        end
        table.remove(self.board)
    end
    return false
end

function Gauntlet:_constructJointly()
    local cap = Constants.GAUNTLET.REJECTION_RETRY_CAP
    for _ = 1, cap do
        self.deck = Deck:new()
        self.player_hole = { self.deck:draw(), self.deck:draw() }
        self.dealer_hole = { self.deck:draw(), self.deck:draw() }
        self.board       = {
            self.deck:draw(), self.deck:draw(), self.deck:draw(),
            self.deck:draw(), self.deck:draw(),
        }

        if self:_currentlyWinning() == self.outcomes[1] then
            if self:_findCheatCards() then
                self.natural[1] = true
                if self.outcomes[1] then self.natural[2] = true end
                if self.outcomes[2] then self.natural[3] = true end
                return
            end
        end
    end

    -- Cap exhausted. Use the last deal as-is and override outcomes.
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
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[2] and "WIN" or "LOSS",
            result.natural[2] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    local r3 = result.evals[3]
    if r3 then
        lines[#lines + 1] = string.format("  R3 [+1]: %s", tostring(result.board[7]))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r3.player_rank))
        lines[#lines + 1] = string.format("    dealer: %s", rankStr(r3.dealer_rank))
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[3] and "WIN" or "LOSS",
            result.natural[3] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    return table.concat(lines, "\n")
end

return Gauntlet
