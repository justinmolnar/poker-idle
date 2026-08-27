-- data/hand_structure.lua
--
-- The SHAPE of a hand, per outcome tier: how often it reaches showdown
-- rather than folding out, and (when it folds out) which street it dies
-- on. Read by models/HandScript's planner.
--
-- This is the structural half of pace. pace_mult scales a hand's clock
-- uniformly; these change how many events a hand HAS. A mode whose
-- small pots almost always fold out preflop resolves in a handful of
-- beats no matter what the clock says — which is what makes a fast mode
-- feel fast rather than merely sped-up.
--
-- Shape mirrors data/poker_event_timings.lua and data/pot_tiers.lua:
--   default          — the baseline, all four tiers
--   by_gtype[id]     — partial override, merged over default PER TIER
--
-- showdown_chance_by_tier
--   Odds the hand reaches showdown. Tiny pots almost never do (real
--   poker: small pots are blind-steals and c-bet fold-outs). Big pots
--   nearly always reveal cards.
--
-- foldout_end_street_weights
--   For fold-outs, weights over { preflop, flop, turn, river } for which
--   street the hand ends on. Smaller tiers bail preflop overwhelmingly;
--   bigger tiers run deeper before someone folds.
--
-- Pure data; no logic.

return {
    default = {
        showdown_chance_by_tier = {
            small   = 0.00,
            medium  = 0.50,
            large   = 0.85,
            jackpot = 1.00,
        },
        foldout_end_street_weights = {
            -- weights match { preflop, flop, turn, river }
            small   = { 80, 17, 2, 1 },
            medium  = { 5, 35, 45, 15 },
            large   = { 0, 10, 35, 55 },
            jackpot = { 0, 5, 25, 70 },
        },
    },

    by_gtype = {
        -- Filled by the identity retune (phase E), from sim/gtype_ev.lua.
    },
}
