# The House script

Every line the House says, transcribed from the LIVE data. **The source of
truth is `data/story.lua`** (beats + the shove's keyed lines); this document
mirrors it for review. Voice, character, and copy rules live in
`docs/the-house-voice.md` — read that first. This is the 2026-09-05 pass
from the designer's rewrite (tools/story_editor export).

Review tool: `tools/story_editor.html` (open from file://, pick the repo) lists
every beat by its trigger and exports a JSON change list to apply here and in
`data/story.lua`.

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
| Deal. | `table:1` | **FORCE** wait: hands_played ≥ 1 |

### `first_hand_lost` — grind. Trigger: the first resolved hand lost.
| Looks like you {c:lost:lost} that one. Luckily it was only a {dyn:first_hand_tier}. | `stack:1` | click |
| {c:won:Wins} and {c:lost:losses} come at different sizes. {l:stack} {l:large} {l:medium} {l:small} {w:small} {w:medium} {w:large} {w:stack} Keep playing. | | click |

### `first_hand_won` — grind. Trigger: the first resolved hand won.
| Looks like you {c:won:won} your first hand. We're going to get along just fine. You can see the size of the win here, it was a {dyn:first_hand_tier} | `stack:1` | click |
| {c:won:Wins} and {c:lost:losses} come at different sizes. {l:stack} {l:large} {l:medium} {l:small} {w:small} {w:medium} {w:large} {w:stack} Keep playing. | | click |

### `first_payout` — grind. Trigger: hands_played ≥ 1, bankroll > 0.
| See that. A table only holds its buy-in. {c:won:Win} past full and the rest ends up in the bankroll. Yours to spend how you see fit. | `stack:1`, `cell:bankroll` | click |

### `sharper_reads` — grind. Trigger: can afford Sharper Reads (strand-safe).
| block | anchor | hold |
|---|---|---|
| You can afford {c:upgrade:Sharper_Reads}. Grab it. | `buy_runup_sharper_reads` | show: affordable → **FORCE** wait: run_upgrades_owned ≥ 1 |
| That'll improve your odds of winning. Hover it to see what it can do for you at the next level. | `buy_runup_sharper_reads` | **FORCE** wait: a fresh hover (the mouse has to leave and come back) |
| You'll want to keep an eye on the {c:upgrade:upgrade_rack}, you won't have a chance in hell at the higher stakes without it. The players get better at every stake. | `buy_runup_sharper_reads` | click |

### `second_table` — grind. Trigger: hu_unlocked (2nd buy-in was in hand).
| block | anchor | hold |
|---|---|---|
| Look at you, a second buy-in already. The duel just opened. Heads-Up. One opponent, whole stacks, both ways. | `gtype:hu` | click |
| Sit down. | `gtype:hu`, `add_table:s001:hu` | show: can afford → **FORCE** wait: HU table open |

### `first_chip` — grind. Trigger: chips_this_run ≥ 1.
| block | anchor | hold |
|---|---|---|
| You rinsed him. got his whole stack {w:stack}. | `stack:1` | click |
| It came with a {chip}. Real gold, I weigh them myself. Win a {w:stack} and the table and it pays one. *(CHECK: a word seems missing)* | `cell:chips`, `chip_badge:banked` | click |
| Remember though, It's only the FIRST {w:stack} at a table that pays a {chip}. You can tell if a table's {c:chip:paid} by the border on the felt, or the button. | `table:banked`, `add_table:banked`, `chip_badge:banked` | click |
| You can also see how many {chip} you'll earn for a {w:stack} here. Higher stakes, better {c:won:payouts}. | every `add_table_chip:*` badge on the strip | click |
| Get 3 {chip}, and you'll get your first answer. | `chip_badge:banked`, `chip_badge:shove` | click |
| While we're here, hover the readout under a table. Go on, don't keep me waiting. | `ev:1..4` | **FORCE** wait: hovering a readout |
| Everything a table does per hour, and its odds at all four pot sizes. The gold {w:stack} is the one that pays. | `ev:1..4` | click |
| Now compare your rooms. Zoom's gold number sits at {dyn:stack_odds_zoom} a hand. The duel runs {dyn:stack_odds_hu}. | `ev:1..4` | click |
| Zoom players rarely go all in. Until you get better at reeling them in at least. | `ev:1..4` | click |
| In case you forget anything, I'm keeping notes. | `btn:help` | click |

### `the_pitch` — grind. Trigger: chips_this_run ≥ 3. Deliberately NOT forced.
| block | anchor | hold |
|---|---|---|
| Three! Look at you. So here's your answer. | `chip_badge:shove` | click |
| There's only one way out of here. Straight through the {c:chip:door}. | `btn:shove` | click |
| But first, you gotta get past me. One hand, everything you have goes in. Winner takes all. | `btn:shove` | click |
| {c:won:Win}, and you walk out with the lot. {c:lost:Lose}, and you keep the {chip}. I'll set you back up with the 2 dollar loan. No harm done. | `btn:shove` | click |
| Whenever you're ready. No rush. I'm always here. If you feel like you've stalled out, then it's usually a good idea to SHOVE. | `btn:shove` | click |

## The shove

The first shove skips the room count entirely (nothing owned, nothing to
count); the ROOM button on the grind appears only after that shove.

### `shove_walkthrough` — shove. **PAUSE.** Trigger: phase buildup.
| block | anchor | hold |
|---|---|---|
| Everything you've got, in one pile. I'll match it if you win and you can walk right out. I love this part. | `shove:pot` | show: the pour has landed → click |
| This bar is your odds at beating me. I'm pretty good though. | `shove:readout` | show: phase running → click |
| ...Am I reading that right? 0%? Bad luck. | `shove:readout` | click (the runout deals after it) |

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
| Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, and it'll be delivered right to your room. | `catalog:book` | click |
| That stamp's the price. Stickered ones aren't ready yet. | `catalog:price:first`, `catalog:sticker:first` | show: catalog open → click |
| Close it when you're done and we'll set you back up. How fun. | `catalog:continue` | click |

### `the_loop` — grind. Trigger: has_shoved, a table open.
| block | anchor | hold |
|---|---|---|
| Same loan, same terms. That's a run. | `cell:bankroll` | click |
| Your {c:upgrade:upgrades} went with it. Those reset. | `buy_runup_sharper_reads` | click |
| Let's take a look at your room. | `btn:room` | **FORCE** wait: on the room screen |

### `the_room` — room. Trigger: has_shoved, on the room screen.
| block | anchor | hold |
|---|---|---|
| Everything you bought from the catalog, delivered as promised. These never reset. | `room:items` | click |
| Your odds on the SHOVE: Items in your room, multiplied by your total bankroll. | | click |
| So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time. | `room:play` | click |

## Rooms and tools, as they first exist

### `first_heat` — grind. **PAUSE.** Trigger: total_heaters ≥ 1.
| This table's {c:heat:on_fire}, if it was already on a hand, that one {c:won:wins}, the next hand is dealt for you. Guaranteed win. Fire's your friend. | `table:heater` | click |

### `six_max_open` — grind. Trigger: a 6-max table open.
| The long game. Slow hands, five stacks on the table, and the fattest pots in the room when one finally lands. | `gtype:six_max` | click |
| With so many players these take forever. Maybe you can speed them up somehow. | `gtype:six_max` | click |

### `first_tournament` — grind. Trigger: a tournament open.
| A tournament. One buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}. Great business, tournaments. | `gtype:ko` | click |
| Not for you of course, cash games pay better. They do have their place though, they can improve your other tables. | `gtype:ko` | click |

### `first_cursors` — grind. Trigger: owns box_of_mice.
The right-click controls described are not wired yet; the copy leads.
| Look at you, management. The {c:upgrade:cursors} can deal for you now. Buy them over here, and their {c:upgrade:upgrades}. Right click a table to stop them dealing there. You can also right click a table button to stop dealing to ALL of that type, or the {c:upgrade:cursor} button itself to COMPLETELY stop them from dealing. Right click again to enable. | `buy_runup_cursor`, `buy_runup_cursor_speed` | click |

## Reactive lessons (first time the situation exists)

### `stake_ladder` — grind. Trigger: can afford NL10.
| NL10's open. That's {dyn:stake_mult_s002} times the money, but the players are better. Worth an {c:upgrade:upgrade} or two first. | `add_table:s002:zoom` | click |
| The number's {c:lost:red}. I wouldn't recommend playing here until you get a few more {c:upgrade:upgrades} first | `add_table_ev:s002:*` (the $/h readout) | click |

### `first_bust` — grind. Trigger: any table busted.
| So much for knowing what you're doing I guess, you {c:lost:lost} your whole stack at this table. | `rebuy:any` | click |
| To keep playing you'll have to rebuy, don't let it happen again. | `rebuy:any` | click |

### `chip_denied` — grind. Trigger: a denied stack.
| You {c:won:won} another {w:stack} but no {chip}. This table type's already {c:chip:paid} its {chip}. Each stake and game pays once per run. Climb. | `chip_badge:banked` | click |

### `focus_overload` — grind. Trigger: focus overloaded.
| Easy, tiger. You can't focus on that many tables at once. ALL your {c:won:wins} at ALL tables win {dyn:focus_penalty_pct} less for each table above your focus cap. Adds up fast. | `cell:focus`, `buy_runup_focus` | click |

### `first_corruption` — shove. Trigger: catalog open, a CORRUPTED item exists.
Corruption and {achip} are NOT HIS and get no tutorialization anywhere (see
the voice doc's treason section); all he does is notice.
| Wait. What did you do to it? | `catalog:corrupt:first` | click |

## Acts 2 and 3 (cooler, by design)

### `act2` — grind. Trigger: first shove hand won.
| block | anchor | hold |
|---|---|---|
| I hope the undertow didn't catch you off guard, I should've told you about it sooner. Oh well. | `cell:shove` | click |
| The mid stakes are open now. Bring money. | `add_table:s004:zoom` | click |

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
