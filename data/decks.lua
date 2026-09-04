-- data/decks.lua
--
-- The roster of 11 decks (+ the Master).
--
-- Decks are Act 2 progression (Decks.systemUnlocked: first shove win).
-- XP only accrues to the ACTIVE deck; effects of EVERY unlocked deck
-- stack. Nothing is gated by stake: every count-shaped rule earns the
-- table's BUY-IN IN DOLLARS per event (models/deck_xp_rules.lua) — a win
-- at NL2 is 2 XP, at NL100 100, at NL10K 10,000 — so the ladder's own
-- steps are the pacing and the rule is the same everywhere. Each
-- curve is front-loaded: the first levels land while you are still
-- climbing toward the deck's stake (you use the deck TO get over the
-- wall — L1-L3 are about 1 / 3 / 10 min on the 9-table board one stake
-- below), the last levels need that stake, and a strong 9-table board
-- there maxes it in 30-45 min. Money-shaped rules (Nit, Maniac, The Bank,
-- Investor) are already in dollars and pace the same way on their own.
--
-- Rough targets (2026-09-03, docs/balance-act2.md): Standard maxes at
-- NL10K; Hustler / Swarm / Short Stack at NL10K-NL1M; Specialist /
-- Multitasker / Tier Manipulator at NL1M; Nit / Maniac / The Bank /
-- Investor at NL100M; Master on a good NL100M run. Act 2 is six shoves,
-- about one maxed deck each, Master last.
--
-- Unlocks are each deck's OWN lifetime counter (models/deck_unlock_rules),
-- thresholds staged so the cheap ones open during the first NL10K play
-- and the money ones around NL1M / NL100M. Tune from play.
--
-- Defines:
--   • id        = unique identifier string
--   • name      = player-facing display name
--   • sprite    = card-back texture path (reused across the roster)
--   • max_level = always 5
--   • xp_curve  = PER-DECK cumulative thresholds for levels 1..5, in the
--                 UNITS of that deck's xp_rule (buy-in dollars, or dollars)
--   • xp_rule   = parameter block passed to the deck-XP registry (the
--                 level-up condition — each deck's is its own identity)
--   • effects   = numeric perk list applied once per level (capped at 4)
--   • capstone  = single perk list applied once at L5
--   • bonus_text= L1-4 UI text description
--   • flavor_text= deck description text
--   • unlock    = unlock criteria (distinct per deck)
--
-- Re-run `node tools/balance_sweep.js --act2` after touching a deck that
-- moves EV (Standard, Hustler, Nit, Maniac, The Bank, Investor): the
-- upgrade window prices are derived holding them.

local Decks = {

    -- ── 1. Standard ────────────────────────────────────────────────────────
    -- Starter. The climb to NL100 is seconds, so L1-L3 are priced on the
    -- 9-table NL100 board (~140k XP/hr): 1 / 3 / 10 min. L4-L5 at NL10K
    -- (200 / 800 wins there, ~35 min on a strong board).
    {
        id        = "standard",
        name      = "Standard",
        sprite    = "cards/backs/06-nature",
        max_level = 5,
        xp_curve  = { 2.5e3, 8e3, 2.5e4, 2e6, 8e6 },
        xp_rule   = { kind = "hands_won" },
        xp_action_text = "XP per hand won: the table's buy-in in $",
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
    -- Maxes at NL10K (1,400 hands there).
    {
        id        = "hustler",
        name      = "Hustler",
        sprite    = "cards/backs/05-patterns",
        max_level = 5,
        xp_curve  = { 3e3, 1e4, 3e4, 3e6, 1.4e7 },
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "XP per hand played: the table's buy-in in $",
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
            threshold = 2000,
            text      = "Play 2,000 hands to unlock",
        },
    },

    -- ── 3. Nit ─────────────────────────────────────────────────────────────
    -- Maxes at NL100M.
    {
        id        = "nit",
        name      = "Nit",
        sprite    = "cards/backs/05-nature",
        max_level = 5,
        xp_curve  = { 1e7, 5e7, 3e8, 5e9, 1.8e10 },  -- $ lost
        xp_rule   = { kind = "money_lost" },
        xp_action_text = "+1 XP per dollar lost",
        effects   = {
            { kind = "loss_dist_shift",
              shift = { small = 0.15, medium = -0.05, large = -0.07, stack = -0.03 } },
        },
        capstone  = {
            text    = "Losses never roll a Stack.",
            effects = { { kind = "loss_tier_ceiling", tier = "large" } },
        },
        bonus_text  = "Shifts loss distribution towards Small losses",
        flavor_text = "Tight is right. Play safe, live to grind another day.",
        unlock = {
            kind      = "lifetime_money_lost",
            threshold = 3e9,
            text      = "Lose $3B to unlock",
        },
    },

    -- ── 4. Maniac ──────────────────────────────────────────────────────────
    -- Maxes at NL100M.
    {
        id        = "maniac",
        name      = "Maniac",
        sprite    = "cards/backs/05-acorns",
        max_level = 5,
        xp_curve  = { 1e8, 5e8, 3e9, 5e11, 2.4e12 },  -- $ won in stacks
        xp_rule   = { kind = "stack_dollars" },
        xp_action_text = "+1 XP per dollar won in Stack pots",
        effects   = {
            { kind = "win_dist_shift",
              shift = { small = -0.15, medium = -0.15, large = 0.20, stack = 0.10 } },
            { kind = "loss_dist_shift",
              shift = { small = -0.15, medium = -0.15, large = 0.20, stack = 0.10 } },
        },
        capstone  = {
            text    = "50% chance for a tier upgrade, 50% chance to double the payout",
            effects = {
                { kind = "tier_bump_chance",     value = 0.5 },
                { kind = "payout_double_chance", value = 0.5 },
            },
        },
        bonus_text  = "Shifts win and loss distributions heavily toward Large/Stack",
        flavor_text = "Put the pedal to the floor. Wild swings, huge pots.",
        unlock = {
            kind      = "lifetime_stack_count",
            threshold = 20000,
            text      = "Hit 20,000 Stacks to unlock",
        },
    },

    -- ── 5. Short Stack ──────────────────────────────────────────────────────
    -- Maxes at NL10K-NL1M (a rebuy earns 10 × the buy-in).
    {
        id        = "short_stack",
        name      = "Short Stack",
        sprite    = "cards/backs/04-patterns",
        max_level = 5,
        xp_curve  = { 2e3, 8e3, 2e4, 8e5, 2.6e6 },
        xp_rule   = { kind = "table_rebuys" },
        xp_action_text = "XP per rebuy: 10 x the table's buy-in in $",
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
            threshold = 100,
            text      = "Rebuy tables 100 times to unlock",
        },
    },

    -- ── 6. The Bank ────────────────────────────────────────────────────────
    -- Maxes at NL100M.
    {
        id        = "bank",
        name      = "The Bank",
        sprite    = "cards/backs/04-acorns",
        max_level = 5,
        xp_curve  = { 1e8, 5e8, 3e9, 4e11, 2e12 },  -- $ won
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
            threshold = 1e11,
            text      = "Earn $100B to unlock",
        },
    },

    -- ── 7. Swarm (Cursor Deck) ─────────────────────────────────────────────
    -- Maxes at NL10K-NL1M.
    {
        id        = "swarm",
        name      = "Swarm",
        sprite    = "cards/backs/02-fish",
        max_level = 5,
        xp_curve  = { 4e3, 1.2e4, 4e4, 4e6, 1.6e7 },
        xp_rule   = { kind = "hands_played" },
        xp_action_text = "XP per hand played: the table's buy-in in $",
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
            threshold = 6000,
            text      = "Play 6,000 hands to unlock",
        },
    },

    -- ── 8. Specialist (Single Table Deck) ──────────────────────────────────
    -- Maxes at NL1M on one table.
    {
        id        = "specialist",
        name      = "Specialist",
        sprite    = "cards/backs/03-fish",
        max_level = 5,
        xp_curve  = { 5e4, 1.5e5, 4e5, 4e8, 1.5e9 },
        xp_rule   = { kind = "hands_won_single_table" },
        xp_action_text = "XP per hand won on a single table: 2 x the buy-in in $",
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
            kind      = "lifetime_stack_count",
            threshold = 2000,
            text      = "Hit 2,000 Stacks to unlock",
        },
    },

    -- ── 9. Multitasker (Focus / Overwhelm Deck) ────────────────────────────
    -- Levels on hands won WHILE OVERWHELMED — the more tables you're running
    -- over your focus cap, the more XP each win grants. Unique on purpose; do
    -- not flatten to a plain table-count threshold. Maxes at NL1M.
    {
        id        = "multitasker",
        name      = "Multitasker",
        sprite    = "cards/backs/05-patterns",
        max_level = 5,
        xp_curve  = { 1e6, 3.5e6, 1e7, 1.6e8, 5.5e8 },
        xp_rule   = { kind = "hands_won_overwhelmed" },
        xp_action_text = "XP per hand won: the buy-in in $, per table over your cap",
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
            threshold = 2000,
            text      = "Play 2,000 hands over your focus cap to unlock",
        },
    },

    -- ── 10. Investor (Upgrades Deck) ──────────────────────────────────────
    -- XP is dollars spent on run upgrades, so the ladder paces it on its
    -- own (an NL10K window is ~$200k, NL1M ~$500M, NL100M ~$32B). Maxes at
    -- NL100M.
    {
        id        = "investor",
        name      = "Investor",
        sprite    = "cards/backs/05-acorns",
        max_level = 5,
        xp_curve  = { 2e5, 5e8, 3e9, 1e10, 3e10 },
        xp_rule   = { kind = "upgrades_bought" },
        xp_action_text = "+1 XP per dollar spent on run upgrades",
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
            threshold = 150,
            text      = "Buy 150 run-upgrade levels to unlock",
        },
    },

    -- ── 11. Tier Manipulator (Win% / Tier Deck) ───────────────────────────
    -- Maxes at NL1M.
    {
        id        = "tier_manipulator",
        name      = "Tier Manipulator",
        sprite    = "cards/backs/05-nature",
        max_level = 5,
        xp_curve  = { 2.5e5, 7e5, 2e6, 8e8, 3e9 },
        xp_rule   = { kind = "hands_won_above_t1" },
        xp_action_text = "XP per hand won above NL2: the table's buy-in in $",
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
            threshold = 1e9,
            text      = "Earn $1B to unlock",
        },
    },

    -- ── 12. The Master (Act 2 R2 key) ──────────────────────────────────────
    -- Unlocks once 5 decks are maxed. Restores the shove base the dealer's
    -- R2 cheat nullifies: +value shove-base per TOTAL deck level (its own
    -- levels included), doubled at capstone. The only way to beat R2.
    -- PLACEHOLDER name/copy/number — balance + captor voice are later passes.
    -- Maxes on a good NL100M run.
    {
        id        = "master",
        name      = "The Master",
        sprite    = "cards/backs/06-nature",
        max_level = 5,
        xp_curve  = { 2.5e7, 7e7, 2e8, 1e11, 2.8e11 },
        xp_rule   = { kind = "hands_won" },
        xp_action_text = "XP per hand won: the table's buy-in in $",
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
