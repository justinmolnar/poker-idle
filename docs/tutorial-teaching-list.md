# Tutorial teaching list (v2, 2026-07-15)

> **Superseded (2026-08-24).** Delivery is now two tiers, story beats and stateless popups, scripted in `docs/house-script.md`. Kept for the original teaching inventory.


Replaces the lost ~33-item list from the 2026-07-14 session. Targets the full-game
flag set (`TUTORIAL` on, `ONBOARDING_MODAL` off): no run-0, no forced how-to-play,
catalog button hidden until first post-shove catalog, decks locked until first clear.

Delivery model (per the redesign decisions):
- **hint** = contextual captor-voice nudge: trigger condition + anchored highlight +
  short text + advance-on-action. One at a time, never queued more than one deep.
- **modal** = full-pause explainer. Reserved for conceptual beats only.
- **glossary** = lives in the how-to-play reference (the shrunk "?" modal) and/or an
  existing tooltip. Not proactively surfaced.
- Copy is written later, in the captor's cheerful institutional voice. {chip} glyph
  never the word "chips". Final copy pass applies the concision rules.

Trigger notation references live state: `state.*` fields, `controller:*` reads
(see services inventory). "First time" conditions need a persisted `hints_seen`
set (one new meta table, keyed by hint id).

---

## Phase 1 — first minutes (empty room → first money)

**Phases 1-5 implemented 2026-07-15; first review pass applied same day.**
Live ids: first_table, ev_readout, stack_chance, help_exists, run_upgrades,
multi_table, outcome_tiers, tied_up, stake_ladder, focus_overload,
quick_reset, first_chip, chip_denied, shove_ready, shove_pct,
two_currencies — plus the catalog first-visit callout (#20, CatalogModal
opts.intro_callout, seen-flag hints_seen["catalog_intro"]). Cut in review:
first_deal, bankroll_flow, focus_limit, rebuy, catalog_button, and the #18
shove-explainer modal (info wrong for the real gauntlet). NEW mechanic from
review: SHOVE (button + top-bar cell) is hidden until the first-ever run
banks GAMEPLAY.SHOVE_UNLOCK_CHIPS (3) — GrindController:shoveUnlocked();
shove_ready fires at that reveal. Exact per-hint reference (class, trigger,
anchor, verbatim copy, review-notes slots): docs/hints-reference.md.
Phase 6 still pending. The "?" now toggles views/HintLogPanel.lua (the
"help desk": a compact title dropdown under the button; hovering a title
replays the full hint in-game — bubble, rings, dim) in TUTORIAL builds;
the old how-to-play modal survives only for prototype builds. Open: the
glossary that lived in the how-to-play is unreachable in TUTORIAL builds.

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 1 | Open your first table (NL2 button, buy-in = your whole $2) | `pool:count()==0 && shove_count==0 && lifetime_hands_played==0` | NL2 add-table button | hint |
| 2 | DEAL plays a hand | first table open, 0 hands played | table DEAL button | hint (advance on first deal) |
| 3 | The money floaters + your bankroll: wins add, losses subtract, blinds drain | first hand resolved | bankroll pile (anchor exists) | hint |
| 4 | $/h readout = expected earnings per hand; green good, red bad; hover for detail | ~3-5 hands resolved | per-table EV readout | hint |
| 5 | The "?" help / glossary exists | after hint 3 dismissed (low priority, fires when nothing else pending) | top-bar ? button | hint (one-shot, tiny) |

## Phase 2 — the earning loop

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 6 | Run upgrades: bought with table money, reset every run; buy them, they pay for themselves | first time `bankroll >= getRunUpgradeNextCost()` for any upgrade while `run_upgrade_levels` empty | right-sidebar upgrade card | hint (advance on purchase) |
| 7 | Multi-tabling: more tables = more $/h; second buy-in affordable | `bankroll >= 2×NL2 buy_in && pool:count()==1` | add-table button | hint |
| 8 | Win/loss tiers (Small→Stack glyphs); Stack is the big one, it matters later | first `large` or `jackpot` tier outcome | the floater / tier glyph in EV tooltip | hint |
| 9 | Tied-up money: cash lives inside tables; CASH OUT reclaims it | first time a purchase fails while `tiedUp() > missing amount` | TIED UP top-bar cell (needs anchor) | hint |
| 10 | Stake ladder: NL10 exists, names = buy-in, ~10× steps | first time `bankroll >= NL10 buy_in` | NL10 add button | hint |

## Phase 3 — overload and failure

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 11 | Focus capacity: you're AT the limit; next table cuts every table's earnings | `pool:count() == currentFocusCapacity()` first time | FOCUS top-bar cell (needs anchor) | hint |
| 12 | Focus overload + the Focus upgrade raises capacity | `currentFocusMult() < 1.0` first time | FOCUS cell + Focus upgrade card | hint (two-part: cell, then card) |
| 13 | Table bust ≠ dead: REBUY refills it, or close it and walk | first table stack hits 0 | REBUY button on the busted panel | hint |
| 14 | Quick reset rescue: bricked = free reset to $2, {chip} kept | `canQuickReset()` first true | quick-reset button over SHOVE | hint |

## Phase 4 — gold chips and the shove

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 15 | First {chip} banked: Stack win paid a gold chip; once per stake+type per run; gold trim marks spent tables (**chip touchpoint 1 of 2**) | `chips_this_run` 0 → >0 | CHIPS top-bar cell + gold-trimmed button | hint |
| 16 | Denied Stack: this table already paid its {chip} this run; other stakes/types still owe you (**chip touchpoint 2 of 2**) | resolution with `tier==jackpot && bountyBanked(stake,gtype)` already true | the gold-trimmed panel | hint |
| 17 | SHOVE presents itself: you're holding {chip} you can't bank without it; shove = all-in, win or lose you keep them and restart stronger | `chips_this_run > 0` && stall signal (no new {chip} banked in N hands AND cheapest un-banked bounty unaffordable — tune N) | SHOVE button (needs anchor) | hint. Per design note: do NOT over-gate; this is the idle-prestige reveal |
| 18 | Shove explainer: what the all-in is, your % to win it. **Runout 1 only — never mention R2/R3 or the dealer** | first SHOVE press, before the gauntlet deals | — | **modal** (the one allowed conceptual beat) |
| 19 | Shove % breakdown: catalog base × bankroll mult; growing bankroll grows the % | first bankroll-tier crossing (`bankroll_tiers` threshold) after first shove | SHOVE top-bar cell | hint (tooltip already has the safe breakdown; hint just points at it) |

## Phase 5 — post-shove meta

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 20 | Catalog: permanent, bought with {chip}, survives every run | first `CatalogModal` open post-shove (`catalog_seen` flips) | — (it's a modal already) | hint-style callout inside the catalog, first visit only |
| 21 | Catalog button now in the top bar: inspect any time, buy post-shove | first grind `enter` with `catalog_seen` true | CATALOG top-bar button (needs anchor) | hint |
| 22 | Run upgrades reset / catalog persists — the two-currency loop | first post-shove grind, sidebar back at level 0 | right sidebar | hint (small; may merge into 21) |

## Phase 6 — later systems (each on first contact)

| # | Teach | Trigger | Anchor | Delivery |
|---|-------|---------|--------|----------|
| 23 | HU: fewer opponents, swingier, big pots both ways | first HU table opened | HU sub-tab / panel | hint |
| 24 | Zoom: fast hands, new opponents every deal | first Zoom table opened | Zoom sub-tab / panel | hint |
| 25 | MTT: buy-in buys a seat, finish position pays; top 3 cash | first MTT table opened | MTT panel | hint |
| 26 | Idle mode: cursors deal for you; [C]/[R] mute toggles; Cursor upgrades appeared in the sidebar | `owned_items` gains `cursor_pool` | a live cursor + upgrade card | hint |
| 27 | Cursors can rebuy too | `owned_items` gains `tireless_assistants` | [R] toggle | hint (tiny) |
| 28 | Decks unlocked: post-win progression; active deck earns XP, all unlocked decks stack passives; swap at shove | `state.cleared` flips true (first grind after credits) | DECK top-bar chip | hint |
| 29 | New deck unlocked | `Decks.checkPendingUnlocks` returns non-empty | DECK chip | hint (toast-weight) |

---

## Deliberately NOT surfaced

- **bb / blind structure** — demoted; lives only as the "1 bb = $X" tooltip row and a
  glossary entry. Was on the old 33 list; dead now.
- **Dealer cheats / R2-R3 forced losses / gauntlet card construction** — the demo
  climax. The shove explainer covers runout 1 only.
- **Fill windows, run-capped ceilings, 0.95 WC cap** — internals; tooltips show
  "next level" deltas only.
- **Run-0 / handicap / poster** — doesn't exist in tutorial builds.
- **Dev hotkeys, debug overlays, analytics** — never.
- **Cold Read / opponent reads** — vestigial, no mechanic behind it; do not hint.
- **Stake themes, confetti, floaters-as-system** — pure juice, self-explanatory.

## Implementation notes

Hint system shipped 2026-07-15 (with Phase 1):

- **data/hints.lua** — declarative specs (id, anchor, text, trigger, done),
  list order = priority. Condition kinds in **models/hint_rules.lua**,
  registered into a dedicated UnlockRegistry instance (`g.hint_rules`);
  ctx = { state, pool }. `all`/`any` compose.
- **controllers/HintController.lua** — two delivery classes. `sticky`
  specs (instructions: press DEAL) hold a one-at-a-time slot with a
  forced bubble until their `done` condition or a bubble click. Non-sticky
  specs (FYIs: this is your bankroll) append to a persisted [i] queue —
  no focus steal, no expiry, only clicking the icon dismisses. If `done`
  already passes when a hint would first fire it retires silently —
  the veteran/old-save suppression (no migration); already-queued hints
  are exempt. Inert unless FEATURES.TUTORIAL. Checks throttled to 0.15 s.
- **views/HintView.lua** — pulsing highlight on the AnchorRegistry rect +
  captor-copy bubble (auto-placement right/left/below/above). The [i]
  strip renders at the "hint_queue" anchor (right of the tables sidebar,
  under the top bar); hovering an icon shows that hint's highlight +
  bubble, clicking it dismisses. **Presence follows the target**: anchors
  are frame-stamped (AnchorRegistry.tick/age), and a hint whose widget
  didn't draw this frame is simply not rendered — sticky bubble vanishes,
  [i] drops out of the strip, nothing dismissed; it returns when the
  widget does. Drawn above gameplay, below the hover tooltip and every
  modal; paused while a modal is up.
- **hints_seen** (id → true) + **hints_queued** (id list): persisted meta
  on GameState (new/wipeAll/serializeMeta; applySaved backfills). The
  shove-explainer modal and catalog callout reuse hints_seen for their
  one-shot flags.
- Sticky (forced bubble): first_table, run_upgrades, quick_reset.
  Everything else queues (shove_ready deliberately so — unlocking the
  shove must not read as pressure to use it).
- **Unconditional counters** feeding triggers (GrindController resolution
  block; GameState meta): total_hands_played, total_big_outcomes (tier
  large/jackpot, wins AND losses), total_denied_stacks (jackpot on an
  already-banked combo). Run-scoped: hands_since_last_bank (reset to 0 on
  a banking hand + resetRun). #17's stall N = 30 (tune in playtest).
- **Rule kinds** (models/hint_rules.lua, ctx = {state, pool, grind}):
  all/any/not composition; hands_played/shoves/chips_this_run/
  total_big_outcomes/total_denied_stacks/hands_since_last_bank/bankroll
  state thresholds; tables_open, hand_in_progress, any_table_busted,
  stake_table_open; tied_up, can_afford_stake, can_afford_run_upgrade,
  run_upgrades_owned; focus_at_capacity, focus_overloaded;
  can_quick_reset, catalog_seen, bankroll_tier, hint_seen.
- **Anchors now registered**: add_table:<stake>:<gtype>,
  buy_runup_<id> (sidebar cards), deal:/rebuy:<idx> + rebuy:any,
  ev:<idx>, cell:bankroll/tied/chips/shove/focus, btn:help/shove/
  quick_reset/catalog, hint_queue. All frame-stamped.
- **AnchorRegistry** now stores optional rects (`set(name, x, y, w, h)`).
  Registered so far: `add_table:<stake>:<gtype>` (ComponentRenderer
  `comp.anchor` pass-through), `deal:<idx>` / `rebuy:<idx>` (felt button),
  `ev:<idx>` (EV readout), `cell:bankroll`, `btn:help`. Still needed for
  later phases: FOCUS cell, TIED UP cell, CHIPS cell, SHOVE button,
  CATALOG button, DECK chip, sidebar upgrade cards.
- DONE 2026-07-15: the "?" is the hint log (views/HintLogPanel.lua, a
  compact title dropdown; hover replays the hint in-game) in TUTORIAL
  builds. The glossary question is still open — fold key terms into
  hints, or give the help desk a second section.
- #17's stall signal is the only fuzzy trigger — everything else is a crisp state
  check. Tune N (hands without a new bank) in playtesting.
