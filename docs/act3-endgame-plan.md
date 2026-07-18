# Act 3 / Endgame — Design & Implementation Plan

Status: design converged with the user (2026-07-17), NOT built. This doc is the
build spec for the full late-game arc: the 9+1 stake ladder, the master deck / R2
base gate, anti-chips, upgrade corruption, the Ultra stake, and the underflow ending.

Balance is a separate later pass — every number here is a placeholder. Do not
implement until the user says build; this is the reference.

---

## 1. The arc at a glance

Three acts, gated by gauntlet wins. Target playtime ~5-6h: **Act 1 ~1.5h, Act 2 ~2.5h,
Act 3 ~1h.**

| Act | Entered by | The player's job | Unlocks |
|---|---|---|---|
| **1** | new game | Grind low stakes, build catalog base, win the first shove (R1). | decks, mid stakes |
| **2** | R1 win (`shove_r1_won`) | Level decks. Max 5 → the **master deck** appears → keep leveling to rebuild the zeroed base and beat R2. | high stakes, anti-chips, Act 3 |
| **3** | R2 win (`shove_r2_won`) | Dealer zeroes your bankroll mult forever. Farm **anti-chips** by losing stacks at high stakes, buy **corruption** + the **Ultra stake**, drive bankroll negative until it underflows to a 999× mult, then win the final shove (R3). | the win |

The gauntlet already gates runouts by act — `models/Gauntlet.lua:71-93` only rolls R2 if
`shove_r1_won`, R3 if `shove_r2_won`. That machinery stays; we change what makes each
runout *winnable*.

---

## 2. Progression spine (milestone → unlock)

| Milestone | State flag | Gates |
|---|---|---|
| Start | — | Low stakes T1-3 |
| R1 win | `shove_r1_won` | Decks system, Mid stakes T4-6 |
| 5 decks maxed | (computed) | Master deck unlock |
| R2 win | `shove_r2_won` | High stakes T7-9, anti-chip earning, corruption shop, Ultra offer |
| Buy Ultra | `ultra_unlocked` | Ultra stake T10 (endgame) |
| Bankroll underflow | (computed) | 999× mult → final shove |
| R3 win | `cleared` | Game won |

`shove_r1_won` / `shove_r2_won` / `cleared` already exist and serialize (set in
`states/ShoveState.lua`, read by `Gauntlet:begin`). The new flags are `ultra_unlocked`
and the anti-chip / corruption state below.

---

## 3. Architecture guardrails (apply to everything here)

These are the project's non-negotiable rules — every task below must honor them:

- **DI / no globals:** no `Game.` outside `main.lua`. Controllers reach state via `self.game.state`.
- **`data/` is logic-free:** stakes, decks, catalog, effects docs are pure tables. New tuning (band gates, anti-chip awards, corruption effects, master-deck base) lives in data, not code.
- **No `if kind ==` / `if id ==` dispatch chains.** Everything routes through the existing registries (`EffectsRegistry`, `XpRuleRegistry`, `UnlockRegistry`) or small **data-driven lookup maps**. New behaviors are **generic capability effect kinds**, never named after a deck/stake/item (e.g. `shove_base_per_deck_level`, not `master_deck_base`).
- **No literal `setColor`:** Theme tokens only. Anti-chip UI needs new Theme tokens + an IconText marker.
- **Engine-agnostic `models/`:** the model layer must stay liftable into a future idle game. Anti-chips, corruption, and the base rework are all generic mechanisms parameterized by data.
- **Save back-compat is required** (public itch build, real saves): every new persisted field backfills to a default in `applySaved`; no serialized key renames without migration. Follow the `deck_overhaul_migrated` one-time-migration pattern.
- **`{chip}` icon, never the word "chips."** Anti-chips get their **own** IconText marker (proposed `{achip}`) and are never written as a word in player copy.
- **Concise copy, no em-dashes** in player-facing strings.
- **`Table_legacy.lua` is the prototype hand model** — mirror per-hand/showdown changes into both. Note: everything in this plan is full-build-only (decks/Act-3 are off in the prototype), so anti-chip award (resolution loop, not Table) and corruption (computeEffects) need **no** legacy mirror. Only touch `Table_legacy` if a change lands in the per-hand outcome path both builds share.
- **`RollingValue`** for any animated on-screen number (anti-chip counter, negative bankroll).

---

## 4. Feature: the 9+1 stake ladder

**Today:** `data/stakes.lua` has 6 stakes (s001-s006 = T1-T6), each with
`win_chance/_capped`, `win_dist/_capped`, `loss_dist/_capped`, `fill_window`
(windows widen per tier: `0→5, 3→8, 6→11, 9→14, 12→17, 15→20`). `FEATURES.HIGH_TIER_STAKES`
currently gates the T4-6 add-table buttons.

**Target bands:**
- **Low = T1-3** (existing s001-s003) — always available.
- **Mid = T4-6** (existing s004-s006) — gated behind `shove_r1_won`.
- **High = T7-9** (NEW s007-s009) — gated behind `shove_r2_won`. Fill windows continue widening (`18→23, 21→26, 24→29`) so they stay near-naked even with a strong deck stack; naked WC ~0.001, loss_dist heavily jackpot. **This is where stack losses (and anti-chips) happen.**
- **Ultra = T10** (NEW s010) — gated behind `ultra_unlocked` (bought with anti-chips). Buy-in several magnitudes above T9; `win_chance ≈ 0`, unreachable fill window, `loss_dist` ~all jackpot. Structurally unwinnable — a loss sink, not a grind tier.

**Data change (`data/stakes.lua`):** add s007-s010; add a `band = "low"|"mid"|"high"|"ultra"`
field to every stake (drives gating without an `if id ==` chain).

**Gating (data-driven, no chain):** a small map in data —
`BAND_GATE = { low = nil, mid = "shove_r1_won", high = "shove_r2_won", ultra = "ultra_unlocked" }`.
A `GrindController:stakeAvailable(stake)` helper reads `state[BAND_GATE[stake.band]]`.
The add-table / stake-picker UI filters through it. Retire the `HIGH_TIER_STAKES` flag's
current role (or repoint it) since availability is now milestone-driven.

**Reuse:** the fill/outcome pipeline (`outcome_math.buildOutcome`) already supports
arbitrary stakes and tier-scoped effects; High/Ultra are just more rows. Tier indices are
1-based positions in the stakes list (`Lookups.indexById`), so `tier_min`/`tier_max`
effect bounds keep working.

---

## 5. Feature: the master deck + R2 base gate

**The problem it solves:** by Act 2 the player can already overshoot R1
(`raw_r1 = catalog × mult` well past 100%). We want R2 to be *unwinnable* until the player
has invested heavily in decks — decks become the literal key to the second cheat.

### 5a. Shove formula rework (`models/shove_rate.lua`)

Today (`buildRates`, lines 86-92):
```
r1 = clamp(catalog × mult)
r2 = clamp(catalog × (mult/2))         -- cheat 1: bankroll halved
r3 = clamp((catalog/2) × (mult/2))     -- cheat 2: catalog also halved
```
`catalog` = `ctx.shove_rate` (from `shove_rate_add` catalog effects) — this is the "base %."

**New:** introduce a second base term `deck = ctx.shove_base` (from the master deck), and
have the dealer's R2 cheat **nullify the catalog base** while the master-deck base survives
(diegetically: the dealer disqualifies your catalog-as-evidence, but not your skill):
```
r1 = clamp((catalog + deck) × mult)
r2 = clamp(deck × (mult/2))            -- catalog nullified; only deck base survives
r3 = clamp((deck/2) × (mult/2))        -- deck base also halved
```
So with no master deck (`deck = 0`): `r2 = r3 = 0` → R2 flatly unwinnable ("zero the base").
As the master deck grows, `deck` climbs until `deck × mult/2 ≥ 1` (overshoot beats cheat 1)
and `deck/2 × mult/2 ≥ 1` (beats cheat 2). Overshoot stays the route; the master deck fuels it.

Keep the `DEMO_CUT` branch (prototype still hard-zeros r2/r3). Prototype is unaffected
(`deck = 0`, decks off).

### 5b. `ctx.shove_base` from the master deck

**The master deck is a normal 12th deck** in `data/decks.lua` (own 5 levels, `xp_curve`,
`xp_rule`). Its levels count toward the total like any deck ("deck levels add").

- **Unlock:** new `UnlockRegistry` kind `decks_maxed` (threshold 5) — counts decks at
  `max_level`. Registered in `models/deck_unlock_rules.lua`; the master deck's `unlock`
  block is `{ kind = "decks_maxed", threshold = 5 }`.
- **Effect:** base scales with **total deck levels across the whole collection**, so it needs
  that sum. Compute `total_deck_levels` once in `GameState:computeEffects` (it has `self`
  = state) and seed it into `ctx` as a transient (same pattern as `active_tables_count`).
  Then a generic capability kind:
  - `shove_base_per_deck_level` (master deck L1-4): `ctx.shove_base = math.max(ctx.shove_base or 0, (e.value or 0) * (ctx.total_deck_levels or 0))`. **`max`, not `+`,** so `applyN` re-application is idempotent (avoids multiplying by the master deck's own level).
  - `shove_base_double` (master deck L5 capstone): sets `ctx.shove_base_double = true`; `shove_rate.compute` applies `×2` when set.
- `ShoveRate.compute` reads `ctx.shove_base` (and the double flag) and passes `deck` into
  `buildRates`.

Placeholder: `value ≈ 0.01` per level (≈ +1% base per deck level). 11 base decks × 5 = 55
levels + the master deck's own 5 → up to ~+0.60 base, ×2 at capstone. Tune so a committed
deck-maxer overshoots R2/R3 and a partial investment doesn't.

**Open decision (flagged):** the exact cheat model in 5a — does R2 fully nullify catalog
(recommended, matches "zero the base"), or just halve it harder? Confirm before wiring.

---

## 6. Feature: anti-chips currency

A second, more powerful currency, **earned only by losing stacks at High stakes.**

- **State:** `state.anti_chips` (meta, persists; never reset by prestige). Add to
  `serializeMeta`; backfill `= 0` in `applySaved`.
- **Earned:** in the `GrindController` resolution loop, when `r.delta < 0` and
  `r.tier == "jackpot"` (a stack loss) and the table's stake `band == "high"` and Act 3 is
  active. Award from stake data (`stake.anti_chip_award`) — pure data, no formula in code.
  This lives at the same site as the existing chip-bounty logic (`GrindController:update`),
  so it reuses the resolution pass; **no Table/Table_legacy change.**
  - By Act 3 the player's engine wins ~everywhere they've filled (T1-6), so stack losses can
    *only* happen at the fresh, unfilled High stakes — that's the design lock that makes High
    the sole anti-chip faucet. No extra gating needed beyond `band == "high"`.
- **Spent on:** Ultra unlock + corruption (Section 7/8). Anti-chips are a normal currency
  with a spend menu; Ultra is one item on it.
- **UI:** a top-bar anti-chip counter (Act 3 only), `RollingValue`-animated, using the new
  `{achip}` IconText marker + Theme tokens. Never the word.

**New IconText marker `{achip}`:** register alongside `{chip}` (find the IconText marker
registry the `{chip}`/`{w:stack}` markers live in) with a distinct sprite/glyph. All
anti-chip copy uses the marker.

---

## 7. Feature: corruption (anti-catalog upgrades)

Spend anti-chips to **corrupt an owned catalog upgrade into an ultra-powerful variant.**

- **Data (`data/catalog.lua`):** corruptible items gain a `corrupt` block:
  `corrupt = { cost_achip = N, effects = { ... } }` — the corrupted effect set + its
  anti-chip price. Pure data.
- **State:** `state.corrupted_items` (array of corrupted item ids; meta). Serialize +
  backfill `= {}`.
- **Purchase:** a `GameState:tryCorruptItem(item)` mutator mirroring `tryBuyCatalogItem`
  (validate owned + affordable in anti-chips + has a `corrupt` block), append to
  `corrupted_items`, invalidate `effects_cache`.
- **Rollup (`GameState:computeEffects`):** when applying an owned catalog item, if its id is
  in `corrupted_items`, apply `item.corrupt.effects` **instead of** `item.effects`. Build a
  `corrupted_set` once and branch on set-membership (a data lookup, not an `if id ==`
  chain) — same shape as the existing `owned_set` / `removed_by` handling.
- **UI:** a corruption action in the catalog/act-3 shop (a per-item "corrupt" affordance
  priced in `{achip}`). Corrupted items get a distinct visual (Theme token).

This is the memory's "corrupt upgrades into ultra-powerful variants" (option B); the earlier
"remove upgrades" (option A) is dropped per the latest call — anti-chip sinks are **Ultra +
corruption only.**

---

## 8. Feature: Ultra stake + the underflow ending

The terminal sequence. After R2 (`shove_r2_won`), the dealer's final cheat sets the
bankroll multiplier to **0 forever**, so shove rates collapse to 0 and R3 is unwinnable by
normal means. The only escape is to underflow.

- **Bankroll mult forced to 0 in Act 3 (`models/shove_rate.lua`):** when
  `state.shove_r2_won` and not yet underflowed, `mult = 0` (dealer's declaration). The
  bankroll-tier interpolation is bypassed. Gate this in `ShoveRate.compute` via a ctx/flag
  input (keep `shove_rate.lua` pure — pass the Act-3 state in, don't reach into globals).
- **Negative bankroll allowed in Act 3:** the resolution loop currently clamps losses so
  bankroll can't go below 0 (`GrindController` ~`:304-306`, `r.delta = -state.bankroll`).
  Add an Act-3/Ultra exception so Ultra losses drive bankroll **negative**. Buying tables /
  upgrades still requires `bankroll ≥ cost` (positive gate unchanged) — negativity only
  accrues from losing, it doesn't fund purchases.
- **Ultra:** `ultra_unlocked` (bought with anti-chips) reveals s010. Its buy-in is huge and
  it's unwinnable, so playing it is a controlled bankroll bleed.
- **Underflow → 999× (`models/shove_rate.lua` + data):** when bankroll drops below a huge
  negative threshold (`UNDERFLOW_THRESHOLD`, data constant), `mult` flips from 0 to **999**
  (the "stack overflowed negatively" gag). Now `r3 = (deck/2) × (999/2)` overshoots massively
  → the final shove clears R3 → `cleared = true` → game won.
- **Ending copy / captor voice:** the House's "you're never getting out… your bankroll mult
  is 0, forever" beat plays on entering Act 3; the underflow flips it. Copy is a later pass
  (captor voice), not this build.

**Sequence recap:** R2 win → mult 0 + anti-chips unlock → farm anti-chips at High by losing
stacks → buy Ultra (+ corrupt upgrades) → bleed bankroll negative at Ultra → underflow to
999× → final shove → win.

---

## 9. Save / migration summary

New persisted fields (all `serializeMeta`, backfilled in `applySaved`): `anti_chips` (0),
`corrupted_items` ({}), `ultra_unlocked` (false). No run-scoped additions. No key renames.
Reuse the `deck_overhaul_migrated`-style one-time flag only if a field needs a real data
transform; plain backfills need just the `= default` in `applySaved`. Stake `band` fields
and the master deck are pure data adds (new saves + old saves both read the current
`data/*.lua`), so they need no migration — but the master deck's `decks_maxed` unlock must
tolerate a save that already has 5+ maxed decks (it'll unlock on next `checkPendingUnlocks`,
which is correct).

---

## 10. Phased action plan

Each phase is independently testable and lands in order so nothing half-wires the shove
math. Numbers are placeholders throughout; balance is Phase 6. Check items off as built.

### Phase 1 — Stake ladder (Sec 4) — **IN PROGRESS (2026-07-17)**
- [x] Add `band = "low"|"mid"|"high"|"ultra"` to every stake in `data/stakes.lua`
- [x] Add High stakes `s007`–`s009` (placeholder WC/dist, widening fill windows)
- [x] Add Ultra stake `s010` (astronomical buy-in, ~0 WC, unreachable fill, all-jackpot loss)
- [x] Add `C.STAKE_BAND_GATE` (band → unlocking state flag) in `data/constants.lua`
- [x] Add `GrindController:stakeAvailable(stake)` — the single source of truth
- [x] Route `GrindView.stakeVisible` through the controller (add-table buttons + range tooltips)
- [ ] **Verify (user, in-game):** low always shows; mid appears only after R1 win; high only after R2 win; ultra never shows yet; prototype build still shows low only.

### Phase 2 — Master deck + base rework (Sec 5) — **BUILT (2026-07-17)**; verify pending
- [x] `total_deck_levels` transient seeded in `GameState:computeEffects`
- [x] Capability kinds `shove_base_per_deck_level` (max-idempotent) + `shove_base_double`
- [x] `decks_maxed` unlock kind in `models/deck_unlock_rules.lua` (+ `Decks.totalLevels`/`maxedCount` helpers)
- [x] Master deck spec `master` in `data/decks.lua` (5 levels; unlock `decks_maxed`≥5; placeholder copy/number)
- [x] `buildRates` new formula: `r1=(cat+deck)×mult`, `r2=deck×(mult/2)`, `r3=(deck/2)×(mult/2)`; breakdown shows a Deck-base line
- [x] `data/effects.lua` docs for the new kinds
- [ ] **Verify (user, in-game):** R2 = 0 with no master deck (even with fat catalog); master deck appears at 5 maxed decks; deck base + R1 headline climb as deck levels accrue; capstone doubles it; prototype unaffected.

### Phase 3 — Anti-chips (Sec 6)
- [ ] `state.anti_chips` + `serializeMeta` + `applySaved` backfill
- [ ] `{achip}` IconText marker + Theme tokens
- [ ] Earn site in `GrindController` resolution loop (jackpot loss @ High band, Act 3)
- [ ] `stake.anti_chip_award` data field on High/Ultra
- [ ] Top-bar anti-chip counter (Act 3 only, `RollingValue`)

### Phase 4 — Corruption (Sec 7)
- [ ] `corrupt = { cost_achip, effects }` blocks on corruptible `data/catalog.lua` items
- [ ] `state.corrupted_items` + serialize + backfill
- [ ] `GameState:tryCorruptItem` mutator
- [ ] `computeEffects` applies `corrupt.effects` for ids in the corrupted set (set-membership, no `if id ==`)
- [ ] Corruption affordance in the shop + corrupted visual (Theme token)

### Phase 5 — Ultra + underflow ending (Sec 8)
- [ ] `state.ultra_unlocked` (bought with anti-chips) reveals `s010`
- [ ] Act-3 bankroll mult forced to 0 in `shove_rate` (pass Act-3 state in; keep it pure)
- [ ] Negative-bankroll Act-3 exception in the resolution loop (purchases still need `≥ cost`)
- [ ] `UNDERFLOW_THRESHOLD` constant; mult flips 0 → 999 on underflow
- [ ] Final-shove win path (`cleared`); captor-voice copy is a later pass

### Phase 6 — Balance (separate, user-owned)
Top-ladder WC/dist/fill tuning, master-deck base constant, anti-chip award rates, Ultra
buy-in, underflow threshold, and pacing to the 1.5/2.5/1h targets. Do **not** fold into the
build phases.

### Cross-cutting (do alongside the phase that introduces the field)
- [ ] Save backfills for `anti_chips` (0), `corrupted_items` ({}), `ultra_unlocked` (false)
- [ ] Resolve the four open decisions in Sec 12 before Phase 2/5 wiring

---

## 11. Critical files

- `data/stakes.lua` — s007-s010, `band` field
- `data/constants.lua` — `BAND_GATE`, `UNDERFLOW_THRESHOLD`, `HIGH_TIER_STAKES` repoint, anti-chip/master-deck placeholder constants
- `data/decks.lua` — master deck spec
- `data/catalog.lua` — `corrupt` blocks
- `data/effects.lua` — docs for new capability kinds
- `models/shove_rate.lua` — `buildRates` formula, `ctx.shove_base`, Act-3 mult=0 + underflow→999
- `models/deck_unlock_rules.lua` — `decks_maxed` unlock kind
- `models/poker_effects.lua` — `shove_base_per_deck_level`, `shove_base_double` capability kinds
- `models/GameState.lua` — `total_deck_levels` transient, anti-chip/corruption/ultra state + serialize + backfill, `tryCorruptItem`, corruption branch in `computeEffects`
- `controllers/GrindController.lua` — `stakeAvailable` filter, anti-chip earn in resolution loop, negative-bankroll Act-3 exception
- `states/ShoveState.lua` — Act-3 entry (mult-0 declaration) hook, `ultra_unlocked` flow
- Views — stake picker band filtering, anti-chip top-bar counter (`RollingValue` + `{achip}`), corruption shop affordance, Theme tokens + IconText marker

---

## 12. Open decisions to confirm before building

1. **Cheat model (Sec 5a):** R2 fully nullifies the catalog base (recommended) vs. a harder halving.
2. **Do mid/high bands need an explicit `{chip}` purchase to open, or does the milestone alone unlock them?** (User was unsure. Recommendation: milestone unlocks; Ultra is the only currency-gated tier, via anti-chips — cleanest.)
3. **Does the master-deck base also carry the final R3 overshoot, or does the underflow 999× mult do all the R3 lifting?** (Both can be true; confirm the intended feel.)
4. **`{achip}` marker glyph/name** and Theme palette for anti-chips + corrupted items.
