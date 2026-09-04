-- data/decks.lua
--
-- The roster of 12 decks (2026-09 refactor; the retcon reference for what
-- each replaced is docs/deck-refactor-2026-09.md).
--
-- Decks are Act 2 progression (Decks.systemUnlocked: first shove win).
-- XP only accrues to the ACTIVE deck; effects of EVERY unlocked deck
-- stack. Each deck levels on its own plain unit (dollars won, heaters
-- caught, knockouts…) and opens on its own counter; nothing is gated by
-- stake. Act 2 is six or seven runs and each run maxes one deck: play,
-- max, shove, pick the next, until five are maxed, the Master opens, and
-- a good NL100M run maxes it for R2.
--
-- Built on the game's identities (docs/gametype-identity-redesign.md):
-- zoom is the sustain (Firehose), heads-up the burst (Closer), six-max
-- the tank (Anchor), tournaments the support (Circuit Pro), heat and
-- chips their own systems (Hot Hand, Bounty Hunter). Rules kept: a
-- status is a punch and no deck lengthens one; chip awards are immutable
-- (Bounty Hunter changes odds, not size); every "never" is a percentage.
--
-- Defines:
--   • id        = unique identifier string
--   • name      = player-facing display name
--   • sprite    = card-back texture path (art not final; reuse is fine)
--   • max_level = always 5
--   • xp_curve  = PER-DECK cumulative thresholds for levels 1..5, in the
--                 UNITS of that deck's xp_rule (plain: $, counts)
--   • xp_rule   = parameter block passed to the deck-XP registry
--                 (models/deck_xp_rules.lua) — each deck's own signal
--   • effects   = numeric perk list applied once per level (capped at 4)
--   • capstone  = single perk list applied once at L5 (may grant a proc
--                 or router: data/procs.lua, data/routers.lua)
--   • bonus_text= L1-4 UI text description
--   • flavor_text= deck description text
--   • unlock    = unlock criteria (models/deck_unlock_rules.lua kinds)
--
-- The first entry is the starter (GameState seeds it; the Act 2 story
-- beats anchor on its tile). Re-run `node tools/balance_sweep.js --act2`
-- after touching a deck that moves EV.

local Decks = {

    -- ── 1. Standard — cash ─────────────────────────────────────────────────
    -- Opens: start. Maxes: NL10K (a 9-table session's winnings).
    {
        id        = "standard",
        name      = "Standard",
        sprite    = "cards/backs/04-patterns",
        max_level = 5,
        xp_curve  = { 2e3, 2e4, 2e5, 2e6, 6e6 },
        xp_rule   = { kind = "money_won" },
        xp_action_text = "+1 XP per dollar won",
        effects   = {
            { kind = "earnings_mult", value = 1.5 },
        },
        capstone  = {
            text    = "{w:stack} wins pay double.",
            effects = { { kind = "stack_mult", value = 2.0 } },
        },
        bonus_text  = "+50% cash winnings per level",
        flavor_text = "The classic back. Solid, reliable, honest.",
    },

    -- ── 2. Firehose — zoom, the sustain ────────────────────────────────────
    -- Opens: 3,000 zoom hands. Maxes: NL1M on a zoom-heavy board.
    {
        id        = "firehose",
        name      = "Firehose",
        sprite    = "cards/backs/02-fish",
        max_level = 5,
        xp_curve  = { 1e4, 1e5, 1e6, 1e7, 5e7 },
        xp_rule   = { kind = "money_won", gtype = "zoom" },
        xp_action_text = "+1 XP per dollar won on Zoom",
        effects   = {
            { kind = "hand_pace_mult", value = 1.15, gtype = "zoom" },
        },
        capstone  = {
            text    = "A Zoom {w:stack} resolves every other Zoom table on the spot.",
            effects = { { kind = "proc", proc = "firehose_cascade" } },
        },
        bonus_text  = "Zoom tables deal 15% faster per level",
        flavor_text = "Hands are hands. Open the valve.",
        unlock = {
            kind      = "hands_at_gtype",
            gtype     = "zoom",
            threshold = 3000,
            text      = "Play 3,000 Zoom hands to unlock",
        },
    },

    -- ── 3. Closer — heads-up, the burst ────────────────────────────────────
    -- Opens: 3,000 HU hands. Maxes: NL1M.
    {
        id        = "closer",
        name      = "Closer",
        sprite    = "cards/backs/01-robot",
        max_level = 5,
        xp_curve  = { 1e4, 1e5, 1e6, 1e7, 5e7 },
        xp_rule   = { kind = "money_won", gtype = "hu" },
        xp_action_text = "+1 XP per dollar won Heads-Up",
        effects   = {
            { kind = "win_chance_shift", amount = 0.03, gtype = "hu" },
        },
        capstone  = {
            text    = "Heads-Up {l:stack} losses have a 50% chance to read one tier smaller.",
            effects = { { kind = "loss_tier_shift", from = "stack", to = "large", chance = 0.5, gtype = "hu" } },
        },
        bonus_text  = "+3% win chance Heads-Up per level",
        flavor_text = "One opponent. One stack. Take it.",
        unlock = {
            kind      = "hands_at_gtype",
            gtype     = "hu",
            threshold = 3000,
            text      = "Play 3,000 Heads-Up hands to unlock",
        },
    },

    -- ── 4. Bounty Hunter — chips ───────────────────────────────────────────
    -- Opens: 30 {chip} banked. Maxes: NL100M (the lanes run out there).
    {
        id        = "bounty_hunter",
        name      = "Bounty Hunter",
        sprite    = "cards/backs/04-acorns",
        max_level = 5,
        xp_curve  = { 10, 40, 100, 200, 400 },
        xp_rule   = { kind = "chips_banked" },
        xp_action_text = "+1 XP per {chip} banked",
        effects   = {
            { kind = "unbanked_stack_shift", value = 0.05 },
        },
        capstone  = {
            text    = "+1 {chip} on every bounty.",
            effects = { { kind = "stack_chip_add", value = 1 } },
        },
        bonus_text  = "+5% {w:stack} chance per level at tables whose {chip} you haven't banked yet",
        flavor_text = "Every lane has a price on it. Collect.",
        unlock = {
            kind      = "total_chips_banked",
            threshold = 30,
            text      = "Bank 30 {chip} to unlock",
        },
    },

    -- ── 5. Specialist — the pure board ─────────────────────────────────────
    -- Opens: 3,000 hands at 4+ tables. Maxes: NL1M.
    {
        id        = "specialist",
        name      = "Specialist",
        sprite    = "cards/backs/05-patterns",
        max_level = 5,
        xp_curve  = { 1e4, 1e5, 1e6, 1e7, 5e7 },
        xp_rule   = { kind = "money_won", pure_only = true },
        xp_action_text = "+1 XP per dollar won while every table is the same game",
        effects   = {
            { kind = "pure_board_bonus", earnings_mult = 1.2 },
        },
        capstone  = {
            text    = "A pure board deals 25% faster.",
            effects = { { kind = "pure_board_pace", value = 1.25 } },
        },
        bonus_text  = "+20% cash winnings per level while every open table is the same game",
        flavor_text = "One game. Every table. Perfect execution.",
        unlock = {
            kind      = "total_hands_at_4plus",
            threshold = 3000,
            text      = "Play 3,000 hands at 4+ tables to unlock",
        },
    },

    -- ── 6. Hot Hand — heat ─────────────────────────────────────────────────
    -- Opens: 50 heaters caught. Maxes: NL1M (heat sources are Act 2 items).
    {
        id        = "hot_hand",
        name      = "Hot Hand",
        sprite    = "cards/backs/05-nature",
        max_level = 5,
        xp_curve  = { 5, 20, 60, 150, 300 },
        xp_rule   = { kind = "heaters_caught" },
        xp_action_text = "+1 XP per heater caught",
        effects   = {
            { kind = "heater_win_mult", value = 1.25 },
        },
        capstone  = {
            text    = "When a heater burns out, 25% chance it jumps to a neighbouring table.",
            effects = { { kind = "proc", proc = "hot_hand_spread" } },
        },
        bonus_text  = "A heater's hand pays 25% more per level",
        flavor_text = "Run good. Then run gooder.",
        unlock = {
            kind      = "total_heaters",
            threshold = 50,
            text      = "Catch 50 heaters to unlock",
        },
    },

    -- ── 7. Maniac — variance ───────────────────────────────────────────────
    -- Opens: 5,000 {w:stack}. Maxes: NL100M.
    {
        id        = "maniac",
        name      = "Maniac",
        sprite    = "cards/backs/07-beach",
        max_level = 5,
        xp_curve  = { 5e5, 5e6, 5e7, 5e8, 5e9 },
        xp_rule   = { kind = "stack_dollars" },
        xp_action_text = "+1 XP per dollar won in {w:stack} pots",
        effects   = {
            { kind = "win_dist_shift",
              shift = { small = -0.10, medium = -0.10, large = 0.10, stack = 0.10 } },
        },
        capstone  = {
            text    = "Wins: 50% chance to read a tier bigger, 50% chance to pay double.",
            effects = {
                { kind = "win_tier_bump_chance",     value = 0.5 },
                { kind = "win_payout_double_chance", value = 0.5 },
            },
        },
        bonus_text  = "Wins lean Large and {w:stack}, +10% each per level",
        flavor_text = "Put the pedal to the floor. Wild swings, huge pots.",
        unlock = {
            kind      = "lifetime_stack_count",
            threshold = 5000,
            text      = "Hit 5,000 {w:stack} to unlock",
        },
    },

    -- ── 8. Nit — loss shape ────────────────────────────────────────────────
    -- Opens: $10M lost. Maxes: NL100M.
    {
        id        = "nit",
        name      = "Nit",
        sprite    = "cards/backs/03-fish",
        max_level = 5,
        xp_curve  = { 1e6, 1e7, 1e8, 1e9, 1e10 },
        xp_rule   = { kind = "money_lost" },
        xp_action_text = "+1 XP per dollar lost",
        effects   = {
            { kind = "loss_dist_shift",
              shift = { small = 0.18, medium = -0.06, large = -0.06, stack = -0.06 } },
        },
        capstone  = {
            text    = "{l:stack} losses have a 50% chance to read one tier smaller.",
            effects = { { kind = "loss_tier_shift", from = "stack", to = "large", chance = 0.5 } },
        },
        bonus_text  = "Losses lean Small, +18% per level",
        flavor_text = "Tight is right. Play safe, live to grind another day.",
        unlock = {
            kind      = "lifetime_money_lost",
            threshold = 1e7,
            text      = "Lose $10M to unlock",
        },
    },

    -- ── 9. Anchor — six-max, the tank ──────────────────────────────────────
    -- Opens: 25 tilts taken. Maxes: NL100M.
    {
        id        = "anchor",
        name      = "Anchor",
        sprite    = "cards/backs/04-hand",
        max_level = 5,
        xp_curve  = { 5, 15, 40, 80, 150 },
        xp_rule   = { kind = "tilts_absorbed" },
        xp_action_text = "+1 XP per tilt a 6-max table takes for a neighbour",
        effects   = {
            { kind = "router", router = "anchor_taunt" },
            { kind = "tilted_loss_mult", value = 0.8, gtype = "six_max" },
        },
        capstone  = {
            text    = "A tilt spent on a 6-max table heats a neighbour.",
            effects = { { kind = "proc", proc = "anchor_convert" } },
        },
        bonus_text  = "Tilts aimed beside a 6-max table land on it instead; its tilted hands lose 20% less per level",
        flavor_text = "Somebody has to take the hit. Sit them at the big table.",
        unlock = {
            kind      = "total_tilts",
            threshold = 25,
            text      = "Take 25 tilts to unlock",
        },
    },

    -- ── 10. Circuit Pro — tournaments, the support ─────────────────────────
    -- Opens: 3 tournaments won. Maxes: NL100M.
    {
        id        = "circuit_pro",
        name      = "Circuit Pro",
        sprite    = "cards/backs/02-castle",
        max_level = 5,
        xp_curve  = { 20, 80, 250, 600, 1200 },
        xp_rule   = { kind = "knockouts" },
        xp_action_text = "+1 XP per knockout",
        effects   = {
            { kind = "ko_targets_add", value = 1 },
        },
        capstone  = {
            text    = "First place heats every table.",
            effects = { { kind = "proc", proc = "circuit_pro_final" } },
        },
        bonus_text  = "Each knockout's effect lands on one more table per level",
        flavor_text = "The tournament pays the room.",
        unlock = {
            kind      = "total_ko_wins",
            threshold = 3,
            text      = "Win 3 tournaments to unlock",
        },
    },

    -- ── 11. The Bank — scale ───────────────────────────────────────────────
    -- Opens: $10B won. Maxes: NL100M (a $1B bankroll).
    {
        id        = "bank",
        name      = "The Bank",
        sprite    = "cards/backs/05-acorns",
        max_level = 5,
        xp_curve  = { 1e5, 1e6, 1e7, 1e8, 1e9 },
        xp_rule   = { kind = "bankroll_peak", absolute = true },
        xp_action_text = "XP is your highest bankroll",
        effects   = {
            { kind = "earnings_per_tier", value = 0.075 },
        },
        capstone  = {
            text    = "Wins are multiplied by your BANK multiplier, up to 3x.",
            effects = { { kind = "earnings_scale_by_bankroll", wins_only = true, cap = 3 } },
        },
        bonus_text  = "+7.5% cash winnings per table tier per level",
        flavor_text = "Earnings grow with stakes. Watch the capital accumulate.",
        unlock = {
            kind      = "lifetime_money_won",
            threshold = 1e10,
            text      = "Earn $10B to unlock",
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
        xp_curve  = { 1e9, 1e10, 5e10, 2e11, 5e11 },
        xp_rule   = { kind = "money_won", tier_min = 6 },
        xp_action_text = "+1 XP per dollar won at NL100M or above",
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
