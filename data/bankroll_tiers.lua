-- data/bankroll_tiers.lua
--
-- Bankroll-tier multiplier ladder for the shove-rate formula. Lookup is
-- "highest row whose threshold ≤ current bankroll." T1..T6 thresholds
-- match the existing data/stakes.lua buy-ins (1:1 with the stakes the
-- player has unlocked the ability to sit at). T7+ extend the curve past
-- the stakes ladder so endgame grinding past $1M still pushes shove
-- rate upward.
--
-- The label is shown in the SHOVE breakdown tooltip — it's the player-
-- visible "where you are on the climb" badge, not just an internal id.
--
-- Pure data — no logic.

return {
    { threshold = 0,        mult = 1, label = "Sub-T1" },
    { threshold = 2,        mult = 1, label = "T1"     },
    { threshold = 25,       mult = 2, label = "T2"     },
    { threshold = 100,      mult = 3, label = "T3"     },
    { threshold = 1000,     mult = 4, label = "T4"     },
    { threshold = 10000,    mult = 5, label = "T5"     },
    { threshold = 100000,   mult = 6, label = "T6"     },
    { threshold = 1000000,  mult = 7, label = "T7"     },
    { threshold = 10000000, mult = 8, label = "T8"     },
}
