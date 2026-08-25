-- data/decks.lua
--
-- The OVERHAULED roster of 11 decks (+ the Master).
--
-- Defines:
--   • id        = unique identifier string
--   • name      = player-facing display name
--   • sprite    = card-back texture path (reused across the roster)
--   • max_level = always 5
--   • xp_curve  = PER-DECK cumulative thresholds for levels 1..5, in the
--                 UNITS of that deck's xp_rule. Money-based rules use
--                 DOLLAR magnitudes (millions) so a single high-tier pot
--                 can't one-shot the curve; count-based rules use event
--                 counts tuned so ~30 min of standard play (6-max single
--                 table ≈ 4.4s/hand ≈ 400 hands / 30 min) maxes the deck.
--   • xp_rule   = parameter block passed to the deck-XP registry (the
--                 level-up condition — each deck's is its own identity)
--   • effects   = numeric perk list applied once per level (capped at 4)
--   • capstone  = single perk list applied once at L5
--   • bonus_text= L1-4 UI text description
--   • flavor_text= deck description text
--   • unlock    = unlock criteria (distinct per deck)
--

local Decks = {

    -- ── 1. Standard ────────────────────────────────────────────────────────
    {
        id        = "standard",
        name      = "Standard",
        sprite    = "cards/backs/06-nature",
        max_level = 5,
        xp_curve  = { 10, 40, 100, 180, 280 },   -- hands won (count)
        xp_rule   = { kind = "hands_won" },
        xp_action_text = "+1 XP per hand won",
        effects   = {
            { kind = "earnings_mult", value = 1.5 },
        },
        capstone  = {
            text    = "Wins never roll Small. Every win is Medium or bigger.",
            effects = { { kind = "win_tier_floor", tier = "medium" } },
        },
        bonus_text  = "+50% cash winnings per level",
        flavor_text = "The classic back. Solid, reliable, honest.",
    },

    -- ── 2. Hustler ─────────────────────────────────────────────────────────
    {
        id        = "hustler",
        name      = "Hustler",
        sprite    = "cards/backs/05-patterns",
        max_level = 5,
        xp_curve  = { 25, 90, 200, 340, 480 },   -- hands played (count)
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "+1 XP per hand played",
        effects   = {
            { kind = "hand_pace_mult", value = 1.4 },
        },
        capstone  = {
            text    = "Double the hand speed of everything (2x speed)",
            effects = { { kind = "hand_pace_mult", value = 2.0 } },
        },
        bonus_text  = "+40% hand pace per level",
        flavor_text = "Fast cards, fast deals, fast money.",
        unlock = {
            kind      = "lifetime_hands_played",
            threshold = 10000,
            text      = "Play 10,000 hands cumulatively to unlock",
        },
    },

    -- ── 3. Nit ─────────────────────────────────────────────────────────────
    {
        id        = "nit",
        name      = "Nit",
        sprite    = "cards/backs/05-nature",
        max_level = 5,
        xp_curve  = { 10000, 100000, 800000, 3000000, 10000000 },  -- $ lost
        xp_rule   = { kind = "money_lost" },
        xp_action_text = "+1 XP per dollar lost",
        effects   = {
            { kind = "loss_dist_shift",
              shift = { small = 0.15, medium = -0.05, large = -0.07, jackpot = -0.03 } },
        },
        capstone  = {
            text    = "Losses never roll Jackpot, so you can't lose a full stack.",
            effects = { { kind = "loss_tier_ceiling", tier = "large" } },
        },
        bonus_text  = "Shifts loss distribution towards Small losses",
        flavor_text = "Tight is right. Play safe, live to grind another day.",
        unlock = {
            kind      = "lifetime_money_lost",
            threshold = 1000000,
            text      = "Lose $1,000,000 cumulatively to unlock",
        },
    },

    -- ── 4. Maniac ──────────────────────────────────────────────────────────
    {
        id        = "maniac",
        name      = "Maniac",
        sprite    = "cards/backs/05-acorns",
        max_level = 5,
        xp_curve  = { 50000, 300000, 2000000, 7000000, 20000000 },  -- $ won in jackpots
        xp_rule   = { kind = "jackpot_dollars" },
        xp_action_text = "+1 XP per dollar won in Jackpots",
        effects   = {
            { kind = "win_dist_shift",
              shift = { small = -0.15, medium = -0.15, large = 0.20, jackpot = 0.10 } },
            { kind = "loss_dist_shift",
              shift = { small = -0.15, medium = -0.15, large = 0.20, jackpot = 0.10 } },
        },
        capstone  = {
            text    = "50% chance for a tier upgrade, 50% chance to double the payout",
            effects = {
                { kind = "tier_bump_chance",     value = 0.5 },
                { kind = "payout_double_chance", value = 0.5 },
            },
        },
        bonus_text  = "Shifts win and loss distributions heavily toward Large/Jackpot",
        flavor_text = "Put the pedal to the floor. Wild swings, huge pots.",
        unlock = {
            kind      = "lifetime_jackpot_count",
            threshold = 1500,
            text      = "Hit 1,500 Jackpots to unlock",
        },
    },

    -- ── 5. Short Stack ──────────────────────────────────────────────────────
    {
        id        = "short_stack",
        name      = "Short Stack",
        sprite    = "cards/backs/04-patterns",
        max_level = 5,
        xp_curve  = { 30, 80, 140, 200, 260 },   -- table_rebuys grants +10/rebuy
        xp_rule   = { kind = "table_rebuys" },
        xp_action_text = "+10 XP per table rebuy",
        effects   = {
            { kind = "rebuy_discount", value = 0.15 },
        },
        capstone  = {
            text    = "50% chance for rebuys to be completely free",
            effects = { { kind = "free_rebuy_chance", value = 0.5 } },
        },
        bonus_text  = "Rebuys are 15% cheaper per level",
        flavor_text = "Low buy-in specialist. Keep refilling the stacks.",
        unlock = {
            kind      = "lifetime_rebuys",
            threshold = 500,
            text      = "Rebuy tables 500 times to unlock",
        },
    },

    -- ── 6. The Bank ────────────────────────────────────────────────────────
    {
        id        = "bank",
        name      = "The Bank",
        sprite    = "cards/backs/04-acorns",
        max_level = 5,
        xp_curve  = { 100000, 700000, 4000000, 15000000, 50000000 },  -- $ won
        xp_rule   = { kind = "money_won" },
        xp_action_text = "+1 XP per dollar won",
        effects   = {
            { kind = "earnings_per_tier", value = 0.15 },
        },
        capstone  = {
            text    = "Every hand outcome is multiplied by your bankroll multiplier",
            effects = { { kind = "earnings_scale_by_bankroll" } },
        },
        bonus_text  = "+15% cash winnings per table tier per level",
        flavor_text = "Earnings grow with stakes. Watch the capital accumulate.",
        unlock = {
            kind      = "lifetime_money_won",
            threshold = 5000000,
            text      = "Earn $5,000,000 cumulatively to unlock",
        },
    },

    -- ── 7. Swarm (Cursor Deck) ─────────────────────────────────────────────
    {
        id        = "cursor",
        name      = "Swarm",
        sprite    = "cards/backs/02-fish",
        max_level = 5,
        xp_curve  = { 30, 120, 280, 450, 650 },   -- hands played (count)
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "+1 XP per hand played",
        effects   = {
            { kind = "cursor_count_add", value = 1 },
        },
        capstone  = {
            text    = "Cursors move 3x faster and click instantly",
            effects = {
                { kind = "cursor_speed_mult", value = 3.0 },
                { kind = "cursor_instant_click" },
            },
        },
        bonus_text  = "+1 cursor per level",
        flavor_text = "The swarm grows. Let the clicks deal the cards.",
        unlock = {
            kind      = "lifetime_hands_played",
            threshold = 15000,
            text      = "Play 15,000 hands cumulatively to unlock",
        },
    },

    -- ── 8. Specialist (Single Table Deck) ──────────────────────────────────
    {
        id        = "specialist",
        name      = "Specialist",
        sprite    = "cards/backs/03-fish",
        max_level = 5,
        xp_curve  = { 30, 110, 240, 380, 520 },   -- single-table wins grant +2 each
        xp_rule   = { kind = "hands_won_single_table" },
        xp_action_text = "+2 XP per hand won on a single table",
        effects   = {
            { kind = "solo_table_bonus", earnings_mult = 2.0, wc_bonus = 0.10 },
        },
        capstone  = {
            text    = "Single table deals 2x faster (2x pace)",
            effects = { { kind = "solo_table_pace", value = 2.0 } },
        },
        bonus_text  = "+100% earnings and +10% Win Chance on exactly 1 table",
        flavor_text = "One table. One focus. Perfect execution.",
        unlock = {
            kind      = "lifetime_hands_played",
            threshold = 1500,
            text      = "Play 1,500 hands cumulatively to unlock",
        },
    },

    -- ── 9. Multitasker (Focus / Overwhelm Deck) ────────────────────────────
    -- Levels on hands won WHILE OVERWHELMED — the more tables you're running
    -- over your focus cap, the more XP each win grants. Unique on purpose; do
    -- not flatten to a plain table-count threshold.
    {
        id        = "multitasker",
        name      = "Multitasker",
        sprite    = "cards/backs/05-patterns",
        max_level = 5,
        xp_curve  = { 30, 110, 250, 400, 550 },   -- overwhelmed wins (scales w/ overload)
        xp_rule   = { kind = "hands_won_overwhelmed" },
        xp_action_text = "+1 XP per table over your cap, per hand won",
        effects   = {
            { kind = "focus_capacity_add", value = 3 },
        },
        capstone  = {
            text    = "Removes Focus penalty entirely",
            effects = { { kind = "focus_penalty_immune" } },
        },
        bonus_text  = "+3 Focus Capacity per level",
        flavor_text = "Thrive in the swarm. Keep adding tables.",
        unlock = {
            kind      = "lifetime_hands_overwhelmed",
            threshold = 5000,
            text      = "Play 5,000 hands over your focus cap to unlock",
        },
    },

    -- ── 10. Investor (Upgrades Deck) ──────────────────────────────────────
    {
        id        = "investor",
        name      = "Investor",
        sprite    = "cards/backs/05-acorns",
        max_level = 5,
        xp_curve  = { 45, 120, 240, 360, 480 },   -- upgrades_bought grants +15 each
        xp_rule   = { kind = "upgrades_bought" },
        xp_action_text = "+15 XP per purchased run upgrade",
        effects   = {
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
        capstone  = {
            text    = "Adds a final Super Level to run upgrades in the shop",
            effects = { { kind = "run_upgrade_bonus_levels", value = 1 } },
        },
        bonus_text  = "Sharper Reads and Pot Control are 15% stronger per level",
        flavor_text = "Invest in upgrades. Compound your poker edge.",
        unlock = {
            kind      = "lifetime_upgrades_bought",
            threshold = 50,
            text      = "Buy 50 run-upgrade levels to unlock",
        },
    },

    -- ── 11. Tier Manipulator (Win% / Tier Deck) ───────────────────────────
    {
        id        = "tier_manipulator",
        name      = "Tier Manipulator",
        sprite    = "cards/backs/05-nature",
        max_level = 5,
        xp_curve  = { 15, 55, 120, 200, 280 },   -- wins at T2+ only (count)
        xp_rule   = { kind = "hands_won_above_t1" },
        xp_action_text = "+1 XP per hand won at T2+ stakes",
        effects   = {
            { kind = "fill_window_widen", value = 1 },
        },
        capstone  = {
            text    = "Every level of upgrade you purchase adds +1 to all other tiers automatically",
            effects = { { kind = "fill_cascade" } },
        },
        bonus_text  = "Adds new, purchasable upgrade levels per tier",
        flavor_text = "Manipulate the stakes. Bend the limits.",
        unlock = {
            kind      = "lifetime_money_won",
            threshold = 50000000,
            text      = "Earn $50,000,000 cumulatively to unlock",
        },
    },

    -- ── 12. The Master (Act 2 R2 key) ──────────────────────────────────────
    -- Unlocks once 5 decks are maxed. Restores the shove base the dealer's
    -- R2 cheat nullifies: +value shove-base per TOTAL deck level (its own
    -- levels included), doubled at capstone. The only way to beat R2.
    -- PLACEHOLDER name/copy/number — balance + captor voice are later passes.
    {
        id        = "master",
        name      = "The Master",
        sprite    = "cards/backs/06-nature",
        max_level = 5,
        xp_curve  = { 40, 130, 280, 450, 650 },   -- hands won (count; endgame, longer)
        xp_rule   = { kind = "hands_won" },
        xp_action_text = "+1 XP per hand won",
        effects   = {
            { kind = "shove_base_per_deck_level", value = 0.01 },
        },
        capstone  = {
            text    = "Doubles the base it restores, and it may exceed the things you own",
            effects = { { kind = "shove_base_double" } },
        },
        bonus_text  = "+1 to your ITEMS per total deck level, never more than the things you own",
        flavor_text = "Every deck you've mastered, in one hand.",
        unlock = {
            kind      = "decks_maxed",
            threshold = 5,
            text      = "Max 5 decks to unlock",
        },
    },

}

return Decks
