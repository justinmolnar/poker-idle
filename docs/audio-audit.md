# Audio audit and sound design brainstorm

August 2026. Assessment of what the game sounds like today and a plan for
what it should sound like. Nothing here is built unless a section says so.

## What is there today

- One palette. 62 files, almost all the uVegas chip and card pack, plus five
  legacy MP3s (fanfare, game over, buzz, whoosh, ding). Every entry in
  `data/sounds.lua` is a chip or a card: the catalog purchase is a chip drop,
  the cursor tap is a chip, counting your room is a chip. The whole game
  sounds like one felt table, even in a bedroom or a paper catalog.
- No music, no ambience, no loop of any kind. `services/SoundService` is
  one-shot only.
- The House has no sound. Twelve story beats and about twenty shove lines
  appear as silent text.
- Volume is authored per entry, with `layer` for a second sample under the
  first. `Timeline:skip` suppresses sounds. Both are good foundations.
- About a dozen call sites fire sound. The room intro (the newest) uses the
  lightest chip click for every item.

## Identity

Four spaces, four sound worlds:

1. The room and the grind: domestic, close, small. Hum, tick, mouse click,
   chair creak. Warm.
2. The catalog: paper. Page turn, stamp thunk, pen scratch, the price ring
   being drawn.
3. The felt: the chip pack, and only there. Dry, no reverb.
4. The break (Act 3, underflow, corruption): the same sounds, damaged.
   Bitcrush, pitch wobble, dropouts.

Keep the chip pack for the felt. Once the room stops sounding like a casino,
walking to the felt sounds like going somewhere.

## Music

- Style: lo-fi, close, slightly detuned. One electric piano or Rhodes, soft
  tape hiss, a brushed kick. A radio left on in the next room. Cheap and cosy,
  because the House is cheap and cosy. Not casino jazz; that is the felt's
  world and it would flatten the contrast.
- Where: the grind and the room only. Same track, different filter: clear in
  the room (you are near the radio), lowpassed on the grind (the radio is
  behind you).
- Cuts at SHOVE: the click hard-stops the music with the chip riffle. Silence
  through the room count, the cut, the buildup. The silence is the fanfare.
  The gauntlet gets diegetic sound only, plus one sustained low tone that
  rises with each runout. Music returns on the grind from the top of the loop,
  as if it was never off.
- Desk Speakers = the music gets clearer. Owning it lifts the lowpass cutoff on
  the grind track. Keep this as the one audio upgrade so it is noticed.
  Corrupt speakers: louder and wrong (pitch drifts, one channel drops).
- Acts: Act 2 adds a bass layer under the same loop. Act 3 strips it to piano
  and hiss. Underflow: the loop skips (a 250ms segment repeats) and bends
  down 20 cents per shove. Credits: the loop plays clean for the first time.
- Build: one music service (loop, crossfade, a lowpass parameter), OGG
  streams, states set a scene and the service resolves it from `data/music.lua`
  (scene -> track, layers, cutoff, gain). Same DI and data pattern as the rest.

## The room count: one sound per item

Each catalog item carries `sound = "<name>"` in `data/catalog.lua`, resolving
in `data/sounds.lua`. The count plays it per tick, pitch drifting up with the
index so the accelerating cadence turns from foley into a rhythm, a drum fill
built out of your possessions. The lock is one clean sound (a latch or a light
switch), not a chip.

The same sound is the item's signature in play: when an item fires, its sound
plays. The rolls live in `GrindController` and `models/poker_effects` (no
`love.*`), so they emit one event, `item_fired(item_id, kind)`, through the
dispatcher and the view layer plays `item.sound`. No sound code in models.

Which items fire in play (the rest are passive and sound only in the count):

| item | fires when | sound |
|---|---|---|
| Rubber Duck | first loss voided | squeak |
| Compact Fridge | first stack loss voided | fridge door thunk |
| Chrome Toaster | pot bumps a tier | toaster pop |
| Microwave Oven | pot pays double | ding |
| Wall Clock | hand wins outright | single tick |
| First Aid Kit | free rebuy | latch click |
| Receipt Printer | denied chip banks anyway | printer chatter |
| Fire Extinguisher | a loss would have been a stack | short hiss |
| Blackout Curtains | a win would have been small | curtain slide |
| Electric Kettle | busted table refunds | kettle click |
| Cereal Shelf | run starts with recycled losses | box shake |
| Lava Lamp / Stack of Books | win tier bumps up | glass blub / page flip |
| Throw Pillow / Comfort Bed | loss tier softened | soft thump / mattress creak |
| Dogs Playing Poker / Pencil Holder / Tip Jar | bounty paid | frame knock / pen click / coins in glass |
| Prize Vase / Framed Diploma | tournament cash | ceramic ring / glass tap |
| Reserved Seat Card / Rolled Vouchers / Rebuy Note | run start, buy-in, rebuy | card flick / paper rip / sticky peel |
| Box of Mice, Laptop, Keyboard, Tablet | cursor deals, rebuys, sync | mouse click, key tap, touchpad tap, pen tap |
| Starter Gift Box / Stash Box | run start | box lid / drawer |
| Ultra Stake | unlock | gate |

Count-only (per-hand passives would spam): Space Heater, Shredder, Gaming
Chair, the monitors, Headset, Speakers, TV, and every win-chance item.

Rules: anything that fires more than about once a minute (cursor clicks,
clock ticks) sits 12dB under the rest and skips a play if the same sound went
off in the last 200ms. Corrupt items keep the same sound, damaged
(bitcrushed, or reversed for stamp-style ones), so a corrupted duck still
squeaks and you can hear that it is wrong.

Sourcing: about 52 short foley one-shots; the chip pack covers none of them.
Wire the names first with the built-in `kind = "beep"` synth as placeholder
so the pipeline works before the files exist.

## The House

A voice without a voice, cheapest first:

- A text tick per block: a soft typewriter or one Rhodes note, the same note
  every time so it becomes his sound. A lower note for the panic lines.
- The music ducks 6dB while his box is open. It makes the box feel like he
  stepped in.
- One stinger for the reveal beats only (first cheat card, act2 lede,
  underflow, deck_out): a single low piano note left to ring.

## The felt and the shove

- The chip pour's landings climb in pitch with `arrival_frac` so the pour
  resolves upward into the lock flash.
- The number flights: a whoosh on lift (`whoosh.mp3` exists), the snap on land
  (built). ITEMS could carry the last item's foley with it, pitched up, so it
  is audibly from the room.
- Cheat card: paper on felt, the one card sound in the pack with a slap, then
  half a second of silence. The silence is the House not speaking.
- Loss: no game-over MP3. One chip sliding away, and the music stays off until
  the catalog closes.
- Clear: shorten the fanfare; the catalog landing on the felt is the real
  payoff and wants a heavy paper thud.
- The ending: card deals that degrade every ~8th card (bitcrushed copy, then
  lower sample rate, then clicks). By the flood it is a Geiger counter. The
  last card is silent. Credits fade in with the clean loop.

## The catalog

- Open: paper unfold. Page turn per leaf. Stamp: a rubber stamp thunk with a
  tiny delay. Buying: pen scratch, then the stamp, and a short scribble for
  the price ring.
- Corrupt purchase: the stamp reversed, and the glyph morph gets a faint high
  whine that stops when you look away.

## Act 3 and the break

- A damage bus: when underflowed, samples play through a bitcrusher with a
  random 5% dropout. LOVE has `love.audio.setEffect` (reverb, distortion,
  ringmod) where EFX is supported; otherwise pre-render damaged copies of the
  ten most common samples and switch the registry to them. The sample-set
  picker already supports variant sets.
- Anti-chip bank: the chip sound with the coin layer reversed.

## Mixing rules

- Three buses: music, foley/UI, felt. The felt ducks music to zero; the House
  ducks music 6dB.
- Nothing repeats identically twice in a row: the sample-set picker plus a
  plus or minus 3% pitch jitter in `SoundService`.
- Cursor swarm and border pulses are the noisiest grind events by count; they
  sit 12dB under everything else or they mask the music.
- Every accelerating sequence (chip pour, room count, deck flood) gets a pitch
  ramp, not a volume ramp.

## Where to start

Cheapest, biggest change: per-item room-count foley plus the music cut at
SHOVE. Both are data plus one service, and both make the room feel like a
place. The speakers-clarify-the-music trick is one lowpass parameter on top.

## Related, built

- Corrupted items wear `shaders/corrupted.frag` in the room and the shove
  intro (tearing bands with per-band colour damage, a violet stain,
  dropouts). The audio equivalent is the damage bus above.
