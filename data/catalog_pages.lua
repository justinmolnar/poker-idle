-- data/catalog_pages.lua
--
-- Authored page layout for the catalog order-book. PURE DATA — no logic.
--
-- Each entry is ONE leaf (a single page). A two-page spread pairs two
-- consecutive leaves, so leaf order here is also spread order: leaves 1-2 are
-- the first spread, 3-4 the second, and so on. A themed spread (e.g. the
-- cursor hero on the left, its sub-items on the right) is just two adjacent
-- leaves — keep the "big" leaf on an odd index so it lands on the left.
--
--   { title = "Shown at the top of the leaf",
--     items = { "item_id", ... } }   -- in draw order, top to bottom
--
-- A leaf holds 3 SLOT-UNITS. Items are 1 unit unless they declare `slots`
-- in data/catalog.lua (e.g. cursor_pool = 3 → fills its whole leaf as a hero
-- card). Items beyond the 3-unit budget on a leaf are dropped, so keep each
-- leaf's slot total ≤ 3.
--
-- Items are matched by id against data/catalog.lua. An id that isn't visible
-- yet (locked/hidden/act-3-gated, or owned-prereq not met) is simply skipped;
-- a leaf whose items are all skipped drops out of the book entirely. Any
-- visible catalog item not listed on a page here falls into a trailing
-- "&c." catch-all leaf, so nothing is ever unreachable.

return {
    { title = "Value Picks",
      items = { "poker_poster", "branded_hat", "whiteboard" } },
    { title = "Reads & Tempo",
      items = { "mirror", "energy_drink", "calculator" } },

    { title = "Big Swings",
      items = { "self_help_book", "lava_lamp", "lucky_coin" } },
    { title = "Cushions",
      items = { "stress_ball", "worry_stone", "headphones" } },

    { title = "Creature Comforts",
      items = { "gaming_chair", "rubber_duck", "fridge" } },
    { title = "Petty Cash",
      items = { "pocket_cash", "free_sit", "discount_sits" } },

    { title = "Curiosities",
      items = { "pen", "copy_machine", "dogs_playing_poker" } },
    { title = "Big Cashes",
      items = { "plastic_trophy", "engraved_plaque", "unlock_ultra" } },

    -- Cursor spread: the hero (slots=3, left leaf) faces its crew (right leaf).
    { title = "The Swarm",
      items = { "cursor_pool" } },
    { title = "Cursor Crew",
      items = { "first_cursor", "tireless_assistants" } },
}
