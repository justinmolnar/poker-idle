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
- [x] `music_layer_hiss` | `layers/hiss.ogg`, played by services/MusicLayers on the grind and in the room once Act 3 opens, louder after the underflow; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | Act 3, louder after the underflow
- [x] `music_gauntlet_drone` | `layers/gauntlet_drone.ogg` (crossfaded into a loop), services/MusicLayers, a step up per runout result shown; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the gauntlet felt
- [x] title / credits | the title plays the loop through the intercom with the room's treatment (the room in the dark); credits are silent. Decide if that stays | title, credits

## 2. The House

- [x] `radio/open/*` | mic keying on, static burst; ONE file now, want 4–6 so the key-up varies | every speech bubble starts
- [x] `radio/voice/*` | distorted voice bed, ONE file now, want 3–4 different textures | while his text types
- [x] `house_stinger` | `felt/house_stinger.ogg`, one low piano note left to ring (the shove timeline at the first cheat card and the deck running out, the `act2` beat's `sound`, the underflow crossing); Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | first cheat card, the Act 2 lede, the underflow, deck_out

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
- [x] paper lands | `felt/catalog_thud.ogg` for the book, `felt/flyer_slap.ogg` for the pamphlet; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the book and the pamphlet land on the felt

## 4. The grind

- [x] pot resolve | the pack's chip stacks by tier, coins layered on a won Stack | a hand resolves, win or loss
- [x] Stack loss | the pack's 4-chip drop with itself pitched down under it (`pot_lost_stack`); the legacy buzz is deleted | a Stack is lost
- [x] table open / close | `ui/table_open.ogg`, `ui/table_close.ogg`, a UI pair by one author (not a chair, per the user); Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | a table opens, a table is cashed out
- [x] `seat_ko` | the pack's heaviest drop | a tournament seat busts
- [x] `stake_up_flourish` | pack chips and coins | a new stake opens
- [x] tilt lands | `felt/tilt_lands.ogg`, a negative UI sound, played when the tilt appears (with the fist when a punch carried it); Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | a tilt is applied to a table
- [x] heater lands | `felt/heater_lands.ogg`, played when the heater appears (with the fist when a punch carried it); Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | a heater is applied
- [x] punch | `felt/punch.ogg` at contact; a shove plays it at half; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the slam; a table shoving its neighbour
- [x] `focus_overload` | `felt/focus_overload.ogg`, pitched down per step over the cap; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the board goes over the focus cap
- [x] deck | `felt/deck_up.ogg` (a card fan), from the deck cell's announcement; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the deck in play levels; a deck unlocks
- [x] underflow | `felt/underflow.ogg`, once at the crossing; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). The broken readouts' digital tear is `felt/glyph_tear_1..3.ogg`, one of them now and then (0.7–2.2 s apart) while the readouts are broken (GrindView). | the Act 3 break; the glyph ticks
- [x] `anti_chip_bank` | the bankroll chip through the damage bus | an anti-chip banks

## 5. Per-item foley

Each item plays the file named after its id (`assets/audio/items/<id>.ogg`):
in the room count, and again when it fires in play. Every item has its OWN
file; nothing shares. 73 of the 73 live items are in (credited in the
folder's MANIFEST). Ids are the display names in snake case since 2026-09-12
(save version 3); the rows below carry the live ids.

- [x] `gaming_poster` | Gaming Poster | a bell, one strike | count only (Freesound CC0, items/MANIFEST)
- [x] `tally_book` | Tally Book | a pencil scratch, one stroke | count only (Freesound CC0, items/MANIFEST)
- [x] `bonsai` | Bonsai | leaves brushed, a snip | count only (Freesound CC0, items/MANIFEST)
- [x] `house_cat` | House Cat | one short meow | 1 in 50 hands won, a random table's next win bumps (Freesound CC0, items/MANIFEST)
- [x] `candle` | Candle | a match strike, short | a Stack win lights a random table (Freesound CC0, items/MANIFEST)
- [x] `trophy_shelf` | Trophy Shelf | a small cup set down on wood | a bounty pays double (Freesound CC0, items/MANIFEST)
- [x] `dusty_console` | Dusty Console | a cartridge blown on, a click | count only (Freesound CC0, items/MANIFEST)
- [x] `handheld` | Handheld | a handheld's power tone or button click | a Zoom loss deals the next hand (Freesound CC0, items/MANIFEST)
- [x] `red_rug` | Red Rug | a rug shaken out, one flap | count only (Freesound CC0, items/MANIFEST)
- [x] `dish_soap` | Dish Soap | a squeeze bottle, short | a tilt slides to the next table (Freesound CC0, items/MANIFEST)
- [x] `bottle_of_wine` | Bottle of Wine | a cork | the first table at a stake catches a heater (Freesound CC0, items/MANIFEST)
- [x] `desk_lamp` | Desk Lamp | a lamp switch, click | count only (Freesound CC0, items/MANIFEST)
- [x] `telephone` | Telephone | a receiver set down | count only (Freesound CC0, items/MANIFEST)
- [x] `old_keyboard` | Old Keyboard | one stuck key | count only (Freesound CC0, items/MANIFEST)
- [x] `medical_poster` | Medical Poster | paper pressed flat on a wall | a knockout revives a busted neighbour (Freesound CC0, items/MANIFEST)
- [x] `hybrid_console` | Hybrid Console | a dock click | count only (Freesound CC0, items/MANIFEST)
- [x] `washing_machine` | Washing Machine | the spin, short | count only (Freesound CC0, items/MANIFEST)
- [x] `floor_plant` | Floor Plant | big leaves, brushed | a 6-Max Stack bumps its neighbours (Freesound CC0, items/MANIFEST)
- [x] `gas_stove` | Gas Stove | an igniter click | count only (Freesound CC0, items/MANIFEST)
- [x] `cast_iron_pan` | Cast Iron Pan | a pan set on a burner, clang | count only (Freesound CC0, items/MANIFEST)
- [x] `hot_bath` | Hot Bath | water, a tap run for a second | a knockout's steam heats a neighbour (Freesound CC0, items/MANIFEST)
- [x] `fresh_towel` | Fresh Towel | a towel snap | a knockout bumps a neighbour's next win (Freesound CC0, items/MANIFEST)
- [x] `replay_tv` | Replay TV | tape whir, a deck loading | count only (Freesound CC0, items/MANIFEST)
- [x] `shower_head` | Shower Head | a shower running, short | count only (Freesound CC0, items/MANIFEST)
- [x] `box_of_tissues` | Box of Tissues | one tissue pulled | a knockout refunds a neighbour's buy-in (Freesound CC0, items/MANIFEST)
- [x] `kitchen_bin` | Kitchen Bin | a bin lid | a tilt lands in the corner (Freesound CC0, items/MANIFEST)
- [x] `cleaning_robot` | Cleaning Robot | a small motor whir | count only (Freesound CC0, items/MANIFEST)

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

- [x] button click | `ui/button_click.ogg` through ClickFlash.press / .click; the cursors play it quiet as `cursor_tap`; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | any button, tab, key, row, toggle, dropdown item, the close X, table types, REBUY, an upgrade, a catalog tab, a deck tile; the cursor swarm plays it quiet in place of the pack chip
- [x] modal open / close | `ui/modal_open.ogg`, `ui/modal_close.ogg`, in the screens' open/close functions, the confirm and action dialogs, and the felt book and pamphlet; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | the catalog, the pamphlet, Settings, the glossary, confirm dialogs
- [x] page turn | `ui/page_turn.ogg`, lower for a jump of several spreads; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | each leaf, wheel or dog-ear of the book
- [x] stamp | `ui/stamp.ogg` on a purchase; a corrupt one plays damaged; Freesound CC0, credited in the folder's MANIFEST (2026-10-03). | ORDERED lands on a bought item
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

- [ ] `gaming_poster` | Gaming Poster
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

## 8. Clicks

Built 2026-10-03 (services/ClickFX, ClickSurfaces, Sparks, Poke; numbers in data/clicks.lua; sim/smoke_clicks.lua). Every click answers where it lands, like Hearthstone's board: a surface sound and
a spark at the cursor on every click, result or not. A click that does something layers the button click (section 6)
over it with a gold burst; a button that can't act plays the denied thunk and shakes; rapid clicks climb in pitch and
spark size, capped, settling when you pause; the cursors click too, pitched up, quieter, fewer specks. A dead click is
told from a live one in `main.lua` (no `ClickFlash.press`/`.click` fired during the press), and surfaces come from a
registry of tagged rects beside the anchors. Candidates for every row are in the audition (`tools/audition_sounds.py`,
"Clicks (new)").

- [x] `click_felt` | a soft cloth tap | a table's playing area, the shove felt; dust in the stake's felt colour, a faint ring (`ui/click_felt.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_chrome` | a hard tick | Settings and the other mechanical modals, sidebars, panel headers and frames; 2–3 glints (`ui/click_chrome.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_rail` | a deeper knock, a desk edge | the bottom bar; specks off its top edge, readouts react (digits jostle, numbers bump, chip icons spin) (`ui/click_rail.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_empty` | a hollow knock | an empty slot; grey dust (`ui/click_empty.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_wall` | a muffled thump | the background, the room's floor and walls; dim specks (`ui/click_wall.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_paper` | a paper tap | the catalog's pages and cards, the pamphlet, the House poster (it swings on its pin), the story band; paper flecks (`ui/click_paper.ogg`, Freesound CC0, ui/MANIFEST)
- [x] `click_denied` | a dull thunk | a button that can't act (an upgrade you can't afford); dark specks, the button shakes (`ui/click_denied.ogg`, Freesound CC0, ui/MANIFEST)

Already in hand, no file to find: cards (the pack's give, pitched up; the card jumps), table chips and the bankroll
pile (the pack's chip clack; the top chip hops, the column wobbles), room items (their own foley; the item bobs), the
book and pamphlet closed on the felt (their landing sounds, quieter; they scoot), the speaker (`radio/open` static,
the grille rattles; a plain speaker thump once you own the Desk Speakers), and the House poster's rare static tick
from the speaker.

## Totals

| section | in | to find |
|---|---|---|
| music | 4 | 1 (needs wiring) |
| the House | 2 sets (want more variants) + the stinger | 0 |
| the shove | 10 | 0 |
| the grind | 13 | 0 |
| items | 73 | 0 |
| paper and interface | 8 | 0 |
| clicks | 7 (placed; played by name from `data/clicks.lua`) | 0 |
| room cells | 46 | 26 to place, 5 to retune |

**1 sound to find: the bass layer under the music (same key and tempo as the loop, so not something found off the shelf). Everything else is in, credited and wired (`tools/audition_sounds.py`, `tools/place_sounds.py`). 26 room cells to place, 5 to retune.**
