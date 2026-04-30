-- data/mtt_payouts.lua
--
-- MTT payout multiplier table. Indexed by ctx.mtt_payout_boost (0/1/2,
-- driven by the Plastic Trophy / Engraved Plaque catalog perks via
-- max-stacking — see models/poker_effects.lua) and by hands cleared.
--
-- Cleared count below 6 = no payout (lost buy-in). 6/7/8 cleared each
-- pay a multiplier × the table's stake buy-in. The 8-clear cap stays
-- pinned at 20× across all tiers — the perks raise the floor (the 6
-- and 7 consolation cashes), not the ceiling.
--
-- Pure data — no logic.

return {
    [0] = { [6] = 3, [7] = 6,  [8] = 20 },   -- baseline (no perks)
    [1] = { [6] = 4, [7] = 8,  [8] = 20 },   -- with Plastic Trophy
    [2] = { [6] = 5, [7] = 10, [8] = 20 },   -- with Engraved Plaque
}
