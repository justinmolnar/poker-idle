# Sound checklist

Every sound the build wants, one line per sound HEARD (not per call site),
so they can be sourced in one sitting. Sections 3-6 were merged 2026-09-17
from a per-call-site list; the dropped lines are recorded at the end of
section 6. Cross-referenced 2026-09-04 (items and the room rechecked 2026-09-08, the whole
list 2026-09-17 after the 2026-09-12 id rename) against `data/sounds.lua` (the named
presets), every `playNamed` / timeline beat / `arrival_sound` in the code,
`assets/audio/` on disk, and the catalog's item ids. Companion to
`docs/audio-audit.md` (the why).

Marks: `[x]` a real file is in and wired, or a pack sound accepted as final ·
`[ ]` still to find; where a pack chip, card or legacy MP3 plays meanwhile
the row says so, but a placeholder is not a sound.
`(wire)` = the code has no call for it; a file alone won't play, ask for the
hook. Files drop into `assets/audio/<folder>/<name>.ogg` and pair by name
(`services/SoundLoader`); presets in `data/sounds.lua` win when they exist.
The loader scans EVERY folder under `assets/audio/` except one named `raw`,
so never park a file under a live name: it plays.

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
- [x] title / credits | the title plays the loop through the intercom with the room's treatment (the room in the dark); credits are silent. Decide if that stays | title, credits

## 2. The House

- [x] `radio/open/*` | mic keying on, static burst; ONE file now, want 4–6 so the key-up varies | every speech bubble starts
- [x] `radio/voice/*` | distorted voice bed, ONE file now, want 3–4 different textures | while his text types
- [ ] `house_stinger` (wire) | one low piano note left to ring, 1.5–2s | first cheat card, the Act 2 lede, the underflow, deck_out

## 3. The shove: the room count, the cut, the felt

- [x] `lights_on` / `lights_off` | the switch, with the tube coming on over it for on | the fixture blooms; the fixture dies
- [x] room-count tick | each item plays its own file (section 5), a chip click for the ones without one | each item counted
- [x] number lift | `whoosh.mp3` (`number_lift`), fired as each number leaves the room | ITEMS and BANK lift off the room and land in their slots
- [x] card give | the pack's deal (the first seven gives), the cheat card its heavier take, degraded three ways for the ending flood | every card on the felt
- [x] card flip | the pack's last three gives, pitched down; the deal keeps the first seven (`hole_card_flip` / `card_dealt`) | your cards turn, the dealer's turn, the title's idle turns, the page turn until it has its own
- [x] chip land | the pack's chip, pitched per landing, at three weights | the pour, the take, the pot arriving at you, chips reaching the bankroll
- [x] `shove_initiated` | the pack's riffle | the buildup starts
- [x] win sting | the pack's coins, a 4-chip drop under them for the full clear (`runout_won` / `gauntlet_won` / `tournament_won`); the legacy fanfare is deleted | a won runout, the full clear, TOURNAMENT WON
- [x] loss | one pack chip pitched down, no jingle (`gauntlet_lost` / `table_busted`); the legacy game-over is deleted | a lost runout, a table busting
- [ ] paper lands | a heavy thud for the book, a light slap for the pamphlet; the thud is wired and silent, the slap plays the flip today | the book and the pamphlet land on the felt

## 4. The grind

- [x] pot resolve | the pack's chip stacks by tier, coins layered on a won Stack | a hand resolves, win or loss
- [x] Stack loss | the pack's 4-chip drop with itself pitched down under it (`pot_lost_stack`); the legacy buzz is deleted | a Stack is lost
- [ ] table open / close | a chair pulled up, a chair pushed in; today the open is a pack chip, the close is silent (wire) | a table opens, a table is cashed out
- [x] `seat_ko` | the pack's heaviest drop | a tournament seat busts
- [x] `stake_up_flourish` | pack chips and coins | a new stake opens
- [ ] tilt lands (wire) | glass tipping, or a knock going wrong | a tilt is applied to a table
- [ ] heater lands (wire) | a match strike, short | a heater is applied
- [ ] punch (wire) | fist on a table, the frame the fist lands (data/statuses slam.rise); the shove reuses it quieter | the slam; a table shoving its neighbour
- [ ] `focus_overload` | a short strained tone; wired, plays once per crossing of the cap (drop the file in and it plays) | the board goes over the focus cap
- [ ] deck (wire) | one bright note or a card fan; a new deck and a level-up share it | the deck in play levels; a deck unlocks
- [ ] underflow (wire) | a deep thud with a tail, 1s; afterwards a short digital tear, three variants, for the broken readouts | the Act 3 break; the glyph ticks
- [x] `anti_chip_bank` | the bankroll chip through the damage bus | an anti-chip banks

## 5. Per-item foley

Each item plays the file named after its id (`assets/audio/items/<id>.ogg`):
in the room count, and again when it fires in play. Every item has its OWN
file; nothing shares. 46 of the 73 live items are in (credited in the
folder's MANIFEST). Ids are the display names in snake case since 2026-09-12
(save version 3); the rows below carry the live ids.

- [ ] `fight_night_poster` | Fight Night Poster | a bell, one strike | count only
- [ ] `tally_book` | Tally Book | a pencil scratch, one stroke | count only
- [ ] `bonsai` | Bonsai | leaves brushed, a snip | count only
- [ ] `house_cat` | House Cat | one short meow | 1 in 50 hands won, a random table's next win bumps
- [ ] `candle` | Candle | a match strike, short | a Stack win lights a random table
- [ ] `trophy_shelf` | Trophy Shelf | a small cup set down on wood | a bounty pays double
- [ ] `dusty_console` | Dusty Console | a cartridge blown on, a click | count only
- [ ] `handheld` | Handheld | a handheld's power tone or button click | a Zoom loss deals the next hand
- [ ] `red_rug` | Red Rug | a rug shaken out, one flap | count only
- [ ] `dish_soap` | Dish Soap | a squeeze bottle, short | a tilt slides to the next table
- [ ] `bottle_of_wine` | Bottle of Wine | a cork | the first table at a stake catches a heater
- [ ] `desk_lamp` | Desk Lamp | a lamp switch, click | count only
- [ ] `telephone` | Telephone | a receiver set down | count only
- [ ] `old_keyboard` | Old Keyboard | one stuck key | count only
- [ ] `medical_poster` | Medical Poster | paper pressed flat on a wall | a knockout revives a busted neighbour
- [ ] `hybrid_console` | Hybrid Console | a dock click | count only
- [ ] `washing_machine` | Washing Machine | the spin, short | count only
- [ ] `floor_plant` | Floor Plant | big leaves, brushed | a 6-Max Stack bumps its neighbours
- [ ] `gas_stove` | Gas Stove | an igniter click | count only
- [ ] `cast_iron_pan` | Cast Iron Pan | a pan set on a burner, clang | count only
- [ ] `hot_bath` | Hot Bath | water, a tap run for a second | a knockout's steam heats a neighbour
- [ ] `fresh_towel` | Fresh Towel | a towel snap | a knockout bumps a neighbour's next win
- [ ] `replay_tv` | Replay TV | tape whir, a deck loading | count only
- [ ] `shower_head` | Shower Head | a shower running, short | count only
- [ ] `box_of_tissues` | Box of Tissues | one tissue pulled | a knockout refunds a neighbour's buy-in
- [ ] `kitchen_bin` | Kitchen Bin | a bin lid | a tilt lands in the corner
- [ ] `cleaning_robot` | Cleaning Robot | a small motor whir | count only

The five sounds parked in `items/unassigned/` on 2026-09-07 (a beep, a glass
tap, a paper rip, a shredder, a card draw) were deleted 2026-09-17: the
2026-09-12 rename had given five items those exact names, so they were
playing. Nothing is parked now.

(`tilt` and `snake_case_unique` are a hidden system entry and the authoring
template; `ultra_stake` has its file; no sound for the first two. `stash_box`
and the two `_retired` ids are retired and never counted.)

## 6. Paper and interface

Nothing in the interface makes a sound today except the felt and the
cursors; the click flash is silent. Buttons are buttons: one click, wired
once in the button component, covers every one of them.

- [ ] button click (wire) | one soft click, the same everywhere | any button, tab, key, row, toggle, dropdown item, the close X, table types, REBUY, an upgrade, a catalog tab, a deck tile; the cursor swarm plays it quiet in place of the pack chip
- [ ] modal open / close (wire) | a paper or panel slide in, and out; the book and the pamphlet are the paper take | the catalog, the pamphlet, Settings, the glossary, confirm dialogs
- [ ] page turn | two or three page turns; today the card flip | each leaf, wheel or dog-ear of the book
- [ ] stamp (wire) | one rubber stamp thunk; a corrupt purchase runs it through the damage bus | ORDERED lands on a bought item
- [x] title deal | the pack's card give per letter card, then a chip landing for the apostrophe | the name deals onto the title
- [x] title light switch | `lights_on` | Continue / New Game throw the switch
- [x] title key-up | the radio open, static only, no words | the intercom keys up while the title idles
- [x] credits | silence | the credits

Dropped 2026-09-17, on purpose, so nobody re-adds them: the border pulse
(remove the two calls; the pot resolve carries it), the deal press, fold
and muck, the cursor bump, a separate shove punch, sticker peel, receipt
feed, the corrupt-offer whine, slider ticks, the pen scratch, a reversed
stamp, the demo end card, a hint-bubble sound, the House's per-line tick,
a click at the room-count lock (the light switch covers it), and every
per-button sound (rebuy, upgrade, open table, close table, cursor tap) in
favour of the one click above.

## 7. The room: items with no cell

Every item is placed once, in the room editor, into `data/room_layout.lua`
(`gx, gy` on the 5x5 grid, `align` for a wall). 26 of the 73 live items have
no entry, so they do not appear in the room when owned and the shove's count
skips past them. Rechecked 2026-09-17, live ids.

- [ ] `fight_night_poster` | Fight Night Poster
- [ ] `tally_book` | Tally Book
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
- [ ] `hot_bath` | Hot Bath
- [ ] `fresh_towel` | Fresh Towel
- [ ] `replay_tv` | Replay TV
- [ ] `shower_head` | Shower Head
- [ ] `window` | Window
- [ ] `blackout_curtains` | Blackout Curtains
- [ ] `kitchen_bin` | Kitchen Bin
- [ ] `cleaning_robot` | Cleaning Robot

Placed, but the cell was tuned for the sprite the id used to wear (the
2026-09-07 reskin moved the entry with the sound; the 2026-09-12 rename
carried each cell to its new id, coordinates untouched); each wants a look
in the editor:

- [ ] `chrome_toaster` (the Chrome Toaster, in the old nightstand's cell: it still carries the microwave and box-of-mice homes)
- [ ] `nightstand` (the Nightstand, in the old toaster's cell)
- [ ] `rubber_duck` (in the retired duck's cell)
- [ ] `electric_kettle` (in the retired kettle's cell)
- [ ] `beige_tower` (in the old tower's cell)

## Totals

| section | in | to find |
|---|---|---|
| music | 2 | 3 (all need wiring) |
| the House | 2 sets (want more variants) | 1 (needs wiring) |
| the shove | 9 | 1 |
| the grind | 5 | 7 |
| items | 46 | 27 |
| paper and interface | 4 | 4 |
| room cells | 46 | 26 to place, 5 to retune |

**43 sounds to find: 27 item files and 16 for everything else, 14 of those
needing a hook in the code first (marked wire). 26 room cells to place, 5
to retune.** The wiring is one `playNamed` per line; ask and I'll add the
hooks in a batch so every name here pairs with a file the moment it lands
in `assets/audio/`.
