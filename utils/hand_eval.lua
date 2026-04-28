-- utils/hand_eval.lua
--
-- Hold'em hand evaluator. Stub for now — the shove prototype is the first
-- thing that needs this and will fill in the implementation. Per
-- docs/what-to-pull.md: pull a small Lua hold'em evaluator (~150 lines) or
-- write one; 5-card eval is straightforward.
--
-- Expected API (when implemented):
--   HandEval.rank(cards)         → integer rank (higher = better)
--   HandEval.compare(a, b)       → -1 | 0 | 1
--   HandEval.bestFiveOfSeven(c)  → 5 cards from 7 (Hold'em board+hole)

local HandEval = {}

function HandEval.rank(_)
    error("HandEval.rank not implemented — see utils/hand_eval.lua")
end

function HandEval.compare(_, _)
    error("HandEval.compare not implemented — see utils/hand_eval.lua")
end

function HandEval.bestFiveOfSeven(_)
    error("HandEval.bestFiveOfSeven not implemented — see utils/hand_eval.lua")
end

return HandEval
