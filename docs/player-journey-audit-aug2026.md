# Player journey audit — what the game teaches, and where it stops

Date: 2026-08-23. Scope: the **player-facing journey**, start to finish, on the live
full-game flag set (`PROTOTYPE_MODE = false` → TUTORIAL on, DECKS on, HIGH_TIER_STAKES
on, MTT_KO on, DEMO_CUT off). Not a code audit.

Method: walked the actual state machine and data — title → grind → shove → prestige →
catalog → deck select → grind, across all three acts — and checked every beat against
the teaching surfaces that exist (`data/hints.lua`, the help desk, tooltips, catalog
copy, modals).

---

## 0. The headline

**Every teaching surface in the game is scoped to Act 1, before the first SHOVE.**

15 hints exist. All fire on counters that saturate inside the first session. Worse,
**six of the fifteen use `shoves >= 1` as their `done` condition** — a
veteran-suppression shortcut that also *permanently disables* those hints the moment
the player shoves for the first time.

| Hint | `done` | Consequence if the player shoves first |
|---|---|---|
| `tied_up` | `shoves >= 1` | Never learns CASH OUT or where the money went |
| `focus_overload` | `shoves >= 1` | Never learns the FOCUS penalty. Ever. |
| `stake_ladder` | NL10 open **or** `shoves >= 1` | The ladder is never explained |
| `first_chip` | `shoves >= 1` | The bounty rule is never stated |
| `chip_denied` | `shoves >= 1` | The once-per-(stake × type)-per-run rule — the core of the whole run loop — is never stated |
| `shove_ready` | `shoves >= 1` | Fine, self-retiring by design |

So the teaching budget isn't just front-loaded, it's **self-destructing**. And the game
actively encourages the rush: SHOVE unlocks at 3 {chip}, which is reachable long before
a player has hit focus overload or a denied bounty.

After the first shove the only surviving hints are `two_currencies` and `shove_pct`.
Then nothing, for the remaining ~5 hours of designed playtime.

The three act breaks — the most important moments in the game — are the three least
explained.

---

## 1. The journey map

**T** = taught · **P** = partial (tooltip/copy exists, nothing points at it) · **✗** = not taught anywhere.

### Act 0 — boot

| # | Beat | What the player must understand | Now |
|---|---|---|---|
| 0.1 | Title: Start / Load / Delete / Exit | — | T |
| 0.2 | Analytics consent modal | — | T |
| 0.3 | First grind: empty felt, $2, no tables | Nothing to do but open a table. A ROOM button is already in the top bar leading to a completely empty room (both `run0` items are stripped in TUTORIAL builds). | P |

### Act 1 — the earning loop, pre-first-shove — **this part works**

| # | Beat | Must understand | Now |
|---|---|---|---|
| 1.1 | Open first table | The $2 buy-in *is* your whole bankroll | T `first_table` |
| 1.2 | Press DEAL | DEAL plays one hand | ✗ `first_deal` cut in review — it's the literal first verb |
| 1.3 | First resolutions | Wins add, losses subtract, money now lives inside the table | ✗ `bankroll_flow` cut |
| 1.4 | Hovering | Everything self-documents | T `hover_things` |
| 1.5 | Table readout | Four outcome tiers, $/h, {w:stack}% | T `table_stats` |
| 1.6 | Help desk | The "?" replays hints | T `help_exists` |
| 1.7 | Run upgrades | Reset each run, pay for themselves | T `run_upgrades` |
| 1.8 | Second table | Throughput scales by tabling | T `multi_table` |
| 1.9 | Tied-up money | CASH OUT reclaims it | T (fragile, §0) |
| 1.10 | NL10 | Ladder, ~10× steps, harder opponents | T (fragile) |
| 1.11 | Focus overload | Over cap penalizes ALL tables | T (fragile) |
| 1.12 | Table bust + REBUY | A busted table isn't dead | ✗ `rebuy` cut in review |
| 1.13 | Quick reset | Bricked = free reset to $2 | T `quick_reset` |
| 1.14 | First {chip} | Stack win banks a bounty | T (fragile) |
| 1.15 | Denied {chip} | Diversify across stakes AND types | T (fragile) |
| 1.16 | SHOVE unlocks at 3 {chip} | All-in, ends the run, {chip} survive | T `shove_ready` |
| 1.17 | First SHOVE press | Every table cashes out; one hand decides the run | P — no explainer; the specced modal (#18) was cut for leaking R2/R3 |
| 1.18 | Lose R1 → prestige | You keep the {chip} | T `PrestigeModal` |
| 1.19 | Catalog, first visit | Permanent, bought with {chip} | T `catalog_intro` callout |
| 1.20 | Back in grind | Sidebar back at level 0; catalog persists | T `two_currencies` |
| 1.21 | SHOVE % | Catalog base × bankroll mult | T `shove_pct` |

**← All teaching ends here.** Everything below is untaught.

### Act 1 continued — the repeat loop

| # | Beat | Must understand | Now |
|---|---|---|---|
| 1.22 | Runs 2..N | The run's *job* has changed. It is no longer "get rich", it is "sweep bounties across as many (stake × type) combos as possible, then shove." This is the optimal play and is **never stated anywhere.** | ✗ **P0** |
| 1.23 | Catalog raises SHOVE % | Every catalog item silently carries `shove_rate_add`; no `effect_text` mentions it. The player cannot tell which purchases advance the win condition. **The primary progression axis of Act 1 is invisible.** | ✗ **P0** |
| 1.24 | Game-type tabs (HU / ZOOM / MTT) | Three table modes with different pace, win chance and pot shape | P — hover blurb only, never pointed at. The MTT blurb is also **factually wrong**: `GrindView.lua:334` says "100bb chips", `game_types.lua` sets `starting_stack_bb = 10`. |
| 1.25 | MTT tables | No DEAL button (auto-deals), seats bust out, finish position pays, top 3 cash, payout bar | ✗ **P1** |
| 1.26 | COMING SOON stickers | Catalog items unlock from your *scars* — busts, stack losses, rebuys, hands over cap | P — the sticker prints a progress counter, nothing frames the idea |
| 1.27 | Run-upgrade cap | Sidebar reads `MAX 11/29`: maxed but visibly not maxed. Cause: `fill_scaled` pins the cap to your top available stake. | ✗ **P1** — reads as a bug |
| 1.28 | ROOM | Owned catalog items become furniture. Purely cosmetic. | ✗ **P2** |

### Act 2 — entered by winning Runout 1

| # | Beat | What actually happens | Now |
|---|---|---|---|
| 2.1 | **First R1 win** | The biggest milestone in the game. The player gets a modal titled **"BUSTED"** reading *"You busted on the all-in."* `busted_at` is passed to `PrestigeModal` and discarded (`_busted_at`). Nothing marks the win. | ✗ **P0 — the worst beat in the game** |
| 2.2 | Deck select modal | A modal never seen before appears in the post-shove flow, unintroduced | ✗ **P0** |
| 2.3 | DECK chip appears in the top bar | New permanent UI element | ✗ **P1** (tooltip exists once found) |
| 2.4 | T4-T6 add-table buttons appear | The mid band silently unlocks | ✗ **P1** |
| 2.5 | Deck rules | Only the *active* deck earns XP; *all unlocked* decks' passives stack; swap only at shove; each deck has its own XP rule | P — all of it is in the DECK tooltip; nothing points there |
| 2.6 | Deck unlocks | `Decks.checkPendingUnlocks` appends silently. No toast, no glow, no floater. A deck can unlock and the player never knows. | ✗ **P1** |
| 2.7 | Deck level-ups | Also silent | ✗ **P1** |
| 2.8 | **The R2 wall** | Shove, win R1, lose R2. Every time, forever. `r2 = deck × (mult/2)`, and with no master deck `deck = 0`, so **r2 is exactly 0 and R2 is mathematically unwinnable.** `ShoveRate.formatBreakdown` *hides the "Deck base" line entirely while deck == 0* — the term zeroing them isn't even displayed. | ✗ **P0 — hard invisible wall** |
| 2.9 | The escape | Max 5 decks → The Master unlocks → its `shove_base_per_deck_level` is the only base surviving the R2 cheat | ✗ **P0** — discoverable only by accident |
| 2.10 | The Master unlocks | Silent, like every deck | ✗ **P0** |

### Act 3 — entered by winning Runout 2

| # | Beat | What actually happens | Now |
|---|---|---|---|
| 3.1 | **R2 win** | `ShoveRate.compute` sets `mult = 0` **permanently**. The top-bar SHOVE % snaps to 0% and stays there. From the player's seat, the game has broken. | ✗ **P0** |
| 3.2 | The escape | The only route back is `bankroll < -$100,000,000,000`, which flips mult to 999×. | ✗ **P0** — no progress readout, no statement of the rule anywhere |
| 3.3 | {achip} cell appears | A purple counter joins the top bar | ✗ **P1** |
| 3.4 | Anti-chips are earned by **losing** | `+N {achip}` floats on a **stack loss** at high/ultra stakes, once per (stake × type) per run — the exact inversion of the {chip} rule taught in Act 1 | ✗ **P0** |
| 3.5 | T7-T9 appear | Near-unwinnable by design (naked WC ~0.001, loss dist heavily jackpot). To an uninformed player this reads as a broken difficulty curve, not a loss farm. | ✗ **P0** |
| 3.6 | Corruption | Owned catalog items grow a purple price stamp; spend {achip} to corrupt them into much stronger versions | ✗ **P1** |
| 3.7 | Ultra stake (25 {achip}) | `"Unwinnable. Bleed bankroll to underflow."` — **this catalog description is the only place in the entire game that states the Act 3 win condition** | P |
| 3.8 | Underflow → 999× → R3 | The clear | ✗ |
| 3.9 | Credits | "you walked out." | T |

---

## 2. Ranked gap list

### P0 — player stalls, misplays a whole act, or reads the game as broken

1. **Winning R1 shows a modal that says BUSTED.** The act break isn't acknowledged.
2. **The R2 wall is invisible and mathematically absolute.** Deck base = 0 → r2 = 0, and the tooltip hides the zeroed term. No signpost toward "max 5 decks → The Master."
3. **Act 3 zeroes the mult.** SHOVE % reads 0% forever with no stated cause and no stated escape.
4. **Anti-chips invert the Act 1 rule** (win → lose) with no teaching.
5. **High stakes are a deliberate loss farm** and read as broken balance.
6. **`shove_rate_add` is invisible on every catalog item.**
7. **The "sweep bounties across stake × type" run objective is never stated.**
8. **Six hints tie `done` to the first shove**, so five core Act 1 concepts can be permanently skipped (§0).

### P1 — system arrives unexplained; the player plays worse but continues

9. Deck system: unlock, XP rules, active-vs-stacked passives, swap-at-shove.
10. Deck unlocks and level-ups are entirely silent.
11. Mid (T4-T6) and high (T7-T9) bands appear with no announcement.
12. MTT is a structurally different table type with no explanation, and a wrong blurb.
13. HU / Zoom identities are hover-only and never pointed at.
14. Cursor swarm: buying `cursor_pool` spawns cursors, adds two sidebar upgrades, and adds per-table `[D]`/`[R]` toggles plus per-type controls. All of it materializes unexplained.
15. `mouse_pad` / `tireless_assistants` change cursor *behavior* (rebuy clicking, collision phasing) with no in-game statement of what changed.
16. Run-upgrade `MAX 11/29` reads as a bug.
17. REBUY after a table bust.
18. Corruption.

### P2 — polish

19. The ROOM's purpose.
20. What NL2 / NL10 / bb mean — deliberately demoted (§5), but the glossary that held it is **currently unreachable in TUTORIAL builds**.
21. Catalog unlock gates being scar-based.
22. Focus penalty math (tooltip covers it; nothing points there).

---

## 3. Defects inside the teaching that *does* exist

- **MTT blurb is wrong.** `views/GrindView.lua:334` says "sit down with 100bb chips"; `data/game_types.lua` sets `starting_stack_bb = 10`.
- **`PrestigeModal` discards `busted_at`** (`views/PrestigeModal.lua:15`) — the one field that would let it tell a total loss from an act break.
- **`first_chip` says "banked"**, but `chips_this_run` stays *pending* until a shove or quick reset commits it (`GrindController.lua:1091`, `:1778`), and the top-bar count stays 0 pre-shove. Copy and mechanic disagree.
- **The glossary is unreachable in TUTORIAL builds** — the how-to-play modal that held it survives only in prototype builds. Flagged as open in `docs/tutorial-teaching-list.md`; still open.
- **No `AnchorRegistry` entry exists for the DECK chip**, so no hint can point at it until one is added. Every other later-phase target already has one.

---

## 4. Where and how each gap should be delivered

Reusing the existing hint / modal / glossary model, plus two classes the game doesn't
have yet (toast, persistent readout).

| Gap | Delivery | Why |
|---|---|---|
| R1 win acknowledged | **Branch `PrestigeModal` on `busted_at`** — same modal, different title + body when `outcomes[1] == true` and it's the first time | Zero new machinery; the data is already passed in and thrown away |
| Deck system intro | **Modal**, once, at 2.2 | A conceptual beat, and the player is already in a modal flow |
| Mid/high band unlock | **Hint** on the new add-table buttons, first grind entry after the flag flips | `add_table:<stake>:<gtype>` anchors already exist |
| R2 wall / master deck | **Hint** on the SHOVE cell after the first R1-win-R2-loss, **plus** unhide the `Deck base: 0.0%` line in `ShoveRate.formatBreakdown` | Showing the zeroed term is the honest fix; the hint names the goal |
| Deck unlock / level-up | **Toast**, or reuse `AwardGlow` on the DECK chip plus a floater | Same fanfare pattern the {chip} bounty already uses |
| Act 3 rules change | **Modal** at the R2 win | An act break *and* a rules change — the one place a full pause is earned |
| Anti-chips | **Hint** on the first `{achip}` float, plus a queue hint on the new top-bar cell | Mirrors `first_chip` exactly, inverted |
| High stakes = loss farm | Fold into the Act 3 modal, then a **hint** on the T7 add-table button | The framing has to land before they sit down |
| Underflow goal | **Persistent readout** — a progress bar toward `UNDERFLOW_THRESHOLD` in the Act 3 top bar | A one-shot hint can't carry an hour-long goal |
| `shove_rate_add` visible | **Tooltip row** on every catalog card: "+1.2% ALL-IN" | Data already exists per item; pure surfacing |
| Bounty-sweep objective | **Hint** after the second shove, anchored on the gtype tab strip | The concept only becomes actionable on run 2 |
| Game types (HU/Zoom/MTT) | **Hint** per type on first open, anchored on the gtype tab | Phase 6 #23-25 — specced, never built |
| MTT structure | **Hint** on first MTT table, and fix the blurb | Same |
| Cursors | **Hint** on `owned_items` gaining `cursor_pool` | Phase 6 #26-27 — specced, never built |
| REBUY | **Hint** on `any_table_busted` — the rule kind already exists | Was cut; should be restored |
| Run-upgrade cap | **Tooltip line**: "Capped by your highest stake" | One line, kills a false bug report |
| Corruption | **Hint** on the first corruptible item post-R2 | |
| ROOM | **Hint**, once, on the first catalog purchase | Gives the empty room a reason to be visited |
| Glossary | **Second section in the help desk** | The panel exists; it needs a static tab |

**Structural fix that unblocks half of the above**: change the six `done = shoves >= 1`
conditions to describe *the thing being learned* (`focus_overload` → done when focus is
no longer overloaded; `tied_up` → done when a cash-out happens). If old-save
suppression is still wanted, do it with an explicit first-scan-only veteran check.
Right now one mechanism is doing two jobs and breaking one of them.

---

## 5. Deliberately not taught — re-checked, still correct

Carried from `docs/tutorial-teaching-list.md` and verified against the live build:

- bb / blind structure (tooltip + glossary only)
- Dealer cheats, R2/R3 structure, gauntlet card construction — the reveal
- Fill windows, run-capped ceilings, the 0.95 WC cap
- Run-0 / handicap / poster — stripped in TUTORIAL builds; the room genuinely starts empty
- Dev hotkeys, debug overlays, analytics
- Stake themes, confetti, floaters — pure juice
- Cold Read / opponent reads — still vestigial, still no mechanic behind it

---

## 6. Sequencing

If this is built in slices, the order that buys the most per unit of work:

1. **Slice A — copy and one-liners, no new systems.** `PrestigeModal` R1-win branch; unhide the zeroed deck base; fix the MTT blurb; run-upgrade cap tooltip line; `shove_rate_add` row on catalog cards.
2. **Slice B — the `done`-condition rewrite.** Stops Act 1 teaching from self-destructing. Pure data edit in `data/hints.lua`.
3. **Slice C — Act 2.** Deck intro modal, band-unlock hints, deck unlock/level-up fanfare, R2-wall hint. Needs a DECK anchor and a toast primitive.
4. **Slice D — Phase 6.** The already-specced first-contact hints: game types, MTT, cursors, rebuy.
5. **Slice E — Act 3.** Act-break modal, anti-chip hints, underflow readout, corruption hint. Biggest lift, least-played act.
