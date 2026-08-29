-- data/balance.lua
--
-- Central Balance & Pacing Engine (Phase 1)
-- Authored taste inputs and derived arithmetic.
-- Preserves hand-authored relative pricing across department shelves, while
-- deriving k and overall price scaling downstream of taste inputs.

local Balance = {}

-- ─── Locked Design Inputs ───────────────────────────────────────────────────
-- Taste parameters from docs/balance-plan.md:
Balance.TOTAL_GAME_HOURS       = 7
Balance.ACT1_HOURS             = 1.5
Balance.ACT2_HOURS             = 4
Balance.ACT3_HOURS             = 1

Balance.RUN_MINUTES            = 20
Balance.ACT1_RUNS_TO_CLEAR     = 3
Balance.ACT1_COMPLETION_AT_WIN = 0.70     -- fraction of Act 1 catalog owned at win (~18 of 25)
Balance.ACT1_SHOVE_TARGET      = 0.80     -- win chance at expected winning shove (Shove 3)
Balance.T3_MULT                = 3

Balance.ACT1_ITEM_COUNT        = 67

-- ─── Derived Math ────────────────────────────────────────────────────────────
-- Target catalog R1 contribution for Act 1 (raw1 = (catalog + deck) * mult)
Balance.CATALOG_TARGET_ACT1    = Balance.ACT1_SHOVE_TARGET / Balance.T3_MULT            -- 0.80 / 3 = 0.2666...

-- Number of items owned at expected Act 1 win
Balance.ITEMS_AT_WIN           = Balance.ACT1_ITEM_COUNT * Balance.ACT1_COMPLETION_AT_WIN  -- 25 * 0.70 = 17.5

-- Shove rate added per catalog item. A FLAT 1%: one item, one point of
-- shove. The pacing model above prices items (getItemCost); it no longer
-- sets what they are worth, because a derived 0.78% per item was a number
-- nobody could read off the card. (The derived value is kept for reference.)
Balance.K_SHOVE_PER_ITEM_DERIVED = Balance.CATALOG_TARGET_ACT1 / Balance.ITEMS_AT_WIN
Balance.K_SHOVE_PER_ITEM         = 0.01

-- The arithmetic that used to live here moved to
-- models/catalog_loader.lua. data/ is tables: these are the authored taste
-- inputs and the constants derived straight from them, nothing else.

return Balance
