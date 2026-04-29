-- data/opponent_types.lua
--
-- Opponent tags + per-tag grid shifts. Every seated opponent is a
-- (skill, playstyle) compound. Under the post-refactor model, the
-- *base difficulty* of any (stake, gtype) combination is set by the
-- per-stake difficulty shift (see data/stakes.lua) and the per-gtype
-- modifier (see data/game_types.lua), NOT by the opponent skills.
-- Opponent tags are texture: a small modulation around the base, plus
-- the targets that upgrades (Calm Hands, Patience, etc.) latch onto.
--
-- Skill tiers (3): rec / reg / pro.
--   rec applies a small "lose_to_win" shift  → slightly easier
--   reg is the neutral baseline              → no shift
--   pro applies a small "win_to_lose" shift  → slightly harder
-- These are intentionally small (~5%) so the per-stake curve does the
-- heavy lifting; a fresh-save player at s001 hits ~50/50 regardless of
-- whether the opponent is rec or pro, then watches the curve drop fast
-- as they climb stakes.
--
-- Playstyles (4): fish / tag / lag / nit.
--   No built-in EV difference between styles — they're flavor + the
--   targets for style-specific upgrades (Patience vs fish/nit). Subtle
--   additive cell shifts redistribute mass across tiers (variance shape)
--   without moving the W/L balance much.
--
-- Default distributions are uniform across all stakes — the opponent
-- pool you face is the same at $0.02 and $1000. The stake's difficulty
-- shift is what changes; recs aren't artificially more common at low
-- stakes because that would re-implement difficulty through the back
-- door (which is exactly what we just refactored away from).
--
-- ─── Pot-tier magnitude bands ──────────────────────────────────────
-- Magnitudes per tier (in big-blinds; rolled uniformly within range):
--   Tiny    1.0 –  3.0
--   Small   5.0 – 15.0
--   Medium  18.0 – 45.0
--   Jackpot 80.0 – 120.0      (≈ full buy-in — stack-off win or loss)
--
-- Pure data; no logic.

return {

    -- ── Pot-tier magnitude bands (used by Table:_sampleGrid). Listed
    --    here so EV math has a single source of truth alongside the
    --    grid distributions in data/base_grid.lua.
    tier_bb_ranges = {
        tiny    = { lo = 1.0,  hi = 3.0   },
        small   = { lo = 5.0,  hi = 15.0  },
        medium  = { lo = 18.0, hi = 45.0  },
        jackpot = { lo = 80.0, hi = 120.0 },
    },

    -- ── Default opponent distributions ──────────────────────────────
    -- Uniform across all stakes / game types. Read by Table:fillOpponents
    -- (per-seat sampling) and Table:tableGrid (gauge expectation math).
    -- Numbers are weights, not probabilities; sampleDist normalizes.
    default_distributions = {
        skills     = { rec = 1, reg = 1, pro = 1 },
        playstyles = { fish = 1, tag = 1, lag = 1, nit = 1 },
    },

    -- ── Per-skill shifts ────────────────────────────────────────────
    -- A single grid_shift descriptor per skill, applied in the buildGrid
    -- pipeline after stake/gtype but before ctx shifts. nil = no shift.
    -- Magnitudes intentionally small so skill is texture, not the curve.
    skill_shifts = {
        rec = { op = "lose_to_win", amount = 0.05 },
        reg = nil,
        pro = { op = "win_to_lose", amount = 0.05 },
    },

    -- ── Skill metadata (display name, shortcut, blurb, ctx_key) ─────
    -- ctx_key is the field name on a player's effects ctx that *targets*
    -- this skill tier with grid-shift effects (e.g. Calm Hands shifts
    -- mass on pro cells specifically). The applicator reads opp.skill,
    -- looks up the skill's ctx_key, then checks for matching shifts.
    skills = {
        rec = {
            name    = "Recreational",
            short   = "Rec",
            ctx_key = "vs_rec",
            blurb   = "Plays for fun, no theory study, makes mistakes constantly.",
        },
        reg = {
            name    = "Regular",
            short   = "Reg",
            ctx_key = "vs_reg",
            blurb   = "Knows the basics, plays solid most of the time.",
        },
        pro = {
            name    = "Pro",
            short   = "Pro",
            ctx_key = "vs_pro",
            blurb   = "Studies the game, exploits weaker players surgically.",
        },
    },

    -- ── Per-style additive grid shifts ──────────────────────────────
    -- Applied as additive cell deltas after the skill shift. Cells listed
    -- get added to (negative cells clamp at 0); the whole grid renormalizes
    -- to sum=1 at the end of buildGrid.
    --
    --   fish — pays you off (mass into MW + JW from TL + TW)
    --   tag  — neutral (no shift)
    --   lag  — variance (mass into JW + JL from TW + TL)
    --   nit  — tight (mass into TW + TL from MW + JW)
    style_shifts = {
        fish = { mw =  0.04, jw =  0.04, tl = -0.04, tw = -0.04 },
        tag  = nil,
        lag  = { jw =  0.03, jl =  0.03, tw = -0.03, tl = -0.03 },
        nit  = { tw =  0.03, tl =  0.03, jw = -0.03, mw = -0.03 },
    },

    -- ── Playstyle metadata (display + blurbs) ───────────────────────
    playstyles = {
        fish = {
            name  = "Fish",
            blurb = "Loose-passive. Calls too much, folds too rarely. Pays off your value bets.",
        },
        tag = {
            name  = "TAG",
            blurb = "Tight-aggressive. Picks spots, applies pressure. Solid baseline.",
        },
        lag = {
            name  = "LAG",
            blurb = "Loose-aggressive. Hard to read, plays many hands. Big swings both ways.",
        },
        nit = {
            name  = "Nit",
            blurb = "Ultra-tight. Predictable. Easy to fold to but hard to extract from.",
        },
    },
}
