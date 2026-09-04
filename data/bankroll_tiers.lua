-- data/bankroll_tiers.lua
--
-- Bankroll-tier multiplier ladder for the shove-rate formula. Lookup is
-- "highest row whose threshold ≤ current bankroll." Thresholds match the
-- data/stakes.lua buy-ins (1:1 with the stakes the player has unlocked
-- the ability to sit at); change the ladder there and mirror it here.
--
-- The label is shown in the SHOVE breakdown tooltip — it's the player-
-- visible "where you are on the climb" badge, not just an internal id.
--
-- Pure data — no logic.

return {
    { threshold = 0,        mult = 1, label = "Sub-T1" },
    { threshold = 2,        mult = 1, label = "T1"     },
    { threshold = 10,       mult = 2, label = "T2"     },
    { threshold = 100,      mult = 3, label = "T3"     },
    { threshold = 1e4,      mult = 4, label = "T4"     },
    { threshold = 1e6,      mult = 5, label = "T5"     },
    { threshold = 1e8,      mult = 6, label = "T6"     },
    { threshold = 1e11,     mult = 7, label = "T7"     },
    { threshold = 1e14,     mult = 8, label = "T8"     },
}
