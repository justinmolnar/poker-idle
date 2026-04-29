-- data/opponent_types.lua
--
-- Opponent tags + per-tag outcome-model modifiers. Every seated opponent is
-- a (skill, playstyle) compound. The base difficulty of any (stake, gtype)
-- combination is set by the per-stake outcome config (data/stakes.lua) and
-- the per-gtype dist shape (data/game_types.lua), NOT by opponent skills.
-- Opponent tags are texture: a small modulation around the base, plus the
-- targets that upgrades (Iron Nerves, Patience, etc.) latch onto.
--
-- Skill tiers (3): rec / reg / pro.
--   rec — small additive bump on win_chance (slightly easier)
--   reg — neutral
--   pro — small additive penalty on win_chance (slightly harder)
-- Magnitudes are intentionally tiny (~5pp) so the per-stake curve does the
-- heavy lifting.
--
-- Playstyles (4): fish / tag / lag / nit.
--   No built-in EV difference — they reshape the per-tier distributions
--   (variance shape) without moving win_chance. Targets for style-specific
--   upgrades (Patience vs fish/nit) latch onto these tags.
--
-- Default distributions are uniform across all stakes — the opponent pool
-- you face is the same at $0.02 and $1000. The stake's own win_chance /
-- dist values are what change; recs aren't artificially more common at low
-- stakes because that would re-implement difficulty through the back door.
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

    -- ── Pot-tier magnitude bands (used by Table:rollTierMagnitude). Listed
    --    here so EV math has a single source of truth alongside the
    --    per-stake distributions in data/stakes.lua.
    tier_bb_ranges = {
        tiny    = { lo = 1.0,  hi = 3.0   },
        small   = { lo = 5.0,  hi = 15.0  },
        medium  = { lo = 18.0, hi = 45.0  },
        jackpot = { lo = 80.0, hi = 120.0 },
    },

    -- ── Default opponent distributions ──────────────────────────────
    -- Uniform across all stakes / game types. Read by Table:fillOpponents
    -- (per-seat sampling) and Table:tableOutcome (gauge expectation math).
    -- Numbers are weights, not probabilities; sampleDist normalizes.
    default_distributions = {
        skills     = { rec = 1, reg = 1, pro = 1 },
        playstyles = { fish = 1, tag = 1, lag = 1, nit = 1 },
    },

    -- ── Per-skill win_chance deltas ─────────────────────────────────
    -- Additive on win_chance. Applied in step 2 of buildOutcome, before
    -- any ctx shifts. 0 = neutral.
    skill_shifts = {
        rec =  0.05,
        reg =  0,
        pro = -0.05,
    },

    -- ── Skill metadata (display name, shortcut, blurb, ctx_key) ─────
    -- ctx_key is the field name on a player's effects ctx that *targets*
    -- this skill tier with shifts (e.g. Calm Hands shifts win_chance only
    -- when opp.skill == "pro"). Catalog/run-upgrade descriptors carry the
    -- skill filter directly; ctx_key is documentation only.
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

    -- ── Per-style additive distribution shape ───────────────────────
    -- Applied as additive deltas on win_dist and/or loss_dist after the
    -- skill bump. Each entry may carry a `win_dist` and/or `loss_dist`
    -- field; both are 4-tier delta tables (cells listed get added; missing
    -- cells = 0). Negative cells clamp at 0 and each dist renormalizes to
    -- sum=1 at the end of buildOutcome.
    --
    --   fish — pays you off (mass into small/medium on win_dist only)
    --   tag  — neutral (no shift)
    --   lag  — variance both ways (jackpot mass on both dists)
    --   nit  — tight both ways (tiny mass on both dists)
    style_dist_shifts = {
        fish = {
            win_dist = { tiny = -0.04, small = 0.02, medium = 0.02 },
        },
        tag = nil,
        lag = {
            win_dist  = { tiny = -0.03, jackpot = 0.03 },
            loss_dist = { tiny = -0.03, jackpot = 0.03 },
        },
        nit = {
            win_dist  = { tiny = 0.03, jackpot = -0.03 },
            loss_dist = { tiny = 0.03, jackpot = -0.03 },
        },
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
