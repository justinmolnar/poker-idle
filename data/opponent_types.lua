-- data/opponent_types.lua
--
-- Opponent classification: every seated opponent is a (skill, playstyle)
-- compound. Skill is the dominant axis on the 8-cell outcome grid; playstyle
-- is a small additive nudge layered on top.
--
-- The 8 cells are arranged: 4 pot tiers (Tiny / Small / Medium / Jackpot)
-- × 2 columns (Lose / Win). Each cell holds a probability; columns sum
-- to 1.0. Per hand, models/Table.lua:_buildGrid takes the per-skill grid,
-- applies the style modifier, applies the game-type grid_modifier, applies
-- ctx.grid_shifts (run upgrades + catalog perks), and renormalizes — then
-- :_sampleGrid picks one cell.
--
-- Magnitudes per tier (in big-blinds; rolled uniformly within the range):
--   Tiny    1.0 –  3.0
--   Small   5.0 – 15.0
--   Medium  18.0 – 45.0
--   Jackpot 80.0 – 120.0      (≈ full buy-in — stack-off win or loss)
--
-- The cell magnitudes live in models/Table.lua so the data here stays pure
-- distribution. Pure data; no logic.

return {

    -- ── Pot-tier magnitude bands (used by Table:_sampleGrid). Listed here
    --    so the tooltip / EV math has a single source of truth alongside
    --    the cell distributions.
    tier_bb_ranges = {
        tiny    = { lo = 1.0,  hi = 3.0   },
        small   = { lo = 5.0,  hi = 15.0  },
        medium  = { lo = 18.0, hi = 45.0  },
        jackpot = { lo = 80.0, hi = 120.0 },
    },

    -- ── Per-skill base grids ────────────────────────────────────────────
    -- Probability mass per cell, by opponent skill. Each grid sums to 1.0.
    -- The shape is brutal-by-default at the top: a naked player can grind
    -- rec/reg, but grind/pro are essentially unwinnable until upgrades stack.
    --
    --   vs rec   ≈ 70% Win — soft pool, strongly +EV
    --   vs reg   ≈ 30% Win — net -EV; you bleed without reads
    --   vs grind ≈  5% Win — strongly -EV; needs upgrades to break even
    --   vs pro   ≈  1% Win — catastrophic; needs Calm Hands + stacked perks
    --
    -- Pro's L column also leans heavier on Medium / Jackpot tiers, modeling
    -- "they stack you when they have it" — losses against pros aren't just
    -- frequent, they're large. Sharper Reads etc. shift mass back into the
    -- W column via lose_to_win shifts.
    --
    -- Field naming: tl = tiny lose, tw = tiny win, etc.
    skill_grids = {
        rec = {
            tl = 0.15, sl = 0.08,  ml = 0.04,  jl = 0.03,
            tw = 0.30, sw = 0.25,  mw = 0.10,  jw = 0.05,
        },
        reg = {
            tl = 0.30, sl = 0.20,  ml = 0.13,  jl = 0.07,
            tw = 0.18, sw = 0.06,  mw = 0.03,  jw = 0.03,
        },
        grind = {
            tl = 0.30, sl = 0.30,  ml = 0.20,  jl = 0.15,
            tw = 0.020, sw = 0.015, mw = 0.005, jw = 0.010,
        },
        pro = {
            tl = 0.30, sl = 0.25,  ml = 0.25,  jl = 0.19,
            tw = 0.005, sw = 0.002, mw = 0.001, jw = 0.002,
        },
    },

    -- ── Skill metadata (display name, shortcut, blurb, ctx_key) ─────────
    -- ctx_key is the field on the player's effects ctx that *targets* this
    -- skill tier with grid-shift effects (e.g. Calm Hands shifts mass on
    -- pro cells specifically). The applicator reads opp.skill, looks up the
    -- skill's ctx_key, then checks for matching shifts in ctx.grid_shifts.
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
        grind = {
            name    = "Grinder",
            short   = "Grind",
            ctx_key = "vs_grind",
            blurb   = "Volume-focused regular at this stake. Very hard to push around.",
        },
        pro = {
            name    = "Pro",
            short   = "Pro",
            ctx_key = "vs_pro",
            blurb   = "Studies the game, exploits weaker players surgically.",
        },
    },

    -- ── Per-style additive grid shifts ──────────────────────────────────
    -- Applied after the skill grid is selected, before any ctx shifts.
    -- Cells listed get added to (negative cells clamp at 0), then the
    -- whole grid renormalizes to sum=1.
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

    -- ── Playstyle metadata (display + blurbs) ───────────────────────────
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
