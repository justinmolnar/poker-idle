-- data/mtt_hand_count.lua
--
-- Per-finish-position hand-count ranges for 8-max KO tournaments.
-- Used by models/MttSession:planRun to pick total tournament length
-- after rolling finish_position. Uniform integer in [lo, hi].
--
-- Shape: top finishes run long (you survived deep, lots of dramatic
-- chip swings); early busts run short. Caps the worst-case length at
-- 15 and prevents 3-hand 1st-place flukes.
--
-- Pure data — no logic.

return {
    [1] = { lo = 11, hi = 15 },
    [2] = { lo = 10, hi = 14 },
    [3] = { lo =  9, hi = 13 },
    [4] = { lo =  7, hi = 11 },
    [5] = { lo =  6, hi = 10 },
    [6] = { lo =  5, hi =  8 },
    [7] = { lo =  4, hi =  7 },
    [8] = { lo =  3, hi =  5 },
}
