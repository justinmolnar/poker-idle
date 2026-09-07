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
--    No. NNN, the X." line always points at a neighbouring card. Chain
--    adjacency outranks fiction when the two fight.
-- 3. Size to 8 (a spread) or 4 (a page). No 9s. A shelf that has more than
--    eight keeps its keeps and gets a second page of four.
-- 4. VALUE BUYS lists exactly ONE item from every other department, and is
--    the only department allowed to repeat an id: an identity's Value Buys
--    card is its ninth slot, a cheap early taste of the shelf. Everything
--    else appears on exactly one shelf. sim/lint_copy.lua checks this.
--    Exempt: a `gate` item (the Ultra key, on the back page by itself) and
--    a `retired` item (cut from the book; docs/retired-item-effects.md).
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

    -- One card from every shelf, in shelf order, cheap, and the first page
    -- the player sees: a table of contents. The cursor box is priced, not
    -- stickered, so "this is automation" is visible from the jump; the
    -- vase reads "???" through Act 1; the corkboard is the stats shelf's
    -- card until it is rewritten.
    { id = "value_buys", title = "Value Buys", label = "VALUE BUYS", tab = { "sem:chip" },
      items = {
          "corkboard", "starter_gift_box", "fight_night_poster", "energy_drink",
          "bonsai", "prize_vase", "dish_soap", "box_of_mice",
      } },

    -- The flat numbers: odds, sizes, winnings. Cheap and Act 1, so first.
    -- Every one but the Toaster is a refactor slot.
    { id = "stats", title = "Memberships & Vouchers", label = "STATS", tab = { "paper:sticker_counting" },
      items = {
          "chrome_toaster", "wall_hanger", "corkboard", "stack_of_books",
          "lava_lamp", "throw_pillow", "comfort_bed", "yellow_sticky_note",
      } },

    -- The run and the rack: what a run starts with and what the upgrades
    -- cost and reach. (Stash Box, Rubber Duck, Electric Kettle and the
    -- Calculator were cut to fit the spread: docs/retired-item-effects.md.)
    { id = "rack", title = "Desk & Stationery", label = "THE RACK", tab = { "sem:upgrade" },
      items = {
          "starter_gift_box", "desk", "cereal_shelf", "compact_fridge",
          "rebuy_sticky_note", "ring_binder", "bookshelf", "second_monitor",
      } },

    -- THE TABLES, together, in the order a run opens them.
    -- Heads-Up first: stacks feed things, and the {chip} bounties.
    { id = "hu", title = "Game Room", label = "HEADS-UP", tab = { "gtype:hu" },
      items = {
          "fight_night_poster", "dogs_playing_poker", "gaming_chair", "candle",
          "pencil_holder", "tip_jar", "mirror", "dusty_console",
      } },

    -- Zoom: speed. The printer pair is here as a refactor slot.
    { id = "zoom", title = "Kitchen & Appliances", label = "ZOOM", tab = { "gtype:zoom" },
      items = {
          "energy_drink", "wall_clock", "house_cat", "framed_diploma",
          "receipt_printer", "copy_machine", "headset", "handheld",
      } },

    -- 6-Max: the tank. Bonsai opens the room, root first. The last three
    -- are refactor slots parked here for the shelf's three open spots.
    { id = "six_max", title = "Den & Houseplants", label = "6-MAX", tab = { "gtype:six_max" },
      items = {
          "bonsai", "desk_plant", "console_television", "fire_extinguisher",
          "blackout_curtains", "red_rug", "space_heater", "laminated_blueprint",
      } },

    -- Tournaments: the Act 2 table. The vase and everything that chains
    -- off it.
    { id = "ko", title = "Awards & Trophy Wall", label = "TOURNAMENTS", tab = { "gtype:ko" },
      items = {
          "prize_vase", "whiteboard", "high_roller_pass", "window",
          "curved_monitor", "tower_upgrade", "shredder", "first_aid_kit",
      } },

    -- The mental game: heat and tilt. Mostly Act 2. Desk Speakers is a
    -- refactor slot; one slot is open.
    { id = "mental", title = "Bed & Bath", label = "HEAT & TILT", tab = { "sem:heat", "sem:tilt" },
      items = {
          "nightstand", "rolled_vouchers", "dish_soap", "cool_towel",
          "waste_basket", "microwave_oven", "desk_speakers",
      } },

    -- The cursor swarm, root first: one spread holds the whole crew. The
    -- box is Act 1; the crew is Act 2, so the shelf closes the book. The
    -- tab wears the colour the word "cursor" wears in copy (sem.upgrade).
    { id = "cursors", title = "Computer Accessories", label = "CURSORS", tab = { "sem:upgrade" },
      items = {
          "box_of_mice", "laptop_terminal", "gaming_keyboard", "wacom_tablet",
          "desk_lamp", "telephone", "glass_partition", "cleaning_robot",
      } },

    -- The Ultra key is its own thing: on no shelf, so it falls to the
    -- book's back "&c." page alone. Gates are exempt from rule 4.
}
