# The catalog's economy (2026-09-07)

What the book costs, what a run earns, and the rules that keep the two in
step. The data is data/catalog.lua and data/catalog_pages.lua; the numbers
are held by `lua sim/lint_catalog_economy.lua` (run it with the other four
lints) and the pacing by `lua sim/act1.lua`, which plays Act 1 through the real
engine (`sim/act1_policy.lua` holds the policy).

## Income

One {chip} bounty per (stake × game type) per run, at the stake's
`chip_award` (1..6 across NL2..NL100M). Chips are meta: never lost, spent
once, no refunds.

| act | stakes | game types | ceiling per run | runs | banked over the act |
|---|---|---|---|---|---|
| Act 1 | T1-T3 | Zoom, Heads-Up, 6-Max (bought: Bonsai) | 18 (24 with the Gaming Poster) | ~5 | ~100 |
| Act 2 | T1-T6 | + tournaments | 84 | ~6 | ~450 |
| Act 3 | T1-T9 | 4 | 180 | | finishes the book |

## The budget

`Balance.CATALOG_CHIP_BUDGET = { act1 = 242, act2 = 538, tol = 6 }`.
Act 1 = every ownable card without `act = 2` (37 today), Act 2 = the cards
with it (35). The whole book is 780. The Act 1 target of 40% owned at the
R1 win (~15 cards, ~0.40 shove at T3 with `T3_MULT`) is what `sim/act1.lua`
measures; the Act 1 item count is derived (`CatalogLoader.act1Count`),
never authored.

## The tiers

A card is priced by its role on its shelf, then the acts are summed to the
budget:

| act | intro | core | chain link | capstone |
|---|---|---|---|---|
| Act 1 | 2-5 (a key 8-13) | 5-10 | | 12-14 |
| Act 2 | cheap tier 8-10 | 12-16 | 12-18 | 18-22 |

Act 2 has a cheap tier on purpose: the 2026-09-04 audit found nothing
under 9 chips there.

## The rules (data/catalog_pages.lua rules 2, 5-8)

- **A chain is a shelf.** Every `requires` points at a card on the same
  shelf or at the shelf's Value Buys intro. A chain is contiguous, root
  first, so "SEE No." points at a neighbour (or page one).
- **A shelf is a ladder.** Down a shelf `cost_chip` never decreases; the
  capstone is the last card. Value Buys reads the same way.
- **Nothing is naked.** Every card has an unlock, a requires, or is an
  intro. Price alone is not a gate.
- **Act flag honesty.** A gate that cannot open before the R1 win (a
  tournament win, decks unlocked, the R1 flag, a `lifetime_*` counter)
  carries `act = 2` or a `mystery` teaser (the Prize Vase: "???" in the Act 1
  book, peels when Act 2 opens). Gates otherwise read the ungated
  `total_*` counters (models/catalog_unlock_rules.lua).
- **Shove is flat.** 1% per owned card, forced by models/catalog_loader.lua;
  the `shove_rate_add` entries carry no value.

## The shelves, in reading order

Value Buys 2 · 3 · 3 · 4 · 5 · 8 · 8 · 13 — Stats 3 · 5 · 6 · 7 · 7 · 8 · 9 · 14 — Rack 6 · 7 · 8 · 8 · 8 · 12 · 20 · 22 — Heads-Up 4 · 6 · 6 · 6 · 8 · 8 · 8 · 22 — Zoom 5 · 6 · 6 · 7 · 8 · 10 · 16 · 17 — 6-Max 6 · 8 · 8 · 14 · 16 · 18 · 20 · 22 — Tournaments 12 · 13 · 14 · 15 · 16 · 17 · 18 · 20 — Mental 5 · 8 · 8 · 12 · 13 · 15 · 16 · 18 — Cursors 10 · 11 · 12 · 12 · 13 · 15 · 16 · 20. (`lua sim/lint_catalog_economy.lua` prints the live list with ids.)

## What changed on 2026-09-11

Ids are the names. Fifteen items whose id still carried an older name were renamed to their display
name in snake case, and their sprite alias (assets/sprites/aliases.json), sound file
(assets/audio/items), room cell (data/room_layout), room light, proc ghost, designer tag and test
keys followed: wall_hanger→wall_hook, cutting_board→tally_book, rolled_vouchers→bottle_of_wine,
glass_partition→beige_tower, framed_diploma→hybrid_console, curved_monitor→hot_bath,
tower_upgrade→fresh_towel, copy_machine→replay_tv, high_roller_pass→shower_head,
shredder→box_of_tissues, cool_towel→electric_kettle, waste_basket→kitchen_bin, whiteboard→rubber_duck,
and the swapped pair nightstand↔chrome_toaster. The two retired cards that held a wanted id are
`rubber_duck_retired` and `electric_kettle_retired`. Saves serialize ids, so `SAVE.VERSION` went to 3
and a v2 file is refused. Deck ids were checked and left alone (`bank`, `master` for "The Bank",
"The Master" are the intended short forms).

## What changed on 2026-09-10

The Act 1 cadence pass, from a full playthrough's counters (3,045 hands, 2,013 won, 712 stacks,
89 busts, 77 rebuys, 92 tilts, 52 heaters, 63 chips banked). The Heads-Up shelf had opened five
items in the act and the Zoom shelf none; Heat & Tilt had one Act 1 card; Bonsai sat past the act.

- **Zoom does hands the way Heads-Up does stacks.** The shelf's gates count total hands and hands won,
  so a Heads-Up player still sees it open; only Handheld (400) and Headset (1,200) stay on Zoom hands.
  The Act 1 loop leads the shelf: House Cat (5, 300 hands won), Hybrid Console (6, 600 hands, moved
  from Act 2, no longer requires the Wall Clock), Washing Machine (10, 1,500 hands, moved from Act 2).
  Wall Clock 2,500 hands. Receipt Printer and Replay TV stay Act 2.
- **Stats opens on the board question.** Yellow Sticky Note leads at 3. Throw Pillow (8, 200 stack
  losses) and Wall Hook (9, 5,000 hands) move to Act 2 as builds. The Hook now counts table TYPES in
  play (a stake at a game type; effect kind `odds_per_lane_seated`, ctx `lanes_seated`), not stakes.
- **Heat & Tilt has Act 1 cards.** Bottle of Wine (5, 10 busts) is the act's heat source; Desk Speakers
  (8, 10 heaters) what heat is worth; Dish Soap at 15 tilts. Both moved from Act 2.
- **Value Buys inside the act.** Bonsai at 45 chips (was 75), the Chrome Toaster at 60 rebuys (was 150).
- Budgets re-stated: Act 1 242 over 37 cards, Act 2 538 over 35, the book 780.

## What changed on 2026-09-07

- Every price set from the tiers; the book went from 879 to 805 (Act 1 230, Act 2 575), and the then-current `sim/run.lua` cleared Act 1 in 4 runs at 48% shove (target 4-5 at 40%; that sim has since been replaced by `sim/act1.lua`).
- Chains re-rooted onto their shelf: Mirror now needs the Gaming Poster
  Poster (was Wall Hanger, on Stats); Fire Extinguisher needs the Bonsai
  (was Microwave Oven, on Mental); Microwave Oven needs the Nightstand (was
  Bonsai). The 6-Max shelf lists the fire chain root first.
- Six naked cards got gates: Wall Hanger (50 hands), Yellow Sticky Note
  (100 hands at 4+ tables), Lava Lamp (400 hands won), Cutting Board (1200
  hands won), Trophy Shelf (150 stacks), Washing Machine (4000 Zoom hands).
- Gaming Poster's gate read a `lifetime_*` counter that only accrues
  in Act 2; it now reads `total_chips_banked` so the Act 1 intro can open.
- `Balance.ACT1_ITEM_COUNT`, `ITEMS_AT_WIN` and `CatalogLoader.chipsPerRun`
  are gone (stale, circular); the count is derived.
- `Constants.DEBUG.CATALOG_NO_CHAINS` is back off.
