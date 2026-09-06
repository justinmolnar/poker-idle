# Catalog items by game system

Every catalog item (`data/catalog.lua`), grouped by the part of the game it
influences rather than by store department. An item that touches several
systems appears in every group it belongs to, so the groups overlap on
purpose. Effects are the base (Act 1/2) ones; the corrupt column is what the
Act 3 anti-{chip} purchase replaces them with. Blank corrupt = no corrupt
block yet.

Ids are the frozen save keys. Costs are the authored {chip} price. Every
item also adds a flat +1% shove rate, omitted below.

Generated 2026-09-06 from the catalog, `data/procs.lua`, `data/routers.lua`
and `data/effects.lua`.

---

## 1. Index (alphabetical)

| Item | id | Cost | Act | Does |
|---|---|---|---|---|
| Blackout Curtains | `blackout_curtains` | 24 | 2 | Heat landing on a 6-max: 50% the adjacent table catches it too |
| Bonsai | `bonsai` | 10 | 1 | Opens 6-Max tables |
| Bookshelf | `bookshelf` | 22 | 2 | +1 level on every run upgrade |
| Box of Mice | `box_of_mice` | 13 | 2 | Unlocks the cursor swarm and the Cursor upgrade |
| Calculator | `calculator` | 7 | 1 | Sharper Reads and Pot Control 15% stronger |
| Candle | `candle` | 7 | 1 | Stack win: 25% a random other table catches a heater |
| Cereal Shelf | `cereal_shelf` | 24 | 2 | Start each run with last run's biggest NL2 pot |
| Chrome Toaster | `chrome_toaster` | 14 | 2 | 8% chance a win bumps one tier |
| Cleaning Robot | `cleaning_robot` | 24 | 2 | Stack win: cursors double speed for 10s |
| Comfort Bed | `comfort_bed` | 4 | 1 | 15% chance a Stack loss softens to Large |
| Compact Fridge | `compact_fridge` | 12 | 1 | Run's first Stack loss is voided |
| Console Television | `console_television` | 26 | 2 | A 6-max takes 50% of statuses aimed at an adjacent table |
| Cool Towel | `cool_towel` | 16 | 2 | After a tilt runs its course, 25% the table heats |
| Copy Machine | `copy_machine` | 19 | 2 | Receipt Printer sweep deals empty Zoom tables |
| Corkboard | `corkboard` | 4 | 1 | +5% win chance everywhere |
| Curved Monitor | `curved_monitor` | 13 | 2 | Knockout: 20% heat a table within 2 cells |
| Desk | `desk` | 9 | 1 | Start each run with 1 table open |
| Desk Lamp | `desk_lamp` | 10 | 2 | Cursors never pause to clean trackballs |
| Desk Plant | `desk_plant` | 8 | 1 | +6% win chance at 6-max |
| Desk Speakers | `desk_speakers` | 10 | 2 | +5% win chance at tournaments |
| Dish Soap | `dish_soap` | 12 | 1 | Tilt: 25% lands on the adjacent table instead |
| Dogs Playing Poker | `dogs_playing_poker` | 6 | 1 | Stack win: 25% that table catches a heater |
| Dusty Console | `dusty_console` | 5 | 1 | +3% win chance at Heads-Up |
| Electric Kettle | `electric_kettle` | 11 | 2 | Busted tables refund 30% of buy-in |
| Energy Drink | `energy_drink` | 3 | 1 | Every 25 hands anywhere, a Zoom table catches a heater |
| Fight Night Poster | `fight_night_poster` | 4 | 1 | Heads-Up bounties pay double {chip} |
| Fire Extinguisher | `fire_extinguisher` | 24 | 2 | Tilt on an already-tilted 6-max heats the adjacent table |
| First Aid Kit | `first_aid_kit` | 16 | 2 | Knockout: 10% pays out your biggest buy-in |
| Framed Diploma | `framed_diploma` | 18 | 2 | Every 100 hands won, every table rolls heat / tilt / nothing |
| Gaming Chair | `gaming_chair` | 10 | 1 | Stack win: 30% an adjacent table catches a heater |
| Gaming Keyboard | `gaming_keyboard` | 12 | 2 | Cursors travel 30% faster |
| Glass Partition | `glass_partition` | 12 | 2 | Cursors phase through each other |
| Handheld | `handheld` | 5 | 1 | +3% win chance at Zoom |
| Headset | `headset` | 6 | 1 | +6% win chance at Zoom |
| High Roller Pass | `high_roller_pass` | 19 | 2 | Each tournament finish: +1% win chance for cash games at that stake |
| House Cat | `house_cat` | 8 | 1 | Every 50 hands won, a table's next win reads a tier higher |
| Laminated Blueprint | `laminated_blueprint` | 19 | 2 | Active deck earns 50% more XP |
| Laptop Terminal | `laptop_terminal` | 12 | 2 | +1 cursor |
| Lava Lamp | `lava_lamp` | 5 | 1 | 15% chance a Medium win boosts to Large |
| Microwave Oven | `microwave_oven` | 18 | 2 | Tilt on a 6-max: 50% a random other table catches a heater |
| Mirror | `mirror` | 3 | 1 | +10% win chance at Heads-Up |
| Nightstand | `nightstand` | 13 | 2 | Rebuy: 50% heats that table |
| Pencil Holder | `pencil_holder` | 8 | 1 | +1 {chip} on every Stack win |
| Prize Vase | `prize_vase` | 12 | 2 | Tournament win: every table +1% win chance for the run |
| Rebuy Sticky Note | `rebuy_sticky_note` | 10 | 1 | Rebuys cost 25% less |
| Receipt Printer | `receipt_printer` | 19 | 2 | Stack win: every Zoom table settles at once |
| Red Rug | `red_rug` | 8 | 1 | Table in the top-left board cell: +2% win chance |
| Ring Binder | `ring_binder` | 7 | 1 | Run upgrades cost 15% less |
| Rolled Vouchers | `rolled_vouchers` | 9 | 2 | First table opened at a stake catches heat |
| Rubber Duck | `rubber_duck` | 5 | 1 | Run's first loss is voided |
| Second Monitor | `second_monitor` | 10 | 2 | +2 focus capacity |
| Shredder | `shredder` | 18 | 2 | Knockout: 12% refunds an adjacent table's buy-in |
| Space Heater | `space_heater` | 8 | 1 | Losses 20% softer |
| Stack of Books | `stack_of_books` | 4 | 1 | 25% chance a Small win boosts to Medium |
| Starter Gift Box | `starter_gift_box` | 4 | 1 | +50% starting bankroll |
| Stash Box | `stash_box` | 6 | 1 | +$5 starting bankroll |
| Telephone | `telephone` | 12 | 2 | Cursors never race to the same table |
| Throw Pillow | `throw_pillow` | 4 | 1 | 25% chance a Large loss softens to Medium |
| Tip Jar | `tip_jar` | 24 | 2 | {chip} bounties pay 50% more |
| Tower Upgrade | `tower_upgrade` | 14 | 2 | Knockout: 15% a table within 2 cells gets next win a tier higher |
| Ultra Stake | `ultra_stake` | 0 | 3 | Gate: unlocks the T10 ULTRA stake (corrupt only) |
| Wacom Tablet | `wacom_tablet` | 13 | 2 | Cursors click REBUY |
| Wall Clock | `wall_clock` | 12 | 1 | Every 100 hands won, a random other table catches a heater |
| Wall Hanger | `wall_hanger` | 2 | 1 | Stack wins pay 1.2x |
| Waste Basket | `waste_basket` | 18 | 2 | Tilt aimed anywhere (not a 6-max): 35% lands on the corner table |
| Whiteboard | `whiteboard` | 17 | 2 | Tournament-win ratchet grants twice as much |
| Window | `window` | 20 | 2 | While a tournament runs, tilts at its stake: 35% arrive as heat |
| Yellow Sticky Note | `yellow_sticky_note` | 5 | 1 | Wins pay 25% more |
| (hidden) Tilt | `tilt` | 0 | sys | Granted at start: tournament bust tilts neighbours, 6-max Stack loss tilts a neighbour |

---

## 2. Grouping by game system

### 2.1 Generic stats (always-on numbers, every table)

The passive baseline. Flat multipliers and shifts that never fire, never
target, never care where a table sits.

| Item | Effect | Corrupt |
|---|---|---|
| Corkboard | `win_chance_shift` +5% at all tables | +20% |
| Yellow Sticky Note | `earnings_mult` 1.25 on wins | 4.0 |
| Space Heater | `loss_mult` 0.80 | 3.0 (losses 3x bigger) |
| Wall Hanger | `stack_mult` 1.20 on Stack-tier wins | 5.0 |
| Stack of Books | `win_tier_shift` Small to Medium, 25% | 45% |
| Lava Lamp | `win_tier_shift` Medium to Large, 15% | 45% |
| Chrome Toaster | `win_tier_bump_chance` 8% any win up one tier | 35% |
| Throw Pillow | `loss_tier_shift` Large to Medium, 25% | Large to Stack 40% (worse) |
| Comfort Bed | `loss_tier_shift` Stack to Large, 15% | `anti_award_mult` 2.0 |
| Rubber Duck | `void_first_loss` (per run) | Small loss to Stack 35% (worse) |
| Compact Fridge | `void_first_stack_loss` (per run) | `first_anti_mult` 3.0 |

### 2.2 Per-game-type win chance (Heads-Up / Zoom / 6-max / tournaments)

Same shape as 2.1 but scoped by `gtype`.

| Item | Game type | Effect | Corrupt |
|---|---|---|---|
| Mirror | Heads-Up | +10% win chance | +35% |
| Dusty Console | Heads-Up | +3% win chance | none |
| Headset | Zoom | +6% win chance | +35% |
| Handheld | Zoom | +3% win chance | none |
| Desk Plant | 6-max | +6% win chance | +35% |
| Desk Speakers | Tournaments | +5% win chance | +30% KO, -10% 6-max |
| High Roller Pass | Cash at a tournament's stake | `tourney_backing` +1% per finish | same, losses 1.5x |
| Red Rug | Whichever table is top-left | `corner_win_chance` +2% | none |

### 2.3 Heads-Up

HU is the {chip} mode and the mode that hits Stack tier most often, so the
Stack-triggered procs below are HU items without naming it.

| Item | Role | Effect |
|---|---|---|
| Mirror | Stat | +10% win chance at HU |
| Dusty Console | Stat | +3% win chance at HU |
| Fight Night Poster | Economy | `bounty_gtype_mult` HU bounties pay 2x {chip} (corrupt 4x) |
| Wall Hanger | Stat | Stack wins pay 1.2x |
| Pencil Holder | Economy | +1 {chip} per Stack win (corrupt +4) |
| Dogs Playing Poker | Proc `dogs_playing_poker_high` | Stack win: 25% self heater (corrupt 35%) |
| Gaming Chair | Proc `gaming_chair_spread` | Stack win: 30% heater on an adjacent table (corrupt adds losses 1.4x) |
| Candle | Proc `candle_flame` | Stack win: 25% heater on a random other table |
| Receipt Printer | Proc `receipt_printer_cascade` | Stack win: every Zoom table settles now |
| Cleaning Robot | Proc `cleaning_robot_overdrive` | Stack win: cursors 2x speed for 10s |

### 2.4 Zoom

Zoom is volume. Global hand counters fill fastest with Zoom open, and two
items aim specifically at Zoom tables.

| Item | Role | Effect |
|---|---|---|
| Headset | Stat | +6% win chance at Zoom |
| Handheld | Stat | +3% win chance at Zoom |
| Energy Drink | Proc `energy_drink_caffeine`, `on_hand_played` every 25 | Heater on a random Zoom table (corrupt every 10) |
| Wall Clock | Proc `wall_clock_century`, `on_hand_won` every 100 | Heater on a random other table (corrupt adds losses 1.5x) |
| House Cat | Proc `house_cat_nap`, `on_hand_won` every 50 | Random other table's next win reads a tier higher (corrupt every 25) |
| Framed Diploma | Proc `framed_diploma_century`, `on_hand_won` every 100 | Every table rolls 1/3 heater, 1/3 tilt, 1/3 nothing (corrupt adds wins pay 0.7x) |
| Receipt Printer | Proc `receipt_printer_cascade` | Stack win anywhere: all Zoom tables `resolve_now` |
| Copy Machine | `cascade_deals_empty` | The cascade also deals idle Zoom tables |

### 2.5 6-max (the tank)

The only mode that wants a full inbox. Its items fire on statuses landing
ON a 6-max and convert them outward.

| Item | Role | Effect |
|---|---|---|
| Bonsai | Key | `six_max_unlocked`: opens the mode |
| Desk Plant | Stat | +6% win chance at 6-max |
| Desk | Start | Run starts with 1 free NL2 6-max table (corrupt 6) |
| Microwave Oven | Proc `microwave_oven_vent`, tilt lands on a 6-max | 50% a random other table catches a heater (corrupt adds losses 1.5x) |
| Fire Extinguisher | Proc `fire_extinguisher_compress`, tilt refreshes an already-tilted 6-max | Adjacent table catches a heater (corrupt adds wins 0.75x) |
| Blackout Curtains | Proc `blackout_curtains_read`, fresh heater on a 6-max | 50% adjacent table catches a heater (corrupt adds losses 1.6x) |
| Console Television | Router `console_television_intercept` | 50% a 6-max steals any status aimed at an adjacent table, good or bad (corrupt adds wins 0.5x) |
| Hidden Tilt | Proc `tilt_cooler` | A 6-max Stack loss tilts an adjacent table (the mode's built-in cost) |
| Desk Speakers (corrupt) | Stat | -10% win chance at 6-max |

Chain: Bonsai, Microwave Oven, Fire Extinguisher, Blackout Curtains,
Console Television.

### 2.6 Tournaments (KO)

| Item | Role | Effect |
|---|---|---|
| Desk Speakers | Stat | +5% win chance at tournaments |
| Prize Vase | Proc `prize_vase_ratchet`, `on_tournament_win` | Every table +1% win chance for the run, stacking (corrupt 3%) |
| Whiteboard | `ratchet_gain_mult` 2.0 | Each ratchet grant doubled |
| High Roller Pass | `tourney_backing` 0.01 | Cash tables at a stake gain +1% per finish of a still-open tournament there |
| Window | Router `window_bend` | While a tournament runs, 35% of tilts aimed at its stake arrive as heaters |
| Curved Monitor | Proc `curved_monitor_heater`, `on_ko` 20% | Heater on a table within 2 cells, escalates with busts (corrupt 30%, hits every table in range, losses 1.5x) |
| Tower Upgrade | Proc `tower_upgrade_bump`, `on_ko` 15% | A cash table within 2 cells gets next win a tier higher (corrupt 25%, all in range, plus Medium loss to Large 35%) |
| Shredder | Proc `shredder_refund`, `on_ko` 12% | Refunds an adjacent cash table's buy-in (corrupt 25%, wins 0.7x) |
| First Aid Kit | Proc `first_aid_kit_biggest`, `on_ko` 10% | Pays out your biggest open buy-in (corrupt adds wins 0.7x) |
| Hidden Tilt | Proc `tilt_miss`, `on_tournament_miss` | Busting a tournament tilts every adjacent table |

Chains: Prize Vase, then Curved Monitor, Tower Upgrade, Shredder. Prize
Vase, then Whiteboard. Prize Vase, then High Roller Pass, then Window.

### 2.7 Heat (heater sources)

Everything that puts a heater on a table. A heater is a punch: the hand it
lands in wins and so does the next.

| Item | Trigger | Lands on |
|---|---|---|
| Energy Drink | Every 25 hands played | Random Zoom table |
| Wall Clock | Every 100 hands won | Random other table |
| Framed Diploma | Every 100 hands won | Every table, 1/3 odds each |
| Dogs Playing Poker | Stack win, 25% | Itself |
| Gaming Chair | Stack win, 30% | Adjacent table |
| Candle | Stack win, 25% | Random other table |
| Curved Monitor | Knockout, 20% | Table within 2 cells |
| Microwave Oven | Tilt on a 6-max, 50% | Random other table |
| Fire Extinguisher | Tilt refresh on a 6-max | Adjacent table |
| Blackout Curtains | Heater on a 6-max, 50% | Adjacent table |
| Cool Towel | Tilt spent, 25% | Itself |
| Nightstand | Rebuy, 50% | Itself (corrupt 100%) |
| Rolled Vouchers | First table opened at a stake | Itself (corrupt every table opened) |
| Window | Router | Converts 35% of incoming tilts to heat at a running tournament's stake |

### 2.8 Tilt (sources, redirection, conversion)

| Item | Role | Effect |
|---|---|---|
| Hidden Tilt | Source | Tournament bust tilts adjacent tables; 6-max Stack loss tilts an adjacent table |
| Framed Diploma | Source | 1/3 of every table tilts every 100 hands won |
| Dish Soap | Router `dish_soap_deflect` | 25% a tilt lands on the adjacent table instead |
| Waste Basket | Router `basket_corner` | 35% a tilt aimed at a non-6-max lands on the top-left corner table (corrupt 70%) |
| Window | Router `window_bend` | 35% tilts at a running tournament's stake arrive as heat |
| Console Television | Router | A 6-max steals statuses, tilts included, aimed at its neighbour |
| Cool Towel | Proc `cool_towel_burnout` | After a tilt's punch is spent, 25% the table heats |
| Microwave Oven | Proc | Tilt landing on a 6-max: 50% heater elsewhere |
| Fire Extinguisher | Proc | Second tilt on a tilted 6-max: adjacent heater |

Chain: Dish Soap, then Cool Towel and Waste Basket.

### 2.9 Positioning (where a table sits on the board matters)

Adjacent means sharing a side, Manhattan distance on the board grid. The
player aims these by dragging tables.

| Item | Geometry | Effect |
|---|---|---|
| Red Rug | Top-left cell | +2% win chance |
| Waste Basket | Top-left cell | Tilts redirected there |
| Gaming Chair | Radius 1 | Stack-win heater on a neighbour |
| Dish Soap | Radius 1 | Tilt deflected to a neighbour |
| Fire Extinguisher | Radius 1 | Heater on a 6-max's neighbour |
| Blackout Curtains | Radius 1 | Heater spreads to a 6-max's neighbour |
| Console Television | Radius 1 | 6-max steals a neighbour's status |
| Shredder | Radius 1 | Knockout refunds a neighbour's buy-in |
| Curved Monitor | Radius 2 | Knockout heats a table in range |
| Tower Upgrade | Radius 2 | Knockout bumps a table in range |
| Window | Same stake as the running tournament | Tilt to heat while it runs |
| Hidden Tilt | Radius 1 | Both tilt procs hit neighbours |

### 2.10 Cursors (automation)

| Item | Effect | Corrupt |
|---|---|---|
| Box of Mice | `cursor_unlocked`: the swarm and the Cursor upgrade | +8 cursors |
| Laptop Terminal | `cursor_count_add` +1 | +4 |
| Gaming Keyboard | `cursor_speed_mult` 1.30 | `cursor_instant_click` |
| Wacom Tablet | `cursor_rebuy_unlocked`: cursors click REBUY | plus rebuys 20% off |
| Desk Lamp | `cursor_optical_sensor`: no trackball-cleaning pauses | plus `cursor_memory_unlocked` |
| Telephone | `cursor_sync_unlocked`: no two target the same table | none |
| Glass Partition | `cursor_collision_phasing`: no bumping | none |
| Cleaning Robot | Stack win: `cursor_speed_mult` 2.0 for 10s | none |

Chain: Box of Mice root; Laptop Terminal, Gaming Keyboard, Wacom Tablet,
Desk Lamp off it; Telephone and Glass Partition off Laptop Terminal;
Cleaning Robot off Gaming Keyboard.

### 2.11 Run upgrades (the in-run upgrade shop)

| Item | Effect | Corrupt |
|---|---|---|
| Calculator | `run_upgrade_strength_mult` +15% on Sharper Reads and Pot Control | +150% |
| Ring Binder | `run_upgrade_cost_mult` 0.85 | 0.20 |
| Bookshelf | `run_upgrade_bonus_levels` +1 on every upgrade | +4 |
| Box of Mice | Unlocks the Cursor upgrade | |

### 2.12 Run start (bankroll and tables at the beginning of a run)

| Item | Effect | Corrupt |
|---|---|---|
| Starter Gift Box | `start_bankroll_pct` +50% | 25x last run's bankroll |
| Stash Box | `start_bankroll_add` +$5 | +$100,000 |
| Cereal Shelf | `start_biggest_pot` scope t1: start with last run's biggest NL2 pot | any stake |
| Desk | `start_table_count` 1 | 6 |
| Rolled Vouchers | First table at each stake opens hot | every table |

### 2.13 Rebuys, busts and buy-ins (the cash-table sustain)

| Item | Effect | Corrupt |
|---|---|---|
| Rebuy Sticky Note | `rebuy_discount` 25% | 75% |
| Electric Kettle | `bust_refund_pct` 30% of buy-in back on bust | 120% |
| Nightstand | Rebuy: 50% heats that table | 100% |
| Wacom Tablet | Cursors click REBUY | plus 20% rebuy discount |
| Shredder | Knockout: 12% refunds a neighbour's buy-in | 25% |
| First Aid Kit | Knockout: 10% pays your biggest buy-in | same, wins 0.7x |

### 2.14 {chip} economy (the meta currency)

| Item | Effect | Corrupt |
|---|---|---|
| Fight Night Poster | HU bounties pay 2x {chip} | 4x |
| Pencil Holder | +1 {chip} on every Stack win | +4 |
| Tip Jar | `chip_award_mult` 1.50 on all bounties | 4.0 |
| Bonsai | Opens the 6-max bounty ladder by opening the mode | |

### 2.15 Focus (multi-tabling capacity)

| Item | Effect | Corrupt |
|---|---|---|
| Second Monitor | `focus_capacity_add` +2 | +6 |

The only catalog item that touches focus. Gaming Chair's unlock counts
hands past focus but its effect is a heater proc.

### 2.16 Decks

| Item | Effect | Corrupt |
|---|---|---|
| Laminated Blueprint | `deck_xp_mult` 1.50 on the active deck | 8.0 |

### 2.17 Tier bumps (next-win-reads-higher enchants)

Distinct from the flat tier shifts in 2.1: these mark ONE table's next win.

| Item | Trigger | Target |
|---|---|---|
| House Cat | Every 50 hands won | Random other table |
| Tower Upgrade | Knockout, 15% | Cash table within 2 cells |

### 2.18 Gates and keys (items that open a mode or stake)

| Item | Opens |
|---|---|
| Bonsai | 6-Max tables |
| Box of Mice | Cursor swarm and the Cursor upgrade |
| Ultra Stake | T10 ULTRA stake (Act 3, corrupt purchase only, 25 {achip}) |

### 2.19 Anti-{chip} (Act 3 corruption payouts)

Effects that only exist in corrupt blocks and pay the Act 3 currency.

| Item (corrupt) | Effect |
|---|---|
| Comfort Bed | `anti_award_mult` 2.0: Stack losses pay {achip} twice |
| Compact Fridge | `first_anti_mult` 3.0: first Stack loss each run pays {achip} 3x |

---

## 3. Grouping by trigger shape

A second cut, for tuning: what kind of moment an item waits for.

| Shape | Items |
|---|---|
| Always on (no trigger) | Corkboard, Yellow Sticky Note, Space Heater, Wall Hanger, Stack of Books, Lava Lamp, Chrome Toaster, Throw Pillow, Comfort Bed, Mirror, Dusty Console, Headset, Handheld, Desk Plant, Desk Speakers, Red Rug, Fight Night Poster, Pencil Holder, Tip Jar, Calculator, Ring Binder, Bookshelf, Rebuy Sticky Note, Electric Kettle, Second Monitor, Laminated Blueprint, Whiteboard, High Roller Pass, all cursor flags |
| Once per run | Rubber Duck, Compact Fridge, Starter Gift Box, Stash Box, Cereal Shelf, Desk |
| Hand counter | Energy Drink (25 played), House Cat (50 won), Wall Clock (100 won), Framed Diploma (100 won) |
| Stack win | Dogs Playing Poker, Gaming Chair, Candle, Receipt Printer, Cleaning Robot, Pencil Holder |
| Stack loss | Hidden Tilt (6-max only) |
| Knockout | Curved Monitor, Tower Upgrade, Shredder, First Aid Kit |
| Tournament win | Prize Vase |
| Tournament bust | Hidden Tilt |
| Status lands on a 6-max | Microwave Oven, Fire Extinguisher, Blackout Curtains |
| Status is spent | Cool Towel |
| Rebuy | Nightstand |
| Table opened | Rolled Vouchers |
| Router (intercepts deliveries) | Dish Soap, Waste Basket, Window, Console Television |

---

## 4. Grouping by what lands

| Payload | Items |
|---|---|
| Heater on a table | Energy Drink, Wall Clock, Framed Diploma, Dogs Playing Poker, Gaming Chair, Candle, Curved Monitor, Microwave Oven, Fire Extinguisher, Blackout Curtains, Cool Towel, Nightstand, Rolled Vouchers |
| Tilt on a table | Hidden Tilt, Framed Diploma |
| Next win a tier higher | House Cat, Tower Upgrade |
| Money back | Shredder, First Aid Kit, Electric Kettle |
| Tables resolve now | Receipt Printer (plus Copy Machine deals the idle ones) |
| Permanent run-wide win chance | Prize Vase (doubled by Whiteboard) |
| Timed cursor buff | Cleaning Robot |
| Redirected or transformed status | Dish Soap, Waste Basket, Window, Console Television |

---

## 5. Items with multiple homes

The items that sit in two or more system groups above:

| Item | Groups |
|---|---|
| Framed Diploma | Zoom counter, Heat, Tilt |
| Window | Tournaments, Heat, Tilt, Positioning |
| Console Television | 6-max, Tilt, Positioning |
| Fire Extinguisher | 6-max, Heat, Tilt, Positioning |
| Blackout Curtains | 6-max, Heat, Positioning |
| Microwave Oven | 6-max, Heat, Tilt |
| Waste Basket | Tilt, Positioning |
| Dish Soap | Tilt, Positioning |
| Gaming Chair | Heads-Up, Heat, Positioning |
| Curved Monitor | Tournaments, Heat, Positioning |
| Tower Upgrade | Tournaments, Tier bumps, Positioning |
| Shredder | Tournaments, Rebuys and buy-ins, Positioning |
| Receipt Printer | Heads-Up, Zoom |
| Cleaning Robot | Heads-Up, Cursors |
| Nightstand | Heat, Rebuys |
| Rolled Vouchers | Heat, Run start |
| Wacom Tablet | Cursors, Rebuys |
| Pencil Holder | Heads-Up, {chip} economy |
| Box of Mice | Cursors, Run upgrades, Gates |
| Bonsai | 6-max, Gates, {chip} economy |
| Desk | 6-max, Run start |
| Hidden Tilt | 6-max, Tournaments, Tilt, Positioning |
