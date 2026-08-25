# The House script

Every line the House says, in order. This is the source of truth for
`data/story.lua` (beats) and `data/hints.lua` (popups). Copy is reviewed here,
then transcribed; the game never gets a line this document doesn't have.

## Who is talking

The House. It owns the room, the tables, the catalog, the chips, the furniture,
and the door. It is friendly. Genuinely: it likes having you here, it wants you
to do well, it explains things because a player who understands the tables
makes more money, and it is pleased when you do. It wants you to shove because
that is the big moment and it is rooting for you. It is profiting off you the
whole time and it cheats when you win, and none of that is in the tone. The
menace is entirely in the facts; the voice is a good host.

Rules that keep sixty lines sounding like one mouth:

- Normal. Plain sentences, contractions, the odd "nice" or "there you go".
  No menace, no purr, no clipped villain cadence.
- Helpful. He explains things the way a friend at the table would, and he gives
  advice ("I'd grab that").
- A block is one click's worth of reading: a few sentences, wrapped in the box.
  Not one click per sentence.
- He is warm about your wins and easy about your losses. "Next time" is his
  favourite phrase.
- He never says the door is a lie. The panic is the only time it slips.
- Reveal rule: nothing that can play before a runout win names a runout, a cheat,
  a card count, or the second hand.
- No em-dashes. `{chip}` never the word "chips". Cut filler.

## Two tiers

**Story beats** run in the order below, one at a time, in the band at the bottom
of the screen (the shove's headline slot on the shove). Each line points at
something (the pulsing mark) and either holds for a click, a timer, or a
condition. A beat that has been seen never plays again, and there are no skip
conditions: a beat plays for every save the first time its trigger passes,
however far along that save is. Beat N can assume beats 1..N-1 played.

**Popups** are the `[i]` bubbles. Each has its own trigger and explains one thing.
**A popup never says anything that depends on story progress**: no "run", "reset",
"act", "last time", and no trigger on story state. If a fact needs that, it is a
beat.

Hold notation: `click` waits for a click on the box or SPACE. `2s` advances
itself. `wait: <cond>` holds until the condition passes (the "you can afford it
now" move). The last line of a beat with no hold ends the beat when it is clicked.

---

## Story beats

Each row is one BLOCK: one click's worth of reading, wrapped in the box.

### S1 `arrival`
Screen: grind. Trigger: screen name grind, hands_played max 0, tables_open max 0.

| block | anchor | hold |
|---|---|---|
| Welcome in. Have a seat. You play, I run the room. Easy. |  | click |
| Two dollars to start. It's yours. Win one big hand and you walk out of here. | `cell:bankroll` | click |
| Go on, open a table. | `add_table:s001:six_max` | wait: tables_open min 1 |

### S2 `look_around`
Screen: grind. Trigger: hands_played min 2.

| block | anchor | hold |
|---|---|---|
| Everything here explains itself. Hover anything. The upgrades on the right make you better at the tables. | `ev:1`, `buy_runup_sharper_reads` | click |
| You can afford Sharper Reads now. I'd grab it. | `buy_runup_sharper_reads` | show: can_afford_run_upgrade id sharper_reads → wait: run_upgrades_owned min 1 |

### S3 `second_table`
Screen: grind. Trigger: tables_open min 1 max 1, can_afford_stake stake s001.

| block | anchor | hold |
|---|---|---|
| One table's a bit slow. Open another. | `add_table:s001:six_max` | wait: tables_open min 2 |

### S4 `first_chip`
Screen: grind. Trigger: chips_this_run min 1.

| block | anchor | hold |
|---|---|---|
| Oh, nice. That's a {chip}. Take a whole stack and a table pays one. One per table, so spread out. | `chip_badge:banked` | click |
| Get three and we'll talk about the door. | `chip_badge:shove` | click |

### S5 `the_pitch`
Screen: grind. Trigger: chips_this_run min 3.

| block | anchor | hold |
|---|---|---|
| Three! Look at you. So here's how you get out of here. | `chip_badge:shove` | click |
| One hand, everything you've got on it. Win, and you walk out with the lot. Lose, and you keep the {chip}. No harm done. | `btn:shove` | click |
| Whenever you're ready. No rush. | `btn:shove` | click |

### S6 the shove (`shove:*`)
Scheduled by the shove timeline, not the director. The act ledes play on the grind (S9, S10).

| id | line |
|---|---|
| `shove:pushing` | Pushing all in. |
| `shove:arrive` | All of it. Here we go. |
| `shove:loss` | Ah. House wins that one. Next time. |
| `shove:panic_wait` | Wait. |
| `shove:panic_won` | You... won? Already? |
| `shove:panic_no` | No. |
| `shove:panic_new_card` | New card. Try again later. |
| `shove:panic_again` | Twice. Nobody does this twice. |
| `shove:panic_no_more` | You get nothing. Ever. |
| `shove:clear` | There is nothing left to take from you. (once) |

### S7 `first_catalog`
Screen: shove. Trigger: screen name shove, catalog_open.

| block | anchor | hold |
|---|---|---|
| Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, it's yours. | `catalog:book` | click |
| That stamp's the price. Stickered ones aren't ready yet. The count says how close. | `catalog:price:first`, `catalog:sticker:first` | click |
| Close it when you're done and we'll set you back up. | `catalog:continue` | click |

### S8 `the_loop`
Screen: grind. Trigger: screen name grind, has_shoved, tables_open min 1.

| block | anchor | hold |
|---|---|---|
| And we're back to two dollars. That's a run. Sharper Reads went with it. Those reset. The catalog doesn't. | `cell:bankroll`, `buy_runup_sharper_reads` | click |
| Your odds on the big hand: what you own, times what you hold. So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time. | `cell:shove`, `chip_badge:shove` | click |

### S9 `act2`
Screen: grind. Trigger: screen name grind, act2_unlocked.

| block | anchor | hold |
|---|---|---|
| You actually won that. Good for you. The next hand doesn't count your catalog. Just your deck. | `cell:deck` | click |
| It levels up as it plays, and its bonus is on every hand. Max out five and something new joins the rack. | `cell:deck` | click |
| The big tables are open now. Bring money. | `add_table:s004:six_max` | click |

### S9b `act2_decks`
Screen: shove. Trigger: screen name shove, deck_select_open.

| block | anchor | hold |
|---|---|---|
| Pick one. It plays the next run. The locked ones tell you what opens them. | `deck:tile:1` | click |

### S10 `act3`
Screen: grind. Trigger: screen name grind, act3_unlocked.

| block | anchor | hold |
|---|---|---|
| Twice. Honestly, that's a first. Bad news: the last card covers your multiplier, so the final hand is a zero however rich you are. | `cell:shove` | click |
| Good news: lose a whole stack anywhere and I'll pay you for it. The cheaper the table, the more. Spend those in the catalog on things you already own. | `cell:achips`, `btn:catalog` | click |
| And your money sits in a box with a bottom. Worth knowing. | `cell:underflow` | click |

### S11 `credits`
Screen: credits. Trigger: screen name credits.

| block | anchor | hold |
|---|---|---|
| See you tomorrow. |  | delay 1.5s → click |

---
## Popups (stateless, his voice)

Each: trigger, anchor, text. Text can wrap in the bubble. `sticky` = stays until
done.

| id | trigger | anchor | text |
|---|---|---|---|
| `table_stats` | hands ≥ 5 | `ev:1..4` | Hands come in four sizes. / wins {w:small} {w:medium} {w:large} {w:stack} / losses {l:small} {l:medium} {l:large} {l:stack} / $/h is what a table makes you per hand. The gold {w:stack} % is your shot at a whole stack. Hover for the math. |
| `help_exists` | hands ≥ 18 | `btn:help` | Missed something I said? It's all at the help desk, any time. |
| `tied_up` | ≥1 table, tied ≥ $0.01, can't afford NL2 | `cell:tied`, `btn:cash_out` | Short on cash? Most of it's sitting on your tables, still in play. CASH OUT or close one to get it back. |
| `stake_ladder` | can afford NL10 | `add_table:s002:six_max` | NL10's open. Ten times the money, but the players are better. Worth an upgrade or two first. |
| `focus_overload` | focus overloaded | `cell:focus`, `buy_runup_focus` | That's a lot of tables. You're playing all of them a bit worse. Close one, or grab Focus. |
| `quick_reset` (sticky) | can quick reset | `btn:quick_reset` | Stuck? Happens. Free reset to two dollars, and your {chip} come with you. |
| `chip_denied` | denied stacks ≥ 1 | `chip_badge:banked` | That table's already paid its {chip}. Try a different stake or a different game. |
| `rebuy` | any table busted | `rebuy:any` | Empty, not gone. REBUY puts a fresh stack on it. |
| `gtype_hu` | HU table open | `gtype:hu` | Heads-up: one opponent. You'll win fewer hands, and the pots run deep both ways. |
| `gtype_zoom` | Zoom table open | `gtype:zoom` | Zoom deals you a new table every hand. More wins, smaller ones. |
| `gtype_mtt` | MTT table open | `gtype:mtt` | A tournament: one buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}. |
| `cursor_swarm` | owns `cursor_pool` | `buy_runup_box_of_mice`, `buy_runup_cursor_speed` | The cursors deal for you. More of them, and faster, in the sidebar. The D on a table stops them dealing there. |
| `shove_pot_pile` | shove, buildup | `shove:pot` | Everything you've got, in one pile. Here we go. |
| `shove_readout` | shove, running | `shove:readout` | BASE is your catalog. MULT is your money. The bar under them is your number. Keep an eye on it. |
| `shove_cheat_happened` | shove, cheat dealt ≥ 1 | `shove:cheat_6` | That card landed on your BASE and took it out of the count. The bar shows what's left. House rules. Plan around it. |
| `shove_banked` | shove, result hold | `shove:summary` | BANKED is yours to keep. The all-in was everything else. |
| `catalog_corruption` | catalog open, anti-chips ≥ 1 | `catalog:corrupt:first` | Things you own can be corrupted for {achip}. Corrupted ones do far worse things. |
| `deck_xp` | deck select open | `deck:xp` | The bar fills as the deck plays. Full bar, next level, better bonus. |
| `room_what` | screen room, first visit | `room:play` | Everything you buy ends up in here. PLAY takes you back to the tables. |

Cut: `first_table`, `hover_things`, `run_upgrades`, `multi_table`, `first_chip`,
`shove_ready`, `shove_pct`, `two_currencies`, `deck_rack`, `mid_stakes`,
`master_deck`, `anti_chips`, `high_stakes_farm`, `corruption`, `underflow`,
`shove_first_hold`, `catalog_what`, `catalog_sticker`, `catalog_price`,
`catalog_close`, `deck_tiles`, `deck_continue`. All absorbed by beats or by a button.

---

## Open questions for review

1. S1 line 4, "Win one big hand and you walk out of here." is the promise in one
   line, before the player knows what SHOVE is. It could wait for S5. I put it
   here because the premise should be said in the first thirty seconds.
2. S8's "That was a run." is the first time the word appears. Every popup avoids it.
3. The shove lines stay in the headline slot for now; moving them to the bottom
   band is a one-anchor change once the band exists.
