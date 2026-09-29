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
-- status is a punch (the Gas Stove may lengthen one); chip awards are immutable
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
--   • unlock    = unlock criteria (models/deck_unlock_rules.lua kinds)
--
-- Player-facing copy, one shape per field (views read them through
-- models/Decks: bonusTextAt / bonusTextPerLevel / levelsOnText), all in
-- the style sheet's forms (docs/copy-style.md; sim/lint_copy.lua checks
-- per_level and every capstone number against the effects). Numbers are
-- NEVER shown as XP; the UI shows bars, and these words:
--   • bonus      = { text, per_level }. `text` is the effect with {n} where
--                  the number goes, under eight words; `per_level` is the
--                  number for ONE level in the printed unit. The tooltip
--                  shows {n} × level (the bonus in play now), the roster
--                  shows {n} + " per level". A bonus with no number (a
--                  router, the Master) has no {n} and no per_level.
--   • levels_on  = what fills the bar, a noun phrase short enough for a
--                  tile: "money won on Zoom". Shown as "Levels on <x>" in
--                  the column and tooltip, bare on the tile.
--   • capstone.text = one sentence in a family skeleton, its number in it.
--   • unlock.text   = a lowercase noun phrase the counter completes, the
--                  catalog sticker's shape: "Zoom hands" renders as
--                  "0 / 3,000 Zoom hands". `format = "money"` switches the
--                  counter to dollars. The counter comes from the unlock
--                  registry's progress, never from this text.
--   • flavor_text = one line of voice.
-- IconText markers ({chip}, {w:stack}, {l:stack}) are fine in all of them.
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
        -- Sized by sim/deck_curve_check.lua (2026-09-29): nine filled T3
        -- six-max tables reach L3 in ~16 min and L4 in ~40 min, and L5
        -- stays T4 money that lands in T4's first quarter hour (nine mid
        -- NL10K tables: 13 min on Zoom, 26 on six-max). The previous top
        -- (2e6) was 44 min to 1.4 h of T4; before that 6e6, hours.
        xp_curve  = { 2e3, 1.5e4, 6e4, 1.5e5, 6e5 },
        xp_rule   = { kind = "money_won" },
        levels_on = "money won",
        -- The deck that refuses to lose big: a stack loss is rerolled once
        -- per level, keep the smallest (OutcomeMath.sampleOutcome). Low
        -- stakes stop throwing stack losses at all, the top stakes about
        -- 190x less on a full build (sim/standard_reroll.lua). Act 3's
        -- anti ladder is what pushes back.
        effects   = {
            { kind = "stack_loss_rerolls", value = 1 },
        },
        capstone  = {
            text    = "Those rerolls can land on a {c:won:win}.",
            effects = { { kind = "stack_loss_reroll_wins" } },
        },
        bonus       = { text = "A {l:stack}: reroll it {n} times, keep the smallest.", per_level = 1 },
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
        levels_on = "money won on Zoom",
        effects   = {
            { kind = "hand_pace_mult", value = 1.15, gtype = "zoom" },
        },
        capstone  = {
            text    = "Win a {w:stack} at {k:Zoom}: every {k:Zoom} table catches a {c:heat:heater}.",
            effects = { { kind = "proc", proc = "firehose_cascade" } },
        },
        bonus       = { text = "{k:Zoom} deal speed +{n}%", per_level = 15, compound = true },
        flavor_text = "Hands are hands. Open the valve.",
        unlock = {
            kind      = "hands_at_gtype",
            gtype     = "zoom",
            threshold = 3000,
            text      = "Zoom hands",
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
        levels_on = "money won Heads-Up",
        effects   = {
            { kind = "win_chance_shift", amount = 0.03, gtype = "hu" },
        },
        capstone  = {
            text    = "At {k:Heads-Up}, 1 in 2 chance: {l:stack} {arrow} {l:large}.",
            effects = { { kind = "loss_tier_shift", from = "stack", to = "large", chance = 1/2, gtype = "hu" } },
        },
        bonus       = { text = "+{n}% {c:chance:odds} at {k:Heads-Up}", per_level = 3 },
        flavor_text = "One opponent. One stack. Take it.",
        unlock = {
            kind      = "hands_at_gtype",
            gtype     = "hu",
            threshold = 3000,
            text      = "Heads-Up hands",
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
        levels_on = "{chip} banked",
        effects   = {
            { kind = "unbanked_stack_shift", value = 0.05 },
        },
        capstone  = {
            text    = "+1 {chip} on every {c:chip:bounty}.",
            effects = { { kind = "stack_chip_add", value = 1 } },
        },
        bonus       = { text = "+{n}% {w:stack} {c:chance:odds} at unpaid tables", per_level = 5 },
        flavor_text = "Every lane has a price on it. Collect.",
        unlock = {
            kind      = "total_chips_banked",
            threshold = 30,
            text      = "{chip} {c:chip:banked}",
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
        levels_on = "money won on a one-game board",
        effects   = {
            { kind = "pure_board_bonus", earnings_mult = 1.2 },
        },
        capstone  = {
            text    = "One-game board deal speed ×1.25.",
            effects = { { kind = "pure_board_pace", value = 1.25 } },
        },
        bonus       = { text = "+{n}% {c:won:winnings} when {k:every_table} is one game", per_level = 20, compound = true },
        flavor_text = "One game. Every table. Perfect execution.",
        unlock = {
            kind      = "total_hands_at_4plus",
            threshold = 3000,
            text      = "hands at 4+ tables",
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
        levels_on = "heaters caught",
        effects   = {
            { kind = "heater_win_mult", value = 1.25 },
        },
        capstone  = {
            text    = "A {c:heat:heater} ends: 1 in 4 chance a table {k:adjacent} to it catches one.",
            effects = { { kind = "proc", proc = "hot_hand_spread" } },
        },
        bonus       = { text = "+{n}% on the hand a {c:heat:heater} deals for you", per_level = 25, compound = true },
        flavor_text = "Run good. Then run gooder.",
        unlock = {
            kind      = "total_heaters",
            threshold = 50,
            text      = "{c:heat:heaters} caught",
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
        levels_on = "money won in {w:stack} pots",
        effects   = {
            { kind = "win_dist_shift",
              shift = { small = -0.10, medium = -0.10, large = 0.10, stack = 0.10 } },
        },
        capstone  = {
            text    = "Each {c:won:win}: 1 in 2 chance one size up, and 1 in 2 chance ×2.",
            effects = {
                { kind = "win_tier_bump_chance",     value = 1/2 },
                { kind = "win_payout_double_chance", value = 1/2 },
            },
        },
        bonus       = { text = "{c:won:Wins} lean {w:large} and {w:stack}, +{n}% each", per_level = 10 },
        flavor_text = "Put the pedal to the floor. Wild swings, huge pots.",
        unlock = {
            kind      = "total_stacks",
            threshold = 5000,
            text      = "{w:stack} {c:won:wins}",
        },
    },

    -- ── 8. Swarm — the cursors ─────────────────────────────────────────────
    -- Opens: hands dealt by cursors. Levels on the same. Replaced Nit
    -- 2026-09-07 (docs/deck-refactor-2026-09.md): Standard's reroll made
    -- Nit's whole kit a worse Standard. Each level makes a Focus level
    -- worth one more table (a 3x3 solo, the full 6x6 at L5 with the
    -- Second Monitor); the capstone doubles cursor speed. Focus and the
    -- swarm are one thing: nobody deals 30 tables by hand.
    {
        id        = "swarm",
        name      = "Swarm",
        sprite    = "cards/backs/03-fish",
        max_level = 5,
        -- Hands a cursor caused, cumulative: its click and every hand
        -- chained off that click on the house's clock (the Zoom chain, a
        -- spread, a clash's deal; models/deck_xp_rules). A player's click
        -- and its chain earn nothing. A 16-Zoom NL10K swarm board plays
        -- ~200 such hands a minute, so this maxes in about 50 minutes of
        -- it: a deck maxes inside a run, and a run is under an hour. A
        -- board chaining 800 a minute maxes it in a quarter of that.
        -- (Until 2026-09-28 only the clicks counted, a quarter of that
        -- board's hands, against a 40,000 top: days.)
        xp_curve  = { 200, 800, 2500, 5500, 10000 },
        xp_rule   = { kind = "cursor_deals" },
        levels_on = "hands dealt by cursors",
        effects   = {
            { kind = "focus_level_worth", value = 1 },
        },
        -- Level 5 is the capstone (Decks.applyEffects applies the per-level
        -- block four times), so the fifth "+1 worth" rides the capstone:
        -- that is what puts max Focus at 34 and the full board at 36 with
        -- the Second Monitor. sim/test_everything.lua measures it.
        capstone  = {
            text    = "{c:upgrade:Cursor} speed ×2.",
            effects = { { kind = "cursor_speed_mult", value = 2 }, { kind = "focus_level_worth", value = 1 } },
        },
        bonus       = { text = "Each {c:upgrade:FOCUS} level is worth +{n} more.", per_level = 1 },
        flavor_text = "Nobody deals thirty tables. Nobody has to.",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 3000,                         -- PLACEHOLDER
            text      = "hands dealt by {c:upgrade:cursors}",
        },
    },

    -- ── 9. Anchor — six-max, the tank ──────────────────────────────────────
    -- Opens: 25 tilts taken. Maxes: NL100M.
    -- The taunt router (tilts aimed beside a 6-max land on it) is what makes
    -- the levels_on line true; it has no number, so the bonus line is the
    -- loss reduction and the taunt reads from how the deck levels.
    {
        id        = "anchor",
        name      = "Anchor",
        sprite    = "cards/backs/04-hand",
        max_level = 5,
        xp_curve  = { 5, 15, 40, 80, 150 },
        xp_rule   = { kind = "tilts_absorbed" },
        levels_on = "tilts a 6-max takes for a neighbour",
        effects   = {
            { kind = "router", router = "anchor_taunt" },
            { kind = "tilted_loss_mult", value = 0.8, gtype = "six_max" },
        },
        capstone  = {
            text    = "A {c:tilt:tilt} on a {k:6-Max} ends: a table {k:adjacent} to it catches a {c:heat:heater}.",
            effects = { { kind = "proc", proc = "anchor_convert" } },
        },
        bonus       = { text = "-{n}% on {c:tilt:tilted} {k:6-Max} {c:lost:losses}", per_level = 20, compound = true },
        flavor_text = "Somebody has to take the hit. Sit them at the big table.",
        unlock = {
            kind      = "total_tilts",
            threshold = 25,
            text      = "{c:tilt:tilts} taken",
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
        levels_on = "knockouts",
        effects   = {
            { kind = "ko_targets_add", value = 1 },
        },
        capstone  = {
            text    = "{k:First_place}: {k:every_table} catches a {c:heat:heater}.",
            effects = { { kind = "proc", proc = "circuit_pro_final" } },
        },
        bonus       = { text = "Each {k:knockout} reaches {n} more table", per_level = 1 },
        flavor_text = "The tournament pays the room.",
        unlock = {
            kind      = "total_ko_wins",
            threshold = 3,
            text      = "tournament {c:won:wins}",
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
        levels_on = "your highest bankroll",
        effects   = {
            { kind = "earnings_per_tier", value = 0.075 },
        },
        capstone  = {
            text    = "{c:won:Winnings} scale with your BANK multiplier, up to ×3.",
            effects = { { kind = "earnings_scale_by_bankroll", wins_only = true, cap = 3 } },
        },
        bonus       = { text = "+{n}% {c:won:winnings} per stake", per_level = 7.5 },
        flavor_text = "Earnings grow with stakes. Watch the capital accumulate.",
        unlock = {
            kind      = "total_money_won",
            threshold = 1e10,
            text      = "money won",
            format    = "money",
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
        levels_on = "money won at NL100M and up",
        effects   = {
            { kind = "shove_base_per_deck_level", value = 0.01 },
        },
        capstone  = {
            text    = "The base it restores ×2, up to your item count.",
            effects = { { kind = "shove_base_double" } },
        },
        bonus       = { text = "+1% shove base per deck level you hold, up to your item count" },
        flavor_text = "Every deck you've mastered, in one hand.",
        unlock = {
            kind      = "decks_maxed",
            threshold = 5,
            text      = "decks maxed",
        },
    },

}

return Decks
