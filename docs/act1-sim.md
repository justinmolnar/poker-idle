# Act 1 simulation

> `lua sim/act1.lua --seeds=30` on 2026-09-28. Policy in `sim/act1_policy.lua`.

## Calibration

The designer's own Act 1 banks 4, then 7-9, then 15 a run, takes about an hour, and then
keeps paying 15 a run for as long as it takes. The steady 15 is the load-bearing number:
it is 1+2+3 on Heads-Up doubled by the Fight Night Poster plus 1+2 on Zoom, so reproducing
it means the bounty model, the stake ladder and the Poster are all behaving.

| shove | designer | sim (median) | |
|---|---|---|---|
| 1 | 4 | 6 | match |
| 2 | 8 | 15 | differs |
| 3 | 15 | 15 | match |
| 4 | 15 | 15 | match |
| 5 | 15 | 15 | match |
| total | ~60 min | 60 min | match |

- **Steady state (shoves 3+): matches.** The 15-a-run engine is reproduced.
- **Opening (shoves 1-2): differs.** The sim extends the stake ladder further before its first shoves than the designer does. `first_shove_asap` and the `lanes` order in `sim/act1_policy.lua` are the two knobs that move this.
- **Total time: matches.**

**Calibration partially passes**: the run engine is right, the opening policy is not the
designer's. Act 1 timings below are conditional on the policy as written.

## Result

- Act 1 cleared in a median **60 minutes** (range 23-129) over 30 of 30 seeds.
- Median **5 shoves**.

## Per shove, seed 1

| # | at | run | tables | {chip} | r1 | result | bought |
|---|---|---|---|---|---|---|---|
| 1 | 8 min | 7.5 min | 4 | 6 | 0.0% | lost | fight_night_poster, corkboard |
| 2 | 20 min | 11.0 min | 6 | 15 | 5.6% | lost | mirror, energy_drink, starter_gift_box, yellow_sticky_note |
| 3 | 36 min | 15.0 min | 6 | 15 | 18.4% | lost | stack_of_books, house_cat, bottle_of_wine |
| 4 | 48 min | 11.2 min | 6 | 15 | 27.5% | **WON** | lava_lamp, stash_box |

