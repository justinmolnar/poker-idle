-- data/mtt_finish_dist.lua
--
-- Per-tournament finish-position distribution for 8-max KO mode.
--
-- Used by models/MttSession:planRun. At the click-DEAL moment of a fresh
-- tournament, the session lerps `naked` toward `capped` by the player's
-- EFFECTIVE PER-HAND WIN CHANCE at that stake (everything the cash table
-- uses: the stake, the game type, upgrades, decks, catalog) over `wc_ref`,
-- and samples one of positions 1..8. It used to lerp by the fill ratio
-- alone, which ignored the stake entirely: every tier at full levels was
-- the same 30% to win outright, and T6 was as easy as T1.
--
--   • naked  — the Run-0 / no-upgrades baseline. Mass concentrated on
--              4th-8th, so a fresh player busts out of most tournaments
--              before cashing.
--   • capped — the fully-upgraded ceiling. Mass concentrated on 1st-3rd
--              with a real shot at the top.
--
-- Weights need not normalize to 1 — they're normalized at sample time.
-- Tune to taste: lower the [1] / [2] / [3] weights in `capped` to make
-- cashing harder even at full fill; raise the [1] in `capped` to give
-- top-finish thrills more often.
--
-- Pure data — no logic.

return {
    -- The per-hand win chance at which `capped` is fully deserved: T1's
    -- ceiling. A stake whose ceiling is 25% (T6) reaches a third of the
    -- way there at its own max, and gets the rest from stronger upgrades.
    wc_ref = 0.75,

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
    capped = {
        [1] = 0.30,
        [2] = 0.20,
        [3] = 0.15,
        [4] = 0.12,
        [5] = 0.08,
        [6] = 0.06,
        [7] = 0.05,
        [8] = 0.04,
    },
}
