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
          "poker_poster", "branded_hat", "mirror", "energy_drink",
          "whiteboard", "self_help_book", "lucky_coin", "lava_lamp",
          "sticky_notes",
      } },

    -- Softens what losing costs you: tier downgrades, loss multipliers,
    -- voids, and the free rebuy when it still goes wrong.
    { title = "Bed & Bath",
      items = {
          "stress_ball", "worry_stone", "rubber_duck", "headphones",
          "medical_kit", "bathtub",
      } },

    -- Machines that fire on their own at an event: a pot bumps, a beat gets
    -- eaten, a bust drains back, last run's losses come back clean.
    { title = "Kitchen & Appliances",
      items = {
          "fridge", "toaster", "the_sink", "microwave", "dishwasher",
          "fire_extinguisher",
      } },

    -- Attention: focus capacity, the penalty for exceeding it, and the
    -- per-game-type edges you get from paying attention at one kind of table.
    { title = "Home Office",
      items = {
          "water_cooler", "gaming_chair", "second_monitor", "headset",
          "wall_clock", "projector", "big_tv",
      } },

    -- Paper goods. Everything here bends the run-upgrade economy or the
    -- bounty paperwork around it.
    { title = "Desk & Stationery",
      items = {
          "calculator", "ring_binder", "pen", "filing_cabinet",
          "copy_machine", "supply_closet",
      } },

    -- The cursor swarm. cursor_pool is slots=3, so it fills its own leaf as
    -- a hero card and the crew lands on the next one.
    { title = "Computer Accessories",
      items = {
          "cursor_pool", "first_cursor", "mouse_pad", "tireless_assistants",
      } },

    -- Things on the wall that pay you: bounty bonuses, tournament payout
    -- tiers, deck XP.
    { title = "Awards & Wall Art",
      items = {
          "dogs_playing_poker", "plastic_trophy", "engraved_plaque",
          "study_chart", "tip_jar",
      } },

    -- Paperwork that makes sitting down cheaper or richer.
    { title = "Memberships & Vouchers",
      items = {
          "pocket_cash", "free_sit", "discount_sits", "punch_card",
          "glass_door", "unlock_ultra",
      } },
}
