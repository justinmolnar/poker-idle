# Gauntlet Math — Locked Structure

## Core formula

The gauntlet is 3 runouts. The dealer cheats once after R1 (revealed at the demo's climax) and again after R2. Each cheat reduces a different component of the player's power.

```
R1 power = catalog × mult              (no cheat)
R2 power = catalog × (mult / 2)        (cheat 1: dealer halves your tribute)
R3 power = (catalog / 2) × (mult / 2)  (cheat 2: dealer also disqualifies your evidence)
```

R1 = full power. R2 = half power. R3 = quarter power.

**Diegetic framing:**
- Cheat 1 attacks your bankroll-as-tribute. Your money is suddenly worth less to the dealer.
- Cheat 2 also attacks your catalog-as-evidence. The stuff you brought no longer counts the same.
- Two kinds of betrayal, escalating. Clearing the gauntlet means breaking both locks.

## Multiplier ladder

`T[x] mult = x`. Clean for the player — UI shows "T4 — 4x bankroll multiplier" and the player gets it instantly.

| Tier | Mult |
|------|------|
| T1   | 1x   |
| T2   | 2x   |
| T3   | 3x   |
| T4   | 4x   |
| T5   | 5x   |
| T6   | 6x   |

## Catalog growth targets

| Tier reached     | Catalog target | PP needed (cumulative) |
|------------------|----------------|------------------------|
| T3 (demo end)    | 25%            | 12 PP                  |
| T4               | 35%            | ~40 PP                 |
| T5               | 38%            | ~55 PP                 |
| T6               | 57%            | ~150 PP                |

**The T5→T6 jump (19% catalog growth) is gated economically, not scripted.** The final base catalog items are priced high enough that the player physically cannot afford them until run 5 banks its 84 PP payout. Player at T5 with full T5 budget tops out around 38% catalog. T6 odds become available only after run 5's bankroll funds the expensive items.

This is the economic wall that makes T6 the structural win condition. The player is free to grind T1-T3 indefinitely if they want — the gate is "have you banked the late-tier PP yet," not "have we scripted you forward."

## Per-runout rates by tier

| Tier              | Catalog | Mult | R1   | R2   | R3   | Full gauntlet clear |
|-------------------|---------|------|------|------|------|---------------------|
| T3 demo (R1 only) | 25%     | 3x   | 75%  | —    | —    | **75% R1**          |
| T4                | 35%     | 4x   | 100% | 70%  | 35%  | **25%**             |
| T5                | 38%     | 5x   | 100% | 95%  | 47%  | **45%**             |
| T6                | 57%     | 6x   | 100% | 100% | 85%  | **85%**             |

**R3 is always the wall.** The drama lives there at every tier. R1 and R2 progressively become formalities at higher tiers. The player tenses up specifically when R3 starts.

**T5 → T6 nearly doubles clear odds (45% → 85%).** That's the structural payoff for reaching the final tier. The climb is tangibly perceivable.

## Canonical player journey

| Run | Tier reached | Outcome                                                            | PP banked | Cumulative PP |
|-----|--------------|--------------------------------------------------------------------|-----------|---------------|
| 0   | sub-T1       | Forced bust (no-poster handicap), free Poker Poster gift           | 0         | 0             |
| 1   | T2           | Bust R1                                                            | 12        | 12            |
| 2   | T3           | Win R1 at 75%, **cheat reveals**, demo ends                        | 24        | 36            |
| 3   | T4           | Gauntlet at 25%. R3 wall. Bust.                                    | 40        | 76            |
| 4   | T5           | Gauntlet at 45%. R3 wall again, closer. Bust.                      | 60        | 136           |
| 5   | T6           | Buys expensive late items. Gauntlet at 85%. **Clears.** Game end. | 84        | 220           |

**Expected losses:** 2 (one at T4, one at T5). Lucky players may clear at T5; unlucky players may lose T6 and need a run 6.

The losses are organic to the math, not scripted. Self-balancing: lucky players advance faster but weaker; unlucky players advance slower but stronger.

## Catalog content phases

### Phase 1 — Demo (T3 reachable)
- ~12 PP buys 25% catalog
- Cheap items, ~2-3% shove rate each, priced 2-4 PP
- Includes free Poker Poster (tutorial gift from captor — lifts the no-poster handicap that makes Run 0 unwinnable)
- ~5-6 demo items

### Phase 2 — Mid game (T4-T5 reachable)
- ~43 PP buys 13% more catalog
- Mid items, ~3-4% shove rate each, priced 8-15 PP
- Mix begins: some shove rate, some qualitative effects
- ~4-5 mid items

### Phase 3 — Late game (T6 unlock)
- ~95 PP buys 19% more catalog + qualitative items
- **Expensive base items, ~5-7% shove rate each, priced 30-50 PP** — these are the economic gate
- Player needs to spend ~75 PP on these to unlock T6 odds
- Remaining ~20 PP on qualitative late items
- ~3-4 expensive base items + qualitative items mixed in

### Qualitative items throughout
Priced on perceived power, not shove rate contribution. Examples:
- "Tiny losses don't deduct from bankroll"
- "Once-per-run guaranteed Win activator"
- "First hand of every prestige run = guaranteed Jackpot"
- "See win chance before clicking DEAL"
- "See opponents' approximate skill labels"

These cluster in late-game spend because by run 5, percentage growth has diminishing returns — qualitative items are where remaining PP goes.

## Efficiency curve

| Phase    | PP    | Catalog growth | Per PP |
|----------|-------|----------------|--------|
| Demo     | 12    | 25%            | 2.08%  |
| Run 3    | 30    | 10%            | 0.33%  |
| Run 4    | 15    | 3%             | 0.20%  |
| Run 5    | 75    | 19%            | 0.25%  |

Demo to late efficiency drop: ~10x. Acceptable because late PP is buying:
1. Expensive base items that *do* matter (they unlock T6 odds)
2. Qualitative items priced on perceived power, not shove rate

The catalog has **two phases** of progression and they feel different. Players don't experience late items as "diminishing returns on the same thing" — they experience them as a different kind of upgrade.

## Why this structure works

**The cheat structure is diegetically clean.** Two different kinds of betrayal, each tied to a different component of the player's power. The player understands what's being taken from them at each moment.

**R3 is always the wall.** Consistent dramatic locus across the whole game. The player learns to expect it, fear it, and eventually overcome it.

**T6 is the structural win condition.** Not "another harder tier" — the tier where the climb pays off. Gated economically so the player can't accidentally clear at T5; gated naturally so the player can't be forced into T6 unprepared.

**The 45% → 85% jump from T5 to T6** is the structural payload. The player can feel themselves getting strong enough. The upgrade is legible and earned.

**Catalog stays meaningful across the whole game.** Early items feel chunky (2%+ per PP). Late items feel transformative (qualitative). Mid items bridge the two with steady shove rate growth.

## Constants summary

```
mult(tier)           = tier
catalog_target(T3)   = 0.25
catalog_target(T4)   = 0.35
catalog_target(T5)   = 0.38
catalog_target(T6)   = 0.57

r1_rate = catalog × mult                      (clamped to 1.0)
r2_rate = catalog × (mult / 2)                (clamped to 1.0)
r3_rate = (catalog / 2) × (mult / 2)          (clamped to 1.0)

gauntlet_clear = r1_rate × r2_rate × r3_rate
```

## Open questions / next session

1. **Catalog content brainstorm.** Need ~15-20 items designed across the three phases. Mix of shove rate contributors and qualitative effects. Fits captor's-loyalty-program-of-mundane-objects framing.

2. **Item rename pass.** Five existing items break the catalog-of-objects rule:
   - HU Specialist → Mirror
   - Pot Odds Master → Whiteboard
   - Damage Control → Stress Ball
   - Cheap Coaching → Self-Help Book
   - Endorsement Deal → Branded Hat

3. **Free starter item (Poker Poster).** Tutorial gift from the captor, granted automatically on Run 0's forced bust. Mechanism: the Poster's presence in `owned_items` removes the phantom `no_poster_handicap` catalog entry (data/catalog.lua), which otherwise multiplies T1's win chance by 0.4 and skews loss_dist toward Medium+. With Poster, the math returns to normal poker; without it, you don't know how to play.

4. **Live shove rate readout** in top bar with breakdown tooltip — without visible feedback, the multiplicative system is invisible to the player.