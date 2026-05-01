# Demo Balancing — Run 0 through First Gauntlet

This doc covers the demo's full play arc: from the player's first session (run 0, forced bust) through run 2's R1 win and cheat reveal that ends the demo. Math fundamentals (gauntlet formula, multiplier ladder, catalog targets) live in `gauntlet_math.md` and are not reiterated here.

## Run 0 — The forced bust

The game opens unwinnable. Without any catalog items, baseline win chance is **~20%** and losses lean Medium+. The player will bust within minutes of starting. There is no path to climb.

This is intentional. The forced bust is the game's first structural statement: **you cannot do this alone.**

### Diegetic framing
The player has been brought to the room. They sit down at the laptop. They start grinding online poker. The math is rigged against them — they're a fish, the table eats them. Bust.

The captor's voice (institutional, cheerful loyalty-program tone) appears for the first time: *"Welcome to the program! As a token of our appreciation for your participation, please enjoy your first gift on the house."*

A poker hand chart poster appears on the wall of the room. The player has been given the **Poker Poster** — their first catalog item, free. The game is now playable.

### What this establishes
1. **The captor is generous.** They gave you something for free. They want you to succeed.
2. **You needed them.** The game was unwinnable before. Now it isn't. The dependency is established immediately.
3. **The catalog is a loyalty program.** Items appear in your room as gifts/rewards. They are physical objects.
4. **No pity-PP.** The bankroll fix comes from the free item, not from a quiet handout. Diegetically cleaner.

### The Poker Poster (exception item)
The Poster is the only catalog item that names poker directly. It exists as the tutorial gift — it's what teaches the player to play. Every other item in the catalog is a mundane domestic object with an arbitrary mechanical hook.

- **PP cost:** Free
- **Shove rate base:** 0%
- **Description:** "A handy reference for the modern player."
- **Mechanical effect:** Removes the no-Poster handicap; restores normal poker math. With the Poster, T1 plays at its naked ~50% win chance with normal loss distribution. Without it, the handicap (a phantom catalog entry, `no_poster_handicap` in data/catalog.lua) multiplies win chance by 0.4 (T1 ~50% → ~20%) and skews loss_dist toward Medium+. The Poster has no direct effects of its own; its mechanism is purely the `removed_by` hook on the handicap entry.
- Cannot be sold or removed. Always first item in the catalog list, marked as "Gift."

The Poster doesn't add a bonus on top of normal play — it removes the handicap that exists by default. Diegetically: the Poster doesn't make you better at poker, it just teaches you how to play it. Run 0 is "you don't know what you're doing"; Run 1+ is "you know how to play, now you have to grind."

## Run 1 — First real run (T2 bust)

Player has the Poker Poster. They climb T1 confidently, reach T2, grind T2 — but T2 is harder, and without further upgrades, the modal outcome is bust before reaching T3.

**Expected outcome:** Player busts at T2 with ~12 PP banked from bounties.

If the player is paying attention and has read the shove-rate UI, they may shove at T2 and lose (low shove rate without catalog items). Either path — bust or failed shove — banks roughly the same PP.

Run 1's structural job is **teaching the player that the catalog matters**. They have PP. They look at the catalog. They buy items. Run 2 will be different.

## The demo catalog — 11 items, 29 PP total cost

Every item gives both a shove rate base contribution AND a felt run effect. Both lines appear on the card: the captor's flavor description and the mechanical effect underneath, plain and factual.

The catalog is **deliberately overstocked** for the player's PP. Player has 12 PP, items total 29 PP. The player must choose 4-5 items from the available 10 (Poster is free and granted automatically). Different builds = different runs.

### The list

| # | Item | PP | Shove % | Description | Mechanical effect |
|---|------|-----|---------|-------------|-------------------|
| 0 | Poker Poster | Free | 0% | "A handy reference for the modern player." | +25% win chance at all tables |
| 1 | Whiteboard | 3 | 4% | "Every room could use a whiteboard." | +5% win chance at all tables |
| 2 | Self-Help Book | 3 | 5% | "Bestseller. Life-changing, they say." | 25% chance for Tiny wins to become Small |
| 3 | Stress Ball | 3 | 6% | "For when things get tense." | 25% chance for Medium losses to become Small |
| 4 | Mirror | 2 | 4% | "A nice big one. You should see yourself sometimes." | +10% win chance at HU tables |
| 5 | Branded Hat | 1 | 5% | "Snug fit. Logo's barely noticeable." | Jackpots pay 1.2x |
| 6 | Lucky Coin | 3 | 4% | "Heavy. Older than it looks." | +50% starting bankroll |
| 7 | Lava Lamp | 3 | 5% | "Soothing to watch. Hypnotic, almost." | 15% chance for Small wins to become Medium |
| 8 | Energy Drink | 2 | 3% | "Tastes terrible. Works fine." | Hands resolve 25% faster |
| 9 | Worry Stone | 3 | 6% | "Worn smooth by someone." | 15% chance for Big losses to become Medium |
| 10 | Plastic Trophy | 3 | 4% | "Participation award. Handsome on a shelf." | MTT payouts: 4×/8×/20× |

**Totals:** 26 PP across 10 paid items, 46% total shove rate available.

### Lever coverage

The 11 items cover distinct levers so build choice is meaningful:

- **Universal win chance:** Whiteboard (Poster handles the baseline)
- **Stake-specific win chance:** Mirror (HU)
- **Win-side tier shifts:** Self-Help Book (Tiny→Small), Lava Lamp (Small→Medium)
- **Loss-side tier shifts:** Stress Ball (Medium→Small), Worry Stone (Big→Medium)
- **Jackpot amplifier:** Branded Hat
- **Starting bankroll:** Lucky Coin
- **Pace:** Energy Drink
- **Tournament:** Plastic Trophy

Multiple buildable archetypes:

- **Variance-crusher:** Stress Ball + Worry Stone + Whiteboard (9 PP, 16% shove). Steady climb, lower upside.
- **Aggressive upside:** Self-Help Book + Lava Lamp + Branded Hat + Lucky Coin (10 PP, 19% shove). Big swings, faster climb.
- **HU specialist:** Mirror + Stress Ball + Whiteboard + Branded Hat (9 PP, 19% shove). Lean into HU, stable elsewhere.
- **Max shove:** Stress Ball + Worry Stone + Lava Lamp + Mirror + Branded Hat (12 PP, 26% shove). Hits catalog target, weaker felt effects.
- **Speed run:** Energy Drink + Lucky Coin + Self-Help Book + Branded Hat (9 PP, 17% shove). Fast pace, fast bankroll, early shove.

### Card layout

Each item card shows two text layers. Captor flavor on top (warm, oblique, describes the object). Mechanical effect below (clean, technical, factual).

```
WHITEBOARD                              3 PP

"Every room could use a whiteboard."

+5% win chance at all tables
```

The captor's voice describes **the object**, never the poker effect. The mechanical line is matter-of-fact, not selly. The captor is informing, not marketing — which is creepier than hard-sell would be.

### Why the items are framed as mundane objects
The catalog is the captor's **room dressing**, not poker tools. Mundane domestic objects with arbitrary mechanical hooks (Nasubi-style). The connection between the object and its effect is left dangling on purpose. The texture: *why does the worry stone make big losses smaller? why does the lava lamp bump win sizes? who knows. it does.*

Poker Poster is the only exception — it's the tutorial gift that teaches you to play. Once that job is done, no further items name poker directly.

## Run 2 — The cheat reveal

Player has Poker Poster + 4-5 demo items of their choosing. Run 2 strength is meaningfully higher than run 1 across whatever levers they prioritized.

The player climbs T1 → T2 → T3 with much less friction. They reach T3 with a healthy bankroll.

At T3, the player decides to shove. **Shove rate at T3 with ~24% catalog × 3x multiplier = ~72%.** Comfortable but earned — the player feels they bought their way to this moment.

R1 wins. The player exhales. The captor's voice changes register for the first time — the cheat is revealed. R2 begins.

**Demo ends here.** The save state carries into the full game.

## Why busting in run 2 shouldn't really happen

The shove option is always available. A player paying any attention will:
1. Watch their bankroll grow
2. See their shove rate increase as bankroll climbs (multiplicative system)
3. Push the shove button when it looks favorable

The only way to bust is to ignore the shove and grind T3 indefinitely against −EV math. That's possible but it requires the player to actively reject the obvious play. The demo doesn't need to protect against this — players who do it learn the lesson and shove next time.

The structural promise: **run 2 reaches the cheat reveal in the modal case.** RNG outliers may force a run 2 bust → run 3 retry with the same catalog, but that's a recovery path, not the expected experience.

## Sequence summary

| Run | Reaches | Outcome | PP banked | Cumulative PP |
|-----|---------|---------|-----------|----------------|
| 0 | T1 | Forced bust (~20% baseline win rate, no items). **Captor gives Poker Poster.** | 0 | 0 |
| 1 | T2 | Bust at T2 (catalog has only Poster). | 12 | 12 |
| — | — | Player chooses 4-5 items from the 10-item demo catalog (12 PP budget). | — | 0 remaining |
| 2 | T3 | Climbs comfortably. Shoves at T3 (~72% R1). Wins. **Cheat reveals.** | 24 | 24 |

Demo ends after run 2's cheat reveal. Save state carries to full game.

## Open questions / VR work

1. **Tutorial moment for shove rate UI.** When does the player first see the shove rate readout in the top bar? Probably appears after the Poker Poster gift or first time bankroll crosses a tier threshold. Needs to be visible before run 2 so the player understands the lever they're pulling.

2. **First shove tutorial.** Run 1 should probably force or strongly suggest the player attempt a shove, even at low rate, so they understand the mechanic before run 2's stakes. Could be a captor prompt: *"You can push your luck at any time! Just hit that big SHOVE button when you're feeling lucky."*

3. **Catalog visibility.** Player should see the catalog in run 1 (with locked/preview items showing what 12 PP could buy) so the spend decision isn't a blind menu dive after busting.

4. **Tonal calibration of the Poster gift moment.** This is the captor's first direct address. The voice needs to land as cheerful-institutional, slightly off — generous in a way that makes you wonder why. Not menacing yet, just *attentive in a way you didn't consent to*.

5. **Catalog UI.** Sidebar list is fine for VR. Flyer/SkyMall pages presentation is post-VR demo polish.

6. **Item icons/art.** VR can ship with placeholder text/silhouettes; final icons are demo-tier polish.