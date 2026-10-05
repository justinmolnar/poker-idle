-- data/catalog_pages.lua
--
-- Authored DEPARTMENT layout for the catalog order-book. PURE DATA — no logic.
--
-- ─── A DEPARTMENT IS A SPREAD ───────────────────────────────────────────
-- Leaves hold 4 slot-units (views/CatalogModal LEAF_SLOTS); departments are
-- sized to fill spreads cleanly: 8 items = exactly one spread (two facing
-- pages), 4 items = one page. views/CatalogModal:_pages packs each
-- department into leaves; only the first leaf prints the heading.
--
-- ─── THE ORDER OF THE BOOK ──────────────────────────────────────────────
-- Value Buys first, then the book runs roughly in the order a run meets
-- things: the flat numbers and the rack (Act 1, cheap), then the FOUR
-- TABLES together in the order the player opens them (Heads-Up, Zoom,
-- 6-Max, Tournaments), then the mental game and the cursors, which are
-- mostly Act 2. Value Buys lists its one card per shelf in this same
-- order, so it reads as a table of contents.
--
-- ─── A SHELF IS AN IDENTITY ─────────────────────────────────────────────
-- Every department after Value Buys is one system of the game: a game type
-- (Zoom, Heads-Up, 6-Max, tournaments), the cursors, the mental game (heat
-- and tilt), the run and the rack, or the flat stats. Its `id` names that
-- system and its `tab` colours the index tab along the book's top edge. Items go
-- on the shelf of the system they act on (the designer's tags in
-- tools/catalog_meta.json are the source of that call).
--
-- ─── FOUR RULES FOR A DEPARTMENT ────────────────────────────────────────
-- 1. The title is something a department store prints above a shelf. Never a
--    poker concept. (The id and the tab colour carry the system.)
-- 2. A CHAIN IS A SHELF: every `requires` chain sits contiguous, root first,
--    so requires-order = reading-order and the card's red "Stocked after
--    No. NNN, the X." line points at a neighbouring card. The one exception
--    is a chain whose root is the shelf's Value Buys intro (Bonsai, the
--    Prize Vase, the Box of Mice): the root is on page one, the rest sit
--    contiguous on the shelf. Chain adjacency outranks fiction when the
--    two fight.
-- 3. Size to 8 (a spread) or 4 (a page). No 9s. A shelf that has more than
--    eight keeps its keeps and gets a second page of four.
-- 4. EVERY ITEM IS ON EXACTLY ONE PAGE. An identity is NINE unique items:
--    one on VALUE BUYS, its intro (a cheap early taste of the system), and
--    eight on its shelf. Value Buys lists exactly one intro per other
--    department, named in its `shelf_of` map, and nothing else; no id
--    appears on two pages. sim/lint_copy.lua checks this.
--    Exempt: a `gate` item (the Ultra key, on the back page by itself) and
--    a `retired` item (cut from the book; docs/retired-item-effects.md).
-- 5. A SHELF IS A LADDER: down a shelf, cost_chip never decreases, and the
--    shelf's capstone is its last card. Value Buys reads the same way. A
--    chain has to be contiguous AND ascending, so a chain's prices climb.
-- 6. NOTHING IS NAKED: every card has an unlock, a requires, or is a Value
--    Buys intro. Price alone is not a gate.
-- 7. A GATE THAT CANNOT OPEN IN ACT 1 (a tournament win, decks unlocked,
--    the R1 flag, a lifetime_* counter) carries `act = 2`, or a `mystery`
--    so the demo shows a "???" teaser that peels when Act 2 opens.
-- 8. THE TIERS price a card by its role on the shelf, then the two acts
--    are summed to data/balance.lua CATALOG_CHIP_BUDGET (130 / 584). Act 1
--    is priced per beat since 2026-10-05 (after shove 1: 1-2; after 2:
--    2-5; after 3: 5-7; after 4: 7-9); the Act 1 tiers below are older:
--        Act 1  intro 2-5 (a key 8-13) · core 5-10 · capstone 12-14
--        Act 2  cheap 8-10 · core 12-16 · chain link 12-18 · capstone 18-22
--    Rules 5-8 and the sums: `lua sim/lint_catalog_economy.lua`.
--
-- Fields:
--   id     the system ("value_buys", "zoom", "hu", "mental", "rack", "stats",
--          "six_max", "ko", "cursors")
--   title  the department name on the page
--   label  the word on the index tab: the system, not the fiction ("ZOOM")
--   tab    one or two colour tokens for the index tab: "sem:<meaning>"
--          (data/theme.lua sem), "gtype:<id>" (data/game_type_themes.lua
--          chrome_color), "paper:<token>" (Theme.paper). Two tokens draw a
--          gradient, top to bottom.
--   items  catalog ids in reading order
--
-- Items are matched by id against data/catalog.lua. An id that isn't visible
-- yet is simply skipped; a department whose items are all skipped drops out
-- of the book entirely. Any visible catalog item not listed here falls into
-- a trailing "&c." department, so nothing is ever unreachable — but every
-- non-hidden item IS listed here; keep it that way when adding items.

return {

    -- One intro card per shelf, in shelf order, cheap, and the first page
    -- the player sees. These items live ONLY here: each is its identity's
    -- ninth item, never a repeat of one. The cursor box is priced, not
    -- stickered, so "this is automation" is visible from the jump; the
    -- vase reads "???" through Act 1; the corkboard is the stats intro
    -- until it is rewritten. `shelf_of` names the identity each card
    -- introduces (the lint checks one per shelf).
    { id = "value_buys", title = "Value Buys", label = "VALUE BUYS", tab = { "sem:chip" },
      items = {
          "corkboard", "starter_gift_box", "energy_drink", "fight_night_poster",
          "chrome_toaster", "bonsai", "prize_vase", "box_of_mice",
      },
      shelf_of = {
          corkboard = "stats", starter_gift_box = "rack", fight_night_poster = "hu",
          energy_drink = "zoom", bonsai = "six_max", prize_vase = "ko",
          chrome_toaster = "mental", box_of_mice = "cursors",
      } },

    -- The numbers, each on a condition the player arranges: the gaps on
    -- the board, the table in your hand, the hands you pick yourself, how
    -- many table types. The Corkboard (the intro) is the one flat card.
    -- The Sticky Note leads: the one board question a first run can ask.
    -- The Pillow (one isolated table) and the Hook (many lanes) are Act 2
    -- builds and sit late.
    { id = "stats", title = "Memberships & Vouchers", label = "STATS", tab = { "paper:sticker_counting" },
      items = {
          "yellow_sticky_note", "stack_of_books", "lava_lamp", "tally_book",
          "throw_pillow", "wall_hook", "nightstand",
      } },

    -- The run and the rack: what a run starts with (the Gift Box is the
    -- intro) and what the upgrades cost and reach. (Stash Box, Rubber Duck
    -- and Electric Kettle were cut to fit: docs/retired-item-effects.md.
    -- The Calculator came back the same day when the intro stopped being a
    -- repeat and the shelf had eight again.)
    { id = "rack", title = "Desk & Stationery", label = "THE RACK", tab = { "sem:upgrade" },
      items = {
          "desk", "rebuy_sticky_note", "ring_binder", "compact_fridge",
          "second_monitor", "bookshelf", "cereal_shelf",
      } },

    -- THE TABLES, together, in the order a run opens them.
    -- Heads-Up first: the chip engine. Stacks feed heaters, the bounties
    -- pay more, and the Mirror throttles how hard the duel hits stacks.
    { id = "hu", title = "Game Room", label = "HEADS-UP", tab = { "gtype:hu" },
      items = {
          "mirror", "dogs_playing_poker", "candle", "dusty_console",
          "trophy_shelf", "gaming_chair", "pencil_holder", "tip_jar",
      } },

    -- Zoom: volume. Heads-Up does stacks, Zoom does hands, so the shelf
    -- gates on hands (any table's) and its Act 1 loop leads: the cat cashes
    -- wins, the console turns the board's speed into odds, the washer
    -- spins wins in a row into speed. Then what fast-fold means (a loss
    -- deals the next hand, a tilt does not follow) and the clock; the
    -- printer and the TV are Act 2's block.
    { id = "zoom", title = "Kitchen & Appliances", label = "ZOOM", tab = { "gtype:zoom" },
      items = {
          "house_cat", "handheld", "headset", "hybrid_console",
          "washing_machine", "wall_clock", "receipt_printer", "replay_tv",
      } },

    -- 6-Max: the tank. The Bonsai (the intro) opens the room. The money
    -- half first (the family pot, the spill), then the role: what it takes
    -- for the block, what it costs it, what it turns it into, and the full
    -- house when every game is on the board.
    { id = "six_max", title = "Den & Houseplants", label = "6-MAX", tab = { "gtype:six_max" },
      items = {
          "desk_plant", "red_rug", "space_heater", "floor_plant",
          "laminated_blueprint", "fire_extinguisher", "blackout_curtains", "console_television",
      } },

    -- Tournaments: the Act 2 table, the support. The vase (the intro) and
    -- everything that chains off it; the knockout items hand things to the
    -- tournament's block, the poster brings a busted neighbour back.
    { id = "ko", title = "Awards & Trophy Wall", label = "TOURNAMENTS", tab = { "gtype:ko" },
      items = {
          "medical_poster", "first_aid_kit", "hot_bath", "fresh_towel",
          "box_of_tissues", "rubber_duck", "shower_head", "window",
      } },

    -- The mental game: heat and tilt. The Toaster (rebuy, heater) is the
    -- intro. Act 1 gets a source (the Wine lights a table), what heat is
    -- worth (the speakers) and a tilt router (the soap); then the tilt
    -- converters, and how long the weather lasts: the stove makes a heater
    -- last, the pan lets a burning table take a tilt and keep its fire.
    { id = "mental", title = "Bed & Bath", label = "HEAT & TILT", tab = { "sem:heat", "sem:tilt" },
      items = {
          "bottle_of_wine", "desk_speakers", "dish_soap", "electric_kettle",
          "kitchen_bin", "cast_iron_pan", "microwave_oven", "gas_stove",
      } },

    -- The cursor swarm (its root, the Box of Mice, is the Value Buys intro).
    -- The crew is Act 2, so the shelf closes the book. The tab wears the
    -- colour the word "cursor" wears in copy (sem.upgrade). The partition
    -- chains off the lamp (a lit cursor), so it follows it; the two clash
    -- items close the shelf.
    { id = "cursors", title = "Computer Accessories", label = "CURSORS", tab = { "sem:upgrade" },
      items = {
          "laptop_terminal", "old_keyboard", "telephone", "wacom_tablet",
          "desk_lamp", "beige_tower", "gaming_keyboard", "cleaning_robot",
      } },

    -- The Ultra key is its own thing: on no shelf, so it falls to the
    -- book's back "&c." page alone. Gates are exempt from rule 4.
}
