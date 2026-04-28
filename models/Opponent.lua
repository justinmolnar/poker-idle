-- models/Opponent.lua
--
-- One seated opponent at a table. Compound type: skill (additive penalty)
-- + playstyle (lateral modifier targeted by upgrades). Pure data + display
-- helpers; no per-hand state lives here — the Table model owns the deck,
-- community cards, pot, and per-hand math.
--
-- skill   — string key into data/opponent_types.skills      (e.g. "rec")
-- style   — string key into data/opponent_types.playstyles  (e.g. "fish")
-- name    — display string drawn from data/opponent_names
-- stack   — current chip count ($). Static for the slice (= buy-in at the
--           stake the table sits at). Polish later: stacks fluctuate as
--           hands resolve.

local Opponent = {}
Opponent.__index = Opponent

function Opponent:new(skill, style, name, stack)
    return setmetatable({
        skill = skill,
        style = style,
        name  = name  or "Unnamed",
        stack = stack or 0,
    }, Opponent)
end

return Opponent
