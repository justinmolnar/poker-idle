-- data/mtt_payouts.lua
--
-- MTT payout multiplier table. Indexed by ctx.mtt_payout_boost (0/1/2,
-- driven by the Plastic Trophy / Engraved Plaque catalog perks via
-- max-stacking — see models/poker_effects.lua) and by finish position
-- mapped to a key (1st = 8, 2nd = 7, 3rd = 6; 4th and below = no
-- payout, lost buy-in). Each key pays a multiplier × the table's stake
-- buy-in. The 8 key stays pinned at 20× across the base tiers — the
-- perks raise the floor (the consolation cashes), not the ceiling.
--
-- Pure data — no logic.

return {
    [0] = { [6] = 3, [7] = 6,  [8] = 20 },   -- baseline (no perks)
    [1] = { [6] = 4, [7] = 8,  [8] = 20 },   -- with Plastic Trophy
    [2] = { [6] = 5, [7] = 10, [8] = 20 },
    -- Corrupted Plastic Trophy / Engraved Plaque.
    [3] = { [6] = 20, [7] = 40,  [8] = 80 },
    [4] = { [6] = 40, [7] = 80,  [8] = 160 },   -- with Engraved Plaque
}
