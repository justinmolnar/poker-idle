-- data/pot_tiers.lua
--
-- Pot-tier magnitude bands (in big-blinds; rolled uniformly within range).
-- Single source of truth for the four tiers used by the outcome model.
--
-- THE SEATS RULE: the most a hand can pay is one 100bb stack from each
-- opponent matching your all-in — max win = seats × stack. WIN bands may
-- scale with a game type's opponent count; LOSS bands do not (you can
-- only ever lose your own stack). models/Table.lua enforces the same
-- rule as a hard cap (OutcomeMath.maxWinBB), so a band's `hi` above
-- seats × 100 clips.
--
-- Resolution (models/outcome_math.lua tierBand):
--   by_gtype[gtype_id][side][tier]  →  default[side][tier]
-- Partial overrides fall through PER TIER, so a gtype block may override
-- only its stack cell.
--
-- ko is pinned to an explicit empty block ON PURPOSE: tournament plans
-- are SERIALIZED (GameState.active_table_ko_plans) and their bust
-- schedules project seat stacks via tierAvgBB — shifting ko bands
-- invalidates every saved mid-tournament plan. Never give ko bands
-- without a save migration.
--
-- Pure data; no logic. Consumers go through OutcomeMath.rollTierMagnitude
-- / tierAvgBB; nothing else reads this file directly.

return {
    default = {
        win = {
            small   = { lo = 1.0,  hi = 3.0   },
            medium  = { lo = 5.0,  hi = 15.0  },
            large   = { lo = 18.0, hi = 45.0  },
            stack = { lo = 80.0, hi = 120.0 },
        },
        loss = {
            small   = { lo = 1.0,  hi = 3.0   },
            medium  = { lo = 5.0,  hi = 15.0  },
            large   = { lo = 18.0, hi = 45.0  },
            stack = { lo = 80.0, hi = 120.0 },
        },
    },
    by_gtype = {
        ko = {},   -- frozen on default; see header

        -- 6-MAX — the tank. Five opponents, so five stacks can go in:
        -- the biggest pots in the game, and the reason to sit a slow
        -- table. Loss side stays default (one stack is all you can lose).
        six_max = {
            win = {
                small   = { lo = 2.0,   hi = 6.0   },
                medium  = { lo = 12.0,  hi = 35.0  },
                large   = { lo = 70.0,  hi = 180.0 },
                stack = { lo = 380.0, hi = 500.0 },   -- 5 stacks = the cap
            },
        },

        -- ZOOM — the drip. Same five-seat ceiling as 6-max (it is the
        -- same table), but the mass sits in tiny pots and the stack is
        -- a once-a-session event, so what you actually feel is volume.
        zoom = {
            win = {
                small   = { lo = 1.0,   hi = 3.0   },
                medium  = { lo = 4.0,   hi = 12.0  },
                large   = { lo = 25.0,  hi = 60.0  },
                stack = { lo = 300.0, hi = 500.0 },
            },
        },

        -- HEADS-UP — the duel. One opponent means one stack: its stack
        -- sits just under the 100bb cap rather than being clipped by it.
        -- Small ceiling, but it reaches that ceiling constantly, which is
        -- what makes it the {chip} engine.
        hu = {
            win = {
                small   = { lo = 3.0,  hi = 8.0   },
                medium  = { lo = 15.0, hi = 40.0  },
                large   = { lo = 45.0, hi = 85.0  },
                stack = { lo = 70.0, hi = 100.0 },
            },
        },
    },
}
