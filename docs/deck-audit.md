# Deck audit — 2026-09-04

> Superseded the same day by the roster refactor: `docs/deck-refactor-2026-09.md` records what changed and how to retcon it; `data/decks.lua` is live. The measurements below are of the OLD roster.

Every number below is the game's own outcome math through `tools/sim_bridge.lua`
(9 capped six-max tables unless stated; Specialist measured on 1 table).
"×" is EV per hand with the deck at that level divided by EV without it.
Base EV: NL100 capped +114 bb, NL10K capped +5.8 bb, NL100M capped −0.9 bb.

## Findings that matter most

1. **Specialist is broken.** ×16 earnings and +0.40 win chance on one table: +3,550 bb/hand at NL100 (31× a capped table, 3.5× a whole 9-table board), 200× at NL10K. One table with this deck out-earns everything else in the game.
2. **The Bank's capstone multiplies by the BANK multiplier** (1× to 8× by bankroll tier) on every outcome. At NL10K with a $1B roll it is 75×. Combined with its per-tier levels (×3.4 at NL10K, ×4.6 at NL100M) it is the strongest late deck by an order of magnitude, and it stacks with Standard.
3. **Maniac hurts you until L5.** Its loss-side shift lands 54% of losses on Stack at NL10K; at L4 it is 0.89× at NL100 and makes NL100M more negative. Only the capstone (tier bump + double) pulls it positive. A deck that is a debuff for four levels is not a deck.
4. **Tier Manipulator is a debuff at every level.** Widening a window lowers the fill ratio of the levels you already own: NL10K capped goes from +5.8 bb to −6.8 bb at L4. The extra top levels it "adds" are the next stake's levels anyway.
5. **Hustler is the second-strongest income deck** (×7.7 hands per hour with the capstone), stronger than Standard on a board, and it multiplies everything: XP, chips, deck levelling. As the second deck the player gets it is the wrong size.
6. **Redundancy.** Swarm (+4 cursors) is dwarfed by Box of Mice (+8) and the Cursor upgrade (+12). Multitasker's +12 focus is the Focus upgrade twice over and its capstone (immunity) is redundant with its own L4. Investor duplicates Calculator + Bookshelf. Tier Manipulator duplicates Nightstand. Short Stack duplicates Rebuy Sticky Note + Wacom. Three decks level on the same signal (hands played / hands won).
7. **Rebuy discount can exceed 100%.** Short Stack 60% + Rebuy Sticky Note 75% + Wacom 20% = 155%, and `rebuyCostFor` returns `buy_in × (1 − discount)` with no clamp: a rebuy would pay the player. Clamp needed regardless of the deck outcome.
8. **XP units are inconsistent.** Count decks earn the table's buy-in per event; money decks earn dollars. Short Stack earning "10 × the buy-in per rebuy" is an unreadable unit when "dollars spent on rebuys" is the same thing said plainly. Standard maxes too late (800 NL10K wins).
9. **Standard's capstone** ("wins never roll Small") is a tier floor on a deck whose whole identity is a cash multiplier. It is also worth almost nothing at capped stakes (Small is 10–15% of wins) and a lot at naked ones, backwards from how the deck is used.

## Measured effect per deck

| deck | L4 mechanic | NL100 | NL10K | NL100M | capstone adds |
|---|---|---|---|---|---|
| Standard | wins ×1.5⁴ = ×5.06 | 5.3× | 19× | −0.9 → +127 bb | tier floor: ~nothing at cap |
| Hustler | pace ×1.4⁴ = ×3.84 | 3.8× hands | 3.8× | 3.8× | ×2 → 7.7× hands |
| Nit | loss shift, +0.60 small | 1.04× | 3.4× | −0.9 → +15 bb | no Stack losses: +25 bb at NL100M |
| Maniac | win & loss shift to large/stack | 0.89× | 1.6× | −0.9 → −5.9 bb | bump/double: 1.7× / 4.2× / −7.5 bb |
| The Bank | ×(1 + 0.6·tier) on wins | 2.9× | 11.8× | −0.9 → +113 bb | × bankroll mult (1–8): 18× / 75× / +714 bb |
| Specialist (1 table) | wins ×16, +0.40 wc | 31× | 202× | −0.9 → +1,677 bb | solo pace ×2 |
| Investor | fill gain ×1.6 | 2.05× | 8.4× | −0.9 → +70 bb | +1 level per upgrade |
| Tier Manipulator | window widened ×4 | 0.61× | −1.2× | worse | cascade: still 0.72× / −0.26× |
| Short Stack | rebuys −60% | n/a | n/a | n/a | 50% free |
| Swarm | +4 cursors | n/a | n/a | n/a | cursor speed ×3, instant |
| Multitasker | +12 focus cap | n/a | n/a | n/a | immune (redundant with L4) |
| Master | +1% shove base per deck level, capped at items | n/a | n/a | n/a | uncapped, ×2 |

Reading the stake columns: a wins-only multiplier is worth more the closer a stake is to breakeven, which is why Standard is ×5 at NL100 and ×19 at NL10K. That is the mechanism by which decks flip the wall, and it is why arrival pricing had to assume them.

## Current unlock and XP (as shipped today)

| deck | unlock | XP rule (units) | curve top |
|---|---|---|---|
| Standard | start | hands won × buy-in | 8M (800 NL10K wins) |
| Hustler | 2k hands | hands played × buy-in | 14M |
| Swarm | 6k hands | hands played × buy-in | 16M |
| Short Stack | 100 rebuys | 10 × buy-in per rebuy | 2.6M |
| Specialist | 2k Stacks | 2 × buy-in per solo win | 1.5B |
| Multitasker | 2k hands over cap | buy-in × tables over cap per win | 550M |
| Tier Manipulator | $1B won | hands won above NL2 × buy-in | 3B |
| Nit | $3B lost | $ lost | 18B |
| Maniac | 20k Stacks | $ won in Stacks | 2.4T |
| The Bank | $100B won | $ won | 2T |
| Investor | 150 upgrade levels | $ spent on upgrades | 30B |
| Master | 5 maxed | hands won × buy-in | 280B |

Problems: three decks on hands played/won; "× buy-in" is a unit nobody can read on a card; Standard, Tier Manipulator and Master are the same signal three times.

## Per-deck breakdown and recommendation

Tier labels: **unlock** = the stake you are a real player at when it opens; **max** = the stake whose board maxes it in about a session. Act 2 = 6 shoves, one deck each, Master last.

### 1. Standard — the cash multiplier
- **Now**: wins ×1.5/level (×5.06), capstone tier floor. XP hands won × buy-in, maxes at 800 NL10K wins.
- **Effect**: the deck that turns a −EV arrival into a print. ×19 at NL10K. It is the right power for the starter if it is the ONLY multiplier early.
- **Problems**: capstone off-identity and near-worthless at cap; maxes too late.
- **Recommend**: keep ×1.5/level. Capstone in-identity: **Stacks pay ×2** (`stack_mult`), the loudest cash moment. XP: **dollars won** (plain). Curve top ≈ 300 NL10K wins of winnings ($ won in a 15-minute NL10K session). Unlock start of Act 2; max at NL10K.

### 2. Hustler — pace
- **Now**: ×1.4/level (×3.84), capstone ×2 (×7.7). XP hands played × buy-in.
- **Effect**: multiplies everything per hour: income, XP, chips. On a 9-table board it is bigger than Standard and it compounds with every other deck.
- **Recommend**: **+25%/level additive → ×2 at L4** (the applicator is multiplicative today: either add a `hand_pace_add` kind or use 1.189/level, which is "+19%" on the card; additive is the honest read). Capstone: **×1.5**, not ×2 (×3 total), or move Hustler to a late unlock if ×2 stays. XP: **hands played** (count, any stake), long curve: it should be the slow deck, maxing around NL1M. Unlock NL10K.

### 3. Nit — loss shape
- **Now**: +0.15 small / −0.15 spread per level, capstone no Stack losses. XP $ lost.
- **Effect**: nothing at NL100 (losses already small), ×3.4 at NL10K, and at NL100M the capstone alone is +25 bb (Stack losses are 29% of losses there). Identity is clean and scales exactly where losses matter.
- **Recommend**: keep. XP $ lost is right. Unlock NL1M (first place losses hurt), max NL100M.

### 4. Maniac — variance
- **Now**: shifts BOTH win and loss dists to large/stack. Debuff until capstone.
- **Recommend**: shift the **win** dist only (large/stack), and let the capstone be the gamble: **tier bump 50% on wins, payout double 50% on wins**. Then it is ×1.5–4× at cap with a Stack-heavy shape and no self-harm. XP $ won in Stacks is right. Unlock NL1M, max NL100M. If the self-harm is the point, make the loss shift the capstone's cost, not the L1 tax.

### 5. Short Stack — rebuys
- **Now**: −15%/level, capstone 50% free. XP 10 × buy-in per rebuy.
- **Effect**: only matters while tables bust, i.e. at arrival on each new stake, which is exactly when money is tight. Good identity, small deck.
- **Problems**: stacks additively with Rebuy Sticky Note (−75% corrupt) and Wacom (−20%) past 100%. Unit unreadable.
- **Recommend**: XP **dollars spent on rebuys**. Discount **multiplicative** with items and clamped at 0 (bug fix in `rebuyCostFor` regardless). Capstone: **busting refunds half the stack** instead of "50% free" (reads as an event, not a coin flip). Unlock NL10K (rebuys start there), max NL1M.

### 6. The Bank — scale
- **Now**: +0.15 × tier index per level on wins, capstone × bankroll multiplier.
- **Effect**: 11.8× at NL10K before the capstone; 75× after with a $1B roll. Multiplies with Standard.
- **Recommend**: keep the per-tier levels (identity: grows with stakes) but halve them (+0.075/level → ×2.2 at NL10K, ×2.8 at NL100M). Capstone: **× bankroll multiplier on wins only, capped ×3**, or replace with "banking a {chip} pays its stake's buy-in". XP: **$ won** is right but move Standard off it (Standard → $ won; Bank → **highest bankroll reached**, a Bank thing). Unlock NL1M, max NL100M. This is a late deck; it must not be the second one.

### 7. Swarm — cursors
- **Now**: +1 cursor/level, capstone speed ×3 + instant. XP hands played × buy-in.
- **Effect**: +4 cursors next to Box of Mice's 8 and the Cursor upgrade's 12. The capstone is Gaming Keyboard's instant click plus most of Cursor Speed's ×6.
- **Recommend**: give it what cursors can't buy: **cursors deal one extra hand per click per level** (a cursor click resolves 2/3/4/5 hands), capstone **cursors also rebuy**. Or retire it into the cursor catalog line. XP: **hands dealt by cursors** (the new `total_cursor_deals` counter), which nothing else uses. Unlock with Box of Mice, max NL1M.

### 8. Specialist — one table
- **Now**: ×2 earnings and +0.10 wc per level on a single table, capstone solo pace ×2.
- **Effect**: ×16 and +0.40 wc = 31× one table at NL100, 202× at NL10K. Broken.
- **Recommend**: **+0.05 wc/level and ×1.25 earnings/level** (≈ ×2.4 and +0.20 wc at L4: a solo table worth ~4–6 board tables at NL10K), capstone solo pace ×2. That makes "one table" a real alternative to nine, not a replacement for the game. XP **$ won on a single table**. Unlock NL10K, max NL1M.

### 9. Multitasker — overload
- **Now**: +3 focus/level, capstone immune. XP overwhelmed wins × buy-in.
- **Effect**: the Focus upgrade already sells +10 for money; +12 free plus immunity means focus stops being a system.
- **Recommend**: keep the identity but make it scale: **focus penalty −25% per level** (0.15 → 0.0375 per extra table), capstone **tables over the cap deal 25% faster**. XP: hands won over the cap × excess (count, no buy-in). Unlock NL10K (when 9 tables are real), max NL1M.

### 10. Investor — upgrades
- **Now**: fill gain +15%/level (×1.6), capstone +1 level. XP $ spent on upgrades.
- **Effect**: 8.4× at NL10K because ×1.6 on the gain pushes past the capped numbers. Duplicates Calculator (+15%/+150%) and Bookshelf (+1/+4 levels).
- **Recommend**: keep as the upgrade deck but cut to **+10%/level**, capstone **upgrades cost 25% less** (the Ring Binder's kind), which nothing else in the roster does. XP $ spent on upgrades is right. Unlock NL10K (upgrades get expensive), max NL100M.

### 11. Tier Manipulator — windows
- **Now**: widen ×4, capstone cascade. A debuff at every level.
- **Recommend**: **retire** (Nightstand owns widening) or rebuild as the **tier deck**: +5% Stack share per level, capstone next tier up on any Stack. XP $ won at the top stake you have filled.

### 12. The Master — the key
- **Now**: +1% shove base per total deck level, capped at items owned; capstone uncapped ×2. XP hands won × buy-in.
- **Effect**: correct as the R2 key; numbers depend on the R2 design. 30 levels = +30%, capstone +60%.
- **Recommend**: keep. XP: **total XP earned on other decks** (it levels by mastering the others), or hands won at NL100M.

## Proposed roster order (unlock → max)

| shove | deck opens | levels on | maxes at |
|---|---|---|---|
| 1 | Standard | NL100 climb → NL10K | NL10K |
| 2 | Short Stack, Swarm, Investor (pick one to level) | NL10K | NL1M |
| 3 | Hustler, Specialist, Multitasker | NL10K–NL1M | NL1M |
| 4 | Nit, Maniac | NL1M | NL100M |
| 5 | The Bank | NL1M | NL100M |
| 6 | Master | NL100M | NL100M |

Unlock counters per deck, each its own (Standard start; Short Stack $ spent on rebuys; Swarm cursor deals; Investor upgrade levels bought; Hustler hands played; Specialist $ won on one table; Multitasker hands over cap; Nit $ lost; Maniac Stack $; Bank highest bankroll; Master 5 maxed). Thresholds from the sweep once the effects are settled.

## Room for identity and proc decks

The roster has no deck about heat, tilt, game types, chips or procs, which is where the catalog's identity lives now. Candidates, one line each:

- **Hot Hand** (heat): XP heaters caught. Levels: a heater's second hand pays ×1.25 more per level. Capstone: a heated win lights a neighbour. (Never lengthen the punch: a longer punch decides every hand.)
- **Steam** (tilt): XP tilts taken. Levels: +15% tilt resist per level (Dish Soap's kind). Capstone: the hand after a tilt wins.
- **Grinder** (zoom): XP zoom hands. Levels: zoom pace +15%/level. Capstone: zoom Stacks pay double.
- **Closer** (heads-up): XP HU wins. Levels: +3% wc on HU per level. Capstone: HU Stack losses read one tier smaller.
- **Table Captain** (six-max): XP six-max Stacks. Levels: +4% Stack share on six-max per level. Capstone: a six-max Stack heats the table.
- **Circuit Pro** (tournaments, the old MTT Pro): XP tournament finishes. Levels: finish odds fill +10%/level. Capstone: first place pays double.
- **Bounty Hunter** (chips): XP chips banked. Levels: +5% Stack share per level at stakes whose bounty is unbanked. Capstone: a banked bounty heats the table. (Chip awards themselves stay immutable.)

## Bugs found on the way

- `GrindController:rebuyCostFor` does not clamp the discount; stacked discounts above 100% make a rebuy pay out.
- Tier Manipulator's widening lowers fill for owned levels (measured, not theoretical).
- Maniac's loss-side shift makes the deck negative through L4 at every stake.
- Two decks share a sprite (`05-patterns`, `05-nature`, `05-acorns` each used twice).
