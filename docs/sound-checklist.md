# Sound checklist

Every sound the current build wants, in one list, so they can be sourced in
one sitting. Companion to `docs/audio-audit.md` (the why in full). Nothing
here is wired yet except the chip/card pack already in `data/sounds.lua`.

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

## 3. The room count and the cut (5 sounds)

- [ ] `room_materialize` | soft swell, 0.6s, like a light warming up | the room comes up from black
- [ ] `room_lock` | a latch or a light switch, clean, one hit | the counter locks on the final number
- [ ] `number_lift` | short whoosh (existing `whoosh.mp3` may do) | ITEMS and BANK lift off
- [ ] `number_land` | already `card_snap`; want a slightly heavier variant | the number lands in its slot
- [ ] `count_tick_fallback` | a neutral wooden tick | any item without its own sound yet

## 4. Per-item foley (52 sounds, one per catalog item)

Played when the item is counted in the room intro, and again in play when the
item fires (F) or only in the count (C) if it is a passive.

| | id | item | sound to find | fires |
|---|---|---|---|---|
| [ ] | wall_hanger | Wall Hanger | a hat dropped on a hook | C |
| [ ] | mirror | Mirror | glass tap | C |
| [ ] | energy_drink | Energy Drink | can crack and fizz | C |
| [ ] | corkboard | Corkboard | a pushpin pressed into cork | C |
| [ ] | stack_of_books | Stack of Books | page flip | F: win tier bumps small to medium |
| [ ] | throw_pillow | Throw Pillow | soft cloth thump | F: loss softened large to medium |
| [ ] | gift_box | Starter Gift Box | box lid lifting, tissue paper | F: run start |
| [ ] | lava_lamp | Lava Lamp | a slow glass blub | F: win tier bumps medium to large |
| [ ] | comfort_bed | Comfort Bed | mattress creak | F: loss softened stack to large |
| [ ] | sticky_notes | Yellow Sticky Note | sticky note peel | C |
| [ ] | rubber_duck | Rubber Duck | squeak | F: first loss voided |
| [ ] | stash_box | Stash Box | small drawer / tin lid | F: run start |
| [ ] | dogs_playing_poker | Dogs Playing Poker | picture frame knocked against a wall | F: first bounty +1 |
| [ ] | calculator | Calculator | one calculator key | C |
| [ ] | ring_binder | Ring Binder | binder rings snapping shut | C |
| [ ] | space_heater | Space Heater | heater click (not the hum) | C (per-hand passive) |
| [ ] | pencil_holder | Pencil Holder | pen click | F: bounty paid |
| [ ] | desk_plant | Desk Plant | leaves brushed | C |
| [ ] | seat_card | Reserved Seat Card | laminated card flicked | F: run start |
| [ ] | rebuy_note | Rebuy Sticky Note | sticky note peel, shorter | F: rebuy |
| [ ] | gaming_chair | Gaming Chair | office chair creak | C |
| [ ] | headset | Headset | headphone crackle / cup placed on head | C |
| [ ] | prize_vase | Prize Vase | ceramic ring | F: tournament cash |
| [ ] | fridge | Compact Fridge | fridge door thunk | F: first stack loss voided |
| [ ] | wall_clock | Wall Clock | one clock tick | F: hand won outright |
| [ ] | vouchers | Rolled Vouchers | paper rip | F: buy-in |
| [ ] | second_monitor | Second Monitor | monitor power blip | C |
| [ ] | laptop | Laptop Terminal | laptop trackpad tap | F: cursor deals |
| [ ] | gaming_keyboard | Gaming Keyboard | mechanical key tap | F: cursor deals (faster) |
| [ ] | box_of_mice | Box of Mice | a burst of mouse clicks | F: cursor deals |
| [ ] | wacom_tablet | Wacom Tablet | stylus tap | F: cursor rebuys |
| [ ] | kettle | Electric Kettle | kettle switch click | F: busted table refund |
| [ ] | toaster | Chrome Toaster | toaster pop | F: pot bumps a tier |
| [ ] | first_aid_kit | First Aid Kit | latch click | F: free rebuy |
| [ ] | nightstand | Nightstand | wooden drawer | C |
| [ ] | receipt_printer | Receipt Printer | receipt printer chatter, short | F: denied chip banks |
| [ ] | microwave | Microwave Oven | microwave ding | F: pot pays double |
| [ ] | diploma | Framed Diploma | glass tap on a frame | F: tournament cash |
| [ ] | blueprint | Laminated Blueprint | laminate sheet flex | C |
| [ ] | console_tv | Console Television | CRT power on click and hum tail | C |
| [ ] | high_roller_pass | High Roller Pass | a card swipe / frame set down | F: buy-in at NL1K+ |
| [ ] | window | Window | window latch / blind cord | C |
| [ ] | bookshelf | Bookshelf | a book slid onto a shelf | C |
| [ ] | cereal_shelf | Cereal Shelf | cereal box shake | F: run start with recycled losses |
| [ ] | fire_extinguisher | Fire Extinguisher | short hiss | F: a loss would have been a stack |
| [ ] | blackout_curtains | Blackout Curtains | curtain slide | F: a win would have been small |
| [ ] | tip_jar | Tip Jar | coins into a glass | F: bounty paid |
| [ ] | pc_tower | Tower Upgrade | PC fan spin-up | C |
| [ ] | curved_monitor | Curved Monitor | monitor blip, lower | C |
| [ ] | desk_speakers | Desk Speakers | one speaker thump | C (and it lifts the music lowpass) |
| [ ] | shredder | Shredder | shredder whir, short | C (per-hand passive) |
| [ ] | unlock_ultra | Ultra Stake | a heavy gate | F: unlock |

Corrupt items reuse the same file through a damage bus (or a pre-rendered
bitcrushed copy); nothing extra to find.

## 5. The felt and the shove (6 sounds)

- [ ] `chip_pour_tick` | already `chip_land_pot`; want it pitchable so the pour rises | each chip lands in the buildup
- [ ] `cheat_card` | a card slapped on felt, dry | cards 6 and 7 land (replaces the chip drop used now)
- [ ] `runout_loss` | one chip sliding off felt | a lost runout (replaces `game_over.mp3`)
- [ ] `runout_win_short` | a short clean fanfare, under 1.5s | a won runout (shorten `victory_fanfare.mp3` or replace)
- [ ] `catalog_thud` | heavy paper thud | the catalog lands on the felt
- [ ] `deck_card_degraded` | the card deal sound, three damaged versions (bitcrushed, lower rate, clicks) | the ending flood, every ~8th card degrades

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
- [ ] `anti_chip_bank` | the chip bank sound with the coin layer reversed (can be built from the pack) | an anti-chip banks

## 8. Act 3 and the break (3 sounds)

- [ ] `underflow_hit` | a deep thud with a violet-flash-sized tail, 1s | the underflow moment
- [ ] `glitch_burst` | a short digital tear, three variants | the broken grind's glyph corruption ticks
- [ ] `music_skip` | a 250ms segment of the room loop cut so it can repeat | the loop skipping after the underflow (can be cut from the loop itself)

## Totals

Music 4, House 3, room/cut 5, items 52, felt 6, catalog 6, grind 5, break 3:
**84 sounds**, of which about 10 can be made from files already in the repo.
