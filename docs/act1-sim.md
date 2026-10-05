# Act 1 simulation

> `lua sim/act1.lua --seeds=30` on 2026-10-04. Policy in `sim/act1_policy.lua`.

## Calibration

The designer's own Act 1 banks 4, then 7-9, then 15 a run, takes about an hour, and then
keeps paying 15 a run for as long as it takes. The steady 15 is the load-bearing number:
it is 1+2+3 on Heads-Up doubled by the Fight Night Poster plus 1+2 on Zoom, so reproducing
it means the bounty model, the stake ladder and the Poster are all behaving.

| shove | designer | sim (median) | |
|---|---|---|---|
| 1 | 4 | 4 | match |
| 2 | 8 | 15 | differs |
| 3 | 15 | 15 | match |
| 4 | 15 | 15 | match |
| 5 | 15 | 15 | match |
| total | ~60 min | 44 min | match |

- **Steady state (shoves 3+): matches.** The 15-a-run engine is reproduced.
- **Opening (shoves 1-2): differs.** The sim extends the stake ladder further before its first shoves than the designer does. `first_shove_asap` and the `lanes` order in `sim/act1_policy.lua` are the two knobs that move this.
- **Total time: matches.**

**Calibration partially passes**: the run engine is right, the opening policy is not the
designer's. Act 1 timings below are conditional on the policy as written.

## Result

- Act 1 cleared in a median **44 minutes** (range 20-81) over 30 of 30 seeds.
- Median **4 shoves**.

## Per shove, seed 1

| # | at | run | tables | {chip} | r1 | result | bought |
|---|---|---|---|---|---|---|---|
| 1 | 6 min | 5.4 min | 3 | 4 | 0.0% | lost | fight_night_poster, corkboard |
| 2 | 19 min | 12.3 min | 6 | 15 | 6.0% | lost | mirror, energy_drink, starter_gift_box, yellow_sticky_note, stack_of_books, house_cat |
| 3 | 34 min | 13.6 min | 6 | 15 | 24.1% | lost | bottle_of_wine, lava_lamp, stash_box, dogs_playing_poker |
| 4 | 42 min | 8.1 min | 6 | 15 | 34.8% | lost | desk, handheld, hybrid_console |
| 5 | 51 min | 7.8 min | 6 | 15 | 45.1% | **WON** | tally_book, ring_binder, headset |

