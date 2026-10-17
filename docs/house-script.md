# The House script

Every line the House says, transcribed from the LIVE data. **The source of
truth is `data/story.lua`** (beats + the shove's keyed lines); this document
mirrors it for review. Voice, character, and copy rules live in
`docs/the-house-voice.md` — read that first. This is the 2026-09-05 pass
from the designer's rewrite (tools/story_editor export).

Review tool: `tools/story_editor.html` (open from file://, pick the repo) lists
every beat by its trigger and exports a JSON change list to apply here and in
`data/story.lua`.

In the game (dev builds): **F9** opens the beat browser — every beat on a
stage built for it, in the game's own skin: ←/→ a line, ↑/↓ a beat, a panel
with the trigger, the line's fields, which targets are lit and which are
missing, the box's lines and pages; N/B take a note per line/beat into
`tools/story_notes.json`. The game is parked meanwhile and nothing saves.

Supporting surfaces, also in his voice:
- `data/glossary.lua` — the written-down versions of every lesson (the desk
  under his poster). Exposure = the beat that taught it has played.
- `data/hints.lua` — ONE sticky rescue popup (`quick_reset`). The old `[i]`
  info-popup tier is retired; beats and the glossary carry all teaching.

## Delivery

He speaks through the intercom bolted to his poster: a burst of static keys
the mic, the text types out word by word in the caption band (the jagged
shout-burst tail points at the speaker), the speaker rattles and a chopped
voice/static bed plays while the text is arriving, and the music he pipes in
CUTS while any bubble of his is up (pre-speakers). Silence when the words
stop. A click mid-type completes the block; the next click advances.

## Asides

`data/story.lua` `asides`, placed by the director, each once. **gift**: the
first time a beat ends with NOTHING armed to follow it on the grind (the
opening's run is over, the player is about to get the floor) he goes straight
on into "Play nice and I'll put something on for you… Jazz."; the click
through it is the release, and the music starts (it is silent until then).
**music**: the first beat that starts after that opens with "One thing. I
can't play the music and talk at the same time…" — the music has just cut
under him. Never on a replay or in the beat browser.

## Beat mechanics

Beats play ONE at a time, in script order. Triggers ARM the moment they pass
(anywhere, even mid-beat or behind a menu, persisted) and the beat plays when
the band is free on its own screen — a transient trigger is never lost. A
seen beat never replays. Beat N can assume beats above it have played.

Line notation: `click` holds for a click/SPACE. `wait: <cond>` holds until
the condition passes. **`FORCE`** = the screen dims to the line's targets and
clicks anywhere else are swallowed: the player must DO the thing, and the
action itself advances the line. `show: <cond>` delays the line until true.

**PAUSE** (a beat flag): the simulation freezes while one of the beat's
lines is up — the shove clock, the tables, the cursors, the status timers —
so what he points at is still there when he says it. The click resumes it.
A forced `wait` line never freezes. Only the beats marked below have it.

## Running threads (do not break these when editing)

1. **THE LOAN.** The two dollars is a loan, established in `arrival`
   ("Call it a loan"). It recurs at: `the_pitch` ("the 2 dollar loan"),
   `the_loop` ("same loan, same terms"). He is an institution; he never
   misremembers the terms. Never call the two dollars "yours".
2. **THE QUESTIONS.** `arrival` prices the mystery ("answers are for poker
   players"). `first_chip` wires the door into it ("your first answer").
   `the_pitch` pays it off ("here's your answer"). After the pitch the
   thread is CLOSED; no later line reopens it.
3. **THE TEMPERATURE CURVE.** Adornment is heaviest in Act 1, thinner in
   Act 2, nearly absent in Act 3. The banter drying up across acts is
   intentional characterization. Do not add warmth to Acts 2/3.
4. **MINIMAL BY DESIGN.** All `deck_*` keys, `clear` and `underflow` are
   deliberately bare; adornment or chatty neighbors dilute them. That is a
   style constraint, not frozen copy — nothing in this file is immutable.
5. **ONCE-ONLY PHRASES** (each appears exactly once, never reuse):
   "princess" (first line of the game), "I'm always here" (the pitch),
   "We'll fix that" (room_empty).
6. **Question marks.** The 2026-09-05 pass put his first question mark in
   `shove_walkthrough` ("...Am I reading that right? 0%?"), before
   `panic_won`. The old rule (none before the panic) is retired; the panic
   still carries the first question he asks the PLAYER.
7. **The cards' names.** The sixth card is the Undertow, the seventh the
   Ferry. He names each only once it is on the felt (`house_cheats`,
   `panic_again` / `panic_no_more`).

---

## Act 1

### `arrival` — grind. Trigger: hands_played 0, tables_open 0.
A fresh game has no money. Line 3 HANDS OVER the loan (`grant = "loan"`): the
bankroll climbs from 0 to 2.00 as the block lands. Every run reset renews it
the same way, climbing from 0, with no line.
| block | anchor | hold |
|---|---|---|
| Morning, princess. You must've had the best sleep of your life. | | click |
| I know you've got questions. I've got answers. Not yet, though. Answers are for poker players, and so far all you've done is stand there. | | click |
| Here's 2 dollars. Call it a loan. Put it on the felt. | `cell:bankroll`, `add_table:s001:zoom` | **FORCE** wait: tables_open ≥ 1 |
| The 2 dollars is on the table. You want it back, you cash out. But we've got poker to play. | `stack:1`, `cell:tied` | click |
| Click on the table to deal. | `table:1` | **FORCE** wait: hands_played ≥ 1 |

### `first_hand_lost` — grind. Trigger: the first resolved hand lost.
| Looks like you {c:lost:lost} that one. ⏎ Luckily it was only {dyn:first_hand_amount} {dyn:first_hand_tier}. | `stack:1` | click |

### `first_hand_won` — grind. Trigger: the first resolved hand won.
| Looks like you {c:won:won} your first hand. We're going to get along just fine. You can see the size of the win here. It was {dyn:first_hand_amount} {dyn:first_hand_tier}. | `stack:1` | click |

### `payout_sizes` — grind. Trigger: hands_played ≥ 1 (arms with the first-hand beats; plays after whichever of the two fired).
| Payouts come in many sizes. ⏎ Losses: {l:small} {l:medium} {l:large} {l:stack} ⏎ Wins: {w:small} {w:medium} {w:large} {w:stack} | | click |

### `first_payout` — grind. Trigger: hands_played ≥ 1, bankroll > 0.
| A table only holds its buy-in. {c:won:Win} past full and the rest ends up in the bankroll. Yours to spend how you see fit. | `stack:1`, `cell:bankroll` | click |

### `sharper_reads` — grind. Trigger: can afford Sharper Reads (strand-safe).
| block | anchor | hold |
|---|---|---|
| You can afford {c:upgrade:Sharper_Reads}. Grab it. | `buy_runup_sharper_reads` | show: affordable → **FORCE** wait: run_upgrades_owned ≥ 1 |
| That'll improve your {c:chance:odds} of winning. Hover {c:upgrade:Pot_Control}. | `buy_runup_pot_control` | **FORCE** wait: a fresh hover of Pot Control (the mouse has to leave and come back) |
| Hovering lets you know what things do. Use it if you're lost. *(said with the hover's tooltip held up)* | `buy_runup_pot_control` | click |
| I'm keeping notes. If you forget what anything does, use this button to see them. | `btn:help` | click |
| You'll want to keep an eye on the {c:upgrade:upgrade_rack}, you won't have a chance in hell at the higher stakes without it. The players get better at every stake. | `buy_runup_sharper_reads` | click |

### `second_table` — grind. Trigger: hu_unlocked (2nd buy-in was in hand).
| block | anchor | hold |
|---|---|---|
| Look at you, a second buy-in already. Heads-Up just opened. One opponent, whole stacks, both ways. Sit down. | `gtype:hu`, `add_table:s001:hu` | show: can afford → **FORCE** wait: HU table open |

### `first_chip` — grind. Trigger: chips_this_run ≥ 1.
| block | anchor | hold |
|---|---|---|
| You rinsed him. got his whole stack {w:stack}. | `stack:banked` | click |
| It came with a {chip}. Real gold, I weigh them myself. Win a {w:stack} at a table and it pays one. | `cell:chips`, `chip_badge:banked`, `stack:banked` | click |
| Only the FIRST {w:stack} at each stake and game pays a {chip}, once a run. You can tell a table's {c:chip:paid} by the border on the felt, or on its button. | `table:banked`, `add_table:banked`, `chip_badge:banked` | click |
| You can also see how many {chip} you'll earn for a {w:stack} here. Higher stakes, better {c:won:payouts}. | every `add_table_chip:*` badge on the strip | click |
| Get 3 {chip}, and you'll get your first answer. | `cell:chips`, `chip_badge:banked` | click |
| While we're here, hover the readout under a table. Go on, don't keep me waiting. | `ev:1..4` | **FORCE** wait: hovering a readout |
| What a table makes an hour, and its {c:chance:odds} at every pot size. The gold {w:stack} is the one that pays. | `ev:1`…`ev:4`, `add_table_ev:<stake>:<gtype>` (every add-table row that reads out) | click |
| Zoom's gold number currently sits at {dyn:stack_odds_zoom} a hand. Heads-Up runs {dyn:stack_odds_hu}. | `stack_pct:1..4` | click |
| Zoom players rarely go all in. Until you get better at reeling them in at least. | `ev:1..4` | click |

### `the_pitch` — grind. Trigger: chips_this_run ≥ 3. Deliberately NOT forced.
| block | anchor | hold |
|---|---|---|
| Three! Look at you. So here's your answer. | `cell:chips` | click |
| There's only one way out of here. Straight through the {c:chip:door}. | `btn:shove` | click |
| But first, you gotta get past me. One hand, everything you have goes in. No need to cash out your tables, I'll do it for you. Winner takes all. | `btn:shove` | click |
| {c:won:Win}, and you walk out with the lot. {c:lost:Lose}, and you keep the {chip}. I'll set you back up with the 2 dollar loan. No harm done. | `btn:shove` | click |
| Whenever you're ready. No rush. I'm always here. If you feel like you've stalled out, it's usually a good idea to hold SHOVE. | `btn:shove` | click |

## The shove

The first shove skips the room count entirely (nothing owned, nothing to
count); the ROOM button on the grind appears only after that shove.

### `shove_walkthrough` — shove. **PAUSE.** Trigger: phase buildup.
| block | anchor | hold |
|---|---|---|
| Everything you've got, in one pile. I'll match it if you win and you can walk right out. I love this part. | *(none)* | show: the pour has landed → click |
| That equation's your shot at beating me. Don't worry about the numbers yet, I'll walk you through them later. | `shove:readout` | show: phase running → click |
| I'm pretty good though. ...Am I reading that right? 0%? Bad luck. | `shove:readout` | click (the runout deals after it) |

### `shove_result` — shove. **PAUSE.** Trigger: result hold.
| Looks like you {c:chip:banked} {dyn:banked_chips} {chip}. Those are yours to keep, call it a consolation prize. | `shove:summary` | click |

### `house_cheats` — shove. **PAUSE.** Trigger: a cheat card is ON the felt (never a flag).
| I forgot to tell you about the undertow card. Unfortunately it landed on your ITEMS and took them out of the count. The bar shows what's left. House rules. Nothing personal. | `shove:cheat_6` | click |

### Keyed shove lines (`shove:*`, scheduled by the shove's own timeline)
Fixed slots; an empty text is a silent slot.
| id | line | |
|---|---|---|
| `pushing` | Pushing all in. | |
| `arrive` | All of it. That's the spirit. | |
| `loss` | Ah. House {c:won:wins} that one. I'm sure you got the next one though. | |
| `panic_wait` | Wait...No no nono |  |
| `panic_won` | What just happened? |  |
| `panic_no` | *(silent)* |  |
| `panic_new_card` | New card. Try again later. |  |
| `panic_again` | You survived the undertow? How is that even possible. |  |
| `panic_no_more` | Sadly though, no one crosses the ferry. Clumsy me dropped it on your bankroll, hope that doesn't change the... | lands before the 7th card |
| `clear` | There is nothing left to take from you. | once = true |
| `deck_no` | No. |  |
| `deck_again` | Again. |  |
| `deck_doesnt` | That one doesn't count. |  |
| `deck_deal` | Deal. |  |
| `deck_all` | All of it, then. |  |
| `deck_out` | There's nothing left to deal. |  |
| `room_count` | Let's see what you've got. | not on the first shove |
| `room_done` | That's your room. Not bad. | |
| `room_empty` | Nothing yet. That's fine. We'll fix that. | |

### `first_catalog` — shove. **PAUSE.** Trigger: catalog open.
| block | anchor | hold |
|---|---|---|
| Before you head back, have a look at the catalog. Anything in here you keep. | `catalog:book` | **FORCE** wait: catalog open |
| Buy it, and it'll be delivered right to your room. | `catalog:book` | click |
| The stamp's the price, in {chip}. Stickered ones aren't ready yet. But they usually tell you why. | `catalog:price:first`, `catalog:sticker:first` | show: catalog open → click |
| Close it when you're done and we'll set you back up. How fun. | `catalog:book` | click |

### `first_purchase` — shove. Trigger: the first item owned.
| block | anchor | hold |
|---|---|---|
| Added to the manifest. | `catalog:manifest` | click |

### `the_loop` — grind. Trigger: has_shoved (the moment the felt is back; no table needed).
| block | anchor | hold |
|---|---|---|
| Same loan, same terms. Run it back. | `cell:bankroll` | click |
| Your {c:upgrade:upgrades} went with it. Those reset. | every `buy_runup_*` row on the rack (whichever exist) | click |
| Let's take a look at your room. | `btn:room` | **FORCE** wait: on the room screen |

### `the_room` — room. Trigger: has_shoved, on the room screen.
| block | anchor | hold |
|---|---|---|
| Cozy. Everything you bought from the catalog, delivered as promised. These never reset. | `room:items` | click |
| Remember the SHOVE equation? It's ITEMS in your room, multiplied by your BANKROLL, tables included. That's why it was 0%. You didn't own anything yet. | | click |
| So it's about {chip} now. Every table pays at least one. Higher stakes pay more. Collect, then shove. You'll get it. Next time. | `room:play` | click |

### `catalog_browse` — grind. **PAUSE.** Trigger: on the grind, the catalog open (the read-only book from the desk).
| The Catalog. Browse all you like, but you can only make purchases after a SHOVE. | *(none: the book is the whole screen)* | click |

## Rooms and tools, as they first exist

### `first_heat` — grind. **PAUSE.** Trigger: total_heaters ≥ 1.
| That table's on a {c:heat:heater}. If it's mid-hand, that hand {c:won:wins} now. The next hand is dealt for you, and it {c:won:wins} too. Fire's your friend. | `table:heater` | click |

### `first_tilt` — grind. **PAUSE.** Trigger: total_tilts ≥ 1.
Tilt is granted at run start (the hidden Tilt catalog entry), so the first one lands on its own. He names it once, the way he named the heater; the glossary card opens on it.
| That table's on {c:tilt:tilt}. If it's mid-hand, that hand's {c:lost:lost}. The next hand is dealt for you, and it's {c:lost:lost} too. Happens at every table sooner or later. Ride it out. | `table:tilt` | click |

### `six_max_open` — grind. Trigger: a 6-max table open.
| The long game. Slow hands, five stacks on the table, and the fattest pots in the room when one finally lands. | `gtype:six_max` | click |
| This one's big and slow, like a tank. It drips between the big ones, so leave it running. MOST things that help a table help this one the most. Hell, even things that hurt most tables can help at 6-Max. | `gtype:six_max` | click |

### `first_tournament` — grind. Trigger: a tournament open.
| A tournament. One buy-in, no rebuy. Eight seats, ten blinds each, and it deals itself. | `gtype:ko` | click |
| The blinds climb as it goes, and you sit some hands out while the rest of them play. Your {c:upgrade:upgrades} set your odds in it. | `gtype:ko` | click |
| Each player it knocks out is a {ko}. Top three cash. Win it outright for the {chip}. They have their place. A {ko} can improve your other tables. | `gtype:ko` | click |

### `first_cursors` — grind. Trigger: owns box_of_mice.
The right-click controls: views/GrindView:_rightClick.
| Ah, you got the box of mice, excellent. The cursors can deal for you if you're tired of doing it yourself. | `buy_runup_cursor`, `buy_runup_cursor_speed` | click |
| Right click a table, a table button, or the {c:upgrade:Cursor} upgrade to stop them dealing at that table, those tables, or all tables. Right click again to start them. | `table:1`, `add_table:open`, `buy_runup_cursor` | click |

## Reactive lessons (first time the situation exists)

### `stake_ladder` — grind. Trigger: can afford NL10.
| NL10's open. That's {dyn:stake_mult_s002} times the money, but the players are better. The number's {c:lost:red}. I wouldn't recommend playing here until you get a few more {c:upgrade:upgrades} first. | `add_table:s002:zoom`, `add_table_ev:s002:*` (the $/h readout) | click |

### `first_bust` — grind. Trigger: any table busted.
| So much for knowing what you're doing I guess, you {c:lost:lost} your whole stack at this table. | `rebuy:any` | click |
| To keep playing you'll have to rebuy, don't let it happen again. | `rebuy:any` | click |

### `chip_denied` — grind. Trigger: a denied stack.
| You {c:won:won} another {w:stack} but no {chip}. This table type's already {c:chip:paid} its {chip}. Each stake and game pays once per run. Climb. | `chip_badge:banked` | click |

### `focus_overload` — grind. Trigger: focus overloaded.
| Easy, tiger. FOCUS is how many tables you can keep up with. Up to {dyn:focus_cap}, they all play at full speed. Every table past that slows ALL of them by {dyn:focus_penalty_pct}. Adds up fast. Raise it with {c:upgrade:Focus} on the rack, or close a table. | `cell:focus`, every table's X (`table_close:N`), every row's X (`cash_out_type:*`) | click |

### `first_corruption` — shove. Trigger: catalog open, a CORRUPTED item exists.
Corruption and {achip} are NOT HIS and get no tutorialization anywhere (see
the voice doc's treason section); all he does is notice.
| Wait. What did you do to it? | `catalog:corrupt:first` | click |

## Acts 2 and 3 (cooler, by design)

### `act2` — grind. Trigger: first shove hand won.
| block | anchor | hold |
|---|---|---|
| I hope the undertow didn't catch you off guard. I forgot, we have a couple house rules in play. I can't remember if there are others. |  | click |
| The mid stakes are open now. Bring money. | `add_table:s004:zoom`, `add_table:s005:zoom`, `add_table:s006:zoom` | click |

### `flyer_lands` — shove. Trigger: the deck flyer has landed on the felt.
| I have a new flyer for you, check it out. | `deck:flyer` | **FORCE** wait: the flyer open |

### `act2_decks` — shove. Trigger: the deck flyer open.
| You can only run one at a time, its bonus levels up as you play. Reach level 5 for the Capstone bonus effect. | `deck:tile:1` | click |
| ALL your decks give you their bonus, whether they're active or not. So it's in your best interest to diversify. | `deck:xp` | click |

Act 3 has no grind lede any more: the second win is narrated on the felt
by `panic_again` / `panic_no_more` as the Ferry lands.

### `the_top_table` — grind. Trigger: ultra_unlocked (the Ultra key bought).
| I didn't even know we had a table that big. Not that it matters for you, get as high as you want you're never getting a multiplier above zero again. | `add_table:s010:zoom` | click |

### `underflow` — grind. Trigger: the scripted Ultra loss takes the bankroll below the floor.
| You lost at the ULTRA stake. That must sting. | `cell:bankroll` | click |
| Wait...what happened to your multiplier? | `cell:shove` | click |

The credits screen has no line now.

---

## The one popup (not a beat)

`quick_reset` (sticky, `data/hints.lua`): *Stuck? Happens. Free reset to two
dollars, and your {chip} come with you.* — anchored on the rescue button,
shows while a quick reset is possible.
