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

function Card:new(suit, rank)
    return setmetatable({ suit = suit, rank = rank }, Card)
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
