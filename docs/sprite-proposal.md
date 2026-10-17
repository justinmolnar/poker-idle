# Sprites: one room, eight zones (2026-09-07)

Proposed and APPLIED the same day (names, sprites, the sound files that
could move, the room cells that could move). Ids are frozen (live saves).
Every item plays its OWN sound file (assets/audio/items/<id>.ogg); nothing
shares a file. The "share" notes in the tables below were the proposal's
shorthand for "a similar sound"; each of those still needs its own file.

## The frame

The player is held in one room and plays poker. Everything in the book is
something the House ships to that room. So every card has to be a thing a
person kept in a room would want, use, or be unsettled by. Office
furniture for a company of forty (a glass partition, a copier, a shredder,
a whiteboard, a diploma) fails that test. A bath, a kettle, a wine bottle,
a cat, a fake window, a blueprint of the building pass it.

The pack (assets/sprites/TinyHouse) is already sorted into zones:
Bathroom, Bedroom, Books, Kitchen, Office desk, Computer, Consoles, Living
room, Plants, Posters, Windows. Eight shelves, eight zones. A shelf's cards
come from one zone, so the book reads as a floor plan and the room fills
in by zone as the player buys down a shelf.

| shelf (id) | identity | zone of the room |
|---|---|---|
| Stats | the flat numbers, where the tables sit | **the bed corner** (bed, pillow, nightstand, hook, lamp, books, notes) |
| Rack | run upgrades, prices, how a run starts | **the desk and the pantry** (desk, calculator, binder, shelf, fridge, cereal) |
| Heads-Up | stacks and bounties, the duel | **the trophy wall** (posters, mirror, chair, consoles, jar, candle) |
| Zoom | speed, hands per second | **the arcade shelf** (handhelds, cat, clock, printer, washer, replay TV) |
| 6-Max | the board, neighbours, heat spreading | **the living room** (plants, rug, TV, curtains, heater, blueprint) |
| Tournaments | knockouts, busts, rebuys | **the bathroom** (bath, towel, tissues, duck, shower, medical kit) |
| Mental | heat and tilt | **the kitchen** (stove, pan, kettle, microwave, soap, bin, wine) |
| Cursors | the rig that clicks for you | **the computer** (mice, laptop, keyboards, tablet, phone, PC, lamp, robot) |

Value Buys stays one intro per shelf and each intro is from its shelf's zone.

## Budget

| | today | proposed |
|---|---|---|
| items that change sprite | | 14 (8 of them change what the thing IS) |
| items that change name only | | 2 |
| sound files to find | 25 items had none | **27** (every item has its own file; four retired files came back, five mismatched ones went to unassigned/) |
| room cells to place | 27 unplaced | **26**, of which about half are wall hangs or sit on placed furniture (the editor's `homes`, no floor cell) |
| sound files reused from retired items | | 3 (duck, kettle, drawer) |
| placements reused from retired items | | 2 (duck, kettle) |

Legend below: **sound** keep = file exists; share:X = play X's family (no new
file); reuse:X = a retired item's file, copied to this id; NEW = find one.
**room** placed = in data/room_layout.lua today; wall = a wall hang; home =
sits on an already placed item; NEW = needs a floor cell.

## Value Buys (page one, one per shelf)

| id | name | sprite (TinyHouse/…) | sound | room | note |
|---|---|---|---|---|---|
| corkboard | Corkboard | Office/Corkboard_2 | keep | placed | "one photo of a beach": the captive's corkboard. Stats intro. |
| starter_gift_box | Starter Gift Box | Present/Present_100 | keep | placed | Rack intro. |
| energy_drink | Energy Drink | Kitchen/Cola | keep | placed | Zoom intro. |
| gaming_poster | Gaming Poster | Poster/Poster_5 | share:frame (dogs_playing_poker) | wall | HU intro. |
| bonsai | Bonsai | Japanese_Room/Bonsai | share:plant (desk_plant) | home (on the desk) | 6-Max intro. |
| prize_vase | Prize Vase | Japanese_Room/Japanese_Vase | keep | placed | Tournaments intro. Not bathroom, but it is the trophy; the WC (Bathroom/WC_Ani, animated) is the pointed alternative if you want the intro to be the first fixture of a bathroom the room does not have. |
| nightstand | **Chrome Toaster** | Kitchen/Toaster_Ani | swap with chrome_toaster | swap | Mental intro must be kitchen: this id becomes the toaster ("Rebuy: 1 in 2 the table catches a heater. Two slots. One setting. Pops without warning."). The two ids swap name, sprite, sound file and room entry; zero new assets. |
| box_of_mice | Box of Mice | Office/White_Box | keep | placed | Cursors intro. |

## Stats: the bed corner

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| wall_hanger | Wall Hook | Bathroom/Hanger | keep | placed | name only: "hanger" reads as a coat hanger. |
| throw_pillow | Throw Pillow | Sofa/Pillow_11 | keep | placed | |
| stack_of_books | Stack of Books | Books/Books_Pile | keep | placed | |
| yellow_sticky_note | Yellow Sticky Note | Office/Sticky_Note_1 | keep | placed | a note above the bed. |
| lava_lamp | Lava Lamp | LavaLamp_Ani | keep | placed | |
| comfort_bed | Comfort Bed | Bedroom/Bed_A_4 | keep | placed | |
| cutting_board | **Tally Book** | Books/Notebooks | share:paper (pencil_holder pen click) | home (on the nightstand) | the one card whose effect is the player's own streak ("wins in a row on hands you deal yourself") is a captive keeping his own count. A cutting board on the bed shelf is a kitchen thing with nothing to cut. |
| chrome_toaster | **Nightstand** | Bedroom/Night_Table_Tile | swap with nightstand | swap | "1 in 12 a win lands one size up. One drawer. You never know what is in it." |

## Rack: the desk and the pantry

All eight have sounds and placements. No sprite changes.

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| desk | Desk | Desks/Desk_1_Tile | reuse:stash_box (drawer) | placed | the only Rack card with no sound; the retired Stash Box's drawer is the desk drawer. |
| ring_binder | Ring Binder | Books/Ring_Binder_Green | keep | placed | |
| calculator | Calculator | Office/Calculator | keep | placed | |
| rebuy_sticky_note | Rebuy Sticky Note | Office/Sticky_Note_2 | keep | placed | |
| compact_fridge | Compact Fridge | Kitchen/Fridge/Fridge_2_A_Tile | keep | placed | provisions: what the room has when you wake. |
| second_monitor | Second Monitor | Computer/NewImac_A_Tile | keep | placed | |
| bookshelf | Bookshelf | Living Roon/shelving_6 | keep | placed | |
| cereal_shelf | Cereal Shelf | Kitchen/Cereals | keep | placed | |

## Heads-Up: the trophy wall

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| mirror | Mirror | Bathroom/Mirror | keep | placed | "You should see yourself. And yourself." |
| dusty_console | Dusty Console | Consoles/NES | share:console (NEW family, see Zoom) | home (under the TV) | "Two controllers. Built for one-on-one." |
| dogs_playing_poker | Dogs Playing Poker | Poster/Poster_4 | keep | placed | |
| candle | Candle | Japanese_Room/Candle | NEW (match strike) | home (on the trophy shelf) | |
| trophy_shelf | Trophy Shelf | Living Roon/shelving_7 | share:ceramic (prize_vase) | wall | |
| pencil_holder | Pencil Holder | Office/Pencil_Holder | keep | placed | keep. Optional: Office/Photos ("Polaroids of every table you have beaten, +1 on every bounty") reads better on a trophy wall; costs one placement, shares the frame sound. |
| gaming_chair | Gaming Chair | Chairs/Gaming Chair/GChair_9_A | keep | placed | |
| tip_jar | Tip Jar | Kitchen/Glass_1 | keep | placed | |

## Zoom: the arcade shelf

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| handheld | Handheld | Consoles/Gameboy | share:console | home (on the desk) | |
| headset | Headset | Office/Headset | keep | placed | |
| house_cat | House Cat | Cat_Ani (animated) | NEW (meow) | home (on the bed) | |
| wall_clock | Wall Clock | Office/Clock_Ani | keep | placed | |
| framed_diploma | **Switch** | Consoles/Nintendo_Switch | share:console | home (under the TV) | a captive has no diploma. "+2% at Zoom per hand per second the board plays": "Docked. The faster the board runs, the better it plays." Loses the glass-tap sound, gains the console family. |
| receipt_printer | Receipt Printer | Office/Printer_Ani | keep | placed | keep: it prints the House's slips (the manifest is a receipt). |
| copy_machine | **Replay TV** | Televisions_TV/Tv_DVD_Ani (animated) | NEW (VCR whir) | NEW | a copier in a cell is absurd. "A Zoom hand counts as two. The replay. Every hand, played back." |
| washing_machine | Washing Machine | Kitchen/Washing_Machine_Ani (animated) | NEW (spin) | NEW | |

The console family: one "cartridge click" file shared by Dusty Console,
Handheld and the Switch.

## 6-Max: the living room

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| desk_plant | Desk Plant | Plants/Plant_1 | keep | placed | |
| red_rug | Red Rug | Carpets/Carpet_Red | share:cloth (throw_pillow) | NEW (floor, under the sofa cell) | |
| space_heater | Space Heater | Office/AC | keep | placed | |
| floor_plant | Floor Plant | Plants/Plant_5 | share:plant | NEW | |
| laminated_blueprint | Laminated Blueprint | Office/Blueprint | keep | placed | KEEP, and lean on it: the blueprint of the building on a captive's wall is the escape plan. "The plan, drawn out. Nobody else can read it." already says so. |
| fire_extinguisher | Fire Extinguisher | Office/Fire_Extinguisher | keep | placed | "Inspection tag expired a long time ago." A fire extinguisher that spreads fire. Keep. |
| blackout_curtains | Blackout Curtains | Windows/Window_11_B | keep | wall | "No window behind them. Still helps." Keep. |
| console_television | Console Television | Televisions_TV/BigTv_Ani | keep | placed | |

## Tournaments: the bathroom

The room has no bathroom. The House sends one piece at a time, and every
piece is about getting knocked out and getting back in.

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| medical_poster | Medical Poster | Poster/Poster_Medical | share:frame | wall | |
| first_aid_kit | First Aid Kit | Office/Medical_Kit_Ani | keep | placed | |
| curved_monitor | **Hot Bath** | Bathroom/Bath_Ani (animated) | NEW (water; shared with the shower) | NEW (2 cells) | "A knockout: 1 in 5 a table adjacent to the tournament catches a heater. Steam. It gets into the next room." The monitor's beep is dropped. |
| tower_upgrade | **Fresh Towel** | Bathroom/Hanging_Towel | NEW (towel snap) | wall | "A knockout: 1 in 6 an adjacent cash table's next win lands one size up." The tower's boot sound and floor cell move to the Beige Tower on Cursors. |
| shredder | **Box of Tissues** | Bathroom/Tissues | share:paper | home (on the bath edge) | "A knockout: 1 in 8 an adjacent cash table gets its buy-in back. For the busts." |
| whiteboard | **Rubber Duck** | Bathroom/Duck | reuse:rubber_duck | reuse:rubber_duck | "A tournament win: +2% odds at every table for the run. Squeak. It saw the whole thing." The retired duck's sound and placement come back for free. |
| high_roller_pass | **Shower Head** | Bathroom/Tap_Shower | share:water | wall | "Each tournament a table finishes: +1% odds at its stake's cash tables. Rinse. Repeat." |
| window | Window | Bathroom/Bath_window | keep | wall | sprite only: the bathroom window, still "the view is not included". |

## Mental: the kitchen

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| rolled_vouchers | **Bottle of Wine** | Kitchen/Wine | NEW (cork) | placed (vouchers' cell) | "Open your first table at a stake: it catches a heater. A new stake is an occasion." Coupons are the House's paper; a bottle is what the captive would ask for. If you would rather keep the vouchers (sound and placement exist), they are not wrong, only dull. |
| dish_soap | Dish Soap | Kitchen/Dish_Soap | NEW (squirt) | home (on the sink or fridge) | |
| cool_towel | **Electric Kettle** | Kitchen/Ketel | reuse:electric_kettle | reuse:electric_kettle | "A tilt ends: 1 in 4 that table catches a heater. Boils fast. Whistles louder." A cool towel that starts fires was backwards; the retired kettle's sound and cell come back. |
| waste_basket | Kitchen Bin | Kitchen/TrashBin_Closed | NEW (lid) | NEW | sprite only: the kitchen bin, not the office one. |
| desk_speakers | Desk Speakers | Living Roon/Speaker_6_Tile | keep | placed | keep. (The voice doc's "shitty radio" is a separate fixture; this is the pair he lets you buy.) |
| cast_iron_pan | Cast Iron Pan | Kitchen/Frying_Pan | NEW (clang) | home (on the stove) | |
| microwave_oven | Microwave Oven | Microwave/Microwave_5_Tile | keep | placed | |
| gas_stove | Gas Stove | Kitchen/Stoves | NEW (igniter click) | NEW | |

## Cursors: the rig

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| laptop_terminal | Laptop Terminal | Computer/MacBook_Ani | keep | placed | |
| old_keyboard | Old Keyboard | Computer/OldKeyboard_Tile | share:keyboard (gaming_keyboard) | home (on the desk) | |
| telephone | Telephone | Office/Telephone | NEW (one ring) | home (on the nightstand) | keep: a phone that only reaches the tables is the right kind of wrong. |
| wacom_tablet | Wacom Tablet | Computer/WacomTablet | keep | placed | |
| desk_lamp | Desk Lamp | Lamp/Lamp_8_A_Tile | share:switch (assets/audio/room/light_switch) | home (on the desk) | |
| glass_partition | **Beige Tower** | Computer/OldPC_A_Tile | reuse:tower_upgrade (8-bit boot) | reuse:tower_upgrade (its cell) | "A lit cursor clashes with another: it lights too. Runs hot. So does everything plugged into it." A glass wall means nothing to one person in one room. |
| gaming_keyboard | Gaming Keyboard | Computer/NewKeyboard_Tile | keep | placed | |
| cleaning_robot | Cleaning Robot | Cleaning_Robot_Ani (animated) | NEW (whir) | NEW (it roams; one cell) | |

## Ultra

| id | name | sprite | sound | room | note |
|---|---|---|---|---|---|
| ultra_stake | Ultra Stake | Japanese_Room/Japanese_Tori_Gate | keep | placed | the gate is the only card that is a door. Keep. |

## Sounds still to find (27)

Gaming Poster (`gaming_poster`), Tally Book (`cutting_board`), Bonsai (`bonsai`), House Cat (`house_cat`), Candle (`candle`), Trophy Shelf (`trophy_shelf`), Dusty Console (`dusty_console`), Handheld (`handheld`), Red Rug (`red_rug`), Dish Soap (`dish_soap`), Bottle of Wine (`rolled_vouchers`), Desk Lamp (`desk_lamp`), Telephone (`telephone`), Old Keyboard (`old_keyboard`), Medical Poster (`medical_poster`), Hybrid Console (`framed_diploma`), Washing Machine (`washing_machine`), Floor Plant (`floor_plant`), Gas Stove (`gas_stove`), Cast Iron Pan (`cast_iron_pan`), Hot Bath (`curved_monitor`), Fresh Towel (`tower_upgrade`), Replay TV (`copy_machine`), Shower Head (`high_roller_pass`), Box of Tissues (`shredder`), Kitchen Bin (`waste_basket`), Cleaning Robot (`cleaning_robot`)

In `assets/audio/items/unassigned/`: the five files whose items became something else (beep, glass tap, paper rip, shredder, card draw), kept for reuse.

## Room cells still to place (26)

Gaming Poster (`gaming_poster`), Tally Book (`cutting_board`), Bonsai (`bonsai`), House Cat (`house_cat`), Candle (`candle`), Trophy Shelf (`trophy_shelf`), Dusty Console (`dusty_console`), Handheld (`handheld`), Red Rug (`red_rug`), Dish Soap (`dish_soap`), Desk Lamp (`desk_lamp`), Telephone (`telephone`), Old Keyboard (`old_keyboard`), Medical Poster (`medical_poster`), Washing Machine (`washing_machine`), Floor Plant (`floor_plant`), Gas Stove (`gas_stove`), Cast Iron Pan (`cast_iron_pan`), Hot Bath (`curved_monitor`), Fresh Towel (`tower_upgrade`), Replay TV (`copy_machine`), Shower Head (`high_roller_pass`), Window (`window`), Blackout Curtains (`blackout_curtains`), Kitchen Bin (`waste_basket`), Cleaning Robot (`cleaning_robot`)

The cells that moved with a reskin (Nightstand/Toaster swap, Duck, Kettle, Beige Tower) are tuned for the old sprite and want a pass in the room editor.

## What this does NOT touch

Ids, effects, prices, gates, chains, shelf membership, the story. The
department titles in data/catalog_pages.lua could take the zone names
("BED & BATH", "KITCHEN") but that is a separate copy call.
