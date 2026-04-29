-- data/base_grid.lua
--
-- The universal 8-cell outcome grid — the starting point before any
-- per-stake / per-gtype / per-skill / per-style / ctx shifts are layered
-- on. Tuned to be symmetric (~50% Win, EV ≈ 0 bb/hand) so that an unmodified
-- s001 6-max hand against an average opponent reads as a coin flip; every
-- stake / opponent / upgrade interaction is a deviation from this baseline.
--
-- Cells:
--   tl/sl/ml/jl  — Tiny / Small / Medium / Jackpot Lose
--   tw/sw/mw/jw  — Tiny / Small / Medium / Jackpot Win
-- Sums to 1.0.
--
-- Pipeline (models/Table.lua:_buildGrid):
--   1. Copy this grid.
--   2. Apply stake.difficulty (list of grid_shifts; harder stakes shift
--      mass W → L via win_to_lose).
--   3. Apply gtype.grid_modifier (additive per-tier shift, split L/W).
--   4. Apply OpTypes.skill_shifts[opp.skill] (single shift; rec slightly
--      easier, pro slightly harder, reg neutral).
--   5. Apply OpTypes.style_shifts[opp.style] (additive cell shifts).
--   6. Apply ctx.grid_shifts — targeted (matched on opp tags / gtype) and
--      general (run upgrades, catalog perks).
--   7. Clamp negative cells to 0 and renormalize to sum=1.
--
-- Pure data; no logic.

return {
    tl = 0.20, sl = 0.15, ml = 0.14, jl = 0.01,
    tw = 0.20, sw = 0.15, mw = 0.14, jw = 0.01,
}
