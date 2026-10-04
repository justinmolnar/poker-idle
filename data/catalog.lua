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
--     effect_text = "The rule, in the style sheet's forms (docs/copy-style.md):
--                    '+5% {c:chance:odds} at {k:Zoom}.', '1 in 4 chance:
--                    {w:small} {arrow} {w:medium}.', 'Win a {w:stack}: 1 in
--                    3 chance the {k:adjacent} table catches a
--                    {c:heat:heater}.' Numbers wear their pills on their
--                    own; keywords are wrapped {k:…}. Every number in it
--                    is checked against `effects` by sim/lint_copy.lua; a
--                    corrupt line that only adds a penalty reads 'Same,
--                    and {c:lost:Losses} ×1.5.'
--     description = "Italic flavor blurb under the effect line: the voice
--                    lives here, never in effect_text",
--     allow_numbers = { 10 },       -- optional: a number in effect_text with
--                                   -- no effect behind it (a real-time count)
--     see_also    = { "<item id>", "runup:<upgrade id>" },
--                                   -- optional: rules this one refers to; the
--                                   -- hover card prints theirs beneath
--     readout     = { kind = "..." },
--                                   -- optional: a live value the hover card
--                                   -- prints (models/item_readouts.lua kinds)
--     retired     = true,           -- optional: cut from the book and the shelf lint;
--                                   -- id and effects kept for saves that own it
--                                   -- (docs/retired-item-effects.md has the record)
--     refactor    = true,           -- optional: the designer has flagged this
--                                   -- item for a rewrite. The book washes the
--                                   -- card red and stamps REFACTOR; nothing
--                                   -- else reads it. Remove with the rewrite.
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
-- Deck stickers (data/decks.lua) use the same shape.
--
-- A gate with no meaningful ratio (a flag, like shove_r1_won) prints no
-- counter, so it keeps a standalone imperative: "Win your first shove".
--
-- `format = "money"` switches the counter to dollar formatting. Default is a
-- plain abbreviated count.
--
-- IDS ARE THE NAMES. An item's id is its display name in snake case
-- (`chrome_toaster` is the Chrome Toaster), and its sprite alias
-- (assets/sprites/aliases.json), its sound (assets/audio/items) and its
-- room cell (data/room_layout) all share that id. owned_items /
-- corrupted_items serialize ids into saves, so renaming one is a save
-- version bump (data/constants.lua SAVE.VERSION): the 2026-09-11 pass
-- renamed fifteen and bumped to 3.
--
-- ─── The budget ─────────────────────────────────────────────────────────
-- The book as authored is 780 {chip}: the Act 1 shelves (no `act = 2`) 242,
-- the Act 2 shelves 538. The Act 1 shelves are then scaled by
-- data/balance.lua ACT1_PRICE_SCALE (0.65: they sell for ~157 in play); the
-- prices written below are the authored ones (CATALOG_CHIP_BUDGET). Income per run:
-- a T1-T3 sweep banks 18 (24 with Fight Night), a T1-T6 sweep 84, so Act 1's
-- five runs bank ~100 and Act 2's six ~450; Act 3 (180 a run) finishes the
-- book. Prices come from role tiers and read as a ladder down each shelf
-- (data/catalog_pages.lua rules 5-8); `lua sim/lint_catalog_economy.lua`
-- sums the live book and fails outside ±6 of each act's number.
--
-- Shove is a flat 1% per item (data/balance.lua K_SHOVE_PER_ITEM), derived
-- at boot, so the shove_rate_add entries below carry no value: an act's
-- shove is its item count. Act 1's 37 items carry 0.37 ≥ the 0.250 the
-- first shove needs at T3; later items buy capability rather than shove.
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
        effect_text      = "Bad beats put {c:tilt:tilts} on the tables around them.",
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


    {
        -- Spread: every distinct table type in play (a stake at a game:
        -- NL2 Heads-Up and NL2 Zoom are two) lifts the whole board. Six
        -- lanes exist in Act 1 and a run sits at one or two of them, so
        -- this is an Act 2 card: there it is 36 lanes and room to fill them.
        id          = "wall_hook",
        act         = 2,
        name        = "Wall Hook",
        effect_text = "Each table type you sit at (stake and game): +1% {c:chance:odds} at {k:every_table}.",
        description = "Sturdy wall hook for hanging your hat and gear.",
        sprite      = "wall_hook",
        phase       = "mid",
        cost_chip     = 9,
        unlock      = {
            kind      = "total_hands_played",
            threshold = 5000,
            text      = "hands played",
        },
        position    = { x = 120, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "odds_per_lane_seated", value = 0.01 },   -- PLACEHOLDER
        },
    },
    {
        id          = "mirror",
        name        = "Mirror",
        -- The chip engine's throttle: every Heads-Up table open makes every
        -- Heads-Up table hit stacks more. The player picks how hard to lean
        -- on the duel. Heads-Up only: Zoom's stack cell is capped on purpose.
        effect_text = "Each {k:Heads-Up} table open: +2% {w:stack} {c:chance:odds} at {k:Heads-Up}.",
        description = "A nice big one. You should see yourself. And yourself.",
        sprite      = "mirror",
        phase       = "demo",
        cost_chip     = 4,
        -- The blue "SEE No." slip points at the Fight Night Poster, the
        -- Heads-Up intro on page one, resolved by that 4-{chip} purchase —
        -- never a wall (page one's own Gift Box teaches the slip first), and it
        -- keeps the first post-shove catalog down to ONE ready-to-peel
        -- (the Gift Box). The old hu_unlocked gate was long-met by then.
        requires    = "fight_night_poster",
        position    = { x = 160, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "hu_stack_odds_per_hu_table", value = 0.02 },   -- PLACEHOLDER
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "hu_stack_odds_per_hu_table", value = 0.05 },
            },
            effect_text = "Each {k:Heads-Up} table open: +5% {w:stack} {c:chance:odds} at {k:Heads-Up}.",
        },
    },
    {
        -- The {chip} economy's signpost: appears the moment the first
        -- bounty banks, and says out loud what the numbers already made
        -- true — Heads-Up is the chip mode.
        id          = "fight_night_poster",
        name        = "Fight Night Poster",
        effect_text = "{k:Heads-Up} {c:chip:bounties} pay ×2 {chip}.",
        description = "A duel draws a crowd. The crowd pays.",
        sprite      = "fight_night_poster",
        phase       = "demo",
        cost_chip   = 4,
        unlock = {
            kind      = "total_chips_banked",
            threshold = 1,
            text      = "{chip} {c:chip:banked}",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "bounty_gtype_mult", gtype = "hu", value = 2.0 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "bounty_gtype_mult", gtype = "hu", value = 4.0 },
            },
            effect_text = "{k:Heads-Up} {c:chip:bounties} pay ×4 {chip}.",
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
        effect_text = "Deal a {k:Zoom} table: every {k:adjacent} {k:Zoom} table at the same stake deals too.",
        description = "Tastes terrible. Works fine.",
        sprite      = "energy_drink",
        phase       = "demo",
        cost_chip     = 3,
        position    = { x = 200, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "energy_drink_deal_spread" },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "proc", proc = "energy_drink_deal_spread_corrupt" },
            },
            effect_text = "Deal a {k:Zoom} table: every {k:Zoom} table at the same stake deals too.",
        },
    },
    {
        id          = "corkboard",
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Corkboard",
        effect_text = "+5% {c:chance:odds} at {k:every_table}.",
        description = "Pins, notes, one photo of a beach.",
        sprite      = "corkboard",
        phase       = "demo",
        cost_chip     = 2,
        position    = { x = 240, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "win_chance_shift", amount = 0.05 },
        },
        corrupt = {
            cost_achip = 2,
            effects = {
                { kind = "win_chance_shift", amount = 0.2 },
            },
            effect_text = "+20% {c:chance:odds} at {k:every_table}.",
        },
    },
    {
        -- The d6: a loss rolls again and keeps the better, wins included.
        id          = "stack_of_books",
        name        = "Stack of Books",
        effect_text = "A {c:lost:loss}: 1 in 6 chance it rerolls, keep the better.",
        description = "Pile of bestselling self-help guides.",
        sprite      = "stack_of_books",
        phase       = "demo",
        cost_chip     = 5,
        position    = { x = 280, y = 220 },
        unlock = {
            kind      = "total_hands_won",
            threshold = 250,
            text      = "hands won",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "loss_reroll_chance", value = 1/6 },   -- PLACEHOLDER
        },
    },
    {
        -- Quiet: a table with nothing on any side. A 6-Max beside it counts
        -- as nothing with the Comfort Bed.
        -- An Act 2 build (isolating a table is playing one table in
        -- Act 1); the Comfort Bed is what makes it a board.
        id          = "throw_pillow",
        act         = 2,
        name        = "Throw Pillow",
        effect_text = "A table with nothing {k:adjacent}: {c:won:winnings} ×1.5.",
        description = "Soft plush pillow. Perfect for cushioning rough beats.",
        sprite      = "throw_pillow",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 320, y = 220 },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 200,
            text      = "{l:stack} {c:lost:losses} taken",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "lonely_winnings_mult", value = 1.5 },   -- PLACEHOLDER
        },
    },
    {
        id          = "starter_gift_box",
        name        = "Starter Gift Box",
        effect_text = "+50% starting bankroll.",
        description = "A wrapped gift box for starting fresh.",
        sprite      = "starter_gift_box",
        phase       = "demo",
        cost_chip   = 3,
        -- Page one's chain teacher: the first "SEE No." slip in the book points
        -- at the Corkboard, two cards to the left, and the 2-{chip} buy clears it.
        requires    = "corkboard",
        position    = { x = 360, y = 220 },
        unlock = {
            kind      = "has_shoved",
            text      = "Make your first shove",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "start_bankroll_pct", value = 0.50 },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "start_bankroll_pct", value = 24 },
            },
            effect_text = "Starting bankroll ×25.",
        },
    },
    {
        -- In hand: the table you are holding plays better, and its cell is
        -- empty for everything that reads empties while you hold it.
        id          = "lava_lamp",
        name        = "Lava Lamp",
        effect_text = "The table in your hand: +10% {c:chance:odds} while you hold it.",
        description = "Soothing to watch. Hypnotic, almost.",
        sprite      = "lava_lamp",
        phase       = "demo",
        cost_chip   = 6,
        unlock      = {
            kind      = "total_hands_won",
            threshold = 400,
            text      = "hands won",
        },
        position    = { x = 400, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "held_odds", value = 0.10 },   -- PLACEHOLDER
        },
    },
    {
        -- Takes no thought: the tank is the quiet neighbour, for everything
        -- on this shelf that reads empty spaces.
        id          = "comfort_bed",
        name        = "Comfort Bed",
        effect_text = "A {k:6-Max} counts as an empty space.",
        description = "Restful memory-foam bed. Nothing to think about.",
        sprite      = "comfort_bed",
        phase       = "demo",
        cost_chip     = 7,
        position    = { x = 440, y = 220 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "six_max_counts_empty" },
        },
        unlock = {
            kind      = "total_stack_losses",
            threshold = 110,
            text      = "{l:stack} {c:lost:losses} taken",
        },
    },
    {
        -- Elbow room: a gap beside a table is worth odds there. Gaps are
        -- the cells the board's shape leaves open; where they sit is the
        -- player's to arrange.
        id          = "yellow_sticky_note",
        name        = "Yellow Sticky Note",
        effect_text = "Each empty space {k:adjacent} to a table: +5% {c:chance:odds} there.",
        description = "A pad of yellow notes. Sticks to anything.",
        sprite      = "yellow_sticky_note",
        phase       = "demo",
        -- The Stats shelf's first card and its Act 1 taster: the one
        -- question a partial board asks from the first run (fill the gap,
        -- or leave it for the odds beside it), priced to be bought early.
        cost_chip   = 3,
        unlock      = {
            kind      = "total_hands_at_4plus",
            threshold = 100,
            text      = "hands at 4+ tables",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "odds_per_empty_adjacent", value = 0.05 },   -- PLACEHOLDER
        },
    },
    {
        -- Hand-picked: the active combo. Only hands you deal yourself
        -- build or break it, so you keep it alive by choosing the right
        -- table each click; the swarm's deals never touch it.
        id          = "tally_book",
        name        = "Tally Book",
        effect_text = "{c:won:Wins} in a row on hands you deal yourself: {c:won:winnings} ×1.1 per win, up to ×2. A {c:lost:loss} you dealt ends it.",
        description = "You keep your own count.",
        sprite      = "tally_book",
        phase       = "mid",
        cost_chip   = 7,
        unlock      = {
            kind      = "total_hands_won",
            threshold = 1200,
            text      = "hands won",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "manual_combo", value = 0.10, cap = 2.0 },   -- PLACEHOLDER
        },
    },
    {
        id          = "rubber_duck_retired",
        retired             = true,   -- cut 2026-09-07; docs/retired-item-effects.md
        refactor      = true,   -- flagged for refactor (designer tag); the book washes it red
        name        = "Rubber Duck",
        effect_text = "Your run's first loss is voided.",
        description = "Squeak. It never happened.",
        sprite      = "rubber_duck_retired",
        phase       = "demo",
        cost_chip     = 5,
        position    = { x = 210, y = 400 },
        effects     = {
            { kind = "shove_rate_add" },
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
                { kind = "loss_tier_shift", from = "small", to = "stack", chance = 1/3 },
            },
            effect_text = "1 in 3 chance: {l:small} {arrow} {l:stack}.",
        },
    },


    {
        id          = "stash_box",
        retired             = true,   -- cut 2026-09-07; docs/retired-item-effects.md
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
            { kind = "shove_rate_add" },
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
        effect_text = "Win a {w:stack}: 1 in 4 chance that table catches a {c:heat:heater}.",
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
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "dogs_playing_poker_high" },
        },
        corrupt = {
            cost_achip = 3,
            effects = {
                { kind = "proc", proc = "dogs_playing_poker_high_corrupt" },
            },
            effect_text = "Win a {w:stack}: 1 in 3 chance that table catches a {c:heat:heater}.",
        },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "{c:upgrade:Sharper_Reads}, {c:upgrade:Pot_Control} and {c:upgrade:Cursor_Speed} +15%.",
        see_also    = { "runup:sharper_reads", "runup:pot_control" },
        description = "Solar. Works under the desk lamp.",
        sprite      = "calculator",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 180, y = 200 },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 130,
            text      = "{c:upgrade:upgrade} levels bought",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "run_upgrade_strength_mult", value = 0.15 },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "run_upgrade_strength_mult", value = 1.5 },
            },
            effect_text = "{c:upgrade:Sharper_Reads}, {c:upgrade:Pot_Control} and {c:upgrade:Cursor_Speed} +150%.",
        },
    },
    {
        id          = "ring_binder",
        name        = "Ring Binder",
        effect_text = "{c:upgrade:Upgrade} prices -15%.",
        description = "Three rings, one broken clasp.",
        sprite      = "ring_binder",
        phase       = "mid",
        cost_chip   = 7,
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "{c:upgrade:Upgrade} prices -80%.",
        },
    },
    {
        -- Tanking pays: the table the tank took a tilt for gets its next
        -- win one size up (the two tilt-taking routers, models/table_procs).
        id          = "space_heater",
        name        = "Space Heater",
        effect_text = "A {k:6-Max} takes a {c:tilt:tilt} aimed {k:adjacent} to it: that table's next {c:won:win} is one size up.",
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
            { kind = "shove_rate_add" },
            { kind = "tank_absorb_bumps" },
        },
    },
    {
        id          = "pencil_holder",
        name        = "Pencil Holder",
        effect_text = "+1 {chip} on every {c:chip:bounty}.",
        description = "Desk holder with pens. Nobody counts them.",
        sprite      = "pencil_holder",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 230, y = 200 },
        effects     = {
            { kind = "shove_rate_add" },
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
        effect_text = "Opens {k:6-Max}.",
        description = "Grown slow on purpose. The deep game. Worth the wait.",
        sprite      = "bonsai",
        phase       = "mid",
        cost_chip   = 8,
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "six_max_unlocked" },
        },
        unlock = {
            -- A whole game type is a late-act MILESTONE, not a day-one key:
            -- the game only ever sells two rooms. A full Act 1 banks ~63,
            -- so 45 lands around run four: late Act 1, inside the act.
            kind      = "total_chips_banked",
            threshold = 45,
            text      = "{chip} {c:chip:banked}",
            -- "???" until the pitch has named the door economy
            mystery   = { kind = "total_chips_banked", threshold = 3 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "six_max_unlocked" },
                { kind = "hand_pace_mult", value = 1.25, gtype = "six_max" },
            },
            effect_text = "Opens {k:6-Max}. {k:6-Max} deal speed ×1.25.",
        },
    },
    {
        -- Armour: the tank's tilted hands lose small. A skew on the forced
        -- hands' loss tiers (Table:deal, tilted_loss_dist_shift), so
        -- taunting costs blinds, not stacks.
        id          = "desk_plant",
        name        = "Desk Plant",
        effect_text = "A {c:tilt:tilt} on a {k:6-Max}: smaller {c:lost:losses}.",
        description = "Real. Someone waters it when you're not looking.",
        sprite      = "desk_plant",
        phase       = "mid",
        cost_chip   = 6,
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "tilted_loss_dist_shift", gtype = "six_max",
              shift = { small = 0.30, medium = 0.00, large = -0.15, stack = -0.15 } },   -- PLACEHOLDER
        },
    },
    {
        id          = "desk",
        name        = "Desk",
        effect_text = "Start each run with 1 free NL2 table, already seated.",
        description = "Solid wood, one drawer. Somewhere to put things.",
        sprite      = "desk",
        phase       = "mid",
        cost_chip     = 6,
        position    = { x = 330, y = 200 },
        unlock = {
            kind      = "total_upgrade_levels",
            threshold = 70,
            text      = "{c:upgrade:upgrade} levels bought",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "start_table_count", value = 1 },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "start_table_count", value = 6 },
            },
            effect_text = "Start each run with 6 free NL2 tables, already seated.",
        },
    },
    {
        id          = "rebuy_sticky_note",
        name        = "Rebuy Sticky Note",
        effect_text = "{k:Rebuy} prices -25%.",
        description = "Discount coupon pad. Sticks where you'll see it.",
        sprite      = "rebuy_sticky_note",
        phase       = "mid",
        cost_chip   = 8,
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "{k:Rebuy} prices -75%.",
        },
    },
    {
        id          = "gaming_chair",
        name        = "Gaming Chair",
        effect_text = "Win a {w:stack}: 1 in 3 chance a table {k:adjacent} to it catches a {c:heat:heater}.",
        description = "Ergonomic. Overload hurts less.",
        sprite      = "gaming_chair",
        phase       = "mid",
        cost_chip     = 8,
        unlock = {
            kind      = "total_hands_overwhelmed",
            threshold = 25,
            text      = "hands over the FOCUS cap",
        },
        position    = { x = 150, y = 400 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "gaming_chair_spread" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc",      proc = "gaming_chair_spread" },
                { kind = "loss_mult", value = 1.4 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.4.",
        },
    },
    {
        -- New table, new people: a tilt that ends a Zoom hand does not
        -- follow to the next one (Table:_finalizeHand).
        id          = "headset",
        name        = "Headset",
        effect_text = "{k:Zoom} shakes off a {c:tilt:tilt} after one hand.",
        description = "Foam mic cover. Someone else's earwax.",
        sprite      = "headset",
        phase       = "mid",
        cost_chip   = 7,
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "zoom_tilt_one_hand" },
        },
        -- One of the two Zoom cards gated on Zoom hands (the rest count
        -- every hand, so a Heads-Up player still sees the shelf open).
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 1200,
            text      = "Zoom hands",
        },
    },
    {
        id          = "prize_vase",
        -- Tournaments open with Act 2 (C.GTYPE_GATE.ko = shove_r1_won). The
        -- vase is Value Buys' tournament card, so it sits in the Act 1 book
        -- as a "???" (the mystery below) and peels when Act 2 opens. In the
        -- demo build it is a permanent "???": the tease is the point.
        name        = "Prize Vase",
        effect_text = "Win a {k:tournament}: +1% {c:chance:odds} at {k:every_table} for the run.",
        readout     = { kind = "run_ratchet", effect = "win_chance_shift", field = "amount" },
        description = "Came with a ribbon. The ribbon didn't last.",
        sprite      = "prize_vase",
        phase       = "mid",
        cost_chip     = 8,
        unlock = {
            kind      = "total_ko_wins",
            threshold = 1,
            text      = "tournament {c:won:wins}",
            -- "???" until Act 2 opens tournaments at all
            mystery   = { kind = "shove_r1_won" },
        },
        position    = { x = 350, y = 300 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "prize_vase_ratchet" },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "proc", proc = "prize_vase_ratchet_corrupt" },
            },
            effect_text = "Win a {k:tournament}: +3% {c:chance:odds} at {k:every_table} for the run.",
        },
    },
    {
        id          = "compact_fridge",
        name        = "Compact Fridge",
        effect_text = "Your run's first {l:stack} is voided.",
        description = "The cooler. Eats the worst beat.",
        sprite      = "compact_fridge",
        phase       = "mid",
        cost_chip     = 8,
        position    = { x = 270, y = 400 },
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "First {l:stack} each run pays ×3 {achip}.",
        },
    },
    {
        id          = "wall_clock",
        name        = "Wall Clock",
        effect_text = "Win a hand: 1 in 100 chance {k:a_random_table} catches a {c:heat:heater}.",
        description = "The second hand ticks a little loud.",
        sprite      = "wall_clock",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_hands_played",
            threshold = 2500,
            text      = "hands played",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "wall_clock_century" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "proc",      proc = "wall_clock_century" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.5.",
        },
    },

    {
        id          = "house_cat",
        name        = "House Cat",
        effect_text = "Win a hand: 1 in 50 chance {k:a_random_table}'s next {c:won:win} lands one size up.",
        description = "Someone's cat. It has opinions.",
        sprite      = "house_cat",
        phase       = "demo",
        -- The Zoom shelf's first card: Zoom does hands the way Heads-Up
        -- does stacks, and this pays on every hand won, on any table.
        cost_chip   = 5,
        unlock = {
            kind      = "total_hands_won",
            threshold = 300,
            text      = "hands won",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "house_cat_nap" },
        },
        corrupt = {
            cost_achip = 4,
            effects = {
                { kind = "proc", proc = "house_cat_nap_corrupt" },
            },
            effect_text = "Win a hand: 1 in 25 chance {k:a_random_table}'s next {c:won:win} lands one size up.",
        },
    },
    {
        id          = "candle",
        name        = "Candle",
        effect_text = "Win a {w:stack}: 1 in 4 chance {k:a_random_table} catches a {c:heat:heater}.",
        description = "One wick. Surprising reach.",
        sprite      = "candle",
        phase       = "mid",
        cost_chip   = 6,
        -- Stacks land ~155 per shove (measured from a real save at
        -- shove five: 775 stacks), so stack thresholds are per-shove
        -- rates, not "rare event" counts. 600 ≈ shove four.
        unlock = {
            kind      = "total_stacks",
            threshold = 600,
            text      = "{w:stack} {c:won:wins}",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "candle_flame" },
        },
    },
    {
        -- A Heads-Up item that Zoom is glad to own: stacks come from the
        -- duel, and they pay more everywhere.
        id          = "trophy_shelf",
        name        = "Trophy Shelf",
        effect_text = "A {c:chip:bounty} pays: 1 in 4 chance it pays ×2.",
        description = "Room for one more. There is always room for one more.",
        sprite      = "trophy_shelf",
        phase       = "mid",
        cost_chip   = 8,
        unlock      = {
            kind      = "total_stacks",
            threshold = 150,
            text      = "{w:stack} {c:won:wins}",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "bounty_double_chance", value = 1/4 },   -- PLACEHOLDER
        },
    },
    {
        id          = "dusty_console",
        name        = "Dusty Console",
        effect_text = "{w:stack} {c:won:winnings} ×1.5.",
        description = "Two controllers. Built for one-on-one.",
        sprite      = "dusty_console",
        phase       = "mid",
        cost_chip   = 6,
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "hu",
            threshold = 1000,
            text      = "Heads-Up hands",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "stack_mult",     value = 1.5 },   -- PLACEHOLDER
        },
    },
    {
        -- Fast fold, the real Zoom: lose, and you are already at the next
        -- table (GrindController's resolution loop deals it).
        id          = "handheld",
        name        = "Handheld",
        effect_text = "A {c:lost:loss} at {k:Zoom}: the next hand deals now.",
        description = "Fits in a pocket. Fast games between fast games.",
        sprite      = "handheld",
        phase       = "mid",
        cost_chip   = 6,
        -- One of the two Zoom cards gated on Zoom hands.
        unlock = {
            kind      = "total_hands_at_gtype",
            gtype     = "zoom",
            threshold = 400,
            text      = "Zoom hands",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "zoom_fast_fold" },
        },
    },
    {
        -- The family pot: the tank's big hand, more often.
        id          = "red_rug",
        name        = "Red Rug",
        effect_text = "A {w:large} {c:won:win} at {k:6-Max}: 1 in 3 chance it's a {w:stack}.",
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
            { kind = "shove_rate_add" },
            { kind = "win_tier_shift", from = "large", to = "stack", chance = 1/3, gtype = "six_max" },   -- PLACEHOLDER
        },
    },
    {
        id          = "dish_soap",
        name        = "Dish Soap",
        effect_text = "A {c:tilt:tilt} aimed at a table: 1 in 4 chance it lands on a table {k:adjacent} to it instead.",
        description = "Cuts through anything.",
        sprite      = "dish_soap",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_tilts",
            threshold = 15,
            text      = "tables {c:tilt:tilted}",
            -- "???" until tilt exists in this player's game
            mystery   = { kind = "total_tilts", threshold = 1 },
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "router", router = "dish_soap_deflect" },
        },
    },

    {
        -- The Heat & Tilt shelf's first card and Act 1's heat source: no
        -- item makes weather on its own before this, so the shelf's taster
        -- has to be the thing that lights a table.
        id          = "bottle_of_wine",
        name        = "Bottle of Wine",
        effect_text = "Open your first table at a stake: it catches a {c:heat:heater}.",
        description = "A new stake is an occasion.",
        sprite      = "bottle_of_wine",
        phase       = "demo",
        cost_chip     = 5,
        position    = { x = 600, y = 300 },
        unlock = {
            kind      = "total_busts",
            threshold = 10,
            text      = "tables {c:lost:busted}",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "rolled_vouchers_arrival" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc", proc = "rolled_vouchers_arrival_corrupt" },
            },
            effect_text = "Open any table: it catches a {c:heat:heater}.",
        },
    },
    {
        id          = "second_monitor",
        act         = 2,
        name        = "Second Monitor",
        effect_text = "+2 {c:upgrade:FOCUS}.",
        description = "Mismatched stand. You stop turning your head.",
        sprite      = "second_monitor",
        phase       = "mid",
        cost_chip   = 12,
        effects     = {
            { kind = "shove_rate_add" },
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
                { kind = "focus_capacity_add", value = 2 },
                { kind = "focus_penalty_reduce_mult", value = 0.5 },
            },
            effect_text = "+2 {c:upgrade:FOCUS}, and the {c:upgrade:FOCUS} penalty ×0.5.",
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
        cost_chip     = 10,
        requires    = "box_of_mice",
        position      = { x = 200, y = 500 },
        effects       = {
            { kind = "shove_rate_add" },
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
        effect_text   = "{c:upgrade:Cursor} speed ×1.3.",
        description   = "Mechanical keyboard for faster {c:upgrade:cursor} response.",
        sprite        = "gaming_keyboard",
        phase         = "late",
        cost_chip     = 16,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 1000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_speed_mult", value = 1.30 },
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_instant_click" },
            },
            effect_text = "{c:upgrade:Cursors} click the moment they arrive.",
        },
    },
    {
        id          = "box_of_mice",
        -- Act 1, band B by price alone: 13 {chip} with no sticker, so
        -- "this is automation" is visible from the first catalog and saving
        -- for it is the player's call.
        name        = "Box of Mice",
        effect_text = "Opens the {c:upgrade:cursors} and the Cursor {c:upgrade:upgrade}.",
        description = "Cardboard storage box of mice.",
        sprite      = "box_of_mice",
        phase       = "late",
        cost_chip     = 13,
        slots       = 1,  -- demoted from hero so the whole cursor chain fits one spread
        position    = { x = 100, y = 500 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "cursor_unlocked" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "cursor_unlocked" },
                { kind = "cursor_count_add", value = 8 },
            },
            effect_text = "Opens the {c:upgrade:cursors}, +8 of them.",
        },
    },
    {
        id            = "wacom_tablet",
        act         = 2,
        name          = "Wacom Tablet",
        effect_text   = "{c:upgrade:Cursors} click {k:REBUY}.",
        description   = "Graphics drawing tablet for macro commands.",
        sprite        = "wacom_tablet",
        phase         = "late",
        cost_chip       = 12,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_rebuys",
            threshold = 100,
            text      = "rebuys",
        },
        position      = { x = 300, y = 500 },
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_rebuy_unlocked" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "cursor_rebuy_unlocked" },
                { kind = "rebuy_discount", value = 0.20 },
            },
            effect_text = "{c:upgrade:Cursors} click {k:REBUY}. {k:Rebuy} prices -20%.",
        },
    },
    {
        id            = "desk_lamp",
        act           = 2,
        name          = "Desk Lamp",
        effect_text   = "A {c:upgrade:cursor} crosses a {c:heat:heater}: 1 in 4 chance it catches fire, and the next table it deals catches a {c:heat:heater}.",
        description   = "Runs hot. So does anything under it.",
        sprite        = "desk_lamp",
        phase         = "late",
        cost_chip     = 13,
        requires    = "box_of_mice",
        unlock = {
            kind      = "total_cursor_deals",
            threshold = 3000,
            text      = "hands dealt by {c:upgrade:cursors}",
        },
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_ignite_chance", value = 1/4 },   -- PLACEHOLDER chance
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "cursor_ignite_chance", value = 1/4 },
                { kind = "cursor_fire_persists" },
            },
            effect_text = "Same, and it stays lit after that deal.",
        },
    },
    {
        id            = "telephone",
        act           = 2,
        name          = "Telephone",
        effect_text   = "No two {c:upgrade:cursors} head for the same table.",
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
            { kind = "shove_rate_add" },
            { kind = "cursor_sync_unlocked" },
        },
    },
    {
        -- Every clash is a keystroke: the table under two clashing cursors
        -- deals. Turns the swarm's cost into volume with or without the
        -- robot (with it, the same clash deals AND heats). The DEAL goes
        -- through dealIdleTable like a cursor's own click, so on_deal procs
        -- (the Energy Drink) see it and a busy table is a miss.
        id            = "old_keyboard",
        act           = 2,
        name          = "Old Keyboard",
        effect_text   = "Two {c:upgrade:cursors} clash: the table under them deals.",
        description   = "Every key sticks. Every bump is a keystroke.",
        sprite        = "old_keyboard",
        phase         = "late",
        cost_chip     = 11,
        requires    = "laptop_terminal",
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_clash_deals" },
        },
    },
    {
        id            = "beige_tower",
        act           = 2,
        name          = "Beige Tower",
        effect_text   = "A lit {c:upgrade:cursor} clashes with another: it lights too.",
        description   = "Runs hot. So does everything plugged into it.",
        sprite        = "beige_tower",
        phase         = "late",
        cost_chip     = 15,
        requires    = "desk_lamp",
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_fire_spreads" },
        },
    },
    {
        id          = "electric_kettle_retired",   -- the id went to the Electric Kettle that carries the name (was cool_towel)
        retired             = true,   -- cut 2026-09-07; docs/retired-item-effects.md
        act         = 2,
        name        = "Electric Kettle",
        effect_text = "A table {c:lost:busts}: 30% of its buy-in comes back.",
        description = "Boils fast. Whistles louder.",
        sprite      = "electric_kettle_retired",
        phase       = "late",
        cost_chip   = 11,
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "A table {c:lost:busts}: 120% of its buy-in comes back.",
        },
    },
    {
        id          = "nightstand",
        act         = 2,
        name        = "Nightstand",
        effect_text = "1 in 12 chance a {c:won:win} lands one size up.",
        description = "One drawer. You never know what is in it.",
        sprite      = "nightstand",
        phase       = "late",
        cost_chip   = 14,
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "win_tier_bump_chance", value = 1/12 },
        },
        unlock = {
            kind      = "total_stacks",
            threshold = 1600,
            text      = "{w:stack} {c:won:wins}",
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "win_tier_bump_chance", value = 1/3 },
            },
            effect_text = "1 in 3 chance a {c:won:win} lands one size up.",
        },
    },
    {
        id          = "first_aid_kit",
        act         = 2,
        name        = "First Aid Kit",
        effect_text = "A {k:knockout}: 1 in 10 chance it pays you the biggest buy-in on your board.",
        description = "Wall-mounted. Break glass, sit back down.",
        sprite      = "first_aid_kit",
        phase       = "late",
        cost_chip   = 13,
        unlock = {
            kind      = "total_rebuys",
            threshold = 230,
            text      = "rebuys",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "first_aid_kit_biggest" },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "proc",          proc = "first_aid_kit_biggest" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "Same, and {c:won:Winnings} ×0.7.",
        },
    },
    {
        -- Support in the plainest sense: the tournament keeps its block
        -- seated. Park a busted table beside one and wait for a knockout.
        id            = "medical_poster",
        act           = 2,
        name          = "Medical Poster",
        effect_text   = "A {k:knockout}: a {c:lost:busted} cash table {k:adjacent} to the {k:tournament} rebuys for free.",
        description   = "Get back in there.",
        sprite        = "medical_poster",
        phase         = "late",
        cost_chip     = 12,
        unlock = {
            kind      = "total_busts",
            threshold = 100,                          -- PLACEHOLDER
            text      = "tables {c:lost:busted}",
        },
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "medical_poster_revive" },
        },
    },
    {
        id          = "chrome_toaster",
        name        = "Chrome Toaster",
        effect_text = "{k:Rebuy}: 1 in 2 chance that table catches a {c:heat:heater}.",
        description = "Two slots. One setting. Pops without warning.",
        sprite      = "chrome_toaster",
        phase       = "late",
        cost_chip   = 5,
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "nightstand_rested" },
        },
        unlock = {
            kind      = "total_rebuys",
            threshold = 60,
            text      = "rebuys",
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "proc", proc = "nightstand_rested_corrupt" },
            },
            effect_text = "{k:Rebuy}: that table catches a {c:heat:heater}.",
        },
    },
    {
        -- The block: a row of Zooms is the firehose. Per table, per Zoom
        -- neighbour (GrindController stamps the count, Table:update reads it).
        id          = "receipt_printer",
        act         = 2,
        name        = "Receipt Printer",
        effect_text = "Each {k:Zoom} table {k:adjacent} to a {k:Zoom} table: its deal speed ×1.1.",
        description = "Chatters out a slip for every table. Feed it more paper.",
        sprite      = "receipt_printer",
        phase       = "mid",
        cost_chip   = 16,
        unlock = {
            kind      = "total_stacks",
            threshold = 1100,
            text      = "{w:stack} {c:won:wins}",
        },
        position    = { x = 330, y = 400 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "zoom_block_pace", value = 0.10 },   -- PLACEHOLDER
        },
    },
    {
        id          = "microwave_oven",
        act         = 2,
        name        = "Microwave Oven",
        effect_text = "A {k:6-Max} takes a {c:tilt:tilt}: 1 in 2 chance {k:a_random_table} catches a {c:heat:heater}.",
        description = "Turntable squeaks. Clock blinks 12:00.",
        sprite      = "microwave_oven",
        phase       = "late",
        cost_chip   = 16,
        -- Second link of the tank chain: the Bonsai opens the room, this
        -- starts converting what lands on it.
        requires    = "chrome_toaster",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "microwave_oven_vent" },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "proc",      proc = "microwave_oven_vent" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.5.",
        },
    },
    {
        -- Hands per second: the board's live throughput feeds the Zoom
        -- tables' odds (GrindController keeps a one-second count; the
        -- outcome model reads it). Only a Zoom-heavy board registers.
        -- Second card on the Zoom shelf: with the House Cat and the
        -- Washing Machine it is Act 1's Zoom loop (the washer spins the
        -- board faster, this turns the speed into odds, the cat cashes the
        -- wins).
        id          = "hybrid_console",
        name        = "Hybrid Console",
        effect_text = "Each hand per second the board plays: +2% {c:chance:odds} at {k:Zoom}.",
        description = "Docked. The faster the board runs, the better it plays.",
        sprite      = "hybrid_console",
        phase       = "mid",
        cost_chip     = 6,
        unlock = {
            kind      = "total_hands_played",
            threshold = 600,
            text      = "hands played",
        },
        position    = { x = 450, y = 400 },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "odds_per_hand_per_second", value = 0.02 },   -- PLACEHOLDER
        },
    },
    {
        -- The combo: wins in a row spin the table faster, a loss stops the
        -- drum. Zoom's win chance and pace are what make streaks happen.
        id          = "washing_machine",
        name        = "Washing Machine",
        effect_text = "{c:won:Wins} in a row at {k:Zoom}: deal speed ×1.05 per win, up to ×1.5. A {c:lost:loss} ends it.",
        description = "Spin cycle. It only gets louder.",
        sprite      = "washing_machine",
        phase       = "mid",
        cost_chip   = 10,
        unlock      = {
            kind      = "total_hands_played",
            threshold = 1500,
            text      = "hands played",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "zoom_combo_pace", value = 0.05, cap = 0.50 },   -- PLACEHOLDER
        },
    },
    {
        -- The full house: with every game on the board, the tank's wins
        -- light the room. Scoped to 6-Max wins because they are the slow,
        -- rare ones; the condition means you are running tournaments too.
        id          = "laminated_blueprint",
        act         = 2,
        name        = "Laminated Blueprint",
        effect_text = "Every game open on the board: a {c:won:win} at {k:6-Max}: {k:a_random_table} catches a {c:heat:heater}.",
        description = "Wall blueprint chart. Every room, in use.",
        sprite      = "laminated_blueprint",
        phase       = "late",
        cost_chip   = 16,
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "laminated_blueprint_full_house" },
        },
        unlock = {
            kind      = "decks_unlocked_count",
            threshold = 5,
            text      = "decks unlocked",
            -- "???" until decks exist (Act 2)
            mystery   = { kind = "shove_r1_won" },
        },
    },
    {
        -- The spill: the family pot spills into the block. Rare by nature,
        -- so it hits every neighbour with no chance on it.
        id          = "floor_plant",
        act         = 2,
        name        = "Floor Plant",
        effect_text = "A {w:stack} at {k:6-Max}: each table {k:adjacent} to it gets its next {c:won:win} one size up.",
        description = "Too big for the desk. It gets everywhere.",
        sprite      = "floor_plant",
        phase       = "late",
        cost_chip   = 14,
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "floor_plant_spill" },
        },
    },
    {
        id          = "console_television",
        act         = 2,
        name        = "Console Television",
        effect_text = "A {c:heat:heater} or {c:tilt:tilt} aimed {k:adjacent} to a {k:6-Max}: 1 in 2 chance the {k:6-Max} takes it instead.",
        description = "Always on. You stop noticing the sound.",
        sprite      = "console_television",
        phase       = "late",
        cost_chip   = 22,
        -- The router caps the tank chain.
        requires      = "blackout_curtains",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "router", router = "console_television_intercept" },
        },
        corrupt = {
            cost_achip = 13,
            effects = {
                { kind = "router",        router = "console_television_intercept" },
                { kind = "earnings_mult", value = 0.5 },
            },
            effect_text = "Same, and {c:won:Winnings} ×0.5.",
        },
    },

    {
        -- The room runs hot: every heater burning anywhere lifts every
        -- table. Scales with the board and with the swarm's fire.
        -- Act 1's second Heat & Tilt card: opens once anything has made
        -- heat (the Wine, the Dogs, the Toaster). Owning it also opens the
        -- clean audio chain (services/MusicDirector).
        id          = "desk_speakers",
        name        = "Desk Speakers",
        effect_text = "Each {c:heat:heater} burning: +1% {c:chance:odds} at {k:every_table}.",
        description = "Two small ones. Turn it up and the whole room feels it.",
        sprite      = "desk_speakers",
        phase       = "mid",
        cost_chip   = 8,
        unlock = {
            kind      = "total_heaters",
            threshold = 10,
            text      = "{c:heat:heaters} caught",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "odds_per_heater", value = 0.01 },   -- PLACEHOLDER
        },
        corrupt = {
            cost_achip = 6,
            effects = {
                { kind = "odds_per_heater", value = 0.03 },
            },
            effect_text = "Each {c:heat:heater} burning: +3% {c:chance:odds} at {k:every_table}.",
        },
    },
    {
        -- Longer fire: a heater's forced hand buys one more (Table:_finalizeHand,
        -- punch_extra_hands). The late strong item of the mental game.
        id          = "gas_stove",
        act         = 2,
        name        = "Gas Stove",
        effect_text = "A {c:heat:heater} wins one more hand.",
        description = "Four burners. None of them turn off.",
        sprite      = "gas_stove",
        phase       = "late",
        cost_chip   = 18,
        unlock = {
            kind      = "total_heaters",
            threshold = 200,                          -- PLACEHOLDER
            text      = "{c:heat:heaters} caught",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "punch_extra_hands", status = "heater", value = 1 },
        },
        corrupt = {
            cost_achip = 8,
            effects = {
                { kind = "punch_extra_hands", status = "heater", value = 1 },
                { kind = "punch_extra_hands", status = "tilt",   value = 1 },
            },
            effect_text = "Same, and a {c:tilt:tilt} loses one more too.",
        },
    },
    {
        -- Fire holds: a tilt landing on a burning table still LANDS (it
        -- counts, the converters see it, the Anchor absorbs it) but never
        -- takes the table; the heater keeps its hand (Table:applyStatus).
        -- Heat already overrides tilt the other way: the last punch to
        -- land takes the next hand.
        id          = "cast_iron_pan",
        act         = 2,
        name        = "Cast Iron Pan",
        effect_text = "A {c:tilt:tilt} lands on a {c:heat:heater}: it still counts, the {c:heat:heater} wins.",
        description = "Holds heat. Takes a beating.",
        sprite      = "cast_iron_pan",
        phase       = "late",
        cost_chip   = 15,
        unlock = {
            kind      = "total_tilts",
            threshold = 60,                           -- PLACEHOLDER
            text      = "{c:tilt:tilts} taken",
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "heat_shrugs_tilt" },
        },
    },
    {
        id          = "hot_bath",
        act         = 2,
        name        = "Hot Bath",
        effect_text = "A {k:knockout}: 1 in 5 chance a table {k:adjacent} to the {k:tournament} catches a {c:heat:heater}.",
        description = "Steam. It gets into the next room.",
        sprite      = "hot_bath",
        phase       = "mid",
        cost_chip   = 14,
        -- First of the on-KO items: the ratchet first, then the knockouts.
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "curved_monitor_heater" },
        },
        corrupt = {
            cost_achip = 7,
            effects = {
                { kind = "proc",      proc = "curved_monitor_heater_corrupt" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "A {k:knockout}: 1 in 3 chance each table {k:adjacent} to the {k:tournament} catches a {c:heat:heater}, and {c:lost:Losses} ×1.5.",
        },
    },
    {
        id          = "fresh_towel",
        act         = 2,
        name        = "Fresh Towel",
        effect_text = "A {k:knockout}: 1 in 6 chance a cash table {k:adjacent} to the {k:tournament} gets its next {c:won:win} one size up.",
        description = "Folded once. Warm from somewhere.",
        sprite      = "fresh_towel",
        phase       = "mid",
        cost_chip   = 15,
        requires      = "hot_bath",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "tower_upgrade_bump" },
        },
        corrupt = {
            cost_achip = 5,
            effects = {
                { kind = "proc", proc = "tower_upgrade_bump_corrupt" },
                -- It bumps pot tiers, so corruption bumps loss tiers back.
                { kind = "loss_tier_shift", from = "medium", to = "large",
                  chance = 1/3 },
            },
            effect_text = "A {k:knockout}: 1 in 4 chance every cash table {k:adjacent} to the {k:tournament} gets its next {c:won:win} one size up, and 1 in 3 chance: {l:medium} {arrow} {l:large}.",
        },
    },
    {
        -- Carbon copy: volume into progression. Every counter that counts
        -- hands (stickers, gates, deck XP) counts a Zoom hand as two.
        id          = "replay_tv",
        act         = 2,
        name        = "Replay TV",
        effect_text = "A {k:Zoom} hand counts as two.",
        description = "The replay. Every hand, played back.",
        sprite      = "replay_tv",
        phase       = "mid",
        cost_chip   = 17,
        requires    = "receipt_printer",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "zoom_hands_count_twice" },
        },
    },
    {
        id          = "rubber_duck",
        act         = 2,
        name        = "Rubber Duck",
        effect_text = "A {k:tournament} win pays +2% {c:chance:odds} at {k:every_table} for the run.",
        allow_numbers = { 2 },
        see_also    = { "prize_vase" },
        description = "Squeak. It saw the whole thing.",
        sprite      = "rubber_duck",
        phase       = "late",
        cost_chip   = 17,
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "ratchet_gain_mult", value = 2.0 },
        },
    },

    {
        id          = "shower_head",
        act         = 2,
        name        = "Shower Head",
        effect_text = "Each {k:tournament} a table finishes: +1% {c:chance:odds} at cash tables of its stake, until that table closes.",
        readout     = { kind = "tourney_backing" },
        description = "Rinse. Repeat.",
        sprite      = "shower_head",
        phase       = "late",
        cost_chip   = 18,
        -- Finish-based branch of the tournament chain.
        requires    = "prize_vase",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "tourney_backing", value = 0.01 },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "tourney_backing", value = 0.01 },
                { kind = "loss_mult",       value = 1.5 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.5.",
        },
    },
    {
        id          = "window",
        act         = 2,
        name        = "Window",
        effect_text = "While a {k:tournament} runs: a {c:tilt:tilt} aimed at its stake has a 1 in 3 chance to arrive as a {c:heat:heater}.",
        description = "Mounts flat on any wall. The view is not included.",
        sprite      = "window",
        phase       = "late",
        cost_chip   = 20,
        -- The router caps the tournament chain.
        requires      = "shower_head",
        unlock = {
            kind      = "total_tilts",
            threshold = 40,
            text      = "tables {c:tilt:tilted}",
            -- "???" until tilt exists in this player's game
            mystery   = { kind = "total_tilts", threshold = 1 },
        },
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "router", router = "window_bend" },
        },
        corrupt = {
            cost_achip = 10,
            effects = {
                { kind = "router",    router = "window_bend" },
                { kind = "loss_mult", value = 1.5 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.5.",
        },
    },
    {
        id          = "bookshelf",
        act         = 2,
        name        = "Bookshelf",
        effect_text = "{c:upgrade:Sharper_Reads} and {c:upgrade:Pot_Control}: +1 effective level at every stake.",
        description = "Every book on it is about the same thing.",
        sprite      = "bookshelf",
        phase       = "late",
        cost_chip   = 20,
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "{c:upgrade:Sharper_Reads} and {c:upgrade:Pot_Control}: +4 effective levels at every stake.",
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
        cost_chip   = 22,
        effects     = {
            { kind = "shove_rate_add" },
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
        effect_text = "A {c:tilt:tilt} on a {c:tilt:tilted} {k:6-Max}: a table {k:adjacent} to it catches a {c:heat:heater}.",
        description = "Inspection tag expired a long time ago.",
        sprite      = "fire_extinguisher",
        phase       = "late",
        cost_chip   = 18,
        -- Tilt-on-tilted only means something once tilts are farmable.
        requires    = "bonsai",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "fire_extinguisher_compress" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "proc",          proc = "fire_extinguisher_compress" },
                { kind = "earnings_mult", value = 0.75 },
            },
            effect_text = "Same, and {c:won:Winnings} ×0.75.",
        },
    },
    {
        id          = "blackout_curtains",
        act         = 2,
        name        = "Blackout Curtains",
        effect_text = "A {k:6-Max} catches a {c:heat:heater}: 1 in 2 chance a table {k:adjacent} to it catches one too.",
        description = "No window behind them. Still helps.",
        sprite      = "blackout_curtains",
        phase       = "late",
        cost_chip   = 20,
        requires      = "fire_extinguisher",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "blackout_curtains_read" },
        },
        corrupt = {
            cost_achip = 12,
            effects = {
                { kind = "proc",      proc = "blackout_curtains_read" },
                { kind = "loss_mult", value = 1.6 },
            },
            effect_text = "Same, and {c:lost:Losses} ×1.6.",
        },
    },
    {
        id          = "tip_jar",
        act         = 2,
        name        = "Tip Jar",
        effect_text = "{chip} {c:chip:bounties} pay ×1.5.",
        description = "Coins in a glass. Yours, mostly.",
        sprite      = "tip_jar",
        phase       = "late",
        cost_chip   = 22,
        effects     = {
            { kind = "shove_rate_add" },
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
            effect_text = "{chip} {c:chip:bounties} pay ×4.",
        },
    },

    {
        id          = "box_of_tissues",
        act         = 2,
        name        = "Box of Tissues",
        effect_text = "A {k:knockout}: 1 in 8 chance a cash table {k:adjacent} to the {k:tournament} gets its buy-in back.",
        description = "For the busts.",
        sprite      = "box_of_tissues",
        phase       = "late",
        cost_chip   = 16,
        requires      = "fresh_towel",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "shredder_refund" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "proc",          proc = "shredder_refund_corrupt" },
                { kind = "earnings_mult", value = 0.70 },
            },
            effect_text = "A {k:knockout}: 1 in 4 chance a cash table {k:adjacent} to the {k:tournament} gets its buy-in back, and {c:won:Winnings} ×0.7.",
        },
    },
    {
        id          = "electric_kettle",
        act         = 2,
        name        = "Electric Kettle",
        effect_text = "A {c:tilt:tilt} ends: 1 in 4 chance that table catches a {c:heat:heater}.",
        description = "Boils fast. Whistles louder.",
        sprite      = "electric_kettle",
        phase       = "late",
        cost_chip   = 12,
        requires    = "dish_soap",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "proc", proc = "cool_towel_burnout" },
        },
    },
    {
        id          = "kitchen_bin",
        act         = 2,
        name        = "Kitchen Bin",
        effect_text = "A {c:tilt:tilt}: 1 in 3 chance it lands on the top-left table instead.",
        description = "The corner is the basket. Ride it out, throw it away.",
        sprite      = "kitchen_bin",
        phase       = "late",
        cost_chip   = 13,
        requires    = "dish_soap",
        effects     = {
            { kind = "shove_rate_add" },
            { kind = "router", router = "basket_corner" },
        },
        corrupt = {
            cost_achip = 9,
            effects = {
                { kind = "router", router = "basket_corner_corrupt" },
            },
            effect_text = "A {c:tilt:tilt}: 2 in 3 chance it lands on the top-left table instead.",
        },
    },
    {
        id            = "cleaning_robot",
        act           = 2,
        name          = "Cleaning Robot",
        effect_text   = "Two {c:upgrade:cursors} clash: the table under them catches a {c:heat:heater}, not a {c:tilt:tilt}.",
        description   = "It runs into everything. It was built to.",
        sprite        = "cleaning_robot",
        phase         = "late",
        cost_chip     = 20,
        requires    = "gaming_keyboard",
        unlock = {
            kind      = "total_stacks",
            threshold = 500,
            text      = "{w:stack} {c:won:wins}",
        },
        effects       = {
            { kind = "shove_rate_add" },
            { kind = "cursor_clash_status", status = "heater" },
        },
        corrupt = {
            cost_achip = 8,                           -- PLACEHOLDER
            effects = {
                { kind = "cursor_clash_status", status = "heater" },
                { kind = "cursor_clash_chance", value = 1 },
            },
            effect_text = "Same, and every clash lands.",
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
        effect_text = "Opens the ULTRA stake.",
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
            effect_text = "The ULTRA stake is open.",
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

