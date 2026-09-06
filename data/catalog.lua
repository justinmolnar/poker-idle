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
--     requires         = "<id>",  -- gate: prerequisite item id. NEVER hidden:
--                                 -- a chain member is always visible, wearing
--                                 -- the COMING SOON sticker with its "after
--                                 -- No. NNN, the X" line — visible-but-locked
--                                 -- is the game's promise pattern. (The old
--                                 -- requires_hide flag is retired; the modal
--                                 -- still honors it if data ever sets it.)
--     act              = 2,       -- Act 2+ entry; stripped in the demo build
--     unlock           = { kind, threshold, text, format?, mystery? }
--                        mystery = a condition table (same kinds): until it
--                        passes, the sticker prints "???" instead of the
--                        text+counter — the card is never hidden, but a gate
--                        whose WORDS would introduce an unmet mechanic stays
--                        unspeakable ("0/5 tables tilted" is a tilt spoiler).
--     house_line       = "...",   -- optional: what the House says when the
--                                 -- item is clicked in the room (one line,
--                                 -- the band, never recorded). None yet.
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
--   A — Act 1 early, T1-T2.        12 items ·  47 {chip} · shove 0.12
--   B — Act 1 late, T2-T3.         21 items · 176 {chip} · shove 0.21
--   C — Act 2, deck era, T4-T6.    23 items · 330 {chip} · shove 0.23
--   D — Act 2 late.                11 items · 233 {chip} · shove 0.11
--                                            ─────────────────────────────
--                                            786 {chip} · shove 0.67
--
-- Shove is a flat 1% per item (data/balance.lua K_SHOVE_PER_ITEM), so a
-- band's shove is its item count. A+B alone carry 0.33 ≥ the 0.250 the
-- first shove needs at T3, so a fully-bought Act 1 catalog wins it with
-- room to spare. Later items buy capability rather than shove.
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
        id               = "tilt",
        name             = "Tilt",
        effect_text      = "Bad beats rattle the tables around them.",
        description      = "Happens at every table sooner or later.",
        hidden           = true,
        granted_at_start = true,
        phase            = "system",
        cost_chip        = 0,
        effects = {
            { kind = "proc", proc = "tilt_miss"   },
            { kind = "proc", proc = "tilt_cooler" },
        },
    },

    -- ═══ BAND A — Act 1 early (T1-T2) · 12 items · 47 {chip} ════════════

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
            { kind = "stack_mult",   value = 1.20 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "shove_rate_add", value = 0.15 },
                { kind = "stack_mult",   value = 5.00 },
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
        -- Page one's prerequisite teacher: the blue "SEE No. 001" slip,
        -- resolved by the 2-{chip} first purchase — never a wall, and it
        -- keeps the first post-shove catalog down to ONE ready-to-peel
        -- (the Gift Box). The old hu_unlocked gate was long-met by then.
        requires    = "wall_hanger",
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
        -- The {chip} economy's signpost: appears the moment the first
        -- bounty banks, and says out loud what the numbers already made
        -- true — Heads-Up is the chip mode.
        id          = "fight_night_poster",
        name        = "Fight Night Poster",
        effect_text = "Heads-Up {c:chip:bounties} pay double {chip}.",
        description = "A duel draws a crowd. The crowd pays.",
        sprite      = "fight_night_poster",
        phase       = "demo",
        cost_chip   = 4,
        unlock = {
            kind      = "lifetime_chips_banked",
            threshold = 1,
            text      = "{chip} {c:chip:banked}",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "bounty_gtype_mult", gtype = "hu", value = 2.0 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "bounty_gtype_mult", gtype = "hu", value = 4.0 },
            },
            effect_text = "Heads-Up {c:chip:bounties} pay quadruple {chip}.",
        },
    },
    {
        -- THE ZOOM ITEM, and the first heater the player ever sees. A
        -- global hand counter that lands its heater on a Zoom table: Zoom deals
        -- 25 hands in a minute where a 6-max takes ten, so the lesson is that Zoom is
        -- volume and volume feeds the rest of the board. Heat itself is
        -- taught by the House the first time any table catches it (story:
        -- first_heat). Tuned by the proc's `every`, nothing else.
        id          = "energy_drink",
        name        = "Energy Drink",
        effect_text = "Every 25 hands, a Zoom table catches a {c:heat:heater}.",
        description = "Tastes terrible. Works fine.",
        sprite      = "energy_drink",
        phase       = "demo",
        cost_chip     = 3,
        position    = { x = 200, y = 220 },
        effects     = {
            { kind = "shove_rate_add",  value = 0.008 },
            { kind = "proc", proc = "energy_drink_caffeine" },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "proc", proc = "energy_drink_caffeine_corrupt" },
            },
            effect_text = "Every 10 hands, a Zoom table catches a {c:heat:heater}.",
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
        unlock = {
            kind      = "total_hands_won",
            threshold = 250,
            text      = "hands won",
        },
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
        unlock = {
            kind      = "total_stack_losses",
            threshold = 1,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift",
              from = "large", to = "medium", chance = 0.25 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "loss_tier_shift", from = "large", to = "stack", chance = 0.4 },
            },
            effect_text = "40% chance {l:large} {arrow} {l:stack}.",
        },
    },
    {
        id          = "starter_gift_box",
        name        = "Starter Gift Box",
        effect_text = "+50% starting bankroll.",
        description = "A wrapped gift box for starting fresh.",
        sprite      = "starter_gift_box",
        phase       = "demo",
        cost_chip   = 4,
        position    = { x = 360, y = 220 },
        unlock = {
            kind      = "has_shoved",
            text      = "Make your first shove",
        },
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
        description = "Restful memory-foam bed to sleep off heavy {c:lost:losses}.",
        sprite      = "comfort_bed",
        phase       = "demo",
        cost_chip     = 4,
        position    = { x = 440, y = 220 },
        -- 4-tier note: spec called this "15% Big loss → Medium". The code's
        -- outcome model has 4 tiers (small/medium/large/stack — no Big).
        -- Repointed to Stack loss → Large so the catastrophic-loss-
        -- insurance reading is preserved. Pairs with Stress Ball's
        -- large-loss cushion.
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "loss_tier_shift", from = "stack", to = "large", chance = 0.15 },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 110,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "anti_award_mult", value = 2.0 },
            },
            effect_text = "{l:stack} {c:lost:losses} pay {achip} twice.",
        },
    },
    {
        id          = "yellow_sticky_note",
        name        = "Yellow Sticky Note",
        effect_text = "{c:won:Wins} pay 25% more.",
        description = "A pad of yellow notes. Sticks to anything.",
        sprite      = "yellow_sticky_note",
        phase       = "demo",
        cost_chip   = 5,
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "earnings_mult",  value = 1.25 },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "earnings_mult", value = 4.0 },
            },
            effect_text = "{c:won:Wins} pay 4×.",
        },
    },
    {
        id          = "rubber_duck",
        name        = "Rubber Duck",
        effect_text = "Your run's first loss is voided.",
        description = "Squeak. It never happened.",
        sprite      = "rubber_duck",
        phase       = "demo",
        cost_chip     = 5,
        position    = { x = 210, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.005 },
            { kind = "void_first_loss" },
        },
        unlock = {
            kind      = "total_busts",
            threshold = 100,
            text      = "tables {c:lost:busted}",
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "loss_tier_shift", from = "small", to = "stack", chance = 0.35 },
            },
            effect_text = "35% chance {l:small} {arrow} {l:stack}.",
        },
    },

    -- ═══ BAND B — Act 1 late (T2-T3) · 21 items · 190 {chip} ════════════

    {
        id          = "stash_box",
        name        = "Stash Box",
        effect_text = "+$5 starting bankroll.",
        description = "Folded cash tucked away in a cardboard box.",
        sprite      = "stash_box",
        phase       = "mid",
        cost_chip     = 6,
        position    = { x = 100, y = 300 },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 10,
            text      = "{chip} {c:chip:banked}",
        },
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
        effect_text = "Winning a {stack}: 25% chance that table catches a {c:heat:heater}.",
        description = "The one with the bulldog. It winks.",
        sprite      = "dogs_playing_poker",
        phase       = "mid",
        cost_chip   = 6,
        unlock = {
            kind      = "total_chips_banked",
            threshold = 25,
            text      = "{chip} {c:chip:banked}",
        },
        position    = { x = 390, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.006 },
            { kind = "proc", proc = "dogs_playing_poker_high" },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "proc", proc = "dogs_playing_poker_high_corrupt" },
            },
            effect_text = "Winning a {stack}: 35% chance that table catches a {c:heat:heater}.",
        },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "{c:upgrade:Sharper_Reads} and {c:upgrade:Pot_Control} 15% stronger.",
        description = "Solar. Works under the desk lamp.",
        sprite      = "calculator",
        phase       = "mid",
        cost_chip     = 7,
        position    = { x = 180, y = 200 },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 130,
            text      = "{c:upgrade:upgrade} levels bought",
        },
        effects     = {
            { kind = "shove_rate_add",            value = 0.006 },
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "run_upgrade_strength_mult", value = 1.5 },
            },
            effect_text = "{c:upgrade:Sharper_Reads} and {c:upgrade:Pot_Control} 2.5× stronger.",
        },
    },
    {
        id          = "ring_binder",
        name        = "Ring Binder",
        effect_text = "{c:upgrade:Upgrades} cost 15% less.",
        description = "Three rings, one broken clasp.",
        sprite      = "ring_binder",
        phase       = "mid",
        cost_chip   = 7,
        effects     = {
            { kind = "shove_rate_add",        value = 0.006 },
            { kind = "run_upgrade_cost_mult", value = 0.85 },
        },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 90,
            text      = "{c:upgrade:upgrade} levels bought",
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "run_upgrade_cost_mult", value = 0.2 },
            },
            effect_text = "{c:upgrade:Upgrades} cost 80% less.",
        },
    },
    {
        id          = "space_heater",
        name        = "Space Heater",
        effect_text = "{c:lost:Losses} 20% softer.",
        description = "Hums all night. The cold stops mattering.",
        sprite      = "space_heater",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 280, y = 200 },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 225,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.008 },
            { kind = "loss_mult",      value = 0.80 },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "loss_mult", value = 3.0 },
            },
            effect_text = "{c:lost:Losses} 3× bigger.",
        },
    },
    {
        id          = "pencil_holder",
        name        = "Pencil Holder",
        effect_text = "+1 {chip} on every {c:chip:bounty}.",
        description = "Desk holder with pens. Extra chip on every {c:chip:bounty}.",
        sprite      = "pencil_holder",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 230, y = 200 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.006 },
            { kind = "stack_chip_add", value = 1 },
        },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 150,
            text      = "{chip} {c:chip:banked}",
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "stack_chip_add", value = 4 },
            },
            effect_text = "+4 {chip} on every {c:chip:bounty}.",
        },
    },
    {
        -- THE KEY TO 6-MAX. Owning it latches state.six_max_unlocked (the
        -- ultra_unlocked pattern): the mode is a purchase, and the door is
        -- the whole reward. No rider on purpose — the room's identity is
        -- the slow, deep table itself, and what other items land on it.
        id          = "bonsai",
        name        = "Bonsai",
        effect_text = "Opens the 6-Max tables, the deep game.",
        description = "Grown slow on purpose. Worth the wait.",
        sprite      = "bonsai",
        phase       = "mid",
        cost_chip   = 10,
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "six_max_unlocked" },
        },
        unlock = {
            -- A whole game type is a mid-act MILESTONE, not a day-one key:
            -- the game only ever sells two rooms. ~75 banked lands around
            -- run five, so the Den spread opens genuinely mid-game.
            kind      = "total_chips_banked",
            threshold = 75,
            text      = "{chip} {c:chip:banked}",
            -- "???" until the pitch has named the door economy
            mystery   = { kind = "total_chips_banked", threshold = 3 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "six_max_unlocked" },
            },
            effect_text = "Opens the 6-Max tables.",
        },
    },
    {
        id          = "desk_plant",
        name        = "Desk Plant",
        effect_text = "+6% win chance at 6-max.",
        description = "Real. Someone waters it when you're not looking.",
        sprite      = "desk_plant",
        phase       = "mid",
        cost_chip   = 8,
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "six_max" },
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
        cost_chip     = 9,
        position    = { x = 330, y = 200 },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 70,
            text      = "{c:upgrade:upgrade} levels bought",
        },
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
        id          = "rebuy_sticky_note",
        name        = "Rebuy Sticky Note",
        effect_text = "Rebuys cost 25% less.",
        description = "Discount coupon pad. Sticks where you'll see it.",
        sprite      = "rebuy_sticky_note",
        phase       = "mid",
        cost_chip   = 10,
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "rebuy_discount", value = 0.25 },
        },
        unlock = {
            kind      = "total_rebuys",
            threshold = 300,
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
        effect_text = "Winning a {stack}: 30% chance a nearby table catches a {c:heat:heater}.",
        description = "Ergonomic. Overload hurts less.",
        sprite      = "gaming_chair",
        phase       = "mid",
        cost_chip     = 10,
        unlock = {
            kind      = "total_hands_overwhelmed",
            threshold = 25,
            text      = "hands past focus",
        },
        position    = { x = 150, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "proc", proc = "gaming_chair_spread" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc",      proc = "gaming_chair_spread" },
                { kind = "loss_mult", value = 1.4 },
            },
            effect_text = "Winning a {stack}: 30% chance a nearby table catches a {c:heat:heater}. {c:lost:Losses} 40% heavier.",
        },
    },
    {
        id          = "headset",
        name        = "Headset",
        effect_text = "+6% win chance at Zoom.",
        description = "Foam mic cover. Someone else's earwax.",
        sprite      = "headset",
        phase       = "mid",
        cost_chip   = 6,
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.06, gtype = "zoom" },
        },
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 2600,
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
        -- Tournaments open with Act 2 (C.GTYPE_GATE.ko = shove_r1_won);
        -- act = 2 keeps this out of the Act 1 book instead of sitting there
        -- as a "???" the demo can never open.
        act         = 2,
        name        = "Prize Vase",
        effect_text = "Winning a tournament lifts every table 1% for the run.",
        description = "Came with a ribbon. The ribbon didn't last.",
        sprite      = "prize_vase",
        phase       = "mid",
        cost_chip     = 12,
        unlock = {
            kind      = "total_ko_wins",
            threshold = 1,
            text      = "tournament {c:won:wins}",
            -- "???" until they've actually sat in a tournament
            mystery   = { kind = "total_hands_at_gtype", gtype = "ko", threshold = 1 },
        },
        position    = { x = 350, y = 300 },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "prize_vase_ratchet" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "proc", proc = "prize_vase_ratchet_corrupt" },
            },
            effect_text = "Winning a tournament lifts every table 3% for the run.",
        },
    },
    {
        id          = "compact_fridge",
        name        = "Compact Fridge",
        effect_text = "Your run's first {l:stack} is voided.",
        description = "The cooler. Eats the worst beat.",
        sprite      = "compact_fridge",
        phase       = "mid",
        cost_chip     = 12,
        position    = { x = 270, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "void_first_stack_loss" },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 450,
            text      = "{l:stack} {c:lost:losses} taken",
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
        effect_text = "Every 100 hands won, a random table catches a {c:heat:heater}.",
        description = "The second hand ticks a little loud.",
        sprite      = "wall_clock",
        phase       = "mid",
        cost_chip   = 12,
        unlock = {
            kind      = "total_hands_played",
            threshold = 7000,
            text      = "hands played",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.013 },
            { kind = "proc", proc = "wall_clock_century" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "proc",      proc = "wall_clock_century" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Every 100 hands won, a random table catches a {c:heat:heater}. {c:lost:Losses} 50% heavier.",
        },
    },

    {
        id          = "house_cat",
        name        = "House Cat",
        effect_text = "Every 50 hands won, a table's next win reads a tier higher.",
        description = "Someone's cat. It has opinions.",
        sprite      = "house_cat",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_hands_won",
            threshold = 2900,
            text      = "hands won",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "house_cat_nap" },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "proc", proc = "house_cat_nap_corrupt" },
            },
            effect_text = "Every 25 hands won, a table's next win reads a tier higher.",
        },
    },
    {
        id          = "candle",
        name        = "Candle",
        effect_text = "Winning a {stack}: 25% chance a random table catches a {c:heat:heater}.",
        description = "One wick. Surprising reach.",
        sprite      = "candle",
        phase       = "mid",
        cost_chip   = 7,
        -- Stacks land ~155 per shove (measured from a real save at
        -- shove five: 775 stacks), so stack thresholds are per-shove
        -- rates, not "rare event" counts. 600 ≈ shove four.
        unlock = {
            kind      = "total_stacks",
            threshold = 600,
            text      = "{stack} {c:won:wins}",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "candle_flame" },
        },
    },
    {
        id          = "dusty_console",
        name        = "Dusty Console",
        effect_text = "+3% win chance at Heads-Up tables.",
        description = "Two controllers. Built for one-on-one.",
        sprite      = "dusty_console",
        phase       = "mid",
        cost_chip   = 5,
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "hu",
            threshold = 1000,
            text      = "Heads-Up hands",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "win_chance_shift", amount = 0.03, gtype = "hu" },
        },
    },
    {
        id          = "handheld",
        name        = "Handheld",
        effect_text = "+3% win chance at Zoom tables.",
        description = "Fits in a pocket. Fast games between fast games.",
        sprite      = "handheld",
        phase       = "mid",
        cost_chip   = 5,
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 1200,
            text      = "Zoom hands",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "win_chance_shift", amount = 0.03, gtype = "zoom" },
        },
    },
    {
        id          = "red_rug",
        name        = "Red Rug",
        effect_text = "The table in the board's top-left corner plays on the rug: +2% win chance.",
        description = "Really ties the room together.",
        sprite      = "red_rug",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_hands_played",
            threshold = 6500,
            text      = "hands played",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "corner_win_chance", value = 0.02 },
        },
    },
    {
        id          = "dish_soap",
        name        = "Dish Soap",
        effect_text = "A {c:tilt:tilt} has a 25% chance to land on the table beside its target instead.",
        description = "Cuts through anything.",
        sprite      = "dish_soap",
        phase       = "mid",
        cost_chip   = 12,
        unlock = {
            kind      = "total_tilts",
            threshold = 90,
            text      = "tables {c:tilt:tilted}",
            -- "???" until tilt exists in this player's game
            mystery   = { kind = "total_tilts", threshold = 1 },
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "router", router = "dish_soap_deflect" },
        },
    },
    -- ═══ BAND C — Act 2, deck era (T4-T6) · 23 items · 330 {chip} ═══════

    {
        id          = "rolled_vouchers",
        act         = 2,
        name        = "Rolled Vouchers",
        effect_text = "The first table you open at a stake catches {c:heat:heat}.",
        description = "Tightly rolled entry coupons.",
        sprite      = "rolled_vouchers",
        phase       = "mid",
        cost_chip     = 9,
        position    = { x = 600, y = 300 },
        unlock = {
            kind      = "total_busts",
            threshold = 275,
            text      = "tables {c:lost:busted}",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "rolled_vouchers_arrival" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc", proc = "rolled_vouchers_arrival_corrupt" },
            },
            effect_text = "Every table you open catches {c:heat:heat}.",
        },
    },
    {
        id          = "second_monitor",
        act         = 2,
        name        = "Second Monitor",
        effect_text = "+2 focus capacity.",
        description = "Mismatched stand. You stop turning your head.",
        sprite      = "second_monitor",
        phase       = "mid",
        cost_chip   = 10,
        effects     = {
            { kind = "shove_rate_add",     value = 0.012 },
            { kind = "focus_capacity_add", value = 2 },
        },
        unlock = {
            kind      = "total_hands_at_4plus",
            threshold = 4000,
            text      = "hands at 4+ tables",
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "focus_capacity_add", value = 6 },
            },
            effect_text = "+6 focus capacity.",
        },
    },
    {
        id            = "laptop_terminal",
        act         = 2,
        name          = "Laptop Terminal",
        effect_text   = "+1 {c:upgrade:cursor}.",
        description   = "Open laptop terminal running extra clicker scripts.",
        sprite        = "laptop_terminal",
        phase         = "late",
        cost_chip     = 12,
        requires    = "box_of_mice",
        position      = { x = 200, y = 500 },
        effects       = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "cursor_count_add", value = 1 },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_count_add", value = 4 },
            },
            effect_text = "+4 {c:upgrade:cursors}.",
        },
    },
    {
        id            = "gaming_keyboard",
        act         = 2,
        name          = "Gaming Keyboard",
        effect_text   = "{c:upgrade:Cursors} travel 30% faster.",
        description   = "Mechanical keyboard for faster {c:upgrade:cursor} response.",
        sprite        = "gaming_keyboard",
        phase         = "late",
        cost_chip     = 12,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 1000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add",    value = 0.010 },
            { kind = "cursor_speed_mult", value = 1.30 },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_instant_click" },
            },
            effect_text = "{c:upgrade:Cursors} click instantly.",
        },
    },
    {
        id          = "box_of_mice",
        act         = 2,
        name        = "Box of Mice",
        effect_text = "Unlocks the {c:upgrade:cursor} swarm and the Cursor {c:upgrade:upgrade}.",
        description = "Cardboard storage box of mice.",
        sprite      = "box_of_mice",
        phase       = "late",
        cost_chip     = 13,
        slots       = 1,  -- demoted from hero so the whole cursor chain fits one spread
        position    = { x = 100, y = 500 },
        unlock = {
            kind      = "total_hands_at_4plus",
            threshold = 2000,   -- was 5000: idling has to arrive early in Act 2, not deep into it
            text      = "hands at 4+ tables",
        },
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
            effect_text = "+8 {c:upgrade:cursors}.",
        },
    },
    {
        id            = "wacom_tablet",
        act         = 2,
        name          = "Wacom Tablet",
        effect_text   = "{c:upgrade:Cursors} click REBUY.",
        description   = "Graphics drawing tablet for macro commands.",
        sprite        = "wacom_tablet",
        phase         = "late",
        cost_chip       = 13,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_rebuys",
            threshold = 100,
            text      = "rebuys",
        },
        position      = { x = 300, y = 500 },
        effects       = {
            { kind = "shove_rate_add",       value = 0.012 },
            { kind = "cursor_rebuy_unlocked" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "cursor_rebuy_unlocked" },
                { kind = "rebuy_discount", value = 0.20 },
            },
            effect_text = "{c:upgrade:Cursors} click REBUY, and rebuys cost 20% less.",
        },
    },
    {
        id            = "desk_lamp",
        act           = 2,
        name          = "Desk Lamp",
        effect_text   = "{c:upgrade:Cursors} never pause to clean their trackballs.",
        description   = "Optical sensors need light to work.",
        sprite        = "desk_lamp",
        phase         = "late",
        cost_chip     = 10,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 3000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cursor_optical_sensor" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_optical_sensor" },
                { kind = "cursor_memory_unlocked" },
            },
            effect_text = "{c:upgrade:Cursors} see everything and forget nothing.",
        },
    },
    {
        id            = "telephone",
        act           = 2,
        name          = "Telephone",
        effect_text   = "{c:upgrade:Cursors} coordinate targeting: no two race to the same table.",
        description   = "They call ahead.",
        sprite        = "telephone",
        phase         = "late",
        cost_chip     = 12,
        requires    = "laptop_terminal",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 6000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cursor_sync_unlocked" },
        },
    },
    {
        id            = "glass_partition",
        act           = 2,
        name          = "Glass Partition",
        effect_text   = "{c:upgrade:Cursors} phase through each other without bumping.",
        description   = "Everyone gets a lane.",
        sprite        = "glass_partition",
        phase         = "late",
        cost_chip     = 12,
        requires    = "laptop_terminal",
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cursor_collision_phasing" },
        },
    },
    {
        id          = "electric_kettle",
        act         = 2,
        name        = "Electric Kettle",
        effect_text = "{c:lost:Busted} tables refund 30% of the buy-in.",
        description = "Boils fast. Whistles louder.",
        sprite      = "electric_kettle",
        phase       = "late",
        cost_chip   = 11,
        effects     = {
            { kind = "shove_rate_add",   value = 0.012 },
            { kind = "bust_refund_pct",  value = 0.30 },
        },
        unlock = {
            kind      = "total_busts",
            threshold = 300,
            text      = "tables {c:lost:busted}",
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "bust_refund_pct", value = 1.2 },
            },
            effect_text = "{c:lost:Busted} tables refund 120% of the buy-in.",
        },
    },
    {
        id          = "chrome_toaster",
        act         = 2,
        name        = "Chrome Toaster",
        effect_text = "8% chance a win bumps one tier.",
        description = "Two slots. One setting. Pops without warning.",
        sprite      = "chrome_toaster",
        phase       = "late",
        cost_chip   = 14,
        effects     = {
            { kind = "shove_rate_add",       value = 0.014 },
            { kind = "win_tier_bump_chance", value = 0.08 },
        },
        unlock = {
            kind      = "total_stacks",
            threshold = 1600,
            text      = "{stack} {c:won:wins}",
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "win_tier_bump_chance", value = 0.35 },
            },
            effect_text = "35% chance a win bumps one tier.",
        },
    },
    {
        id          = "first_aid_kit",
        act         = 2,
        name        = "First Aid Kit",
        effect_text = "Knockouts have a 10% chance to pay out your biggest buy-in.",
        description = "Wall-mounted. Break glass, sit back down.",
        sprite      = "first_aid_kit",
        phase       = "late",
        cost_chip   = 16,
        unlock = {
            kind      = "total_rebuys",
            threshold = 230,
            text      = "rebuys",
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "proc", proc = "first_aid_kit_biggest" },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "proc",          proc = "first_aid_kit_biggest" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Knockouts have a 10% chance to pay out your biggest buy-in. {c:won:Wins} pay 30% less.",
        },
    },
    {
        id          = "nightstand",
        act         = 2,
        name        = "Nightstand",
        effect_text = "A rebuy has a 50% chance to {c:heat:heat} that table.",
        description = "One drawer. Lock included.",
        sprite      = "nightstand",
        phase       = "late",
        cost_chip   = 13,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "nightstand_rested" },
        },
        unlock = {
            kind      = "total_rebuys",
            threshold = 150,
            text      = "rebuys",
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "proc", proc = "nightstand_rested_corrupt" },
            },
            effect_text = "Every rebuy heats that table.",
        },
    },
    {
        id          = "receipt_printer",
        act         = 2,
        name        = "Receipt Printer",
        effect_text = "Win a {stack} and every Zoom table settles at once.",
        description = "Chatters out a slip for every table. Feed it more paper.",
        sprite      = "receipt_printer",
        phase       = "mid",
        cost_chip   = 19,
        -- Late-Act-1 machine at a late-Act-1 price: 1,100 stacks ≈
        -- shove seven at the measured ~155/shove (see the Candle's note).
        unlock = {
            kind      = "total_stacks",
            threshold = 1100,
            text      = "{stack} {c:won:wins}",
        },
        position    = { x = 330, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "receipt_printer_cascade" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc", proc = "receipt_printer_cascade" },
            },
            effect_text = "Win a {stack} and every Zoom table settles at once.",
        },
    },
    {
        id          = "microwave_oven",
        act         = 2,
        name        = "Microwave Oven",
        effect_text = "When a 6-max is {c:tilt:tilted}: 50% chance another table catches a {c:heat:heater}.",
        description = "Turntable squeaks. Clock blinks 12:00.",
        sprite      = "microwave_oven",
        phase       = "late",
        cost_chip   = 18,
        -- Second link of the tank chain: the Bonsai opens the room, this
        -- starts converting what lands on it.
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "microwave_oven_vent" },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "proc",      proc = "microwave_oven_vent" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "When a 6-max is {c:tilt:tilted}: 50% chance another table catches a {c:heat:heater}. {c:lost:Losses} 50% heavier.",
        },
    },
    {
        id          = "framed_diploma",
        act         = 2,
        name        = "Framed Diploma",
        effect_text = "Every 100 hands won, every table rolls: a third catch {c:heat:heat}, a third {c:tilt:tilt}, a third nothing.",
        description = "Wall-mounted certificate. Handsome on the wall.",
        sprite      = "framed_diploma",
        phase       = "late",
        cost_chip     = 18,
        -- Millennium IS century, bigger — lesson two of the counter items.
        requires    = "wall_clock",
        position    = { x = 450, y = 400 },
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "framed_diploma_century" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc",          proc = "framed_diploma_century" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Every 100 hands won, every table rolls: a third catch {c:heat:heat}, a third {c:tilt:tilt}, a third nothing. {c:won:Wins} pay 30% less.",
        },
    },
    {
        id          = "laminated_blueprint",
        act         = 2,
        name        = "Laminated Blueprint",
        effect_text = "Active deck earns 50% more XP.",
        description = "Wall blueprint chart for systematic study.",
        sprite      = "laminated_blueprint",
        phase       = "late",
        cost_chip   = 19,
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "deck_xp_mult",   value = 1.50 },
        },
        unlock = {
            kind      = "decks_unlocked_count",
            threshold = 5,
            text      = "decks unlocked",
            -- "???" until decks exist (Act 2)
            mystery   = { kind = "shove_r1_won" },
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
        id          = "console_television",
        act         = 2,
        name        = "Console Television",
        effect_text = "A 6-max may take a status aimed at the table beside it.",
        description = "Always on. You stop noticing the sound.",
        sprite      = "console_television",
        phase       = "late",
        cost_chip   = 26,
        -- The router caps the tank chain.
        requires      = "blackout_curtains",
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "router", router = "console_television_intercept" },
        },
        corrupt = {
            cost_achip = 13,
            effects = {
                { kind = "router",        router = "console_television_intercept" },
                { kind = "earnings_mult", value = 0.5 },
            },
            effect_text = "A 6-max may take a status aimed at the table beside it. {c:won:Wins} pay 50% less.",
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
        cost_chip   = 10,
        unlock = {
            kind      = "total_chips_banked",
            threshold = 160,
            text      = "{chip} {c:chip:banked}",
        },
        effects     = {
            { kind = "shove_rate_add",   value = 0.010 },
            { kind = "win_chance_shift", amount = 0.05, gtype = "ko" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "win_chance_shift", amount = 0.30, gtype = "ko" },
                { kind = "win_chance_shift", amount = -0.10, gtype = "six_max" },
            },
            effect_text = "+30% win chance at tournaments. -10% at 6-max.",
        },
    },
    {
        id          = "curved_monitor",
        act         = 2,
        name        = "Curved Monitor",
        effect_text = "Knockouts have a 20% chance to {c:heat:heat} a nearby table.",
        description = "Wraps around you. The room gets smaller.",
        sprite      = "curved_monitor",
        phase       = "mid",
        cost_chip   = 13,
        -- First of the on-KO items: the ratchet first, then the knockouts.
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add", value = 0.012 },
            { kind = "proc", proc = "curved_monitor_heater" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "proc",      proc = "curved_monitor_heater_corrupt" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Knockouts have a 30% chance to {c:heat:heat} every nearby table. {c:lost:Losses} 50% heavier.",
        },
    },
    {
        id          = "tower_upgrade",
        act         = 2,
        name        = "Tower Upgrade",
        effect_text = "Knockouts have a 15% chance to make a nearby table's next win read a tier higher.",
        description = "Fans you can hear from the bed. Boots in seconds.",
        sprite      = "tower_upgrade",
        phase       = "mid",
        cost_chip   = 14,
        requires      = "curved_monitor",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "tower_upgrade_bump" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc", proc = "tower_upgrade_bump_corrupt" },
                -- It bumps pot tiers, so corruption bumps loss tiers back.
                { kind = "loss_tier_shift", from = "medium", to = "large",
                  chance = 0.35 },
            },
            effect_text = "Knockouts have a 25% chance to make every nearby table's next win read a tier higher. {c:lost:Losses} run a tier bigger.",
        },
    },
    {
        id          = "copy_machine",
        act         = 2,
        name        = "Copy Machine",
        effect_text = "The Receipt Printer's sweep DEALS the Zoom tables it finds empty.",
        description = "The printer's big sibling.",
        sprite      = "copy_machine",
        phase       = "mid",
        cost_chip   = 19,
        requires    = "receipt_printer",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "cascade_deals_empty" },
        },
    },
    {
        id          = "whiteboard",
        act         = 2,
        name        = "Whiteboard",
        effect_text = "The plan, drawn out: tournament {c:won:wins} ratchet twice as hard.",
        description = "Nobody else can read it.",
        sprite      = "whiteboard",
        phase       = "late",
        cost_chip   = 17,
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "ratchet_gain_mult", value = 2.0 },
        },
    },
    -- ═══ BAND D — Act 2 late · 11 items · 233 {chip} ════════════════════

    {
        id          = "high_roller_pass",
        act         = 2,
        name        = "High Roller Pass",
        effect_text = "Each tournament finish gives cash games at its stake +1% win chance, lost if that tournament closes.",
        description = "Laminated. Rarely inspected.",
        sprite      = "high_roller_pass",
        phase       = "late",
        cost_chip   = 19,
        -- Finish-based branch of the tournament chain.
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "tourney_backing", value = 0.01 },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "tourney_backing", value = 0.01 },
                { kind = "loss_mult",       value = 1.5 },
            },
            effect_text = "Each tournament finish gives cash games at its stake +1% win chance, lost if that tournament closes. {c:lost:Losses} 50% heavier.",
        },
    },
    {
        id          = "window",
        act         = 2,
        name        = "Window",
        effect_text = "While a tournament runs, {c:tilt:tilts} aimed at its stake have a 35% chance to arrive as {c:heat:heat}.",
        description = "Mounts flat on any wall. View may vary.",
        sprite      = "window",
        phase       = "late",
        cost_chip   = 20,
        -- The router caps the tournament chain.
        requires      = "high_roller_pass",
        unlock = {
            kind      = "total_tilts",
            threshold = 40,
            text      = "tables {c:tilt:tilted}",
            -- "???" until tilt exists in this player's game
            mystery   = { kind = "total_tilts", threshold = 1 },
        },
        effects     = {
            { kind = "shove_rate_add", value = 0.016 },
            { kind = "router", router = "window_bend" },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "router",    router = "window_bend" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "While a tournament runs, {c:tilt:tilts} aimed at its stake have a 35% chance to arrive as {c:heat:heat}. {c:lost:Losses} 50% heavier.",
        },
    },
    {
        id          = "bookshelf",
        act         = 2,
        name        = "Bookshelf",
        effect_text = "+1 level on every {c:upgrade:upgrade}.",
        description = "Every book on it is about the same thing.",
        sprite      = "bookshelf",
        phase       = "late",
        cost_chip   = 22,
        effects     = {
            { kind = "shove_rate_add",           value = 0.016 },
            { kind = "run_upgrade_bonus_levels", value = 1 },
        },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 150,
            text      = "{c:upgrade:upgrade} levels bought",
        },
        corrupt = {
            cost_achip = 11,
            effects = {
                { kind = "run_upgrade_bonus_levels", value = 4 },
            },
            effect_text = "+4 levels on every {c:upgrade:upgrade}.",
        },
    },
    {
        id          = "cereal_shelf",
        act         = 2,
        name        = "Cereal Shelf",
        effect_text = "Start each run with your biggest NL2 pot from last run.",
        description = "Restocked from somewhere. Never the same brand.",
        sprite      = "cereal_shelf",
        phase       = "late",
        cost_chip   = 24,
        effects     = {
            { kind = "shove_rate_add",    value = 0.016 },
            { kind = "start_biggest_pot", scope = "t1" },
        },
        unlock = {
            kind = "shove_r1_won",
            text = "Win your first shove",
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "start_biggest_pot", scope = "any" },
            },
            effect_text = "Start each run with your biggest pot from last run, any stake.",
        },
    },
    {
        id          = "fire_extinguisher",
        act         = 2,
        name        = "Fire Extinguisher",
        effect_text = "A {c:tilt:tilt} landing on an already {c:tilt:tilted} 6-max heats the table beside it.",
        description = "Inspection tag expired a long time ago.",
        sprite      = "fire_extinguisher",
        phase       = "late",
        cost_chip   = 24,
        -- Tilt-on-tilted only means something once tilts are farmable.
        requires    = "microwave_oven",
        effects     = {
            { kind = "shove_rate_add", value = 0.018 },
            { kind = "proc", proc = "fire_extinguisher_compress" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "proc",          proc = "fire_extinguisher_compress" },
                { kind = "earnings_mult", value = 0.75 },
            },
            effect_text = "A {c:tilt:tilt} landing on an already {c:tilt:tilted} 6-max heats the table beside it. {c:won:Wins} pay 25% less.",
        },
    },
    {
        id          = "blackout_curtains",
        act         = 2,
        name        = "Blackout Curtains",
        effect_text = "When a 6-max catches {c:heat:heat}, 50% chance the table beside it catches it too.",
        description = "No window behind them. Still helps.",
        sprite      = "blackout_curtains",
        phase       = "late",
        cost_chip   = 24,
        requires      = "fire_extinguisher",
        effects     = {
            { kind = "shove_rate_add", value = 0.018 },
            { kind = "proc", proc = "blackout_curtains_read" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "proc",      proc = "blackout_curtains_read" },
                { kind = "loss_mult", value = 1.6 },
            },
            effect_text = "When a 6-max catches {c:heat:heat}, 50% chance the table beside it catches it too. {c:lost:Losses} 60% heavier.",
        },
    },
    {
        id          = "tip_jar",
        act         = 2,
        name        = "Tip Jar",
        effect_text = "{chip} {c:chip:bounties} pay 50% more.",
        description = "Coins in a glass. Yours, mostly.",
        sprite      = "tip_jar",
        phase       = "late",
        cost_chip   = 24,
        effects     = {
            { kind = "shove_rate_add",  value = 0.022 },
            { kind = "chip_award_mult", value = 1.50 },
        },
        unlock = {
            kind      = "total_chips_banked",
            threshold = 200,
            text      = "{chip} {c:chip:banked}",
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "chip_award_mult", value = 4.0 },
            },
            effect_text = "{chip} {c:chip:bounties} pay 4×.",
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
        cost_chip   = 18,
        requires      = "tower_upgrade",
        effects     = {
            { kind = "shove_rate_add", value = 0.014 },
            { kind = "proc", proc = "shredder_refund" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc",          proc = "shredder_refund_corrupt" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Knockouts have a 25% chance to refund a nearby buy-in. {c:won:Wins} pay 30% less.",
        },
    },
    {
        id          = "cool_towel",
        act         = 2,
        name        = "Cool Towel",
        effect_text = "After a {c:tilt:tilt} runs its course, 25% chance the table heats up.",
        description = "Kept folded. Kept cold.",
        sprite      = "cool_towel",
        phase       = "late",
        cost_chip   = 16,
        requires    = "dish_soap",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "cool_towel_burnout" },
        },
    },
    {
        id          = "waste_basket",
        act         = 2,
        name        = "Waste Basket",
        effect_text = "The corner is the basket: a {c:tilt:tilt} aimed anywhere has a 35% chance to land on the corner table instead.",
        description = "Ride it out, throw it away.",
        sprite      = "waste_basket",
        phase       = "late",
        cost_chip   = 18,
        requires    = "dish_soap",
        effects     = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "router", router = "basket_corner" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "router", router = "basket_corner_corrupt" },
            },
            effect_text = "The corner is the basket: a {c:tilt:tilt} aimed anywhere has a 70% chance to land on the corner table instead.",
        },
    },
    {
        id            = "cleaning_robot",
        act           = 2,
        name          = "Cleaning Robot",
        effect_text   = "Winning a {stack} sends the {c:upgrade:cursors} into overdrive: double speed for 10 seconds.",
        description   = "It only speeds up after someone {c:won:wins} big. Nobody knows why.",
        sprite        = "cleaning_robot",
        phase         = "late",
        cost_chip     = 24,
        requires    = "gaming_keyboard",
        unlock = {
            kind      = "total_stacks",
            threshold = 500,
            text      = "{stack} {c:won:wins}",
        },
        effects       = {
            { kind = "shove_rate_add", value = 0.010 },
            { kind = "proc", proc = "cleaning_robot_overdrive" },
        },
    },
    -- ═══ Act 3 — anti-{chip} corruption ═════════════════════════════════

    -- ── Rung one: the first procs a player meets ─────────────────────────

    -- ── The mental game ──────────────────────────────────────────────────

    -- ── Engine upgrades ──────────────────────────────────────────────────
    {
        id          = "ultra_stake",
        act         = 2,
        name        = "Ultra Stake",
        effect_text = "Unlock the T10 ULTRA stake.",
        description = "The top table. House limit: none.",
        sprite      = "ultra_stake",
        phase       = "late",
        cost_chip     = 0,
        requires_act3 = true,
        -- A gate, not a thing you own: it unlocks a stake and sits on no
        -- shelf, so it is outside the "every item is 1% shove" rule and
        -- outside pricing. Authored here rather than special-cased by id in
        -- the loader.
        gate        = true,
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

-- Costs and the flat shove rate are DERIVED, not authored: see
-- models/catalog_loader.lua, which main.lua runs once at boot. Edit
-- `authored_cost_chip`; `cost_chip` is overwritten. This file is tables.

return items

