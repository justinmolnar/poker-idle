# The shove, as a sequence

Status: **built, 2026-08-24**, across seven commits on `chip-visuals`. Verified
headlessly (beat replay, catalog slide, no-spoilers, golden op trace, layout);
nothing has been seen rendered. The panic timings are data in
`views/ShoveView.lua`'s timeline and `data/shove_style.lua`, and are first guesses.

This collects every point raised about the gauntlet in the 2026-08-24 session, in
one place, so that none of them falls out again.

## Why this exists

The visual pass gave the gauntlet a table. The teaching pass gave it copy. Neither
made a first shove *legible*, because the shove has no beats. Traced on the clock,
a first shove is:

```
 0.0s  chips fly in, ALL IN pops                (the only drama in the sequence)
 ~5.0  hole cards deal, flip; flop, turn, river   (each a 0.25s fade)
       on ONE frame: best-5 strokes appear, two label pills appear,
       a LOSS chip appears, game_over.mp3 plays
 +2.0  a modal slams over all of it: BUSTED, +N {chip}, Continue
       catalog
       deck select (Act 2+)
       grind, everything reset
```

The player's own summary of that: *chips go in, I lose, a modal says I lose, a
catalog opens, the game resets.* Why did I lose? What cards won? What is this
catalog? How do I win? What is a good percent?

And the two things the sequence is actually *about* are both invisible:

- **The cheat.** After an R1 win there are 3.0 seconds of nothing
  (`RUNOUT_PAUSE + CHEAT_REVEAL_PAUSE`), then a card, then LOSS. The player read
  that as the game hanging. It is supposed to be the house getting caught.
- **The win.** `victory_fanfare.mp3` plays. That is the entire fanfare. Confetti
  exists in the repo and nothing calls it.

**Half of tutorialising is making the thing read.** Copy on a modal that covers the
answer two seconds after it lands is not teaching.

---

## Principles

1. **The result stays on the felt.** No modal covers the cards. Whatever the
   player needs to understand a loss (which hand beat which, what was taken) is
   drawn on the table, next to the cards, and stays there until they leave.
2. **The house is a character, and this is its room.** The dealer is the House.
   It has a poster on this screen, with an opening under it the cards come
   through, like the plastic divider at a DMV counter. It speaks. Every beat that
   is currently silent is the House saying something or doing something.
3. **A rule change is performed, not applied.** When the House cheats, the player
   watches it panic and cheat *because it was losing*. Card 6 is not a card. It
   is the House going "wait. you won? ...no. New card."
4. **Winning is a real win before it is taken away.** The reversal has nothing to
   reverse if the win never landed.
5. **The next screen is a consequence, not a transition.** The catalog arrives
   because you have {chip} to spend, and it arrives as a thing you open, not a
   thing that opens on you.
6. **Progress has a visible axis.** "How do I get more %" and "what is a good
   percent" are answered by a meter that fills toward 100 and visibly drops when
   the number does, on the grind, all the time.

---

## The House on this screen

**Deferred.** The poster is built and off (`shove_style.house.enabled = false`).
A primitive-shape house earned nothing on screen; it gets real art in a later
pass. Until then the House's bubble floats beside its mark.

The design, for when it has art: a poster, same glyph as the grind's
(`GrindView:_drawHouse`), placed **above the dealer's hole cards**. Below it, a slot, the width of the card row, drawn as a
gap in a counter: the dealer's hole cards and every board card are dealt *out of
this slot*, downward onto the felt. Cards 6 and 7 come from the same place.

The House speaks from the poster in the same bubble the grind uses (`HintView`'s
bubble, tail to the roof). It is the same voice as the hints because it is the
same captor. Panic can be text, staging, or both; the distinction is not
important yet. Both are currently missing and what is there reads as nothing.

The House is faceless and always wins, until the player breaks the count.

---

## The sequence

Timings are proposals against the existing constants
(`CARD_DEAL_INTERVAL 0.35`, `RUNOUT_PAUSE 1.2`, `CHEAT_REVEAL_PAUSE 1.8`). Every
"hold" is a click-through, not a timer: the screen waits for the player.

### 0. Buildup — mostly right already

Chips fly from YOUR STACK into the pot, the readout ticks up, ALL IN pops. Keep.
One change: the House says something as the stack arrives. *"All of it? Good."*

### 1. The deal, in real showdown order

The player's two cards flip on the deal: you know your own hand. **The dealer's
stay face-down through the whole board.** Flop, turn, river deal against a hidden
hand. Then the dealer turns over, and that flip *is* the showdown.

Both hands used to flip together at 0.65s, before the flop. The hand was decided
before a single board card came out, so nothing after it could carry tension, and
no amount of lighting or motion at the end could produce any. This was the actual
defect; everything else was choreography on top of it.

### 1b. One thing at a time

At the result, five things used to arrive at once: two label pills, a LOSS chip,
a House bubble, and a catalog sliding in. Nobody could tell where to look. Now:

```
dealer flips          the reveal
  +0.0  winner lights, loser dims
  +0.6  WIN / LOSS chip
  +1.0  the pot leaves toward the winner
  +1.9  the House, one line
  +2.6  BANKED THIS RUN
  +3.0  hold
click                 the catalog rises
```

Nothing lands at the same instant as anything else. One hand label, for the
winner only, beside the winning hand. The [i] hint queue is off on this screen.

### 2. Runout 1 resolves

**If lost** (the common first shove):

- The dealer's best five stay lit; the player's cards dim. Not a stroke on both
  sides at equal weight, which is what happens now. The winner is bright and the
  loser is grey.
- The pot pile **leaves**: chip-flight from the pot to the slot under the poster.
  The felt already has this physics (`ChipFlight`). The money is seen going.
- The readout's `= 100%` rolls to `= 0%`.
- A "why" line under the label pills, plain: *"Two pair beats a pair."*
- The House: *"That is how it goes."*
- **Hold.** The result stays. Click to continue.

**If won:**

- The player's best five lit, the dealer's grey. WIN chip. Coins.
- The pot pile jumps **toward the player**. Confetti (`services/Confetti`, unused
  today). This must feel like a win, for a full beat, or step 3 does not work.
- The House says nothing. The silence is the tell.
- Then step 3.

### 3. The cheat — the "oh fuck"

This is the 3.0-second gap that currently reads as a crash. It is the most
important beat on the screen and it has the timing slot already.

- Beat. The House: *"Wait."*
- Beat. *"You... won? Already?"*
- The pot pile, which was moving toward the player, **stops**.
- *"No."*
- Card 6 comes out of the slot and slaps down on **BASE** in the readout. The
  catalog base is buried. `= 100%` rolls to whatever `deck x mult` is, which on a
  first R1 win is `0%`.
- *"New card. Try again later."*
- Runout 2 resolves against the now-zeroed base. LOSS.
- This LOSS has a different weight from a normal loss and the summary says so:
  not *busted*, **robbed**.
- **Hold.**

R2 → card 7 onto **MULT**, bigger panic, same shape. The Act 3 version is the House
reaching for the slot and having nothing left to play, which is why underflow is
the ending.

### 4. The summary — on the felt, not a modal

`PrestigeModal` goes. What it said moves onto the table, under the result:

- BANKED THIS RUN, the {chip} glyph, the count. Big. This is the thing you kept.
- If the run banked nothing, say that too.
- The House, once, first shove only: *"The all-in is gone. Those stay yours."*

The act break (R1 / R2 won for the first time) is also on the felt, not a modal.
It is the House's line after the robbery: the reframe from `PrestigeModal`'s
`MILESTONE` table, delivered by the character that just cheated you.

### 5. The catalog arrives

It **slides in**, closed, from the edge of the felt. GRAB CORNER TO OPEN, which it
already says. It is a thing on the table now, next to your result, and you open
it when you want to. `intro_callout` shows on the cover for a first visit.

Continue leaves the shove screen. Deck select follows if unlocked.

### 6. Back on the grind

- **The shove meter.** A bar on the grind, near the SHOVE button, that fills toward
  100% and *visibly drains* when the number drops (a bankroll tier change, a
  cash-out). Persistent and ambient. This is the answer to "how do I get more %"
  and "what is a good %": you can see it move when you do things.
- **Bubbles everywhere.** See the next section.

---

## The teaching surface has to exist off the grind

`HintView` and `HintController` are instantiated only in `GrindState`, and
`GrindState:252` skips them whenever any modal is up. So the House cannot speak on
the shove screen, in the catalog, in deck select, or in the room, and the catalog
and deck select are blind even inside the grind. Zero anchors are registered in
`CatalogModal`, `DeckSelectModal`, `RoomView` or `ShoveView`.

Every hint added in the teaching pass fires on the grind only. That is a big
part of why the shove screen feels like nothing is explained: nothing *can* be.

Needed:

- Hint rendering hosted per state (shove, room) and drawn *above* modals in the
  grind, with `ctx` widened past the grind-shaped `{ state, pool, grind }`.
- Anchors in the four views that have none.
- Hints written for those surfaces: what the catalog is, what a sticker is, what
  the deck rack does, what the room is for, and everything on the shove felt.

This is its own slice and it is a prerequisite for most of the sequence above.

---

## Still true, from earlier in the thread

- Only 5 board cards ever sit in the row; 6 and 7 land on the readout. Built.
- Nothing may pre-spoil the structure. No slot under BASE/MULT, no empty result
  chips, no "runout 1" in the bust copy. Guarded by `no_spoilers.lua`.
- Every term is live until a card covers it: `r1 = cat x mult`,
  `r2 = 0 x mult`, `r3 = deck x 0`. Underflow puts a number on MULT the card
  cannot cover.
- Act 3 is a prestige loop: shove, spend {achip}, grind Ultra, lose, repeat, until
  one run bleeds past the threshold. The R3 burial plays on every Act 3 shove.
- The House does not change between acts. One room, one seat, one dealer.
  What separates the acts is which card it has left to play.
- `DEMO_CUT` never deals card 6 or 7; every beat in step 3 is inert in that build.

---

## What was built, in order

1. The off-grind hint surface: one host in `main.lua`, above every modal.
2. `PrestigeModal` deleted; result + summary on the felt; holds on click.
3. The loss beat: winner lit, loser grey, pot leaves, readout drains.
4. The cheat beat, with the win landing fully first, then the panic.
5. The poster and the slot the cards deal from.
6. Catalog slide-in, closed, no scrim.
7. The drain bar under the gauntlet's readout (not on the grind).
8. Win fanfare: confetti, which existed and was called nowhere.

Not built: the "why" line under the label pills ("Two pair beats a pair").
The pills already name both hands; whether a comparison line adds anything is
a call to make after seeing it.
