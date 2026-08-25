> **Legacy (moved 2026-08-25). Targets and tables are old.** Act targets here are 1.5h / 2.5h / 1h; the demo target is now Act 1 at 45-90 min (last replay ~46 min, ~40% winning shove). The item table uses old names and old per-item shove values (items are flat 1% now). Parts of the plan were applied piecemeal (tournament tiers, zoom stack chance, run-upgrade modifier math) and never closed out here.

# Game-Wide Rebalance Plan (2026-07-18)

Whole-game pacing + economy rebalance, not just one act. Numbers are grounded where
possible (hand rate, per-tier earning) and placeholder where they need a call.

---

## 0. The goal

**Act length target (rough — it's a variance game):** ~1.5h / 2.5h / 1h.
**Current, estimated:** ~30 min / ~1h / (Act 3 unmeasured).

So Act 1 needs ~3× longer and Act 2 ~2.5× longer, achieved through **steeper exponential
curves**, not fixed timers. The levers you named: first-tier power, amount of upgrades, cost
of upgrades, shove % given, deck curves, chip economy depth.

---

## 1. The pacing anchor (grounded)

- **Standard speed = six-max, single table = 4.4s/hand** (`data/game_types.lua`, `six_max
  pace_mult = 0.5`) → **~13.6 hands/min → ~400 hands per 30 min** single-table.
- **Money-won per 30 min at standard, per tier** (the exponential everything tunes against):

| Tier | ~$/winning hand | money-won / 30 min |
|---|---|---|
| T1 (NL2) | ~$0.26 | ~$50 |
| T3 (NL100) | ~$13 | ~$2.6k |
| T6 (NL100K) | ~$13k | ~$1.3M |
| T9 (NL100M) | ~$13M | ~$5B |

Money spans ~$50 → $5B across the ladder. **Money is the game's power exponent** — anything
priced/gated in dollars auto-scales with tier.

---

## 2. Act 1 — stretch it to ~1.5h through DEPTH, not difficulty

Currently ~30 min. Length comes from **more to acquire and a further-out first shove** — NOT
from nerfing win rates. **Do not touch T1–T3 win chances or fill speed.** The early game should
stay a satisfying win-and-climb; dropping T1 below a coinflip just spawns a quick-reset rage
loop and players quit. Act 1 gets longer because there's more worth building toward, not
because hands got harder.

- **More upgrades to work toward.** The main lever — §3's expanded upgrade/chip catalog gives
  a long shopping list, so Act 1 is "keep unlocking and buying the next interesting thing,"
  not "grind to one threshold and shove."
- **Exponential pricing (§3a).** Costs that keep pace with earning mean you're always saving
  toward the next upgrade through all of Act 1, instead of buying the whole shop in 5 min.
- **Shove base %.** R1 = `catalog × mult`. The first shove should be a ~1.5h payoff: catalog
  base accrues as you buy shove-rate items, so "ready to shove" is the reward for building up
  the catalog. Push that threshold out (slower base accrual / higher R1 bar) so R1 isn't a
  30-min formality — tune the base, never the player's win rate.

Net Act 1 knobs: upgrade depth, pricing curve, and shove-base accrual. Win rates stay put.

---

## 3. Upgrades & chips — depth + exponential cost + visible unlocks

Three problems you named:

**(a) Cost curve too shallow.** Everything's bought by T2 in ~5 min. Run-upgrade costs must be
dollar-magnitude exponential so buying continues through T2+. Current Sharper Reads tops at
$1.5M/level; with a few decks + T4 income that's trivial. Final levels should cost T5–T6
buy-in money ($10M+), and/or add levels. The curve should track the per-tier earning table in
§1 so an upgrade level is always "a session of your current tier," never pocket change.

**(b) Not enough upgrades; chips die at ~50.** Chips buy *catalog* items — there are ~15,
~110 chips total, then nothing to spend on. The rebalanced + expanded list is §3.5 below
(~48 items, ~3,000 chips, gated across A1→A3).

**(d) Shove% per chip — cut ~2.5×.** Today shove base is ~0.36 concentrated in the 10 demo
items at **~0.0138 shove/chip**. Cut to **~0.005 shove/chip** and spread small `shove_rate_add`
across the *whole* catalog, so building a clearable base (~0.4–0.5) is a run-long grind costing
~90+ chips instead of ~26. Supports Act 1's ~1.5h first shove and keeps chips buying shove deep
into Act 2. Per-item shove drops from 0.02–0.05 to ~0.005–0.018.

**(c) Visible unlock conditions (Vampire Survivors).** You should see *how* to unlock a thing
before knowing what it does. The **`UnlockRegistry`** already does exactly this for decks —
generic condition→predicate dispatch. Reuse it:
- Add optional `unlock = { kind, threshold, text }` to catalog entries (same shape decks use).
- `CatalogModal` renders locked items as silhouettes showing `unlock.text` ("Open one table
  for 10 min", "Bank a {chip} at every stake in one run"), reveals them when the predicate
  passes — the silhouette treatment `DeckSelectModal` already does, applied to the catalog.
- New unlock kinds in a `catalog_unlock_rules.lua` mirroring `deck_unlock_rules.lua`
  (table-open-duration, tables-open-count, per-stake bounty sweep, hands-at-tier, etc.).

---

## 3.5 The rebalanced + expanded catalog (the list)

~48 items, costs escalating 0 → 600 chips (total ~3,000) so chips stay a live sink through
A1→A3. Build tag: **[have]** existing effect kind · **[kind]** one small new effect kind ·
**[sys]** needs a shared micro-system (brainstorm Part 6). `sr` = `shove_rate_add` (rebalanced
per §3d).

**Band A — Act 1 early (0–8 chips): starter shove + basics**
| Item | Effect | Chip | Unlock | Build |
|---|---|---|---|---|
| Poker Poster | tutorial (lifts handicap) | 0 | — | [have] |
| Branded Hat | jackpot pays 1.2× · sr .015 | 2 | — | [have] |
| Whiteboard | +5% WC all · sr .012 | 3 | — | [have] |
| Energy Drink | +25% pace · sr .008 | 3 | — | [have] |
| Self-Help Book | small→med 25% · sr .015 | 3 | — | [have] |
| Stress Ball | large→med 25% · sr .018 | 3 | — | [have] |
| Lucky Coin | +50% start bankroll · sr .012 | 4 | — | [have] |
| Lava Lamp | med→large 15% · sr .015 | 4 | — | [have] |
| Worry Stone | jackpot-loss→large 15% · sr .018 | 4 | — | [have] |
| Mirror | +10% WC HU · sr .012 | 4 | — | [have] |
| Rubber Duck | run's 1st loss voided | 4 | bust once | [kind] once/run void |
| Dogs Playing Poker | 1st {chip} bounty +1 | 5 | bank a {chip} | [have] gated |
| Pocket Cash | +$5 start | 6 | — | [have] |
| Free Sit | start with 1 table | 8 | — | [have] |

**Band B — Act 1 late / T3–T4 (10–25 chips): utility + first rule-benders**
| Item | Effect | Chip | Unlock | Build |
|---|---|---|---|---|
| Calculator | +2% WC all · sr .006 | 10 | — | [have] |
| Pen | +1 {chip}/bounty | 10 | — | [have] |
| Headphones | losses 5% softer · sr .008 | 10 | — | [have] |
| Gaming Chair | focus penalty halved | 12 | hit focus cap | [have] |
| Plastic Trophy | MTT 4/8/20× | 12 | — | [have] |
| Second Monitor | +2 hard table cap | 15 | run 4 tables | [kind] table_cap_add |
| The Fridge | 1st {l:stack}/run voided | 15 | take a stack loss | [kind] once/run void |
| Diploma | 1st hand at each stake/run auto-wins | 18 | reach T3 | [kind] per-stake first-hand win |
| Discount Sits | buy-ins 15% cheaper · sr .006 | 20 | — | [have] |
| Wall Clock | every 60s, next hand forced win | 25 | 30 min played | [kind] timed forced win |

**Band C — Act 2 / deck era (30–120 chips): heaters, automation, synergy**
| Item | Effect | Chip | Unlock | Build |
|---|---|---|---|---|
| Cursor Pool | unlock swarm · sr .01 | 30 | — | [have] |
| Trained Cursor | +1 cursor | 20 | req Cursor Pool | [have] |
| Tireless Assistants | cursors also rebuy | 25 | req Cursor Pool | [have] |
| The Sink | busted tables refund 25% buy-in | 35 | — | [kind] bust refund |
| The Toaster | 5 wins = heater (+1 tier until loss) | 40 | win 5 straight | [sys] heater |
| Copy Machine | 1st denied {chip}/run banks anyway | 45 | get denied once | [have] hooks denied event |
| Medical Kit | each table's 1st bust/run self-revives | 50 | — | [kind] once/table revive |
| The Printer | top table's BB paid to bankroll every 10s | 55 | — | [sys] passive income |
| The Big TV | +2 focus cap, all −10% $/h · sr .01 | 65 | — | [have] |
| Zen Corner | hold over focus cap → % regenerates | 70 | — | [sys] focus regen |
| Engraved Plaque | MTT 5/10/20× | 80 | req Plastic Trophy | [have] |
| The Shower | quick reset keeps run upgrades | 90 | quick-reset 10× | [kind] reset keeps upgrades |
| Tori Gate | active deck +50% XP | 60 | decks unlocked | [kind] deck_xp_mult |
| The Mirror (shove) | R1 deals two boards, best stands · sr .02 | 100 | win first shove | [sys] shove reroll |
| Regulars' Door | rivals with records; beat 10× → {chip} | 120 | — | [sys] rivals |

**Band D — Act 2 late / Act 3 (100–600 chips): engine + endgame**
| Item | Effect | Chip | Unlock | Build |
|---|---|---|---|---|
| Console Shelf | 1st N hands/run +1 tier (N = consoles owned) | 100–300 (20-item set) | — | [sys] collect + heater |
| The Bonsai | grows per shove survived → +start bankroll | 140 | — | [sys] shove-count growth |
| The Dishwasher | shove returns 10% of run losses next run | 150 | first shove | [kind] loss recycle |
| Fire Extinguisher | 1st $0-with-tables/run auto-cashes all | 160 | — | [sys] auto-cashout (A3 kit) |
| Insurance Policy | failed shove refunds 10% committed | 180 | — | [kind] shove insurance |
| Blueprint | shove tooltip reveals R2/R3 | 200 | reach Act 3 | [have] info |
| Corkboard | 3 challenges/run, each +1 {chip} at shove | 220 | — | [have] reuse hint predicates |
| Private Game | once/run: double-buy-in rival table, 2× {chip} | 300 | Act 3 | [sys] special table |
| Ultra Stake | corrupt with anti-chips → unlock T10 | anti-chip | Act 3 | [have] existing |

**Chip-supply check:** bounties bank ~6/run at T1–T3, ~21 at T1–T6, ~45 at T1–T9. Against a
~3,000-chip catalog that's dozens of runs of sink — chips stay busy A1→A3, always saving toward
the next affordable thing rather than staring at a wall.

**Build split:** the ~24 **[have]** items ship immediately (just re-cost + trim shove). **[kind]**
items are one small effect-kind each (once/run voids, table cap, timed forced-win, deck-XP mult,
loss recycle, shove insurance). **[sys]** items (heaters, automation, rivals, special tables,
growth) are the brainstorm's shared micro-systems — a later content pass. It's a menu; cut,
rename, re-cost freely.

---

## 4. Decks (Act 2) — money-scaled curves, unique identities

**~30 min to MAX a deck** at standard; 5 decks maxed to unlock the master = ~2.5h = Act 2.

**XP: money is the exponent — scale the curve, not the currency.** The one-hand-max bug is that
`XP_CURVE_5 = {10,40,120,320,800}` is dollar-scale ~$1 while the game pays millions, so any
real pot buries it. Fix = dollar-magnitude exponential thresholds:

```
xp_curve (cumulative $ of the deck's tracked money-event), per deck:
  L1 = 1e3   L2 = 1e4   L3 = 1e5   L4 = 1e6   L5 = 1e7   (default anchor)
```

L5 = $10M needs T5–T6 earning to reach in ~30 min; T1 would take hundreds of hours ("past L2
is hours unless you climb"). Slide the L5 anchor per deck to its target tier band. Decks whose
theme isn't dollars (cursors, rebuys) use a **count** event tuned the same way.

**Unique unlock + unique money-event per deck** (current problem: all share "play/win a hand").
Starter table — the *filter* on each money-event themes the deck AND sets its tier pull:

| Deck | Effect | Levels on | Unlock | L5 anchor |
|---|---|---|---|---|
| **Standard** | +winnings | total $ won | default | $1M |
| **Hustler** | +pace | $ won (volume, any tier) | 2,500 hands | $500k |
| **Nit** | softer losses | total **$ lost** | lose $250k | $10M |
| **Maniac** | volatility | $ swung in **jackpot** pots | 50 jackpots | $20M |
| **Short Stack** | rebuy discount | **$ spent on rebuys** | 100 rebuys | count |
| **The Bank** | bankroll-scaled | **peak bankroll** | reach $1M | $100M |
| **Swarm** | +cursors | **cursor-dealt hands** | own cursors + 1,000 hands | count |
| **Specialist** | solo bonus | $ won **at 1 table** | 1,000 solo hands | $2M |
| **Multitasker** | focus immunity | $ won **at 4+ tables** | 100 hands @4+ | $5M |
| **Investor** | upgrade strength | **$ spent on upgrades** | 25 upgrade levels | count |
| **Tier Manipulator** | fill window | $ won **at T4+** | win $10M @T4+ | $50M |
| **The Master** | shove base | total $ won | 5 decks maxed | $100M |

New XP-rule kinds this implies (data-driven, `deck_xp_rules.lua`): dollar variants with filters
(`money_won{tier_min}`, `money_lost`, `jackpot_dollars`, `money_won{solo}`, `money_won{min_tables}`)
+ counts (`rebuys`, `cursor_hands`, `upgrade_levels_bought`, `peak_bankroll`). Several exist;
the rest are one registration each. Replaces the single shared `XP_CURVE_5` with per-deck curves.

---

## 5. Bug — Pot Control can't touch T6

`pot_control` maxes at 14 fill units, but T6's fill window starts at 15, so `fillRatio` returns
0 and T6's win/loss distribution stays fully naked no matter how much you buy. Either a silent
dead-zone bug or an undocumented "decks own T6 fill" choice. Fix: raise `max_level` to ≥20 to
reach T6's window, or document the intent. Sharper Reads (18) already reaches 60% of T6.

---

## 6. Suggested order (mechanical → content)

1. **Deck XP → dollar curves + unique events/unlocks** (§4). Biggest feel change, mechanical
   once identities are set.
2. **Pot Control fix** (§5).
3. **Run-upgrade cost curve steepen** (§3a).
4. **Act 1 pacing** — upgrade depth + pricing + shove-base threshold (§2). No win-rate nerfs.
5. **Catalog unlock-condition framework** (§3c) — `UnlockRegistry` reuse + CatalogModal silhouettes.
6. **Pull first upgrade tranche** (§3b).
7. Iterate content (more upgrades, deck polish) with direction from you.

Items 1–4 I can execute against the numbers here. 5–6 want a nod on approach. Content beyond
that is yours to direct.
