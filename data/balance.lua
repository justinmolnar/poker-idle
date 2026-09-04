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
-- Act 1 is won across repeated shoves, not on one big one: the real
-- cadence is 4-5 runs, arriving at ~40% on the big hand and having had
-- several tries at it by then. (Was 3 runs / 0.80, which nothing ever hit.)
Balance.ACT1_RUNS_TO_CLEAR     = 5
Balance.ACT1_COMPLETION_AT_WIN = 0.40     -- fraction of the Act 1 catalog owned by then (~13 of 33)
Balance.ACT1_SHOVE_TARGET      = 0.40     -- win chance on the big hand around run 4-5
Balance.T3_MULT                = 3

-- Act 1's catalog is bands A+B (data/catalog.lua header), not the whole
-- book; the sims measure Act 1 completion against this.
Balance.ACT1_ITEM_COUNT        = 33

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

-- ─── Run-upgrade pricing (models/UpgradePricing.lua) ─────────────────────────
-- Sharper Reads / Pot Control are priced in HANDS of the board the player
-- has at that point, from the game's own outcome math at boot:
--   cost(L) = EV$/hand(best table at fill L-1, reference board)
--             × tables × HANDS(L) × cost_mult
--   HANDS(L) = UPGRADE_HANDS_FIRST × UPGRADE_HANDS_GROWTH ^ (L-1)
-- Two knobs. FIRST is the opening: half a round of the best table at
-- fill 0 (six-max NL2 on paper; the zoom-only opener earns it in ~3
-- hands). GROWTH is the ramp: 1.26 makes each level ~26% more rounds
-- than the last — L11 is ~10× L1, L18 ~50×, L29 ~600× — so the game
-- starts fast and slows down, and every Act 2 stake's first level lands
-- above its seat price (NL10K ~3.5 buy-ins, NL1M ~1.3, NL100M ~1.05).
Balance.UPGRADE_HANDS_FIRST  = 0.5
Balance.UPGRADE_HANDS_GROWTH = 1.26
-- The raw prices step hardest where the best table changes (a stake's
-- ×100 arrives in one level). Sigma, in levels, of the Gaussian that
-- smooths the per-level ratios into a ramp; the total climb is kept.
Balance.UPGRADE_RAMP_SMOOTHING = 2.5

-- Every derived upgrade price is rounded to this many significant figures
-- (2: $535,323,234 -> $540M, $1,834 -> $1,800, $2.34 -> $2.30) so the price
-- shown is the price paid and never a nine-digit number with cents.
-- Rounding is monotone, so the ramp keeps its order; a step under ~5%
-- can land two neighbouring levels on the same price, which is fine.
Balance.UPGRADE_PRICE_SIG_FIGS = 2

-- The reference board per stake band (data/stakes.lua `band`): the
-- item-less player with that band's expected tables and decks. Items are
-- the real player's edge over this; decks are the Act 2+ accelerator and
-- the high stakes are −EV without them even capped, so they are in.
-- `tables_ramp` = one table at L1 growing to `tables` (the focus base cap).
-- `gtypes` = a list, or "cash" for every non-tournament mode.
Balance.UPGRADE_REFERENCE = {
    low  = { tables = 4,  tables_ramp = true, decks = {}, gtypes = "cash" },
    mid  = { tables = 9,  decks = { standard = 5 }, gtypes = "cash" },
    -- Act 3 is unbalanced; the high board holds Standard and Nit (the two
    -- decks that make T6+ playable) until that pass.
    high = { tables = 12, decks = { standard = 5, nit = 5 }, gtypes = "cash" },
}

-- The arithmetic that used to live here moved to
-- models/catalog_loader.lua. data/ is tables: these are the authored taste
-- inputs and the constants derived straight from them, nothing else.

return Balance
