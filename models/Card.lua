-- models/Card.lua
--
-- A single playing card. Pure data + view helpers — no game logic.
--
-- The sprite name maps directly to the asset path under assets/sprites/cards/
-- fronts/<suit>/<rank>.png — call SpriteLoader:getSprite(card:spriteName())
-- to render. rankValue() converts the string rank to a numeric weight (a=14)
-- for the hand evaluator.

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

function Card:spriteName()
    return self.suit .. "/" .. self.rank
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
