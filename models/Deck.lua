-- models/Deck.lua
--
-- A standard 52-card deck. Stateful — the Gauntlet owns one per shove and
-- mutates it as cards are dealt. For deterministic tests, call
-- love.math.setRandomSeed(seed) before constructing.
--
--   :draw()            → pop top card
--   :remaining()       → shallow copy of cards still in the deck
--   :removeCard(card)  → remove a specific card (used during runout 2/3
--                        rejection sampling so the chosen cheat card isn't
--                        re-drawn on the next runout)

local Card = require("models.Card")

local Deck = {}
Deck.__index = Deck

function Deck:new()
    local self = setmetatable({}, Deck)
    self.cards = {}
    for _, suit in ipairs(Card.SUITS) do
        for _, rank in ipairs(Card.RANKS) do
            table.insert(self.cards, Card:new(suit, rank))
        end
    end
    self:shuffle()
    return self
end

function Deck:shuffle()
    for i = #self.cards, 2, -1 do
        local j = love.math.random(1, i)
        self.cards[i], self.cards[j] = self.cards[j], self.cards[i]
    end
end

function Deck:draw()
    return table.remove(self.cards)
end

function Deck:remaining()
    local copy = {}
    for i, c in ipairs(self.cards) do copy[i] = c end
    return copy
end

function Deck:removeCard(card)
    for i, c in ipairs(self.cards) do
        if c == card then
            table.remove(self.cards, i)
            return true
        end
    end
    return false
end

function Deck:size()
    return #self.cards
end

return Deck
