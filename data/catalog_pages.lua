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
          "corkboard", "starter_gift_box", "fight_night_poster", "energy_drink",
          "bonsai", "prize_vase", "nightstand", "box_of_mice",
      },
      shelf_of = {
          corkboard = "stats", starter_gift_box = "rack", fight_night_poster = "hu",
          energy_drink = "zoom", bonsai = "six_max", prize_vase = "ko",
          nightstand = "mental", box_of_mice = "cursors",
      } },

    -- The flat numbers: odds, sizes, winnings. Cheap and Act 1, so first.
    -- Every one but the Toaster is a refactor slot.
    { id = "stats", title = "Memberships & Vouchers", label = "STATS", tab = { "paper:sticker_counting" },
      items = {
          "chrome_toaster", "wall_hanger", "stack_of_books",
          "lava_lamp", "throw_pillow", "comfort_bed", "yellow_sticky_note",
      } },

    -- The run and the rack: what a run starts with (the Gift Box is the
    -- intro) and what the upgrades cost and reach. (Stash Box, Rubber Duck
    -- and Electric Kettle were cut to fit: docs/retired-item-effects.md.
    -- The Calculator came back the same day when the intro stopped being a
    -- repeat and the shelf had eight again.)
    { id = "rack", title = "Desk & Stationery", label = "THE RACK", tab = { "sem:upgrade" },
      items = {
          "desk", "cereal_shelf", "compact_fridge", "rebuy_sticky_note",
          "ring_binder", "calculator", "bookshelf", "second_monitor",
      } },

    -- THE TABLES, together, in the order a run opens them.
    -- Heads-Up first: the chip engine. Stacks feed heaters, the bounties
    -- pay more, and the Mirror throttles how hard the duel hits stacks.
    { id = "hu", title = "Game Room", label = "HEADS-UP", tab = { "gtype:hu" },
      items = {
          "dogs_playing_poker", "gaming_chair", "candle", "pencil_holder",
          "tip_jar", "trophy_shelf", "mirror", "dusty_console",
      } },

    -- Zoom: speed. The printer pair is here as a refactor slot.
    { id = "zoom", title = "Kitchen & Appliances", label = "ZOOM", tab = { "gtype:zoom" },
      items = {
          "wall_clock", "house_cat", "framed_diploma",
          "receipt_printer", "copy_machine", "headset", "handheld",
      } },

    -- 6-Max: the tank. Bonsai opens the room, root first. The last three
    -- are refactor slots parked here for the shelf's three open spots.
    { id = "six_max", title = "Den & Houseplants", label = "6-MAX", tab = { "gtype:six_max" },
      items = {
          "desk_plant", "console_television", "fire_extinguisher",
          "blackout_curtains", "red_rug", "space_heater", "laminated_blueprint",
      } },

    -- Tournaments: the Act 2 table, the support. The vase (the intro) and
    -- everything that chains off it; the knockout items hand things to the
    -- tournament's block, the poster brings a busted neighbour back.
    { id = "ko", title = "Awards & Trophy Wall", label = "TOURNAMENTS", tab = { "gtype:ko" },
      items = {
          "whiteboard", "high_roller_pass", "window", "curved_monitor",
          "tower_upgrade", "shredder", "first_aid_kit", "medical_poster",
      } },

    -- The mental game: heat and tilt. The Nightstand (rebuy, heater) is
    -- the intro. Sources, then the tilt routers and converters, then how
    -- long and how much the weather is worth: the speakers scale with the
    -- heaters burning, the stove makes a heater last, the pan lets a
    -- burning table take a tilt and keep its fire.
    { id = "mental", title = "Bed & Bath", label = "HEAT & TILT", tab = { "sem:heat", "sem:tilt" },
      items = {
          "rolled_vouchers", "dish_soap", "waste_basket", "cool_towel",
          "microwave_oven", "desk_speakers", "gas_stove", "cast_iron_pan",
      } },

    -- The cursor swarm (its root, the Box of Mice, is the Value Buys intro).
    -- The crew is Act 2, so the shelf closes the book. The tab wears the
    -- colour the word "cursor" wears in copy (sem.upgrade). The partition
    -- chains off the lamp (a lit cursor), so it follows it; the two clash
    -- items close the shelf.
    { id = "cursors", title = "Computer Accessories", label = "CURSORS", tab = { "sem:upgrade" },
      items = {
          "laptop_terminal", "gaming_keyboard", "wacom_tablet", "desk_lamp",
          "glass_partition", "telephone", "old_keyboard", "cleaning_robot",
      } },

    -- The Ultra key is its own thing: on no shelf, so it falls to the
    -- book's back "&c." page alone. Gates are exempt from rule 4.
}
