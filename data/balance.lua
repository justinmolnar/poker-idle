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
Balance.ACT1_COMPLETION_AT_WIN = 0.40     -- fraction of the Act 1 catalog owned by then (~15 of 37)
Balance.ACT1_SHOVE_TARGET      = 0.40     -- win chance on the big hand around run 4-5
Balance.T3_MULT                = 3

-- The catalog's {chip} budget: what the Act 1 shelves (no `act = 2`) and
-- the Act 2 shelves sum to after CatalogLoader.deriveAll, ±tol. The whole
-- book is 780. Income per run: Act 1 banks 18 (24 with Fight Night), Act 2
-- 84, Act 3 180. `lua sim/lint_catalog_economy.lua` checks the sums; the
-- Act 1 item count is derived from the catalog (CatalogLoader.act1Count),
-- never authored here.
Balance.CATALOG_CHIP_BUDGET    = { act1 = 117, act2 = 594, tol = 6 }
-- The Act 1 shelves' prices, scaled together (CatalogLoader.itemCost). At
-- 1.0 the prices in data/catalog.lua are what the player pays: since
-- 2026-10-05 they are written per beat (the catalog after shove 1: 1-2;
-- after 2: 2-5; after 3: 5-7; after 4: 7-9), so the scale is left at 1.
Balance.ACT1_PRICE_SCALE       = 1.0

-- Shove rate added per catalog item. A FLAT 1%: one item, one point of
-- shove. The budget above prices items; it does not set what they are
-- worth, because a derived 0.78% per item was a number nobody could read
-- off the card.
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
-- The floor under a level's price: the stake the level is FOR, at this
-- many big blinds a hand (a modest edge; a filled NL10K earns ~6), over
-- the same rounds. It only binds where that stake is not yet profitable
-- on its reference board, so a level for NL1M costs NL1M money even while
-- NL1M loses, instead of NL10K money. Below NL10K it never binds.
Balance.UPGRADE_FLOOR_BB     = 5
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
-- `tables_ramp` = one table at L1 growing to `tables`. The low band prices
-- off a TWO-table board, not the focus cap of four: the Act 1 run is the
-- climb to NL100, and priced off four tables levels 6-9 cost ~$1,200 and
-- the run took 20 minutes (median Act 1 80 min over 30 seeds of
-- sim/act1.lua). Off two it is ~$650 and the run is ~12, Act 1 ~58 min.
-- Mid and high price off their own boards, so only levels 1-11 reprice,
-- plus a bleed through UPGRADE_RAMP_SMOOTHING into levels 12-14 (-26%,
-- -18%, -7%); level 16 on is unchanged.
-- `gtypes` = a list, or "cash" for every non-tournament mode.
Balance.UPGRADE_REFERENCE = {
    low  = { tables = 2,  tables_ramp = true, decks = {}, gtypes = "cash" },
    mid  = { tables = 9,  decks = { standard = 5 }, gtypes = "cash" },
    -- Act 3 is unbalanced; the high board holds Standard (the deck that
    -- makes T6+ playable: its reroll) until that pass.
    high = { tables = 12, decks = { standard = 5 }, gtypes = "cash" },
}

-- ─── The cursor swarm's own weather ──────────────────────────────────
-- Two cursors clashing rolls `chance` to punch the table under them: a
-- tilt by default, a heater with the Cleaning Robot (ctx.cursor_clash_status).
-- The punch numbers are the ones every heater/tilt proc in data/procs.lua
-- uses. CURSOR_FIRE is what a lit cursor (the Desk Lamp) leaves on the
-- table it deals. Read by GrindController:onCursorClash / onLitCursorDeal.
Balance.CURSOR_CLASH = {
    chance = 1/4,
    tilt   = { magnitude = 0.35, t = 5 },
    heater = { magnitude = 0.35, t = 6 },
}
Balance.CURSOR_FIRE = { magnitude = 0.35, t = 6 }

-- The arithmetic that used to live here moved to
-- models/catalog_loader.lua. data/ is tables: these are the authored taste
-- inputs and the constants derived straight from them, nothing else.

return Balance
