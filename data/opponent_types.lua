-- data/opponent_types.lua
--
-- Opponent classification: every seated opponent is a (skill, playstyle)
-- compound. Skill is a pure difficulty knob — higher skill = harder, period,
-- no upgrade exploits a particular skill bracket. Playstyle is lateral —
-- some styles are exploitable (fish, nit), others tougher (tag, lag), and
-- catalog/run upgrades target playstyles via vs_<style>_mult effect kinds.
--
-- Per hand resolution:
--   raw_wr = (BASE_WR + skills[s].penalty + playstyles[p].modifier) * ctx[upgrade_kind]
--
-- Distributions over both axes live on each entry in data/stakes.lua. Pure
-- data — no logic in this file.

return {

    -- ── Skill levels (additive penalty; targetable via per-skill ctx_key) ──
    -- ctx_key is the field on the player's effects ctx that softens this
    -- skill tier's penalty. Catalog upgrades like Calm Hands write
    -- ctx.vs_pro_penalty as a multiplier (e.g. 0.67 = 33% softer); the
    -- win-rate fold reads ctx[skill_data.ctx_key] and multiplies the raw
    -- penalty by it. No `if opp.skill == "pro"` chain — each skill is data.
    skills = {
        rec = {
            name    = "Recreational",
            short   = "Rec",
            penalty = 0.00,
            ctx_key = "vs_rec_penalty",
            blurb   = "Plays for fun, no theory study, makes mistakes constantly.",
        },
        reg = {
            name    = "Regular",
            short   = "Reg",
            penalty = -0.04,
            ctx_key = "vs_reg_penalty",
            blurb   = "Knows the basics, plays solid most of the time.",
        },
        grind = {
            name    = "Grinder",
            short   = "Grind",
            penalty = -0.10,
            ctx_key = "vs_grind_penalty",
            blurb   = "Volume-focused regular at this stake. Very hard to push around.",
        },
        pro = {
            name    = "Pro",
            short   = "Pro",
            penalty = -0.20,
            ctx_key = "vs_pro_penalty",
            blurb   = "Studies the game, exploits weaker players surgically.",
        },
    },

    -- ── Playstyles (lateral modifier; targeted by vs_<style>_mult) ───────
    -- ctx_key is the field name the EffectsRegistry writes to when an
    -- upgrade_kind effect fires — Table:_winRate looks up ctx[ctx_key] to
    -- pick up the multiplier.
    playstyles = {
        fish = {
            name         = "Fish",
            modifier     =  0.05,
            upgrade_kind = "vs_fish_mult",
            ctx_key      = "vs_fish",
            blurb        = "Loose-passive. Calls too much, folds too rarely. Bleeds chips.",
        },
        tag = {
            name         = "TAG",
            modifier     = -0.04,
            upgrade_kind = "vs_tag_mult",
            ctx_key      = "vs_tag",
            blurb        = "Tight-aggressive. Picks spots, applies pressure. Solid.",
        },
        lag = {
            name         = "LAG",
            modifier     = -0.02,
            upgrade_kind = "vs_lag_mult",
            ctx_key      = "vs_lag",
            blurb        = "Loose-aggressive. Hard to read, plays many hands.",
        },
        nit = {
            name         = "Nit",
            modifier     =  0.02,
            upgrade_kind = "vs_nit_mult",
            ctx_key      = "vs_nit",
            blurb        = "Ultra-tight. Predictable. Easy to fold to but hard to extract from.",
        },
    },

    -- Player baseline edge before skill+playstyle adjustments.
    BASE_WIN_RATE = 0.55,
}
