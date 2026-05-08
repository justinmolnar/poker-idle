-- data/decks.lua
--
-- Deck specs for the deck-system progression layer. Pure data — no
-- functions, no requires. Consumed by models/Decks.lua (level math +
-- guarded state mutation), models/deck_xp_rules.lua (XP rule dispatch),
-- models/deck_unlock_rules.lua (unlock dispatch), and views/DeckSelectModal.lua
-- (render).
--
-- Bonus contributions reuse already-registered effect kinds in
-- models/poker_effects (jackpot_mult, earnings_mult, loss_mult,
-- hand_pace_mult, focus_penalty_reduce_mult, win_chance_fill,
-- win_dist_shift). Each level applies the `effects` block once via
-- EffectsRegistry:applyN, exactly the way stacking run upgrades work.
--
-- XP rules dispatch through services/XpRuleRegistry; kind names live in
-- models/deck_xp_rules.lua. Unlock conditions dispatch through
-- services/UnlockRegistry; kind names live in models/deck_unlock_rules.lua.
--
-- Effects stack across all *unlocked* decks; only the *active* deck
-- accrues XP. Locked decks render as silhouettes in the modal until
-- their unlock condition is satisfied.
--
-- The `xp_curve` is the cumulative XP threshold to *enter* level N.
-- xp_curve[1] = 0 (start), xp_curve[2] = total XP needed to reach L2,
-- etc. Past xp_curve[max_level] the deck stops accruing.

local XP_CURVE_10 = { 0, 100, 300, 700, 1500, 3100, 6300, 12700, 25500, 51100 }

local Decks = {
    {
        id        = "standard",
        name      = "Standard",
        sprite    = "cards/backs/06-nature",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "money_won" },
        xp_action_text = "+1 XP per dollar won",
        effects   = {
            { kind = "earnings_mult", value = 1.025 },
        },
        bonus_text  = "+2.5% winnings per level",
        flavor_text = "The everyday deck. Quietly stacking.",
        -- No `unlock` field — default unlocked.
    },
    {
        id        = "low_stakes_hero",
        name      = "Low Stakes",
        sprite    = "cards/backs/05-nature",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "money_won", tier_max = 3 },
        xp_action_text = "+1 XP per dollar won at T1-T3",
        effects   = {
            { kind     = "win_dist_shift",
              tier_max = 3,
              shift    = { small = -0.005, jackpot = 0.005 } },
        },
        bonus_text  = "Reshapes T1-T3 wins toward jackpot",
        flavor_text = "Big fish in a small pond. Hits more often than it should.",
        unlock = {
            kind      = "lifetime_money_won",
            threshold = 200,
            text      = "Earn $200 cumulatively to unlock",
        },
    },
    {
        id        = "hustler",
        name      = "Hustler",
        sprite    = "cards/backs/05-acorns",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "+1 XP per hand played",
        effects   = {
            { kind = "hand_pace_mult", value = 1.05 },
        },
        bonus_text  = "+5% hand pace per level",
        flavor_text = "Faster shuffles, faster decisions, faster everything.",
        unlock = {
            kind      = "lifetime_hands_played",
            threshold = 2500,
            text      = "Play 2,500 hands cumulatively to unlock",
        },
    },
    {
        id        = "patterns",
        name      = "Patterns",
        sprite    = "cards/backs/04-patterns",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "money_lost" },
        xp_action_text = "+1 XP per dollar lost",
        effects   = {
            { kind = "loss_mult", value = 0.975 },
        },
        bonus_text  = "-2.5% loss magnitude per level",
        flavor_text = "Soak it. The pattern shows up after enough mistakes.",
        unlock = {
            kind      = "lifetime_money_lost",
            threshold = 500,
            text      = "Lose $500 cumulatively to unlock",
        },
    },
    {
        id        = "multi_tabler",
        name      = "Multi-Tabler",
        sprite    = "cards/backs/05-patterns",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "hands_played", min_tables = 4 },
        xp_action_text = "+1 XP per hand played with 4+ tables open",
        effects   = {
            { kind = "focus_penalty_reduce_mult", value = 0.925 },
        },
        bonus_text  = "Focus penalty x0.925 per level",
        flavor_text = "More tables, less suffering. Find the rhythm.",
        unlock = {
            kind      = "lifetime_hands_at_4plus_tables",
            threshold = 500,
            text      = "Play 500 hands with 4+ tables open to unlock",
        },
    },
    {
        id        = "fish",
        name      = "Fish",
        sprite    = "cards/backs/03-fish",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "jackpot_dollars" },
        xp_action_text = "+1 XP per dollar won on jackpots",
        effects   = {
            { kind = "jackpot_mult", value = 1.05 },
        },
        bonus_text  = "+5% jackpot payout per level",
        flavor_text = "Schools of fish like to lose. Be the lure.",
        unlock = {
            kind      = "lifetime_jackpot_count",
            threshold = 50,
            text      = "Win 50 jackpots cumulatively to unlock",
        },
    },
    {
        id        = "tournament_pro",
        name      = "MTT Pro",
        sprite    = "cards/backs/02-fish",
        max_level = 10,
        xp_curve  = XP_CURVE_10,
        xp_rule   = { kind = "hands_won", gtype = "mtt" },
        xp_action_text = "+1 XP per MTT hand won",
        effects   = {
            { kind = "auto_win_chance", gtype = "mtt", amount = 0.025 },
        },
        bonus_text  = "+2.5% auto-win on MTT hands per level",
        flavor_text = "Cash, cash, cash. Tournaments bend toward you.",
        unlock = {
            kind      = "lifetime_mtt_hands_won",
            threshold = 100,
            text      = "Win 100 MTT hands cumulatively to unlock",
        },
    },
}

return Decks
