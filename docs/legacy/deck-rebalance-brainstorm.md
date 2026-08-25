> **Legacy (moved 2026-08-25).** Says "not built yet"; the 5-level / capstone structure it proposes IS built (`data/decks.lua`). Numbers here were sketches and are not the live ones. Superseded by `docs/deck-new-roster.md` (which itself lacks the master deck).

# Deck Rebalance Brainstorm (2026-07-17)

Decks are the act-2 power layer and they currently don't deliver: at max
level the strongest is ~1.6×, most are 1.2-1.3×. Target feel:

- **3-5× power** per deck at max. The player should FEEL powerful.
- **T4-T6 nearly impossible without decks, increasingly trivial with them.**
- Not built yet — this replaces the current data/decks.lua roster in
  spirit; numbers are sketches.

## Structure (decided)

- **5 levels per deck** (down from 10).
- **Levels 1-4: big numbers** — ~+50%-class steps, each level-up visibly
  moves $/h the moment it lands.
- **Level 5: ONE rule** — a sentence that changes how the game works, not
  a number. The capstone is the destination.
- **Max level must come SLOWER than today** despite fewer levels — the
  current XP curve is already too fast. Levels are the act-2 long arc.

## Why T4-T6 gating falls out naturally

Per-stake `fill_window`s are T4: 9→14, T5: 12→17, T6: 15→20 fill units.
Run upgrades can only supply the bottom of that, so T4+ plays near-naked
odds — that IS the wall. Decks that grant fill units (and effects that
scale by tier) convert deck levels directly into "the top of the ladder
stops being impossible."

## The roster (4+1 sketches)

| Deck | L1-4 (per level) | L5 capstone rule | XP (on-theme events) |
|---|---|---|---|
| **Standard** | +50% winnings | Wins never roll Small — every win is Medium+ | hands won |
| **Hustler** | +40% pace | Filler hands resolve instantly; only Large+ pots play the theater | hands played |
| **High Roller** | +3 fill units at T4+ | T4+ buy-ins cost half | hands won at T4+ |
| **Card Counter** | "the count": every 20th hand is a guaranteed win; −3 per level (L4: every 8th) | The counted win is always Large+ | showdown wins |
| **The Nit** | loss magnitude −20% (L4: ×0.4) | {l:stack} cannot happen | hands lost |
| **Maniac** | win AND loss magnitude +50% (L4: 3× volatility) | No pot rolls below Large | {stack} outcomes, either color |
| **Short Stack** | buy-ins −15% (L4: ~half; tied-up halves, table count explodes) | Rebuys are free | tables opened |
| **Collector** | bounty payout +50% (L4: 3× {chip}) | The once-per-run bounty rule becomes TWICE per run | {chip} banked |
| **The Bank** | +15% earnings per bankroll tier above T1 (grows into the tiers being pushed) | Bankroll accrues 1%/min interest | hands played, weighted by bankroll tier |
| **Shark** | after any {l:large}+: all tables +25% win chance for 3 hands (L4: near-certain revenge) | Revenge-window pots double | wins inside revenge windows |
| **MTT Pro** | +10% tournament auto-win (L4: 40%) | 1st place pays double $ and double {chip} | tournament hands won |

Notable identities:
- **High Roller** is the tier-breaker centerpiece — L4 = +12 fill units:
  T4/T5 capped, T6 close. `win_chance_fill` already exists as an effect kind.
- **Card Counter** is deterministic power: a visible ticker counting to the
  sure thing on every table.
- **Short Stack** changes zero odds and might be the biggest spike anyway
  (affordability = table count).
- **The Nit / Maniac** are opposites; the Nit is also the deck act 3 forces
  you to bench (you can't farm {l:stack} anti-chips wearing it) — decks as
  loadout choices.
- **Collector L5** is the single most valuable sentence in the game.

## XP pacing (the real gate)

- **Count EVENTS, not dollars.** Dollar-based XP explodes at T4+ (one
  NL1K pot outweighs a thousand NL2 hands) and would let high-tier play
  trivialize the decks that trivialize high tiers. Every rule above is
  event-countable, and events are tier-proof. The existing money-based XP
  rules die in the rebalance.
- **Log-spaced eras:** ~50 / 500 / 5,000 / 50,000 on-theme events. L1 =
  first session with the deck, L2 = a run, L3 = several runs, L4 = an
  act, L5 = a commitment.
- Only the ACTIVE deck earns XP (existing rule, keep) — with slow curves,
  "who am I leveling this run" becomes a real identity choice per run.
- Four level-ups + one capstone per deck total: each deserves real
  fanfare (deck art/border upgrade per level; full ceremony at L5).
  Scarcity makes the +50% steps feel enormous.

## Stacking pressure valve (keep in back pocket)

All unlocked decks stack passively; 11 maxed decks multiply into a
monster. That may be CORRECT for the arc — the restored r2/r3 formula
needs the 200-400% overshoot route reachable, and act 3's "make enough
money to lose enough money" wants a monstrous engine. If it overshoots:
**capstone rules apply only while that deck is ACTIVE; numbers stack from
all unlocked.** Bounds the passive pile and makes the active slot about
which RULE you're wearing — one more reason the swap-at-shove moment
matters.

## Open questions

- Unlock conditions need re-flavoring for the new era (current ones are
  early-game numbers like "$200 won"; decks now unlock at the first R1
  win, so several thresholds arrive pre-met). Tier-flavored unlocks fit
  the 3-5× era better: "win $10K at T4+", "bank a {chip} at every stake
  in one run".
- Evolutions (L5 art change / effect replacement) and act-3 corrupted
  deck variants (the Nit that can't WIN big) — parked, pairs with the
  anti-chip "corrupt upgrades" idea in docs/room-catalog-brainstorm.md
  era notes.
- Exact numbers everywhere are sketches; tune in data/decks.lua when
  built.
