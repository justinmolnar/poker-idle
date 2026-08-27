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
--     act              = 2,       -- Act 2+ entry; stripped in the demo build
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

    -- ═══ THE MENTAL GAME ════════════════════════════════════════════════
    -- Not a purchase. Granted at run start and hidden from the book, so
    -- the bad beats are part of the felt rather than something you opt
    -- into. `removed_by` is the hook a future mental-game item hangs on:
    -- one catalog entry with that id and no effects of its own suppresses
    -- every tilt in the game.
    {
        id               = "the_tilt",
        name             = "Tilt",
        effect_text      = "Bad beats rattle the tables around them.",
        description      = "It happens to everyone. It is happening to you.",
        hidden           = true,
        granted_at_start = true,
        phase            = "system",
        cost_chip        = 0,
        effects = {
            { kind = "proc", proc = "miss_tilt"   },
            { kind = "proc", proc = "cooler_tilt" },
        },
    },

    -- ═══ BAND A — Act 1 early (T1-T2) · 47 {chip} · shove 0.115 ═════════

    {
        id          = "wall_hanger",
        name        = "Wall Hanger",
        effect_text = "{stack} pays 1.2×.",
        description = "Sturdy wall hook for hanging your hat and gear.",
        sprite      = "wall_hanger",
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
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "hu" },
            },
            effect_text = "+35% win chance at Heads-Up.",
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
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "hand_pace_mult", value = 4.0 },
            },
            effect_text = "Hands resolve 4× faster.",
        },
    },
    {
        id          = "corkboard",
        name        = "Corkboard",
        effect_text = "+5% win chance at all tables.",
        description = "Pins, notes, one photo of a beach.",
        sprite      = "corkboard",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 240, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.05 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "win_chance_shift", amount = 0.2 },
            },
            effect_text = "+20% win chance at all tables.",
        },
    },
    {
        id          = "stack_of_books",
        name        = "Stack of Books",
        effect_text = "25% chance to boost {small} {arrow} {medium}.",
        description = "Pile of bestselling self-help guides.",
        sprite      = "stack_of_books",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 280, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "win_tier_shift",
              from = "small", to = "medium", chance = 0.25 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "win_tier_shift", from = "small", to = "medium", chance = 0.45 },
            },
            effect_text = "45% chance {small} {arrow} {medium}.",
        },
    },
    {
        id          = "throw_pillow",
        name        = "Throw Pillow",
        effect_text = "25% chance to soften {l:large} {arrow} {l:medium}.",
        description = "Soft plush pillow. Perfect for cushioning rough beats.",
        sprite      = "throw_pillow",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 320, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift",
              from = "large", to = "medium", chance = 0.25 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "loss_tier_shift", from = "large", to = "jackpot", chance = 0.4 },
            },
            effect_text = "40% chance {l:large} {arrow} {l:stack}.",
        },
    },
    {
        id          = "gift_box",
        name        = "Starter Gift Box",
        effect_text = "+50% starting bankroll.",
        description = "A wrapped gift box for starting fresh.",
        sprite      = "gift_box",
        phase       = "demo",
        cost_chip   = 5,
        position    = { x = 360, y = 220 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.010 },
            { kind = "start_bankroll_pct", value = 0.50 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "start_bankroll_pct", value = 25.0 },
            },
            effect_text = "Start with 25× last run's bankroll.",
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
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "win_tier_shift", from = "medium", to = "large", chance = 0.45 },
            },
            effect_text = "45% chance {medium} {arrow} {large}.",
        },
    },
    {
        id          = "comfort_bed",
        name        = "Comfort Bed",
        effect_text = "15% chance to soften {l:stack} {arrow} {l:large}.",
        description = "Restful memory-foam bed to sleep off heavy losses.",
        sprite      = "comfort_bed",
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
            cost_achip = 2,
            effects = {
                { kind = "anti_award_mult", value = 2.0 },
            },
            effect_text = "{l:stack} losses pay {achip} twice.",
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
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "earnings_mult", value = 4.0 },
            },
            effect_text = "Wins pay 4×.",
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
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "loss_tier_shift", from = "small", to = "jackpot", chance = 0.35 },
            },
            effect_text = "35% chance {l:small} {arrow} {l:stack}.",
        },
    },

    -- ═══ BAND B — Act 1 late (T2-T3) · 190 {chip} · shove 0.135 ═════════

    {
        id          = "stash_box",
        name        = "Stash Box",
        effect_text = "+$5 starting bankroll.",
        description = "Folded cash tucked away in a cardboard box.",
        sprite      = "stash_box",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 100, y = 300 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.006 },
            { kind = "start_bankroll_add", value = 5 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "start_bankroll_add", value = 100000 },
            },
            effect_text = "+$100,000 starting bankroll.",
        },
    },
    {
        id          = "dogs_playing_poker",
        name        = "Dogs Playing Poker",
        effect_text = "First {chip} bounty each run pays +1.",
        description = "The one with the bulldog. It winks.",
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
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "first_bounty_bonus", value = 8 },
            },
            effect_text = "First {chip} bounty each run pays +8.",
        },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "Sharper Reads and Pot Control 15% stronger.",
        description = "Solar. Works under the desk lamp.",
        sprite      = "calculator",
        phase       = "mid",
        cost_chip     = 10,
        position    = { x = 180, y = 200 },
        effects     = {
            { kind = "shove_rate_add",            value = 0.006 },
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "run_upgrade_strength_mult", value = 1.5 },
            },
            effect_text = "Sharper Reads and Pot Control 2.5× stronger.",
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
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "run_upgrade_cost_mult", value = 0.2 },
            },
            effect_text = "Upgrades cost 80% less.",
        },
    },
    {
        id          = "space_heater",
        name        = "Space Heater",
        effect_text = "Losses 20% softer.",
        description = "Hums all night. The cold stops mattering.",
        sprite      = "space_heater",
        phase       = "mid",
        cost_chip     = 12,
        position    = { x = 280, y = 200 },
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "loss_mult",      value = 0.80 },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "loss_mult", value = 3.0 },
            },
            effect_text = "Losses 3× bigger.",
        },
    },
    {
        id          = "pencil_holder",
        name        = "Pencil Holder",
        effect_text = "+1 {chip} on every bounty.",
        description = "Desk holder with pens. Extra chip on every bounty.",
        sprite      = "pencil_holder",
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
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "jackpot_chip_add", value = 4 },
            },
            effect_text = "+4 {chip} on every bounty.",
        },
    },
    {
        id          = "desk_plant",
        name        = "Desk Plant",
        effect_text = "+6% win chance at 6-max.",
        description = "Real. Someone waters it when you're not looking.",
        sprite      = "desk_plant",
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
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "six_max" },
            },
            effect_text = "+35% win chance at 6-max.",
        },
    },
    {
        id          = "desk",
        name        = "Desk",
        effect_text = "Start each run with 1 table.",
        description = "Solid wood, one drawer. Somewhere to put things.",
        sprite      = "desk",
        phase       = "mid",
        cost_chip     = 14,
        position    = { x = 330, y = 200 },
        effects     = {
            { kind = "shove_rate_add",    value = 0.010 },
            { kind = "start_table_count", value = 1 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "start_table_count", value = 6 },
            },
            effect_text = "Start each run with 6 tables.",
        },
    },
    {
        id          = "rebuy_note",
        name        = "Rebuy Sticky Note",
        effect_text = "Rebuys cost 25% less.",
        description = "Discount note stuck to your desk.",
        sprite      = "rebuy_note",
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
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "rebuy_discount", value = 0.75 },
            },
            effect_text = "Rebuys cost 75% less.",
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
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "focus_penalty_immune" },
                { kind = "overcap_loss_mult", value = 3.0 },
            },
            effect_text = "No focus penalty. Tables over the cap lose 3× bigger.",
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
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "win_chance_shift", amount = 0.35, gtype = "zoom" },
            },
            effect_text = "+35% win chance at Zoom.",
        },
    },
    {
        id          = "prize_vase",
        name        = "Prize Vase",
        effect_text = "Winning a tournament lifts every table 1% for the run.",
        description = "Came with a ribbon. The ribbon didn't last.",
        sprite      = "prize_vase",
        phase       = "mid",
        cost_chip     = 18,
        position    = { x = 350, y = 300 },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "tourney_ratchet" },
        },
        unlock = {
            kind      = "total_mtt_wins",
            threshold = 1,
            text      = "tournament wins",
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "proc", proc = "tourney_ratchet_corrupt" },
            },
            effect_text = "Winning a tournament lifts every table 3% for the run.",
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
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "first_anti_mult", value = 3.0 },
            },
            effect_text = "First {l:stack} each run pays {achip} 3×.",
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
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "auto_win_chance", amount = 0.25 },
            },
            effect_text = "25% of hands win outright.",
        },
    },

    -- ═══ BAND C — Act 2, deck era (T4-T6) · 330 {chip} · shove 0.200 ════

    {
        id          = "vouchers",
        act         = 2,
        name        = "Rolled Vouchers",
        effect_text = "Buy-ins cost 15% less.",
        description = "Tightly rolled entry coupons.",
        sprite      = "vouchers",
        phase       = "mid",
        cost_chip     = 14,
        position    = { x = 600, y = 300 },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "buy_in_mult",    value = 0.85 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "buy_in_mult", value = 0.3 },
            },
            effect_text = "Buy-ins 70% cheaper.",
        },
    },
    {
        id          = "second_monitor",
        act         = 2,
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
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "focus_capacity_add", value = 4 },
            },
            effect_text = "+4 focus capacity.",
        },
    },
    {
        id            = "laptop",
        act         = 2,
        name          = "Laptop Terminal",
        effect_text   = "+1 cursor. Sealed optical bearings (no trackball cleaning).",
        description   = "Open laptop terminal running extra clicker scripts.",
        sprite        = "laptop",
        phase         = "late",
        cost_chip     = 18,
        requires      = "box_of_mice",
        requires_hide = true,
        position      = { x = 200, y = 500 },
        effects       = {
            { kind = "shove_rate_add",        value = 0.010 },
            { kind = "cursor_count_add",      value = 1 },
            { kind = "cursor_optical_sensor" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_count_add", value = 4 },
                { kind = "cursor_optical_sensor" },
            },
            effect_text = "+4 cursors.",
        },
    },
    {
        id            = "gaming_keyboard",
        act         = 2,
        name          = "Gaming Keyboard",
        effect_text   = "Cursors travel 30% faster & coordinate targeting (no racing).",
        description   = "Mechanical keyboard for faster cursor response.",
        sprite        = "gaming_keyboard",
        phase         = "late",
        cost_chip     = 18,
        requires      = "box_of_mice",
        requires_hide = true,
        effects       = {
            { kind = "shove_rate_add",       value = 0.010 },
            { kind = "cursor_speed_mult",    value = 1.30 },
            { kind = "cursor_sync_unlocked" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_instant_click" },
                { kind = "cursor_sync_unlocked" },
            },
            effect_text = "Cursors click instantly and coordinate.",
        },
    },
    {
        id          = "box_of_mice",
        act         = 2,
        name        = "Box of Mice",
        effect_text = "Unlocks the cursor swarm and the Cursor upgrade.",
        description = "Cardboard storage box of mice.",
        sprite      = "box_of_mice",
        phase       = "late",
        cost_chip     = 20,
        slots       = 3,  -- full-leaf hero card (see data/catalog_pages.lua)
        position    = { x = 100, y = 500 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "cursor_unlocked" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "cursor_unlocked" },
                { kind = "cursor_count_add", value = 8 },
            },
            effect_text = "+8 cursors.",
        },
    },
    {
        id            = "wacom_tablet",
        act         = 2,
        name          = "Wacom Tablet",
        effect_text   = "Cursors click REBUY & phase through each other without bumping.",
        description   = "Graphics drawing tablet for macro commands.",
        sprite        = "wacom_tablet",
        phase         = "late",
        cost_chip       = 20,
        requires      = "box_of_mice",
        requires_hide = true,
        position      = { x = 300, y = 500 },
        effects       = {
            { kind = "shove_rate_add",          value = 0.012 },
            { kind = "cursor_rebuy_unlocked" },
            { kind = "cursor_collision_phasing" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "cursor_rebuy_unlocked" },
                { kind = "cursor_collision_phasing" },
                { kind = "cursor_sync_unlocked" },
                { kind = "cursor_instant_click" },
            },
            effect_text = "Cursors rebuy, phase, sync and click instantly.",
        },
    },
    {
        id          = "kettle",
        act         = 2,
        name        = "Electric Kettle",
        effect_text = "Busted tables refund 30% of the buy-in.",
        description = "First thing you asked for. Took a while.",
        sprite      = "kettle",
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
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "bust_refund_pct", value = 1.2 },
            },
            effect_text = "Busted tables refund 120% of the buy-in.",
        },
    },
    {
        id          = "toaster",
        act         = 2,
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
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "tier_bump_chance", value = 0.35 },
            },
            effect_text = "35% chance a pot bumps one tier.",
        },
    },
    {
        id          = "first_aid_kit",
        act         = 2,
        name        = "First Aid Kit",
        effect_text = "20% of rebuys are free.",
        description = "Wall-mounted. Break glass, sit back down.",
        sprite      = "first_aid_kit",
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
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "free_rebuy_chance", value = 0.6 },
            },
            effect_text = "60% of rebuys are free.",
        },
    },
    {
        id          = "nightstand",
        act         = 2,
        name        = "Nightstand",
        effect_text = "Upgrades reach one level further.",
        description = "One drawer that's yours. Nobody checks it.",
        sprite      = "nightstand",
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
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "fill_window_widen", value = 4 },
            },
            effect_text = "Upgrades reach 4 levels further.",
        },
    },
    {
        id          = "receipt_printer",
        name        = "Receipt Printer",
        effect_text = "Win a {stack} and every Zoom table settles at once.",
        description = "Chatters out a slip for every table. Feed it more paper.",
        sprite      = "receipt_printer",
        phase       = "demo",
        cost_chip     = 2,
        position    = { x = 330, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "cascade_on_jackpot" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "cascade_on_jackpot" },
            },
            effect_text = "Win a {stack} and every Zoom table settles at once.",
        },
    },
    {
        id          = "microwave",
        act         = 2,
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
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "payout_double_chance", value = 0.45 },
            },
            effect_text = "45% chance a pot pays double.",
        },
    },
    {
        id          = "diploma",
        act         = 2,
        name        = "Framed Diploma",
        effect_text = "Tournament cashes pay 5× / 10× / 20×.",
        description = "Wall-mounted certificate. Handsome on the wall.",
        sprite      = "diploma",
        phase       = "late",
        cost_chip     = 28,
        requires    = "prize_vase",
        position    = { x = 450, y = 400 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.014 },
            { kind = "mtt_payout_boost", value = 2 },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "mtt_payout_boost", value = 4 },
            },
            effect_text = "Tournament cashes pay 40× / 80× / 160×.",
        },
    },
    {
        id          = "blueprint",
        act         = 2,
        name        = "Laminated Blueprint",
        effect_text = "Active deck earns 50% more XP.",
        description = "Wall blueprint chart for systematic study.",
        sprite      = "blueprint",
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
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "deck_xp_mult", value = 8.0 },
            },
            effect_text = "Active deck earns 8× XP.",
        },
    },
    {
        id          = "console_tv",
        act         = 2,
        name        = "Console Television",
        effect_text = "+2 focus capacity. Wins pay 10% less.",
        description = "Always on. You stop noticing the sound.",
        sprite      = "console_tv",
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
        corrupt = {
            cost_achip = 13,
            effects = {
                { kind = "focus_capacity_add", value = 10 },
                { kind = "earnings_mult", value = 0.5 },
            },
            effect_text = "+10 focus. Wins pay 50% less.",
        },
    },

    -- ═══ BAND D — Act 2 late · 233 {chip} · shove 0.120 ═════════════════

    {
        id          = "high_roller_pass",
        act         = 2,
        name        = "High Roller Pass",
        effect_text = "Buy-ins 30% cheaper at NL1K and above.",
        description = "Framed. You never had to show it to anyone.",
        sprite      = "high_roller_pass",
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
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "buy_in_mult", value = 0.1, tier_min = 4 },
            },
            effect_text = "Buy-ins 90% cheaper at NL1K and above.",
        },
    },
    {
        id          = "window",
        act         = 2,
        name        = "Window",
        effect_text = "At NL1K and above, wins skew bigger.",
        description = "Faces a wall. It's the light you wanted.",
        sprite      = "window",
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
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "win_dist_shift", shift = { small = -0.4, jackpot = 0.4 }, tier_min = 4 },
            },
            effect_text = "At NL1K and above, 40% more wins land as {w:stack}.",
        },
    },
    {
        id          = "bookshelf",
        act         = 2,
        name        = "Bookshelf",
        effect_text = "+1 level on every upgrade.",
        description = "Every book on it is about the same thing.",
        sprite      = "bookshelf",
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
        corrupt = {
            cost_achip = 11,
            effects = {
                { kind = "run_upgrade_bonus_levels", value = 4 },
            },
            effect_text = "+4 levels on every upgrade.",
        },
    },
    {
        id          = "cereal_shelf",
        act         = 2,
        name        = "Cereal Shelf",
        effect_text = "Start each run with 10% of last run's losses.",
        description = "Restocked from somewhere. Never the same brand.",
        sprite      = "cereal_shelf",
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
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "loss_recycle_pct", value = 0.75 },
            },
            effect_text = "Start with 75% of last run's losses.",
        },
    },
    {
        id          = "fire_extinguisher",
        act         = 2,
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
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "loss_dist_shift", shift = { small = -0.5, jackpot = 0.5 } },
            },
            effect_text = "Half of all losses roll {l:stack}.",
        },
    },
    {
        id          = "blackout_curtains",
        act         = 2,
        name        = "Blackout Curtains",
        effect_text = "Wins never roll {w:small}.",
        description = "No window behind them. Still helps.",
        sprite      = "blackout_curtains",
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
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "earnings_per_tier", value = 0.5 },
            },
            effect_text = "Wins pay +50% more per stake tier.",
        },
    },
    {
        id          = "tip_jar",
        act         = 2,
        name        = "Tip Jar",
        effect_text = "{chip} bounties pay 50% more.",
        description = "Coins in a glass. Yours, mostly.",
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
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "chip_award_mult", value = 4.0 },
            },
            effect_text = "{chip} bounties pay 4×.",
        },
    },

    -- ═══ Act 3 — anti-{chip} corruption ═════════════════════════════════

    {
        id          = "pc_tower",
        act         = 2,
        name        = "Tower Upgrade",
        effect_text = "Knockouts have a 15% chance to mark a nearby table's next pot for a tier bump.",
        description = "Fans you can hear from the bed. Boots in seconds.",
        sprite      = "pc_tower",
        phase       = "mid",
        cost_chip   = 12,
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "ko_bump" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc", proc = "ko_bump_corrupt" },
                -- It bumps pot tiers, so corruption bumps loss tiers back.
                { kind = "loss_tier_shift", from = "medium", to = "large",
                  chance = 0.35 },
            },
            effect_text = "Knockouts have a 25% chance to mark every nearby table. Losses run a tier bigger.",
        },
    },
    {
        id          = "curved_monitor",
        act         = 2,
        name        = "Curved Monitor",
        effect_text = "Knockouts have a 20% chance to heat a nearby table 6 seconds.",
        description = "Wraps around you. The room gets smaller.",
        sprite      = "curved_monitor",
        phase       = "mid",
        cost_chip   = 20,
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "proc", proc = "ko_heater" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "proc",      proc = "ko_heater_corrupt" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Knockouts have a 30% chance to heat every nearby table. Losses 50% heavier.",
        },
    },
    {
        id          = "desk_speakers",
        act         = 2,
        name        = "Desk Speakers",
        effect_text = "+5% win chance at tournaments.",
        description = "Two small ones. The bass is all wall.",
        sprite      = "desk_speakers",
        phase       = "mid",
        cost_chip   = 16,
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.05, gtype = "mtt" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "win_chance_shift", amount = 0.30, gtype = "mtt" },
                { kind = "win_chance_shift", amount = -0.10, gtype = "six_max" },
            },
            effect_text = "+30% win chance at tournaments. -10% at 6-max.",
        },
    },
    {
        id          = "shredder",
        act         = 2,
        name        = "Shredder",
        effect_text = "Knockouts have a 12% chance to refund a nearby buy-in.",
        description = "Under the desk. Takes the bad ones.",
        sprite      = "shredder",
        phase       = "late",
        cost_chip   = 26,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "ko_refund" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc",          proc = "ko_refund_corrupt" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Knockouts have a 25% chance to refund a nearby buy-in. Wins pay 30% less.",
        },
    },
    {
        id          = "unlock_ultra",
        act         = 2,
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

-- The demo ends at the Act 1 cliffhanger: Act 2+ entries (bands C and
-- D, the Act 3 section) are stripped at module load — the only branch
-- in this file. GameState:computeEffects iterates this catalog, so a
-- live save that owns one of them no-ops cleanly here while
-- owned_items keeps the purchase for the full build.
if Constants.FEATURES.DEMO_CUT then
    for i = #items, 1, -1 do
        if items[i].act == 2 or items[i].requires_act3 then table.remove(items, i) end
    end
end

local Balance = require("data.balance")

-- Phase 1 Derivations: scale costs and apply k shove rate from data/balance.lua
for _, item in ipairs(items) do
    if item.phase ~= "system" and item.id ~= "unlock_ultra" then
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
        -- A corrupt block REPLACES the item's effects (GameState:computeEffects),
        -- so one without a shove_rate_add would strip the item's shove base.
        -- Give it the item's own unless the block authored a value.
        if item.corrupt and item.corrupt.effects then
            local has = false
            for _, eff in ipairs(item.corrupt.effects) do
                if eff.kind == "shove_rate_add" then has = true end
            end
            if not has then
                table.insert(item.corrupt.effects, 1,
                    { kind = "shove_rate_add", value = Balance.getItemShoveRate(item.id) })
            end
        end
    end
end

return items

