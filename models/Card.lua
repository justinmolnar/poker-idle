-- models/Card.lua
--
-- A single playing card. Pure data + view helpers — no game logic.
--
-- spriteName() returns the path under assets/sprites/ that the SpriteLoader
-- indexes by. Cards live at assets/sprites/cards/fronts/<suit>/<rank>.png,
-- so a card's sprite name is "cards/fronts/<suit>/<rank>".
-- rankValue() returns 2..14 (a = 14) for the hand evaluator.

local Card = {}
Card.__index = Card

local RANK_VALUES = {
    ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6,
    ["7"] = 7, ["8"] = 8, ["9"] = 9, ["10"] = 10,
    j = 11, q = 12, k = 13, a = 14,
}

local SUITS = { "clubs", "diamonds", "hearts", "spades" }
local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "j", "q", "k", "a" }

-- One instance per (suit, rank), made on first use and shared after. A
-- card is immutable data (nothing writes a field on one), so two decks
-- holding the same card hold the same table; equality by identity is
-- then equality by value, which is what every `c == card` meant. A deck
-- was fifty-two fresh tables a hand (the busiest board deals a hand or
-- two a frame), and the gauntlet's search builds hundreds of decks.
local _by_suit = {}
function Card:new(suit, rank)
    local by_rank = _by_suit[suit]
    if not by_rank then by_rank = {}; _by_suit[suit] = by_rank end
    local c = by_rank[rank]
    if not c then
        c = setmetatable({ suit = suit, rank = rank }, Card)
        by_rank[rank] = c
    end
    return c
end

-- Every (suit, rank) name, built once at load. Cards are drawn every frame
-- (up to 19 per table panel) and this was a two-part concatenation per card
-- per draw; the table is 52 strings and never changes. Built here rather
-- than stamped onto each Card because the gauntlet's search allocates
-- hundreds of decks, and those must stay as cheap as they are.
local SPRITE_NAMES = {}
for _, suit in ipairs(SUITS) do
    local by_rank = {}
    for _, rank in ipairs(RANKS) do
        by_rank[rank] = "cards/fronts/" .. suit .. "/" .. rank
    end
    SPRITE_NAMES[suit] = by_rank
end

function Card:spriteName()
    local by_rank = SPRITE_NAMES[self.suit]
    return by_rank and by_rank[self.rank]
        or ("cards/fronts/" .. self.suit .. "/" .. self.rank)
end

function Card:rankValue()
    return RANK_VALUES[self.rank]
end

function Card.__tostring(c)
    return c.rank:upper() .. c.suit:sub(1, 1):upper()
end

Card.SUITS = SUITS
Card.RANKS = RANKS
Card.RANK_VALUES = RANK_VALUES

return Card
