-- models/Gauntlet.lua
--
-- The 3-runout cheating-dealer gauntlet. Stateful gameplay model — owns one
-- Deck, the player's hole, the growing board, and the per-runout outcomes.
--
-- ─── Math contract ──────────────────────────────────────────────────────
-- shove_rate is the GROUND TRUTH. Outcomes are rolled up front:
--     outcomes[1] = chance(shove_rate)
--     outcomes[2] = (only rolled if outcomes[1])  chance(shove_rate)
--     outcomes[3] = (only rolled if outcomes[2])  chance(shove_rate)
-- Cards are then constructed JOINTLY — we redeal hole+5-board until we can
-- find a 6th card AND (if needed) a 7th card from the remaining deck that
-- together produce all three rolled outcomes. Per-runout rejection alone is
-- biased: forcing a WIN almost always succeeds (random hole cards usually
-- improve the hand), while forcing a LOSS at runout 2/3 fails whenever the
-- player's hand is already strong enough that no single new card can flip
-- it. That bias was visible at shove_rate=0.5 — observed clear rate ~23%
-- vs the math-expected 12.5%. Joint construction fixes it.
--
-- If the outer cap is exhausted we accept whatever the last deal produced
-- and override the recorded outcomes so cards and displayed result agree.
-- The overlay's "rejection-cap exhausted" counter then reflects a real
-- math-vs-cards conflict, not a per-runout fluke.
--
-- ─── Engine-agnosticism ────────────────────────────────────────────────
-- Lives in models/ (not services/) because it's poker-specific stateful
-- gameplay logic. services/ is reserved for engine-agnostic infrastructure.
-- The deck / card / hand_eval primitives this builds on are themselves
-- generic and live in models/ + utils/.

local Deck        = require("models.Deck")
local HandEval    = require("utils.hand_eval")
local RNG         = require("utils.rng")
local Constants   = require("data.constants")

local Gauntlet = {}
Gauntlet.__index = Gauntlet

function Gauntlet:new(game, shove_rate)
    return setmetatable({
        game            = game,
        shove_rate      = shove_rate or 0,
        state           = "idle",          -- idle | running | finished
        deck            = nil,
        hole            = nil,             -- {Card, Card}
        board           = nil,             -- list, grows 5 → 6 → 7
        outcomes        = { nil, nil, nil },
        natural         = { nil, nil, nil },  -- false if a runout's outcome was forced by rejection-cap exhaustion
        evals           = { nil, nil, nil },  -- per-runout {player_rank, board_rank, …} for the view
        result          = nil,
    }, Gauntlet)
end

-- Run the entire gauntlet to completion synchronously. After this returns,
-- :result() is populated. Animation/staging will be layered on top in a
-- later phase by interleaving event_bus publishes between the deal steps.
function Gauntlet:begin()
    self.state = "running"

    self.outcomes[1] = RNG.chance(self.shove_rate)
    if self.outcomes[1] then
        self.outcomes[2] = RNG.chance(self.shove_rate)
        if self.outcomes[2] then
            self.outcomes[3] = RNG.chance(self.shove_rate)
        end
    end

    self:_constructJointly()
    self:_evaluateAllRunouts()

    self.state  = "finished"
    self.result = self:_buildResult()
    return self.result
end

-- Whether the current state of (hole + board) wins against the board alone.
-- A draw is a loss — the player must STRICTLY beat the board's hand.
function Gauntlet:_currentlyWinning()
    local all_player = {}
    for _, c in ipairs(self.hole)  do table.insert(all_player, c) end
    for _, c in ipairs(self.board) do table.insert(all_player, c) end
    local p_rank = HandEval.bestFiveOfN(all_player)
    local b_rank
    if #self.board == 5 then
        b_rank = HandEval.rank(self.board)
    else
        b_rank = HandEval.bestFiveOfN(self.board)
    end
    return HandEval.compare(p_rank, b_rank) > 0
end

-- In-place Fisher-Yates on a list (used to randomise candidate iteration).
local function shuffle(t)
    for i = #t, 2, -1 do
        local j = love.math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

-- Try to find a (c6) and (c7) from the deck that together produce
-- outcomes[2] and outcomes[3] given the current hole + 5-board. Returns
-- true on success (board is mutated to include c6, c7; deck has them
-- removed). Returns false on failure (board / deck restored to the
-- 5-board state on entry).
function Gauntlet:_findCheatCards()
    if not self.outcomes[1] then return true end  -- no R2/R3 needed

    local c6_candidates = self.deck:remaining()
    shuffle(c6_candidates)

    for _, c6 in ipairs(c6_candidates) do
        table.insert(self.board, c6)
        if self:_currentlyWinning() == self.outcomes[2] then
            if not self.outcomes[2] then
                -- R2 satisfied with c6, R3 not played. Commit.
                self.deck:removeCard(c6)
                return true
            end
            -- R2 satisfied; need a c7 too.
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

-- Joint construction. Redeals hole + 5-board until both runout 1 matches
-- AND a (c6, c7) pair exists that satisfies runouts 2 and 3. On success
-- all natural[*] = true. On cap exhaustion accepts whatever the last
-- attempt produced and overrides outcomes to match the cards.
function Gauntlet:_constructJointly()
    local cap = Constants.GAUNTLET.REJECTION_RETRY_CAP
    for _ = 1, cap do
        self.deck  = Deck:new()
        self.hole  = { self.deck:draw(), self.deck:draw() }
        self.board = { self.deck:draw(), self.deck:draw(), self.deck:draw(), self.deck:draw(), self.deck:draw() }

        if self:_currentlyWinning() == self.outcomes[1] then
            if self:_findCheatCards() then
                self.natural[1] = true
                if self.outcomes[1] then self.natural[2] = true end
                if self.outcomes[2] then self.natural[3] = true end
                return
            end
        end
    end

    -- Cap exhausted. Use the last hole+5-board as-is and override outcomes
    -- to match the cards. Pull arbitrary cards for any required cheat
    -- runouts and accept their natural results too.
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
    -- Snapshot board state at each runout boundary by working with prefixes.
    local full_board = self.board
    -- R1 (5 board cards)
    if #full_board >= 5 then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5] }
        self.evals[1] = self:_evaluateRunout()
    end
    -- R2 (6 board cards)
    if #full_board >= 6 and self.outcomes[1] then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5], full_board[6] }
        self.evals[2] = self:_evaluateRunout()
    end
    -- R3 (7 board cards)
    if #full_board >= 7 and self.outcomes[2] then
        self.board = { full_board[1], full_board[2], full_board[3], full_board[4], full_board[5], full_board[6], full_board[7] }
        self.evals[3] = self:_evaluateRunout()
    end
    -- Restore full board for the result payload.
    self.board = full_board
end

function Gauntlet:_evaluateRunout()
    local all_player = {}
    for _, c in ipairs(self.hole)  do table.insert(all_player, c) end
    for _, c in ipairs(self.board) do table.insert(all_player, c) end
    local p_rank, p_combo = HandEval.bestFiveOfN(all_player)
    local b_rank, b_combo
    if #self.board == 5 then
        b_rank, b_combo = HandEval.rank(self.board), self.board
    else
        b_rank, b_combo = HandEval.bestFiveOfN(self.board)
    end
    return {
        board_card_count = #self.board,
        player_rank      = p_rank,
        player_combo     = p_combo,
        board_rank       = b_rank,
        board_combo      = b_combo,
        won              = HandEval.compare(p_rank, b_rank) > 0,
    }
end

function Gauntlet:_buildResult()
    local won_all = self.outcomes[1] and self.outcomes[2] and self.outcomes[3]
    local busted_at = nil
    for i = 1, 3 do
        if self.outcomes[i] == false then busted_at = i; break end
    end
    return {
        won        = won_all and true or false,
        busted_at  = busted_at,
        outcomes   = { self.outcomes[1], self.outcomes[2], self.outcomes[3] },
        natural    = { self.natural[1],  self.natural[2],  self.natural[3]  },
        hole       = self.hole,
        board      = self.board,
        evals      = self.evals,
        shove_rate = self.shove_rate,
    }
end

-- ─── Debug formatting ────────────────────────────────────────────────
-- Multi-line copy-paste-able dump of a result. Used by the prototype's
-- console echo so the math can be hand-verified outside the running
-- LÖVE window. Pure formatter — no I/O.

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
    if result.won then
        header = string.format("[gauntlet #%d] rate=%.2f  result=WON",
            attempt_n or 0, result.shove_rate)
    else
        header = string.format("[gauntlet #%d] rate=%.2f  result=LOST@R%d",
            attempt_n or 0, result.shove_rate, result.busted_at or 0)
    end
    lines[#lines + 1] = header
    lines[#lines + 1] = "  hole:    " .. cardsStr(result.hole)

    -- R1: full 5-card board
    local r1 = result.evals[1]
    if r1 then
        local labels = { result.board[1], result.board[2], result.board[3], result.board[4], result.board[5] }
        lines[#lines + 1] = string.format("  R1 [5]:  %s", cardsStr(labels))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r1.player_rank))
        lines[#lines + 1] = string.format("    board:  %s", rankStr(r1.board_rank))
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[1] and "WIN" or "LOSS",
            result.natural[1] == false and " (forced — rejection cap exhausted)" or " (natural)")
    end

    -- R2: cheat card 6
    local r2 = result.evals[2]
    if r2 then
        lines[#lines + 1] = string.format("  R2 [+1]: %s", tostring(result.board[6]))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r2.player_rank))
        lines[#lines + 1] = string.format("    board:  %s", rankStr(r2.board_rank))
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[2] and "WIN" or "LOSS",
            result.natural[2] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    -- R3: cheat card 7
    local r3 = result.evals[3]
    if r3 then
        lines[#lines + 1] = string.format("  R3 [+1]: %s", tostring(result.board[7]))
        lines[#lines + 1] = string.format("    player: %s", rankStr(r3.player_rank))
        lines[#lines + 1] = string.format("    board:  %s", rankStr(r3.board_rank))
        lines[#lines + 1] = string.format("    → %s%s",
            result.outcomes[3] and "WIN" or "LOSS",
            result.natural[3] == false and " (forced — no satisfying card in deck)" or " (natural)")
    end

    return table.concat(lines, "\n")
end

return Gauntlet
