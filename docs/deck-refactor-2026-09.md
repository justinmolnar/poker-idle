# Deck roster refactor — 2026-09-04 change record

The reference for what changed, so any of it can be retconned. Baseline is
commit `46529a8` (the roster as audited in `docs/deck-audit.md`). Live data is
`data/decks.lua`.

**Retcon in one line**: `git show 46529a8:data/decks.lua > data/decks.lua` and
`git show 46529a8:models/deck_xp_rules.lua > models/deck_xp_rules.lua`, then
the engine additions listed at the bottom are simply unused (they are
data-driven kinds; nothing references them without a deck).

## Old roster → verdict

| old deck | L1–4 (old) | capstone (old) | XP (old) | unlock (old) | verdict | replaced by |
|---|---|---|---|---|---|---|
| Standard | wins ×1.5/level | wins never roll Small | $ won (buy-in units) | starter | **kept, retuned**: capstone → Stacks pay ×2; XP plain $ won, curve top 6M | — |
| Hustler | pace ×1.4/level | pace ×2 | hands played × buy-in | 2k hands | **retired** (×7.7 global pace, second deck) | Firehose owns pace, zoom only |
| Nit | loss shift +0.15 small / −0.05 / −0.07 / −0.03 | losses never roll Stack | $ lost | $3B lost | **kept, retuned**: +0.18 / −0.06 ×3; capstone 50% Stack→Large; opens $10M lost | — |
| Maniac | win AND loss shift to large/stack | 50% bump + 50% double, both sides | Stack $ | 20k Stacks | **kept, fixed**: win-side shift only; capstone wins-only bump/double; opens 5k Stacks | — |
| Short Stack | rebuys −15%/level | 50% free rebuy | 10 × buy-in per rebuy | 100 rebuys | **retired** (Rebuy Sticky Note + Wacom own rebuys) | Bounty Hunter |
| The Bank | +0.15·tier per level on wins | × BANK multiplier, both sides, uncapped | $ won | $100B won | **kept, halved**: +0.075·tier; capstone wins only, cap ×3; XP highest bankroll; opens $10B won | — |
| Swarm | +1 cursor/level | cursor speed ×3, instant | hands played × buy-in | 6k hands | **retired** (Box of Mice / Cursor upgrade) | Closer |
| Specialist | ×2 earnings and +0.10 wc on one table | solo pace ×2 | 2 × buy-in per solo win | 2k Stacks | **refactored**: pure board (every table one type) ×1.2/level; capstone pure pace ×1.25; XP $ won while pure; opens 3k hands at 4+ tables | — |
| Multitasker | +3 focus/level | focus immune | overwhelmed wins | 2k over cap | **retired** (the Focus upgrade's identity) | Hot Hand |
| Investor | fill gain +15%/level | +1 upgrade level | $ spent on upgrades | 150 levels | **retired** (Calculator + Bookshelf) | Circuit Pro |
| Tier Manipulator | window widen +1/level (a debuff) | cascade | wins above NL2 × buy-in | $1B won | **retired** | Anchor |
| The Master | +1% shove base per deck level | uncapped ×2 | hands won × buy-in | 5 maxed | **kept**: XP $ won at NL100M+ | — |

## New decks

| deck | XP | opens | L1–4 | capstone |
|---|---|---|---|---|
| Firehose | $ won on zoom | 3,000 zoom hands | zoom pace +15%/level (`hand_pace_mult` gtype) | a zoom Stack resolves every other zoom table (`firehose_cascade`) |
| Closer | $ won on HU | 3,000 HU hands | +3% wc on HU/level | HU Stack losses 50% → Large |
| Bounty Hunter | chips banked | 30 chips | +5% Stack share at unbanked lanes/level (`unbanked_stack_shift`) | +1 chip per bounty (`stack_chip_add`) |
| Hot Hand | heaters caught | 50 heaters | heater's forced hand ×1.25/level (`heater_win_mult`) | 25% a burnt-out heater jumps to a neighbour (`hot_hand_spread`) |
| Anchor | tilts absorbed | 25 tilts | tilts aimed beside a six-max land on it (`anchor_taunt`); tilted hands lose 20% less/level (`tilted_loss_mult`) | a spent tilt on a six-max heats a neighbour (`anchor_convert`) |
| Circuit Pro | knockouts | 3 tournaments won | each KO's proc lands on +1 table/level (`ko_targets_add`) | first place heats every table (`circuit_pro_final`) |

## Save migration

`GameState.deck_roster_migrated`, one-shot, decided from the raw save (fresh
games start it true). On an old save: retired ids are pruned from
`unlocked_decks` / `deck_levels` / `deck_xp`; a retired `active_deck_id` is
repaired to the first unlocked deck (the starter); surviving XP snaps to the
current level's threshold on the new curve. Levels are kept. Nothing in
`data/id_migrations.lua` (these are retirements, not renames; the old
`cursor → swarm` line now resolves to a retired id and is pruned the same way).
Covered by `sim/verify_save_migration.lua`.

## Engine additions (all data-driven; harmless if unreferenced)

- Effect kinds: `hand_pace_mult` gtype scope, `win_tier_bump_chance`,
  `win_payout_double_chance`, `earnings_scale_by_bankroll { wins_only, cap }`,
  `pure_board_bonus`, `pure_board_pace`, `tilted_loss_mult`, `heater_win_mult`,
  `ko_targets_add`, `unbanked_stack_shift` (`data/effects.lua`,
  `models/poker_effects.lua`, mirrors in `models/outcome_math.lua`).
- Transients from `GrindController:invalidateEffects`: `board_pure_gtype`,
  `unbanked`; rollup on every bounty bank.
- Procs: selector `pick_n_field`; router kind `taunt_tilt`; bus event
  `on_heat_spent`; deck procs in `data/procs.lua`; KO procs carry
  `pick_n_field = "ko_targets_add"`.
- XP: rules `bankroll_peak` (absolute), `knockouts`, `heaters_caught`,
  `tilts_absorbed`, `chips_banked`; `money_won` filters `gtype`, `pure_only`;
  hand event fields `bankroll`, `board_pure`; `Decks.gainXp` honours
  `xp_rule.absolute`.
- Unlocks: counter kinds `total_tilts`, `total_heaters`, `total_ko_wins`,
  `total_chips_banked`, `total_hands_at_4plus`; kind `hands_at_gtype`.
- State: `total_tilts_absorbed`.
- `Constants.CARD_BACK_SPRITE` is now Standard's back (`04-patterns`).
- Pricing reference boards (`data/balance.lua`): mid Standard L5, high
  Standard + Nit L5.

## UI fields (2026-09-04 deck UI pass)

`bonus_text` → `bonus = { text, per_level }` ({n} substituted by
`Decks.bonusTextAt` / `bonusTextPerLevel`); `xp_action_text` → `levels_on`
(rendered "Levels on <x>"); `unlock.text` lost its " to unlock". Nothing in
`sim/` or `tools/` reads these. The roster, top-bar cell and tooltip draw the
art through `views/DeckArt`; locked decks show the unlock count from
`UnlockRegistry:progress` under the catalog's COMING SOON sticker.

The roster is the deck FLYER (`views/DeckFlyer`, 2026-09-04): a folded sheet
the dealer throws beside the catalog (`services/Throw` carries the arc both
use), unfolding into the tiles and column; CONTINUE warns once when the
deck in play is maxed. `views/DeckSelectModal` is gone; the story triggers
are `deck_flyer_landed` / `deck_flyer_open`.
