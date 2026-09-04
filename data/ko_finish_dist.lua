-- data/ko_finish_dist.lua
--
-- Per-tournament finish-position distribution for 8-max KO mode.
--
-- Used by models/KoSession:planRun (the pre-roll) and mirrored by
-- OutcomeMath.evStats (the readout). At the click-DEAL moment of a fresh
-- tournament, the player's EFFECTIVE PER-HAND WIN CHANCE at that stake
-- (everything the cash table uses: the stake, the game type, upgrades,
-- decks, catalog) is measured against the stake's `wc_ref` bar:
--
--     fill = win_chance / wc_ref[stake]        -- NOT clamped at 1
--     t    = fill ^ curve                      -- convex: slow start, then opens up
--     w    = naked + (capped - naked) * t      -- per position, floored at 0
--
-- and one of positions 1..8 is sampled from w.
--
-- ─── WHY A BAR PER STAKE, AND NO CEILING ───────────────────────────────
-- The old model lerped toward a `capped` table whose 1st place was 0.30 and
-- clamped the fill at 1, so every tier converged on the same 30% to win once
-- a few levels were bought, and nothing could push past it. Now the bar
-- rises with the tier (a tournament at T6 needs a T6-worthy win chance to
-- feel like the T1 one did), `capped[1]` is 1.0, and the fill is allowed
-- past 1: with enough power, and with auto-win perks (which add straight
-- onto t in the planner), a tournament can be made a near-lock. The curve
-- exponent keeps the low end honest: half the bar is a quarter of the way.
--
-- Reference points at curve 2 (naked / capped upgrades / at the 0.95 WC cap):
--   T1  23% / 42% / 57%      T3  3% / 20% / 45%      T6  2% / 5% / 33%
--
-- Weights need not normalize to 1 — they're normalized at sample time.
--
-- Pure data — no logic.

return {
    -- The win chance that reads as "fill 1.0" at each stake, 1-based in
    -- data/stakes.lua order (T1 … T9, Ultra). Above 1 means even the WC
    -- cap alone does not fully fill it.
    wc_ref = { 1.00, 1.10, 1.20, 1.30, 1.40, 1.50, 1.60, 1.70, 1.80, 2.00 },
    wc_ref_default = 1.60,   -- any stake past the list

    -- Exponent on the fill. 1 = the old linear blend; 2 = convex.
    curve = 2,

    -- The Run-0 / no-upgrades baseline. Mass concentrated on 4th-8th, so a
    -- fresh player busts out of most tournaments before cashing.
    naked = {
        [1] = 0.02,
        [2] = 0.04,
        [3] = 0.06,
        [4] = 0.10,
        [5] = 0.15,
        [6] = 0.18,
        [7] = 0.20,
        [8] = 0.25,
    },
    -- Where fill 1.0 lands. 1st place carries most of the mass; the tail
    -- is what a fully-filled player still occasionally hits. Past fill 1
    -- the tail extrapolates below 0 and is floored, so the title share
    -- keeps climbing toward certainty.
    capped = {
        [1] = 1.00,
        [2] = 0.30,
        [3] = 0.15,
        [4] = 0.08,
        [5] = 0.05,
        [6] = 0.03,
        [7] = 0.02,
        [8] = 0.02,
    },
}
