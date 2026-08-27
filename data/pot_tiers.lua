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
-- only its jackpot cell.
--
-- mtt is pinned to an explicit empty block ON PURPOSE: tournament plans
-- are SERIALIZED (GameState.active_table_mtt_plans) and their bust
-- schedules project seat stacks via tierAvgBB — shifting mtt bands
-- invalidates every saved mid-tournament plan. Never give mtt bands
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
            jackpot = { lo = 80.0, hi = 120.0 },
        },
        loss = {
            small   = { lo = 1.0,  hi = 3.0   },
            medium  = { lo = 5.0,  hi = 15.0  },
            large   = { lo = 18.0, hi = 45.0  },
            jackpot = { lo = 80.0, hi = 120.0 },
        },
    },
    by_gtype = {
        mtt = {},   -- frozen on default; see header
        -- six_max / zoom win-side overrides land with the identity
        -- retune (phase E of the chunk-1 plan), picked by sim/gtype_ev.
    },
}
