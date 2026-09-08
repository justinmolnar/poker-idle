# Sound checklist

Every sound the build wants, one line each, so they can be sourced in one
sitting. Cross-referenced 2026-09-04 (items and the room rechecked 2026-09-08) against `data/sounds.lua` (the named
presets), every `playNamed` / timeline beat / `arrival_sound` in the code,
`assets/audio/` on disk, and the catalog's item ids. Companion to
`docs/audio-audit.md` (the why).

Marks: `[x]` a real file is in and wired · `[~]` wired, but playing a stand-in
(a chip or card from the pack, or a legacy MP3) · `[ ]` nothing yet.
`(wire)` = the code has no call for it; a file alone won't play, ask for the
hook. Files drop into `assets/audio/<folder>/<name>.ogg` and pair by name
(`services/SoundLoader`); presets in `data/sounds.lua` win when they exist.

Length guide: foley 0.1–0.5s, UI 0.1–0.3s, stingers under 2s, loops 60–120s.
Mono for everything but music. OGG.

## 1. Music

The director plays whatever is in `assets/audio/music/` through the
intercom chain (muffled until Desk Speakers). Ten noir tracks are in there
now.

- [x] room / grind loop | whatever plays on the grind; decide if the noir pack is final or a placeholder for the lo-fi Rhodes loop the audit wants | grind, room
- [ ] `music_layer_bass` (wire) | a bass line under the same loop, same key and tempo | Act 2 grind
- [ ] `music_layer_hiss` (wire) | tape hiss / vinyl crackle bed, loopable | Act 3, louder after the underflow
- [ ] `music_gauntlet_drone` (wire) | one sustained low tone, pitchable up per runout | the gauntlet felt
- [~] title / credits | the title already plays the loop through the intercom (MusicDirector treats it like the grind; its header comment saying "silence" is stale); credits are silent. Decide if that stays | title, credits

## 2. The House

- [x] `radio/open/*` | mic keying on, static burst; ONE file now, want 4–6 so the key-up varies | every speech bubble starts
- [x] `radio/voice/*` | distorted voice bed, ONE file now, want 3–4 different textures | while his text types
- [ ] `house_tick` (wire) | one soft Rhodes note or a single typewriter key, the same every time | each block of text lands
- [ ] `house_tick_low` (wire) | the same, lower | the panic lines ("No." "Again.")
- [ ] `house_stinger` (wire) | one low piano note left to ring, 1.5–2s | first cheat card, the Act 2 lede, the underflow, deck_out

## 3. The room count and the cut (shove intro)

- [x] `lights_on` | switch plus the tube coming on | the fixture blooms
- [x] `lights_off` | the switch alone | the fixture dies
- [~] room-count tick | each item plays its own file, or falls back to a chip click for the ones without one (section 6) | each item counted
- [ ] `room_lock` | a latch, or a light switch on its own | the count locks (wired by name, silent)
- [ ] `number_lift` (wire) | short whoosh (`whoosh.mp3` may do) | ITEMS and BANK lift off the room
- [~] `card_snap` | the number lands: currently a card give from the pack | ITEMS / BANK land in their slot
- [~] `shove_initiated` | a card riffle from the pack; fine, or a deck shuffle proper | the buildup starts
- [~] `chip_land_pot` | a chip from the pack, pitched up per landing; fine | each chip of the pour lands

## 4. The felt (the gauntlet)

- [~] `card_dealt` / `cheat_card_dealt` | the pack's card give; fine, the cheat is the heavier take | hole and board cards land; cards 6 and 7
- [~] `hole_card_flip` | the pack's card give; a distinct FLIP (card turning over) would separate the deal from the reveal | your cards turn, the dealer's turn
- [~] `runout_won` | coins from the pack | a won runout, R1/R2
- [~] `gauntlet_won` | legacy `victory_fanfare.mp3`; want a short clean fanfare under 1.5s | the full clear
- [~] `gauntlet_lost` | legacy `game_over.mp3`; want one chip sliding off felt, no jingle | a lost runout
- [~] `chip_land_you` | a chip from the pack | the pot arrives at you
- [ ] `catalog_thud` | heavy paper thud, a book on a table | the book lands on the felt (wired, silent)
- [~] pamphlet landing | plays `hole_card_flip`; want a light paper slap | the pamphlet lands beside the book
- [x] `deck_card_degraded_1..3` | rendered from the pack's deal | the ending flood

## 5. The grind

- [~] `card_dealt` | pack card give, once per seat as the backs land | the new hand is dealt
- [ ] fold / muck (wire) | a card slid off felt, soft | a seat folds; the old hand mucks on the next deal
- [~] `pot_won_small/medium/large/stack` | pack chip stacks, coins layered on a Stack; fine | a hand resolves
- [~] `pot_lost_small/medium/large/stack` | pack chips; the Stack layers legacy `negative_buzz.mp3`, replace that with a low thud | a hand loses
- [~] `border_pulse_win/loss` | pack chips at tier volume; could be dropped once the pot sounds carry it | every resolution
- [~] `chip_land_bankroll` | pack chip drop; fine | chips reach the bankroll
- [~] `table_added` | pack chip drop; want a chair pulled up | a table opens
- [ ] table close / cash out (wire) | chair pushed in | a table is cashed out
- [~] `rebuy_clack` | pack chip drop; want a stack set down | REBUY
- [~] `upgrade_purchased` | pack chip drop; want a soft mechanical click, not a chip | a run upgrade is bought
- [~] `stake_up_flourish` | pack chips plus coins; fine | a new stake opens
- [~] `seat_ko` | heaviest pack drop; fine | a tournament seat busts
- [ ] tournament won (wire) | a short clean sting, distinct from the shove's | TOURNAMENT WON floater
- [ ] busted (wire) | one dull knock | a table busts (BUSTED floater)
- [ ] focus overload (wire) | a short strained tone | focus over the cap
- [~] `cursor_tap` | pack chip at 18%; want a real mouse click, quiet | a cursor clicks a table
- [ ] cursor bump (wire) | tiny plastic knock | two cursors collide (the sparks)
- [ ] tilt lands (wire) | glass tipping / a knock going wrong | a tilt is applied to a table
- [ ] heater lands (wire) | a match strike, short | a heater is applied
- [ ] punch: shove (wire) | a shove of furniture across a floor | a table shoves its neighbour
- [ ] punch: slam (wire) | fist on a table, the frame the fist lands (data/statuses slam.rise) | the slam
- [ ] deck level up (wire) | one bright note or a card fan | the deck in play levels
- [ ] new deck (wire) | a paper tab / a card turned face up | a deck unlocks
- [ ] underflow (wire) | a deep thud with a tail, 1s | the Act 3 break
- [ ] glitch tick (wire) | a short digital tear, three variants | the broken readouts' glyph ticks
- [~] `anti_chip_bank` | the bankroll chip through the damage bus; fine | an anti-chip banks

## 6. Per-item foley

Each item plays the file named after its id (`assets/audio/items/<id>.ogg`):
in the room count, and again when it fires in play. Every item has its OWN
file; nothing shares. 46 of the 72 live items are in (credited in the
folder's MANIFEST). Rechecked 2026-09-08 after the reskin: the ids are the
frozen save keys, the names are what the card says now.

- [ ] `fight_night_poster` | Fight Night Poster | a bell, one strike | count only
- [ ] `cutting_board` | Tally Book | a pencil scratch, one stroke | count only
- [ ] `bonsai` | Bonsai | leaves brushed, a snip | count only
- [ ] `house_cat` | House Cat | one short meow | 1 in 50 hands won, a random table's next win bumps
- [ ] `candle` | Candle | a match strike, short | a Stack win lights a random table
- [ ] `trophy_shelf` | Trophy Shelf | a small cup set down on wood | a bounty pays double
- [ ] `dusty_console` | Dusty Console | a cartridge blown on, a click | count only
- [ ] `handheld` | Handheld | a handheld's power tone or button click | a Zoom loss deals the next hand
- [ ] `red_rug` | Red Rug | a rug shaken out, one flap | count only
- [ ] `dish_soap` | Dish Soap | a squeeze bottle, short | a tilt slides to the next table
- [ ] `rolled_vouchers` | Bottle of Wine | a cork | the first table at a stake catches a heater
- [ ] `desk_lamp` | Desk Lamp | a lamp switch, click | count only
- [ ] `telephone` | Telephone | a receiver set down | count only
- [ ] `old_keyboard` | Old Keyboard | one stuck key | count only
- [ ] `medical_poster` | Medical Poster | paper pressed flat on a wall | a knockout revives a busted neighbour
- [ ] `framed_diploma` | Hybrid Console | a dock click | count only
- [ ] `washing_machine` | Washing Machine | the spin, short | count only
- [ ] `floor_plant` | Floor Plant | big leaves, brushed | a 6-Max Stack bumps its neighbours
- [ ] `gas_stove` | Gas Stove | an igniter click | count only
- [ ] `cast_iron_pan` | Cast Iron Pan | a pan set on a burner, clang | count only
- [ ] `curved_monitor` | Hot Bath | water, a tap run for a second | a knockout's steam heats a neighbour
- [ ] `tower_upgrade` | Fresh Towel | a towel snap | a knockout bumps a neighbour's next win
- [ ] `copy_machine` | Replay TV | tape whir, a deck loading | count only
- [ ] `high_roller_pass` | Shower Head | a shower running, short | count only
- [ ] `shredder` | Box of Tissues | one tissue pulled | a knockout refunds a neighbour's buy-in
- [ ] `waste_basket` | Kitchen Bin | a bin lid | a tilt lands in the corner
- [ ] `cleaning_robot` | Cleaning Robot | a small motor whir | count only

In `assets/audio/items/unassigned/`, five files whose items became something
else on 2026-09-07 (a beep, a glass tap, a paper rip, a shredder, a card
draw): free to reuse under a new name, or delete.

(`tilt` and `snake_case_unique` are a hidden system entry and the authoring
template; `ultra_stake` has its file; no sound for the first two.)

## 7. Paper: the catalog and the pamphlet

- [ ] catalog open (wire) | paper unfold | the book opens on the felt / from the top bar
- [~] page turn | plays `hole_card_flip`; want two or three page turns | each leaf, wheel or dog-ear
- [ ] `stamp` (wire) | rubber stamp thunk | ORDERED lands on a bought item
- [ ] `pen_scratch` (wire) | short pen scratch | the price ring is drawn
- [ ] `stamp_reverse` (wire) | the stamp reversed | a corrupt purchase
- [ ] `glyph_whine` (wire) | faint high whine, loopable, quiet | while a corrupt offer is on screen
- [ ] sticker peel (wire) | vinyl peeling off paper | a ready sticker comes off
- [ ] receipt feed (wire) | thermal printer chatter, short | the manifest prints a new row
- [ ] pamphlet open (wire) | a sheet unfolding, lighter than the book | the pamphlet opens out
- [ ] deck picked (wire) | a card tapped on a table | a tile is put in play
- [ ] flyer end card (wire) | (demo build) nothing, or the House's stinger | the demo's end sheet opens

## 8. Interface

Nothing in the interface makes a sound today except the felt and the
cursors; the click flash is silent.

- [ ] button click (wire) | one soft click, the same everywhere | any button, tab, key, row, dropdown item
- [ ] toggle / checkbox (wire) | a lighter tick | Motion levels, analytics box, D/R table toggles
- [ ] modal open / close (wire) | a paper or panel slide, in and out | Settings, glossary, confirm dialogs
- [ ] slider tick (wire) | a very quiet tick per step, or none | the volume sliders
- [ ] hint / story bubble (wire) | covered by the radio key-up; nothing else needed | a bubble opens
- [~] title deal | the pack's card give per letter card, then a chip landing for the apostrophe; fine | the name deals onto the title
- [x] title light switch | `lights_on` | Continue / New Game throw the switch
- [x] title key-up | the radio open, static only, no words | the intercom keys up while the title idles
- [ ] credits (wire) | silence, or the clean loop | the credits

## 9. The room: items with no cell

Every item is placed once, in the room editor, into `data/room_layout.lua`
(`gx, gy` on the 5x5 grid, `align` for a wall). 26 of the 72 live items have
no entry, so they do not appear in the room when owned and the shove's count
skips past them. Rechecked 2026-09-08.

- [ ] `fight_night_poster` | Fight Night Poster
- [ ] `cutting_board` | Tally Book
- [ ] `bonsai` | Bonsai
- [ ] `house_cat` | House Cat
- [ ] `candle` | Candle
- [ ] `trophy_shelf` | Trophy Shelf
- [ ] `dusty_console` | Dusty Console
- [ ] `handheld` | Handheld
- [ ] `red_rug` | Red Rug
- [ ] `dish_soap` | Dish Soap
- [ ] `desk_lamp` | Desk Lamp
- [ ] `telephone` | Telephone
- [ ] `old_keyboard` | Old Keyboard
- [ ] `medical_poster` | Medical Poster
- [ ] `washing_machine` | Washing Machine
- [ ] `floor_plant` | Floor Plant
- [ ] `gas_stove` | Gas Stove
- [ ] `cast_iron_pan` | Cast Iron Pan
- [ ] `curved_monitor` | Hot Bath
- [ ] `tower_upgrade` | Fresh Towel
- [ ] `copy_machine` | Replay TV
- [ ] `high_roller_pass` | Shower Head
- [ ] `window` | Window
- [ ] `blackout_curtains` | Blackout Curtains
- [ ] `waste_basket` | Kitchen Bin
- [ ] `cleaning_robot` | Cleaning Robot

Placed, but the cell was tuned for the sprite the id used to wear (the
2026-09-07 reskin moved the entry with the sound); each wants a look in
the editor:

- [ ] `nightstand` (now the Chrome Toaster, in the old toaster's cell)
- [ ] `chrome_toaster` (now the Nightstand, in the old nightstand's cell)
- [ ] `whiteboard` (now the Rubber Duck, in the retired duck's cell)
- [ ] `cool_towel` (now the Electric Kettle, in the retired kettle's cell)
- [ ] `glass_partition` (now the Beige Tower, in the old tower's cell)

## Totals

| section | in | stand-in | to find |
|---|---|---|---|
| music | 1 | 0 | 4 (three need wiring) |
| the House | 2 sets (want more variants) | 0 | 3 |
| room count and cut | 2 | 4 | 2 |
| felt | 1 | 7 | 1 |
| grind | 0 | 12 | 13 |
| items | 46 | 0 | 27 |
| paper | 0 | 1 | 10 |
| interface | 2 | 1 | 6 |
| room cells | 46 | 5 to retune | 26 |

**68 sounds to find, 24 stand-ins worth replacing; 39 lines need a hook in the
code before a file does anything (marked wire). 26 room cells to place, 5 to retune.** The wiring is one
`playNamed` per line; ask and I'll add the hooks in a batch so every name
here pairs with a file the moment it lands in `assets/audio/`.
