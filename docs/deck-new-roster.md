# New Deck Roster Design

This document details the updated 11-deck roster, defining exactly one scaling mechanic for Levels 1–4, one Capstone mechanic for Level 5, and the XP leveling rule for each deck.

---

## 1. Standard
* **XP Rule**: Win hands.
* **Levels 1–4**: +50% cash winnings per level.
* **Capstone**: Wins never roll Small (every win is Medium+).

## 2. Hustler
* **XP Rule**: Play hands.
* **Levels 1–4**: +40% hand pace per level.
* **Capstone**: Double the hand speed of everything (2x speed).

## 3. Nit
* **XP Rule**: Dollars lost.
* **Levels 1–4**: Shift loss distribution towards Small losses per level.
* **Capstone**: Losses never roll Jackpot (prevents table wipes).

## 4. Maniac
* **XP Rule**: Large/Jackpot wins.
* **Levels 1–4**: Shift win and loss distributions heavily toward Large/Jackpot tiers.
* **Capstone**: Any win or loss has a 50% chance to be upgraded to the next higher pot tier, and a 50% chance to pay out double.

## 5. Short Stack
* **XP Rule**: Table rebuys.
* **Levels 1–4**: Rebuys are 15% cheaper per level (60% cheaper at L4).
* **Capstone**: 50% chance for rebuys to be completely free ($0).

## 6. The Bank
* **XP Rule**: Dollars won.
* **Levels 1–4**: +15% cash winnings per table tier.
* **Capstone**: Every hand outcome is multiplied by your bankroll multiplier.

## 7. MTT Pro
* **XP Rule**: MTT wins.
* **Levels 1–4**: +10% auto-win chance on MTT hands per level.
* **Capstone**: Double payout (cash and chips) on MTT 1st place finishes.

## 8. Specialist (Single Table Deck)
* **XP Rule**: Win hands, but only if active tables == 1.
* **Levels 1–4**: +100% cash winnings and +10% flat Win Chance if exactly 1 table is open. Shuts off completely if tables > 1.
* **Capstone**: Single table deals 2x faster (2x pace).

## 9. Multitasker (Focus / Overwhelm Deck)
* **XP Rule**: Win hands while overwhelmed (active tables > focus capacity), scaling with the excess: `XP = active_tables - focus_capacity`.
* **Levels 1–4**: +3 Focus Capacity per level.
* **Capstone**: Removes Focus penalty entirely (Focus Penalty multiplier is locked at 1.0).

## 10. Investor (Upgrades Deck)
* **XP Rule**: Purchase run upgrades in the shop.
* **Levels 1–4**: All run upgrades purchased are 15% stronger across the board.
* **Capstone**: Adds a final "Super Level" to every run upgrade in the shop.

## 11. Tier Manipulator (Win% / Tier Deck)
* **XP Rule**: Win hands at stakes higher than T1 (T2+).
* **Levels 1–4**: Adds new, purchasable upgrade levels to the shop for each tier, allowing you to scale past the old limits (expanding the windows earlier and later, with T1 expanding only later). Each added level gives its own additional percentage.
* **Capstone**: Every level of upgrade you purchase adds +1 level of that upgrade to every other tier automatically.
