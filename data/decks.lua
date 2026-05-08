-- data/decks.lua
--
-- Deck specs for the deck-system progression layer. Pure data — no
-- functions, no requires. Consumed by models/Decks.lua (level math +
-- guarded state mutation) and views/DeckSelectModal.lua (render).
--
-- Bonus contributions reuse already-registered effect kinds in
-- models/poker_effects (jackpot_mult, earnings_mult, loss_mult). Each
-- level applies the `effects` block once via EffectsRegistry:applyN,
-- exactly the way stacking run upgrades work.
--
-- XP rules dispatch through services/XpRuleRegistry; the kind names are
-- registered in models/deck_xp_rules.lua.
--
-- Effects stack across all *unlocked* decks in the player's collection;
-- only the *active* deck accrues XP. Swap point is the post-shove deck
-- select modal (see views/DeckSelectModal.lua).

local Decks = {
    {
        id        = "fish",
        name      = "Fish",
        sprite    = "cards/backs/03-fish",
        max_level = 5,
        -- Cumulative XP threshold to *enter* level N. xp_curve[1] = 0
        -- (start), xp_curve[2] = total XP needed to reach L2, etc.
        -- Past xp_curve[max_level] the deck stops accruing.
        xp_curve  = { 0, 100, 300, 700, 1500 },
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "+1 XP per hand played",
        effects   = {
            { kind = "jackpot_mult", value = 1.05 },
        },
        bonus_text  = "+5% jackpot payout per level",
        flavor_text = "Schools of fish like to lose. Be the lure.",
    },
    {
        id        = "acorns",
        name      = "Acorns",
        sprite    = "cards/backs/04-acorns",
        max_level = 5,
        xp_curve  = { 0, 100, 300, 700, 1500 },
        xp_rule   = { kind = "bb_won", mult = 1 },
        xp_action_text = "+1 XP per big blind won",
        effects   = {
            { kind = "earnings_mult", value = 1.015 },
        },
        bonus_text  = "+1.5% winnings per level",
        flavor_text = "Stash, store, compound. Every win plants the next.",
    },
    {
        id        = "patterns",
        name      = "Patterns",
        sprite    = "cards/backs/04-patterns",
        max_level = 5,
        xp_curve  = { 0, 100, 300, 700, 1500 },
        xp_rule   = { kind = "hands_lost" },
        xp_action_text = "+1 XP per hand lost",
        effects   = {
            { kind = "loss_mult", value = 0.98 },
        },
        bonus_text  = "-2% loss magnitude per level",
        flavor_text = "Soak it. The pattern shows up after enough mistakes.",
    },
}

return Decks
