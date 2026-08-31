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
-- ─── THREE RULES FOR A DEPARTMENT ───────────────────────────────────────
-- 1. The title is something a department store prints above a shelf. Never a
--    poker concept.
-- 2. A CHAIN IS A SHELF: every `requires` chain sits contiguous, root first,
--    so requires-order = reading-order and the card's red "Stocked after
--    No. NNN, the X." line always points at a neighbouring card. Chain
--    adjacency outranks fiction when the two fight.
-- 3. Size to 8 (a spread) or 4 (a page). No 9s.
--
-- The one deliberate exception is VALUE BUYS, the cheap starter shelf.
--
-- Items are matched by id against data/catalog.lua. An id that isn't visible
-- yet is simply skipped; a department whose items are all skipped drops out
-- of the book entirely. Any visible catalog item not listed here falls into
-- a trailing "&c." department, so nothing is ever unreachable — but every
-- non-hidden item IS listed here; keep it that way when adding items.

return {

    -- The starter shelf, and the unlock system's first classroom: most of
    -- it is open from the jump, the Mirror's sticker fills the moment the
    -- duel opens, the books count your hands, and the Gift Box arrives at
    -- the first post-shove catalog already green — the peel tutorial.
    { title = "Value Buys",
      items = {
          "wall_hanger", "mirror", "energy_drink", "corkboard",
          "stack_of_books", "gift_box", "lava_lamp", "sticky_notes",
      } },

    -- Early scars, in the order they happen: the first lost stack, the
    -- first bust, then the tilt era and its treatments.
    { title = "Bed & Bath",
      items = {
          "throw_pillow", "comfort_bed", "rubber_duck", "space_heater",
          "dish_soap", "cool_towel", "waste_basket", "first_aid_kit",
      } },

    -- The per-game-type toys, laddered by exposure.
    { title = "Game Room",
      items = {
          "fight_night", "nes_console", "gameboy", "headset",
          "dogs_playing_poker", "candle", "gaming_chair", "house_cat",
      } },

    -- The workstation: the run-upgrade economy, laddered by levels bought.
    { title = "Desk & Stationery",
      items = {
          "desk", "ring_binder", "calculator", "pencil_holder",
          "second_monitor", "nightstand", "bookshelf", "blueprint",
      } },

    -- Machines that fire on their own, laddered by the events that earn
    -- them; both mini-chains adjacent (printer→copier, clock→diploma).
    { title = "Kitchen & Appliances",
      items = {
          "fridge", "kettle", "receipt_printer", "copy_machine",
          "wall_clock", "diploma", "toaster", "cereal_shelf",
      } },

    -- The 6-Max tank chain, root first (bonsai opens the room and goes
    -- green at the first post-shove catalog), plus the den furnishings.
    { title = "Den & Houseplants",
      items = {
          "bonsai", "desk_plant", "microwave", "fire_extinguisher",
          "blackout_curtains", "console_tv", "red_rug", "desk_speakers",
      } },

    -- The cursor swarm, root first: one spread holds the whole crew.
    { title = "Computer Accessories",
      items = {
          "box_of_mice", "laptop", "gaming_keyboard", "wacom_tablet",
          "desk_lamp", "telephone", "glass_partition", "cleaning_robot",
      } },

    -- The tournament ecosystem on one spread: the vase and everything
    -- that chains off it, plus the bounty jar.
    { title = "Awards & Trophy Wall",
      items = {
          "prize_vase", "curved_monitor", "pc_tower", "shredder",
          "whiteboard", "high_roller_pass", "window", "tip_jar",
      } },

    -- The back page. Paperwork, and the last thing in the book.
    { title = "Memberships & Vouchers",
      items = {
          "stash_box", "vouchers", "rebuy_note", "unlock_ultra",
      } },
}
