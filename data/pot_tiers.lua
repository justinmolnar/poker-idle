-- data/pot_tiers.lua
--
-- Pot-tier magnitude bands (in big-blinds; rolled uniformly within range).
-- Single source of truth for the four tiers used by the outcome model.
-- Lifted out of the old data/opponent_types.lua when the skill/style
-- system was ripped — this is all that survived.
--
-- Pure data; no logic. Consumers in models/Table.lua read PotTiers[tier]
-- directly.

return {
    tiny    = { lo = 1.0,  hi = 3.0   },
    small   = { lo = 5.0,  hi = 15.0  },
    medium  = { lo = 18.0, hi = 45.0  },
    jackpot = { lo = 80.0, hi = 120.0 },
}
