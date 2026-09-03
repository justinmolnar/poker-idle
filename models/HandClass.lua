-- models/HandClass.lua
--
-- The 169 canonical starting hands. Suits only matter to a hold'em hand
-- preflop insofar as the two cards share one or not, so the 1326 possible
-- two-card combinations collapse to 169 classes: 13 pairs, 78 suited, 78
-- offsuit. That collapse is what makes a preflop equity table small enough
-- to ship (data/preflop_equity.lua is indexed by these classes).
--
-- ─── The ordering contract ──────────────────────────────────────────────
-- Index order is fixed and load-bearing: the generated equity table is a
-- flat matrix in THIS order, so a change here silently invalidates the
-- data file. sim/gen_preflop_equity.lua requires this module rather than
-- rebuilding the order, so the two can never drift.
--
--   for hi = 14 down to 2:
--     for lo = hi down to 2:
--       hi == lo → the pair class          (AA, KK, ... 22)
--       hi >  lo → suited, then offsuit    (AKs, AKo, AQs, AQo, ...)
--
-- So index 1 = AA, 2 = AKs, 3 = AKo, ... 169 = 32o.
--
-- ─── Card conventions ───────────────────────────────────────────────────
-- models/Card carries string ranks ("2".."10","j","q","k","a") and has no
-- __eq, so "already dealt" is tracked the way the rest of the codebase
-- does it: a `seen` set keyed by `suit .. rank`.

local Card = require("models.Card")

local HandClass = {}

local COUNT = 169
HandClass.COUNT = COUNT

-- Rank value (2..14) → the label used in class names.
local VALUE_LABEL = {
    [2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",[8]="8",[9]="9",
    [10]="T",[11]="J",[12]="Q",[13]="K",[14]="A",
}

-- Rank value → the Card.RANKS string ("10" not "T" — the sprite names and
-- HandEval both use the card-side spelling).
local VALUE_RANK = {
    [2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",[8]="8",[9]="9",
    [10]="10",[11]="j",[12]="q",[13]="k",[14]="a",
}

local SUITS = Card.SUITS

-- Built once at load: the ordering contract above, materialized.
local NAMES     = {}     -- [i] = "AKs"
local INDEX     = {}     -- ["AKs"] = i
local HI        = {}     -- [i] = high rank value
local LO        = {}     -- [i] = low rank value
local SUITED    = {}     -- [i] = true | false (pairs are false)
local IS_PAIR   = {}     -- [i] = true | false
local COMBOS    = {}     -- [i] = 6 | 4 | 12
-- BASE[hi][lo] = index of the PAIR (hi == lo) or of the SUITED class
-- (hi > lo); the offsuit class is always the next index. classIndex uses
-- this to stay allocation-free on the hot path.
local BASE      = {}

do
    local i = 0
    for hi = 14, 2, -1 do
        BASE[hi] = {}
        for lo = hi, 2, -1 do
            if hi == lo then
                i = i + 1
                NAMES[i]   = VALUE_LABEL[hi] .. VALUE_LABEL[hi]
                HI[i], LO[i] = hi, lo
                SUITED[i]  = false
                IS_PAIR[i] = true
                COMBOS[i]  = 6
                BASE[hi][lo] = i
            else
                i = i + 1
                NAMES[i]   = VALUE_LABEL[hi] .. VALUE_LABEL[lo] .. "s"
                HI[i], LO[i] = hi, lo
                SUITED[i]  = true
                IS_PAIR[i] = false
                COMBOS[i]  = 4
                BASE[hi][lo] = i

                i = i + 1
                NAMES[i]   = VALUE_LABEL[hi] .. VALUE_LABEL[lo] .. "o"
                HI[i], LO[i] = hi, lo
                SUITED[i]  = false
                IS_PAIR[i] = false
                COMBOS[i]  = 12
            end
        end
    end
    assert(i == COUNT, "HandClass ordering produced " .. i .. " classes")
    for k = 1, COUNT do INDEX[NAMES[k]] = k end
end

HandClass.NAMES = NAMES
HandClass.INDEX = INDEX

-- Class index (1..169) for two Cards. No string building — this runs
-- inside the per-hand construction loops.
function HandClass.classIndex(c1, c2)
    local v1, v2 = c1:rankValue(), c2:rankValue()
    local hi, lo
    if v1 >= v2 then hi, lo = v1, v2 else hi, lo = v2, v1 end
    local base = BASE[hi][lo]
    if hi == lo then return base end
    if c1.suit == c2.suit then return base end
    return base + 1
end

function HandClass.comboCount(i) return COMBOS[i] end
function HandClass.isPair(i)     return IS_PAIR[i] end
function HandClass.isSuited(i)   return SUITED[i] end
function HandClass.name(i)       return NAMES[i] end

-- The 52 cards as { suit, rank, key } records, where key is the
-- `suit .. rank` string the codebase uses for "already dealt" sets.
-- Precomputed because the construction loops rebuild the undealt deck
-- many times per hand, and doing 52 string concatenations each time is
-- most of what that costs.
local CARD_KEYS = {}
do
    for _, suit in ipairs(SUITS) do
        for _, rank in ipairs(Card.RANKS) do
            CARD_KEYS[#CARD_KEYS + 1] = { suit, rank, suit .. rank }
        end
    end
end

-- Every concrete suit assignment for a class, as
-- { suit_hi, suit_lo, key_hi, key_lo }. Pairs: C(4,2) = 6. Suited: 4.
-- Offsuit: 4×3 = 12. Order is fixed so the deterministic fallback in
-- realize() is reproducible. Keys are baked in for the same reason as
-- above — the ranks are fixed by the class, so they can be.
local COMBO_SUITS = {}
do
    for i = 1, COUNT do
        local rank_hi, rank_lo = VALUE_RANK[HI[i]], VALUE_RANK[LO[i]]
        local list = {}
        local function add(s1, s2)
            list[#list + 1] = { s1, s2, s1 .. rank_hi, s2 .. rank_lo }
        end
        if IS_PAIR[i] then
            for a = 1, 4 do
                for b = a + 1, 4 do add(SUITS[a], SUITS[b]) end
            end
        elseif SUITED[i] then
            for a = 1, 4 do add(SUITS[a], SUITS[a]) end
        else
            for a = 1, 4 do
                for b = 1, 4 do
                    if a ~= b then add(SUITS[a], SUITS[b]) end
                end
            end
        end
        COMBO_SUITS[i] = list
    end
end

-- The class's concrete suit assignments, as a list of {suit1, suit2} for
-- the high and low rank. Read-only — callers must not mutate it. Used by
-- the offline equity generator to enumerate a class exhaustively rather
-- than sampling it.
function HandClass.comboSuits(i) return COMBO_SUITS[i] end

-- The Card.RANKS spelling of a class's two ranks (high, low).
function HandClass.ranks(i) return VALUE_RANK[HI[i]], VALUE_RANK[LO[i]] end

-- Turn a class into two concrete Cards that avoid everything in `seen`
-- (a set keyed `suit .. rank`), marking the two it returns into `seen`.
--
-- Tries the class's suit combinations in random order and takes the first
-- that is fully unseen. Returns nil when every combination is blocked —
-- the caller decides whether to resample the class or give up (with ≤7
-- cards seen a class can be fully blocked only in contrived cases, but
-- "returns nil" is a cleaner contract than an assert on the hot path).
function HandClass.realize(i, seen)
    local list = COMBO_SUITS[i]
    local n    = #list
    local rank_hi, rank_lo = VALUE_RANK[HI[i]], VALUE_RANK[LO[i]]

    -- Random start + stride walks the fixed list in a rotated order: no
    -- table copy, no shuffle allocation, still unbiased enough for suits.
    local start = love.math.random(n)
    for step = 0, n - 1 do
        local combo = list[(start + step - 1) % n + 1]
        local k1, k2 = combo[3], combo[4]
        if not seen[k1] and not seen[k2] then
            seen[k1], seen[k2] = true, true
            return { Card:new(combo[1], rank_hi), Card:new(combo[2], rank_lo) }
        end
    end
    return nil
end

-- Every card NOT in `seen`, as fresh Card objects. The construction paths
-- deal boards out of this.
function HandClass.remainingCards(seen)
    local out, n = {}, 0
    for k = 1, 52 do
        local entry = CARD_KEYS[k]
        if not seen[entry[3]] then
            n = n + 1
            out[n] = Card:new(entry[1], entry[2])
        end
    end
    return out
end

return HandClass
