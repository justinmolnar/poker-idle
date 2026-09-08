-- sim/verify_hand_score.lua
--
-- HandEval.score is the gauntlet's fast path: one number per hand, no
-- combination walk, no allocation. It is only safe if it orders hands
-- EXACTLY as the reference does — compare(bestFiveOfN(a), bestFiveOfN(b)).
--
-- This proves that on random deals of 5..9 cards, plus a hand-written set
-- of the cases most likely to diverge (wheels, straight flushes, two trips,
-- three pairs, a flush over a straight, quads with kickers).
--
-- Headless: `lua sim/verify_hand_score.lua` from the repo root.

io.stdout:setvbuf("no")
local cwd = (love and love.filesystem and love.filesystem.getWorkingDirectory()) or "."
package.path = package.path .. ";" .. cwd .. "/?.lua"

local function rnd(a, b)
    if a and b then return math.random(a, b) end
    if a then return math.random(a) end
    return math.random()
end
love = love or {}
love.math = love.math or {}
love.math.random = rnd
love.timer = { getTime = function() return os.clock() end }

local Card     = require("models.Card")
local Deck     = require("models.Deck")
local HandEval = require("models.HandEval")

math.randomseed(4242)

local checks, failures = 0, 0
local function fail(msg)
    failures = failures + 1
    if failures <= 12 then print("FAIL  " .. msg) end
end

local function handStr(cards, n)
    local out = {}
    for i = 1, (n or #cards) do out[i] = tostring(cards[i]) end
    return table.concat(out, " ")
end

local function sign(x)
    if x < 0 then return -1 elseif x > 0 then return 1 end
    return 0
end

-- The reference: the tuple bestFiveOfN produces.
local function refRank(cards, n)
    local slice = {}
    for i = 1, n do slice[i] = cards[i] end
    return (HandEval.bestFiveOfN(slice))
end

-- One comparison, both ways.
local function checkPair(a, na, b, nb)
    checks = checks + 1
    local want = HandEval.compare(refRank(a, na), refRank(b, nb))
    local got  = sign(HandEval.score(a, na) - HandEval.score(b, nb))
    if want ~= got then
        fail(string.format("[%s] vs [%s]: reference %d, score %d",
             handStr(a, na), handStr(b, nb), want, got))
    end
end

-- ─── 1. Random deals across every legal size ───────────────────────────
local ROUNDS = 40000
for _ = 1, ROUNDS do
    local deck = Deck:new()
    local na = math.random(5, 9)
    local nb = math.random(5, 9)
    local a, b = {}, {}
    for i = 1, na do a[i] = deck:draw() end
    for i = 1, nb do b[i] = deck:draw() end
    checkPair(a, na, b, nb)
end

-- ─── 2. Shared-board deals, which is how the game actually compares ────
-- Two hole cards each over one community board: the exact shape the
-- gauntlet's search and the showdown use.
for _ = 1, 20000 do
    local deck  = Deck:new()
    local p = { deck:draw(), deck:draw() }
    local o = { deck:draw(), deck:draw() }
    local board = {}
    local nb = math.random(5, 7)
    for i = 1, nb do board[i] = deck:draw() end
    local pa, ob = { p[1], p[2] }, { o[1], o[2] }
    for i = 1, nb do pa[2 + i] = board[i]; ob[2 + i] = board[i] end
    checkPair(pa, 2 + nb, ob, 2 + nb)
end

-- ─── 3. Hand-written edge cases ────────────────────────────────────────
local function C(rank, suit) return Card:new(suit, rank) end
local function hand(...) return { ... } end

local cases = {
    -- The wheel, and the wheel as a straight flush.
    { hand(C("a","spades"), C("2","hearts"), C("3","clubs"), C("4","diamonds"), C("5","spades")), 5 },
    { hand(C("a","spades"), C("2","spades"), C("3","spades"), C("4","spades"), C("5","spades")), 5 },
    -- A six-high straight beats the wheel.
    { hand(C("2","hearts"), C("3","clubs"), C("4","diamonds"), C("5","spades"), C("6","hearts")), 5 },
    -- Two trips (a boat by the higher).
    { hand(C("k","spades"), C("k","hearts"), C("k","clubs"), C("7","diamonds"), C("7","spades"), C("7","hearts"), C("2","clubs")), 7 },
    -- Three pairs: the top two plus the best kicker.
    { hand(C("a","spades"), C("a","hearts"), C("k","clubs"), C("k","diamonds"), C("q","spades"), C("q","hearts"), C("3","clubs")), 7 },
    -- A flush and a straight in the same seven cards (flush wins).
    { hand(C("2","hearts"), C("3","hearts"), C("4","hearts"), C("5","hearts"), C("6","clubs"), C("9","hearts"), C("k","spades")), 7 },
    -- A boat sitting under a flush (boat wins).
    { hand(C("8","hearts"), C("8","clubs"), C("8","spades"), C("4","hearts"), C("4","clubs"), C("2","hearts"), C("9","hearts")), 7 },
    -- Quads with a kicker that matters.
    { hand(C("9","spades"), C("9","hearts"), C("9","clubs"), C("9","diamonds"), C("a","spades"), C("3","hearts"), C("2","clubs")), 7 },
    { hand(C("9","spades"), C("9","hearts"), C("9","clubs"), C("9","diamonds"), C("k","spades"), C("3","hearts"), C("2","clubs")), 7 },
    -- Straight flush vs a higher plain flush in another suit is impossible
    -- with nine cards, but a straight flush inside a bigger flush is not.
    { hand(C("5","spades"), C("6","spades"), C("7","spades"), C("8","spades"), C("9","spades"), C("k","spades"), C("2","hearts")), 7 },
    -- Ace-high straight.
    { hand(C("10","clubs"), C("j","hearts"), C("q","spades"), C("k","diamonds"), C("a","clubs")), 5 },
    -- Nine cards, the full runout-3 shape.
    { hand(C("a","spades"), C("k","spades"), C("q","spades"), C("j","hearts"), C("10","clubs"),
           C("9","diamonds"), C("8","hearts"), C("7","clubs"), C("2","spades")), 9 },
}

for i = 1, #cases do
    for j = 1, #cases do
        checkPair(cases[i][1], cases[i][2], cases[j][1], cases[j][2])
    end
end

-- ─── 4. Categories must land where the reference puts them ─────────────
-- score's top digit is the category, so it can be read back directly.
for _, case in ipairs(cases) do
    checks = checks + 1
    local ref = refRank(case[1], case[2])
    local cat = math.floor(HandEval.score(case[1], case[2]) / 759375)
    if cat ~= ref[1] then
        fail(string.format("[%s]: category %d, reference %d",
             handStr(case[1], case[2]), cat, ref[1]))
    end
end

print(string.format("\n%d comparisons, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
