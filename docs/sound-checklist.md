# Sound checklist

Every sound the current build wants, in one list, so they can be sourced in
one sitting. Companion to `docs/audio-audit.md` (the why in full).

**Status (2026-08-25):** `[x]` = in the game. All 52 item sounds are in
(`assets/audio/items`, played in the room count and when the item fires).
From the felt section only the cheat card (the pack's deal) and the
degraded deals for the flood (rendered from it) are in. **Still to find: music (4),
the House (3), room materialize + lift whoosh (2), the win fanfare, the
catalog set (6), the grind/UI set (4), the break set (2).**

Format per line: `[ ] name` | what it is | where it plays.
Length guide: item foley 0.1-0.5s; UI 0.1-0.3s; stingers under 2s; music loops
60-120s. Mono is fine for everything but music. OGG.

## 1. Music (3 files, one loop plus two layers)

- [ ] `music_room_loop` | lo-fi electric piano, tape hiss, brushed kick, slightly detuned; "a radio in the next room" | the room and the grind (grind gets a lowpass; Desk Speakers lifts it)
- [ ] `music_layer_bass` | a bass line that sits under the same loop, same tempo/key | Act 2 on the grind
- [ ] `music_layer_hiss` | tape hiss / vinyl crackle bed, loopable | Act 3 (piano + hiss only); louder after the underflow
- [ ] `music_gauntlet_drone` | one sustained low tone, loopable, that can be pitched up per runout | the gauntlet (no music there, only this)

## 2. The House (3 sounds)

- [ ] `house_tick` | one soft note (Rhodes) or a single typewriter key; the same every time | each block of his text appears
- [ ] `house_tick_low` | the same, lower | the panic lines ("No." "Again.")
- [ ] `house_stinger` | one low piano note left to ring, 1.5-2s | reveal beats only: first cheat card, act 2 lede, underflow, deck_out

## 3. The room count and the cut (4 sounds)

- [x] `lights_on` | the switch with the fluorescent tube layered over it | the fixture blooms on at the start of the shove
- [x] `lights_off` | the switch alone | the fixture dies after the count
- [ ] `number_lift` | short whoosh (existing `whoosh.mp3` may do) | ITEMS and BANK lift off
- [x] `number_land` | the card snap | the number lands in its slot

## 4. Per-item foley (52 sounds, one per catalog item)

Played when the item is counted in the room intro, and again in play when the
item fires (F) or only in the count (C) if it is a passive.

| | id | item | sound to find | fires |
|---|---|---|---|---|
| [x] | wall_hanger | Wall Hanger | a hat dropped on a hook | C |
| [x] | mirror | Mirror | glass tap | C |
| [x] | energy_drink | Energy Drink | can crack and fizz | C |
| [x] | corkboard | Corkboard | a pushpin pressed into cork | C |
| [x] | stack_of_books | Stack of Books | page flip | F: win tier bumps small to medium |
| [x] | throw_pillow | Throw Pillow | soft cloth thump | F: loss softened large to medium |
| [x] | gift_box | Starter Gift Box | box lid lifting, tissue paper | C (run start is between screens: silent) |
| [x] | lava_lamp | Lava Lamp | a slow glass blub | F: win tier bumps medium to large |
| [x] | comfort_bed | Comfort Bed | mattress creak | F: loss softened stack to large |
| [x] | sticky_notes | Yellow Sticky Note | sticky note peel | C |
| [x] | rubber_duck | Rubber Duck | squeak | F: first loss voided |
| [x] | stash_box | Stash Box | small drawer / tin lid | C (run start is silent) |
| [x] | dogs_playing_poker | Dogs Playing Poker | picture frame knocked against a wall | F: first bounty +1 |
| [x] | calculator | Calculator | one calculator key | C |
| [x] | ring_binder | Ring Binder | binder rings snapping shut | C |
| [x] | space_heater | Space Heater | heater click (not the hum) | C (per-hand passive) |
| [x] | pencil_holder | Pencil Holder | pen click | F: bounty paid |
| [x] | desk_plant | Desk Plant | leaves brushed | C |
| [ ] | desk | Desk (was Reserved Seat Card; its card-flick sound was deleted 2026-08-25) | a hand set down on wood | C (run start is silent) |
| [x] | rebuy_note | Rebuy Sticky Note | sticky note peel, shorter | F: rebuy |
| [x] | gaming_chair | Gaming Chair | office chair creak | C |
| [x] | headset | Headset | headphone crackle / cup placed on head | C |
| [x] | prize_vase | Prize Vase | ceramic ring | F: tournament cash |
| [x] | fridge | Compact Fridge | fridge door thunk | F: first stack loss voided |
| [x] | wall_clock | Wall Clock | one clock tick | F: hand won outright |
| [x] | vouchers | Rolled Vouchers | paper rip | F: buy-in |
| [x] | second_monitor | Second Monitor | monitor power blip | C |
| [x] | laptop | Laptop Terminal | laptop trackpad tap | F: cursor deals |
| [x] | gaming_keyboard | Gaming Keyboard | mechanical key tap | F: cursor deals (faster) |
| [x] | box_of_mice | Box of Mice | a burst of mouse clicks | F: cursor deals |
| [x] | wacom_tablet | Wacom Tablet | stylus tap | F: cursor rebuys |
| [x] | kettle | Electric Kettle | kettle switch click | F: busted table refund |
| [x] | toaster | Chrome Toaster | toaster pop | F: pot bumps a tier |
| [x] | first_aid_kit | First Aid Kit | latch click | F: free rebuy |
| [x] | nightstand | Nightstand | wooden drawer | C |
| [x] | receipt_printer | Receipt Printer | receipt printer chatter, short | F: denied chip banks |
| [x] | microwave | Microwave Oven | microwave ding | F: pot pays double |
| [x] | diploma | Framed Diploma | glass tap on a frame | F: tournament cash |
| [x] | blueprint | Laminated Blueprint | laminate sheet flex | C |
| [x] | console_tv | Console Television | CRT power on click and hum tail | C |
| [x] | high_roller_pass | High Roller Pass | a card swipe / frame set down | F: buy-in at NL1K+ |
| [x] | window | Window | window latch / blind cord | C |
| [x] | bookshelf | Bookshelf | a book slid onto a shelf | C |
| [x] | cereal_shelf | Cereal Shelf | cereal box shake | C (run start is silent) |
| [x] | fire_extinguisher | Fire Extinguisher | short hiss | F: a loss would have been a stack |
| [x] | blackout_curtains | Blackout Curtains | curtain slide | F: a win would have been small |
| [x] | tip_jar | Tip Jar | coins into a glass | F: bounty paid |
| [x] | pc_tower | Tower Upgrade | PC fan spin-up | C |
| [x] | curved_monitor | Curved Monitor | monitor blip, lower | C |
| [x] | desk_speakers | Desk Speakers | one speaker thump | C (and it lifts the music lowpass) |
| [x] | shredder | Shredder | shredder whir, short | C (per-hand passive) |
| [x] | unlock_ultra | Ultra Stake | a heavy gate | F: unlock |

Corrupt items reuse the same file through the damage bus (built); nothing extra to find.

## 5. The felt and the shove (6 sounds)

- [x] `chip_pour_tick` | already `chip_land_pot`; want it pitchable so the pour rises | each chip lands in the buildup
- [x] `cheat_card` | the pack's card deal, heavy | cards 6 and 7 land (was a chip drop)
- [ ] `runout_loss` | one chip sliding off felt | a lost runout (replaces `game_over.mp3`; preset `gauntlet_lost`)
- [ ] `runout_win_short` | a short clean fanfare, under 1.5s | a won runout (shorten `victory_fanfare.mp3` or replace)
- [ ] `catalog_thud` | heavy paper thud | the catalog lands on the felt (name wired on the timeline)
- [x] `deck_card_degraded` | rendered: bitcrushed, 8kHz, clicks | the ending flood, one step every 12 cards

## 6. The catalog (6 sounds)

- [ ] `catalog_open` | paper unfold | the catalog opens
- [ ] `page_turn` | one page turn, two or three variants | each leaf
- [ ] `stamp` | rubber stamp thunk | an item is bought
- [ ] `pen_scratch` | short pen scratch | the price ring is drawn
- [ ] `stamp_reverse` | the stamp reversed | a corrupt purchase
- [ ] `glyph_whine` | faint high whine, loopable, quiet | while looking at a corrupt offer

## 7. Grind and UI (5 sounds, mostly replacing chip sounds)

- [ ] `upgrade_buy` | a soft mechanical click (not a chip) | run upgrade bought
- [ ] `table_open` | chair pulled up | a table is opened
- [ ] `table_close` | chair pushed in | a table is closed / cashed out
- [ ] `focus_over` | a short strained tone | focus overloaded
- [x] `anti_chip_bank` | the bank chip sound through the damage bus | an anti-chip banks

## 8. Act 3 and the break (3 sounds)

- [ ] `underflow_hit` | a deep thud with a violet-flash-sized tail, 1s | the underflow moment
- [ ] `glitch_burst` | a short digital tear, three variants | the broken grind's glyph corruption ticks
- [ ] `music_skip` | a 250ms segment of the room loop cut so it can repeat | the loop skipping after the underflow (can be cut from the loop itself)

## Totals

Music 4, House 3, room/cut 5, items 52, felt 6, catalog 6, grind 5, break 3:
**84 sounds**, of which about 10 can be made from files already in the repo.
