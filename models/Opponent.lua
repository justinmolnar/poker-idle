-- models/Opponent.lua
--
-- One seated opponent at a table. Pure data — visual identity (name) and
-- a per-table stack value. Per-hand state (cards, pot, etc.) lives on the
-- Table model.
--
-- name   — display string drawn from data/opponent_names
-- stack  — current chip count ($). Static for the slice (= buy-in at the
--          stake the table sits at). Polish later: stacks fluctuate as
--          hands resolve.

local Opponent = {}
Opponent.__index = Opponent

function Opponent:new(name, stack)
    return setmetatable({
        name  = name  or "Unnamed",
        stack = stack or 0,
    }, Opponent)
end

return Opponent
