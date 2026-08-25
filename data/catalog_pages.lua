-- data/catalog_pages.lua
--
-- Authored DEPARTMENT layout for the catalog order-book. PURE DATA — no logic.
--
-- ─── A DEPARTMENT IS NOT A PAGE ─────────────────────────────────────────
-- Each entry below is a department holding as many items as it needs: five,
-- nine, whatever. views/CatalogModal:_pages packs each one into as many
-- leaves as it takes (3 slot-units per leaf), and ONLY the first of those
-- leaves prints the heading. Do NOT split a department into three-item
-- chunks to make pages — that is what produced seventeen headings for
-- forty-nine items.
--
-- ─── TWO RULES FOR A DEPARTMENT ─────────────────────────────────────────
-- 1. The title is something a department store prints above a shelf. Never a
--    poker concept: no "Reads & Tempo", no "Big Swings", no "Cushions".
-- 2. Its items share a MECHANIC, and they ladder cheap → expensive inside
--    it, so shopping a department reads as an upgrade path: Stationery bends
--    the run-upgrade economy, Bed & Bath takes the sting out of losses,
--    Appliances are the machines that fire on their own.
--
-- The one deliberate exception is VALUE BUYS, which is the cheap starter
-- shelf. Those items have nothing in common except being the first things
-- worth owning, and that is the point of the shelf.
--
--   { title = "Shown at the top of every leaf it spans",
--     items = { "item_id", ... } }   -- in draw order, cheap to dear
--
-- Items are matched by id against data/catalog.lua. An id that isn't visible
-- yet (locked/hidden/act-3-gated, or owned-prereq not met) is simply skipped;
-- a department whose items are all skipped drops out of the book entirely.
-- Any visible catalog item not listed here falls into a trailing "&c."
-- department, so nothing is ever unreachable.

return {

    -- The starter shelf. No shared mechanic by design — these are just the
    -- cheap things worth buying first.
    { title = "Value Buys",
      items = {
          "poker_poster", "wall_hanger", "mirror", "energy_drink",
          "corkboard", "stack_of_books", "gift_box", "lava_lamp",
          "sticky_notes",
      } },

    -- Softens what losing costs you: tier downgrades, loss multipliers,
    -- voids, and the free rebuy when it still goes wrong.
    { title = "Bed & Bath",
      items = {
          "throw_pillow", "comfort_bed", "rubber_duck", "blackout_curtains",
          "first_aid_kit",
      } },

    -- Machines that fire on their own at an event: a pot bumps, a beat gets
    -- eaten, a bust drains back, last run's losses come back clean.
    { title = "Kitchen & Appliances",
      items = {
          "fridge", "toaster", "kettle", "microwave", "cereal_shelf",
          "fire_extinguisher",
      } },

    -- Attention: focus capacity, the penalty for exceeding it, and the
    -- per-game-type edges you get from paying attention at one kind of table.
    { title = "Home Office",
      items = {
          "desk_plant", "gaming_chair", "second_monitor", "headset",
          "wall_clock", "window", "console_tv", "space_heater",
      } },

    -- Paper goods. Everything here bends the run-upgrade economy or the
    -- bounty paperwork around it.
    { title = "Desk & Stationery",
      items = {
          "calculator", "ring_binder", "pencil_holder", "nightstand",
          "receipt_printer", "bookshelf",
      } },

    -- The cursor swarm. box_of_mice is slots=3, so it fills its own leaf as
    -- a hero card and the crew lands on the next one.
    { title = "Computer Accessories",
      items = {
          "box_of_mice", "laptop", "gaming_keyboard", "wacom_tablet",
          "pc_tower", "curved_monitor", "desk_speakers", "shredder",
      } },

    -- Things on the wall that pay you: bounty bonuses, tournament payout
    -- tiers, deck XP.
    { title = "Awards & Wall Art",
      items = {
          "dogs_playing_poker", "prize_vase", "diploma",
          "blueprint", "tip_jar",
      } },

    -- Paperwork that makes sitting down cheaper or richer.
    { title = "Memberships & Vouchers",
      items = {
          "stash_box", "seat_card", "vouchers", "rebuy_note",
          "high_roller_pass", "unlock_ultra",
      } },
}
