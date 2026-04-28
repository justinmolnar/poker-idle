-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake:
--
--   • seats              — number of opponents at the felt
--   • pot_mult           — multiplier on rolled pot/bet sizes per hand
--   • pace_mult          — multiplier on the per-hand cinematic. >1 = faster.
--                          The base timeline (PHASE_*_END constants in
--                          models/Table.lua) is what plays at pace_mult=1;
--                          6-max is intentionally below 1 to anchor the
--                          baseline so multi-tabling is the way to scale
--                          throughput, not single-table click-spam.
--   • win_rate_offset    — flat additive offset to win-rate before the
--                          stake/skill/playstyle math. HU is meaningfully
--                          negative — opponents are too strong at the bottom.
--   • skill_modifier     — multiplicative offsets into stake.skill_distribution
--                          (then renormalized). nil = use stake's as-is.
--   • playstyle_modifier — same shape, but for stake.playstyle_distribution.
--   • rerolls_opponents  — true for Zoom; opponents reroll per hand and
--                          their revealed-skill / revealed-style flags reset
--                          (you never learn a Zoom pool).
--
-- Pure data — no logic.

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pot_mult = 1.0,
        pace_mult = 0.5,        -- baseline slow — 4.4s/hand. The pace that anchors all multi-tabling math.
        win_rate_offset = 0.00,
        skill_modifier     = nil,
        playstyle_modifier = nil,
        rerolls_opponents  = false,
    },
    {
        id   = "nine_max",
        name = "9-max",
        short = "9-MAX",
        seats = 8,
        pot_mult = 1.40,        -- bigger multi-way pots
        pace_mult = 0.30,       -- meaningfully slower than 6-max (~7.3s/hand). Mirrors Zoom's ~3s-faster delta on the slow side — nine seats means more decisions per hand and slower runouts.
        win_rate_offset = -0.03,-- modestly harder to win — more multi-way variance, harder reads
        skill_modifier     = nil,
        playstyle_modifier = { fish = 0.7, tag = 1.3, lag = 0.6, nit = 1.6 },  -- distinctly tighter
        rerolls_opponents  = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pot_mult = 0.70,        -- smaller pots — less variance per hand
        pace_mult = 1.0,        -- fast — 2.2s/hand, no idle seats means quick play
        win_rate_offset = -0.15,-- significantly harder — opponents skew hugely pro
        -- HU pool is brutally pro-heavy. Recreationals don't sit at HU.
        skill_modifier     = { rec = 0.1, reg = 0.3, grind = 2.5, pro = 5.0 },
        playstyle_modifier = nil,
        rerolls_opponents  = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pot_mult = 0.65,        -- noticeably smaller pots — less playout, more pre-flop folds
        pace_mult = 1.4,        -- very fast — ~1.57s/hand
        win_rate_offset = 0.02, -- slight tailwind — recreational pool is genuinely softer
        -- Recreational + fishy pool. Easier than 6-max at the same stake.
        skill_modifier     = { rec = 1.5, reg = 1.0, grind = 0.6, pro = 0.3 },
        playstyle_modifier = { fish = 1.4, tag = 0.7, lag = 0.6, nit = 1.2 },
        rerolls_opponents  = true,  -- new opponents every hand — you can never read the pool
    },

}
