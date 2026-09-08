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

-- ─── Fast scoring (no allocation, no combination walk) ─────────────────
--
-- `score(cards, n)` returns ONE number that orders hands exactly as
-- compare(bestFiveOfN(a), bestFiveOfN(b)) does, without enumerating the
-- C(n,5) combinations or allocating anything.
--
-- Why: the gauntlet's board search calls this tens of thousands of times to
-- construct one hand, and bestFiveOfN was 126 rank() calls apiece, each
-- allocating six tables. rank()/bestFiveOfN are still the source of truth
-- for anything that needs the tuple or the five cards making the hand (the
-- showdown label, the highlighted combo) — this is for the search, where
-- only the ordering matters.
--
-- Encoding: base-15 digits, most significant first — category, then the
-- same tiebreakers rank() would emit, zero-padded to five. Every value is
-- ≤ 14, so the encoding is faithful and exact in a double.
--
--   score = cat·15⁵ + t1·15⁴ + t2·15³ + t3·15² + t4·15 + t5
--
-- Scratch state is file-local and reused; score() is not reentrant, which
-- is fine — nothing calls it from inside itself.

-- Presence arrays rather than bitmasks: LOVE runs LuaJIT (Lua 5.1), which
-- has no bitwise operators. Indexed 2..14 plus slot 1 for the ace playing
-- low, so the wheel needs no special case.
-- Straight from data/the Card model rather than through c:rankValue(),
-- to keep the inner loop a table index. Card requires nothing, so this
-- pulls in no cycle.
local RANK_VALUES = require("models.Card").RANK_VALUES
local SUIT_INDEX  = { clubs = 1, diamonds = 2, hearts = 3, spades = 4 }

local _rank_count = {}
local _suit_count = {}
local _suit_has   = { {}, {}, {}, {} }
local _has        = {}

local P1 = 15
local P2 = 225
local P3 = 3375
local P4 = 50625
local P5 = 759375

local function encode(cat, t1, t2, t3, t4, t5)
    return cat * P5 + (t1 or 0) * P4 + (t2 or 0) * P3
                    + (t3 or 0) * P2 + (t4 or 0) * P1 + (t5 or 0)
end

-- Highest card of a straight in `has` (has[v] = rank v present), or nil.
-- has[1] is the ace playing low, so the wheel falls out of the same loop
-- instead of needing detectStraight's special case.
local function straightHigh(has)
    for high = 14, 5, -1 do
        if has[high] and has[high - 1] and has[high - 2]
           and has[high - 3] and has[high - 4] then
            return high
        end
    end
    return nil
end

function HandEval.score(cards, n)
    n = n or #cards

    local has = _has
    for v = 1, 14 do
        _rank_count[v] = 0
        has[v] = false
    end
    for s = 1, 4 do
        _suit_count[s] = 0
        local sh = _suit_has[s]
        for v = 1, 14 do sh[v] = false end
    end

    for i = 1, n do
        local c = cards[i]
        local v = RANK_VALUES[c.rank]
        local s = SUIT_INDEX[c.suit]
        _rank_count[v] = _rank_count[v] + 1
        has[v] = true
        if v == 14 then has[1] = true end          -- the ace, playing low
        if s then
            _suit_count[s] = _suit_count[s] + 1
            local sh = _suit_has[s]
            sh[v] = true
            if v == 14 then sh[1] = true end
        end
    end

    -- Flush, and the straight flush that may live inside it. Ten cards
    -- would be needed for two suits to both reach five, so at most one.
    local flush_suit
    for s = 1, 4 do
        if _suit_count[s] >= 5 then flush_suit = s; break end
    end

    if flush_suit then
        local sf = straightHigh(_suit_has[flush_suit])
        if sf then return encode(STRAIGHT_FLUSH, sf) end
    end

    -- Rank groups, best first: by count, then by value — the same ordering
    -- rank() gets from its sort.
    local q1v, q1c = 0, 0       -- best group
    local q2v, q2c = 0, 0       -- second best
    for v = 14, 2, -1 do
        local c = _rank_count[v]
        if c > 0 then
            if c > q1c then
                q2v, q2c = q1v, q1c
                q1v, q1c = v, c
            elseif c > q2c then
                q2v, q2c = v, c
            end
        end
    end

    if q1c == 4 then
        local kicker = 0
        for v = 14, 2, -1 do
            if v ~= q1v and _rank_count[v] > 0 then kicker = v; break end
        end
        return encode(QUADS, q1v, kicker)
    end

    -- The boat's pair is the highest-VALUE partner, not the next group by
    -- count: with seven or more cards a second set of trips can sit BELOW a
    -- plain pair (JJJ 777 88 is Jacks full of EIGHTS), and picking by count
    -- would take the sevens. rank() never sees this — five cards cannot hold
    -- two trips — so the reference only disagrees at the sizes the gauntlet
    -- actually searches.
    if q1c >= 3 then
        local pair_v = 0
        for v = 14, 2, -1 do
            if v ~= q1v and _rank_count[v] >= 2 then pair_v = v; break end
        end
        if pair_v > 0 then return encode(FULL_HOUSE, q1v, pair_v) end
    end

    if flush_suit then
        local sh = _suit_has[flush_suit]
        local a, b, c, d, e = 0, 0, 0, 0, 0
        local got = 0
        for v = 14, 2, -1 do
            if sh[v] then
                got = got + 1
                if     got == 1 then a = v
                elseif got == 2 then b = v
                elseif got == 3 then c = v
                elseif got == 4 then d = v
                elseif got == 5 then e = v; break end
            end
        end
        return encode(FLUSH, a, b, c, d, e)
    end

    local st = straightHigh(has)
    if st then return encode(STRAIGHT, st) end

    if q1c == 3 then
        local k1, k2 = 0, 0
        for v = 14, 2, -1 do
            if v ~= q1v and _rank_count[v] > 0 then
                if k1 == 0 then k1 = v
                else k2 = v; break end
            end
        end
        return encode(TRIPS, q1v, k1, k2)
    end

    if q1c == 2 and q2c == 2 then
        local kicker = 0
        for v = 14, 2, -1 do
            if v ~= q1v and v ~= q2v and _rank_count[v] > 0 then kicker = v; break end
        end
        return encode(TWO_PAIR, q1v, q2v, kicker)
    end

    if q1c == 2 then
        local k1, k2, k3 = 0, 0, 0
        for v = 14, 2, -1 do
            if v ~= q1v and _rank_count[v] > 0 then
                if     k1 == 0 then k1 = v
                elseif k2 == 0 then k2 = v
                else   k3 = v; break end
            end
        end
        return encode(PAIR, q1v, k1, k2, k3)
    end

    local a, b, c, d, e = 0, 0, 0, 0, 0
    local got = 0
    for v = 14, 2, -1 do
        if _rank_count[v] > 0 then
            got = got + 1
            if     got == 1 then a = v
            elseif got == 2 then b = v
            elseif got == 3 then c = v
            elseif got == 4 then d = v
            elseif got == 5 then e = v; break end
        end
    end
    return encode(HIGH_CARD, a, b, c, d, e)
end

-- Showdown label for one 2-card hole + a 5-card board. Returns the
-- describe() string AND the best-5 combo (the cards making the hand), or
-- (nil, nil) when the inputs aren't a complete 2 + 5 deal. Used by
-- models/Table.
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
