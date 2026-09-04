# Act 2 catalog audit — 2026-09-04

Scope: the 36 catalog items with `act = 2` (575 chips). Numbers come from
the full sweep (`node tools/balance_sweep.js`, `docs/balance-sweep.md`) and
from the bridge on a reference Act 2 board: 9 capped NL10K six-max tables
with Standard L5, which earns about $39M/hr. Where the sweep's own Act 2
board is used (six tables at mid fill including a tournament, older
assumption, −$274M/hr baseline) only the per-fire values and fire rates are
taken, not its totals. Where nothing measures an item, the arithmetic is
shown.

## The economy

- A run banks at most 84 chips: every lane (six stakes × four game types)
  once, `chip_award` 1..6. Realistic per run on the deck-per-run path:
  T1–T4 lanes in run 1 (40), T5 from run 2 (60), T6 from run 4 (84):
  about 410 chips over six runs, plus what Act 1 left over. The book costs
  575, so roughly 70% of it is buyable in Act 2 and the player chooses.
  That is fine; the shape is not: 82 of the 575 chips (14%) are cursor
  quality-of-life, and there is no cheap tier under 9 chips.
- Tip Jar multiplies every bounty ×1.5 (corrupt ×4). If chip awards are
  immutable as a rule, this item and Fight Night's `bounty_gtype_mult`
  are the two places that rule is broken. Decide whether "the award" means
  the data value or the banked amount.
- `shove_rate_add` per item ranges 0.010–0.022 (thirteen at 0.010, six at
  0.012, ten at 0.014, four at 0.016, two at 0.018, Tip Jar 0.022). The
  book adds 0.464 shove; at the flat 1% the design memory calls for it
  would be 0.36. Pick one; today a Tip Jar is worth 2.2 Laptop Terminals
  on the shove for no stated reason.

## Gates, and when they open on the deck-per-run path

| gate | items | opens around |
|---|---|---|
| `total_hands_at_4plus` 2,000 / 4,000 | Box of Mice / Second Monitor | run 1 / run 2 |
| `total_cursor_deals` 1k / 3k / 6k | Gaming Keyboard / Desk Lamp / Telephone | run 2 / 3 / 4 with the swarm on |
| `total_rebuys` 100 / 230 | Wacom / First Aid Kit | run 1 / run 3 |
| `total_busts` 275 / 300 | Vouchers / Kettle | run 2 |
| `total_stacks` 500 / 1,100 / 1,600 | Cleaning Robot / Receipt Printer / Toaster | Act 1 tail already banks ~900; run 1–2 |
| `total_upgrade_levels` 180 / 240 | Nightstand / Bookshelf | ~35 levels a run: run 5 / run 7 — Bookshelf opens after Act 2 is over |
| `total_chips_banked` 160 / 500 | Desk Speakers / Tip Jar | run 3 / never in Act 2 (410 total) |
| `total_tilts` 200 | Window | never without a tournament or six-max board (see tilt below) |
| `decks_unlocked_count` 5 | Blueprint | run 2 |
| `total_ko_wins` 1 | Prize Vase (and its five dependants) | first tournament win |

Tip Jar and Bookshelf are priced and gated for a player who has finished
the act. Window's gate assumes a tilt economy that may not exist.

## Structural findings

1. **Four items still run on the unauthorized statuses.** Tower Upgrade
   (marked), Fire Extinguisher (stacked mark), Framed Diploma (sharp),
   Blackout Curtains (sharp). They are also the four weakest procs on the
   Act 2 board: Tower −$284k/hr and Fire Extinguisher −$400k/hr (a
   both-sides tier bump is net negative where losses matter), Diploma
   +$18k/hr for 18 chips, Blackout +$175k/hr for 24. Repurpose all four
   onto heat / tilt.
2. **Three items duplicate a deck capstone.** Receipt Printer (+ Copy
   Machine, 38 chips together) is exactly Firehose's capstone. Console
   Television's router is Anchor's taunt for every status, heat included,
   so with Anchor on a board it drags heaters onto the slow table. Waste
   Basket is Anchor's capstone made global. Decide which owns the idea;
   the deck was the deliberate one.
3. **Exploits.**
   - Cereal Shelf: 10% of last run's losses seeds the next run. Act 2
     runs lose $10M–$100M, so the next run opens with $1M–$10M (corrupt
     75%: $8M–$75M) and buys NL10K's window, or an NL1M seat, at minute
     zero. It deletes the climb the pricing model prices. Cap the recycle
     at a fixed sum (the T1–T3 windows, about $10k) or move it to Act 3.
   - Electric Kettle corrupt refunds 120% of the buy-in on a bust: a
     table that busts pays you 20% of its seat every time. Cap at 100%.
   - Laminated Blueprint corrupt: ×8 deck XP turns one-maxed-deck-per-run
     into eight. Base ×1.5 is right; corrupt ×2.5 at most.
   - High Roller Pass: +1% win chance at a stake per tournament finish,
     uncapped, per table. One tournament table finishes ~20 a session, so
     cash games at that stake gain +20% per hour and reach the 0.95 cap
     in a run or two. Cap the backing (+10%) or decay it.
4. **Net-negative or dead at the new ladder.**
   - Chrome Toaster bumps losses too: negative in 30 of 48 home-band
     scenarios (worst −2,250 bb/hr at NL1M zoom). The wins-only kind now
     exists (`win_tier_bump_chance`); switch both variants to it.
   - Nightstand widens windows, the same mechanic that made Tier
     Manipulator a debuff: base 0, corrupt −45% EV median at T4–T6
     capped. Bookshelf already owns "+levels". Repurpose.
   - Rolled Vouchers: a seat is minutes of income at every Act 2 stake;
     −15% (corrupt −70%) on buy-ins is worth nothing. Repurpose.
   - Second Monitor: +1 focus for 10 chips beside a Focus upgrade that
     sells +10 for money; the sweep reads zero. Fold into Multitasker's
     old idea or cut.
5. **Tilt has no cash-game source.** Tilt comes from a tournament miss
   (neighbours) and a six-max cooler, nothing else. A zoom/HU player logs
   zero tilts all game (the audited save had 0 after two acts). That makes
   six items dead on that board (Microwave, Waste Basket, Fire
   Extinguisher, Blackout, Cool Towel, Window) and keeps the Anchor deck
   from ever opening. Either that is the intended "six-max / tournament
   build" and the gates should say so, or a Stack loss on any cash table
   should tilt it (`tilt_cooler` without the six_max source filter).
6. **The sweep's Act 2 board is stale.** It assumes mid fill at NL10K and
   NL1M, which under the new ladder is −$274M/hr, so its Act 2 totals are
   not usable as totals. The per-fire values are fine. Update
   `A.BOARDS.act2` in `tools/balance_sweep.js` to capped NL10K with
   Standard L5 before the next pass.

## Item by item (base variant; corrupt in the note)

Value is Δ$/hr on the reference board where measured; "est." is arithmetic.

| item | chips | class | value | verdict |
|---|---|---|---|---|
| Prize Vase | 12 | tournament ratchet | +1% wc all tables per win; ~1–3 wins a run → +2–6% | keep; corrupt 3% fine |
| Whiteboard | 17 | ratchet ×2 | doubles the above | keep |
| High Roller Pass | 19 | per-finish wc | uncapped ramp to the 0.95 cap | cap |
| Window | 20 | tilt↔heat router | needs tilts and a tournament; strong on that board | keep, fix the gate |
| Curved Monitor | 13 | KO → heater | +$2.5M/hr (16 heaters/hr × $221k); Circuit Pro adds targets | keep; corrupt AOE +$14.9M/hr |
| Tower Upgrade | 14 | KO → marked | −$284k/hr | repurpose (status) |
| Shredder | 18 | KO → refund seat | +$2.7M/hr | keep |
| First Aid Kit | 16 | KO → pays biggest seat | 8/hr × seat: $80k/hr at NL10K, $8M/hr at NL1M, $800M/hr at NL100M; ~2% of income everywhere but a bankroll engine on arrival | keep, watch arrival |
| Desk Speakers | 10 | +5% wc tournaments | +935 bb/hr at NL10K ko (sweep OP flag); corrupt −10% six-max is a real cost | keep |
| Box of Mice + 6 cursor items | 82 | QoL | throughput; Cleaning Robot's overdrive unvalued | keep; fold Glass Partition into Telephone |
| Electric Kettle | 11 | bust refund 30% | small (busts are arrival events) | keep; corrupt cap 100% |
| Rolled Vouchers | 9 | buy-ins −15% | nothing | repurpose |
| Chrome Toaster | 14 | tier bump both sides | negative | wins-only |
| Nightstand | 13 | window widen | negative | repurpose |
| Bookshelf | 22 | +1 level | one fifth of a window; corrupt +4 is 80% of a $65B window for 11 achips | keep base; corrupt +2 |
| Receipt Printer + Copy Machine | 38 | zoom cascade | = Firehose capstone | decide owner |
| Microwave Oven | 18 | tilt → heater elsewhere 50% | +$8.7M/hr with tilts; 0 without | keep (tilt build) |
| Waste Basket | 18 | tilt spent → heater on self | up to +$35M/hr on a tournament board; the strongest item in the book | keep but it's Anchor's capstone; consider 50% |
| Fire Extinguisher | 24 | refreshed tilt → stacked mark | −$400k/hr | repurpose (status) |
| Blackout Curtains | 24 | status on six-max → sharp | +$175k/hr | repurpose (status) |
| Framed Diploma | 18 | 1000 wins → zoom sharp | +$18k/hr | repurpose (status) |
| Cool Towel | 16 | Stack win cleanses tilts | +$34k/hr est. (few tilts) | weak; on a tilt board fine |
| Console Television | 26 | six-max steals statuses | conflicts with Anchor; steals heat | tilts-only, or retire |
| Laminated Blueprint | 19 | deck XP ×1.5 | one run → 1.5 decks; corrupt ×8 | corrupt ×2.5 |
| Cereal Shelf | 24 | loss recycle 10% | climb skip | cap |
| Tip Jar | 24 | chips ×1.5 | +50% of the act's currency; gate 500 unreachable in Act 2 | decide vs immutable awards; gate 200 |
| Second Monitor | 10 | +1 focus | zero | cut or fold |

## Recommended pass (numbers only unless marked)

1. Wins-only Toaster; Kettle corrupt 100%; Blueprint corrupt ×2.5; Cereal
   Shelf capped at $10k (corrupt $50k); High Roller Pass capped +10%;
   Bookshelf corrupt +2; Tip Jar gate 200, Bookshelf gate 150.
2. Flat 1% shove on every item, or write down the tiers and why.
3. Repurpose onto heat/tilt: Tower Upgrade, Fire Extinguisher, Framed
   Diploma, Blackout Curtains, Nightstand, Rolled Vouchers (six items;
   the heat/tilt family has room: a KO that tilts the busted seat's
   neighbour, a heater that lasts through a second hand on six-max only,
   a Stack loss that heats the table beside it).
4. Decide the cascade owner (Receipt Printer vs Firehose) and the taunt
   owner (Console Television vs Anchor).
5. Decide the tilt source question (5 above); it changes six items and a
   deck.
6. Update the sweep's Act 2 board and re-run before trusting totals.

## Decisions (2026-09-04, built)

- Chrome Toaster wins-only. Second Monitor +2 (corrupt +6). Bookshelf gate 150 upgrade levels. Tip Jar gate 200 chips. Window gate 40 tilts.
- Cereal Shelf: start with last run's biggest NL2 pot (corrupt: biggest pot at any stake). New state `run_biggest_pot(_t1)` / `last_run_biggest_pot(_t1)`, effect kind `start_biggest_pot`.
- Waste Basket: the corner slot is the basket; tilts aimed anywhere (not at a six-max) land on the corner table 35% (corrupt 70%); Anchor's taunt takes precedence. Router `basket_corner`.
- Window: while a tournament runs, tilts aimed at its stake arrive as heat 35%. Router `tournament_stake` (row/column bending retired).
- Dish Soap: a tilt lands beside its target 25% (router `tilt_deflect`); the tilt resist is gone.
- Cool Towel: after a tilt runs its course, 25% the table heats (`cool_towel_burnout`); the cleanse is gone.
- Fire Extinguisher: a second tilt on a tilted six-max heats the table beside it. Blackout Curtains: heat on a six-max spreads to a neighbour 50%.
- Framed Diploma: every 100 hands won, every table rolls heat / tilt / nothing at a third each (`roll_status` payload, `all` selector).
- Nightstand: a rebuy heats that table 50% (corrupt always); gate 150 rebuys; new trigger `on_rebuy`.
- Rolled Vouchers: the first table opened at a stake catches heat (corrupt: every table); new trigger `on_table_open` with `first_at_stake`.
- Tower Upgrade: knockouts make a nearby table's next win read a tier higher (the House Cat flag), no status.
- Unchanged by decision: High Roller Pass uncapped, Kettle and Blueprint corrupt values, Console Television takes every status, Receipt Printer keeps its cascade next to Firehose's, Tip Jar and Fight Night keep multiplying chips (the naked award is what's immutable), tilt sources, per-item shove values.
- No proc references marked, sharp or stacked mark any more; the three status definitions in data/statuses.lua are now unused and can go.
- The sweep's Act 2 board is now 9 capped NL10K tables with Standard L5.
