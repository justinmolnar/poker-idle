> **Legacy (moved 2026-08-25). Premise half-addressed.** "Why this has stalled" argues for a sim; `sim/run.lua` exists now and the Act 1 pacing replay comes from it. The lever inventory is still a fair map of where numbers live. Dates (demo 2026-10-09) are whatever they are; nothing in the code tracks them.

# Balance & Pacing Plan

Written 2026-08-09. Demo target 2026-10-09. Full game target 2026-11-09
(stretch: 2026-10-09).


## Why this has stalled

Not because balancing is hard. Because the iteration loop is too expensive
to enter.

Every number in the game is a hand-typed literal in a different file. To try
a different pacing you edit ~47 values, then play a 20-minute run to see one
data point. That loop is too slow to voluntarily start, so it doesn't get
started.

Everything below is in service of one thing: make a full balance iteration
cost minutes instead of a day. Once it does, the actual tuning is fast.


## The one rule

**You never pick a number. You pick a duration, and derive the number.**

Nobody can intuit whether a gate is 2K or 20K hands. Everyone can intuit
whether Act 1 should take 40 minutes or 4 hours. Time is the only thing the
player experiences, so time is the only thing authored by taste. Everything
else is arithmetic downstream of it.

Corollary: a hand-typed number in a data file is a bug. If you can't point at
the duration it came from, it's placeholder.


## Locked design inputs

From the 2026-08 design pass. These are the taste calls. Change them freely,
but change them HERE, not downstream.

```
TOTAL_GAME_HOURS        = 7
ACT1_HOURS              = 1.5      (1-2)
ACT2_HOURS              = 4
ACT3_HOURS              = 1

RUN_MINUTES             = 20
ACT1_RUNS_TO_CLEAR      = 3        (3-5 depending on luck/optimization)
ACT1_COMPLETION_AT_WIN  = 0.70     fraction of Act 1 catalog owned
ACT1_SHOVE_TARGET       = 0.80     win chance at the expected winning shove
T3_MULT                 = 3
```

Derived, not authored:

```
CATALOG_TARGET_ACT1 = ACT1_SHOVE_TARGET / T3_MULT      = 0.267
ACT1_ITEM_COUNT     = 25                                (chosen for haul size)
ITEMS_AT_WIN        = ACT1_ITEM_COUNT × 0.70            = 18
K_SHOVE_PER_ITEM    = 0.267 / 18                        = 0.015
ACT1_CHIP_SPEND     = sum(cost curve, 18 items)         ≈ 111
CHIPS_PER_RUN       = 111 / 3                           ≈ 37
```

Rules that hold game-wide:

- **Every catalog item contributes k.** No phase exceptions. The dealer's
  cheat is what removes base%, not the shop quietly ceasing to sell it. The
  number must keep climbing while being nullified, or the player reads a
  frozen value as a broken save.
- Catalog base feeds R1 all game (`raw1 = (catalog + deck) × mult`). It is
  never dead. Full catalog ~47 × 0.015 = 0.705, so R1 clamps to 1.0 by T6
  and the tooltip reads 400%+. That is the intended end state.
- Costs come from a formula, never by hand: `cost(n) = base × r^n`.
- Gates are authored as "appears N minutes into run M", then converted to a
  counter via hand rate × table count. Never guessed.


## Scope

**Demo (Oct 9) = Act 1.** `FEATURES.DEMO_CUT` already zeroes r2/r3 for the
cliffhanger, so the demo is exactly the piece derived above: 25 items, one
currency loop, one shove target. This is the SMALLEST balance surface in the
game and it is the deadline that matters. You are closer than it feels.

**Full game (Nov 9) = Act 2's 4 hours of deck progression, plus Act 3.**
Act 2 is the largest surface and it comes second, on purpose: the method gets
proven on Act 1 where a mistake costs one 20-minute run.


## Phase 0 — Measure income. One sitting. DO THIS FIRST.

The plan has exactly one unknown that blocks everything: **what does a run
actually pay right now?** The spec needs ~37 chips per 20-minute run. If a
run currently pays 4, or 400, every downstream number moves.

Work:
- Play one 20-minute Act 1 run. Notepad beside you.
- Record: chips banked, bounties hit, hands played, tables run, minutes
  elapsed, run-upgrade purchases made.

**MEASURED RESULTS (from analytics log `analytics_1784478043_72896.json`, 2026-08-10):**
- **Chips Banked:** 12 chips
- **Bounties Hit / Pot Tiers:** 301 Jackpot, 215 Small, 183 Large, 85 Medium, 8 MTT payouts
- **Hands Played:** 792 hands (~43.5 hands/min)
- **Tables Run / Game Types:** Primary Heads-Up (657 hands, 83%), MTT (91 hands), Zoom (30 hands), 6-Max (14 hands)
- **Minutes Elapsed:** 18.22 minutes
- **Run Upgrades Purchased:** 20 upgrades (9 Sharper Reads, 9 Pot Control, 2 Focus)

**Conclusion:** Current yield is ~12-13 chips per 20-min run, which is ~1/3 of the spec's ~37 chip target.

Done when: you have those six numbers written down. **[COMPLETE - 2026-08-10]**



## Phase 1 — Make numbers derivable (Aug 10-16) 

Goal: one file holds the taste inputs; everything else is computed.

Work:
- `data/balance.lua`: the locked inputs above as named constants, plus the
  derivation chain producing k, the cost curve, chips-per-run, gate values.
- `data/catalog.lua` reads costs and shove from it instead of literals.
  Item identity (id, name, effect, department) stays hand-authored. Only the
  NUMBERS become derived.
- Cost curve as `base × r^n` over the cheap-to-dear ordering already in
  `catalog_pages.lua`.

Done when: changing `RUN_MINUTES` from 20 to 30 in one place visibly moves
every cost and gate in the game.

Timebox: 1 week. This is the highest-leverage work in the plan.


## Phase 2 — Minimal sim (Aug 17-23)

Goal: answer "how long does Act 1 take" in 200ms instead of 20 minutes.

`models/` is engine-agnostic by architecture rule, so plain `lua` can require
it with no LÖVE dependency.

Work:
- `sim/run.lua`: simulate N runs with a greedy buy-cheapest-first policy.
- Output ONE table: catalog% and shove% at each shove, and elapsed
  minutes to clear Act 1.

Do NOT build: a framework, a UI, graphs, a policy comparison engine, Act 2
support. Those are the rabbit hole that eats the deadline.

Done when: `lua sim/run.lua` prints the shove-curve table and a time-to-clear.

Timebox: 5 days HARD. If it isn't working by Aug 23, ship the plan without it
and tune by hand. The sim is an accelerator, not a dependency.


## Phase 3 — Act 1 tuning loop (Aug 24 - Sep 13)

Goal: Act 1 takes 1-2 hours and shove 3 is the expected win.

The loop, ~4 cycles over 3 weeks:
1. Run the sim. Does the shove curve match the target below?
2. Adjust INPUTS (never downstream numbers) until it does.
3. Play one real run. Compare actual elapsed time to intended.
4. The only question asked: **did it take as long as I said it would?**

Target curve:

| | Items | Catalog | Shove @ T3 |
|---|---|---|---|
| Shove 1 | 10 | 0.150 | 45% |
| Shove 2 | 15 | 0.225 | 68% |
| Shove 3 | 18-19 | 0.270 | 81% |
| Shove 4 | 22 | 0.330 | 99% |

Shove 1 loses. Shove 2 is a coin flip some players take and win. Shove 3 is
the expected win. Losing shove 3 makes shove 4 near-certain, so unlucky
players arrive stronger. That is the self-correcting difficulty.

Also in this phase, and scheduled rather than ad hoc:
- **Add the chip-income items.** Pen-likes are the only compounding decision
  in the catalog and the "feel more powerful" lever. Additive ones (+1 per
  bounty) cheap and early; multiplicative ones (×1.5) gated hard and late,
  because production items are what break economies.
- **Line consolidation**, only if it doesn't threaten the date. Collapsing
  magnitude items into 2-3 tier lines (Gaming Chair I/II/III) means tuning
  ~12 curves instead of ~30 points. Rule: if the effect text has a number,
  it's a line candidate; if it unlocks or toggles, it stays unique.

Done when: three consecutive real runs land inside the intended duration and
the shove curve holds.


## Phase 4 — Demo lock and ship (Sep 14 - Oct 9)

- Sep 14: content freeze. No new items, no new mechanics.
- Sep 14-27: polish, hint/tutorial pass, external playtest with 2-3 people.
  Watch for the ONE thing you can't self-test: does the shove moment land.
- Sep 28 - Oct 9: buffer. Assume it gets used.

Done when: demo ships.


## Phase 5 — Act 2 derivation (starts Sep 14, main work Oct 10 - Nov 1)

Act 2 is 4 of the 7 hours and is mostly deck upgrading. Start the DESK work
during Phase 4's playtest gaps, since deriving is not playtesting and doesn't
compete for the same time.

Same chain, different content:
- Inputs: 4 hours, N runs, deck XP per run, decks to max.
- Derive: XP curve, deck unlock gates, master-deck cost.
- The Act 2 wall is legible by design: R1 fine, R2/R3 at zero, answer is the
  master deck. Verify the player can SEE that, since it's the spine of the act.

Deck curves are more formula-shaped than the catalog was, so this should go
faster per hour of content than Act 1 did.


## Phase 6 — Act 3 (Nov 1-9)

1 hour, anti-chip corruption layer, already designed in
`docs/act3-endgame-plan.md`. Smallest surface, most constrained, last.


## Standing rules

**Do not do these before Oct 9:**
- New features or systems
- Refactors that aren't Phase 1
- New items beyond the chip-income ones in Phase 3
- Sim work past the Aug 23 timebox
- Re-reading old balance docs. `docs/math.md` describes a game that no
  longer exists (T6 endgame, "demo", PP, no decks). Delete it or mark it
  dead so it stops surfacing.

**When stuck, the question is always:** what duration is this number supposed
to produce? If there isn't one, the number isn't ready to be picked yet.


## Exit criteria

| Phase | Done when | By |
|---|---|---|
| 0 | Six numbers written down from one real run | Aug 10 |
| 1 | Changing one input moves every derived number | Aug 16 |
| 2 | `lua sim/run.lua` prints the shove curve | Aug 23 |
| 3 | Three runs land inside intended duration | Sep 13 |
| 4 | Demo ships | Oct 9 |
| 5 | Act 2 hits 4 hours in sim | Nov 1 |
| 6 | Act 3 playable end to end | Nov 9 |
