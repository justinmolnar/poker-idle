-- data/catalog.lua
--
-- The chip-shop catalog. Each item:
--   • is bought ONCE with Gold Chips (the meta currency)
--   • applies one or more effects via the EffectsRegistry
--   • persists across prestiges forever
--
-- Items are unique — no buying seventeen Teddy Bears. Stacking-style
-- progression lives in data/run_upgrades.lua, where the same item can be
-- bought up to its max_level for compounding effect.
--
-- ─── THE RULE ───────────────────────────────────────────────────────────
-- This is a catalog of OBJECTS FOR A ROOM, sold by the people holding you.
-- Every entry is a thing a department store would ship in a box. Nothing is
-- named after a poker concept. The Poker Poster is the single exception and
-- it is the joke. The same rule governs the page headers in
-- data/catalog_pages.lua — those are store departments, not stat groups.
--
-- ─── Item schema ────────────────────────────────────────────────────────
--   {
--     id          = "snake_case_unique",   -- key in GameState.owned_items
--     name        = "Display Name",
--     effect_text = "Explicit mechanical effect, e.g. '+5% win chance'",
--     description = "Italic flavor blurb under the effect line",
--     sprite      = "sprite_name",          -- looked up via SpriteLoader
--     cost_chip   = number,
--     phase       = "demo" | "mid" | "late" | "system",
--     position    = { x = px, y = px },     -- vestigial; room placement is
--                                           -- data/room_layout.lua
--     effects     = { { kind = "...", value = ... }, ... }
--     -- optional flags:
--     hidden           = bool,    -- never shown in catalog UI
--     granted_at_start = bool,    -- auto-granted at game start
--     removed_by       = "<id>",  -- entry's effects suppressed when remover is owned
--     requires         = "<id>",  -- gate: prerequisite item id
--     requires_hide    = bool,    -- hide from UI until prerequisite owned
--     run0             = bool,    -- scripted-intro entry; stripped when FEATURES.TUTORIAL
--     unlock           = { kind, threshold, text, format? }
--   }
--
-- ─── Writing unlock.text ────────────────────────────────────────────────
-- A locked item wears a COMING SOON sticker whose stock fills as you close
-- the gap. The sticker prints the running count IMMEDIATELY BEFORE this
-- string, on one line, so `text` has to finish the sentence the number
-- starts:
--
--     "tables busted"        renders as   "0 / 100 tables busted"
--     "hands over focus cap" renders as   "0 / 2.5K hands over focus cap"
--
-- So: a lowercase plural noun phrase, no leading number (the counter owns
-- it), no imperative. Icon markers work exactly as they do in effect_text.
--
-- A gate with no meaningful ratio (a flag, like shove_r1_won) prints no
-- counter, so it keeps a standalone imperative: "Win your first shove".
--
-- `format = "money"` switches the counter to dollar formatting. Default is a
-- plain abbreviated count.
--
-- IDS ARE FROZEN. owned_items / corrupted_items serialize ids into player
-- saves that are live on itch. Rename a `name` freely; never an `id`.
--
-- ─── The bands ──────────────────────────────────────────────────────────
-- Costs are tuned so the WHOLE catalog is 800 {chip}, split across the two
-- acts it has to last. A T1-T3 bounty sweep (Act 1's ceiling) banks up to
-- 24 {chip} per run; a T1-T6 sweep banks up to 84.
--
--   A — Act 1 early, T1-T2.        12 items ·  47 {chip} · shove 0.115
--   B — Act 1 late, T2-T3.         14 items · 190 {chip} · shove 0.135
--   C — Act 2, deck era, T4-T6.    15 items · 330 {chip} · shove 0.200
--   D — Act 2 late.                 7 items · 233 {chip} · shove 0.120
--                                            ─────────────────────────────
--                                            800 {chip} · shove 0.570
--
-- Shove total matches docs/math.md's catalog_target(T6) = 0.57, and A+B
-- alone carry 0.250 = catalog_target(T3), so a fully-bought Act 1 catalog
-- is exactly enough to make the first shove winnable. Later items buy
-- capability rather than shove — the "two phases" split in math.md.
--
-- ─── Unlock gates ───────────────────────────────────────────────────────
-- Gates read the ungated total_* counters (see models/catalog_unlock_rules),
-- never the deck-gated lifetime_* ones, so an Act 1 item can actually be
-- unlocked in Act 1. Each gate is the scar the item treats: you bust, then
-- the Rubber Duck shows up.

local Constants = require("data.constants")

local items = {

    -- ─── System: phantom handicap entry ─────────────────────────────────
    -- Auto-granted at game start, neutralized when the Poker Poster is
    -- owned. The diegetic "you don't know how to play poker" Run-0
    -- experience: T1's naked 50% WC is multiplied to ~20% and losses
    -- skew Medium+. Once Poster lands, this entry stops applying — Run 1
    -- onward plays at normal poker math. Hidden from all UI.
    {
        id              = "no_poster_handicap",
        name            = "(handicap)",
        description     = "Active until you receive the Poker Poster.",
        phase           = "system",
        run0            = true,
        hidden          = true,
        granted_at_start = true,
        removed_by      = "poker_poster",
        cost_chip         = 0,
        effects         = {
            -- 0.40× knocks T1's naked 0.50 WC down to ~0.20 — "you don't
            -- know how to play" territory.
            { kind = "wc_mult", value = 0.4 },
            -- 4-tier loss skew: knock mass off Small/Medium, push it onto
            -- Large and Jackpot. Renormalized in buildOutcome.
            { kind = "loss_dist_shift",
              shift = { small = -0.50, medium = -0.30,
                        large = 0.50, jackpot = 0.30 } },
        },
    },

    -- ═══ BAND A — Act 1 early (T1-T2) · 47 {chip} · shove 0.115 ═════════

    -- The only catalog item that names poker directly. The player buys it
    -- for 0 chips from the post-bust catalog modal — buying it is what lifts
    -- the no-poster handicap (via the `removed_by` hook above). Mechanism
    -- is purely the ownership flag; the entry has no direct effects.
    {
        id            = "poker_poster",
        name          = "Poker Poster",
        effect_text   = "Learn the fundamentals.",
        description   = "Do you not even know how to play poker?",
        sprite        = "poker_poster",
        phase         = "demo",
        run0          = true,
        cost_chip       = 0,
        position      = { x = 80, y = 200 },
        effects       = {},
    },
    {
        id          = "branded_hat",
        name        = "Wall Hanger",
        effect_text = "{stack} pays 1.2×.",
        description = "Sturdy wall hook for hanging your hat and gear.",
        sprite      = "branded_hat",
        phase       = "demo",
        cost_chip     = 2,
        position    = { x = 120, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "jackpot_mult",   value = 1.20 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "shove_rate_add", value = 0.15 },
                { kind = "jackpot_mult",   value = 5.00 },
            },
            effect_text = "{stack} pays 5.0×.",
        },
    },
    {
        id          = "mirror",
        name        = "Mirror",
        effect_text = "+10% win chance at Heads-Up.",
        description = "A nice big one. You should see yourself sometimes.",
        sprite      = "mirror",
        phase       = "demo",
        cost_chip     = 3,
        position    = { x = 160, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.10, gtype = "hu" },
        },
    },
    {
        id          = "energy_drink",
        name        = "Energy Drink",
        effect_text = "Hands resolve 25% faster.",
        description = "Tastes terrible. Works fine.",
        sprite      = "energy_drink",
        phase       = "demo",
        cost_chip     = 3,
        position    = { x = 200, y = 220 },
        effects     = {
            { kind = "shove_rate_add",  value = 0.008 },
            { kind = "hand_pace_mult",  value = 1.25 },
        },
    },
    {
        id          = "whiteboard",
        name        = "Whiteboard",
        effect_text = "+5% win chance at all tables.",
        description = "Every room could use a whiteboard.",
        sprite      = "whiteboard",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 240, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.05 },
        },
    },
    {
        id          = "self_help_book",
        name        = "Stack of Books",
        effect_text = "25% chance to boost {small} {arrow} {medium}.",
        description = "Pile of bestselling self-help guides.",
        sprite      = "self_help_book",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 280, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "win_tier_shift",
              from = "small", to = "medium", chance = 0.25 },
        },
    },
    {
        id          = "stress_ball",
        name        = "Throw Pillow",
        effect_text = "25% chance to soften {l:large} {arrow} {l:medium}.",
        description = "Soft plush pillow. Perfect for cushioning rough beats.",
        sprite      = "stress_ball",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 320, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift",
              from = "large", to = "medium", chance = 0.25 },
        },
    },
    {
        id          = "lucky_coin",
        name        = "Starter Gift Box",
        effect_text = "+50% starting bankroll.",
        description = "A wrapped gift box for starting fresh.",
        sprite      = "lucky_coin",
        phase       = "demo",
        cost_chip   = 5,
        position    = { x = 360, y = 220 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.010 },
            { kind = "start_bankroll_pct", value = 0.50 },
        },
    },
    {
        id          = "lava_lamp",
        name        = "Lava Lamp",
        effect_text = "15% chance to boost {medium} {arrow} {large}.",
        description = "Soothing to watch. Hypnotic, almost.",
        sprite      = "lava_lamp",
        phase       = "demo",
        cost_chip   = 5,
        position    = { x = 400, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "win_tier_shift",
              from = "medium", to = "large", chance = 0.15 },
        },
    },
    {
        id          = "worry_stone",
        name        = "Comfort Bed",
        effect_text = "15% chance to soften {l:stack} {arrow} {l:large}.",
        description = "Restful memory-foam bed to sleep off heavy losses.",
        sprite      = "worry_stone",
        phase       = "demo",
        cost_chip     = 5,
        position    = { x = 440, y = 220 },
        -- 4-tier note: spec called this "15% Big loss → Medium". The code's
        -- outcome model has 4 tiers (small/medium/large/jackpot — no Big).
        -- Repointed to Jackpot loss → Large so the catastrophic-loss-
        -- insurance reading is preserved. Pairs with Stress Ball's
        -- large-loss cushion.
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift", from = "jackpot", to = "large", chance = 0.15 },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 3,
            text      = "{l:stack} losses taken",
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "shove_rate_add", value = 0.20 },
                { kind = "loss_tier_shift", from = "jackpot", to = "small", chance = 0.90 },
            },
            effect_text = "90% chance to soften {l:stack} {arrow} {l:small}.",
        },
    },
    {
        id          = "sticky_notes",
        name        = "Yellow Sticky Note",
        effect_text = "Wins pay 25% more.",
        description = "A pad of yellow notes stuck to your desk.",
        sprite      = "sticky_notes",
        phase       = "demo",
        cost_chip   = 8,
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "earnings_mult",  value = 1.25 },
        },
    },
    {
        id          = "rubber_duck",
        name        = "Rubber Duck",
        effect_text = "Your run's first loss is voided.",
        description = "Squeak. It never happened.",
        sprite      = "rubber_duck",
        phase       = "demo",
        cost_chip     = 6,
        position    = { x = 210, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.005 },
            { kind = "void_first_loss" },
        },
        unlock = {
            kind      = "total_busts",
            threshold = 3,
            text      = "tables busted",
        },
    },

    -- ═══ BAND B — Act 1 late (T2-T3) · 190 {chip} · shove 0.135 ═════════

    {
        id          = "pocket_cash",
        name        = "Stash Box",
        effect_text = "+$5 starting bankroll.",
        description = "Folded cash tucked away in a cardboard box.",
        sprite      = "pocket_cash",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 100, y = 300 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.006 },
            { kind = "start_bankroll_add", value = 5 },
        },
    },
    {
        id          = "dogs_playing_poker",
        name        = "Canvas Painting",
        effect_text = "First {chip} bounty each run pays +1.",
        description = "Artistic wall canvas that winks.",
        sprite      = "dogs_playing_poker",
        phase       = "mid",
        cost_chip   = 8,
        position    = { x = 390, y = 400 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.006 },
            { kind = "first_bounty_bonus", value = 1 },
        },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 25,
            text      = "{chip} banked",
        },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "Upgrades are 15% stronger.",
        description = "Solar. Works under the desk lamp.",
        sprite      = "calculator",
        phase       = "mid",
        cost_chip     = 10,
        position    = { x = 180, y = 200 },
        effects     = {
            { kind = "shove_rate_add",            value = 0.006 },
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
    },
    {
        id          = "ring_binder",
        name        = "Ring Binder",
        effect_text = "Upgrades cost 15% less.",
        description = "Three rings, one broken clasp.",
        sprite      = "ring_binder",
        phase       = "mid",
        cost_chip   = 10,
        effects     = {
            { kind = "shove_rate_add",        value = 0.006 },
            { kind = "run_upgrade_cost_mult", value = 0.85 },
        },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 25,
            text      = "upgrade levels bought",
        },
    },
    {
        id          = "headphones",
        name        = "Hanging Towel",
        effect_text = "Losses 20% softer.",
        description = "Soft cotton bath towel. Dries off sweat after a loss.",
        sprite      = "headphones",
        phase       = "mid",
        cost_chip     = 12,
        position    = { x = 280, y = 200 },
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "loss_mult",      value = 0.80 },
        },
        corrupt = {
            cost_achip = 8,
            effects = { { kind = "loss_mult", value = 0.50 } },
            effect_text = "Losses 50% softer.",
        },
    },
    {
        id          = "pen",
        name        = "Pencil Holder",
        effect_text = "+1 {chip} on every bounty.",
        description = "Desk holder with pens. Extra chip on every bounty.",
        sprite      = "pen",
        phase       = "mid",
        cost_chip     = 12,
        position    = { x = 230, y = 200 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.006 },
            { kind = "jackpot_chip_add", value = 1 },
        },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 60,
            text      = "{chip} banked",
        },
    },
    {
        id          = "water_cooler",
        name        = "Water Cooler",
        effect_text = "+6% win chance at 6-max.",
        description = "Gurgles. Everyone ends up standing here.",
        sprite      = "water_cooler",
        phase       = "mid",
        cost_chip   = 14,
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "six_max" },
        },
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "six_max",
            threshold = 2000,
            text      = "hands at 6-max",
        },
    },
    {
        id          = "free_sit",
        name        = "Wooden Door",
        effect_text = "Start each run with 1 table.",
        description = "A solid entry door stamped and countersigned.",
        sprite      = "free_sit",
        phase       = "mid",
        cost_chip     = 14,
        position    = { x = 330, y = 200 },
        effects     = {
            { kind = "shove_rate_add",    value = 0.010 },
            { kind = "start_table_count", value = 1 },
        },
    },
    {
        id          = "punch_card",
        name        = "Rebuy Sticky Note",
        effect_text = "Rebuys cost 25% less.",
        description = "Discount note stuck to your desk.",
        sprite      = "punch_card",
        phase       = "mid",
        cost_chip   = 15,
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "rebuy_discount", value = 0.25 },
        },
        unlock = {
            kind      = "total_rebuys",
            threshold = 50,
            text      = "rebuys",
        },
    },
    {
        id          = "gaming_chair",
        name        = "Gaming Chair",
        effect_text = "Focus penalty halved.",
        description = "Ergonomic. Overload hurts less.",
        sprite      = "gaming_chair",
        phase       = "mid",
        cost_chip     = 15,
        position    = { x = 150, y = 400 },
        effects     = {
            { kind = "shove_rate_add",            value = 0.012 },
            { kind = "focus_penalty_reduce_mult", value = 0.5 },
        },
        unlock = {
            kind      = "total_hands_overwhelmed",
            threshold = 500,
            text      = "hands over focus cap",
        },
    },
    {
        id          = "headset",
        name        = "Headset",
        effect_text = "+6% win chance at Zoom.",
        description = "Foam mic cover. Someone else's earwax.",
        sprite      = "headset",
        phase       = "mid",
        cost_chip   = 16,
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "zoom" },
        },
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 2000,
            text      = "Zoom hands",
        },
    },
    {
        id          = "plastic_trophy",
        name        = "Ceramic Vase",
        effect_text = "Tournament cashes pay 4× / 8× / 20×.",
        description = "Decorative display vase. Handsome on a shelf.",
        sprite      = "plastic_trophy",
        phase       = "mid",
        cost_chip     = 18,
        position    = { x = 350, y = 300 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "mtt_payout_boost", value = 1 },
        },
        unlock = {
            kind      = "total_mtt_wins",
            threshold = 1,
            text      = "tournament wins",
        },
    },
    {
        id          = "fridge",
        name        = "Compact Fridge",
        effect_text = "Your run's first {l:stack} is voided.",
        description = "The cooler. Eats the worst beat.",
        sprite      = "fridge",
        phase       = "mid",
        cost_chip     = 18,
        position    = { x = 270, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "void_first_stack_loss" },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 25,
            text      = "{l:stack} losses taken",
        },
    },
    {
        id          = "wall_clock",
        name        = "Wall Clock",
        effect_text = "3% of hands win outright.",
        description = "The second hand ticks a little loud.",
        sprite      = "wall_clock",
        phase       = "mid",
        cost_chip   = 20,
        effects     = {
            { kind = "shove_rate_add",  value = 0.013 },
            { kind = "auto_win_chance", amount = 0.03 },
        },
        unlock = {
            kind      = "total_hands_played",
            threshold = 5000,
            text      = "hands played",
        },
    },

    -- ═══ BAND C — Act 2, deck era (T4-T6) · 330 {chip} · shove 0.200 ════

    {
        id          = "discount_sits",
        name        = "Rolled Vouchers",
        effect_text = "Buy-ins cost 15% less.",
        description = "Tightly rolled entry coupons.",
        sprite      = "discount_sits",
        phase       = "mid",
        cost_chip     = 14,
        position    = { x = 600, y = 300 },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "buy_in_mult",    value = 0.85 },
        },
    },
    {
        id          = "second_monitor",
        name        = "Second Monitor",
        effect_text = "+1 focus capacity.",
        description = "Mismatched stand. You stop turning your head.",
        sprite      = "second_monitor",
        phase       = "mid",
        cost_chip   = 16,
        effects     = {
            { kind = "shove_rate_add",     value = 0.012 },
            { kind = "focus_capacity_add", value = 1 },
        },
        unlock = {
            kind      = "total_hands_at_4plus",
            threshold = 1000,
            text      = "hands at 4+ tables",
        },
    },
    {
        id            = "first_cursor",
        name          = "Laptop Terminal",
        effect_text   = "+1 cursor. Sealed optical bearings (no trackball cleaning).",
        description   = "Open laptop terminal running extra clicker scripts.",
        sprite        = "first_cursor",
        phase         = "late",
        cost_chip     = 18,
        requires      = "cursor_pool",
        requires_hide = true,
        position      = { x = 200, y = 500 },
        effects       = {
            { kind = "shove_rate_add",        value = 0.010 },
            { kind = "cursor_count_add",      value = 1 },
            { kind = "cursor_optical_sensor" },
        },
    },
    {
        id            = "mouse_pad",
        name          = "Gaming Keyboard",
        effect_text   = "Cursors travel 30% faster & coordinate targeting (no racing).",
        description   = "Mechanical keyboard for faster cursor response.",
        sprite        = "mouse_pad",
        phase         = "late",
        cost_chip     = 18,
        requires      = "cursor_pool",
        requires_hide = true,
        effects       = {
            { kind = "shove_rate_add",       value = 0.010 },
            { kind = "cursor_speed_mult",    value = 1.30 },
            { kind = "cursor_sync_unlocked" },
        },
    },
    {
        id          = "cursor_pool",
        name        = "Box of Mice",
        effect_text = "Unlocks the cursor swarm and the Cursor upgrade.",
        description = "Cardboard storage box of mice.",
        sprite      = "cursor_pool",
        phase       = "late",
        cost_chip     = 20,
        slots       = 3,  -- full-leaf hero card (see data/catalog_pages.lua)
        position    = { x = 100, y = 500 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "cursor_unlocked" },
        },
    },
    {
        id            = "tireless_assistants",
        name          = "Wacom Tablet",
        effect_text   = "Cursors click REBUY & phase through each other without bumping.",
        description   = "Graphics drawing tablet for macro commands.",
        sprite        = "tireless_assistants",
        phase         = "late",
        cost_chip       = 20,
        requires      = "cursor_pool",
        requires_hide = true,
        position      = { x = 300, y = 500 },
        effects       = {
            { kind = "shove_rate_add",          value = 0.012 },
            { kind = "cursor_rebuy_unlocked" },
            { kind = "cursor_collision_phasing" },
        },
    },
    {
        id          = "the_sink",
        name        = "Utility Sink",
        effect_text = "Busted tables refund 30% of the buy-in.",
        description = "It goes down the drain, then comes back up.",
        sprite      = "the_sink",
        phase       = "late",
        cost_chip   = 22,
        effects     = {
            { kind = "shove_rate_add",   value = 0.012 },
            { kind = "bust_refund_pct",  value = 0.30 },
        },
        unlock = {
            kind      = "total_busts",
            threshold = 100,
            text      = "tables busted",
        },
    },
    {
        id          = "toaster",
        name        = "Chrome Toaster",
        effect_text = "8% chance a pot bumps one tier.",
        description = "Two slots. One setting. Pops without warning.",
        sprite      = "toaster",
        phase       = "late",
        cost_chip   = 22,
        effects     = {
            { kind = "shove_rate_add",   value = 0.014 },
            { kind = "tier_bump_chance", value = 0.08 },
        },
        unlock = {
            kind      = "total_jackpots",
            threshold = 250,
            text      = "Jackpots hit",
        },
    },
    {
        id          = "medical_kit",
        name        = "First Aid Kit",
        effect_text = "20% of rebuys are free.",
        description = "Wall-mounted. Break glass, sit back down.",
        sprite      = "medical_kit",
        phase       = "late",
        cost_chip   = 24,
        effects     = {
            { kind = "shove_rate_add",    value = 0.012 },
            { kind = "free_rebuy_chance", value = 0.20 },
        },
        unlock = {
            kind      = "total_rebuys",
            threshold = 250,
            text      = "rebuys",
        },
    },
    {
        id          = "filing_cabinet",
        name        = "Filing Cabinet",
        effect_text = "Upgrades reach one level further.",
        description = "Four drawers. The bottom one sticks.",
        sprite      = "filing_cabinet",
        phase       = "late",
        cost_chip   = 24,
        effects     = {
            { kind = "shove_rate_add",    value = 0.014 },
            { kind = "fill_window_widen", value = 1 },
        },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 150,
            text      = "upgrade levels bought",
        },
    },
    {
        id          = "copy_machine",
        name        = "Copy Machine",
        effect_text = "First denied {chip} each run banks anyway.",
        description = "It just prints another.",
        sprite      = "copy_machine",
        phase       = "late",
        cost_chip     = 26,
        position    = { x = 330, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "copy_first_denied" },
        },
        unlock = {
            kind      = "total_denied_stacks",
            threshold = 10,
            text      = "{chip} denied",
        },
    },
    {
        id          = "microwave",
        name        = "Microwave Oven",
        effect_text = "5% chance a pot pays double.",
        description = "Turntable squeaks. Clock blinks 12:00.",
        sprite      = "microwave",
        phase       = "late",
        cost_chip   = 28,
        effects     = {
            { kind = "shove_rate_add",       value = 0.014 },
            { kind = "payout_double_chance", value = 0.05 },
        },
        unlock = {
            kind      = "total_jackpots",
            threshold = 500,
            text      = "Jackpots hit",
        },
    },
    {
        id          = "engraved_plaque",
        name        = "Framed Diploma",
        effect_text = "Tournament cashes pay 5× / 10× / 20×.",
        description = "Wall-mounted certificate. Handsome on the wall.",
        sprite      = "engraved_plaque",
        phase       = "late",
        cost_chip     = 28,
        requires    = "plastic_trophy",
        position    = { x = 450, y = 400 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.014 },
            { kind = "mtt_payout_boost", value = 2 },
        },
    },
    {
        id          = "study_chart",
        name        = "Laminated Blueprint",
        effect_text = "Active deck earns 50% more XP.",
        description = "Wall blueprint chart for systematic study.",
        sprite      = "study_chart",
        phase       = "late",
        cost_chip   = 30,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "deck_xp_mult",   value = 1.50 },
        },
        unlock = {
            kind      = "decks_unlocked_count",
            threshold = 3,
            text      = "decks unlocked",
        },
    },
    {
        id          = "big_tv",
        name        = "Console Television",
        effect_text = "+2 focus capacity. Wins pay 10% less.",
        description = "Always on. You stop noticing the sound.",
        sprite      = "big_tv",
        phase       = "late",
        cost_chip   = 40,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add",     value = 0.014 },
            { kind = "focus_capacity_add", value = 2 },
            { kind = "earnings_mult",      value = 0.90 },
        },
        unlock = {
            kind      = "total_hands_overwhelmed",
            threshold = 2500,
            text      = "hands over focus cap",
        },
    },

    -- ═══ BAND D — Act 2 late · 233 {chip} · shove 0.120 ═════════════════

    {
        id          = "glass_door",
        name        = "Frosted Glass Door",
        effect_text = "Buy-ins 30% cheaper at NL1K and above.",
        description = "You hear them before they arrive.",
        sprite      = "glass_door",
        phase       = "late",
        cost_chip   = 28,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "buy_in_mult",    value = 0.70, tier_min = 4 },
        },
        unlock = {
            kind      = "highest_stake_idx",
            threshold = 4,
            text      = "stake tiers reached",
        },
    },
    {
        id          = "projector",
        name        = "Projector Screen",
        effect_text = "At NL1K and above, wins skew bigger.",
        description = "Large ceiling projector screen for high-stakes tables.",
        sprite      = "projector",
        phase       = "late",
        cost_chip   = 30,
        effects     = {
            { kind = "shove_rate_add", value = 0.016 },
            { kind = "win_dist_shift",
              shift = { small = -0.10, medium = -0.05, large = 0.08, jackpot = 0.07 },
              tier_min = 4 },
        },
        unlock = {
            kind      = "lifetime_money_won",
            threshold = 50000000,
            text      = "won",
            -- The only dollar-denominated gate in the catalog. Picks the money
            -- formatter for the sticker's counter ("$2.1M / $50.0M") instead of
            -- the plain count one.
            format    = "money",
        },
    },
    {
        id          = "supply_closet",
        name        = "Supply Closet",
        effect_text = "+1 level on every upgrade.",
        description = "Stocked for a building with more people in it.",
        sprite      = "supply_closet",
        phase       = "late",
        cost_chip   = 32,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add",           value = 0.016 },
            { kind = "run_upgrade_bonus_levels", value = 1 },
        },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 300,
            text      = "upgrade levels bought",
        },
    },
    {
        id          = "dishwasher",
        name        = "Portable Dishwasher",
        effect_text = "Start each run with 10% of last run's losses.",
        description = "Runs overnight. Everything comes out clean.",
        sprite      = "dishwasher",
        phase       = "late",
        cost_chip   = 35,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add",   value = 0.016 },
            { kind = "loss_recycle_pct", value = 0.10 },
        },
        unlock = {
            kind = "shove_r1_won",
            text = "Win your first shove",
        },
    },
    {
        id          = "fire_extinguisher",
        name        = "Fire Extinguisher",
        effect_text = "Losses never roll {l:stack}.",
        description = "Inspection tag expired a long time ago.",
        sprite      = "fire_extinguisher",
        phase       = "late",
        cost_chip   = 35,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add",     value = 0.018 },
            { kind = "loss_tier_ceiling",  tier = "large" },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 250,
            text      = "{l:stack} losses taken",
        },
    },
    {
        id          = "bathtub",
        name        = "Claw-Foot Tub",
        effect_text = "Wins never roll {w:small}.",
        description = "Takes an hour to fill. Worth it.",
        sprite      = "bathtub",
        phase       = "late",
        cost_chip   = 36,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add", value = 0.018 },
            { kind = "win_tier_floor", tier = "medium" },
        },
        unlock = {
            kind      = "decks_maxed",
            threshold = 1,
            text      = "decks maxed",
        },
    },
    {
        id          = "tip_jar",
        name        = "Change Teacup",
        effect_text = "{chip} bounties pay 50% more.",
        description = "Small teacup filled with spare coins.",
        sprite      = "tip_jar",
        phase       = "late",
        cost_chip   = 37,
        slots       = 2,  -- feature ad: two slot-units tall
        effects     = {
            { kind = "shove_rate_add",  value = 0.022 },
            { kind = "chip_award_mult", value = 1.50 },
        },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 500,
            text      = "{chip} banked",
        },
    },

    -- ═══ Act 3 — anti-{chip} corruption ═════════════════════════════════

    {
        id          = "unlock_ultra",
        name        = "Ultra Stake",
        effect_text = "Unlock the T10 ULTRA stake.",
        description = "Unwinnable. Bleed bankroll to underflow.",
        sprite      = "unlock_ultra",
        phase       = "late",
        cost_chip     = 0,
        requires_act3 = true,
        effects     = {},
        corrupt = {
            cost_achip = 25,
            effects = { { kind = "ultra_unlock_effect" } },
            effect_text = "Ultra stake unlocked.",
        },
    },

}

-- Under tutorial onboarding the run-0 scripted intro doesn't exist: strip
-- its entries at module load (same feature-flag pattern as
-- data/game_types.lua's MTT_KO swap — the only branch in this file).
-- GameState:computeEffects iterates this catalog, so a live save that
-- owns poker_poster no-ops cleanly once the entry is gone.
if Constants.FEATURES.TUTORIAL then
    for i = #items, 1, -1 do
        if items[i].run0 then table.remove(items, i) end
    end
end

local Balance = require("data.balance")

-- Phase 1 Derivations: scale costs and apply k shove rate from data/balance.lua
for _, item in ipairs(items) do
    if not item.run0 and item.phase ~= "system" and item.id ~= "unlock_ultra" then
        item.authored_cost_chip = item.authored_cost_chip or item.cost_chip
        item.cost_chip = Balance.getItemCost(item.authored_cost_chip)
        
        local found_shove = false
        if item.effects then
            for _, eff in ipairs(item.effects) do
                if eff.kind == "shove_rate_add" then
                    eff.value = Balance.getItemShoveRate(item.id)
                    found_shove = true
                end
            end
        else
            item.effects = {}
        end
        if not found_shove then
            table.insert(item.effects, 1, { kind = "shove_rate_add", value = Balance.getItemShoveRate(item.id) })
        end
    end
end

return items

