-- models/HandEval.lua
--
-- 5-card poker hand evaluator + best-5-of-N selector. Game-specific (it
-- knows about flushes, straights, full houses) but otherwise self-contained
-- — no rendering, no game-flow knowledge. Lives in models/ because it's
-- poker logic; the engine-agnostic infrastructure layers (utils/, services/,
-- core/, lib/) must not carry game-specific code.
--
-- A hand rank is represented as a tuple { category, t1, t2, ... } where
-- category is one of the constants below (higher = better) and the trailing
-- entries are tiebreakers in descending priority. compare() does lexicographic
-- comparison so ranks line up cleanly under <, ==, >.
--
-- Brute-force evaluation: bestFiveOfN enumerates C(N,5) combos (max 126 at
-- N=9) and ranks each. Sub-millisecond at the sizes the gauntlet uses; not
-- worth a Cactus-Kev lookup table for the prototype.

local HandEval = {}

local HIGH_CARD      = 1
local PAIR           = 2
local TWO_PAIR       = 3
local TRIPS          = 4
local STRAIGHT       = 5
local FLUSH          = 6
local FULL_HOUSE     = 7
local QUADS          = 8
local STRAIGHT_FLUSH = 9

HandEval.HIGH_CARD      = HIGH_CARD
HandEval.PAIR           = PAIR
HandEval.TWO_PAIR       = TWO_PAIR
HandEval.TRIPS          = TRIPS
HandEval.STRAIGHT       = STRAIGHT
HandEval.FLUSH          = FLUSH
HandEval.FULL_HOUSE     = FULL_HOUSE
HandEval.QUADS          = QUADS
HandEval.STRAIGHT_FLUSH = STRAIGHT_FLUSH

local CATEGORY_NAMES = {
    [HIGH_CARD]      = "high card",
    [PAIR]           = "pair",
    [TWO_PAIR]       = "two pair",
    [TRIPS]          = "three of a kind",
    [STRAIGHT]       = "straight",
    [FLUSH]          = "flush",
    [FULL_HOUSE]     = "full house",
    [QUADS]          = "four of a kind",
    [STRAIGHT_FLUSH] = "straight flush",
}

function HandEval.categoryName(cat)
    return CATEGORY_NAMES[cat] or "unknown"
end

local RANK_LABEL = {
    [2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",[8]="8",[9]="9",
    [10]="10",[11]="J",[12]="Q",[13]="K",[14]="A",
}

-- Player-readable description of a rank tuple. "pair of Aces", "trip 7s",
-- "Jack-high straight", etc. Used by views to label the player + board hands.
function HandEval.describe(rank_tuple)
    if not rank_tuple then return "—" end
    local cat  = rank_tuple[1]
    local main = rank_tuple[2]
    local sec  = rank_tuple[3]
    local m = RANK_LABEL[main] or "?"
    local s = RANK_LABEL[sec]  or "?"
    if     cat == STRAIGHT_FLUSH then return m .. "-high straight flush"
    elseif cat == QUADS          then return "quad " .. m .. "s"
    elseif cat == FULL_HOUSE     then return m .. "s full of " .. s .. "s"
    elseif cat == FLUSH          then return m .. "-high flush"
    elseif cat == STRAIGHT       then return m .. "-high straight"
    elseif cat == TRIPS          then return "trip " .. m .. "s"
    elseif cat == TWO_PAIR       then return "two pair, " .. m .. "s and " .. s .. "s"
    elseif cat == PAIR           then return "pair of " .. m .. "s"
    elseif cat == HIGH_CARD      then return m .. "-high"
    end
    return CATEGORY_NAMES[cat] or "unknown"
end

local function sortDesc(t)
    table.sort(t, function(a, b) return a > b end)
end

-- Detect a straight in unique-rank-values sorted desc. Returns the top rank
-- of the straight, or nil. Handles A-2-3-4-5 wheel as 5-high.
local function detectStraight(unique_desc)
    if #unique_desc < 5 then return nil end
    for i = 1, #unique_desc - 4 do
        if unique_desc[i] - unique_desc[i + 4] == 4 then
            return unique_desc[i]
        end
    end
    if unique_desc[1] == 14 then
        local seen = {}
        for _, v in ipairs(unique_desc) do seen[v] = true end
        if seen[2] and seen[3] and seen[4] and seen[5] then return 5 end
    end
    return nil
end

function HandEval.rank(cards)
    assert(#cards == 5, "HandEval.rank expects exactly 5 cards")

    local values, suits = {}, {}
    for i, c in ipairs(cards) do
        values[i] = c:rankValue()
        suits[i]  = c.suit
    end
    sortDesc(values)

    local counts = {}
    for _, v in ipairs(values) do counts[v] = (counts[v] or 0) + 1 end

    local groups = {}
    for v, c in pairs(counts) do table.insert(groups, { value = v, count = c }) end
    table.sort(groups, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.value > b.value
    end)

    local first_suit = suits[1]
    local is_flush = true
    for i = 2, 5 do
        if suits[i] ~= first_suit then is_flush = false; break end
    end

    local unique_desc = {}
    for _, g in ipairs(groups) do table.insert(unique_desc, g.value) end
    sortDesc(unique_desc)
    local straight_high = detectStraight(unique_desc)

    if is_flush and straight_high then
        return { STRAIGHT_FLUSH, straight_high }
    end
    if groups[1].count == 4 then
        return { QUADS, groups[1].value, groups[2].value }
    end
    if groups[1].count == 3 and groups[2] and groups[2].count == 2 then
        return { FULL_HOUSE, groups[1].value, groups[2].value }
    end
    if is_flush then
        return { FLUSH, values[1], values[2], values[3], values[4], values[5] }
    end
    if straight_high then
        return { STRAIGHT, straight_high }
    end
    if groups[1].count == 3 then
        return { TRIPS, groups[1].value, groups[2].value, groups[3].value }
    end
    if groups[1].count == 2 and groups[2] and groups[2].count == 2 then
        return { TWO_PAIR, groups[1].value, groups[2].value, groups[3].value }
    end
    if groups[1].count == 2 then
        return { PAIR, groups[1].value, groups[2].value, groups[3].value, groups[4].value }
    end
    return { HIGH_CARD, values[1], values[2], values[3], values[4], values[5] }
end

function HandEval.compare(a, b)
    local n = math.max(#a, #b)
    for i = 1, n do
        local av, bv = a[i] or 0, b[i] or 0
        if av < bv then return -1 end
        if av > bv then return  1 end
    end
    return 0
end

-- Best 5-card hand drawn from up to 9 cards (2 hole + 7 board for runout 3).
-- Returns { rank_tuple, picked_5_cards }.
function HandEval.bestFiveOfN(cards)
    local n = #cards
    assert(n >= 5 and n <= 9, "bestFiveOfN expects 5..9 cards, got " .. tostring(n))
    if n == 5 then
        return HandEval.rank(cards), cards
    end

    local best_rank, best_combo = nil, nil
    local picked = {}

    local function recurse(start)
        if #picked == 5 then
            local r = HandEval.rank(picked)
            if not best_rank or HandEval.compare(r, best_rank) > 0 then
                best_rank  = r
                best_combo = { picked[1], picked[2], picked[3], picked[4], picked[5] }
            end
            return
        end
        for i = start, n do
            table.insert(picked, cards[i])
            recurse(i + 1)
            table.remove(picked)
        end
    end
    recurse(1)
    return best_rank, best_combo
end

-- Showdown label for one 2-card hole + a 5-card board. Returns the
-- describe() string AND the best-5 combo (the cards making the hand), or
-- (nil, nil) when the inputs aren't a complete 2 + 5 deal. Shared by
-- models/Table and models/Table_legacy so the two can't drift on this.
function HandEval.handLabel(hole, board)
    if not (hole and #hole >= 2 and board and #board == 5) then
        return nil, nil
    end
    local cards = {
        hole[1], hole[2],
        board[1], board[2], board[3], board[4], board[5],
    }
    local rank, combo = HandEval.bestFiveOfN(cards)
    return HandEval.describe(rank), combo
end

return HandEval
