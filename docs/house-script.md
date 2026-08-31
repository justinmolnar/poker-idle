# The House script

Every line the House says, transcribed from the LIVE data. **The source of
truth is `data/story.lua`** (beats + the shove's keyed lines); this document
mirrors it for review. Voice, character, and copy rules live in
`docs/the-house-voice.md` — read that first. This is the ADORNED pass
(loan thread, questions thread, temperature curve).

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

## Running threads (do not break these when editing)

1. **THE LOAN.** The two dollars is a loan, established in `arrival`. It
   recurs at exactly: `first_payout` ("that part's yours"), `the_pitch`
   ("the loan renews"), `the_loop` ("same loan, same terms"), `first_catalog`
   ("not a loan, that part"), `act2` ("same loan, new terms"). He is an
   institution; he never misremembers the terms. Never call the two dollars
   "yours".
2. **THE QUESTIONS.** `arrival` prices the mystery ("answers are for poker
   players"). `first_chip` wires the door into it ("your first answer").
   `the_pitch` pays it off ("here's your answer, the only one that
   matters"). After the pitch the thread is CLOSED; no later line reopens it.
3. **THE TEMPERATURE CURVE.** Adornment is heaviest in Act 1, thinner in
   Act 2, nearly absent in Act 3 except "and I mean it" on anti-chips (the
   one mechanic where the player losing pays him). The banter drying up
   across acts is intentional characterization. Do not add warmth to
   Acts 2/3.
4. **MINIMAL BY DESIGN.** All `panic_*` keys, `clear`, all `deck_*` keys,
   `underflow`, and `credits` are deliberately bare; adornment or chatty
   neighbors dilute them. That is a style constraint, not frozen copy —
   nothing in this file is immutable.
5. **ONCE-ONLY PHRASES** (each appears exactly once, never reuse):
   "princess" (first line of the game), "I'm always here" (the pitch),
   "We'll fix that" (room_empty), "It's what I do" (chip_denied),
   "one always lands" (six_max_open).
6. **No question marks** in any line that can play before `panic_won`. His
   first question mark in the whole game is "You... won?". (Questions are
   asked and answered by himself with statement punctuation: "Sleep okay.
   Doesn't matter." / "See that.")

---

## Act 1

### `arrival` — grind. Trigger: hands_played 0, tables_open 0.
| block | anchor | hold |
|---|---|---|
| Morning, princess. Sleep okay. Doesn't matter, you look great. | | click |
| I know you've got questions. I've got answers. Not yet, though. Answers are for poker players, and so far all you've done is stand there. | | click |
| That's two dollars on the desk. Call it a loan. Put it on the felt. | `add_table:s001:zoom` | **FORCE** wait: tables_open ≥ 1 |
| There they go. Money on a table is tied up, not gone. You want it back, you cash out. You won't want it back. | `cell:tied`, `btn:cash_out` | click |
| Deal. | `table:1` | **FORCE** wait: hands_played ≥ 1 |

### `first_payout` — grind. Trigger: hands_played ≥ 1, bankroll > 0.
| block | anchor | hold |
|---|---|---|
| See that. A table only holds its buy-in. Win past full and the rest spills straight into your pocket. That part's not the loan. That part's yours. | `cell:bankroll` | click |

### `sharper_reads` — grind. Trigger: can afford Sharper Reads (strand-safe).
| block | anchor | hold |
|---|---|---|
| The rack on the right makes you better at every table. You can afford Sharper Reads. Grab it. I stock that rack myself. | `buy_runup_sharper_reads` | show: affordable → **FORCE** wait: run_upgrades_owned ≥ 1 |

### `second_table` — grind. Trigger: hu_unlocked (2nd buy-in was in hand).
| block | anchor | hold |
|---|---|---|
| Look at you, a second buy-in already. The duel just opened. Heads-Up. One opponent, whole stacks, both ways. It's where I pay. It's also where you get taken. | `gtype:hu` | click |
| Sit down. | `gtype:hu`, `add_table:s001:hu` | show: can afford → **FORCE** wait: HU table open |

### `first_chip` — grind. Trigger: chips_this_run ≥ 1.
| block | anchor | hold |
|---|---|---|
| Oh, nice. That's a {chip}. Real gold, I weigh them myself. Take a whole stack off a table and it pays one. Once per table per run, so spread out. | `chip_badge:banked` | click |
| You could've seen it coming. Hover the readout under a table. Go on. | `ev:1..4` | **FORCE** wait: hovering a readout |
| Everything a table does per hour, and its odds at all four pot sizes. The gold {w:stack} is the one that pays: its shot at a whole stack. | `ev:1..4` | click |
| Now compare your rooms. Zoom's gold number sits at {dyn:stack_odds_zoom} a hand. The duel runs {dyn:stack_odds_hu}. *(live numbers from the player's game)* | `ev:1..4` | click |
| Anything I teach you gets written down. The desk under my poster keeps the glossary. I keep very good records. | `btn:help` | click |
| Get three of those and you get your first answer. | `chip_badge:shove` | click |

### `the_pitch` — grind. Trigger: chips_this_run ≥ 3. Deliberately NOT forced.
| block | anchor | hold |
|---|---|---|
| Three! Look at you. So here's your answer, the only one that matters. The door. | `chip_badge:shove` | click |
| One hand, everything you've got on it. Win, and you walk out with the lot. Lose, and you keep the {chip}. The loan renews. No harm done. | `btn:shove` | click |
| Whenever you're ready. No rush. I'm always here. | `btn:shove` | click |

## The shove

### `shove_walkthrough` — shove. Trigger: phase buildup.
| block | anchor | hold |
|---|---|---|
| Everything you've got, in one pile. I love this part. | `shove:pot` | click |
| ITEMS is how many things you own. BANK is your money. The bar under them is your number. Keep an eye on it. | `shove:readout` | show: phase running |

### `shove_result` — shove. Trigger: result hold. (A receipt; receipts don't banter.)
| block | anchor | hold |
|---|---|---|
| BANKED is yours to keep. The all-in was everything else. | `shove:summary` | click |

### `house_cheats` — shove. Trigger: a cheat card is ON the felt (never a flag).
| block | anchor | hold |
|---|---|---|
| That card landed on your ITEMS and took them out of the count. The bar shows what's left. House rules. Nothing personal. | `shove:cheat_6` | click |

### Keyed shove lines (`shove:*`, scheduled by the shove's own timeline)
| id | line | |
|---|---|---|
| `pushing` | Pushing all in. | |
| `arrive` | All of it. That's the spirit. | |
| `loss` | Ah. House wins that one. Next time. | |
| `panic_wait` | Wait. |  |
| `panic_won` | You... won? Already? |  |
| `panic_no` | No. |  |
| `panic_new_card` | New card. Try again later. |  |
| `panic_again` | Twice. Nobody does this twice. |  |
| `panic_no_more` | You get nothing. Ever. |  |
| `clear` | There is nothing left to take from you. | once = true |
| `deck_no` | No. |  |
| `deck_again` | Again. |  |
| `deck_doesnt` | That one doesn't count. |  |
| `deck_deal` | Deal. |  |
| `deck_all` | All of it, then. |  |
| `deck_out` | There's nothing left to deal. |  |
| `room_count` | Let's see what you've got. | |
| `room_done` | That's your room. Not bad. | |
| `room_empty` | Nothing yet. That's fine. We'll fix that. | |

### `first_catalog` — shove. Trigger: catalog open.
| block | anchor | hold |
|---|---|---|
| Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, it's yours. Not a loan, that part. | `catalog:book` | click |
| That stamp's the price. Stickered ones aren't ready yet. The count says how close. | `catalog:price:first`, `catalog:sticker:first` | click |
| Close it when you're done and we'll set you back up. On the house. | `catalog:continue` | click |

### `the_loop` — grind. Trigger: has_shoved, a table open.
| block | anchor | hold |
|---|---|---|
| And we're back to two dollars. Same loan, same terms. That's a run. Sharper Reads went with it. Those reset. The catalog doesn't. | `cell:bankroll`, `buy_runup_sharper_reads` | click |
| Your odds on the big hand: what you own, times what you hold. So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time. | `cell:shove`, `chip_badge:shove` | click |
| One more thing. The key to the 6-Max room is in the catalog. Keep collecting. The long game. Slow, deep, worth it. Best carpet in the building. | `gtype:six_max` | click |

## Rooms and tools, as they first exist

### `six_max_open` — grind. Trigger: a 6-max table open.
| The long game. Slow hands, five stacks on the table, and the fattest pots in the room when one finally lands. And one always lands. | `gtype:six_max` | click |

### `first_tournament` — grind. Trigger: an MTT open.
| A tournament. One buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}. Great business, tournaments. | `gtype:mtt` | click |

### `first_cursors` — grind. Trigger: owns box_of_mice.
| Look at you, management. The cursors deal for you now. More of them, and faster, in the sidebar. The D on a table stops them dealing there. | `buy_runup_box_of_mice`, `buy_runup_cursor_speed` | click |

## Reactive lessons (first time the situation exists)

### `stake_ladder` — grind. Trigger: can afford NL10.
| NL10's open. That's {dyn:stake_mult_s002} times the money, but the players are better. Worth an upgrade or two first. Just my advice. It's good advice. | `add_table:s002:zoom` | click |

### `first_bust` — grind. Trigger: any table busted.
| Empty, not gone. REBUY puts a fresh stack on it. Happens to everyone. | `rebuy:any` | click |

### `chip_denied` — grind. Trigger: a denied stack.
| That table's already paid its {chip}. Each stake and game pays once per run. Climb, or come back next run. I keep count. It's what I do. | `chip_badge:banked` | click |

### `focus_overload` — grind. Trigger: focus overloaded.
| Easy, tiger. That's a lot of tables, and you're playing all of them a bit worse. Close one, or grab Focus. | `cell:focus`, `buy_runup_focus` | click |

### `the_room` — room. Trigger: on the room screen.
| Everything you buy ends up in here. It'll fill up. PLAY takes you back to the tables. | `room:play` | click |

(Note: deliberately no "they always do" or anything implying previous
guests. The no-history rule outranks banter, always.)

### `first_corruption` — shove. Trigger: catalog open, a CORRUPTED item exists.
His second-ever question mark, spent on the player's first act of vandalism.
Corruption and {achip} are NOT HIS and get no tutorialization anywhere (see
the voice doc's treason section); all he does is notice.
| Wait. What did you do to it? | `catalog:corrupt:first` | click |

## Acts 2 and 3 (cooler, by design)

### `act2` — grind. Trigger: first shove hand won.
| block | anchor | hold |
|---|---|---|
| You actually won that. Good for you. The next hand doesn't count your catalog. Just your deck. Same loan, new terms. | `cell:deck` | click |
| It levels up as it plays, and its bonus is on every hand. Level them all you want. It keeps you busy. | `cell:deck` | click |
| The big tables are open now. Bring money. | `add_table:s004:zoom` | click |
| And the tournament room. Eight seats, one winner. It pays the tables around it more than it pays you. | `gtype:mtt` | click |

### `act2_decks` — shove. Trigger: deck select open. (Mid-recovery; bare procedure IS the characterization.)
| Pick one. It plays the next run. The locked ones tell you what opens them. | `deck:tile:1` | click |
| The bar on each fills as the deck plays. Full bar, next level, better bonus. | `deck:xp` | click |

### `act3` — grind. Trigger: both shove hands won.
| block | anchor | hold |
|---|---|---|
| Twice. Honestly, that's a first. Bad news: the last card covers your multiplier, so the final hand is a zero however rich you are. | `cell:shove` | click |
| No new deck this time. No new terms. That's the game now. Play as long as you like. | | click |

Act 3 opens HOPELESS, as policy: no new deck, no new terms, no tool. The
stated finality is what sends the player looking off the board — and
corruption itself is the signpost that off-the-board exists (stuff he
doesn't know about, happening, and he doesn't like it). Nothing more is
needed or allowed.

### `the_top_table` — grind. Trigger: ultra_unlocked (the Ultra key bought).
He has no idea the count can break; this is simply the biggest game in the
building and he is delighted. The player losing whole stacks up there is
his best business — he is sincerely cheering the instrument of his own
destruction.
| The top table's open. Biggest game in the building. Go on. | `add_table:s010:zoom` | click |

### `underflow` — grind. Trigger: bankroll below the floor.
| That's... not a number. | `cell:bankroll` | click |
| I don't have a card that covers that. Go on. Shove. | `btn:shove` | click |

### `credits` — credits screen. delay 1.5s.
| See you tomorrow. | | click |

---

## The one popup (not a beat)

`quick_reset` (sticky, `data/hints.lua`): *Stuck? Happens. Free reset to two
dollars, and your {chip} come with you.* — anchored on the rescue button,
shows while a quick reset is possible.

## Cut priority (if playtests show Act 1 dragging)

Cut flavor sentences in this order, and ONLY these; the rest of the
adornment is load-bearing (loan thread, questions thread, the once-only
phrases):

1. sharper_reads: "I stock that rack myself."
2. stake_ladder: "Just my advice. It's good advice."
3. first_chip: "Real gold, I weigh them myself."
4. first_tournament: "Great business, tournaments."
