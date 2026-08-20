# Poker Idle — full codebase audit

**Date:** 2026-08-18
**Scope:** every `.lua` file outside `build/` and `build-tools/node_modules/` — 146 files, 38,399 lines — plus `data/`, `assets/`, `shaders/`, `sim/`, `analytics-worker/`, the build pipeline, the git working tree, and `docs/`.
**Method:** parallel specialist passes, one per dimension, each anchored to `file:line` with quoted code. Findings are marked **PROVEN** where they were executed or traced end to end, **REASONED** where they were not. Lua 5.4.6 was available and used to execute test cases against the real modules (`models/HandEval.lua`, `lib/json.lua`, `data/*.lua`) rather than reasoning about them from source.

Sections were produced by independent passes, so a few defects appear in more than one section. That repetition is deliberate and is left in: where three separate passes reached the same `file:line` from different directions (the `views/ShoveView.lua:404` crash was found independently by the crash sweep, the lifecycle pass, and the copy pass), the finding is corroborated rather than merely asserted. Where passes disagreed, the disagreement is called out and resolved in section 19.

This audit covers the four architecture rules, MVC and layering, god files and functions, data integrity, save and back-compat, gameplay math, crash risk, performance, dead code, player-facing copy, and repo tooling.

---

## Verdict

The architecture is in better shape than the defect list suggests, and the defect list is worse than the architecture suggests. Those are two separate stories and it is worth keeping them apart.

**The architecture.** Rule 1 (no globals) passes its own audit grep cleanly — zero `Game.` leaks outside `main.lua`. `models/` never touches `love.graphics`; it is the best-behaved layer in the project. The four registries are genuinely uniform and every one of them errors loudly on an unknown key; a cross-check of 88 data-declared kinds against 99 registrations found zero drift. There are no TODO/FIXME/HACK comments anywhere. That is a real standard, held over a long time, and most codebases this size do not have it.

Rules 2, 3, and 4 have drifted. `views/` is 44% of the codebase — larger than `models/`, `data/`, and `services/` combined — which is the structural tell that logic migrated into the render layer. `data/catalog.lua` executes 40 lines of imperative derivation at load. `services/` is a second view layer with four hard poker leaks and three inverted dependencies on `views/`. Fourteen of 28 services hold mutable module-level state, which is the pattern rule 1 exists to forbid, reappearing one layer below where the grep looks.

**The defects.** Eight Critical findings, and they are not stylistic. A single documented keypress crashes the shipped build inside `love.draw`. A different single keypress on a normal screen deletes the player's entire catalog. Negative bankroll turns every subsequent payout into `NaN` and writes it to disk. Any future `SAVE.VERSION` bump silently wipes every existing player. The two migration guards that exist are dead code. And the most natural command for committing the current work in progress produces a repository that no longer boots.

**The trend is the finding that matters most.** A prior audit sits in `docs/aug2026 audit kimi k3.md`. Re-measuring its targets: not one god file shrank. Six of seven grew, by 793 lines in total. `views/GrindView.lua` +211, `controllers/GrindController.lua` +117, `views/TablePanel.lua` +141, `views/RoomView.lua` +115, `views/CatalogModal.lua` +136, `models/Table.lua` +73. The seams that audit proposed were not taken, and every file it named has since absorbed more code. Whatever else this document says, that number is the one to act on: the codebase is moving away from its own rules, not toward them, and it is doing so while the rules themselves remain correct.

**One process change dominates the fix list.** The two worst runtime defects in this document are the same bug: an identifier that reads as a constant, is never declared, and silently evaluates to `nil`. This was settled definitively rather than by grep — every `.lua` in the repository was compiled with `luac -p -l` and every `GETTABUP _ENV` global read extracted from the bytecode. **The entire codebase contains exactly two undefined global reads**, and both are shipped bugs: `BUILDUP_TOTAL` at `views/ShoveView.lua:404` (crashes `love.draw`) and `ev_sign`/`ev_color` at `views/TablePanelStats.lua:383` (renders "nil" and loses the EV sign). There is no third.

That is the good news and the bad news at once: the class is tiny and completely enumerable, and it still shipped twice, because there is no linter, no test, and no CI in this repo. `luacheck --globals love -q .` in a pre-commit hook closes it permanently and would have caught both.

---

## Fix these first

**8 Critical, 18 High, 6 Medium.** Ordered by severity; every row is anchored and quoted in the sections below. Rows 1-8 are the ones that cost a player something today.

Two scope notes: this table is the audit. The sections after it are reference material to consult when you pick a row up — they are not meant to be read front to back. And two of the eight Criticals (rows 5 and 6) are latent rather than active: they fire on the next `SAVE.VERSION` bump, not today.

| # | Severity | Finding | Location |
|---:|---|---|---|
| 1 | **Critical** | Pressing SPACE during the shove buildup assigns the never-declared `BUILDUP_TOTAL`, nils `phase_t`, and crashes inside `love.draw`. Not gated by any flag; the code comment says this branch "stays in every build". | `views/ShoveView.lua:404` |
| 2 | **Critical** | Pressing `U` on the Room screen wipes `owned_items` and `cleared` when the player already owns everything. **No `DEV_HOTKEYS` gate at all** — unconditional in every build. Room is a normal top-bar button. | `states/RoomState.lua:125-158` |
| 3 | **Critical** | Negative bankroll plus the Bank capstone turns every payout into `NaN`, which then persists to the save file. | `controllers/GrindController.lua:357-358` |
| 4 | **Critical** | `SettingsModal:_performLoad` calls `wipeAll()` *before* checking a save exists. One misclick destroys everything. | `views/SettingsModal.lua:113-128` |
| 5 | **Critical** | Any `SAVE.VERSION` bump returns `nil` for every existing save, and callers treat `nil` as "fresh game". No migration hook exists. | `services/SaveService.lua:61-63` |
| 6 | **Critical** | The two `== nil` migration guards in `applySaved` are dead code — they can never fire. | `models/GameState.lua` |
| 7 | **Critical** | `git commit -am` on the current working tree breaks every clone: `data/catalog.lua` requires the untracked `data/balance.lua`. | `data/catalog.lua:1004` |
| 8 | **Critical** | `r.table_idx` is stale by the time it is consumed. `TablePool:update` stamps the index, the deferred-close sweep then `table.remove`s tables, and line 389 reads the old index — so a payout lands on the **neighbouring table**, the wrong bounty combo is consumed, and if the closed table was last, `tbl` is nil and the loss is clamped against bankroll instead of the stack. Closing a table mid-hand with `[x]` is enough to trigger it. | `controllers/GrindController.lua:213-218, 389` |
| 9 | **High** | `inf`/`-inf` encode to a token `lib/json.lua`'s own decoder rejects — one such value silently wipes the whole save. | `lib/json.lua:41-43` |
| 10 | **High** | The uncommitted `services/FloatingTextSystem.lua` edit is half-finished and breaks table-persisted floaters. | working tree |
| 11 | **High** | Nothing ever seeds the RNG. No run is reproducible and `sim/` cannot replay. | `utils/rng.lua` + 70 call sites |
| 12 | **High** | The legacy-MTT tooltip renders `Expected cash: nil$12.40 per run` and strips the sign, so +EV and −EV tables read identically. | `views/TablePanelStats.lua:383` |
| 13 | **High** | `data/balance.lua` defines three functions inside `data/`, one of which dispatches on a hardcoded content allow-list. | `data/balance.lua:38,51,61` |
| 14 | **High** | Legacy-fork drift: several catalog perks and deck capstones silently no-op in the `PROTOTYPE_MODE = true` build that ships to itch. | `models/Table_legacy.lua` |
| 15 | **High** | `services/CursorPool.lua` requires both `models.Cursor` and `views.Theme` and hardcodes the `deal`/`rebuy` poker actions. Not liftable. | `services/CursorPool.lua:21-22, 74-82` |
| 16 | **High** | `controllers/GrindController:update(dt)` is 637 lines spanning 22 distinct concerns. | `controllers/GrindController.lua:178-810` |
| 17 | **High** | `drawEvReadout()` rebuilds the entire EV-breakdown tooltip — full distribution math plus per-row closures — **every frame for every active cash table**, then discards it unless the mouse happens to be over that tooltip. Gated only on `hit_boxes` being non-nil, which is always true. Scales to 32 tables × 60fps. | `views/TablePanelStats.lua:995-1038` |
| 18 | **High** | `views/TablePanelStats.lua` reimplements money formatting locally instead of using `utils/format.lua`, and never abbreviates. At the game's real high stakes it prints unabbreviated 7-9 digit strings that overflow the tooltip. | `views/TablePanelStats.lua` |
| 19 | **High** | `views/FeltLayout.compute()` reallocates ~10 tables plus a closure per table panel per frame, for layout that is static between resizes. | `views/TablePanel.lua:1476` |
| 20 | **High** | In `ShoveState:keypressed`, the prestige/catalog modal branches only `return` when the modal consumes the key. Neither maps `escape`, so ESC falls through and stacks `SettingsModal` on top of them — and with `DEV_HOTKEYS` currently on, `r` falls through the same gap and silently resets the gauntlet mid-modal. | `states/ShoveState.lua` |
| 21 | **High** | `GrindState:keypressed` handles Tab → RoomState *before* any modal check, bypassing even the onboarding modal documented as forced ("ESC does not escape it"). | `states/GrindState.lua` |
| 22 | **High** | There is no `love.errorhandler` anywhere. Any Lua error drops the player to LÖVE's default blue screen with no save flush — up to 10 seconds of progress lost, on top of whatever caused the error. | absent |
| 23 | **High** | `love.quit` only flushes for `grind`/`shove`, despite the neighbouring comment claiming it "flushes unconditionally". `RoomState` is a save blind spot on both autosave and quit. On the web build `love.quit` likely never fires at all. | `main.lua` |
| 24 | **High** | `OutcomeMath.evStats` runs **three times per cash panel per frame, uncached** — roughly 540 table allocations per frame at 12 panels — and the EV tooltip's full line list is rebuilt every frame for a hover that has not happened. | `views/TablePanelStats.lua` |
| 25 | **High** | The same index-as-identity flaw hits the cursor swarm unattended. | `states/GrindState.lua:258` |
| 26 | **High** | `Panel:draw` rebuilds both sidebars every frame: 110 `OutcomeMath.buildOutcome` calls for tooltips that are not visible, 22 `evStats` (half redundant), 88 discarded strings in the bounty-glow sweep, ~103 anchor tables per frame. | `views/GrindView.lua` |
| 27 | **Medium** | `love.resize` discards the real window size, so `ui_scale` is pinned at 1.25 forever and every font rebuild on resize is a wasted no-op. | `main.lua` |
| 28 | **Medium** | `data/room_layout.lua` furnishes only **9 of 49** live catalog items. The Room is a reachable player feature behind a normal top-bar button, so 40 owned items — all of bands B, C and D — never visually appear, despite the catalog framing them as "objects for a room". | `data/room_layout.lua` |
| 29 | **Medium** | `data/bankroll_tiers.lua` plateaus at $10M (mult 8) while stakes run to $100B, so `shove_rate.lua` returns a flat multiplier across the entire High/Ultra/Act-3 range. | `data/bankroll_tiers.lua` |
| 30 | **Medium** | `views/TablePanelStats.lua:1018-1021` mutates `Theme.tier.loss.jackpot`, which points straight at `data/theme.lua`'s live palette, and the restore is not exception-safe. A throw between mutate and restore leaves the shared palette corrupted for the rest of the session. | `views/TablePanelStats.lua:1018-1021` |
| 31 | **Medium** | `state.bankroll` is never quantised to cents, while affordability checks compare raw floats. | `models/GameState.lua` |
| 32 | **Medium** | `#resolutions == 0` early-returns past `_syncStateList`, losing the MTT `hands_won` reset. | `controllers/GrindController.lua:342` |

**Process fixes, in order of payoff:**

1. `luacheck` in a pre-commit hook — catches findings 1 and 11 and the whole undefined-global class.
2. Gate `RoomState`'s `U` key on `Constants.FEATURES.DEV_HOTKEYS`, and add a build-time assertion that `PROTOTYPE_MODE` is set correctly for the target. The shipped-safety property currently rests on a human remembering to flip one boolean.
3. A save round-trip test and a `HandEval` test. There is currently no automated test of any kind.
4. `git add data/balance.lua sim/` before the next commit, and `.kilo/` into `.gitignore`.

---

## Contents

1. Codebase shape and lead-auditor findings
2. The headline defect: pressing SPACE during the shove crashes the shipped game
3. Rule 2 — MVC separation (models / views / controllers / states / services)
4. Rule 3 — Data-driven: `data/` is logic-free, dispatch via registries, no hardcoded presentation
5. Rule 4 — Engine-agnostic infrastructure (liftability)
6. God-file deep dive — `views/GrindView.lua` + `controllers/GrindController.lua`
7. The table-rendering and chip cluster
8. The legacy fork — Table vs Table_legacy, HandScript vs HandScript_legacy, MttSession vs MttSession_legacy
9. Gameplay math and simulation correctness
10. Save/load, serialization, and back-compat
11. Runtime performance and GC pressure
12. Dead code, unreferenced assets, and duplication
13. Room / Catalog / Modal / Widget UI layer audit
14. Bootstrap, DI container, state machine, and lifecycle
15. data/ content integrity and cross-file referential consistency
16. Tooling, build pipeline, simulator, testing, docs, and the uncommitted working tree
17. Player-facing copy, text conventions, and text plumbing
18. Crash risk and Lua-specific defect sweep
19. Cross-validation against the prior audit (`docs/aug2026 audit kimi k3.md`)

---


## Codebase shape and lead-auditor findings

### Size by layer

| Layer | Files | Lines | % of code |
|---|---:|---:|---:|
| `views/` | 41 | 16,984 | 44.2% |
| `models/` | 24 | 7,610 | 19.8% |
| `data/` | 31 | 4,307 | 11.2% |
| `services/` | 28 | 3,088 | 8.0% |
| `controllers/` | 4 | 2,199 | 5.7% |
| `states/` | 5 | 1,505 | 3.9% |
| `main.lua` | 1 | 421 | 1.1% |
| `lib/` | 3 | 290 | 0.8% |
| `utils/` | 4 | 129 | 0.3% |
| `sim/` | 2 | 108 | 0.3% |
| `core/` | 3 | 88 | 0.2% |
| **Total** | **146** | **38,399** | |

`views/` is 44% of the codebase and larger than `models/` + `data/` + `services/`
combined. In a strict-MVC project where views only render, the view layer being
the biggest layer by a factor of two is itself the headline structural signal:
either the presentation is genuinely elaborate, or logic has migrated into it.
The per-file findings below and in section 2 (MVC) show it is substantially the
latter.

`core/` + `lib/` + `utils/` — the layers the engine-agnostic rule most cares
about — total 507 lines, 1.3% of the code. The reusable engine is thin;
`services/` (3,088 lines) is doing most of the infrastructure work, which is
where the liftability risk concentrates.

### The 15 longest functions

Measured across `main.lua`, `core/`, `lib/`, `utils/`, `services/`,
`controllers/`, `models/`, `views/`, `states/`.

| Lines | Location | Function |
|---:|---|---|
| **637** | `controllers/GrindController.lua:178` | `GrindController:update(dt)` |
| **438** | `views/CatalogModal.lua:466` | `drawItemCard(...)` (13 params) |
| **433** | `views/TablePanel.lua:1282` | `TablePanel.draw(...)` (8 params) |
| **395** | `models/poker_effects.lua:22` | `PokerEffects.registerAll(reg)` |
| **386** | `views/RoomView.lua:357` | `RoomView:draw(full_screen)` |
| **333** | `models/Table.lua:353` | `Table:deal(ctx)` |
| **252** | `views/RoomView.lua:921` | `RoomView:mousepressed(x, y, button)` |
| **207** | `views/GrindView.lua:907` | `iconRow(str)` (nested local) |
| **205** | `models/Table_legacy.lua:516` | `Table:deal(ctx)` |
| **187** | `views/ComponentRenderer.lua:307` | `CR._button(...)` |
| **179** | `models/MttSession.lua:154` | `MttSession:planRun(...)` |
| **175** | `views/TablePanel.lua:399` | `drawOpponentSeat(...)` (13 params) |
| **174** | `views/GrindView.lua:408` | `GrindView:_buildTablesTabComponents()` |
| **168** | `models/HandScript.lua:173` | `plan(outcome, table_ctx)` |
| **167** | `views/GameState.lua:35` | `GameState:new(saved)` |

**Critical — `GrindController:update(dt)` is 637 lines.** It is 35% of its own
file and the single worst function in the project. A per-frame update running
637 lines of branching means every idle-loop behaviour — table ticking, payout
resolution, unlock checks, animation triggers, hint firing — is interleaved in
one scope with shared locals. Nothing in it can be tested, reasoned about, or
changed in isolation, and any early `return` inside it silently skips every
subsequent subsystem for that frame. This is the highest-value single
refactor target in the codebase.

**High — five draw functions over 380 lines.** `drawItemCard` (438 lines, 13
positional parameters) and `drawOpponentSeat` (13 positional parameters) have
parameter lists long past the point where call sites are readable or safe to
reorder; a transposed argument between two same-typed params fails silently and
visually.

### Confirmed dead files

Zero `require` of either file anywhere in the repo, and no dynamic/string
reference:

| File | Lines | Evidence |
|---|---:|---|
| `services/Confetti.lua` | 89 | Only self-references. `Confetti.burst` never called. |
| `views/widgets/Dropdown.lua` | 277 | Full widget: `:new`, `:open`, `:consumeKey`, `:drawPopup`. Never constructed. |

366 lines of maintained-but-unreachable code. `Confetti.lua` carries a header
comment explaining how it differs from `ChipFlight.explode` — the module was
reasoned about and then orphaned, which is the expensive kind of dead code
because it still reads as live.

### Layer coupling (verified)

- **`models/` never touches `love.graphics`, `love.mouse`, or `love.keyboard`** — zero hits. Rule 2 is clean on the model-rendering axis.
- **`services/` reaches upward into `views/` three times** — `CursorPool.lua:22`, `SpriteRenderer.lua:11`, `Tooltip.lua:12` all `require("views.Theme")`. A service depending on a view module inverts the layering and breaks lift: `views/Theme.lua` cannot come along without dragging the view layer's conventions.
- **`services/CursorPool.lua:21` requires `models.Cursor`** — a service depending on a game model. This is the hard liftability break; see section 4.
- `services/` requiring `data/` (`animations`, `constants`, `sounds`) is by design — those are the registry data tables.

### Marker sweep

- **Zero** `TODO` / `FIXME` / `HACK` / `XXX` / `BUG` / `WIP` comments in the entire codebase. Genuinely unusual and worth stating plainly: there is no backlog of self-flagged debt in the comments.
- **51 console `print()` calls** outside `sim/` and the build tools. A naive `grep "print("` returns 198, but 200 of those hits are `love.graphics.print` draw calls — the two are easy to conflate and the distinction matters, because only the console ones cost anything off-screen. The real 51 are unconditional stdout writes not gated by a debug flag: `services/SpriteLoader.lua:115-131` prints on every boot, `services/ShaderRegistry.lua:41-61` prints per shader loaded, `states/ShoveState.lua:143-144` prints gauntlet results and session stats during play. All are event-driven rather than per-frame, so the runtime cost is negligible; in the love.js web build they surface in the browser console, which is untidy for a public release but not a performance problem.

### Architecture rule greps — headline results

| Rule | Audit grep | Result |
|---|---|---|
| 1. No globals | `Game.` outside `main.lua` | **0 hits — PASS** |
| 3. `data/` logic-free | `^function` / logic-layer `require` in `data/` | **3 hits — FAIL** (`data/balance.lua`) |
| 3. No kind-chains | `\.kind ==` dispatch | **5 real hits — FAIL** |
| 3. No literal colors | `love.graphics.setColor(<number>` | **11 hits — FAIL** |

Rule 1 is genuinely clean. Rule 3 is broken in three separate ways. Details in
sections 1 and 3.

### Critical — the next `git commit -am` breaks every clone of the repo

**PROVEN.** `data/catalog.lua` in the working tree requires a file that git does
not track:

```lua
-- data/catalog.lua:1004  (present only in the uncommitted diff)
local Balance = require("data.balance")
```

State of play:

| Fact | Verified by |
|---|---|
| `data/balance.lua` is **untracked** | `git ls-files --error-unmatch data/balance.lua` → *"did not match any file(s) known to git"* |
| `HEAD:data/catalog.lua` does **not** mention `data.balance` | `git show HEAD:data/catalog.lua \| grep -c "data.balance"` → `0` |
| The working tree's `data/catalog.lua` **does**, twice | `grep -c "data.balance" data/catalog.lua` → `2` |
| The require arrived in the uncommitted `+26` diff | `git diff data/catalog.lua` → `+local Balance = require("data.balance")` |

HEAD is currently safe. A fresh clone of HEAD loads `data/catalog.lua` fine —
confirmed by cloning the repo to a temp directory and running
`require("data.catalog")` under Lua 5.4: `catalog load ok: true`.

The hazard is the commit that has not happened yet. `git commit -am` stages
**modified tracked files only** — it does not pick up untracked files. So the
single most natural command to commit this work in progress produces a repository
where `data/catalog.lua` requires a module that isn't in it. Every clone, every
clean checkout, and every build-from-scratch then dies at load with
`module 'data.balance' not found` — before the first frame, with no partial
degradation to soften it.

`sim/run.lua:12` has the same require and is likewise untracked, so it fails
consistently rather than adding a second variant of the problem.

**Fix, before any commit touching `data/catalog.lua`:**

```
git add data/balance.lua sim/
```

More durably: this class of mistake is exactly what an untracked-file check in a
pre-commit hook catches. Any commit that adds a `require("data.X")` where
`data/X.lua` is untracked should fail loudly.

### `.kilo/` is untracked and unignored

`.kilo/` contains `kilo.jsonc`, `package.json`, `package-lock.json`, and a
`node_modules/` directory (it carries its own inner `.gitignore`). It is another
tool's working directory and it is not in `.gitignore`, so it sits in
`git status` as permanent noise next to genuine work in progress — which is
precisely the condition under which a `git add .` sweeps up something unintended.
One line in `.gitignore` fixes it.

Otherwise the repo is clean: **305 tracked files, zero tracked `node_modules`,
zero tracked `build/` output.** `.gitignore` already covers `build/`, `.claude/`,
`*.love`, logs, and the unshipped isometric source art. The largest tracked
assets are the `uVegas` audio files at 108-284 KB each; the largest tracked
source file is `views/GrindView.lua` at 110 KB.

---

## The headline defect: pressing SPACE during the shove crashes the shipped game

**Severity: Critical. Status: PROVEN by full trace. Reachable in the public itch
build. No debug flag gates it.**

`views/ShoveView.lua:404` assigns an identifier that is never defined anywhere in
the file:

```lua
-- views/ShoveView.lua:399-405
function ShoveView:skip()
    -- Buildup-skip: jump to ready-to-deal so the host fires the gauntlet
    -- on its next update tick. Player wanted out of the buildup spectacle.
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        self.phase_t = BUILDUP_TOTAL          -- <-- undefined global, evaluates to nil
        return
    end
```

`BUILDUP_TOTAL` appears exactly twice in the file: at line 162 inside a comment,
and here at 404. It is never declared. Every real constant in this file is a
`local` at lines 122-128 — `BUILDUP_FADE_DURATION`, `BUILDUP_LOCK_DURATION`,
`BUILDUP_FLIGHT_DURATION`, `BUILDUP_INTERVAL_START`, `BUILDUP_INTERVAL_END`,
`BUILDUP_MAX_CHIPS`, `BUILDUP_MIN_CHIPS` — and `BUILDUP_TOTAL` is not among them.

The value that *was* meant is the instance field `self.buildup_total`, set at
line 247 and read at line 445. The uppercase/lowercase pair is the whole bug: a
constant-shaped name was typed where a field lookup belonged, and in Lua an
undefined global is a silent `nil` rather than an error.

### Why it reaches `love.draw`

`:skip()` sets `phase = "ready_to_deal"`, and the buildup renderer runs in **both**
phases:

```lua
-- views/ShoveView.lua:879-880
if self.phase == "buildup" or self.phase == "ready_to_deal" then
    self:_drawBuildup(W, H)
```

So the very next frame enters `_drawBuildup`, whose sixth line divides by the
now-nil field:

```lua
-- views/ShoveView.lua:549
local fade_t = math.min(1, self.phase_t / BUILDUP_FADE_DURATION)
```

`nil / 0.5` throws `attempt to perform arithmetic on a nil value (field 'phase_t')`.

Line 884 repeats the same expression for the black fade-in, so even removing the
first would not save it.

This throws **inside `love.draw`**, which is the worst place for it: there is no
recovery path, the frame never completes, and the player gets LÖVE's blue error
screen rather than any in-game handling.

### Why a real player hits it

The trigger is a documented, encouraged interaction. `states/ShoveState.lua:390-398`:

```lua
-- SPACE during the cinematic = "skip" (continue semantic). That
-- stays in every build. The other branches (re-deal a finished
-- gauntlet, R reset, [/] catalog nudge, D overlay toggle) are
-- debug hotkeys gated on FEATURES.DEV_HOTKEYS.
if key == "space" then
    if self.view:isAnimating() then
        self.view:skip()
        return
    end
end
```

The comment states outright that this branch **"stays in every build"** — the
author deliberately exempted it from the `DEV_HOTKEYS` gate that protects the
neighbouring debug keys. And `views/ShoveView.lua:23` documents it as the
intended control: *"SPACE during animation calls `:skip()` to fast-forward."*

`isAnimating()` returns true for `"buildup"` (line 375), so the guard does
nothing to prevent it.

**Reproduction:** start a shove, press SPACE while the chips are still flying
into the pot. Crash.

The shove is the game's prestige moment and the buildup is a multi-second
spectacle — precisely the animation an impatient player skips. This is not an
edge case; it is the most likely single keypress during that sequence.

### The fix

One word:

```lua
self.phase_t = self.buildup_total or 0
```

`self.buildup_total` is already computed at line 247 and is already the value
line 445 compares against, so this makes `:skip()` do exactly what its own
comment says it does.

**Worth adding at the same time:** a static check for undefined globals. This bug
class — a nil global that reads as a constant — has now produced at least three
findings in this audit (`BUILDUP_TOTAL` here; `ev_sign` and `ev_color` at
`views/TablePanelStats.lua:383`). `luacheck` catches every instance of it in one
pass and would have caught all three before they shipped. That is the highest
value-per-effort process change available to this codebase, and it is a
`luacheck --globals love -q .` in a pre-commit hook.

---

## Rule 2 — MVC separation (models / views / controllers / states / services)

_(in progress)_

### 1. Views that mutate gameplay state

The codebase is mostly disciplined here — `grep "self.game.state.X ="` over `views/`
returns **zero** hits, and the two purchase modals deliberately dispatch through
`GrindController` with a documented comment. The violations that remain are
concentrated and real.

**[High] `views/SettingsModal.lua:113-127` — a view runs the entire load pipeline, including a raw write into model internals.**
```lua
function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    g.state:wipeAll()
    local saved = g.save_service:loadAll() or {}
    g.state:applySaved(saved)
    g.state.effects_cache = nil
    if g.state_machine and g.state_machine.states then
        for _, st in pairs(g.state_machine.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then st:fullReset() end
        end
        g.state_machine:switch("grind")
    end
end
```
A view orchestrates disk I/O, a full state wipe, a re-hydrate, a private cache
invalidation, a broadcast reset over every registered state, and a state-machine
transition. `g.state.effects_cache = nil` is the banned pattern verbatim: a view
reaching into a sibling model's internals to force a recompute. Cost: the load
sequence is unversioned and unreusable — `main.lua` boot, `startNewGame`, and
this modal each hand-roll their own variant, so any change to load ordering
(a new migration step, a new derived cache) has to be found in three places and
will silently diverge in one. **Correct home:** `GameState:reload(save_service)`
or a `services/SaveService` orchestration entry; the modal calls one method.

**[High] `views/DeckSelectModal.lua:65` — constructing a view mutates persistent gameplay state.**
```lua
    -- Ensure any stats-based unlocks (such as the Master deck on loading a save)
    -- are fully synced before the modal is rendered or deck choices are made.
    Decks.checkPendingUnlocks(game.state, game.unlock_rules)
```
`Decks.checkPendingUnlocks` (`models/Decks.lua:119-145`) appends to
`state.unlocked_decks` and seeds `state.deck_levels` / `state.deck_xp` — i.e. it
grants content. Opening a modal is now a state transaction. Cost: whether the
player owns a deck depends on whether they ever opened this screen; the same
call already exists in `main.lua:219` and `GrindController.lua:798/932/1733`, so
this is a fourth ad-hoc sync point papering over a missing invariant. **Correct
home:** the unlock sweep belongs on the boot path plus the XP-award path only
(`GrindController:_grantDeckXp`), never in a constructor.

**[Medium] `views/TablePanel.lua:1312-1313` — the view writes the model's world position.**
```lua
    tbl.x = x
    tbl.y = y
```
The panel stamps screen-space pixels onto the `Table` model each draw so
`Table:_finalizeHand` can put them into `_pending_resolution` (see
`models/Table.lua:780-781, 817-818`). Cost: `Table` is now undrawable-dependent —
a headless run (`sim/`) produces resolutions with `x = nil`, and the render order
of panels silently determines where floaters spawn. **Correct home:** the view
already publishes the same information the right way one screen later —
`Anchors.set(Table.anchorKey(tbl,"center"), ...)` at line 1349. The resolution
consumer should read the anchor registry by table id and `Table` should carry no
coordinates at all.

**[Medium] `views/TablePanel.lua:611-612, 711-714` and `views/PokerEventAnims.lua:238` — views clear and set model FX latches.**
```lua
        if tbl.pot_explode_pending and not tbl.pot_exploded then
            tbl.pot_explode_pending = nil
            ...
                tbl.pot_exploded = true
```
Two different files race to consume the same one-shot flag on the model (the
legacy path in `TablePanel`, the theater path in `PokerEventAnims`), with a
comment explaining which build wins. Cost: the "did the pot detonate" decision
is split across a controller (raises it), two views (consume it), and a model
(stores it); a third render path would have to know the whole protocol.
**Correct home:** a view-side one-shot registry keyed by table id (the codebase
already has `services/Pop.lua` doing exactly this for edge-triggered effects).

**[Medium] `views/TablePanel.lua:1382` — the view owns the model's event playback cursor.**
```lua
        tbl.view_event_cursor = idx
```
The drain of newly-fired script events is driven by a cursor stored on the model
and advanced only by `draw`. Cost: an off-screen or culled table never advances
its cursor, so its animation events queue up unboundedly and all fire at once
when it becomes visible; a headless build never advances it at all.
**Correct home:** view-local table keyed by `Table.anchorKey(tbl)`, or a proper
consumer handle handed out by the model.

### 2. Models touching rendering

**This is the strongest part of the codebase.** Verified clean:

```
$ grep -rn "love\.graphics\|love\.mouse\|love\.keyboard\|Theme\|require(\"views" models/*.lua
(no output)
$ grep -rn "require(\"(views|services|controllers|states)\." models/*.lua
models/GameState.lua:10:local AutoSerializer = require("services.AutoSerializer")
```
The single non-data dependency (`AutoSerializer`) is a stateless serialization
helper, which is legitimate. No model imports `Theme`, `Font`, or a view.

The exceptions are presentation *values* rather than presentation *calls*:

**[Medium] `models/Table.lua:183-190, 224` — the table model owns render-effect timers.**
```lua
        shake_trauma       = 0,
        border_pulse_t     = 0,
        lift_t             = 0,
        glow_t             = 0,
```
plus `self.reroll_flash_t = 0.4` (line 224) and the decay loops at 692-724.
These are pure view state (screen shake amplitude, border flash, hover lift,
shader glow intensity) living on the gameplay model and ticked by `Table:update`.
Cost: `sim/` runs the same `Table:update` and burns cycles decaying values
nothing reads; more importantly a second view of the same table (the mini-panel
grid) shares one shake timer, so two renderings of one table can't animate
independently. **Correct home:** a view-side FX registry keyed by
`Table.anchorKey(tbl)` — `views/TablePanelEffects.lua` already exists and reads
these; it should own them.

**[Medium] `models/Table.lua:780-781, 817-818` — the model stamps screen pixels into its resolution payload.**
```lua
            self._pending_resolution = {
                won   = self.outcome_won,
                delta = resolved_delta,
                tier  = self.outcome_tier,
                x     = self.x,
                y     = self.y,
```
`self.x` / `self.y` are only ever written by `views/TablePanel.lua:1312`. The
model therefore has a field whose sole author is a view and whose sole meaning
is a pixel. Cost: the resolution contract is untestable headless and reads `nil`
in `sim/`. **Correct home:** drop `x`/`y` from the payload; the consumer
(`GrindController:_emitResolutionChips`) already has `AnchorRegistry` and the
table id.

**[Low] `models/Cursor.lua` — a model that is entirely pixel-space.**
`Cursor:update(dt, deal_hbs, claims, speed_px, W, H, dispatcher, ctx)`
(line 102) takes screen dimensions and hit-boxes, moves in px, and claims UI
hit-box indices. It is a view-layer entity filed under `models/`, and
`services/CursorPool.lua:21-22` requires both it and `views.Theme`, making a
"service" depend on a model *and* a view. **Correct home:** `views/` (or a
dedicated `views/CursorSwarm`), with `CursorPool` following it.

**[Low] `models/HandScript.lua:78-301`, `models/Deck.lua:32`, `models/Gauntlet.lua:118`, `models/MttSession.lua:114-141` — models call `love.math.random` directly, bypassing `utils/rng.lua`.**
```lua
local function urand(a, b) return a + love.math.random() * (b - a) end
```
`utils/rng.lua` exists precisely so "a deterministic seed can be swapped in for
tests / replays without touching call sites" (its own header comment), and the
models ignore it. Cost: no seeded replay of a hand is possible, and the headless
`sim/` inherits a hard LÖVE dependency in the pure-logic layer.

### 3. Controllers owning gameplay state

`GrindController` has only four fields on `self`, and three of them are gameplay
state, not input routing:

```
$ grep -o "self\.[a-zA-Z_]*" controllers/GrindController.lua | sort | uniq -c
     60 self.game
     50 self.ctx
     46 self.pool
      7 self.pending_bursts
```

| field | what it is | where it belongs |
|---|---|---|
| `self.pool` (`:53`) | the `TablePool` — every live table, their stacks, their in-flight hands. The single largest chunk of run state in the game. | `GameState` (or a `Run` model owned by it). It's already serialized indirectly via `state.active_table_specs` and rehydrated by `pool:rebuildFromState`, which is the tell: the authoritative copy is elsewhere and the controller holds a shadow. |
| `self.ctx` (`:126`) | the computed effects rollup — every catalog/upgrade multiplier in the game. | `GameState.effects_cache` already exists for exactly this. The controller keeps a *second*, differently-invalidated copy. |
| `self.pending_bursts` (`:48`) | render intents. Legitimately controller-side (documented as a view-decoupling queue). | fine |

**[Critical] `controllers/GrindController.lua:239-790` — the controller *is* the economy.** 60+ direct field writes into `GameState`:
```lua
                        state.chips_this_run = state.chips_this_run + award
                        state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                        state.total_chips_banked = (state.total_chips_banked or 0) + award
```
Bounty caps, first-bounty bonus, Copy Machine's denied-bounty rule, anti-chip
awards, bankroll arithmetic, bust refunds, and ~40 statistics counters are all
inlined here, mutating `GameState` field-by-field with no model method in
between. Cost: `GameState` has no invariants it can enforce (nothing stops a
negative bankroll or a double-award); `sim/` can't exercise the economy without
booting a controller; and the same rule has to be re-derived by every reader.
**Correct home:** `GameState:awardBounty(stake_id, gtype_id, ctx)` /
`:recordHandResult(r)` — the controller should hand the model a resolution and
receive a list of things to animate.

**[High] `controllers/GrindController.lua:264-310` vs `:617-670` — the bounty-award block is copy-pasted.**
The MTT-win path and the cash-jackpot path contain the same ~45 lines (cap
check, `stakes_won_this_run` normalize-`true`-to-1, first-bounty bonus,
`chips_this_run` / `lifetime_chips_banked` / `total_chips_banked`, Copy Machine
fallback, `total_denied_stacks`). One comment at `:288` even documents a past
divergence: *"this used to hand-roll the formula and dropped the Pen add"*.
Cost: the codebase has already shipped a bug from these two copies drifting, and
nothing prevents the next one. **Correct home:** one `GameState:bankBounty(...)`.

**[Medium] `controllers/GrindController.lua:1754-1759` — a `if state == "..."` chain on table phase inside the controller.**
```lua
    if new_state == "dealing" or new_state == "flop"
       or new_state == "turn" or new_state == "river" then
    ...
    elseif new_state == "showdown" then
    elseif new_state == "settling" then
```
Per Rule 2 mode shifts are state/registry driven. Cost: adding a street means
editing this chain, and `data/sounds.lua` already exists as the registry this
should dispatch through (`SoundService.playNamed(phase_sound[new_state])`).

**[Medium] `controllers/HintController.lua:50` — `self.active` is un-persisted tutorial state while its siblings are persisted.**
```lua
        active  = nil,   -- the currently-showing STICKY spec, or nil
```
`hints_seen` and `hints_queued` live on `GameState` and survive a save; the
*currently displayed* sticky hint does not. Cost: save → quit → reload during a
sticky hint drops the hint; because `_markSeen` only fires on completion or
dismissal, the hint re-fires from scratch on the next trigger check, so the
tutorial can loop. `self.by_id` / `self._timer` / `self.enabled` are fine.
**Correct home:** `state.hint_active` alongside the other two (needs a save
migration per project convention, defaulting to nil).

**[Low] `controllers/InputController.lua:30` — a hard-coded two-state toggle.**
```lua
            local next_name = (sm:current() == "grind") and "shove" or "grind"
```
The generic input router knows two poker state names by string. Any third state
breaks the toggle silently (it routes to "grind").

### 4. Views reaching into a sibling model's internals to drive a state change

This is the specifically-banned pattern. Four confirmed instances:

| # | site | code | why it's the banned shape |
|---|---|---|---|
| 1 | `views/SettingsModal.lua:120` | `g.state.effects_cache = nil` | The view invalidates a private model cache to force a recompute it can't otherwise trigger. |
| 2 | `views/DeckSelectModal.lua:65` | `Decks.checkPendingUnlocks(game.state, game.unlock_rules)` | The view calls a model *mutator* to grant content so the render it's about to do will be correct. |
| 3 | `views/TablePanel.lua:1312-1313` | `tbl.x = x; tbl.y = y` | The view writes a model field to change what the model puts in its next resolution payload. |
| 4 | `views/TablePanel.lua:711-714` / `views/PokerEventAnims.lua:238` | `tbl.pot_explode_pending = nil` … `tbl.pot_exploded = true` | Two views consume and set a one-shot latch on a shared model, racing each other. |

`states/` does the same thing, one layer up and worse:

**[Critical] `states/ShoveState.lua:99-118` — the state reaches into the controller's pool and hand-rolls a cash-out that contradicts the controller's own rules.**
```lua
        local pool = self.game.grind.pool
        if pool and pool.tables then
            local tied = 0
            for _, t in ipairs(pool.tables) do
                tied = tied + (t.stack or 0)
            end
            pool.tables = {}
            state.bankroll = state.bankroll + tied
        end
```
`GrindController:cashOutAll()` (`:1258`) exists and routes through
`_finalizeRemove` (`:1227`), which encodes the actual refund rule:
```lua
    if gtype and gtype.chip_stack_table and t.mtt and t.mtt:isPlaying() then
        refund = 0            -- tournament chips don't convert to cash
    else
        refund = t.stack or 0
    end
```
And `GrindController:tiedUp()` (`:1198`) independently agrees, counting
`stake.buy_in` rather than `t.stack` for chip-stack tables. `ShoveState` uses
neither. For a chip-stack tournament, `t.stack` is *tournament chips*
(`models/Table.lua:275`: `self.stack = start_chips`, i.e.
`starting_stack_bb * stake.bb`), so this converts tournament chips into
bankroll dollars at 1:1. **Concrete cost: an exploit.** Open a KO tournament,
double up, press SHOVE — the doubled tournament stack is credited as real money,
where closing the same table normally refunds $0. It also blows away
`pool.tables` by raw assignment, bypassing `pool:removeTable` and every cleanup
it does. **(Verified by reading all three code paths; magnitude of the exploit
depends on live `starting_stack_bb`/`buy_in` values in `data/game_types.lua` and
`data/stakes.lua` — worth confirming numerically before sizing the fix.)**
**Correct home:** `ShoveState:enter()` should call
`self.game.grind:cashOutAll()` and read `state.bankroll` afterward.

**[High] `states/RoomState.lua:122-172` — the debug cheat rebuilds `owned_items` and clears the effects cache by hand.**
```lua
            state.owned_items = owned
            state.cleared = true
        ...
        state.effects_cache = nil
        if self.game.grind and self.game.grind.invalidateEffects then
```
A `keypressed` handler in a state owns catalog ownership semantics *and* a
save-shape repair ("repairs saves the old cheat polluted with hash keys"). Cost:
the save-shape repair only runs if the player presses `u` in the room editor —
so corrupted saves stay corrupted for everyone else. **Correct home:** the
sanitize belongs in `GameState:applySaved`; the grant belongs in
`GameState:debugUnlockAll()`.

**[Medium] `states/GrindState.lua:68-77` — the state installs seven closures onto the DI container so views can drive navigation.**
```lua
    game.grind = self.controller
    game.openCatalog    = function() state_self:openCatalog()    end
    game.openSettings   = function() state_self:openSettings()   end
    ...
    game.toggleRoom     = function() state_self.game.state_machine:switch("room") end
```
This is a service locator wearing the DI container's clothes: `views/GrindView`
and `views/CatalogModal` call `game.openCatalog()` / `game.grind:buyCatalogItem`
with no declared dependency, and the container's shape now depends on whether
`GrindState` has been constructed yet. `views/CatalogModal.lua:304-311` has to
carry a defensive fallback for exactly that reason:
```lua
    if game.grind and game.grind.buyCatalogItem then
        return game.grind:buyCatalogItem(item.id)
    end
    -- Fallback: route through the model directly if the grind controller
    -- isn't registered yet
    return game.state:tryBuyCatalogItem(item)
```
Cost: two live purchase paths with different side effects (the fallback skips
effects-cache invalidation and the sound). **Correct home:** pass callbacks into
the view constructors; register the controller in `main.lua`'s container.

### 5. Business logic living in views

**[High] `views/GrindView.lua:729-762` — a view simulates a hypothetical upgrade purchase to build a tooltip.**
```lua
            local ctx     = self.controller.ctx or {}
            local nextctx = {}
            for k, v in pairs(ctx) do nextctx[k] = v end
            for _, key in ipairs(spec.keys) do
                local list = {}
                for _, d in ipairs(ctx[key] or {}) do list[#list + 1] = d end
                list[#list + 1] = { strength = 1 }
                nextctx[key] = list
            end
```
The view shallow-copies the effects context, appends a synthetic
`{ strength = 1 }` fill, and re-runs `OutcomeMath.buildOutcome` across every
stake × game type (`:617-618`, `:655-656`). Cost: this encodes "what one more
level of an upgrade does" — a progression rule — in the render layer, so the
preview and the real purchase can disagree the moment `strength` stops being
the only relevant field (e.g. an upgrade with a per-level curve). It is also a
shallow copy of a nested structure, so any effect key the loop doesn't rewrite
is shared by reference with the live ctx. **Correct home:**
`OutcomeMath.previewNextLevel(ctx, upgrade)` or
`GameState:previewUpgrade(upgrade_id)`.

**[High] `views/TablePanelStats.lua:342-397` — the view computes tournament EV.**
```lua
    local function finishOdds(k) return (k >= cap) and (p ^ k) or (p ^ k) * (1 - p) end
    local exp_mult = 0
    for _, k in ipairs(thresholds) do exp_mult = exp_mult + finishOdds(k) * (payouts[k] or 0) end
    local net_ev = buy_in * (exp_mult - 1)
```
Win-streak probability distribution and net expected value, derived in a
tooltip builder. `models/outcome_math.lua` (572 lines) is the module for this
and has no equivalent. Cost: the number the player uses to decide whether a
game type is worth playing is computed by nothing the simulator or the balance
pass can call — `sim/` and `data/balance.lua` cannot check it.

**[High] `views/TablePanelStats.lua:255-262` — the view applies the earnings/loss multipliers to displayed averages.**
```lua
    local em = (controller and controller.ctx and controller.ctx.earnings_mult) or 1
    local lm = (controller and controller.ctx and controller.ctx.loss_mult)     or 1
    local win_avg_dollars  = stats.pool.win_avg_bb  * bb * em
    local loss_avg_dollars = stats.pool.loss_avg_bb * bb * lm
```
The view is the only place `earnings_mult` is folded into the average-win
readout. Cost: if `OutcomeMath` ever starts (or stops) applying `earnings_mult`
inside `stats.pool`, the tooltip silently double-counts or drops it with no
test able to catch it. **Correct home:** `outcome_math` should return dollars.

**[High] payout-table selection duplicated across the model/view boundary — 6 sites.**
```
models/Table.lua:954          local payouts = MttPayouts[boost] or MttPayouts[0]
models/Table_legacy.lua:931   local payouts = MttPayouts[boost] or MttPayouts[0]
views/TablePanel.lua:762      local payout_table = MttPayouts[boost] or MttPayouts[0]
views/TablePanel.lua:818      local payout_table = MttPayouts[boost] or MttPayouts[0]
views/TablePanelStats.lua:303 local payouts = MttPayouts[boost] or MttPayouts[0]
views/TablePanelStats.lua:348 local payouts = MttPayouts[boost] or MttPayouts[0]
```
Plus the finish-position decode (`pos = n_seats - k + 1`,
`n_seats = (gtype.seats or 0) + 1`) is re-derived in `views/TablePanelStats.lua:296-336`
and `views/TablePanel.lua:817` against `models/Table.lua:952-958`. Cost: the
ladder the player sees and the ladder that pays out are separate
implementations of the same rule. **Correct home:** one
`MttPayouts.tableFor(ctx)` + `MttPayouts.positionFor(key, n_seats)` accessor.

**[Medium] `views/GrindView.lua:962, 1012, 1316, 1922` — `ShoveRate.compute` is called four times per frame from the view, with the view assembling its input.**
```lua
        local rates = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
```
The "wealth" definition (`bankroll + tiedUp`) is a gameplay concept re-stated at
four render sites; `states/ShoveState.lua:118` computes the *shove-time* rate
from `state.bankroll` alone (post-cashout), so the displayed odds and the
gauntlet's actual odds use different inputs by construction.
**Correct home:** `GrindController:shoveRates()` computed once per tick.

**[Medium] `views/CatalogModal.lua:112-152` — visibility, unlock eligibility and peel state resolved in the view.**
`visibleItems(state)`, `catalogUnlocked(game, item, state)`, `isPeeled(state, item_id)`
each walk `data/catalog.lua` and evaluate gates. `models/catalog_unlock_rules.lua`
exists as the registry for this. Cost: `GrindView:_catalogButtonVisible` and the
modal can disagree about whether there is anything to buy.

**[Low] `views/TablePanelStats.lua:43-51` — `binomCoeff` is a combinatorics helper defined in a view and never called.**
```lua
-- Binomial coefficient for small n. Used by the MTT expected-payout
-- math (n = 8 hands per session).
local function binomCoeff(n, k)
```
`grep -n binomCoeff views/TablePanelStats.lua` returns only the definition. Dead
math in the render layer.

**[Low] `views/RoomView.lua:1352-1379` and `states/ShoveState.lua:141-146` — `print()` in the view/state layer.**
`RoomView:serializeLayout` dumps a Lua source table to stdout as its export
mechanism; `ShoveState:_beginGauntlet` prints gauntlet odds. Cost: on the web
build stdout goes nowhere, so the room editor's only export path silently
produces nothing.

### 6. States doing work that belongs in a model or controller

**[High] the run-reset triad is hand-copied into four unrelated files.**
```
controllers/GrindController.lua:1092-1094   state:resetRun() ... state:applyStartingPerks(self.ctx)
states/CreditsState.lua:66-69               state:resetRun() ... computeEffects ... applyStartingPerks
states/ShoveState.lua:219-222               state:resetRun() ... computeEffects ... applyStartingPerks
states/ShoveState.lua:270-277               state:resetRun() ... computeEffects ... applyStartingPerks
```
Each site re-derives "a new run starts like this", and they already differ:
`GrindController:quickReset` reuses the stale `self.ctx` instead of recomputing,
while the three states recompute. Cost: adding a step to run start (a new
starting perk, a counter to clear) requires finding four sites; miss one and
that entry path is subtly wrong. **Correct home:**
`GameState:beginRun(effects_registry, catalog, upgrades)`.

**[High] `states/ShoveState.lua:161-176` — act unlocks and their save are decided in a state.**
```lua
        if result.outcomes[1] == true and not state.shove_r1_won then
            state.shove_r1_won = true
            save_needed = true
            print("[shove] Won Runout 1 of the gauntlet: unlocked Act 2!")
        end
```
`shove_r1_won` / `shove_r2_won` are the two biggest progression gates in the
game (they drive stake bands, anti-chips, the deck system) and they are set by
index into a result array inside a screen's callback, followed by an ad-hoc
`saveAll`. Cost: any other path to a gauntlet win (a cheat, a future auto-shove,
the simulator) will not set them. **Correct home:**
`GameState:recordGauntletResult(result)`.

**[Medium] `states/ShoveState.lua:49-59` — `ShoveState` owns `self.gauntlet`, the live gauntlet model.**
The gauntlet is run state, not screen state: `ShoveState:fullReset` has to null
it, `:enter` guards on it (`if not self.gauntlet`), and its absence is what
distinguishes a fresh entry from an F6 hot-reload re-entry. Cost: reloading the
screen loses the in-progress gauntlet; a headless test cannot run one.

**[Medium] `states/RoomState.lua:45-113, 169-192` — the state hand-draws and hit-tests the top bar.**
```lua
    local top_h = fl(56 * s)
    local btn_w = fl(120 * s)
    local btn_h = fl(36 * s)
    local btn_x = W - btn_w - fl(16 * s)
```
The rect is computed independently in `:draw` and again in `:mousepressed`
(`:172-177`), so the drawn button and the clickable button are two literals that
must be kept in sync by hand. Every other screen puts this in a view.

**[Low] `states/TitleState.lua:169-172` — delete-save is a two-step transaction split across services.**
```lua
    self.game.save_service:clearAll()
    self.game.state:wipeAll()
```
If `clearAll` throws, memory and disk disagree. Trivial today; the point is that
`SettingsModal`, `TitleState`, and `InputController`'s F7 each spell this
sequence differently.

### 7. Mode branches on state names inside shared code

Rule 2 requires mode shifts to be StateMachine/Theme driven. The global-state
audit is close to clean:
```
$ grep -rn '== *"(shove|grind|room|title|credits)"' --include=*.lua .
controllers/InputController.lua:30   local next_name = (sm:current() == "grind") and "shove" or "grind"
main.lua:332                         if (cur == "grind" or cur == "shove") and not idle_modal then
main.lua:416                         if current == "grind" or current == "shove" then
views/GrindView.lua:1570             and self.game.state_machine.current_state_name == "room"
```
`main.lua` is the composition root and is allowed to know its states.
The other two are violations:

**[Medium] `views/GrindView.lua:1569-1570` — a view queries the global state machine to style a button.**
```lua
    local is_room_active = self.game.state_machine
        and self.game.state_machine.current_state_name == "room"
```
`GrindView` only ever draws while `grind` is current, so this is asking the
global router a question its owner already knows. Cost: the view is coupled to
the *name* of another screen. **Correct home:** a flag passed from `GrindState`,
or `Theme.active()`.

**[Medium] `controllers/InputController.lua:30`** — see section 3; the same two
poker state names hardcoded into the engine-layer input router.

The larger pattern is *table*-state branching leaking outward:

**[High] `services/FloatingTextSystem.lua:66, 73` — an engine-layer service holds a poker `Table` reference and branches on its gameplay phase.**
```lua
        if tbl and tbl.state == "idle" then
            t.saw_idle = true
        end
        if tbl and t.saw_idle and tbl.state ~= "idle" then
            table.remove(_texts, i)
```
A generic floating-text system stores `opts.table` (a `models/Table` instance)
and implements a bespoke "kill this floater when its table starts a new hand"
rule by polling the model's state machine. This is a Rule 2 *and* Rule 4
violation: the service is not liftable into another game, and it keeps a strong
reference to a model that may already have been removed from the pool
(`pool:removeTable`) — a leak until the floater expires. **Correct home:** the
emitter passes an opaque `owner_key` plus a `cancel_on` predicate, or
`GrindController` calls `FloatingTextSystem.clearOwner(key)` when it deals.

**[Low] `views/TablePanel.lua:608, 1546` — `if tbl.state == "idle"` in the panel.**
Legitimate as a render branch, but it means "is idle" is spelled as a raw string
comparison in six files rather than `Table:isIdle()`.

### 8. Services that hold game state

Most module-level upvalue state in `services/` is frame-scoped render caching and
is fine (`AnchorRegistry._anchors`, `ClickFlash._flashes`, `HoverService._hovered`,
`Pop._fired/_seen`, `RollingValue._v`, `Tooltip._t`, `Ghosts._ghosts`,
`FlightSystem._flying`, `ShaderRegistry._shaders`, `SoundService._sources`).
Three are not:

**[High] `services/CursorPool.lua` — a "service" that owns the game's autoclicker mechanic, requires a model *and* a view, and contradicts its own header.**
```lua
-- Engine-agnostic: this service sees a hit_box list with an `action`
-- string. It targets only `action == "deal"` for v1 ...  No knowledge of poker.

local Cursor       = require("models.Cursor")
local Theme        = require("views.Theme")

local _cursors = {}               -- list of Cursor instances
```
`_cursors` is the live swarm — a purchasable, upgradeable gameplay system whose
size and speed come from `ctx.cursor_count` / `ctx.cursor_speed_mult`, and whose
clicks *deal hands*. It also branches on the poker action strings `"deal"` and
`"rebuy"` (`:76-81`) and on `ctx.cursor_rebuy_unlocked`, directly refuting the
header. And it draws (`:141-181`). Cost: the swarm's state is invisible to
save/load (a reload silently re-spawns cursors at random positions), the service
cannot be lifted, and `services/` now depends on `models/` and `views/`.
**Correct home:** the swarm belongs in `models/` (state) + `views/` (render),
driven by the controller.

**[Medium] `services/HandAnalytics.lua:27-34` — module-level run state.**
```lua
local _enabled      = false
local _filename     = nil
local _file_data    = nil   -- { save_id, shoves = [...] }
local _current_run  = nil   -- reference into _file_data.shoves[i]
```
`_current_run` is a per-run accumulator holding hand-by-hand history. Cost: two
concurrent runs are impossible, and `startRun` without a matching flush leaks
the previous run's buffer. Acceptable as a singleton if that is a deliberate
choice, but it is *state*, not a utility.

**[Medium] `services/FloatingTextSystem.lua:23` — `_texts` entries hold live `models/Table` references.** See section 7.

**[Low] `services/CursorPool.lua:58-59` uses bare `math.random`, not `love.math.random`.**
```lua
        local cx = W * (0.3 + math.random() * 0.4)
```
Inconsistent with every other RNG site in the codebase and unaffected by
`love.math.setRandomSeed`.


---

## Rule 3 — Data-driven: `data/` is logic-free, dispatch via registries, no hardcoded presentation

### 1. Logic inside `data/`

The rule's own audit grep is `rg "^function|require\(['\"](services|models|controllers|views|states)" data/` → empty. That grep passes only because the violations use `data.*` requires and non-column-0 function syntax. The rule is broken in three places.

**Critical — `data/balance.lua:38,51,61` — three function definitions in a `data/` file.**
```lua
function Balance.getItemCost(authored_cost)
    if not authored_cost or authored_cost <= 0 then return 0 end
    local time_scale = Balance.RUN_MINUTES / 20.0
    local raw_cost = authored_cost * time_scale
    return math.max(1, math.floor(raw_cost + 0.5))
end
```
and, worse, `getItemShoveRate` hardcodes a **content allow-list** inside the balance engine:
```lua
function Balance.getItemShoveRate(item_id)
    if item_id == "poker_poster" or item_id == "no_poster_handicap" or item_id == "unlock_ultra" then
        return 0
    end
    return Balance.K_SHOVE_PER_ITEM
end
```
Cost: this is a string-id dispatch chain (see §2) living in the layer that is supposed to be inert tables. Adding a fourth exempt item means editing `data/`-layer *code*, and the exemption is invisible from `data/catalog.lua` where those items are actually authored. The correct shape is: keep `Balance.*` constants (lines 12-33) as the data table, and move the three functions to a `services/BalanceService.lua` (or `models/` if it needs game state). The per-item exemption should be an authored field on the catalog entry itself (`no_shove_contribution = true`) so the data declares its own exception, and the derivation loop reads the flag.

Aggravating: `data/balance.lua` is **untracked** (`?? data/balance.lua` in `git status`) while `data/catalog.lua:1004` already `require`s it. A fresh clone of the repo does not boot.

**High — `data/catalog.lua:999-1027` — two mutation loops and a kind-chain at module load.**
```lua
for _, item in ipairs(items) do
    if not item.run0 and item.phase ~= "system" and item.id ~= "unlock_ultra" then
        item.authored_cost_chip = item.authored_cost_chip or item.cost_chip
        item.cost_chip = Balance.getItemCost(item.authored_cost_chip)
        ...
        for _, eff in ipairs(item.effects) do
            if eff.kind == "shove_rate_add" then
```
This is a full derivation pass — 40 lines of imperative code rewriting the authored table in place, including `table.insert(item.effects, 1, {...})` synthesising effects that no author wrote. Cost: (a) the catalog you read is not the catalog the game runs, so debugging a price means mentally replaying a loop at the bottom of a 1030-line data file; (b) the `item.id ~= "unlock_ultra"` / `item.phase ~= "system"` guards duplicate the exemption list already in `Balance.getItemShoveRate` — two places, guaranteed drift; (c) it is idempotent only by accident (`authored_cost_chip or cost_chip` guards re-entry, but `table.insert` at index 1 would double-add if the module were ever re-required after a `package.loaded` clear, which the sim harness does).

**Medium — `data/catalog.lua:997-1002` and `data/game_types.lua:38` — feature-flag branches at load.**
```lua
if Constants.FEATURES.TUTORIAL then
    for i = #items, 1, -1 do
        if items[i].run0 then table.remove(items, i) end
    end
end
```
The comment calls this "the only branch in this file", which was true before the Balance block landed below it. Filtering by flag is defensible as a data-composition idiom, but it means `#items` differs by build — and `Balance.ACT1_ITEM_COUNT = 49` is a *hand-typed constant* that must track this filtered length. Nothing asserts they agree. If the tutorial flag flips, `K_SHOVE_PER_ITEM` is silently wrong.

**Low — `data/sounds.lua:14` — `require("utils.sample_set")`.** A pure `utils/` path expander, not an engine layer, and the rule's grep deliberately excludes `utils`. Called out only as the one acceptable case, for contrast.

**Clean:** `data/theme.lua`, `data/effects.lua`, `data/chips.lua`, `data/icons.lua`, `data/constants.lua`, `data/stakes.lua`, `data/decks.lua`, `data/animations.lua` and the rest are logic-free tables. 29 of 31 data files comply.

### 2. String-field dispatch chains

I grepped `if`/`elseif` against `.kind`, `.type`, `.id`, `.category`, `.effect`, `.rule`, `.event`, `.condition`, `.op`, `.mode`, `.state`, `.phase`, `.tier`, `.variant`, `.style`, `.shape`, `.action`, plus all 30 `elseif <expr> == "literal"` sites in the tree. Verdicts below; the majority are legitimate local branches, four are not.

| Site | Field | Verdict |
|---|---|---|
| `data/catalog.lua:1015` | `eff.kind` | **Violation** — kind-chain inside `data/` |
| `data/balance.lua:52` | `item_id` | **Violation** — content allow-list as code |
| `views/GrindView.lua:1091,1094` | `b.kind` | **Violation** — polymorphic, should be a registry |
| `views/GrindView.lua:815` | `up.id` | **Violation** — hardcoded content id in a view |
| `controllers/GrindController.lua:1077` | `id` | Borderline — hardcoded content id in a controller |
| `models/MttSession.lua:297-299` | `tier` | Borderline — ordered ladder written as a chain |
| `views/RoomView.lua:867,1031` | `row.kind` | OK — 2-case local list-row split, dev tool |
| `views/ComponentRenderer.lua:292-297,366-372` | `style` | OK-ish — token lookup already exists next door |
| `views/TablePanelStats.lua:861-865` | `shape` | OK — 3-case layout picker, all local |
| `services/SpriteLoader.lua:67,92` | `info.type` | OK — LÖVE filesystem API, not our data |
| `models/deck_xp_rules.lua:101,114` | `event.type` | OK — guard inside a registered rule, not a dispatcher |
| `views/ChipPile.lua:592`, `views/ShoveView.lua:375+`, `models/Cursor.lua`, `models/Table*.lua`, `services/CursorPool.lua` | `.state`/`.mode`/`.phase`/`.action` | OK — FSM guards, single-owner |
| `views/RoomView.lua:1176-1290`, `states/*State.lua` | `key` | OK — keyboard handlers |

**High — `views/GrindView.lua:1091-1104` — a genuine three-way polymorphic dispatch on a data-carried kind, in a view.**
```lua
for _, b in ipairs(bursts) do
    if b.kind == "scatter" then
        ChipFlight.explodeStack(b.source[1], b.source[2], b.chips, b.options)
    elseif b.kind == "stack" then
        ...
        ChipFlight.transfer(b.source, b.dest, o)
    else
        ChipFlight.flyChipsList(b.source, b.dest, b.chips, b.options)
    end
end
```
This is exactly the shape the rule names: a producer (`GrindController:drainBursts`) emits `{kind = "..."}` records and a consumer switches on the string. Cost: a fourth burst kind means editing view render code, and the fall-through `else` means a typo (`"scater"`) silently renders as `flyChipsList` instead of erroring. Fix: a `BURST_KINDS = { scatter = fn, stack = fn, list = fn }` table in this file (or better, on `ChipFlight`) plus an explicit `assert(handler, "unknown burst kind " .. tostring(b.kind))`. That is a 10-line change and would match the shape of `views/ComponentRenderer.lua:255 CR.types`, which already does this correctly for components.

**Medium — `views/GrindView.lua:815` — `if up.id == "box_of_mice"` puts a content id in render code.**
```lua
local up_actions
if up.id == "box_of_mice" then
```
The comment explains the design intent (the cursor upgrade owns the global cursor toggles), but the binding lives in the view rather than on the upgrade. Cost: renaming the upgrade id in `data/run_upgrades.lua` silently drops the global cursor controls with no error — the branch just never fires. Should be an authored flag: `owns_global_cursor_controls = true` on the entry, and the view tests `up.owns_global_cursor_controls`.

**Medium — `controllers/GrindController.lua:1077` — same pattern for `"poker_poster"`.**
```lua
for _, id in ipairs(state.owned_items) do
    if id == "poker_poster" then has_poster = true; break end
end
```
Same drift cost, and it is the *third* place `"poker_poster"` is hardcoded outside `data/catalog.lua` (also `data/balance.lua:52`). Grep count for the literal `"poker_poster"` outside `data/catalog.lua`: 2 files. A `gates_quick_reset = true` field on the item would collapse all of them.

**Low — `models/MttSession.lua:297-299` — the tier ladder is written as a chain instead of read as an ordered list.**
```lua
if     tier == "jackpot" then tier = "large"
elseif tier == "large"   then tier = "medium"
elseif tier == "medium"  then tier = "small" end
```
`data/pot_tiers.lua` already declares tiers; a `TIER_ORDER = {"small","medium","large","jackpot"}` there plus an index-decrement is both shorter and keeps the ordering in one place. Cost today is low (four tiers, stable), but adding a tier requires finding this chain — and the parallel clamp at line 287 (`if tier == "jackpot" or tier == "large" then tier = "medium"`) which would also need editing.

**Note (not a violation) — `views/ComponentRenderer.lua` is the model to copy.** Line 136 comments "Type registry (data-driven dispatch)", line 255 defines `CR.types`, and `CR._drawComp:281` / `CR.hitTest:529` both do `local def = CR.types[comp.type]`. That is the correct shape. Its residual `style ==` chains (292, 366) are a smaller version of the same problem — a `STYLE_TOKENS = { heading = Theme.fg.heading, muted = Theme.fg.muted, warning = Theme.status.warn }` map would delete both chains, and line 361-365 already demonstrates the table-lookup idiom for `line.color_token` two lines above the chain.

### 3. Registry consistency audit

Seven dispatch mechanisms. Four are the same shape and are the strongest part of the codebase; three deviate, and only two of the seven fail *loudly* on an unknown key.

| Registry | Instance shape | `register` sig | Unknown key | Verdict |
|---|---|---|---|---|
| `services/EffectsRegistry.lua` | `:new()` per-instance, DI (`g.effects`) | `(kind, fn)` | **`error()`** :43 | Reference implementation |
| `services/XpRuleRegistry.lua` | `:new()`, DI (`g.xp_rules`) | `(kind, fn)` | **`error()`** :39 | Matches |
| `services/UnlockRegistry.lua` | `:new()`, DI (`g.unlock_rules`, `g.hint_rules`) | `(kind, fn, progress_fn?)` | **`error()`** :51 | Matches, plus optional 3rd arg |
| `services/PokerEventRegistry.lua` | `:new()`, DI (`g.poker_events`) | `(kind, fn)` | **`error()`** :41 | Matches, but see naming note |
| `services/AnimationSystem.lua` `FACTORIES` :175 | module-level table, closed set | not registerable | **`error()`** :199,205 | Deviates: closed, not open |
| `services/ShaderRegistry.lua` | module-level `_shaders` upvalue, **no `:new()`** | `loadFromFile/FromSource(name,…)` | **silent `nil`** :71 | Deviates: singleton + silent |
| `SoundService.playNamed` → `data/sounds.lua` | module-level `Sounds` table | data file entry | **silent no-op** :175 | Deviates: silent |

**Good — the four `:new()` registries are genuinely uniform.** Same `setmetatable({fns={}}, R)`, same `register(kind, fn)`, same `has(kind)`, same `error("<Name>: no applicator for kind '"..tostring(k).."'")` message template. Wiring is uniform too: `main.lua:200/206/213/216/225/233` all do `<Rules>.registerAll(g.<registry>)`. A typo'd `kind` in `data/catalog.lua` or `data/decks.lua` crashes at effect-application time with the offending string in the message. That is the loud behaviour the rule wants.

I cross-checked data → registry coverage: 88 distinct `kind = "..."` strings across `data/catalog.lua`, `data/run_upgrades.lua`, `data/decks.lua` against 99 registered kinds. **Zero used-but-unregistered.** The 19 that looked missing to a naive grep are registered by loop over `COUNTER_KINDS` (`models/catalog_unlock_rules.lua:30-60`, `models/deck_unlock_rules.lua:32-53`), and I verified all 17 backing fields exist in `models/GameState.lua`. No drift today.

**Medium — the loop-registration idiom converts a loud failure into a silent one, one layer up.**
```lua
for _, field in ipairs(COUNTER_KINDS) do
    reg:register(field, function(cond, state)
        return (state and state[field] or 0) >= (cond.threshold or 0)
    end, ...)
end
```
`models/catalog_unlock_rules.lua:52-60`. A typo in the *data file's* kind still errors. But a typo in `COUNTER_KINDS` itself registers a working predicate that reads a nonexistent GameState field, returns `0`, and the unlock is permanently unreachable — no error, no log, and it looks correct in the catalog UI as "0 / 500". Same in `models/deck_unlock_rules.lua`. Cost: a permanently-ungettable item on a shipped save with no crash to point at it. A cheap fix is one `assert(GameState.DEFAULTS[field] ~= nil, field)` in the loop, or a boot-time coverage test.

**Medium — `SoundService.playNamed` fails silently on an unknown name.**
```lua
function SoundService.playNamed(name, opts)
    local vol_mult = (opts and opts.volume_mult) or 1.0
    playEntry(Sounds[name], vol_mult)
end
```
`services/SoundService.lua:174-177`, and `playEntry:154` opens with `if not entry then return end`. This is the one registry the rule text names explicitly, and it is the least defended. Cost: it is fed *computed* names — `controllers/GrindController.lua:1765 sounds.playNamed(key)`, `:577 self:_playNamed(pulse_sound, ...)`, `services/FlightSystem.lua:301 SoundService.playNamed(s.name)`, `views/ShoveView.lua:462 self.game.sounds.playNamed(ev.sound)`. A renamed key in `data/sounds.lua` produces silence, which is indistinguishable from a design decision and will not be noticed until a playtest. Note `data/sounds.lua:52-54` already shows the class of bug this hides: `pot_won_large` and `pot_lost_large` are misaligned in the source (`pot_won_large      = { files = CHIP_3ON2` — inconsistent column padding vs. its siblings), the sort of edit that produces a typo. Contrast `AnimationSystem.create:196-206`, which `error()`s on both an unknown preset *and* an unknown type — same class of data lookup, opposite policy. Recommend matching AnimationSystem: `error` under a debug flag, warn otherwise.

Corroborating count: 26 names declared in `data/sounds.lua`, only 10 reachable by literal `playNamed("…")`. The other 16 (`pot_won_*`, `pot_lost_*`, `border_pulse_*`, `chip_land_*`, `runout_won`, `gauntlet_won/lost`, `cheat_card_dealt`, `card_snap`) are only reachable through the four computed-name call sites, so nothing static can verify them.

**Low — `services/ShaderRegistry.lua` is a singleton, breaking the DI shape of its four siblings.** `_shaders` is a file-local upvalue (`:26`), there is no `:new()`, and `main.lua` cannot hand it to anyone. Consumers `require` it directly. `.get(name):71` returns `nil` for both "never loaded" and "failed to compile", so a caller cannot distinguish a typo'd name from a driver failure. The nil-return is deliberate and documented (graceful degradation), which is right for compile failure and wrong for a name typo.

**Low — `services/AnimationSystem.lua:175 FACTORIES` is closed, not a registry.** `local FACTORIES = { flip=…, bounce=…, fade=…, progress=…, timer=… }` with no `register` function. Adding a curve means editing the service, so a future game lifting `services/` and wanting a new curve must fork the file. The rule's own text calls this "AnimationSystem's factory table", so it is compliant as written; flagging only as an inconsistency with the four open registries. It also has the best unknown-key handling of any of the seven — two distinct errors, one for preset and one for type, both naming the bad string.

**Note (Rule 4 spillover, flagged for the engine-agnostic section):** `services/PokerEventRegistry.lua` sits in the engine layer whose own header says "Engine-agnostic: knows nothing about poker" while carrying `Poker` in the filename and module name. The mechanism is identical to `XpRuleRegistry`; the name is the only poker-specific thing about it.

### 4. Hardcoded presentation values outside `data/theme.lua` + `views/Theme.lua`

The rule's grep is `rg "love\.graphics\.setColor\(\s*\d"` → empty. It is **not** empty: 10 hits in project code (2 more in `build-tools/node_modules`, ignored). And the grep understates the problem by ~4x, because the dominant violation is `Theme.setColor({ literal })` — routing a literal through the theme helper, which passes the grep while defeating the point.

#### 4a. Numeric `love.graphics.setColor` — 10 hits

| File:line | Code | Judgement |
|---|---|---|
| `views/CatalogModal.lua:554` | `setColor(0.15, 0.15, 0.12, 0.55)` | Ink color, should be a token |
| `views/CatalogModal.lua:556` | `setColor(1, 1, 1, (is_owned and …) and 0.40 or 1.0)` | Asset tint — should be `Theme.assetTint(alpha)` |
| `views/CatalogModal.lua:561` | `setColor(0.15, 0.15, 0.12, 0.15)` | Ink color |
| `views/CatalogModal.lua:1119` | `setColor(0, 0, 0, 0.55)` | Scrim, should be a `Theme.bg.scrim` token |
| `views/RoomView.lua:410,482,576` | `setColor(1, 1, 1, 1)` | White reset — should be `Theme.assetTint()` |
| `views/RoomView.lua:574` | `setColor(1, 1, 1, 0.40)` | Ghosted asset — `Theme.assetTint(0.40)` |
| `views/RoomView.lua:645` | `setColor(1, 1, 1, 0.60)` | Ghosted asset — `Theme.assetTint(0.60)` |
| `main.lua:365` | `setColor(1, 1, 1, 1)` | **Acceptable** — final canvas blit before `love.graphics.draw`, below the theme layer entirely |

`views/Theme.lua:70 Theme.assetTint(alpha)` exists precisely for the six `(1,1,1,α)` cases and reads `Theme.tint.world` so a future palette can hue-shift everything. Cost of bypassing it: `RoomView` and the `CatalogModal` sticker art will not respond to a palette tint that every other view honours, so adding a palette produces a UI that is half-tinted. `RoomView` is the level editor (dev tool), which lowers its severity; `CatalogModal` is shipped player-facing UI, which does not.

**Severity: Medium** for `views/CatalogModal.lua:554/556/561/1119`, **Low** for the five `RoomView` hits, **not a defect** for `main.lua:365`.

#### 4b. `Theme.setColor({literal})` — 43 hits, and `views/CatalogModal.lua` is 37 of them

| File | `setColor({literal})` | total `setColor` | % literal |
|---|---|---|---|
| `views/CatalogModal.lua` | **37** | 46 | **80%** |
| `views/TablePanelStats.lua` | 4 | 48 | 8% |
| `views/TablePanel.lua` | 1 | 41 | 2% |
| `views/widgets/Sticker.lua` | 1 | 17 | 6% |

**High — `views/CatalogModal.lua` has a second, undeclared palette embedded in it.** The literal `0.15, 0.15, 0.12` (the order-book ink) appears **38 times in this one file**; `0.75, 0.20, 0.20` (the red stamp) 6 times; plus `{0.94,0.90,0.83}`, `{0.90,0.85,0.76}`, `{0.88,0.84,0.77}` for three barely-distinguishable paper tones.
```lua
Theme.setColor({ 0.15, 0.15, 0.12, 0.30 })    -- :516
Theme.setColor({ 0.15, 0.15, 0.12, 0.08 })    -- :538
Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })    -- :540
Theme.setColor({ 0.15, 0.15, 0.12, 0.60 })    -- :674
```
Cost: (a) this is the file the player looks at after every bust, and none of it responds to `Theme.setActive` — switching to the `shove` palette leaves the catalog in room colors; (b) `Theme.setColor` already takes an alpha as its 2nd argument (`views/Theme.lua:59`), so all 38 could be `Theme.setColor(Theme.catalog.ink, 0.30)` with a single 4-line token block added to `data/theme.lua`; (c) three near-identical paper tones with no names means nobody can tell whether the difference is intentional. This is the single worst Rule-3 presentation offender in the tree — 38 of the 43 literal-table calls in the codebase are one color in one file.

Note `views/CatalogModal.lua` is currently **modified but uncommitted** (`M data/catalog.lua`, `M views/CatalogModal.lua` in `git status`), so this is live drift, not legacy.

**Low — `views/TablePanelStats.lua:550,691** `Theme.setColor({1, 1, 1}, 0.03)` — a hairline white overlay, twice. One `Theme.fg.hairline_overlay` token removes both.

**Low — `views/TablePanel.lua:1435** `Theme.setColor({ 0.65, 0.35, 0.95 })` — this exact triple is **already a token**: `data/theme.lua:196 achip = { 0.65, 0.35, 0.95 }` with the comment "purple disc for anti-chips". A token was defined and then the literal was pasted anyway. Cost: change the anti-chip purple in `data/theme.lua` and this one call site keeps the old color.

#### 4c. Fonts

**Clean, with one exception.** `services/FontService.lua:54-57` derives all four sizes from `data/theme.lua`'s `Theme.font.size_sm/md/lg`, and every `setFont` call in views goes through `game.fonts.{xs,sm,md,lg}` or a local alias.

**Low — `views/Chips.lua:23,38** `local LABEL_FONT_PX_BASE = 9` → `love.graphics.newFont(LABEL_FONT_PX, "normal", 1)`. The only `newFont` outside FontService, with a literal size that is not in `Theme.size` (9 sits between `xs = 10` and nothing) and uses the LÖVE default face rather than `Theme.font.path_main`. Cost: the chip denomination labels are the one text in the game not in the project typeface and not on the type scale, and they do not resize with the FontService scale path — `:52` reimplements the scaling separately.

#### 4d. Spacing / padding

`data/theme.lua:213-231 Theme.space` defines 15 named spacing tokens. Adoption is thin and lopsided:

| File | `Theme.space.` uses | UPPER_CASE literal-px locals |
|---|---|---|
| `views/TablePanel.lua` | 19 | 13 |
| `views/GrindView.lua` | **1** | **24** |
| `views/ShoveView.lua` | 8 | 16 |
| `views/CatalogModal.lua` | 9 | 7 |
| `views/RoomView.lua` | 0 | 4 |

**Medium — `views/GrindView.lua` uses `Theme.space` exactly once while declaring 24 literal-pixel layout constants.** The largest view in the game is effectively opted out of the spacing scale. This is not as bad as a raw magic number inline — the constants are named and grouped at the top of the file — but it means the base-4 grid is unenforced and the two files disagree about what "a gap" is. Cost is consistency drift rather than breakage; the concrete symptom is that changing `Theme.space.widget_gap` visibly moves `TablePanel` and does nothing to `GrindView`.

### 5. Gameplay magic numbers that belong in `data/`

`data/constants.lua` already has the right homes: `GAMEPLAY` (:119-139, bankroll / focus / caps), `POKER` (:145-149, deal timings), `SAVE` (:153-157), `FLOAT` (:161-163). `data/balance.lua` adds pacing inputs. Most tuning values are in one of them. The exceptions below are all balance-affecting.

**High — `models/outcome_math.lua:67` and `models/Table_legacy.lua:159` both declare `WC_ABSOLUTE_CAP = 0.95`, independently.**
```lua
-- models/outcome_math.lua:67
local WC_ABSOLUTE_CAP = 0.95   -- final WC ceiling regardless of fill/shifts
OutcomeMath.WC_ABSOLUTE_CAP = WC_ABSOLUTE_CAP
-- models/Table_legacy.lua:159  (byte-identical line, including the comment)
local WC_ABSOLUTE_CAP = 0.95   -- final WC ceiling regardless of fill/shifts
```
This is precisely the `PROTOTYPE_MODE` dual-model hazard the brief warns about, made worse by the value being copy-pasted rather than shared. `models/MttSession.lua:170` reads `OutcomeMath.WC_ABSOLUTE_CAP`; `models/Table.lua:109` documents that it delegates to OutcomeMath. So the *live* (`PROTOTYPE_MODE = false`) build has one source of truth and the legacy/itch build has a second, private copy. Cost: the hard ceiling on win chance — a headline balance number — silently diverges between builds the moment anyone tunes it, and the tuner has no reason to suspect a second copy exists. It should be `Constants.GAMEPLAY.WC_ABSOLUTE_CAP` or at minimum `Table_legacy` should require it from `outcome_math`.

**Medium — `models/shove_rate.lua:41` `local R1_DISPLAY_CAP = 0.99`.** A balance ceiling on the game's headline number (the SHOVE %), living as a file-local in a model rather than in `data/constants.lua`. Well-commented (:36-40), which is why this is Medium not High, but it is a number a designer will want to tune and will not find by reading `data/`.

**Medium — `models/MttSession.lua:243` `local SAFETY_BB = 3` declared *inside a function body*.**
```lua
-- 10bb-turbo scale: low enough that filler hands can still roll
-- medium, high enough that the player never projects onto the felt.
local SAFETY_BB      = 3       -- min remaining bb before downgrading filler losses
```
Its own comment ties it to the turbo stack size (`gtype.starting_stack_bb`, read on line 240 from `data/game_types.lua`). So it is a derived balance constant scoped to a game type, hardcoded as a scalar inside a loop's enclosing function. Cost: adding a non-turbo tournament game type with a 100bb stack silently keeps `SAFETY_BB = 3`, and the bust-pacing plan the whole function exists to build goes wrong in a way that only shows up as a skewed finish distribution. Belongs as a `safety_bb` field on the game-type entry in `data/game_types.lua`, next to `starting_stack_bb`.

**Medium — `controllers/GrindController.lua:359` — an un-named balance formula inline in a controller.**
```lua
if self.ctx and self.ctx.earnings_scale_by_bankroll then
    local br = self.game.state.bankroll or 0
    r.delta = r.delta * (1.0 + math.log10(br + 1) * 0.1)
end
```
The `0.1` is the entire strength of the Bank capstone upgrade, and `math.log10` is its entire curve. Neither is in `data/`. Cost: buffing the capstone means editing controller code, and the effect entry in `data/effects.lua` that declares `earnings_scale_by_bankroll` carries no value at all — the data says "this upgrade exists", the controller secretly owns how strong it is. Every other effect kind carries its magnitude as `value` on the data entry; this one does not.

**Low — `models/Table.lua:786` / `models/Table_legacy.lua:810` — `self.state_timer >= 0.4` inline.** The settling-beat duration, a felt-timing value, hardcoded in both models while every sibling timing (`CARD_DEAL_INTERVAL`, `RUNOUT_PAUSE`, `CHEAT_REVEAL_PAUSE`) sits in `Constants.POKER:145-147`. Same dual-model mirror hazard.

**Low — `models/Table.lua:675-683` and `models/Table_legacy.lua:710-718` — six feedback-decay rates duplicated verbatim.**
```lua
local SHAKE_DECAY_RATE        = 1.2
local VIGNETTE_DECAY_RATE     = 1.2
local BORDER_PULSE_DECAY_RATE = 1.0
local LIFT_RISE_RATE       = 6.0    -- ~0.3 s up
```
`data/feedback_intensity.lua` exists and is the obvious home. Presentation tuning rather than balance, hence Low, but it is four more values that must be mirrored across the two models.

**Low — `controllers/GrindController.lua:1439` `local PALETTE_MAX_CHIPS = 60`.** A render budget in a controller; `data/chips.lua` is the home.

**Not defects:** `models/HandEval.lua:20-28` (hand-rank ordinals — these are poker's rules, not tuning), `models/Cursor.lua:24-26` (autoclicker feel constants, single-owner, but `data/constants.lua` would be tidier), `models/payout_breakdown.lua:63 EPS = 1e-9` (float epsilon), `states/TitleState.lua:23-25` (layout, belongs in Theme not data).

### 6. Structural duplication and drift across `data/`

Four data files key off the stake ladder and none of them agrees on how many stakes exist. `data/stakes.lua` is the master list with **10** entries (`s001`..`s010`).

| File | Keyed by | Entries | Covers | Drift |
|---|---|---|---|---|
| `data/stakes.lua` | `id` | **10** (`s001`-`s010`) | master | — |
| `data/chips.lua` `stake_palettes` | stake_id | **10** | `s001`-`s010` | in sync |
| `data/stake_themes.lua` | stake_id | **6** | `s001`-`s006` | **4 stakes unstyled** |
| `data/bankroll_tiers.lua` | `threshold` | 9 rows, labels `Sub-T1`,`T1`-`T8` | up to $10M | **2 stakes unlabelled** |

**Medium — `data/stake_themes.lua` covers 6 of 10 stakes; the top 4 fall back to the default palette.** Consumed at 9 call sites (`views/TablePanel.lua:251,599,685,967,1396,1449`, `controllers/GrindController.lua:1581,1674`, `views/PokerEventAnims.lua:237`), each doing a bare `StakeThemes[tbl.stake_id]` with a nil-fallback. The file's own header says "T1 should look cheap and dim; T6 should look like the Bellagio. Climbing stakes is a visible upgrade" — and then NL1M / NL10M / NL100M / ULTRA, the four most prestigious tables in the game, render in the *default* Theme chrome, i.e. visually identical to each other and less distinguished than NL100K. Cost: the entire stated purpose of the file inverts at the top of the ladder. The nil-fallback is why nothing errors. Since `data/chips.lua` managed to keep 10 entries in sync, this is a maintenance miss, not a design decision.

**Medium — `data/bankroll_tiers.lua` stops two stakes short, and its header comment is now false.**
```lua
-- T1..T6 thresholds match the existing data/stakes.lua buy-ins (1:1 with
-- the stakes the player has unlocked the ability to sit at). T7+ extend
-- the curve past the stakes ladder ...
    { threshold = 1000000,  mult = 7, label = "T7"     },
    { threshold = 10000000, mult = 8, label = "T8"     },
```
`T7`/`T8` are described as extending "past the stakes ladder", but `s007` buy_in = $1,000,000 and `s008` = $10,000,000 — those two rows are now *on* the ladder, not past it, and `s009` ($100M) and `s010` ($100B, ULTRA) have no row at all. Cost: (a) `models/shove_rate.lua:48-62 lookupBracket` walks to the highest row ≤ bankroll, so the shove-rate multiplier flatlines at 8× for every bankroll above $10M — the entire Act 3 range where the file says "endgame grinding past $1M still pushes shove rate upward" is exactly where it stops pushing; (b) the tier badge shown in the SHOVE breakdown reads "T8" for a player sitting at ULTRA, contradicting the stake name on their own table. Verified safe on the nil-upper edge: `models/shove_rate.lua:70 interpolateMult` opens `if not upper then return lower.mult end`, so the top row does not crash — it just plateaus, which is the drift described above rather than a bug.

**Low — the four-tier name list `{small, medium, large, jackpot}` is re-typed in 8 data files.** `data/stakes.lua:43,70+`, `data/decks.lua:83,109,111`, `data/catalog.lua:864`, `data/game_types.lua:108,109,131,132`, `data/effects.lua:77,138,148,173,307,312`, `data/chips.lua:30`, `data/sounds.lua:47`, `data/pot_tiers.lua:12-15`. `data/pot_tiers.lua` calls itself "single source of truth for the four tiers", and it is for the *magnitudes*, but the *key set* is duplicated everywhere as bare table keys. Adding a fifth tier means editing 8 data files plus `models/outcome_math.lua`'s `TIER_KEYS`/`TIER_INDEX` plus the chain at `models/MttSession.lua:297`. This is inherent to Lua table literals and not really fixable without a validation pass; noting it as the concrete cost of the tier-set being implicit. A boot-time assert that every `win_dist`/`loss_dist`/`shift` table has exactly the `pot_tiers` keys would catch a typo'd `jackpo = 0.02` that today silently sums a distribution to 0.98.

**Not duplication:** `data/pot_tiers.lua` (magnitudes in bb) and `data/stakes.lua` `win_dist`/`loss_dist` (probabilities over those tiers) encode genuinely different things and are correctly separated. `data/stake_themes.lua` (chrome per stake) vs `data/chips.lua` `stake_palettes` (denomination indices per stake) are also distinct concerns despite both keying on stake_id — but they are the pair most likely to drift together, and already have.

### Summary counts

| Metric | Count |
|---|---|
| Function definitions in `data/` | **3** (all `data/balance.lua`) |
| Imperative loops mutating data at load in `data/` | **3** (`catalog.lua:999,1007,1014`) |
| `data/` files that are pure tables | 29 / 31 |
| Kind-chains that should be registries | **4** (2 in `data/`, 2 in views/controllers) |
| `love.graphics.setColor(<numeric>)` in project code | **10** (rule says 0) |
| `Theme.setColor({literal})` | **43** (37 in `views/CatalogModal.lua`) |
| The literal `0.15, 0.15, 0.12` | **38**, all in `views/CatalogModal.lua` |
| Registries with loud unknown-key handling | 5 / 7 |
| Data kinds used but unregistered | **0** (verified across 88 kinds) |
| Balance constants duplicated across the Table/Table_legacy split | **8** (`WC_ABSOLUTE_CAP`, 4 decay rates, settling 0.4, 2 caps) |
| Stake ladder entries by file | 10 / 10 / **6** / **9** |

---

## Rule 4 — Engine-agnostic infrastructure (liftability)

The rule: `core/`, `lib/`, `utils/`, `services/`, and `controllers/StateMachine.lua`
must be liftable verbatim into the next idle game. They must not know this is a
poker game.

**Verdict: `core/`, `lib/`, and `utils/` pass. `services/` fails, in four
distinct ways.** The engine that would actually lift is 507 lines; the 3,088-line
`services/` layer that does the real infrastructure work is entangled with the
game.

### Hard leaks — the API or behaviour is poker-shaped

**Critical — `services/CursorPool.lua` breaks liftability three ways at once.**

```lua
-- services/CursorPool.lua:21-22
local Cursor       = require("models.Cursor")
local Theme        = require("views.Theme")
```

A service requiring a **model** and a **view**. Both are inversions: the engine
layer reaches upward into the two layers most specific to this game. Neither
`models/Cursor.lua` nor `views/Theme.lua` can come along on a lift without
dragging its whole layer's conventions.

Worse, the service hardcodes this game's *catalog perks* into its targeting:

```lua
-- services/CursorPool.lua:74-82
local rebuy_unlocked = ctx and ctx.cursor_rebuy_unlocked
...
    if hb.action == "deal" and not hb.cursor_muted and hb.idx then
        deal_hbs[hb.idx] = hb
    elseif rebuy_unlocked and hb.action == "rebuy"
           and not hb.cursor_rebuy_muted and hb.idx then
```

`"deal"`, `"rebuy"`, and `cursor_rebuy_unlocked` are poker concepts and a
specific purchasable item. The next game has no deal and no rebuy, so this
function is not liftable — it is rewritten. Its own header comment claims
otherwise: *"could be parameterized later. No knowledge of poker."* It has
knowledge of poker on line 78.

**Fix:** the caller passes the set of claimable action names —
`CursorPool.update(ctx, hit_boxes, claimable_actions)` where the game supplies
`{ deal = true, rebuy = rebuy_unlocked }`. Two-line change; makes the file
genuinely neutral.

**High — `services/HandAnalytics.lua` is a poker file in the services folder.**

Every identifier in its persisted schema is poker: `shove_count`, `shoves`,
`shove_rate`, `gauntlet_result`, `bankroll`, `chips_earned`. It hardcodes a
product-specific marker string:

```lua
-- services/HandAnalytics.lua:25
local ANALYTICS_MARKER = "@@POKERIDLE_ANALYTICS@@"
```

and pulls game config from inside a function body:

```lua
-- services/HandAnalytics.lua:59-61
local Constants = require("data.constants")
_enabled = Constants.DEBUG.HAND_ANALYTICS
```

A lazy `require` inside a function is also the only one of its kind in the
services layer — every other service requires at file scope. It hides the
dependency from anyone reading the header.

**Fix:** this file is not a service. Either move it to `models/RunAnalytics.lua`,
or make it a generic `services/RunLog.lua` that takes `{ marker, run_key, fields }`
from the caller and knows none of the field names. The former is one `git mv`;
the latter is the version that pays off on the next lift.

**Medium — `services/PokerEventRegistry.lua` is named for poker.** The rule
explicitly says infrastructure names must describe what the thing *does*, not
what it does for poker (`EffectsRegistry`, not `PokerStatBuilder`). The file's
own line 12 comment reads *"Engine-agnostic: knows nothing about poker"* — under
a filename that does. The body genuinely is neutral, so this is a rename:
`services/EventKindRegistry.lua`. The name is the only violation, and it is a
pure code-internal rename, so it is free under the back-compat rule.

**Medium — `services/DenominationBreakdown.lua` hardcodes tuning data.**

```lua
-- services/DenominationBreakdown.lua:38-43
function DenominationBreakdown.tierFromUnit(magnitude)
    if magnitude < 5  then return "small"    end
    if magnitude < 18 then return "medium"   end
    if magnitude < 80 then return "large"  end
    return "jackpot"
end
```

The thresholds `5 / 18 / 80` are balance numbers and `small/medium/large/jackpot`
are this game's tier vocabulary, both living in a service. Retuning a tier
boundary means editing engine code rather than `data/`, which is also a rule 3
violation. The header comment concedes it: *"Thresholds match the unit
conventions in the consuming data file's tier table"* — a coupling maintained by
hand across two files with nothing enforcing it.

**Fix:** take the ladder as a parameter, sourced from `data/chips.lua` alongside
`tier_chip_target`, which the same function signature already accepts from the
caller.

### Inverted layering — services depending on views

Three services require `views.Theme`:

| File | Line |
|---|---|
| `services/CursorPool.lua` | 22 |
| `services/SpriteRenderer.lua` | 11 |
| `services/Tooltip.lua` | 12 |

`views/Theme.lua` is 75 lines and is genuinely infrastructure — a palette
accessor. Its placement in `views/` is what makes these three look like
violations. **The cheapest correct fix is to move `Theme.lua` to `services/`
(or `core/`) and leave the requires alone.** That converts three layering
violations into zero with one file move and an import rewrite, and it makes the
theme system liftable, which it currently is not.

### `services/` is a second view layer

Nine files in the engine layer issue `love.graphics` calls:

| File | `love.graphics` calls |
|---|---:|
| `services/ShaderRegistry.lua` | 9 |
| `services/CursorPool.lua` | 9 |
| `services/Tumble.lua` | 7 |
| `services/Tooltip.lua` | 7 |
| `services/Confetti.lua` | 6 |
| `core/camera.lua` | 4 |
| `services/SpriteRenderer.lua` | 3 |
| `services/FontService.lua` | 3 |
| `services/SpriteLoader.lua` | 2 |

Some of these are legitimate — `ShaderRegistry`, `FontService`, `SpriteLoader`,
and `SpriteRenderer` are renderer plumbing and `core/camera` is a transform, all
of which necessarily touch the graphics API. But `CursorPool`, `Tumble`,
`Tooltip`, and `Confetti` contain actual draw code: they decide what a thing
looks like. That is the view layer's job, and it means a lift of `services/`
carries this game's visual decisions with it. It is also why `services/` needed
to require `views.Theme` in the first place — the two problems are the same
problem.

### Construction style is not standardised

Of 28 services, **only 6 have a constructor** — the four registries
(`EffectsRegistry`, `PokerEventRegistry`, `UnlockRegistry`, `XpRuleRegistry`)
plus `SaveService` and partially `SpriteRenderer`. The other 22 are module
tables, and **14 of them hold mutable module-level state**:

| Service | `local _state` fields |
|---|---:|
| `services/HandAnalytics.lua` | 5 |
| `services/SoundService.lua` | 4 |
| `services/Tooltip.lua` | 3 |
| `services/AnchorRegistry.lua` | 2 |
| `services/CursorPool.lua` | 2 |
| `services/FlightSystem.lua` | 2 |
| `services/Pop.lua` | 2 |
| `ClickFlash`, `FloatingTextSystem`, `Ghosts`, `HoverService`, `RollingValue`, `ShaderRegistry`, `SpriteRenderer` | 1 each |

Rule 1 says no globals and no service locators. A `require`d module holding
mutable state that any caller can reach is a global with an import statement in
front of it — it is the thing the rule exists to prevent, and it is the majority
idiom in `services/`. `main.lua` is clean of `Game.` leaks, so rule 1 passes its
own audit grep, but the pattern it forbids has reappeared one layer down.

The concrete cost is not theoretical: state that lives on a module survives a
state transition and a prestige reset unless something explicitly clears it, and
nothing enforces that a new service provides a `clear()`. `FloatingTextSystem`
has one; `Pop`, `Ghosts`, and `ClickFlash` need checking for the same.

Two idioms coexist and nothing tells a future contributor which to pick. Pick
one — DI instances constructed in `main.lua`, matching the four registries — and
convert the rest as they are touched.

### Lift-readiness by directory

| Directory | Lines | Score | Justification |
|---|---:|:---:|---|
| `core/` | 88 | **A** | `camera`, `event_bus`, `time`. Zero poker vocabulary. `camera.lua` touches `love.graphics` unavoidably. Lifts as-is. |
| `lib/` | 290 | **A** | `class`, `input_dispatcher`, `json`. Fully generic. Lifts as-is. |
| `utils/` | 129 | **A−** | `format`, `lookups`, `rng`, `sample_set`. Neutral. Only comments mention poker data files, and comments are cheap to fix. |
| `controllers/StateMachine.lua` | 108 | **A** | No poker references. Lifts as-is. |
| `services/` | 3,088 | **C** | Four hard leaks, three inverted view dependencies, four files carrying draw code, no construction standard. Roughly 20 of 28 files would lift cleanly; the remaining 8 are the ones doing the most work. |

### Ordered fix list — cheapest first, biggest liftability gain per unit of work

1. **Move `views/Theme.lua` to `services/Theme.lua`.** One move, three requires rewritten. Removes every services-to-views dependency and makes the theme system liftable. Pure code-internal rename, so no save impact.
2. **Rename `services/PokerEventRegistry.lua` to `services/EventKindRegistry.lua`.** One move plus its requires. Removes the naming violation entirely.
3. **Parameterise `CursorPool`'s claimable actions.** Two lines; removes the poker knowledge from the targeting loop.
4. **Move `models/Cursor.lua` into the service, or invert it** so `CursorPool` receives a factory. Removes the last services-to-models require.
5. **Relocate `HandAnalytics` to `models/RunAnalytics.lua`.** Stops pretending it is infrastructure.
6. **Pass the tier ladder into `DenominationBreakdown` from `data/chips.lua`.** Fixes a rule 3 and a rule 4 violation in the same edit.
7. **Move the draw code out of `CursorPool`, `Tumble`, `Tooltip`.** The largest job; do it when those files are next touched, not as a dedicated pass.
8. **Standardise construction on DI instances.** Ongoing; convert on contact.

Steps 1-6 total a few hours and would move `services/` from C to roughly B+.
Step 7 is what would make it an A, and it is the one that can wait.

---

## God-file deep dive — `views/GrindView.lua` + `controllers/GrindController.lua`

Scope: `views/GrindView.lua` (2455 lines), `controllers/GrindController.lua` (1800 lines),
`states/GrindState.lua` (512 lines). Cross-checked against `views/TablePanel.lua`,
`views/ShoveView.lua`, `views/RoomView.lua`, and the prior audit
`docs/aug2026 audit kimi k3.md`.

### 1. Structural map

Line counts are `end` line minus `function` line, inclusive. `[!]` = over 60 lines.
`[N]` = more than 4 levels of control nesting inside the body.

#### `views/GrindView.lua` — 2455 lines, 57 functions (incl. 6 nested locals)

| Lines | N | Function | Purpose |
|---|---|---|---|
| 59-61 | 3 | `stakeVisible` (local) | delegate to `controller:stakeAvailable` |
| 119-238 | 120 [!] | `recomputeLayout` (local) | recompute ~20 file-local layout upvalues from W/H/fonts |
| 187-191 | 5 | `cellW` (nested) | max(label,value) width + pad |
| 242-262 | 21 | `GrindView:new` | ctor; seeds 4 tween fields |
| 267-272 | 6 | `tweenNumber` (local) | lerp helper |
| 274-302 | 29 | `:_buildPanels` | build left/right `Panel` + register tabs |
| 310-406 | 97 [!][N] | `:_makeGameTypeStrip` | game-type sub-tab strip as one `custom` component (blurb table + `draw_fn` + `hit_fn`) |
| 408-579 | 172 [!][N] | `:_buildTablesTabComponents` | ADD TABLE rows: EV, bounty badge, cursor action strip, tooltips |
| 582-588 | 7 | `catalogName` (local) | id to display name, linear scan of Catalog |
| 597-601 | 5 | `_cell` (local) | "MAX"/"+N%"/"-" |
| 603-608 | 6 | `_capped` (local) | is fill past a stake's window? |
| 611-641 | 31 [N] | `_winChanceRows` (local) | win-chance tooltip grid (`OutcomeMath.buildOutcome` 2x/stake) |
| 646-706 | 61 [!][N] | `_stackRateRows` (local) | per-mode stack-rate grid (`buildOutcome` 2x per stake per gtype) |
| 716-722 | 7 | `_blurbRow` (local) | IconText tooltip row |
| 729-761 | 33 | `:_buildRangeTooltip` | blurb + range grid; shallow-copies ctx |
| 763-868 | 106 [!][N] | `:_buildUpgradesTabComponents` | UPGRADES rows + the `box_of_mice` global cursor toggles |
| 872-1106 | **235** [!][N] | `:update` | 11 unrelated concerns (see section 2 note) |
| 1114-1117 | 4 | `moneyText` (local) | hybrid exact/abbrev |
| 1119-1122 | 4 | `chipsText` (local) | |
| 1136-1161 | 26 | `drawStatCell` (local) | label-over-value cell + optional pop scale |
| 1166-1256 | 91 [!] | `:_drawDeckCell` | deck card-back sprite + shader + border + level badge |
| 1258-1468 | **211** [!][N] | `:_drawTopBar` | whole top bar: bankroll, tied, total, chip, achip, shove, deck, tables, focus |
| 1418-1432 | 15 | `popText` (nested) | scale-about-center print |
| 1476-1481 | 6 | `:_topBarBtnW` | |
| 1483-1492 | 10 | `:_cashOutButtonRect` | |
| 1494-1514 | 21 | `:_drawCashOutButton` | |
| 1523-1525 | 3 | `:_catalogButtonVisible` | |
| 1527-1536 | 10 | `:_catalogButtonRect` | |
| 1538-1550 | 13 | `:_drawCatalogButton` | |
| 1554-1563 | 10 | `:_roomButtonRect` | |
| 1565-1580 | 16 | `:_drawRoomButton` | |
| 1584-1593 | 10 | `:_settingsButtonRect` | |
| 1595-1606 | 12 | `:_drawSettingsButton` | |
| 1610-1618 | 9 | `:_helpButtonRect` | |
| 1623-1636 | 14 | `:_drawHelpButton` | prototype-only |
| 1655-1686 | 32 [N] | `bestGridLayout` (local) | O(n) search for best 4:3 cell |
| 1691-1702 | 12 | `:_quickResetButtonRect` | |
| 1704-1772 | 69 [!] | `:_drawCenterGrid` | empty state + freeze cache + tile loop |
| 1776-1784 | 9 | `:_shoveButtonRect` | |
| 1793-1801 | 9 | `:_houseRect` | |
| 1804-1810 | 7 | `:_houseHelpBtnRect` | |
| 1813-1819 | 7 | `:_houseInfoBtnRect` | |
| 1821-1880 | 60 | `:_drawHouse` | procedural poster + house glyph + "?" / "i" badges |
| 1887-1909 | 23 | `:_drawShoveButton` | |
| 1911-2000 | 90 [!][N] | `:_drawShoveFace` | SHOVE button face + rate + chip/achip badges |
| 2014-2074 | 61 [!][N] | `:_drawFloatingText` | multi-line stroked floater renderer |
| 2019-2024 | 6 | `resolveToken` (nested) | token to Theme color, re-created per frame |
| 2083-2109 | 27 | `:_drawBankrollChips` | bankroll pile place/sync/draw |
| 2116-2175 | 60 | `:draw` | composite orchestrator |
| 2179-2315 | 137 [!] | `:mousepressed` | 11 sequential rect tests + 2 panel routes + hit_box loop |
| 2317-2371 | 55 | `:_handleSidebarButton` | id string-prefix parse chain |
| 2337-2342 | 6 | `scopeOf` (nested) | |
| 2384-2413 | 30 | `:_handleHitBox` | flash + ghost + registry dispatch |
| 2415-2418 | 4 | `:mousereleased` | |
| 2425-2436 | 12 | `:mousemoved` | freeze deadzone |
| 2438-2445 | 8 | `:wheelmoved` | |
| 2451-2453 | 3 | `:resize` | |

#### `controllers/GrindController.lua` — 1800 lines, 63 functions

| Lines | N | Function | Purpose |
|---|---|---|---|
| 33-35 | 3 | `bountyKey` (local) | `stake:gtype` |
| 40-55 | 16 | `:new` | ctor, builds ctx then pool |
| 61-82 | 22 | `_multSuffix` (local) | "Pot $X xN" floater suffix — presentation math in a controller |
| 87-98 | 12 | `:_queueBurst` | |
| 104-112 | 9 | `:_queueScatter` | |
| 116-120 | 5 | `:drainBursts` | |
| 124-133 | 10 | `:invalidateEffects` | recompute ctx; latches `ultra_unlocked` |
| 139-141 | 3 | `:tableSlotsCap` | |
| 146-161 | 16 | `:currentFocusMult` | |
| 173-176 | 4 | `:currentFocusCapacity` | |
| 178-810 | **633** [!][N] | `:update` | see section 2 |
| 815-822 | 8 | `:_grantDeckXp` | |
| 832-838 | 7 | `:_requirementMet` | |
| 843-853 | 11 | `:bountyBanked` | |
| 855-859 | 5 | `:antiBountyBanked` | |
| 865-871 | 7 | `:bountyAward` | |
| 873-877 | 5 | `:antiBountyAward` | |
| 879-938 | 60 [!] | `:buyRunUpgrade` | cost math + purchase + analytics + XP + counters |
| 943-945 | 3 | `:getRunUpgradeLevel` | |
| 953-971 | 19 | `:getRunUpgradeMaxLevel` | dynamic fill-scaled cap |
| 973-988 | 16 | `:getRunUpgradeNextCost` | duplicate of the cost block inside `buyRunUpgrade` |
| 999-1011 | 13 | `:buyInMultFor` | |
| 1014-1021 | 8 | `:_cheapestBuyIn` | |
| 1024-1029 | 6 | `:_noLiveTables` | |
| 1031-1037 | 7 | `:wouldStrandRun` | |
| 1045-1054 | 10 | `:shoveUnlocked` | |
| 1058-1063 | 6 | `:isStranded` | |
| 1072-1082 | 11 | `:canQuickReset` | |
| 1088-1096 | 9 | `:quickReset` | |
| 1101-1110 | 10 | `:peelCatalogSticker` | |
| 1112-1135 | 24 | `:buyCatalogItem` | |
| 1137-1146 | 10 | `:corruptCatalogItem` | |
| 1155-1161 | 7 | `:stakeAvailable` | |
| 1166-1187 | 22 | `:addTable` | |
| 1198-1215 | 18 | `:tiedUp` | called about 5x/frame from the view |
| 1227-1242 | 16 | `:_finalizeRemove` | |
| 1244-1254 | 11 | `:removeTable` | |
| 1258-1265 | 8 | `:cashOutAll` | |
| 1271-1288 | 18 | `:changeTableStake` | |
| 1292-1298 | 7 | `:toggleCursorMute` | |
| 1304-1310 | 7 | `:toggleCursorRebuyMute` | |
| 1317-1320 | 4 | `tableMatches` (local) | |
| 1324-1334 | 11 | `:cashOutType` | |
| 1340-1350 | 11 | `:typeCursorState` | |
| 1355-1365 | 11 | `:setTypeCursorMute` | |
| 1367-1377 | 11 | `:setTypeCursorRebuyMute` | |
| 1382-1401 | 20 | `:dealHand` | |
| 1406-1409 | 4 | `:_playNamed` | |
| 1422-1424 | 3 | `_paletteForStake` (local) | |
| 1441-1451 | 11 | `_paletteForAmount` (local) | |
| 1456-1459 | 4 | `:_offscreenAnchor` | |
| 1461-1463 | 3 | `_anchor` (local) | |
| 1475-1497 | 23 | `:_emitDealChips` | dead under `POKER_THEATER` (see section 7) |
| 1499-1516 | 18 | `:_emitBuyInChips` | |
| 1518-1535 | 18 | `:_emitCashOutChips` | near-identical to `_emitBuyInChips` |
| 1540-1562 | 23 | `:_emitMttPayoutChips` | near-identical again |
| 1564-1651 | 88 [!][N] | `:_emitResolutionChips` | win/loss/overflow bursts |
| 1667-1679 | 13 | `:_emitAmountExplosion` | |
| 1687-1694 | 8 | `:rebuyCostFor` | |
| 1699-1744 | 46 | `:rebuyTable` | |
| 1750-1767 | 18 | `:_playStateTransitionSound` | |
| 1775-1783 | 9 | `:initiateShove` | |
| 1787-1798 | 12 | `:dealAll` | |

#### Worst 15 by complexity across both files

| # | Function | Lines | Max nesting | Distinct concerns |
|---|---|---|---|---|
| 1 | `GrindController:update` 178-810 | 633 | 7 | 14 |
| 2 | `GrindView:update` 872-1106 | 235 | 5 | 11 |
| 3 | `GrindView:_drawTopBar` 1258-1468 | 211 | 4 | 9 cells + 3 rect stashes |
| 4 | `GrindView:_buildTablesTabComponents` 408-579 | 172 | 5 | 6 |
| 5 | `GrindView:mousepressed` 2179-2315 | 137 | 3 | 11 routes |
| 6 | `recomputeLayout` 119-238 | 120 | 3 | 5 |
| 7 | `GrindView:_buildUpgradesTabComponents` 763-868 | 106 | 5 | 4 |
| 8 | `GrindView:_makeGameTypeStrip` 310-406 | 97 | 5 | 3 |
| 9 | `GrindView:_drawDeckCell` 1166-1256 | 91 | 3 | 5 |
| 10 | `GrindView:_drawShoveFace` 1911-2000 | 90 | 3 | 4 |
| 11 | `GrindController:_emitResolutionChips` 1564-1651 | 88 | 3 | 3 |
| 12 | `GrindView:_drawCenterGrid` 1704-1772 | 69 | 4 | 3 |
| 13 | `GrindView:_drawFloatingText` 2014-2074 | 61 | 4 | 3 |
| 14 | `_stackRateRows` 646-706 | 61 | 4 | 2 |
| 15 | `GrindController:buyRunUpgrade` 879-938 | 60 | 3 | 5 |

The top three functions are 1079 lines — 25% of both files combined.

Note on the prior audit's numbers: it recorded `GrindView:_drawTopBar` at 160 lines
and `_buildTablesTabComponents` at 174. Today they are 211 and 172. The 207-line
`iconRow` figure in the task brief is a mis-attribution — the nested `iconRow`
closure at 907-916 is 10 lines; what spans ~200 lines from there is the rest of
`GrindView:update`'s tooltip block (907-1075).

### 2. `GrindController:update(dt)` dissected — lines 178-810 (633 lines)

Fourteen distinct concerns are interleaved. Six of them mutate `game.state`
directly, three mutate per-table view-FX flags, two do string formatting, one
does analytics I/O, one does audio dispatch. Nothing between them is ordered by
necessity except the first two.

#### A. Pre-tick state snapshot — 179-184

```lua
local prev_states = {}
for i, t in ipairs(self.pool.tables) do
    prev_states[i] = t.state
end
```
Reads: `pool.tables[i].state`. Writes: a fresh table every frame (see section 8).
Exists solely to feed concern C.

#### B. Pool tick — 186

`local resolutions = self.pool:update(dt, self.ctx)` — the only line in the
function that is actually "update the model". `r.table_idx` is stamped **here**,
by index, and that index is consumed 200+ lines later at 389. See section 4 C1.

#### C. Transition sounds — 188-196
Reads `prev_states`, `t.state`. Calls `_playStateTransitionSound` which reads
`t.outcome_tier` / `t.outcome_won`. Pure audio. No state writes.

#### D. Deferred buy-in chip bursts — 198-208
```lua
if t._pending_buyin
   and AnchorRegistry.get(TableModel.anchorKey(t, "you"))
   and AnchorRegistry.get("bankroll") then
    self:_emitBuyInChips(t, t._pending_buyin)
    t._pending_buyin = nil
```
Reads AnchorRegistry (a *view-written* registry) inside the controller. Writes
`t._pending_buyin`, pushes onto `pending_bursts`. Concern: view-readiness polling.

#### E. Deferred table close — 210-218
Reverse loop; calls `_finalizeRemove(i)` which mutates `state.bankroll`, calls
`pool:removeTable` (index-shifting `table.remove`) and `invalidateEffects()`
(rebuilds `self.ctx`). **This runs after B stamped `r.table_idx`.**

#### F. MTT payout drain — 220-340 (121 lines)
The single largest sub-block. Six nested sub-concerns:

| Lines | Sub-concern | State touched |
|---|---|---|
| 223-237 | drain + win classification | `t.mtt:drainPayout()`, `t.mtt.hands_won`, `t.mtt.last_finish`, `gtype.chip_stack_table`, `gtype.binary_outcome`, AnchorRegistry `center` |
| 238-241 | bankroll credit + burst | `state.bankroll`, `pending_bursts` |
| 242-256 | analytics | `HandAnalytics.recordHand` (7-field table alloc) |
| 258-308 | **chip bounty banking** | `state.total_mtt_wins`, `state.stakes_won_this_run[key]`, `state.hands_since_last_bank`, `state.first_bounty_this_run`, `state.chips_this_run`, `state.lifetime_chips_banked`, `state.total_chips_banked`, `state.denied_copied_this_run`, `state.total_denied_stacks` |
| 310-321 | table view-FX flags | `t.shake_trauma`, `t.vignette_kind`, `t.vignette_alpha`, `t.border_pulse_t`, `t.border_pulse_color`, `t.glow_t`; `_emitAmountExplosion` |
| 322-338 | celebration floater + counter reset | `floating_text.emit`, `t.mtt.hands_won = 0` |

#### G. Early return — 342
```lua
if #resolutions == 0 then return end
```
Skips `self.pool:_syncStateList()` at 809. See section 4 C4.

#### H. Focus multiplier — 344-351
`r.delta = r.delta * focus_mult`. Reads `pool:count()`, `ctx.focus_penalty_*`.

#### I. Bankroll-log earnings capstone — 353-360
```lua
if self.ctx and self.ctx.earnings_scale_by_bankroll then
    local br = self.game.state.bankroll or 0
    r.delta = r.delta * (1.0 + math.log10(br + 1) * 0.1)
```
Reads live bankroll mid-loop, so resolution #2 in the same frame is scaled by the
bankroll resolution #1 just changed. Order-dependent by construction.

#### J. Once-per-run loss voids — 362-376
Writes `state.first_stack_loss_voided_this_run`, `state.first_loss_voided_this_run`.
Zeroes `r.delta`.

#### K. Stack / bankroll accounting — 378-432 (55 lines, the real money model)
Reads `pool.tables[r.table_idx]`, `stake.buy_in`, `state.shove_r2_won`,
`stake.band`, `ctx.bust_refund_pct`. Writes `tbl.stack`, `state.bankroll`,
`state.total_busts`, local `overflow_amount`, and clamps `r.delta`. Four branches
plus a defensive `else` fallback that routes to bankroll.

This is **model logic living in a controller** — the buy-in cap, the negative
clamp, the ultra-band bankroll bleed and the bust refund are all rules, not
routing.

#### L. Hand analytics + timestamp re-stamp — 434-459
Reads/writes `tbl._hand_start_t` (a field the *controller* invented on the model),
calls `love.timer.getTime()` twice, allocates an 11-field record.

#### M. Floater label formatting — 461-497 (37 lines)
Three format flavours + `_multSuffix`. Pure presentation: `string.format("+$%.2f")`,
`"%dbb"`, `"WIN"/"OUT"`, plus a `floater_opts_override` colour token. This is
view work sitting in the controller.

#### N. MTT tier ramp override — 499-513
```lua
local ramp = { "small", "small", "medium", "medium",
               "large", "large", "large", "large" }
r.tier    = ramp[n] or "large"
```
Rewrites the model's outcome tier for feedback purposes, and allocates the ramp
table on every binary-MTT win. Data-as-literal inside a controller (should be
`data/game_types.lua`).

#### O. Floater opts merge + emit — 515-548
Two full `pairs` copies of `intensity_for_floater.floater` (521-525 and 536-537),
an anchor lookup, and a drift-scale calculation. Emits.

#### P. Resolution chip bursts — 550-554
Delegates to `_emitResolutionChips(r, tbl, overflow_amount)` — the only clean seam
in the whole loop.

#### Q. Tier-scaled table FX + pulse SFX — 556-594
Writes `tbl.shake_trauma`, `tbl.vignette_kind`, `tbl.vignette_alpha`,
`tbl.border_pulse_t`, `tbl.border_pulse_color`, `tbl.glow_t`,
`tbl.pot_explode_pending`. Plays `border_pulse_win|loss`. Duplicates F's 310-321
block almost verbatim.

#### R. Cash chip-bounty banking — 596-672 (77 lines)
Structurally a copy of F's 258-308 with the MTT-specific bits swapped. Writes the
same nine `state.*` fields plus a `{chip}` floater. Also bumps
`state.hands_since_last_bank` at 615 *outside* the branch.

#### S. Anti-chip bounty banking — 674-698
Third copy of the same bank/deny shape. Writes
`state.anti_stakes_won_this_run[key]`, `state.anti_chips_this_run`,
`state.hands_since_last_bank`.

#### T. Ungated meta counters — 700-742 (43 lines)
Writes `state.total_hands_played`, `total_big_outcomes`, `total_jackpots`,
`total_stack_losses`, `run_money_lost`, `total_hands_at_4plus`,
`total_hands_overwhelmed`, `total_hands_by_gtype[gtype_id]`, `highest_stake_idx`.
Nine independent counters, no dispatch table.

#### U. Deck-system meta + XP + unlocks — 744-802 (59 lines)
Writes `lifetime_hands_played`, `lifetime_money_won`, `lifetime_money_lost`,
`lifetime_jackpot_count`, `lifetime_mtt_hands_won`,
`lifetime_hands_at_4plus_tables`, `lifetime_hands_overwhelmed`. Calls
`_grantDeckXp` (which can `invalidateEffects()` **mid-loop**, replacing `self.ctx`
that concerns H/I/J/K already read for earlier resolutions), then
`Decks.checkPendingUnlocks` (can `invalidateEffects()` again).

#### V. Save-list resync — 805-809
`self.pool:_syncStateList()`. Unreachable when G returned early.

#### Concern-to-layer summary

| Concern | Belongs in |
|---|---|
| A, B, C | controller (tick + audio) |
| D, P | chip-emission service/controller |
| E | table-lifecycle controller |
| F(258-308), R, S | a **BountyModel** (pure state math) |
| F(310-321), Q | a **TableFxService** (view impulses) |
| H, I, J, K | a **PayoutModel** (money rules) |
| L | analytics service |
| M, N, O | **view** (floater presentation) |
| T, U | a **MetaCounters / progression model** |
| G, V | controller |

### 3. Concrete decomposition plan

#### Where I agree and disagree with the prior audit (`docs/aug2026 audit kimi k3.md`)

The kimi seams were line-range cuts of the *file*, not of the *responsibilities*.
Four of the eight are still right; four are wrong today.

| Kimi seam | Verdict |
|---|---|
| `views/TopBar.lua` = GrindView 1114-1636 | **Agree**, but the range is now 1108-1636 and it must also carry the four `_*ButtonRect` pairs and the three `_*_cell_rect` hover blocks from `update` (999-1075), or the extraction leaves the rects orphaned in the parent. |
| `views/SidebarLeft.lua` = 310-579 | **Agree.** |
| `views/SidebarRight.lua` = 581-868 | **Agree**, but 581-711 (`_winChanceRows` / `_stackRateRows` / `RANGE_TOOLTIP`) is *outcome-model presentation*, not sidebar chrome. It should go to its own `views/UpgradeRangeTooltip.lua` so the sidebar file does not import `models.outcome_math`. |
| `views/ShovePanel.lua` = 1776-2000 | **Agree.** |
| `views/TableGrid.lua` = 1653-1772 | **Disagree on value.** That is 120 lines of already-cohesive code with one caller. Extracting it buys nothing while `update`/`draw` still hold everything else. Do it last or not at all. |
| `controllers/BountyController.lua` = 832-877 + 596-698 | **Disagree on layer.** Bounty banking is pure state arithmetic with zero input routing — it is a **model**, `models/bounties.lua`, not a controller. And the extraction must include the MTT copy at 258-308, which kimi missed; extracting only two of the three copies leaves the drift bug in place. |
| `controllers/CommerceController.lua` = 879-1146 | **Agree**, and the range is right. |
| `controllers/TableLifecycle.lua` = 1155-1409 | **Agree.** |
| `controllers/ChipEmitter.lua` = 1422-1679 | **Agree**, and this is the single highest-value cut in the controller: 258 self-contained lines, one dependency (`pending_bursts`), zero state reads. |
| "GrindView is big, not tangled — do it when the size hurts" | **Disagree.** `GrindView:update` at 235 lines is genuinely tangled: it mixes tween state, hover hit-testing, tooltip authoring for six regions, a 24-iteration bounty sweep, and the chip-burst drain. It has grown 211 lines since the audit precisely because there is nowhere else for new UI to land. |

#### New files

**Views** (render + hit-test only)

| New file | Moves | Approx lines | Seam (what crosses) |
|---|---|---|---|
| `views/grind/Layout.lua` | GrindView 64-238 (`recomputeLayout` + all layout upvalues), 1643-1686 (`bestGridLayout`, `PANEL_ASPECT`) | ~180 | `Layout.recompute(W,H,fonts,state)`; every consumer reads `Layout.TOP_BAR_H` etc. instead of file-locals. **This is the prerequisite for every other view cut** — today the layout constants are upvalues that six extracted files would each need. |
| `views/grind/TopBar.lua` | 1108-1256 (`moneyText`, `chipsText`, `drawStatCell`, `_drawDeckCell`), 1258-1468 (`_drawTopBar`), 1470-1636 (5 button rect/draw pairs), plus 999-1075 from `update` (the tied/shove/deck/workload tooltips) | ~520 | `TopBar.draw(game, controller, Layout)` returns `{tied=rect, shove=rect, deck=rect, workload=rect}`; `TopBar.hover(rects, mx, my, game, controller)`. |
| `views/grind/SidebarTables.lua` | 304-579 (`_makeGameTypeStrip`, `_buildTablesTabComponents`, `stakeVisible`) | ~280 | `build(game, controller, selected_gtype)` returns a component list. `selected_gtype` becomes an argument, not view state. |
| `views/grind/SidebarUpgrades.lua` | 712-868 (`_blurbRow`, `_buildRangeTooltip`, `_buildUpgradesTabComponents`, `catalogName`) | ~160 | `build(game, controller)` returns a component list. |
| `views/grind/UpgradeRangeTooltip.lua` | 590-711 (`_cell`, `_capped`, `_winChanceRows`, `_stackRateRows`, `RANGE_TOOLTIP`) | ~125 | `rowsFor(game, controller, upgrade)`. Owns the only `models.outcome_math` import in the view tree. |
| `views/grind/ShovePanel.lua` | 1774-2000 (`_shoveButtonRect`, `_houseRect`, `_houseHelpBtnRect`, `_houseInfoBtnRect`, `_drawHouse`, `_quickResetButtonRect`, `_drawShoveButton`, `_drawShoveFace`) + the shove/quick-reset tooltip blocks from `update` (902-982) | ~320 | `ShovePanel.draw(game, controller, Layout)`, `ShovePanel.hover(...)`, `ShovePanel.click(x, y) -> intent_string or nil`. |
| `views/grind/FloatingTextLayer.lua` | 2002-2074 | ~75 | `draw(game)`. Genuinely generic — could go to `services/` but it calls `Theme` and `IconText`, so it stays a view. |
| `views/grind/TableGrid.lua` | 1638-1772 minus what moved to Layout | ~90 | `draw(game, controller, hit_boxes, Layout, frozen_ref)`. Lowest priority. |

Residual `views/GrindView.lua`: `new`, `_buildPanels`, a slimmed `update` (tween +
panel hover + burst drain, ~60 lines), `draw` (~60), `mousepressed` (~60 once the
top-bar and shove routes move behind `TopBar.click` / `ShovePanel.click`),
`_handleSidebarButton`, `_handleHitBox`, `mousereleased/moved`, `wheelmoved`,
`resize`. **~380 lines.**

**Models** (pure state + rules, no `love.*`)

| New file | Moves | Approx lines | Seam |
|---|---|---|---|
| `models/payout.lua` | GrindController 346-432 (concerns H, I, J, K) | ~110 | `Payout.apply(state, ctx, r, tbl, stake, focus_mult) -> overflow_amount`. Pure: takes state, mutates it, returns the overflow. Testable headless in `sim/`. |
| `models/bounties.lua` | GrindController 33-35, 258-308, 596-698, 843-877 | ~150 | `Bounties.bankCash(state, ctx, controller, tbl, r) -> award`, `Bounties.bankMtt(...)`, `Bounties.bankAnti(...)`, `Bounties.banked(state, stake, gtype)`, `Bounties.award(ctx, stake_id)`. Collapses the three near-identical bank/deny copies into one `_bank(state, ctx, key, table_field, award_fn)`. |
| `models/run_counters.lua` | GrindController 700-802 (concerns T, U) | ~110 | `RunCounters.record(state, ctx, event)` where `event` is the same table `_grantDeckXp` already builds. Removes 16 hand-rolled `state.x = (state.x or 0) + 1` lines. |

**Services / controllers**

| New file | Moves | Approx lines | Seam |
|---|---|---|---|
| `controllers/ChipEmitter.lua` | GrindController 84-120 (`_queueBurst`, `_queueScatter`, `drainBursts`), 1411-1679 (all `_emit*`, `_palette*`, `_anchor`, `_offscreenAnchor`) | ~300 | `ChipEmitter:new(game)`; `emitter:buyIn(t, amount)`, `:cashOut(t, amount)`, `:mttPayout(t, amount)`, `:resolution(r, tbl, overflow)`, `:explosion(origin, amount, stake_id)`, `:drain()`. GrindController holds one and forwards `drainBursts`. The four `_emit*Chips` bodies collapse into one `_stackTransfer(from_xy, to_xy, amount, stake_id, opts)` — see section 5. |
| `services/TableFx.lua` | GrindController 310-321 + 556-594 | ~60 | `TableFx.apply(tbl, tier_intensity, is_win)`. Engine-agnostic (it just writes named float fields on a record), so it satisfies rule 4. |
| `controllers/GrindCommerce.lua` | GrindController 824-988, 1101-1146 (`buyRunUpgrade`, `getRunUpgrade*`, `_requirementMet`, `peelCatalogSticker`, `buyCatalogItem`, `corruptCatalogItem`) | ~230 | Constructed with `(game, effects_invalidator)`. Also fixes the duplicated cost-ladder math (section 5). |
| `controllers/TableLifecycle.lua` | GrindController 990-1096, 1148-1409 (`buyInMultFor`, `_cheapestBuyIn`, `_noLiveTables`, `wouldStrandRun`, `isStranded`, `canQuickReset`, `quickReset`, `stakeAvailable`, `addTable`, `tiedUp`, `_finalizeRemove`, `removeTable`, `cashOutAll`, `changeTableStake`, cursor mutes, `cashOutType`, `typeCursorState`, `dealHand`) | ~330 | Owns `self.pool`. GrindController delegates. |

Residual `controllers/GrindController.lua`: `new`, `invalidateEffects`,
`tableSlotsCap`, `currentFocusMult`, `currentFocusCapacity`, `_playNamed`,
`_playStateTransitionSound`, `_grantDeckXp`, `initiateShove`, `dealAll`,
`shoveUnlocked`, `rebuyTable`, `rebuyCostFor`, and a `update(dt)` that reads:

```
snapshot -> pool:update -> sounds -> emitter:flushPending -> lifecycle:finalizeCloses
  -> for each mtt payout: MttPayout.settle(...)
  -> for each resolution: Payout.apply -> Bounties.bank* -> TableFx.apply
                          -> emitter:resolution -> RunCounters.record -> floater
  -> pool:_syncStateList()
```
**~55 lines.** Total residual controller ~380 lines.

#### Safest extraction order

Each step is independently shippable and leaves the game running.

1. **`controllers/ChipEmitter.lua`** — zero state reads, one field (`pending_bursts`)
   crosses, and the view side (`drainBursts`) does not change shape. Removes 300
   lines from the controller with the lowest possible risk.
2. **`services/TableFx.lua`** — two call sites, seven float fields, no branching
   logic. Collapses a verbatim duplication while you are still in the file.
3. **`views/grind/Layout.lua`** — mechanical: the upvalues become table fields.
   Must precede every other view cut. Watch for `PANEL_MAX_W/H`, which the file
   header at 108-113 documents as having previously been shadowed by a duplicate
   `local` — the same trap exists for any constant you leave behind.
4. **`views/grind/TopBar.lua`** — biggest view win (520 lines), and after step 3 the
   only cross-file data is the four rects it returns.
5. **`views/grind/ShovePanel.lua`** — self-contained once Layout is out.
6. **`models/bounties.lua`** — do this *before* `payout.lua`, because collapsing the
   three copies is the change most likely to surface a behaviour difference and
   you want it isolated in its own commit.
7. **`models/payout.lua`** — the money rules. Verify against `sim/` after.
8. **`models/run_counters.lua`** — 16 counters, all additive, low risk but touches
   save-relevant fields; needs a read of `GameState:serializeRun` first.
9. **`controllers/GrindCommerce.lua`** and **`controllers/TableLifecycle.lua`** —
   large but mechanical; both are already cleanly grouped in the file.
10. **`views/grind/SidebarTables.lua`**, **`SidebarUpgrades.lua`**,
    **`UpgradeRangeTooltip.lua`**, **`FloatingTextLayer.lua`**, **`TableGrid.lua`** —
    the tail. Optional.

Resulting line counts after steps 1-9: `GrindView.lua` ~1150, `GrindController.lua`
~380, no new file over 530.

### 4. Correctness bugs

First, a negative result worth recording. I compiled all three files with `luac`
and dumped every `_ENV` access, which is the exact check that catches the
`ShoveView.lua:404` (`BUILDUP_TOTAL`) and `TablePanelStats.lua:383`
(`ev_sign`/`ev_color`) class of bug:

```
luac -l views/GrindView.lua | grep -oE '_ENV "[A-Za-z_0-9]*"' | sort -u
  -> ipairs, love, math, pairs, require, setmetatable, string, tostring, type
```
`GrindView.lua`, `GrindController.lua` and `GrindState.lua` all read **only**
stdlib globals and write **none** (`SETTABUP ... _ENV` count is zero for all
three). Running the same command on `views/ShoveView.lua` does surface
`_ENV "BUILDUP_TOTAL"`, so the check is sound — these two god-files are simply
clean of that bug class.

---

#### C1 — `r.table_idx` is stale by the time it is used. Money lands on the wrong table. **Critical**

`models/TablePool.lua:178` stamps the index during the tick:
```lua
for i, t in ipairs(self.tables) do
    local r = t:update(dt, ctx)
    if r then
        r.table_idx = i
```
`controllers/GrindController.lua:213-218` then removes tables **before** anything
consumes that index:
```lua
for i = #self.pool.tables, 1, -1 do
    local t = self.pool.tables[i]
    if t and t.pending_close and t.state == "idle" then
        self:_finalizeRemove(i)      -- -> pool:removeTable -> table.remove (shifts!)
```
and `GrindController.lua:389` consumes it 170 lines later:
```lua
local tbl   = self.pool.tables[r.table_idx]
```

The window is reachable and routine. `models/Table.lua:851` (`_finalizeHand`) sets
`self.state = "idle"` and `Table:update` returns `_pending_resolution` on the
**same call** (836-840), so one `pool:update` can produce a resolution for a table
that is simultaneously eligible for the deferred close. Clicking `[x]` on a table
mid-hand while other tables run — the normal multi-tabling gesture — triggers it.

Consequences, all in the same frame:
- Every resolution whose `table_idx` is greater than the removed index applies its
  `r.delta` to its **left neighbour's** stack (line 396 `tbl.stack + r.delta`), with
  that neighbour's `stake.buy_in` used as the cap (391).
- The bounty at 618-621 and the anti-bounty at 676-681 credit the wrong
  `(stake, gtype)` combo, permanently consuming that combo's once-per-run slot.
- `HandAnalytics.recordHand` (441-453) logs the wrong `stake_id` / `game_type_id`.
- The floater (530) spawns over the wrong panel.
- If the closed table was the **last** one, `tbl` is `nil` and control falls to the
  defensive branch at 421-432, which routes the delta straight to `state.bankroll`
  with no buy-in cap. `_finalizeRemove` already refunded the pre-resolution stack
  at 1237-1239, so a losing hand double-charges: refund uses the old stack, then
  the loss is clamped against *bankroll* rather than that stack.

Fix shape: carry `r.table` (the object) instead of `r.table_idx`, or move the
deferred-close sweep (E) to after the resolution loop.

#### C2 — Cursor-swarm dispatch uses last-frame table indices. **High**

`states/GrindState.lua:258`:
```lua
CursorPool.update(dt, view.hit_boxes, self.controller.ctx,
    function(hb) view:_handleHitBox(hb) end)
```
runs **after** `self.controller:update(dt)` (line 231), which can remove tables.
`view.hit_boxes` was built by the *previous* frame's `draw` (`GrindView.lua:2123`
clears it, `TablePanel.draw` refills it), so `hb.idx` indexes the pre-removal pool.
`_handleHitBox` then dispatches through `HIT_BOX_HANDLERS`
(`GrindView.lua:2376-2382`) where `remove_table` closes a *different* table than the
one the cursor visibly clicked, and `rebuy` spends bankroll on one. Same root cause
as C1 (index-as-identity) and it hits an automated system, so it fires unattended.

#### C3 — `AnchorRegistry.clear()` is never called; anchors leak for the process lifetime. **Medium**

`services/AnchorRegistry.lua:50-53` documents itself as "Called on hard resets (F7,
prestige) so stale positions from a prior layout don't leak into the new run."
```
grep -rn "AnchorRegistry.clear\|Anchors.clear" --include=*.lua .
  -> services/AnchorRegistry.lua:51 (the definition only)
```
Zero call sites. `models/Table.lua:73-119` allocates `_id` from a monotonic
module counter, so `Table.anchorKey` produces a unique key per table ever created
(`table_<id>_you|pot|center|opp_1..7`, ~10 keys). Every table the player opens
during a session adds ten permanent entries to `_anchors`, each a 5-field table.
`GrindState:fullReset` (303-320) clears `CursorPool`, `FlightSystem`, `ChipPile`,
`ClickFlash` and `Ghosts` but not this.

#### C4 — `AnchorRegistry.age()` exists but the controller never uses it. **Medium**

`AnchorRegistry.get` returns "arbitrarily stale" data by its own doc (34-37); `age()`
is the guard. Only `views/HintView.lua:69,196` calls it. Every controller read
accepts a stale anchor:
```lua
-- GrindController.lua:202-207
if t._pending_buyin
   and AnchorRegistry.get(TableModel.anchorKey(t, "you"))
   and AnchorRegistry.get("bankroll") then
    self:_emitBuyInChips(t, t._pending_buyin)
```
This block exists *specifically* to wait until the view has drawn the table. It
tests existence, not freshness — so if the panel stops drawing (a modal covers the
grind, the window is minimised so `love.draw` is skipped) the gate still passes and
the chips fly from a coordinate the table no longer occupies. Same for
`_emitCashOutChips` (1521), `_emitMttPayoutChips` (1542), `_emitResolutionChips`
(1566-1568, 1637).

#### C5 — `state.bankroll` is never quantised to cents; float error reaches affordability tests. **Medium**

Ten write sites in `GrindController` (239, 400, 405, 415, 431, 906, 1173, 1239,
1284, 1714) and not one rounds. The project *does* have the helper pattern —
`models/Table.lua:310` does `stack = math.floor(stack * 100 + 0.5) / 100` and
`models/HandScript.lua:94` defines `r2` — it is just not applied to bankroll. The
deltas that land on it are irrational by construction:
```lua
-- GrindController.lua:351, 359
r.delta = r.delta * focus_mult                              -- e.g. 0.85
r.delta = r.delta * (1.0 + math.log10(br + 1) * 0.1)        -- irrational
```
Display is `%.2f` / `Format.moneyExact`, but the gates compare raw floats:
`addTable` 1172 `if self.game.state.bankroll < cost then return false end`, and
`wouldStrandRun` 1036 `return (self.game.state.bankroll - cost) < cheapest`. Cost:
a player reading "$0.20" against a $0.20 buy-in gets a dead ADD TABLE button, and
the upgrades tab shows "open or rebuy a table first — buying now ends the run"
(`GrindView.lua:807`) for a purchase that is actually affordable.

#### C6 — Early return at 342 skips the save resync. **Medium**

```lua
-- GrindController.lua:342
if #resolutions == 0 then return end
...
-- 809 (unreachable when the above fired)
self.pool:_syncStateList()
```
The MTT-payout block (220-340) runs *before* that return and mutates save-relevant
model state: `t.mtt.hands_won = 0` (338), plus `state.bankroll`. `_syncStateList`
(`models/TablePool.lua:124`) is what copies `t.mtt.hands_won` into
`state.active_table_mtt_hands_won`. On the frame a tournament settles there are
usually no cash resolutions, so the reset never reaches the save arrays. If an
autosave (or a quit) lands before the next resolving frame, the save records
`hands_won = 8` for a tournament that already paid out, and
`rebuildFromState` restores a tournament that looks already-won.

#### C7 — Top-bar layout is not recomputed when `shove_r2_won` flips. **Medium**

`recomputeLayout` runs only from `_buildPanels` (init + `resize`). It reserves the
anti-chip cell conditionally:
```lua
-- GrindView.lua:215-217
if state and state.shove_r2_won then
    cells_total = cells_total + CELL_W.achip
end
```
but `_drawTopBar` draws it unconditionally on the live flag (1363-1375) and advances
`x` by `CELL_W.achip`. The very next block acknowledges the hazard for the deck cell
and solves it by reserving on the static `Constants.FEATURES.DECKS` (218-224) — the
achip cell got the treatment the comment warns against. When the player wins R2
mid-session the whole run + workload cluster shifts right by ~54px into the
`button_zone` the squeeze math reserved (226 `available = W - TOPBAR_PAD_X -
button_zone`), overlapping CASH OUT until the next window resize.

#### C8 — `pending_bursts` survives `GrindState:fullReset` and every run reset. **Low-Medium**

`GrindState:fullReset` (303-309) calls `FlightSystem.clear()`, but nothing clears
`controller.pending_bursts`. `GrindView:update:1089` drains the queue on the very
next frame and re-emits every burst — flights spawn from anchors belonging to
tables the wipe destroyed. Same for `GrindController:quickReset` (1088-1096), which
rebuilds the pool without flushing the queue.

#### C9 — `invalidateEffects()` fires mid-loop, but `focus_mult` was captured before it. **Low**

```lua
-- 345
local focus_mult = self:currentFocusMult()
for _, r in ipairs(resolutions) do
...
-- 798-801
local newly = Decks.checkPendingUnlocks(state, self.game.unlock_rules)
if #newly > 0 then self:invalidateEffects() end
```
`_grantDeckXp:820` can also call it. After a mid-frame deck level-up, resolutions
2..N read the **new** `self.ctx` at 357/367/413/450 but the **old** `focus_mult`
from 345. Cost: one frame of inconsistent scaling; only observable at the boundary,
but it makes the resolution loop order-dependent for no reason.

#### C10 — `stakes_won_this_run` is guarded in one reader and not in the two writers. **Low**

```lua
-- GrindController.lua:845 (guarded)
local cur = self.game.state.stakes_won_this_run and self.game.state.stakes_won_this_run[key]
-- GrindController.lua:267 and 622 (unguarded)
local cur = state.stakes_won_this_run[key]
```
`GameState` initialises it at 170 and 221 and serialises it at 527, but `applySaved`
(385-407) backfills `anti_stakes_won_this_run` and the four `*_this_run` booleans
while leaving `stakes_won_this_run` alone. A save whose run block lacks the key
survives load (the constructor value stands) but the asymmetry is exactly how the
next serialization change becomes a nil-index crash on the hot path. `(unverified
that a nil is reachable today; confirmed the guard is inconsistent.)`

#### C11 — Three cent-scale division sites are unguarded against `bb == 0`. **Low**

```lua
-- GrindController.lua:1505-1507, 1524-1526, 1551-1553
local bb   = (stake and stake.bb) or 1
local tier = Denoms.tierFromUnit(amount / bb)
```
Two sibling sites do guard — `GrindController.lua:480`
(`stake.bb and stake.bb > 0`) and `TablePanelStats.lua:913` (`if bb <= 0 then bb = 1
end`). No stake in `data/stakes.lua` has `bb = 0` today, so this is latent, not live.

#### C12 — `bestGridLayout` can return a zero-area layout. **Low**

```lua
-- GrindView.lua:1656
local best = { cols = 1, rows = n, pw = 0, ph = 0, area = -1 }
...
if pw_avail > 8 and ph_avail > 8 then   -- if this never passes, best is returned as-is
```
At a window small enough that `grid_h = H - TOP_BAR_H - BOTTOM_BAND_H - 2*MARGIN`
drops under ~8px, `_drawCenterGrid:1770` calls `TablePanel.draw(..., pw=0, ph=0,
...)`. Not a crash in `GrindView` itself, but it hands a zero-size rect to a 1725-line
renderer that divides by panel dimensions.

#### C13 — View-side tween/cache state survives a new game. **Low**

`GrindState:fullReset` (303-320) resets services and modals but never touches the
view. Left holding old-game values: `GrindView.displayed_bankroll` /
`displayed_chips` / `displayed_anti_chips` / `displayed_tied` (242-257),
`frozen_grid`, `selected_gtype`, plus the module-level caches
`RollingValue._v` (keys `focus_pct`, `btn_ev:<stake>:<gtype>` — `RollingValue.reset`
exists and is never called from here) and `Pop`'s change-watch ids
(`tables_x`, `tables_y`, `focus`). `views/AwardGlow.lua` has only `flash` and `draw`
— no clear at all. Cost: after Settings -> Start new game the bankroll counts *down*
from the previous game's figure for ~0.5s.

#### C14 — `ipairs` over a mutated table: checked, clean.

Every removal loop in `GrindController` is a reverse numeric loop with the comment
to match — 213 (`for i = #self.pool.tables, 1, -1`), 1261 (`cashOutAll`), 1326
(`cashOutType`). The `ipairs` walks at 182, 191, 201, 223, 346, 1200, 1342, 1357,
1369, 1789 do not mutate the list they walk. `GrindView.lua:939` walks
`self.hit_boxes` without mutation. No finding here.

#### C15 — Nits

- `GrindView.lua:1185` and `1242` both declare `local level = (state.deck_levels and
  state.deck_levels[active_id]) or 0`; the second shadows the first with an identical
  value. `1233` declares a second `local inset` shadowing `1179`.
- `GrindView.lua:1081` guards `self.displayed_anti_chips or 0` and `state.anti_chips
  or 0` while the three sibling tween lines (1079, 1080, 1082) guard neither.
  `tweenNumber` does `curr + (target - curr) * k`, so a nil target is an arithmetic
  error rather than a no-op.
- `GrindController.lua:1324-1334` `cashOutType` returns `n` counting tables that were
  only *flagged* `pending_close`, not closed. The view discards the return today.

### 5. Duplication

#### Within `GrindController.lua`

**D1 — Three copies of the bounty bank/deny state machine. Severity: High.**
`258-308` (MTT win), `596-672` (cash jackpot), `674-698` (anti-chip). All three run
the identical shape: build `bountyKey`, read `stakes_won_this_run[key]`, normalise
`true`/number into a count, compare against `cap = 1`, write back, zero
`hands_since_last_bank`, call `bountyAward`, apply `first_bounty_bonus`, bump three
lifetime counters, else apply `copy_first_denied` or bump `total_denied_stacks`.
The comment at 279-281 records that this already bit once — *"Same award math as the
cash jackpot path (incl. chip_award_mult AND Pen's flat bonus — this used to
hand-roll the formula and dropped the Pen add)"*. Copy 3 (anti-chip, 674-698) is
still divergent: it has no `first_bounty_bonus`, no `copy_first_denied`, no
`total_denied_stacks`, and no lifetime counters. Cost: any future bounty rule has to
be written three times and the third one is already behind.

**D2 — Three near-identical chip-emit bodies. Severity: Medium.**
`_emitBuyInChips` 1499-1516, `_emitCashOutChips` 1518-1535, `_emitMttPayoutChips`
1540-1562. Each is: resolve two anchors, `Lookups.findById(Stakes, t.stake_id)`,
`local bb = (stake and stake.bb) or 1`, `_paletteForAmount`, `Denoms.tierFromUnit`,
`Denoms.breakdown`, `_queueBurst{kind="stack", amount, arrival_sound, source_key,
dest_key}`. The only variation is which anchor is source vs dest, the sound name,
and (in the MTT one) a pot/center/viewport-centre fallback chain. Collapses to one
`_stackTransfer(from_xy, to_xy, amount, stake_id, opts)` of ~14 lines, saving ~45.

**D3 — Two copies of the tier-FX write block. Severity: Medium.**
`313-320` (MTT win) and `561-593` (per-resolution). Both write `shake_trauma`,
`vignette_kind`, `vignette_alpha`, `border_pulse_t`, `border_pulse_color`, `glow_t`
with `math.max` accumulate semantics; the MTT copy hardcodes
`FeedbackIntensity.jackpot` and omits the `pot_explode_pending` and border-pulse-SFX
tails. This is the `services/TableFx.lua` extraction from section 3.

**D4 — The run-upgrade cost ladder is written twice. Severity: Medium.**
```lua
-- buyRunUpgrade 894-903                    -- getRunUpgradeNextCost 978-987
local cost = 0                              local cost = 0
if upgrade.costs then                       if upgrade.costs then
    if current + 1 <= #upgrade.costs then       if current + 1 <= #upgrade.costs then
        cost = upgrade.costs[current + 1]           cost = upgrade.costs[current + 1]
    else                                        else
        local last_cost = ...                       local last_cost = ...
        cost = last_cost * 3.0                      cost = last_cost * 3.0
```
Character-identical including the magic `3.0`. The view labels the button from
`getRunUpgradeNextCost` and the purchase charges from `buyRunUpgrade`, so a divergence
here charges a price the button never showed.

**D5 — Four paired mute accessors. Severity: Low.**
`toggleCursorMute` 1292-1298 / `toggleCursorRebuyMute` 1304-1310 and
`setTypeCursorMute` 1355-1365 / `setTypeCursorRebuyMute` 1367-1377 differ only in
`cursor_muted` vs `cursor_rebuy_muted`. Likewise `bountyBanked` 843-853 /
`antiBountyBanked` 855-859 and `bountyAward` 865-871 / `antiBountyAward` 873-877.
One field-name parameter removes ~35 lines.

#### Within `GrindView.lua`

**D6 — Five near-identical top-bar button rect/draw pairs. Severity: Medium.**
`_cashOutButtonRect` 1483-1492, `_catalogButtonRect` 1527-1536, `_roomButtonRect`
1554-1563, `_settingsButtonRect` 1584-1593, `_helpButtonRect` 1610-1618 — each is
`{ x = <prev>.x + bw + TOPBAR_BTN_GAP, y = floor((TOP_BAR_H - H)/2), w = bw, h = H }`,
chained positionally so inserting a button means editing three functions. Their
draw partners (`_drawCashOutButton` 1494-1514, `_drawCatalogButton` 1538-1550,
`_drawRoomButton` 1565-1580, `_drawSettingsButton` 1595-1606, `_drawHelpButton`
1623-1636) are the same `AnchorRegistry.set` + `love.mouse.getPosition` + inline
hover-rect test + `LabelButton.draw{...}` block with a different label string and
`ClickFlash` key. This is exactly the "5 near-identical `_drawXButton` functions
become one data-driven list" the prior audit called out; it has grown by one button
since (`ROOM`) rather than shrinking. ~150 lines collapse to a ~30-line list + a
20-line loop.

**D7 — Chip and anti-chip top-bar cells. Severity: Low.**
`1350-1360` and `1363-1375` are the same seven statements (`ui_scale`, `cd =
floor(TOP_BAR_H*0.6)`, `Icons.drawChip|drawAntiChip`, `setFont(fonts.md)`,
`setColor(Theme.fg.heading)`, `print(chipsText(...), x + cd + floor(6*cs), ...)`,
`AnchorRegistry.set`) with one glyph function and one state field swapped.

**D8 — Scale-about-centre printed twice. Severity: Low.**
`drawStatCell` 1149-1157 and the nested `popText` 1420-1431 are the same
push/translate/scale/translate/print/pop, both keyed off `TOPBAR_VALUE_Y` and
`fonts.md`. `popText` exists only because `drawStatCell` takes a `value_scale` it
cannot use for a two-part "X / Y" string.

**D9 — Inline hover-rect test, 16 occurrences. Severity: Low.**
```
grep -c "mx >= .* and mx < .* and my >= " views/GrindView.lua   -> 6
grep -c "x >= .*\.x and x < .*\.x + "     views/GrindView.lua   -> 10
```
Sixteen hand-written `pointInRect` expansions across `update` (906, 959, 987, 1001,
1009, 1021, 1059), the five button draws, `_drawHouse` 1863, `_drawShoveButton`
1899, `_drawShoveFace` 1926, and `mousepressed` (2187, 2198, 2210, 2222, 2230, 2239,
2250, 2262, 2274). Each is an independent chance to write `<=` where the others
write `<`.

#### Against `views/TablePanel.lua`, `views/ShoveView.lua`, `views/RoomView.lua`

**D10 — `moneyText` is duplicated verbatim in `states/RoomState.lua`. Severity: Medium.**
```
grep -rn "if math.abs(n or 0) < 1000" --include=*.lua .
  states/RoomState.lua:14
  views/GrindView.lua:1115
```
Both are `local function moneyText(n) if math.abs(n or 0) < 1000 then return
Format.moneyExact(n) end return Format.money(n) end`. The threshold and the
exact/abbrev policy are a product decision that now lives in two files; it belongs in
`utils/format.lua` beside the two functions it dispatches between.

**D11 — `RoomState` reimplements the grind top bar with a different height. Severity: Medium.**
`GrindView.lua:1259-1262` and `states/RoomState.lua:61-65` draw the same chrome bar +
1px border; `GrindView.lua:1283-1291` and `RoomState.lua:68-73` print the same
bankroll in `fonts.lg` at the same vertical centring. But `GrindView` derives
`TOP_BAR_H` from font metrics (`recomputeLayout` 168-172) while `RoomState` hardcodes
`local top_h = fl(56 * s)`. Concrete cost: the ROOM button in the grind top bar
(`_roomButtonRect`, centred in `TOP_BAR_H`) and the PLAY button that replaces it in
room mode (`RoomState.lua:78-79`, centred in `56*s`, and right-anchored at
`W - btn_w - 16*s` rather than `W - RIGHT_W`) are at different heights *and*
different x. The player's cursor is never on the button they just clicked.

**D12 — `views/ShoveView.lua`: no duplication found.** `grep -n
"floating_text\|ChipPile\|Icons.drawChip\|Format.money" views/ShoveView.lua` returns
nothing. ShoveView renders the gauntlet only. Recording this so the seam is not
looked for again.

**D13 — `views/RoomView.lua`: 11 more inline hover-rect tests.** Same idiom as D9
(`grep -c` gives 5 + 6). No shared code with GrindView beyond `LabelButton`.

**D14 — "Tied up" is formatted in three places.** `GrindView.lua:1332`
(`drawStatCell(x, CELL_W.tied, "TIED UP", moneyText(d_tied), ...)`) and
`views/TablePanel.lua:998` / `1534` (`local tied_str = "Tied up  " ..
Format.moneyExact(rolled)`) — three renderings of the same number with two
different formatters (`moneyText` abbreviates at $1k, `moneyExact` never does), so
the top bar and the panel disagree above $1k. Severity: Low.

### 6. Layering violations

Rule 2 states: models hold state and pure logic; views render and never mutate
state; controllers route input; a controller never owns gameplay state.

#### 6a. Every field on `GrindController`'s `self`

| Field | Set at | What it actually is | Where it belongs |
|---|---|---|---|
| `self.game` | 42 | DI container | Correct. |
| `self.pending_bursts` | 48 | A queue of **screen-space** render intents (`{kind, source={x,y}, dest={x,y}, chips, options}`) | A `ChipEmitter` (section 3). It is view-bound data — `source`/`dest` are pixel coordinates read out of `AnchorRegistry`, which views write. |
| `self.pool` | 53 | **The live gameplay model.** `TablePool` owning every `Table`, its stacks, its MTT sessions, and the save arrays | A model handle on `GrindState` (or on `GameState`, which already persists all 13 `active_table_*` arrays). The controller should receive it, not own it. |
| `self.ctx` | 126 | The rolled-up effects context — derived gameplay state | `GameState.effects_cache`, which **already exists and already holds the same table**. `computeEffects` writes `self.effects_cache = ctx` at `GameState.lua:647` and returns it; `invalidateEffects` then stores a second reference under `controller.ctx`. Two aliases for one object, and only one of them is nilled by `GameState:resetRun()` (line 234). |

That is 3 of 4 fields holding gameplay state or view data. There is nothing on this
object that is input routing.

#### 6b. Controller writing view state onto models

`GrindController` writes seven presentation-impulse fields on `Table` records:
```lua
-- GrindController.lua:564-592
tbl.shake_trauma       = math.max(tbl.shake_trauma or 0, intensity.shake)
tbl.vignette_kind      = is_win and "good" or "bad"
tbl.vignette_alpha     = math.max(tbl.vignette_alpha or 0, intensity.vignette)
tbl.border_pulse_t     = math.max(tbl.border_pulse_t or 0, intensity.border_pulse)
tbl.border_pulse_color = is_win and "good" or "bad"
tbl.glow_t             = math.max(tbl.glow_t or 0, intensity.glow)
tbl.pot_explode_pending = true
```
`models/Table.lua:167-190` declares them and documents the arrangement
(*"GrindController writes these fields on resolution"*), so this is deliberate — but
it makes `Table` a view-state carrier and makes the controller the animation driver.
`services/TableFx.lua` (section 3) at least isolates it.

Two more controller-invented fields are **not** declared on `Table:new` at all:
`t._pending_buyin` (written 1184, read/cleared 202-206) and `t._hand_start_t`
(written 1389 and 457, read 440). Both are the exact `_last_ctx` smell the prior
audit flagged on `models/Table.lua` — undeclared fields that exist only to thread a
value across a frame boundary.

#### 6c. Controller doing view work

- `_multSuffix` 61-82 formats `"\n$44.00 x2.00"` — a display string with its own
  rounding policy (`x%.0f` above 10, `x%.2f` below), 200 lines from any renderer.
- 461-497: the whole floater-label branch. `string.format("+$%.2f")`,
  `string.format("+%dbb")`, `"WIN"`/`"OUT"`, and a `color_token` override table.
- 515-548: merges `FeedbackIntensity` floater opts, then computes
  `drift_scale = math.max(0.4, math.min(1.6, panel_h / 390))` from a **panel pixel
  height** read out of an anchor rect. The controller is doing responsive layout.
- 1456-1459 `_offscreenAnchor` and 1544/1636 read `self.game.viewport` — viewport
  dimensions in the controller.
- `_playStateTransitionSound` 1750-1767 is an `if/elseif` chain on
  `new_state` strings — the kind-chain pattern rule 3 forbids; it should be a
  `data/sounds.lua` state-to-name map.

#### 6d. View doing business math

`GrindView` never writes `state.*` — `grep -nE "(self\.game\.)?state\.[a-z_]+\s*=[^=]"
views/GrindView.lua` returns nothing. That rule holds. The violations are on the read
and compute side.

**V1 — the view simulates a purchase against the effects model. Severity: High.**
```lua
-- GrindView.lua:746-754
local ctx     = self.controller.ctx or {}
local nextctx = {}
for k, v in pairs(ctx) do nextctx[k] = v end
for _, key in ipairs(spec.keys) do
    local list = {}
    for _, d in ipairs(ctx[key] or {}) do list[#list + 1] = d end
    list[#list + 1] = { strength = 1 }
    nextctx[key] = list
end
```
The view fabricates a hypothetical effects context by appending a
`{ strength = 1 }` descriptor, then runs the outcome model against it. It hardcodes
the assumption that one more upgrade level equals one more strength-1 fill
descriptor. If `computeEffects` ever changes how run-upgrade levels roll into
`*_fills`, the tooltip silently lies about what the next level buys. This is a
`controller:previewRunUpgrade(up)` call that never got written.

**V2 — the outcome model is called directly from the view.** `_winChanceRows` 617-618
and `_stackRateRows` 655-656 call `OutcomeMath.buildOutcome`; `_capped` 606 calls
`OutcomeMath.sumFills`. `views/GrindView.lua` imports `models.outcome_math`,
`models.shove_rate` and `models.Decks` (lines 45-47).

**V3 — the view reads the controller's gameplay state directly.** 8 sites read
`self.controller.ctx` (431, 746, 816, 961, 1011, 1064, 1315, 1919) and 7 read
`self.controller.pool` (411, 989, 1294, 1497, 1710, 2197, 2402), two of them reaching
into `.tables` as a raw array:
```lua
-- 1710
local tables = self.controller.pool.tables
-- 2402
local tbl_for_ghost = self.controller.pool.tables[hb.idx]
```
2402 then branches on the model's state-machine label
(`tbl_for_ghost.state ~= "idle"`) to decide whether to spawn a ghost. `TablePanel`
and `TablePanelStats` do the same (`controller.ctx` at TablePanel 1423-1424, 1528;
TablePanelStats 258-259, 301, 345, 895, 902, 910, 930), so this is a house pattern,
not a one-off. It is still a view reaching through a controller into a model.

**V4 — the view hands a model object to a renderer that mutates it.**
`GrindView:_drawCenterGrid:1770` passes `tables[i]` into `TablePanel.draw`, which
writes `tbl.x`/`tbl.y` and clears `tbl.pot_explode_pending` (`TablePanel.lua:612`,
`711`). GrindView is the vector even though the write is in the callee.

**V5 — `_handleSidebarButton` 2317-2371 is a string-prefix parse chain.** Nine
`id:match("^prefix:(.-):(.+)$")` tests dispatching to nine different controller
methods, when `HIT_BOX_HANDLERS` 2376-2382 three functions below shows the registry
form the project already uses. Restated from the prior audit; unchanged since.

### 7. Dead code

Flag values in the shipped build, from `data/constants.lua:19-79` with
`PROTOTYPE_MODE = false`:

```
TUTORIAL = true    POKER_THEATER = true   MTT_KO = true     DECKS = true
HIGH_TIER_STAKES = true   DEV_HOTKEYS = true   DEMO_CUT = false
ONBOARDING_MODAL = false  QUIT_DISABLED = false
DEBUG.HAND_ANALYTICS = true
```

#### Functions never called

**X1 — `GrindController:changeTableStake` 1271-1288 (18 lines). Severity: Medium.**
```
grep -rn "changeTableStake" --include=*.lua .   -> 1 hit (the definition)
```
Zero callers. It is the last survivor of the STAKE-UP button, which
`GrindView.lua:8-10` still advertises in the file header:
*"and a [⤴ next-stake] button when the next tier is unlocked + affordable."*
Its two dependents are dead with it: `TablePool:changeStake`
(`models/TablePool.lua:164-168`, one caller — this) and the
`stake_up_flourish` sound (`data/sounds.lua:77`, one caller — this). ~30 lines
across three files, plus a stale doc comment that describes a feature the player
cannot reach.

**X2 — `GrindController:_emitDealChips` 1475-1497 (23 lines). Severity: Low.**
```lua
function GrindController:_emitDealChips(t)
    if not t then return end
    if Constants.FEATURES and Constants.FEATURES.POKER_THEATER then return end
```
`POKER_THEATER` is `true`, so the 18 lines after the guard never execute. The
function's own header (1465-1474) says *"DEAD under the theater"*. The call site at
`dealHand:1398` survives and costs two table lookups per deal.

**X3 — `GrindView:_drawHelpButton` 1623-1636 + `_helpButtonRect` 1610-1618 (27 lines). Severity: Low.**
```lua
function GrindView:_drawHelpButton()
    if Constants.FEATURES.TUTORIAL then return end
```
`TUTORIAL` is `true`. `_helpButtonRect` has exactly two callers — `_drawHelpButton:1625`
(after the dead guard) and `GrindView:mousepressed:2249` (inside
`if not Constants.FEATURES.TUTORIAL then`, 2248-2256, also dead). The live "?" is the
one on THE HOUSE poster (`_houseHelpBtnRect`, handled at 2260-2268). Note the two
paths register the **same** anchor name `"btn:help"` (1626 and 1861), so if both
were ever live the hint system would target whichever drew last.

#### Unreachable branches

**X4 — `GrindView:mousepressed` 2248-2256.** The prototype-only help-button route.

**X5 — `GrindView:_makeGameTypeStrip` 329-339.** The `MTT_KO`-false fallback blurb —
an 11-line table literal in the `or` arm of `Constants.FEATURES.MTT_KO and "..." or
{...}`. Dead source, but Lua's `and`/`or` short-circuits so it costs nothing at
runtime. Worth noting because it contains an `IconText` closure pair that reads as
live code.

**X6 — the entire onboarding-modal path in `states/GrindState.lua`. Severity: Low, ~40 lines.**
`self.onboarding_modal` is only assigned at `openHelp:133`, which is unreachable:
`openHelp` returns at 130 whenever `FEATURES.TUTORIAL` is true, and the only other
entry (`enter:209-210`) is gated on `FEATURES.ONBOARDING_MODAL`, which is `false`.
So the field is permanently `nil` and every guard on it is dead: `openHelp` 132-134,
`_dismissOnboarding` 146-156, `draw` 292-294, `keypressed` 332-336, `mousepressed`
390-394, `mousereleased` 449-452, `mousemoved` 469-472, `wheelmoved` 489-492, and the
ctor field at 53. `AnalyticsConsentModal` is still reachable via `enter:211-213`, so
only the onboarding half is dead.

**X7 — `GrindController:update:393-394` is an empty branch.**
```lua
if tbl and r.chip_stack_table then
    -- No-op: stack already reconciled. r.delta is informational.
elseif tbl then
```
Deliberate, but it reads as a hole. `if tbl and not r.chip_stack_table then` says the
same thing in one branch. Nit.

#### Flag inversion — not dead, and it should be

**X8 — `DEV_HOTKEYS` is ON in the public build. Severity: High.**
```lua
-- data/constants.lua:38-40
-- Wire the developer hotkeys (F2/F6/F7/backtick/-/=, H/J in grind,
-- R/[/]/D in shove). Off in shipping builds.
DEV_HOTKEYS       = not C.PROTOTYPE_MODE,
```
With `PROTOTYPE_MODE = false` this evaluates to `true`. The comment says the
opposite of what the code does. Live consequence in scope, `states/GrindState.lua:378-386`:
```lua
if not Constants.FEATURES.DEV_HOTKEYS then return end
if key == "h" then
    self.controller:dealHand(1)
elseif key == "j" then
    self.controller:dealAll()
elseif key == "y" then
    self.game.state.cleared = not self.game.state.cleared
```
So on itch: `H` deals table 1, `J` deals every idle table in one keypress (bypassing
the click-to-deal loop the comment at 375-377 says the gate protects), and `Y`
toggles `state.cleared` — which is precisely what `Decks.systemUnlocked`
(`models/Decks.lua:26`) reads, so one keypress grants the entire deck system. `Y` is
also a plain unmodified letter key with no confirmation, and it writes a **persisted
meta field**.

#### Fields written but never read — checked, none found

I traced every field the two files write that looked orphaned, and each has a reader:
`t.pot_exploded` (written 1397, 1792) is read at `TablePanel.lua:710`;
`t.pot_explode_pending` at `TablePanel.lua:612,710-711`; `r.felt_pot` (read by
`_multSuffix:63`) is written at `Table.lua:783,819`; `frozen_grid.anchor_x/_y` are
read at `GrindView:mousemoved:2431-2432`; `mtt_final` at 535; `overflow_amount` at
554 and 1635. `GrindView.selected_gtype` is read at 354, 391 and 427. No finding.

### 8. Per-frame cost

Counts assume the shipped data: 11 stakes (`data/stakes.lua`), 4 game types
(`data/game_types.lua`), 5 run upgrades (`data/run_upgrades.lua`, 2 with
`tooltip_metric`), and a mid-game pool of ~6 tables.

The load-bearing fact: **`views/Panel.lua:272` calls `active_tab.build(game)` every
single draw**, with no memo and no dirty flag.
```lua
if not active_tab or not active_tab.build then return end
...
local comps = active_tab.build(game)
self._last_components = comps
```
Both panels have exactly one registered tab, so `_buildTablesTabComponents` (172
lines) and `_buildUpgradesTabComponents` (106 lines) run in full at 60 Hz.

#### P1 — Tooltips for invisible rows are fully built every frame. Severity: High.

`_buildUpgradesTabComponents:854` calls `self:_buildRangeTooltip(up)` for **every**
upgrade, hovered or not. For the `win_dist` upgrade (`data/run_upgrades.lua:100`),
`_stackRateRows:646-706` does:
```lua
for _, stake in ipairs(Stakes) do            -- 11
    if stakeVisible(view, stake) then
        for i, gt in ipairs(gtypes) do       -- 4
            local _, cd = OutcomeMath.buildOutcome(ctx,     gt, stake)
            local _, nd = OutcomeMath.buildOutcome(nextctx, gt, stake)
```
That is **88 `OutcomeMath.buildOutcome` calls per frame**, plus the `win_chance`
upgrade's 22 (`_winChanceRows:617-618`) = **110 outcome-model evaluations per frame**
to populate two tooltips of which at most one can be on screen. Each row also
allocates a table carrying two closures (`measure`/`render`), so 13 + 11 rows = 24
tables and 48 closures per frame, plus a `pairs` shallow copy of the whole `ctx`
and a copy of each fill list per upgrade (`_buildRangeTooltip:747-753`).

Fix: build the tooltip lazily inside the component's hover path, or gate on
`game.hover.is("button", "buy_runup_" .. up.id)`.

#### P2 — `evStats` runs twice per stake row, per frame. Severity: High.

`_buildTablesTabComponents` calls both:
```lua
-- 454
local ev = TablePanelStats.evPerHand(self.controller, stake, gtype_obj)
-- 558
tooltip = affordable and TablePanelStats.breakdownLinesFor(self.controller, stake, gtype_obj)
```
`TablePanelStats.lua:902` and `:910` each call `OutcomeMath.evStats(ctx, gtype,
stake)` on the same arguments — no shared result. `evStats`
(`models/outcome_math.lua:527-557`) allocates a `per_tier` table plus one table per
tier and calls `resolvedOutcome` once and `payoutMult` twice per tier. At 11 visible
stakes that is **22 `evStats` per frame, half of them redundant**, and again the
`breakdownLinesFor` half is only ever displayed on hover.

#### P3 — 88 discarded string allocations per frame in `GrindView:update`. Severity: Medium.

```lua
-- GrindView.lua:886-899
for _, stake in ipairs(Stakes) do
    for _, gt in ipairs(GameTypes) do
        local key    = stake.id .. ":" .. gt.id
        local banked = self.controller:bountyBanked(stake.id, gt.id)
```
11 x 4 = 44 iterations. Each builds `key` (1 string) and `bountyBanked` internally
builds the same string again via `bountyKey` (`GrindController.lua:33-35`) — 88
short-lived strings per frame, every frame, to detect an event that fires a few times
per run. An event/callback from the banking site would replace the whole sweep.

#### P4 — `tiedUp()` walks the pool four times per frame with linear id scans. Severity: Medium.

Unconditional callers: `GrindView:update:1082`, `_drawTopBar:1271` and `:1316`,
`_drawShoveFace:1922`. Two more fire on hover (962, 1012). Each call
(`GrindController.lua:1198-1215`) walks every table doing
`Lookups.findById(GameTypes, ...)` and `Lookups.findById(Stakes, ...)` — both linear
scans (`utils/lookups.lua:10-16`). At 6 tables: 4 x 6 x (4 + 11) = **~360 comparisons
per frame** for one number. Compute it once in `update` and cache on the view beside
`displayed_tied`.

#### P5 — `ShoveRate.compute` runs twice per frame unconditionally. Severity: Low.

`_drawTopBar:1316` and `_drawShoveFace:1922` both do
`ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())` — identical
arguments, one frame apart in the draw order, each allocating a `rates` table
(`models/shove_rate.lua:172-174`) and each dragging a `tiedUp()` walk with it (P4).
Two more on hover at 962 and 1012.

#### P6 — ~100 anchor tables allocated per frame. Severity: Medium.

`services/AnchorRegistry.lua:30-32` allocates on every set:
```lua
function AnchorRegistry.set(name, x, y, w, h)
    _anchors[name] = { x, y, w, h, frame = _frame }
end
```
`grep -c "AnchorRegistry.set"` gives 19 in `GrindView.lua` and 14 in `TablePanel.lua`.
`TablePanel.draw` runs once per table, so at 6 tables that is 19 + 84 = **103 fresh
5-field tables per frame** that are immediately garbage. Mutating the existing entry
in place when the name is already present would drop it to near zero. Compounds with
C3 (the table never shrinks).

#### P7 — Floater rendering allocates a string per line per floater per frame. Severity: Medium.

```lua
-- GrindView.lua:2049-2055
for _ in t.text:gmatch("\n") do n_lines = n_lines + 1 end
...
for line in (t.text .. "\n"):gmatch("(.-)\n") do
```
Two `gmatch` iterators plus a full string concatenation of the floater text, every
frame, for every live floater. Then 2063-2068 issues **9 `love.graphics.print` calls
per line** (8 stroke offsets + 1 fill). A jackpot banner is 3 lines = 27 draw calls.
Also `resolveToken` (2019-2024) is defined as a fresh closure on each call to
`_drawFloatingText`. Pre-splitting the lines when the floater is emitted removes the
per-frame parse.

#### P8 — `GrindController:update` allocations. Severity: Low.

- 181 `local prev_states = {}` — a fresh table every frame, even with an empty pool.
- 507-508 `local ramp = { "small", "small", "medium", ... }` — an 8-element literal
  allocated per binary-MTT winning hand, and it is data, so it belongs in
  `data/game_types.lua`.
- 519-525 and 536-537 — two separate full `pairs` copies of
  `intensity_for_floater.floater` per resolution:
  ```lua
  floater_opts = {}
  for k, v in pairs(intensity_for_floater.floater) do floater_opts[k] = v end
  for k, v in pairs(floater_opts_override) do floater_opts[k] = v end
  ...
  local opts_copy = {}
  for k, v in pairs(floater_opts) do opts_copy[k] = v end
  ```
- 441-453 and 244-255 allocate an 11-field / 9-field analytics record per resolution
  (`DEBUG.HAND_ANALYTICS` is `true` in the shipped build), and 443/457 call
  `love.timer.getTime()` twice more per resolution.
- `string.format` appears 10 times in `update` (178-810), 6 in `GrindView:update`,
  3 in `_buildTablesTabComponents`, 1 in `_drawTopBar`.

#### P9 — Redundant work in the upgrades builder. Severity: Low.

`_buildUpgradesTabComponents:778-780` calls `getRunUpgradeMaxLevel(up)` and then
`getRunUpgradeNextCost(up)`, which calls `getRunUpgradeMaxLevel(up)` **again**
(`GrindController.lua:976`). Each of those loops all 11 stakes calling
`stakeAvailable` (953-963). Then 786 calls `wouldStrandRun`, which calls
`_noLiveTables` (pool walk) and `_cheapestBuyIn` (11 stakes x `buyInMultFor` x
`Lookups.indexById` linear scan). Per upgrade, per frame, x5 upgrades.

#### P10 — Font and state churn in `_drawTopBar`. Severity: Nit.

8 `love.graphics.setFont` calls and 6 `fonts.X:getWidth/getHeight` calls per frame
across 1284-1459, interleaved with `Theme.setColor`. Cheap individually; listed
because the extraction in section 3 should group them rather than reproduce the
interleaving.

#### Checked and clean

- **No sorting** in either file. `grep -n "table.sort" views/GrindView.lua
  controllers/GrindController.lua` is empty.
- **No `#` over a large table per frame.** `#self.pool.tables` and `#resolutions` are
  bounded by `Constants.GAMEPLAY.MAX_TABLES`; `#self.hit_boxes` is bounded by
  tables x buttons.
- `bestGridLayout` (1655-1686) is O(n) with n <= MAX_TABLES and is skipped entirely
  while `frozen_grid` holds, so the layout search is not a hot spot.


---

## The table-rendering and chip cluster

Audit scope: `views/TablePanel.lua`, `views/TablePanelStats.lua`, `views/TablePanelEffects.lua`,
`views/FeltLayout.lua`, `views/ChipPile.lua`, `views/ChipFlight.lua`, `views/Chips.lua`,
`views/PokerEventAnims.lua`, `services/BandStack.lua`, `services/FlightSystem.lua`,
`services/DenominationBreakdown.lua`, `data/felt_layout.lua`, `data/pot_tiers.lua`, `data/chips.lua`.

### 1. Structural map

#### `views/TablePanel.lua` — 1725 lines, 26 functions

| Lines | Size | Function | Purpose |
|---|---|---|---|
| 1-84 | 84 | (header + 28 `require`s + 6 layout constants) | Module preamble. 28 requires is the largest import surface in `views/`. |
| 93-100 | 8 | `communityCardCount(tbl)` | Board-card count. Dual path: `playback_state` vs legacy state-name keying. |
| 102-104 | 3 | `holeVisible(tbl)` | `tbl.state ~= "idle"`. |
| 106-112 | 7 | `opponentFaceUp(tbl)` | Showdown reveal. Dual path again. |
| 127-129 | 3 | `drawCardBack` | 1-line alias for `CardSprites.back`. |
| 131-133 | 3 | `drawCardFront` | 1-line alias for `CardSprites.front`. |
| 135-137 | 3 | `drawCardSlot` | 1-line alias for `CardSprites.slot`. |
| 147-153 | 7 | `inCombo(card, combo)` | Linear rank+suit scan over the winning 5. |
| 169-241 | 73 | `drawHistoryBars` | Mini header bar-graph of last N results. |
| 243-397 | **155** | `drawHeader` | Stake name, [x], D toggle, R toggle, history-bar zone. **12 params.** |
| 399-570 | **172** | `drawOpponentSeat` | Seat name (memoized truncation), 2 cards, bb stack / BUSTED. **12 params.** |
| 574-587 | 14 | `drawCommunity` | 5 board slots. |
| 593-747 | **155** | `drawPotLabel` | Pot pile place/sync/clear/draw, detonation handoff, "Pot: $X". |
| 754-810 | 57 | `drawLegacyMttLadder` | Legacy binary-MTT payout pips. |
| 815-852 | 38 | `drawTournamentLadder` | Chip-stack finish-position pips. |
| 860-1004 | **145** | `drawPlayerSeat` | Hole cards + 3-way branch (legacy MTT / chip-stack / cash) + player pile + "Tied up". |
| 1015-1029 | 15 | `_pickFeltButtonFont` | Font/scale fit for felt button. |
| 1031-1044 | 14 | `_drawFeltButtonLabel` | Label blit with scale fallback. |
| 1049-1062 | 14 | `_renderFeltButton` | Button.draw wrapper. |
| 1070-1110 | 41 | `drawFeltButton` | DEAL/REBUY overlay + full-felt hit_box. **11 params.** |
| 1132-1136 | 5 | `GHOST_STYLES` table | Per-action ghost registry (good pattern). |
| 1138-1187 | 50 | `TablePanel.makeGhostFor` | Ghost closure factory. |
| 1196-1244 | 49 | `collectShownCards` | **Re-derives** community/hole/opp card rects already computed by the draw fns. |
| 1251-1280 | 30 | `drawShowdownEmphasis` | Dim losers / grow winners overlay. |
| 1282-1710 | **429** | `TablePanel.draw` | Everything else: scale solve, FX transform, event drain, chrome, felt, layout call, seat loop, DEAL/REBUY, EV, emphasis, pot, hand-name pill, vignette/glow, hit-box lift fixup, debug stash. |
| 1715-1723 | 9 | `TablePanel.drawEmpty` | Placeholder slot. |

Five functions (`draw`, `drawOpponentSeat`, `drawHeader`, `drawPotLabel`, `drawPlayerSeat`) are
**1056 of 1725 lines = 61%** of the file.

#### `views/TablePanelStats.lua` — 1130 lines, 31 functions (13 nested)

| Lines | Size | Function | Purpose |
|---|---|---|---|
| 16-38 | 23 | preamble | 10 requires, 3 debug-tooltip constants. |
| 43-51 | 9 | `binomCoeff(n,k)` | **DEAD** — zero call sites in the repo (see §7). |
| 53-58 / 62-65 / 70-72 / 74-80 | 21 | `fmtMoney`, `fmtMoneySigned`, `evLabel`, `fmtPctClean` | Money/pct formatting. |
| 85-87 | 3 | `row(text, style, color)` | Tooltip row constructor. |
| 89-104 | 16 | `iconRow(game, str, style, color)` | **File-level** IconText row — **never called** (see §7). |
| 110-253 | **144** | `buildCashOverviewRenderRow` | 9-param closure factory; nests `mixWidth`/`drawMixRow`/`calcWidth`/`measure`/`render`. |
| 255-288 | 34 | `buildCashLines` | Cash tooltip rows + focus penalty line. `tbl` param always `nil`. |
| 296-336 | 41 | `buildMttLines` | 8-max KO tooltip. `tbl` param always `nil`. |
| 342-399 | 58 | `buildLegacyMttLines` | Legacy binary MTT tooltip. **Contains the `ev_sign`/`ev_color` bug (383).** |
| 416-417 | 2 | `SHAPES` | F3 debug shape list. |
| 421-471 | 51 | `fmtRatio`, `ratioColor`, `activeRows`, `richestTier`, `hasWinEffects`, `hasLossEffects` | Breakdown helpers. |
| 473-605 | **133** | `buildGridRenderRow` | Debug-only grid; nests `measure`/`render`/`drawSubgrid`. |
| 607-736 | **130** | `buildFocusedRenderRow` | Debug-only focused view. |
| 738-842 | **105** | `buildTotalsRenderRow` | Debug-only totals view. |
| 845-869 | 25 | `appendPayoutLines` | F3 dispatch (`if shape == ...` chain, see §6). |
| 873-892 | 20 | `breakdownFromStats` | Cash/KO/legacy dispatch. |
| 894-896 / 900-903 / 909-916 | 18 | `buildEvBreakdownLines`, `breakdownLinesFor`, `evPerHand` | Public entry points. |
| 928-982 | 55 | `evMetrics` | Rolls EV + stack%, measures the readout. |
| 986-989 | 4 | `measureEvReadout` | Width for FeltLayout. |
| 995-1038 | 44 | `drawEvReadout` | Renders it. **Mutates `Theme.tier.loss.jackpot` at 1018-1021.** |
| 1045-1056 | 12 | `stashDebugTooltipIfHover` | Debug hover stash. |
| 1058-1115 | 58 | `renderDebugTooltip` | Deferred tooltip render. |
| 1119-1128 | 10 | `flushDebugOverlay` | Flush. |

**368 of 1130 lines (33%) — `buildGridRenderRow` + `buildFocusedRenderRow` + `buildTotalsRenderRow` —
are reachable only when `game.debug.payout_shape >= 1` (F3).**

#### Is the TablePanel / TablePanelStats / TablePanelEffects split coherent?

**`TablePanelEffects` — yes.** 139 lines, one axis (screen-space FX that read decaying tween
fields off the model: shake, lift, shadow, border pulse, glow, vignette). It requires only
`Theme` + `ShaderRegistry` and knows nothing about poker. It is exactly the seam you want.

**`TablePanelStats` — no. It is two unrelated modules stapled together, and the staple is
"stuff TablePanel wanted out of its file", not a responsibility.** It currently holds:

1. a **money/percent formatting** utility set (`fmtMoney`, `fmtMoneySigned`, `evLabel`,
   `fmtPctClean`) that is consumed outside this cluster;
2. a **tooltip content builder** (`buildCashLines` / `buildMttLines` / `buildLegacyMttLines`) that
   is pure data-assembly and never touches `love.graphics` at build time;
3. **368 lines of F3-only debug instrumentation** (grid/focused/totals) that has nothing to do
   with a table panel and is dead in every shipped frame;
4. an actual **panel widget** (`evMetrics` / `measureEvReadout` / `drawEvReadout`) — the only part
   TablePanel's per-frame draw path calls;
5. a **generic deferred-tooltip renderer** (`renderDebugTooltip`, 58 lines) that re-implements
   measure-and-lay-out-rows on top of the same row protocol `views/Tooltip` already speaks.

The proof it is a size cut rather than a seam: `TablePanel.draw` calls into Stats **four times**
(`measureEvReadout` 1469, `drawEvReadout` 1588, `breakdownLinesFor` 1628, `stashDebugTooltipIfHover`
1709) and each call is a different one of those five concerns. `buildLegacyMttLines` is a
sibling-in-spirit of `drawLegacyMttLadder`, which lives in TablePanel — the same feature is split
across both files on the "is it a tooltip" axis instead of the "is it legacy MTT" axis.

**The coherent seam is by render band, not by file size.** A panel is five stacked bands, each
with its own model reads, its own layout rect from `FeltLayout`, and its own hit-boxes:
`header` / `opponents` / `community` / `pot` / `bottom` (chips+tied+EV, or a tournament ladder).
`FeltLayout.compute` already returns exactly that shape (`L.opponents`, `L.community`, `L.pot`,
`L.hole`, `L.bottom`) — the layout module has the seam and the render module ignores it.
Cross-cutting concerns (FX, ghosts) stay as sibling modules the way `Effects` already does.

### 2. Decomposition plan for `views/TablePanel.lua`

Actual parameter counts (recount from source — the brief says 13, it is 12 for both):
`drawHeader` 12, `drawOpponentSeat` 12, `drawFeltButton` 11, `drawPlayerSeat` 7, `TablePanel.draw` 9.
The problem is not the count alone, it is that **9 of `drawOpponentSeat`'s 12 args are the same 5
values every call** (`tbl`, `sl`, `fonts`, `L.sizes`, `back_sprite`) plus 4 that are a
destructured rect that `FeltLayout` already returns as a table (`seat.x`, `ob.y`, `seat.w`, `ob.h`).

#### The parameter object

One per-panel, per-frame render context, built once at the top of `TablePanel.draw` and passed by
reference to every band renderer. It replaces `sl`/`fonts`/`s`/`ui_s`/`back_sprite`/`hit_boxes`/
`idx`/`ctx`/`controller` in all 12 signatures:

```lua
-- views/PanelContext.lua
-- P = {
--   tbl, idx, game, controller, ctx,      -- model + DI
--   x, y, w, h,                           -- panel rect
--   felt = { x, y, w, h },
--   s, ui_s,                              -- per-panel + window scale
--   fonts, sl,                            -- draw resources
--   back_sprite,                          -- active deck's card back
--   L,                                    -- FeltLayout.compute result
--   gtype, stake, stake_theme, palette,   -- resolved lookups (see 5-B)
--   hit_boxes,
-- }
```

Built once (~15 lines) instead of the 4 `Lookups.findById` + 5 `StakeThemes[...]` re-lookups
that currently happen per band per frame (§5). Every band function becomes `fn(P, rect)`:

```lua
Seats.draw(P, P.L.opponents)      -- was drawOpponentSeat(opp,i,tbl,seat.x,ob.y,seat.w,ob.h,sl,fonts,L.sizes,ob.cards_y_offset,back_sprite)
Header.draw(P)                    -- was drawHeader(tbl,x,y,w,fonts,hit_boxes,idx,true,cursor_on,rebuy_cursor_on,s,ui_s)
Pot.draw(P, P.L.pot)
Bottom.draw(P, P.L.bottom, P.L.hole)
```

`can_remove` (always `true` at the only call site, 1425) and `cursor_on`/`rebuy_cursor_on` (both
read straight off `controller.ctx` at 1423-1424) disappear entirely — the band reads them from
`P.ctx`.

#### Named files

| New file | Moves | Lines |
|---|---|---|
| `views/panel/PanelContext.lua` | new: builds `P` (scale solve 1293-1305, felt rect 1442-1445, lookups, back-sprite resolve 1389) | ~90 |
| `views/panel/PanelHeader.lua` | `drawHeader` 243-397, `drawHistoryBars` 169-241 | ~230 |
| `views/panel/PanelSeats.lua` | `drawOpponentSeat` 399-570, the seat loop 1496-1507, `holeVisible`/`opponentFaceUp`/`communityCardCount` 93-112, `drawCommunity` 574-587 | ~230 |
| `views/panel/PanelPot.lua` | `drawPotLabel` 593-747, the pot-anchor seeding 1357-1359 / 1520-1523, the legacy `HAND n/m` block 1603-1617 | ~200 |
| `views/panel/PanelBottom.lua` | `drawPlayerSeat` 860-1004, the `elseif L.bottom` fallback 1531-1540 | ~170 |
| `views/panel/PanelLadders.lua` | `drawLegacyMttLadder` 754-810, `drawTournamentLadder` 815-852, the ladder hover hit_box 1622-1630, **and `buildLegacyMttLines`/`buildMttLines` pulled back out of TablePanelStats** | ~200 |
| `views/panel/PanelButtons.lua` | `_pickFeltButtonFont`/`_drawFeltButtonLabel`/`_renderFeltButton`/`drawFeltButton` 1015-1110, `GHOST_STYLES`+`makeGhostFor` 1132-1187, the DEAL/REBUY branch 1546-1582 | ~200 |
| `views/panel/PanelShowdown.lua` | `inCombo` 147-153, `collectShownCards` 1196-1244, `drawShowdownEmphasis` 1251-1280, the hand-name pill 1637-1674 | ~170 |
| `views/TablePanel.lua` (remaining) | `TablePanel.draw` as an ordered call list, `drawEmpty`, the hit-box lift fixup 1697-1703 | **~150** |

`TablePanel.draw` becomes ~110 lines: build `P`, push FX transform, drain script events, chrome,
then eight `X.draw(P, ...)` calls in render order, pop, lift-fixup, debug stash. Requires drop from
28 to ~10 (each band file pulls only what it renders — `MttPayouts` and `Stakes` leave the main
file entirely).

#### Data crossing each boundary

Every boundary is `(P, rect)` in and `nil` out, with three exceptions that must stay explicit
because they are side-channels, not returns:

- **`hit_boxes` append** — `PanelHeader`, `PanelButtons`, `PanelLadders`, and `Stats.drawEvReadout`
  all append. Already carried on `P.hit_boxes`; the `hit_boxes_start` lift-fixup (1329, 1697-1703)
  stays in `TablePanel.draw` and works unchanged because it only reads indices.
- **`AnchorRegistry` writes** — `pot`/`you`/`opp_N`/`center`/`tied:N`/`deal:N`/`rebuy:N`. Six
  different functions currently write the `you` anchor (809, 851, 983, 985, 1516-1519) and four
  write `pot` (734, 1357, 1520). After the split, `PanelPot` owns `pot`, `PanelBottom` +
  `PanelLadders` own `you`, `PanelSeats` owns `opp_N`. The defaults at 1357/1516/1520 move into
  `PanelContext` so seeding happens in exactly one place.
- **`tbl.x` / `tbl.y` stash (1312-1313)** — a view writing model fields. Flagged in §6; it moves
  into `PanelContext` so there is one line to delete when it is fixed properly.

#### The 12-param functions specifically

- `drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts, sizes, cards_y_offset, back_sprite)`
  → `PanelSeats.drawSeat(P, opp, i, seat)` where `seat` is the `{x, w}` entry FeltLayout already
  built at `FeltLayout.lua:185/189` plus `ob.y`/`ob.h`/`ob.cards_y_offset` read from `P.L.opponents`.
  **4 params.** The caller stops destructuring a table the layout module handed it whole.
- `drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove, cursor_on, rebuy_cursor_on, s, ui_s)`
  → `PanelHeader.draw(P)`. **1 param.** All 12 values are already on `P`.
- `drawFeltButton(x, y, w, h, fonts, hit_boxes, idx, label, action, fill_color, enabled)`
  → `PanelButtons.drawFelt(P, spec)` with `spec = { label, action, fill_color, enabled }`.
  **2 params** — the rect is always `P.felt` at both call sites (1559, 1570).
- The three D/R toggle blocks inside `drawHeader` (309-343, 348-382) are **34 lines duplicated
  once** — same Button.draw, same strikethrough, same hit_box, differing only in
  `id`/`glyph`/`color`/`muted-field`. They collapse to one `TOGGLES = { {id="toggle_cursor", glyph="D", …}, {…} }`
  data table + a 20-line loop, killing ~48 lines and matching the `GHOST_STYLES` registry pattern
  already used at 1132.

### 3. The chip stack — ownership map and overlaps

#### Who owns what (as built)

| Module | Layer | Actually owns |
|---|---|---|
| `data/chips.lua` | data | 33-rung denomination ladder (value/color/label), 10 per-stake 4-index palettes, `full_palette`, `tier_chip_target`, `tier_burst_cap` (dead). |
| `services/DenominationBreakdown` | engine | amount → ordered denom-index list. **The only genuinely engine-agnostic module here** — it takes the ladder as a parameter: `breakdown(amount, denominations, palette_indices, tier_chip_target, tier_hint)`. |
| `views/Chips` | view | One chip's pixels (`drawChip`), the stacking geometry (`stackLayout` — grouping, `MAX_PER_COLUMN = 6`, `max_w` tail clipping), the scale constants (`CHIP_RADIUS`, `STACK_OFFSET_Y`, `COL_GAP`), the label font, UI glyphs. |
| `views/ChipPile` | view (keyed singleton) | The **collection**: an ordered `{d, air, gen, ttl}` list per key, take/reserve/accept, change-making, the tidy settle tween, GC, scalar reconciliation. |
| `views/ChipFlight` | view | Flight *composition*: palette selection, fabrication of missing value, multi-destination splitting, the two-leg gather, scatter sizing. |
| `services/FlightSystem` | engine | Projectile queue, bezier, `MAX_IN_FLIGHT = 800` drop-oldest, `MAX_PER_EVENT = 7`, scheduled sounds. Genuinely agnostic. |
| `services/BandStack` | engine | 1-D band allocation. In this cluster only because `FeltLayout` uses it. Genuinely agnostic. |

Call graph, top to bottom:
`TablePanel.drawPotLabel` / `drawPlayerSeat` → `ChipPile.place/sync/draw`;
`PokerEventAnims` + `GrindView` burst drain → `ChipFlight.transfer/explodeTaken/explodeStack/flyChipsList` → `ChipPile.take/reserve/accept` + `FlightSystem.emit*`;
everything geometric bottoms out in `Chips.stackLayout`.

#### Responsibilities in the wrong module

**M-1 (High) — `views/ChipPile` and `views/Chips` both claim engine-agnosticism and both hard-`require` `data/chips`.**
`views/ChipPile.lua:29-31` states: *"Engine-agnostic in the same sense views/Chips is: denominations are opaque indices into a caller-supplied ladder"*. Line 45 is `local ChipData = require("data.chips")`, and lines 105-107, 168, 317-319, 668 read `ChipData.denominations` / `.full_palette` / `.tier_chip_target` directly. Nothing is caller-supplied.
```lua
-- ChipPile.lua:316-320
function ChipPile.compose(value, palette, tier)
    local list = Denoms.breakdown(value, ChipData.denominations,
                                  palette or ChipData.full_palette,
                                  ChipData.tier_chip_target, tier or "medium")
```
Cost: the "liftable into the next idle game" property required by architecture rule 4 is false for two of the three chip modules, and the docstring asserts the opposite so nobody rechecks. `DenominationBreakdown` shows the correct shape — thread the ladder through `ChipPile.place`'s opts, or add a one-time `ChipPile.configure(ladder, targets)`.

**M-2 (Medium) — `ChipPile.layoutAt` (242-253) exists only to serve `ChipFlight.explodeStack`.**
It is `Chips.stackLayout` plus a scale transform, on a path that has no pile at all — the comment at 239-241 says exactly that. `ChipFlight._layoutAt` (64-67) is a one-line forwarder to it, so pure geometry routes `ChipFlight → ChipPile → Chips`. A collection module exporting a stateless layout helper for a caller with no collection is the seam in the wrong place; it belongs in `views/Chips`, with `ChipPile.layoutLocal`/`toScreen` (182-194) as its only other caller.

**M-3 (High) — money-cap arithmetic lives in a view.** `views/PokerEventAnims.lua:135-152` (`potDestinations`) reads `data/stakes`, computes the buy-in cap, subtracts the player's committed chips, and decides how a payout splits between the stack pile and the bankroll pile. Its own comment admits the duplication:
```lua
-- The cap arithmetic mirrors GrindController's resolution branch
-- (new_stack > cap -> overflow), read off the same running stack the panel
-- is displaying.
```
Cost: two independent implementations of the overflow rule. Change the cap in the controller and chips fly into the wrong piles until someone notices; the comment's reassurance that "a disagreement just means the piles reconcile" is only true because `ChipPile.update`'s hard ceiling (686) papers over it a second later.

#### Duplicated geometry / stacking math

**D-1 (High) — `_paletteForAmount` is copy-pasted between a controller and a view.**
`views/ChipFlight.lua:47-59` and `controllers/GrindController.lua:1439-1450` are the same function with the same `PALETTE_MAX_CHIPS = 60`. ChipFlight's comment (41-46) says *"As GrindController's `_paletteForAmount`"* — the duplication is known and not recorded as a defect. Cost: the palette-escape threshold has two homes, so a change in one produces different chip compositions on controller-queued bursts vs. the theater's per-event flights at the same table.

**D-2 (Medium) — scaled-chip rendering written twice.** `ChipFlight._chipFn` (70-82) and `ChipPile.drawChipLocal` (215-227) are the same push/translate/scale/drawChip/pop, one deferred, one immediate:
```lua
-- ChipFlight.lua:75-81              -- ChipPile.lua:221-226
love.graphics.push()                 love.graphics.push()
love.graphics.translate(px, py)      love.graphics.translate(sx, sy)
love.graphics.scale(s, s)            love.graphics.scale(s, s)
Chips.drawChip(0, 0, idx, 1, ...)    Chips.drawChip(0, 0, d, alpha, label, tint)
love.graphics.pop()                  love.graphics.pop()
```
Cost: a chip mid-flight and the same chip once landed are drawn by two code paths that must agree to the pixel — the exact property the collection rewrite exists to guarantee.

**D-3 (Medium) — fabrication written twice inside one file.** `ChipFlight.transfer:255-273` and `ChipFlight.explodeTaken:543-560`: same have-sum loop over `ChipData.denominations[t.d].value`, same `Denoms.breakdown` of the shortfall, same append. They differ only in the source pixel (`source[1]` vs. a random existing chip) and in what `options.fabricate` means (see B-9).

**D-4 (Medium) — `Chips.stackFootprint` (163-182) reimplements `stackLayout`'s column math and is dead.** It carries its own latent bug that nothing exercises: `seen` and `groups` are built (167-172) and `groups` is never read.

**D-5 (Low) — denomination-value lookup written four ways.** `ChipPile.denomValue` (105-108, guarded), `ChipFlight._assignDests` (93-94, **unguarded**), `ChipFlight.transfer` (257-259, guarded inline), `ChipFlight.explodeTaken` (545-548, guarded inline). One `Chips.valueOf(d)` covers all four.

**D-6 (Low) — two different defaults for the same missing tier key.** `DenominationBreakdown.lua:77` falls back to `8`; `ChipPile.lua:668` falls back to `12`. A tier string absent from `tier_chip_target` makes the composer build 8 chips and the tidy-threshold judge 8 against a target of 12 — a permanent, silent disagreement.

**D-7 (Low) — palette scans are mirror images.** `ChipPile.smallestIn` (166-173) scans the palette for the minimum value; `ChipFlight._paletteForAmount` (49-59) scans it for the maximum. Same loop, opposite comparator, different files.

#### Half-migrated leftovers from the in-flight refactor

**P-1 (High) — `e.n_air` is simultaneously tracked and derived, and the derived correction is gated on the tracked value.**
The header (`ChipPile.lua:86-98`) states the design and the reason for it: *"the count is DERIVED from the chips each frame rather than tracked... services/PendingChips released on a timer for exactly this reason... replacing it with exact bookkeeping threw that away."* The code then tracks it incrementally (`e.n_air = e.n_air + #refs` at 548, `math.max(0, e.n_air - 1)` at 576) and only re-derives inside `if e.n_air > 0`:
```lua
-- ChipPile.lua:635-644
if e.n_air > 0 then
    local still = 0
    for _, c in ipairs(e.chips) do
        if c.air then
            c.ttl = (c.ttl or AIR_TTL) - dt
            if c.ttl <= 0 then c.air = nil else still = still + 1 end
        end
    end
    e.n_air = still
end
```
Cost: the self-healing property the comment promises does not hold in the direction that matters. See B-1.

**P-2 (Medium) — legacy pot detonation kept alive in the hot function.** `views/TablePanel.lua:700-729`; its own comment says *"With poker theater on this never fires... This is the legacy build's path"* (707-709), and `controllers/GrindController.lua:592` still raises `pot_explode_pending`. Under the shipped config those 30 lines are unreachable, and they hold the only call site of `ChipPile.takeAll` outside `PokerEventAnims.pot_push` — so "detonate the pot" exists twice (TablePanel 710-729 and PokerEventAnims 232-253) and the two must be kept in sync by hand.

**P-3 (Medium) — four expressions of "what is the pot worth" in 25 lines.** `TablePanel.lua:630-655`:
```lua
if theater then       potval = (tbl.playback_state and tbl.playback_state.pot) or 0
elseif tbl.playback_state and (tbl.playback_state.pot or 0) > 0 then potval = tbl.playback_state.pot
else                  potval = (tbl.outcome_delta and math.abs(tbl.outcome_delta) * 2) or 0 end
...
local pile_val = theater and ((tbl.playback_state and tbl.playback_state.pot) or 0) or potval
```
`pile_val` re-derives branch 1 verbatim. Two of the four are the legacy `outcome_delta * 2` guess that the "Payouts stop pretending to be table money" commit was written to remove.

**P-4 (Medium) — the "collection" refactor left `ChipPile.value` behind.** `ChipPile.value(key)` (285-288) is the scalar-shaped accessor the old model needed; it has zero call sites. The internal `pileValue(e)` (130-134) is what update() uses. Dead surface that invites a future caller back onto the scalar path.

**P-5 (Low) — dead exports across the cluster** (verified by repo-wide grep excluding `build/`): `ChipFlight.fly` (135-155), `ChipFlight.explodeAmount` (639-648), `Chips.stackFootprint` (163-182), `ChipPile.value` (285-288), `BandStack.threeUp` (95-108), `TablePanelStats.binomCoeff` (43-51), and the file-level `TablePanelStats.iconRow` (89-104, shadowed by the local at 367 which is the one actually used). **~110 lines, zero callers.**

**P-6 (Low) — dead data.** `data/chips.lua:139-153 tier_burst_cap` — 6 data lines under a 9-line comment explaining how `options.max_per_event` consumes it; nothing reads it, so high-tier bursts still bottleneck at `FlightSystem.MAX_PER_EVENT = 7` exactly as the comment warns. `data/felt_layout.lua:28-29 space.pot_gap` and `space.you_pad` — `FeltLayout` reads only `edge_pad`/`bottom_pad`/`band_gap`/`name_gap`/`comm_gap`/`hole_gap`.

---

### 4. Correctness bugs

#### Undefined-identifier scan (definitive)

I compiled every `.lua` in `views/ services/ models/ controllers/ states/ utils/ core/ lib/ data/` plus `main.lua` with `luac -p -l` and extracted every `GETTABUP _ENV "name"` (a global read = an undefined local). After removing the standard library and `love`, **the entire repository contains exactly two**:

- `views/TablePanelStats.lua:383` — `ev_sign`, `ev_color` (the known bug)
- `views/ShoveView.lua:404` — `BUILDUP_TOTAL`

**This cluster has no third instance.** `TablePanel.lua`, `TablePanelEffects.lua`, `FeltLayout.lua`, `ChipPile.lua`, `ChipFlight.lua`, `Chips.lua`, `PokerEventAnims.lua`, `BandStack.lua`, `FlightSystem.lua`, `DenominationBreakdown.lua` are all clean. Reproduce with:
```
luac -p -l <file> | grep -oE '_ENV "[A-Za-z_][A-Za-z0-9_]*"' | sort -u
```

**B-0a (High, confirmed) — `views/TablePanelStats.lua:383`.**
```lua
row(string.format("Expected cash: %s$%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
```
`ev_sign`/`ev_color` are locals of `buildCashOverviewRenderRow`'s `render` (208-212), a different function. Renders `Expected cash: nil$12.40 per run`, and `math.abs` strips the sign, so a −EV legacy-MTT table is indistinguishable from a +EV one. `ev_color = nil` also drops the row's color token, so it renders in `Theme.fg.heading` instead of good/error. Fix is 3 lines: recompute the sign and token from `net_ev` locally.

**B-0b (High, out-of-cluster sibling) — `views/ShoveView.lua:404` crashes `love.draw`.**
```lua
if self.phase == "buildup" then
    self.phase   = "ready_to_deal"
    self.phase_t = BUILDUP_TOTAL      -- nil; the real field is self.buildup_total (445)
    return
end
```
`ShoveView:draw` at 879 runs `_drawBuildup` for **both** `"buildup"` and `"ready_to_deal"`, and `_drawBuildup:549` does `math.min(1, self.phase_t / BUILDUP_FADE_DURATION)` → *attempt to perform arithmetic on a nil value*. Reachable only if a draw lands between the skip and `ShoveState` promoting the phase to `"running"`; in the normal keypressed→update→draw order the host promotes first, so this is a latent crash rather than a certain one **(unverified at runtime — confirming needs a skip on a frame where the state's update is skipped or the promotion is deferred)**. The value written is wrong regardless: `self.buildup_total` is the intended constant.

#### Pile / flight lifecycle

**B-1 (High) — a pile can wedge invisible chips forever; the documented safety net cannot fire.**
`ChipPile.update:635` gates the TTL sweep on `e.n_air > 0`. Every path that can zero the counter without clearing `c.air` therefore disarms the sweep permanently:
- `ChipPile.accept` (571-578) decrements on *any* chip whose `gen` matches, including one already landed by a prior TTL expiry — no, that early-returns at 573. But `ChipFlight.transfer:330` and `:342-344`, `_gatherLeg:380` and `:398-400` all call `ChipPile.accept(d and d.key, s.chip)`; if `d` is nil the key is nil, `_piles[nil]` is nil, and the function returns having decremented nothing while the chip stays `air = true` in the pile it was reserved into. `_reserveAcross` only populates `dest_of[i]` when `dests` is non-empty (112), but `slot_of` is populated in the same pass, so `s` non-nil implies `d` non-nil. Reachable instead via `FlightSystem.emit`'s drop-oldest at 85-90: `dropped.on_arrive(...)` fires, `accept` runs, counter drops — correct. 
The concrete unreachable-sweep case is simpler: **`e.n_air` is decremented once per `accept`, but `reserve` increments by `#refs` (548) even when some of those chips get no slot** (`out[i].x` is nil at 558-563 when the `max_w` clip dropped the position). `ChipFlight.transfer:329-330` then takes the `not (sx and sy and dx and dy)` branch and calls `accept`, so that one balances. `explodeTaken:581-582` does the same. So the counter is balanced on every path I can trace — but it is balanced *by four separate call sites each remembering to call `accept` on their bail-out branch*, which is precisely the fragility the header called out. **The fix the comment already prescribes is 2 lines**: delete the `if e.n_air > 0 then` guard so the sweep runs unconditionally, and drop `n_air` as a stored field. Severity is High because the failure mode (a permanently invisible chip inflating `pileValue` and every tidy threshold, on a pile that then never reconciles) is silent and session-long.

**B-2 (Medium) — pile animation state survives a table teardown; only a full state reset clears it.**
`ChipPile.clearAll` (731-733) is called from exactly one place, `states/GrindState.lua:306`, alongside `FlightSystem.clear`. Closing one table does not clear that table's piles. They are reclaimed only by the idle GC at 706:
```lua
if e.idle > GC_SECONDS and e.n_air == 0 then _piles[key] = nil end
```
So a closed table's pot and stack piles hold their `chips`, `settle` tween, `place`, and `palette` for **30 seconds** after the panel stops drawing. Harmless visually (nothing draws them) but it means B-1's wedged-`n_air` case also blocks GC forever (`e.n_air == 0` is a GC precondition), converting an invisible-chip bug into an unbounded key leak.

**B-3 (Medium) — `FlightSystem.clear` is never called on table close, only on full reset.** `services/FlightSystem.lua:321` has one caller, `GrindState.lua:305`. Chips in flight toward a table the player just closed keep flying and keep rendering (`FlightSystem.draw:307-316` walks every entity unconditionally) to an anchor that is now stale. `AnchorRegistry` never removes entries, so the destination coordinates are the closed panel's last position and the chips land on whatever panel now occupies that grid cell. Cost: visible chips flying into the wrong table for up to ~1.7 s after a close.

**B-4 (Medium) — `AnchorRegistry` leaks one entry per anchor per table, forever.**
`services/AnchorRegistry.lua:20` `_anchors` is only ever emptied by `AnchorRegistry.clear()` (hard reset). `Table.anchorKey` (`models/Table.lua:86`) keys on a per-process monotonic `_id`, so every table the player ever opens contributes `center`, `you`, `pot`, and `opp_1..opp_7` = **up to 10 permanent entries**, plus `tied:N` / `deal:N` / `rebuy:N` / `ev:N` keyed by panel index (bounded). A long session that opens and closes a few hundred tables accumulates a few thousand dead `{x, y, w, h, frame}` tables. Slow leak, not a stall — but `AnchorRegistry.age()` (43-47) exists precisely to detect staleness and nothing in this cluster uses it to evict.

**B-5 (Low) — `RollingValue` leaks 4 ids per table.** `TablePanel` creates `table_pot:<id>` (609/657), `table_tied:<id>` (996, 1535), and `TablePanelStats.evMetrics` creates `table_ev:<id>`, `table_stackpct:<id>`, `table_losspct:<id>` (941, 943, 964). Only `table_pot:` is ever `reset` (609), and only on idle — never on table close. `services/RollingValue._v` has no GC.

#### `DenominationBreakdown` edge cases

**B-6 (Low) — amount 0 / negative are handled; huge is capped; non-integer is where it bends.**
- `amount <= 0` → `{}` (63-65). Correct, and `ChipPile.sync`'s `value > 0` guard (308) and `update`'s `e.want <= 0` branch (649) both agree.
- Huge: `MAX_TOKENS = 200` (32) caps both the primary fill (118) and the change loop (131). Correct, and the comment explains why.
- **Non-integer: the epsilon comment is wrong about its own code.** Line 114-116 says *"Relative epsilon, not the absolute 1e-9 the old loop compared against: it has to absorb float residue on a $0.01 rung and on a $5e17 one"* — but line 117 is `math.floor(remaining / primary.value + 1e-6)`, which is just a different **absolute** epsilon. The primary-selection loop at 85 still uses `1e-9`. Concrete: on the `s010` palette (top rung `$100e9`) a `remaining` of `100e9 - 8` (well inside float noise at that magnitude, ULP ≈ 16384 for values near 1e15) rounds unpredictably; the low end works, the high end does not. Cost is bounded — one chip more or less on a 200-chip cap — but the comment will stop the next reader from fixing it.

**B-7 (Low) — unguarded ladder index.** `DenominationBreakdown.lua:70-73`:
```lua
denoms[#denoms + 1] = { idx = idx, value = denominations[idx].value }
```
A palette index outside the ladder is an immediate `attempt to index a nil value`. Today every `stake_palettes` entry maxes at 22 and `full_palette` is exactly `1..33` against 33 denominations, so nothing crashes — but this is the one place in the chip stack that does not guard the lookup (`ChipPile.denomValue:105-108` and `ChipFlight`'s three inline copies all do `(e and e.value) or 0`). Adding a rung to `data/chips.lua` without extending `full_palette`, or a typo'd palette, is a hard crash inside a draw.

**B-8 (Low) — `tierFromUnit` hardcodes 5 / 18 / 80 in an "engine-agnostic" service.** `DenominationBreakdown.lua:38-43`:
```lua
function DenominationBreakdown.tierFromUnit(magnitude)
    if magnitude < 5  then return "small"    end
    if magnitude < 18 then return "medium"   end
    if magnitude < 80 then return "large"  end
    return "jackpot"
end
```
Those three numbers are `data/pot_tiers.lua`'s band boundaries (`small.hi = 3`, `medium.lo = 5`/`hi = 15`, `large.lo = 18`/`hi = 45`, `jackpot.lo = 80`) transcribed into engine code. The module header claims *"Maps a magnitude in caller-defined units... Thresholds match the unit conventions in the consuming data file's tier table"* — i.e. it knows it is coupled and says so instead of taking the table as a parameter, which is exactly what `breakdown` does two functions later. Rule-3 violation (logic that should be a data lookup) and rule-4 violation (poker tuning in `services/`). Three live callers, all in `GrindController` (1507, 1526, 1553).

Note the mismatch it already causes: `tierFromUnit` thresholds are in **big blinds**; `tierFromAmount` (47-54) thresholds are in **dollars** via `log10`. Two functions in one module returning the same tier vocabulary from incompatible units, chosen by which caller happens to have a `bb` handy — `ChipFlight` uses `tierFromAmount` (140, 234, 266, 554), `GrindController` uses `tierFromUnit`. The same $50 payout therefore composes as a different tier depending on which path emitted it.

#### Stacking / overflow

**B-9 (Medium) — `options.fabricate` means two different things in one file.**
`ChipFlight.transfer:255` reads it as a **boolean** flag and takes the target from `options.amount`:
```lua
if options.fabricate and options.amount then
    ...
    local short = options.amount - have
```
`ChipFlight.explodeTaken:543-549` reads it as **the target amount itself**:
```lua
if options.fabricate then
    ...
    local short = options.fabricate - have
```
Both callers happen to pass the right shape today (`PokerEventAnims:271` passes `fabricate = moving > ev.amount` to `transfer`; `:248` passes `fabricate = payout + committed` to `explodeTaken`), so nothing is broken — but passing a number to `transfer` makes it silently use `options.amount` instead, and passing `true` to `explodeTaken` makes `short = true - have`, a **hard arithmetic error on a boolean**. Two APIs, one name, one file.

**B-10 (Medium) — `ChipPile.take` can balloon the pile before the ceiling catches it.**
`take` (439-490) loops up to 400 times, and each miss calls `breakChip` (413-437), which replaces one chip with up to 64 smaller ones via `table.insert` at a position (an O(n) shift each):
```lua
if math.abs(n - ni) > 1e-6 or ni < 2 or ni > 64 then return false end
for j = 1, ni do table.insert(e.chips, i + j - 1, { d = next_d }) end
```
Nothing bounds `#e.chips` during this. Worst case inside one `take`: 400 iterations × an O(#chips) scan at 449-458 with `#chips` growing toward 200·64. The `#e.chips > target * 3` snap at 686 only runs on the **next** `update`, i.e. one frame later. Concrete trigger: a take of an amount smaller than the pile's smallest chip on a stake palette with a 5× ratio between rungs (e.g. `s003 = {3,4,5,6}` = 25c/$1/$5/$25) — the `over` branch keeps breaking down and the `best` branch never satisfies `need`.

**B-11 (Low) — `Chips.stackLayout` can silently return an empty layout, and one caller treats that as "no pile".**
`views/Chips.lua:241-254`: when `max_w` is smaller than one column the drop loop empties `groups` and returns `placed = {}`. `ChipPile.slotsByPos` then returns `{}`, so `reserve` hands back slots with `x = nil` and `ChipFlight.transfer:329` skips the flight entirely (correct, it accepts the chip anyway). But `ChipPile.draw:609` draws nothing while `#e.chips` stays non-zero, so `ChipPile.count(key) > 0` at `TablePanel.lua:982` is true and the `you` anchor is offset by `+18 px` for a pile that is not on screen. Cost: on a very narrow panel, chips fly to a point 18px right of where the (invisible) pile is.

**B-12 (Low) — `MAX_PER_COLUMN` is not scaled.** `views/Chips.lua:29` `MAX_PER_COLUMN = 6` is the one stacking constant `Chips.setScale` (46-54) does not touch, while `CHIP_RADIUS`, `STACK_OFFSET_Y`, `COL_GAP` and `LABEL_FONT_PX` all are. A column's height therefore scales linearly with `ui_scale` while its chip count is fixed, so pile aspect ratio drifts with window size and `FeltLayout`'s `pile_r` reservation (`2 * pile_r`, line 92/134) under-reserves at large scales — the pot pile grows further up over the community cards than the layout budgeted for.

#### Sort stability / flicker

**B-13 (Low, debug-only) — `activeRows` sorts on a non-unique key with an unstable sort.** `TablePanelStats.lua:437-444`:
```lua
table.sort(out, function(a, b) return a.ev_delta > b.ev_delta end)
```
`bd.rows` comes from `models/payout_breakdown`; two sources with identical `ev_delta` (common — every additive perk of the same size) have no tiebreak, `table.sort` is not stable, and the list is rebuilt every frame the tooltip is open. Rows swap positions frame to frame. Only reachable with `game.debug.payout_shape >= 1` (F3), so it is debug-surface flicker, not shipped. Adding `or (a.ev_delta == b.ev_delta and a.name < b.name)` fixes it.

**B-14 (not a bug, checked) — the payout-ladder sorts are stable in effect.** `TablePanel.lua:764-765`, `:819-821` and `TablePanelStats.lua:327-328`, `:352-354` all build an array from `pairs(payout_table)` (nondeterministic order) and then `table.sort` it. Because the keys are distinct numbers and the comparators are strict, the output is a total order and therefore deterministic despite the unstable sort and the nondeterministic input order. No flicker.

#### Other correctness

**B-15 (Medium) — `TablePanel.draw:1375` shadows the panel index.**
```lua
local cursor = tbl.view_event_cursor or 0
local idx    = tbl.script_idx or 0        -- shadows the `idx` parameter (panel index)
for i = cursor + 1, idx do ...
tbl.view_event_cursor = idx
```
Behaviour is correct today because the block uses only the script meaning, and the shadow is scoped to the `if`. But `idx` is used for hit-box identity (`"remove_table:" .. idx`), anchors (`"tied:" .. idx`), and hint keys throughout the same 429-line function; one line added inside this block that means the panel would silently get the script cursor.

**B-16 (Low) — `TablePanel.draw` declares `fonts` twice.** Line 1299 `local fonts = game and game.fonts` (used once, at 1300) and line 1361 `local fonts = game.fonts`. The second shadows the first for the remaining 350 lines. The nil-guard on the first is pointless because 1284 already does `game.fonts` unguarded.

**B-17 (Low) — a view writes cache fields onto a model object.** `TablePanel.lua:463-466` memoizes the truncated seat label onto the opponent: `opp._lbl`, `opp._lbl_w`, `opp._lbl_fh`, `opp._lbl_raw`. The cache key is `(raw_name, slot_w, font_height)`; two different fonts with the same pixel height (e.g. `xs` and `sm` at some `ui_scale`) collide and the stale label survives a font-tier change. MVC violation (rule 2: views never mutate model state) with a real, if rare, visual consequence.

**B-18 (Low) — `drawPlayerSeat` passes 6 args to a 4-arg function.** `TablePanel.lua:874`:
```lua
drawCardSlot(cards_x + card_w + hole.gap, cards_y, card_w, card_h, 1)
```
`drawCardSlot` is `(x, y, w, h)` (135-137). The trailing `1` is silently discarded — and the sibling call on the line above (873) does not pass it. Harmless, but it is a leftover from when this shared `drawCardFront`'s signature.

**B-19 (Low) — `ChipPile` GC does not bump the generation.** `update:706` does `_piles[key] = nil` without incrementing `gen`. A later `entry(key)` recreates it with `gen = 1` (113). Any chip still holding a reference from the pile's previous life with `gen == 1` would pass the identity check at 574. Not currently reachable — the GC requires `e.n_air == 0`, and a chip whose TTL expired has `air = nil` so `accept` early-returns at 573 — but the guard is one refactor away from being load-bearing. `clear()` bumps `gen` for exactly this reason (721); the GC path should too.

### 5. Per-frame cost — the hottest draw path in the game

Baseline for the numbers below: **12 open panels × 7 opponents each, 60 fps**, which is the late-game grind screen. `TablePanel.draw` runs once per panel per frame; everything it calls is on that multiplier unless marked otherwise.

#### The three worst offenders

**C-1 (Critical) — `OutcomeMath.evStats` runs THREE times per cash panel per frame, uncached.**
`models/outcome_math.lua:527` has no memoization (grep for `cache`/`memo` in that file returns nothing). One call does `resolvedOutcome` (a `buildOutcome` plus six distribution-mutation passes over 4 tiers) plus **8 `payoutMult` calls** (4 tiers × win/loss), and allocates `per_tier` + 4 per-tier tables + `pool` + the result = **~15 tables**.

It is entered from three independent places in one panel's draw:
```lua
-- TablePanel.lua:1469  (unconditional, just to size the layout)
local ev_w = Stats.measureEvReadout(tbl, controller, fonts) or 0
      -> evMetrics -> tbl:estimateStats(ctx) -> OutcomeMath.evStats

-- TablePanel.lua:1588  (the actual render — recomputes the identical metrics)
Stats.drawEvReadout(tbl, L.bottom.ev, controller, fonts, hit_boxes, "ev:" .. idx)
      -> evMetrics -> tbl:estimateStats(ctx) -> OutcomeMath.evStats

-- TablePanelStats.lua:1028  (inside drawEvReadout, unconditional)
local lines = buildEvBreakdownLines(tbl, controller)
      -> tbl:debugStats(ctx) -> OutcomeMath.evStats
```
Cost: **36 `evStats` calls and ~540 table allocations per frame** at 12 panels — ~32,000 tables/second, all of them identical to the previous frame's unless an upgrade was bought. `evMetrics` returns a metrics table that `measureEvReadout` throws away after reading one field (`m.total_w`, line 988).
Fix: one `evStats` per (ctx-generation, gtype, stake) per frame, cached the way `PayoutBreakdown.cached` (referenced at `TablePanelStats.lua:852`) already is for the debug shapes; and `drawEvReadout` should take the metrics `measureEvReadout` computed rather than recomputing. **Per-frame, per-panel.**

**C-2 (High) — the EV tooltip's entire line list is built every frame for a hover that has not happened.**
`TablePanelStats.lua:1027-1037`:
```lua
if hit_boxes then
    local lines = buildEvBreakdownLines(tbl, controller)
    if lines then
        hit_boxes[#hit_boxes + 1] = { ..., tooltip = lines }
```
`buildEvBreakdownLines` → `breakdownFromStats` → `buildCashLines` → `buildCashOverviewRenderRow` (110-253), which builds `present_win`, `present_loss`, `TIER_COUNT`, and **five closures** (`mixWidth`, `drawMixRow`, `calcWidth`, `measure`, `render`) plus the returned `{measure, render}` table — every one a fresh allocation capturing 9 upvalues. Then `appendPayoutLines` (845) runs and no-ops.
Cost: ~10 tables + 6 closures per panel per frame, ~190/frame at 12 panels, for data that is read only while the mouse is inside a ~60×20 px rect. The same pattern repeats at `TablePanel.lua:1626-1629` for the legacy-MTT ladder tooltip.
Fix: make `tooltip` a nullary function on the hit_box and let the tooltip renderer call it on hover. **Per-frame, per-panel.**

**C-3 (High) — `Chips.stackLayout` allocates one table per chip per pile per frame, and it is called 3× per pile per frame.**
`views/Chips.lua:277-283` builds `{x, y, idx, with_label, src}` for every chip, plus `groups` / `group_for` / `g.src` arrays (215-226). `ChipPile.draw` (609) calls `layoutLocal(denomList(e, true), place)`, and `denomList` (145-154) itself allocates two arrays. On the same frame `ChipPile.place` (261-273) allocates a fresh `e.place` table, and any `reserve`/`take` adds a `slotsByPos` pass that allocates `out` plus one `{x, y, with_label}` per chip.
Cost at a `medium` tier target of 12 chips, 2 piles (pot + stack) per panel: `12 chips × 2 tables × 2 piles × 12 panels = 576 tables/frame` minimum, rising to **2,400/frame during a jackpot pot** (`tier_chip_target.jackpot = 50`). **Per-chip, per-frame.**
Fix: `stackLayout` is deterministic in `(chip_indices, align, max_w)` — cache the placement on the pile entry and invalidate on any structural change (`take`/`reserve`/`accept`/`tidy` already funnel through `finishSettle`).

#### Per-frame allocations, itemised

| # | Site | What allocates | Rate |
|---|---|---|---|
| C-4 | `FeltLayout.compute` (66-258) | The whole `L` tree: `bands` (1 + 5), `rects` (1 + 5), `seats` (1 + n), `sz` via `scaleSizes`, plus `L.opponents`, `L.community`, `L.pot`, `L.hole`, `L.bottom` and `bottom`'s 4 sub-tables = **~25 tables**. Pure function of its inputs, recomputed unconditionally at `TablePanel.lua:1476`. | per-frame, per-panel → 300/frame |
| C-5 | `Table.anchorKey` (`models/Table.lua:86-88`) | `"table_" .. id .. "_" .. slot` — a fresh string per call. `TablePanel` calls it at 594, 715, 719, 809/851, 964, 1349, 1357×2, 1503 (**once per opponent**), 1516×2, 1520×2; `PokerEventAnims` adds more. | per-frame, per-panel + **per-opponent** → ~20/panel = 240 strings/frame |
| C-6 | `AnchorRegistry.set` (`services/AnchorRegistry.lua:29-31`) | `_anchors[name] = { x, y, w, h, frame = _frame }` — a new table on **every** set, discarding the old one. 14 `Anchors.set` sites in `TablePanel` alone. | per-frame, per-panel → ~170 tables/frame |
| C-7 | `Effects.drawHoverShadow` (`TablePanelEffects.lua:74-78`) | `layers` + 3 `{spread, alpha}` tables, rebuilt every frame even at `lift = 0` where the shadow is invisible. | per-frame, per-panel → 48 tables/frame |
| C-8 | `TablePanel.lua:1451-1452` | `{ Theme.status.good[1], ..., 0.18 }` — a 4-element table allocated every frame for any stake with no `felt_tint` entry. | per-frame, per-panel |
| C-9 | `Chips.drawChip` (`views/Chips.lua:76, 80`) | `c = { c[1]*tint[1], ... }` when a stake tint is set, then `dark = { c[1]*0.55, ... }` **unconditionally** — 1-2 tables **per chip drawn**. | **per-chip** → 288-2,400 tables/frame |
| C-10 | `collectShownCards` (`TablePanel.lua:1196-1244`) | `out` + up to 9 `{card, x, y, w, h}` tables, and it **re-derives geometry the draw functions already computed** (community row_x, hole cards_x, opp seat cards_x) — a second implementation of the same math that must not drift. | per-frame, per-panel, showdown only |
| C-11 | `ChipPile.update` (615-709) | `pairs(_piles)` walk of every pile including 30-second-stale ones from closed tables (see B-2); `pileValue` (130-134) is an O(#chips) sum re-run whenever the reconcile branch is live. | per-frame, global |
| C-12 | `FlightSystem.update` (278-294) | `table.remove(_flying, i)` inside a reverse loop — O(n) shift per arrival. At the 800-entity cap during a jackpot detonation, a burst arriving together is O(n²). | per-frame, global |

#### `string.format` and concatenation inside draw

All of these produce a garbage string every frame:

| Site | Expression | Rate |
|---|---|---|
| `TablePanel.lua:563` | `string.format("%dbb", ...)` — the seat stack label | **per-opponent, per-frame** → 84/frame |
| `TablePanel.lua:425` | `"Seat " .. opp_idx` (anonymous pools) | **per-opponent, per-frame** |
| `TablePanel.lua:272, 313, 352` | `"remove_table:" .. idx`, `"toggle_cursor:" .. idx`, `"toggle_rebuy_cursor:" .. idx` | per-frame, per-panel |
| `TablePanel.lua:609, 657, 996, 1535` | `"table_pot:" .. (tbl._id or 0)`, `"table_tied:" .. ...` | per-frame, per-panel |
| `TablePanel.lua:744, 998, 1534` | `"Pot: " .. Format.moneyExact(...)`, `"Tied up  " .. Format.moneyExact(...)` | per-frame, per-panel |
| `TablePanel.lua:1082, 1086` | `action .. ":" .. idx` — twice for the same string | per-frame, per-panel (idle only) |
| `TablePanel.lua:1530, 1537, 1589` | `"tied:" .. idx`, `"ev:" .. idx` | per-frame, per-panel |
| `TablePanel.lua:805, 847` | `string.format("%d:%dx", ...)` | **per-pip, per-frame** (tournament panels) |
| `TablePanel.lua:902, 921, 923, 925` | `"Depth  %dbb"`, `"%dth"`, `"FINISH %s"`, `"%d/%d ALIVE"` | per-frame, per-panel (tournament) |
| `TablePanel.lua:1558` | `string.format("REBUY %s", ...)` | per-frame, per-panel (busted + idle) |
| `TablePanel.lua:1615` | `string.format("HAND %d/%d", ...)` | per-frame, per-panel (legacy MTT) |
| `TablePanelStats.lua:949, 968` | `string.format("%.1f%%", ...)` ×2 — and via C-1 these run **twice per panel** | per-frame, per-panel ×2 |
| `TablePanelStats.lua:159, 164, 167, 204, 217-218, 228, 242` | 8 `string.format` calls inside `buildCashOverviewRenderRow`'s `calcWidth`/`render`, reached every frame via C-2 | per-frame, per-panel |

Roughly **550-700 short-lived strings per frame** at 12 panels. Everything keyed by `idx` or `tbl._id` is constant for the panel's whole lifetime and can be built once and cached on the panel context (§2's `P`).

#### Repeated lookups inside draw

**C-13 (Medium) — `Lookups.findById` is a linear scan and runs per-opponent.**
`utils/lookups.lua:10-17` is an `ipairs` scan. `TablePanel` calls it at **402 and 552 inside `drawOpponentSeat`** — i.e. twice per opponent per frame — plus 879, 893, 1463, 1553, 1624. At 12 panels × 7 opponents that is **168 scans/frame over `data/game_types` and `data/stakes`** for values that are identical for every seat at the table. Hoisting `gtype` and `stake` into the panel context (§2) removes all of them.

**C-14 (Low) — `StakeThemes[tbl.stake_id]` is re-indexed 5× per panel per frame** (`TablePanel.lua:599, 685, 967, 1396, 1449`), each time for the same table. Cheap individually; it belongs on `P` with `gtype`/`stake`.

**C-15 (Low) — `Theme` reads.** 41 `Theme.setColor` calls in `TablePanel` + 8 in `Chips`. Each is 1-2 hash lookups plus a `love.graphics.setColor`; `Theme.setColor` (`views/Theme.lua:59-66`) allocates nothing, so this is not a GC problem — but `Theme.bg`/`Theme.status` must be read per-frame by design (`views/Theme.lua:25-26`: *"Consumers MUST read Theme.bg.widget per-frame, not cache"*), so these are correct as written and should not be "optimised" into locals.

**C-16 (Low) — `Chips.drawChip` saves and restores the font per labelled chip.** `views/Chips.lua:89-98`: `love.graphics.getFont()` → `setFont(label)` → `print` → `setFont(prev)`. Two driver state changes per labelled chip; `stackLayout` labels one chip per column, so ~2-4 columns × 2 piles × 12 panels = ~100 font swaps/frame. **Per-chip (labelled), per-frame.**

---

### 6. Layering violations and hardcoded colors / paddings

**L-1 (High, CONFIRMED) — `views/TablePanelStats.lua:1018-1021` mutates the shared `Theme` table mid-frame and restores it.** The report is accurate. Verbatim:
```lua
local old_color = Theme.tier.loss.jackpot
Theme.tier.loss.jackpot = { 0.55, 0.25, 0.85 }
TierGlyph.draw(lx + m.r, ty + m.text_h - m.r, "jackpot", m.r, "loss")
Theme.tier.loss.jackpot = old_color
```
`Theme.tier` is repointed straight at `PaletteData.palettes[name].tier` by `Theme.setActive` (`views/Theme.lua:37`), so this writes into **`data/theme.lua`'s live palette table** — the shared, process-wide data file — not into a copy. Costs:
1. It is a write into `data/`, which the architecture rules require to be logic-free *and* is implicitly assumed immutable everywhere else.
2. The restore is not exception-safe: any error inside `TierGlyph.draw` leaves the global loss-jackpot color permanently purple for every tooltip, glyph, and history bar in the game until the palette is cycled.
3. It allocates a fresh `{0.55, 0.25, 0.85}` table on every draw of every panel showing the loss readout (per-frame, per-panel).
Fix: `TierGlyph.draw` should take an optional color override argument; the caller passes it instead of reaching into the palette. It is a 2-line signature change.

**L-2 (High) — literal colors outside `data/theme.lua`.** Rule 3 audit `rg "love\.graphics\.setColor\(\s*\d"` is clean, but the violation moved one level up into `Theme.setColor` with an inline table:
```lua
views/TablePanel.lua:1435       Theme.setColor({ 0.65, 0.35, 0.95 })   -- "anti-banked" trim
views/TablePanelStats.lua:1019  Theme.tier.loss.jackpot = { 0.55, 0.25, 0.85 }
views/TablePanelStats.lua:1023  Theme.setColor({ 0.55, 0.25, 0.85 })
views/TablePanelStats.lua:550   Theme.setColor({1, 1, 1}, 0.03)        -- zebra stripe
views/TablePanelStats.lua:691   Theme.setColor({1, 1, 1}, 0.03)        -- same
views/TablePanelStats.lua:820   Theme.setColor({1, 1, 1}, 0.03)        -- same
```
The two purples are the same anti-chip color written twice, 4 lines apart, with no shared name — exactly the drift the rule exists to prevent (the `{chip}` banked trim two lines above at 1430 correctly uses `Theme.currency.chip`). The three `{1,1,1}` zebra stripes want one `Theme.bg.stripe` token. **A grep that would catch this class: `rg "setColor\(\s*\{" --type lua`.**

**L-3 (Medium) — `views/TablePanelEffects.lua` holds five literal colors as module constants** (23, 27, 28):
```lua
local SHADOW_COLOR      = { 0, 0, 0 }
local GLOW_COLOR        = { 1.00, 0.85, 0.30 }   -- warm gold
local SHADER_PASS_COLOR = { 1, 1, 1 }
```
`GLOW_COLOR` is the jackpot gold and duplicates `Theme.currency.chip`'s intent; `SHADOW_COLOR` and `SHADER_PASS_COLOR` are structural (a shadow is black, an identity tint is white) and are the defensible cases. Same file also holds 8 literal pixel constants (`SHAKE_MAX_PX 8`, `LIFT_MAX_PX 18`, `BORDER_PULSE_MAX_W 10`, `SHADOW_DROP_X/Y 4/8`, `GLOW_RECT_PAD 80`) that are never scaled by `ui_scale` — so at a large window the shake amplitude and the drop shadow stay at their 1× size while everything around them grows.

**L-4 (Medium) — a view mutates the model.** Three sites:
- `TablePanel.lua:1312-1313` — `tbl.x = x; tbl.y = y`. The comment (1307-1311) explains why (the resolution emitter needs the panel rect), but `AnchorRegistry` is the mechanism that already exists for exactly this and is used on the next line (1349) for the same table. Two parallel channels for "where is this panel", one of which writes through the model.
- `TablePanel.lua:611-612` — `tbl.pot_exploded = nil; tbl.pot_explode_pending = nil` inside `drawPotLabel`. A draw function clearing gameplay flags.
- `TablePanel.lua:463-466` — the seat-label memo written onto the opponent object (see B-17).
- `TablePanel.lua:1382` — `tbl.view_event_cursor = idx`. The view owns the script-playback watermark, so the animation cursor advances only while the panel is on screen. Arguably correct (the events *are* view effects), but it means a table scrolled out of the grid silently stops draining its script.

**L-5 (Medium) — `if shape == ...` string chain where a registry is required.** `TablePanelStats.lua:861-867`:
```lua
if shape == "grid" then      lines[#lines+1] = buildGridRenderRow(game, bd)
elseif shape == "focused" then lines[#lines+1] = buildFocusedRenderRow(game, bd)
elseif shape == "totals" then  lines[#lines+1] = buildTotalsRenderRow(game, bd) end
```
`SHAPES` (416) is already the ordered name list; making it `SHAPES = { grid = buildGridRenderRow, ... }` plus an order array turns this into one lookup and makes adding a shape a single entry, which is what rule 3 asks for. `TablePanel.lua:1132-1136`'s `GHOST_STYLES` is the correct pattern in the same cluster.

**L-6 (Medium) — game-type dispatch by field-probing, three times over.** `TablePanel.lua:880` (`gtype.hand_count and not gtype.chip_stack_table`), `:888` (`gtype.chip_stack_table`), `:1464`, `:1603-1604`, `:1623`, and `TablePanelStats.lua:877-882` all re-derive "which of the three table kinds is this" from the presence of data fields. Six copies of the same three-way decision; a `gtype.panel_kind = "cash" | "ko" | "legacy_mtt"` field in `data/game_types.lua` plus a renderer registry collapses all of them.

**L-7 (Low) — `TablePanel` mutates its own module-level layout constants during draw.** Lines 1301-1305:
```lua
HEADER_H = math.max(sm_h + 4, math.floor(HEADER_H_BASE * s))
FELT_INSET = ...; REMOVE_BTN_SIZE = ...; DEAL_BTN_W = ...; DEAL_BTN_H = ...
```
These are file-locals (67-71) rewritten per panel, so `drawHeader` and `drawFeltButton` read them as implicit globals rather than parameters. Any future path that draws a header outside `TablePanel.draw` gets the *previous* panel's sizes. They belong on the panel context object from §2.

**L-8 (Low) — magic paddings scattered through the render.** `+ 8` (header text x, 261/391/393), `+ 4` / `- 4` (button gaps, 266, 305-306, 341, 380), `card_gap = big and 6 or 3` (413), `label_pad = 6` (443), `+ 18` (the pile anchor nudge, 983), `+ 16` / `+ 8` (tooltip offsets, `TablePanelStats.lua:1089-1090`), `pad = 8` (`_pickFeltButtonFont`, 1016). `data/felt_layout.lua` exists as the home for exactly these and already holds `edge_pad`/`band_gap`/`name_gap`; none of the above went in.

**L-9 (Low) — `services/DenominationBreakdown.tierFromUnit` embeds `data/pot_tiers.lua`'s numbers in engine code** (see B-8). Rule 4: an engine-layer service should not know that 18 big blinds is a "large" pot.

---

### 7. Dead code and dual code paths kept for the legacy table model

Consolidated; individual entries are cross-referenced to §3/§4.

#### Unreachable in the shipped build (`PROTOTYPE_MODE = false`, `FEATURES.POKER_THEATER` on)

| Lines | What | Evidence |
|---|---|---|
| `TablePanel.lua:700-729` (30) | Legacy pot detonation via `pot_explode_pending`. | Its own comment, 707-709: *"With poker theater on this never fires... This is the legacy build's path."* Still fed by `GrindController.lua:592`. |
| `TablePanel.lua:634-638, 653-655` | The `outcome_delta * 2` pot estimate and its `pile_val` twin (P-3). | `if theater then` takes branch 1 unconditionally. |
| `TablePanel.lua:93-99, 106-112` | The state-name fallbacks in `communityCardCount` / `opponentFaceUp` (`s == "flop"` → 3, etc.). | Both early-out on `tbl.playback_state`, which the theater always populates. |
| `TablePanel.lua:749-810` (57) + `TablePanelStats.lua:342-399` (58) | The whole legacy binary-MTT feature: `drawLegacyMttLadder` + `buildLegacyMttLines`. | Gated on `gtype.hand_count and not gtype.chip_stack_table`, i.e. `FEATURES.MTT_KO` off. **This is where the `ev_sign`/`ev_color` bug lives (B-0a) — it survived because the code path is dark.** |
| `TablePanel.lua:1600-1617, 1619-1630` | The `HAND n/m` counter and the ladder hover hit_box, same gate. | |
| `GrindController.lua:1476-1496` | `_emitDealChips`, whose own comment is *"DEAD under the theater"* and which returns immediately on `FEATURES.POKER_THEATER`. | |

That is **~230 lines of TablePanel + TablePanelStats** (13% of the two files) that never execute in the shipped configuration, concentrated in the four largest functions.

#### Dead with no caller at all (verified repo-wide, `build/` excluded)

| Site | Lines |
|---|---|
| `views/ChipFlight.lua:135-155` `ChipFlight.fly` | 21 |
| `views/ChipFlight.lua:639-648` `ChipFlight.explodeAmount` | 10 |
| `views/Chips.lua:163-182` `Chips.stackFootprint` (also reimplements `stackLayout`, D-4) | 20 |
| `views/ChipPile.lua:285-288` `ChipPile.value` (the pre-refactor scalar accessor, P-4) | 4 |
| `services/BandStack.lua:95-108` `BandStack.threeUp` | 14 |
| `views/TablePanelStats.lua:43-51` `binomCoeff` | 9 |
| `views/TablePanelStats.lua:89-104` file-level `iconRow` — shadowed by the local at 367, which is the one actually used at 396 | 16 |
| `data/chips.lua:139-153` `tier_burst_cap` (P-6) | 15 incl. comment |
| `data/felt_layout.lua:28-29` `space.pot_gap`, `space.you_pad` | 2 |

**~111 lines of code + 17 of data.** Note `ChipFlight.flyChipsList` and `ChipFlight.explodeStack` are **live** (`views/GrindView.lua:1103` and `:1093` respectively) — only `fly` and `explodeAmount` are dead.

#### Debug-only, always compiled, never drawn in a normal session

`views/TablePanelStats.lua:473-842` — `buildGridRenderRow` (133) + `buildFocusedRenderRow` (130) + `buildTotalsRenderRow` (105) = **368 lines, 33% of the file**, reachable only when `game.debug.payout_shape >= 1` (F3, cycled from `controllers/InputController.lua:99`). Their supporting helpers (`fmtRatio`, `ratioColor`, `activeRows`, `richestTier`, `hasWinEffects`, `hasLossEffects`, 421-471) add 51 more. They are legitimate tooling, but they are the single largest reason `TablePanelStats.lua` is 1130 lines, and the file's own docstring (1-14) does not mention them at all — it lists only the EV readout and the backtick overlay. They belong in `views/debug/PayoutShapes.lua`, leaving a ~700-line stats module.

#### Duplicated legacy-vs-current pairs that must be edited together

- **"Detonate the pot"** — `TablePanel.lua:710-729` (legacy) and `PokerEventAnims.lua:232-253` (theater). Different fabrication handling, different destination lists, same intent.
- **"Where does a payout land"** — `PokerEventAnims.potDestinations:135-152` (view) and `GrindController`'s resolution branch (M-3).
- **`_paletteForAmount`** — `ChipFlight.lua:49-59` and `GrindController.lua:1441-1450`, byte-identical (D-1).
- **Card-rect geometry** — computed in `drawCommunity`/`drawPlayerSeat`/`drawOpponentSeat` and re-derived in `collectShownCards` (C-10).
- **Per-hand model** — anything touched here must be mirrored into `models/Table_legacy.lua` (`anchorKey` at :86, `view_event_cursor` at :395/613/781/889 already exist in both), per the project's `PROTOTYPE_MODE` rule.

---

## The legacy fork — Table vs Table_legacy, HandScript vs HandScript_legacy, MttSession vs MttSession_legacy


### 1. The selection mechanism

The fork is **decided in exactly one place**, but it is **not honoured in three others**.

**The single switch — `models/TablePool.lua:16-19`:**

```lua
local Constants = require("data.constants")
local Table     = Constants.FEATURES.MTT_KO
                  and require("models.Table")
                  or  require("models.Table_legacy")
```

That is a *load-time* `require` bound to a file-local upvalue. `Constants.FEATURES.MTT_KO = not C.PROTOTYPE_MODE` (`data/constants.lua:62`), and `C.PROTOTYPE_MODE = false` (`data/constants.lua:19`), so **today `Table_legacy.lua` / `HandScript_legacy.lua` / `MttSession_legacy.lua` are unreachable in a normal boot**. They only come alive when someone flips line 19 back to `true` to cut an itch build (`data/constants.lua:14-18` says exactly that: "Set back to true before building for itch").

The two legacy leaf models are pulled in transitively, never directly:
- `models/Table_legacy.lua:51` `local MttSession = require("models.MttSession_legacy")`
- `models/Table_legacy.lua:60` `local HandScript = require("models.HandScript_legacy")`

So the fork is a **three-file family swap driven by one boolean**, which is the good news. The bad news is the rest:

**The companion data fork — `data/game_types.lua:35-84`.** The `mtt` gtype entry is rewritten by the same flag:

```lua
local mtt_ko    = Constants.FEATURES.MTT_KO
local mtt_entry
if mtt_ko then
    mtt_entry = { ... seats = 7, chip_stack_table = true, starting_stack_bb = 10, ... }
else
    mtt_entry = { ... seats = 5, hand_count = 8, binary_outcome = true, ... }
end
```

**Severity: High.** This puts logic in `data/` — a direct Rule 3 violation (`data/` is supposed to be logic-free tables), and it means the flag has two independent consumers that must agree. `chip_stack_table` is read only by `Table.lua`; `binary_outcome` is read only by `Table_legacy.lua` + `controllers/GrindController.lua:232`. Set `MTT_KO` on but somehow load `Table_legacy` and MTT tables would deal forever and never settle.

**Three call sites that bypass the switch and hard-require the NEW model regardless of the flag:**

| file:line | code | effect in a PROTOTYPE_MODE=true build |
|---|---|---|
| `controllers/GrindController.lua:13` | `local TableModel = require("models.Table")  -- only for anchorKey()` | Loads `Table.lua` + `MttSession.lua` + `HandScript.lua` into a build that runs `Table_legacy`. Two Table modules resident at once. |
| `views/TablePanel.lua:38` | `local Table = require("models.Table")` | same |
| `views/PokerEventAnims.lua:25` | `local Table = require("models.Table")` | same |

**Severity: Medium (latent Critical).** All three only call `Table.anchorKey`, which is byte-identical in both files (`models/Table.lua:86-88` == `models/Table_legacy.lua:86-88`), so it happens to work. But it means the "legacy build" always has the *new* module graph loaded too, and any future use of a second `Table.*` static from these files silently reads the wrong model's constant. The fix is one line: expose `anchorKey` from a tiny shared module or route the require through `TablePool`.

**`GrindController.lua:232` — the outcome-shape fork inside the controller:**

```lua
local won_legacy = gtype and gtype.binary_outcome
local is_win = gtype and (won_ko or won_legacy)
```

This one reads the *gtype field* rather than the flag, which is the right pattern; noted for completeness because it is a fourth place the two families diverge.

**Every `Constants.PROTOTYPE_MODE` / `FEATURES.*` read that changes a code path** (full census, non-`build/`):

| flag | value today | read sites |
|---|---|---|
| `PROTOTYPE_MODE` (direct) | `false` | `controllers/GrindController.lua:253`, `:452` — analytics payload field only, no branch |
| `FEATURES.MTT_KO` | **true** | `models/TablePool.lua:17` (module swap), `data/game_types.lua:35` (gtype swap), `views/GrindView.lua:327` |
| `FEATURES.POKER_THEATER` | **true** | `models/Table.lua:508`, `models/Table_legacy.lua:610`, `controllers/GrindController.lua:1477`, `:1589`, `views/TablePanel.lua:630` |
| `FEATURES.TUTORIAL` | **true** | `controllers/GrindController.lua:1046`, `:1074`; `controllers/HintController.lua:48`; `data/catalog.lua:998`; `states/GrindState.lua:124`; `states/ShoveState.lua:243`; `views/CatalogModal.lua:328`, `:403`, `:1104`; `views/GrindView.lua:1350`, `:1524`, `:1624`, `:1859`, `:2248`, `:2260`; `views/OnboardingModal.lua:24`, `:52` |
| `FEATURES.HIGH_TIER_STAKES` | **true** | `controllers/GrindController.lua:1159` |
| `FEATURES.DEV_HOTKEYS` | **true** | `main.lua:259`, `states/GrindState.lua:378`, `states/ShoveState.lua:401` |
| `FEATURES.DECKS` | **true** | `models/Decks.lua:26`, `views/GrindView.lua:222` |
| `FEATURES.DEMO_CUT` | **false** | `models/shove_rate.lua:107`, `:118`; `states/ShoveState.lua:183`; `views/ShoveView.lua:351`, `:1033` |
| `FEATURES.QUIT_DISABLED` | **false** | `views/SettingsModal.lua:312` |
| `FEATURES.ONBOARDING_MODAL` | **false** | `states/GrindState.lua:209` |

The switch is therefore **centralized for the model family, scattered for everything else** — 40+ branch points across 15 files all keyed off one boolean, with no way to test a build other than editing `data/constants.lua` and rebooting.

### 2. Precise divergence report

Method: each file was split function-by-function with an awk extractor and every
matching pair `diff -u`'d. Counts below are real diff lines, not eyeballing.

#### 2a. `models/Table.lua` (1022) vs `models/Table_legacy.lua` (1044)

| function | in Table | in Table_legacy | identical? | notes |
|---|---|---|---|---|
| `Table.anchorKey` | ✅ 86 | ✅ 86 | **yes (0 diff lines)** | safe for the cross-family requires in §1 |
| `resolveTimeline` | ✅ 93 | ✅ 93 | **yes (0)** | |
| `pickRandomName` | ✅ 102 | ✅ 118 | **yes (0)** | only surrounding comments differ |
| `constructHand` | ✅ 329 | ✅ 492 | **yes (0)** | rejection sampler shared |
| `Table:fillOpponents` | ✅ 209 | ✅ 463 | **yes (0)** | |
| `Table:liveStats` | ✅ 967 | ✅ 938 | **yes (0)** | |
| `Table:isBusy` | ✅ 981 | ✅ 952 | **yes (0)** | |
| `Table:new` | ✅ 116 | ✅ 371 | yes, modulo comments (7 lines, all comment) | |
| `Table:tableOutcome` | ✅ 991 | ✅ 969 | **NO** | `OutcomeMath.buildOutcome` vs the legacy in-file copy — see 2b |
| `Table:setStake` | ✅ 227 | ✅ 481 | **NO** | new adds `self:_clearChipStackState()` |
| `Table:update` | ✅ 686 | ✅ 721 | **NO** (17) | new adds `_reconcileChipFlow()` at the settling transition and `chip_stack_table` on `_pending_resolution` |
| `Table:deal` | ✅ 353 | ✅ 516 | **NO (233 diff lines)** | the big one — see 2c |
| `Table:_finalizeHand` | ✅ 847 | ✅ 871 | **NO (62)** | new: bust detection / plan reconcile / finish position. Legacy: `hands_won >= hand_count` |
| `Table:_endTournament` | ✅ 951 | ✅ 928 | **NO (10)** | signature `(finish_position, n_seats)` vs `()` |
| `Table:debugStats` | ✅ 1001 | ✅ 979 | **NO (30)** | new delegates to `OutcomeMath.evStats`; legacy hand-rolls the EV sum |
| `Table:estimateStats` | ✅ 1007 | ✅ 1013 | **NO (29)** | same |
| `Table:_clearChipStackState` | ✅ 246 | ❌ | new only | |
| `Table:_initChipStackIfNeeded` | ✅ 258 | ❌ | new only | |
| `Table:_reconcileChipFlow` | ✅ 288 | ❌ | new only | |
| `sampleDist` | ❌ | ✅ 102 | **legacy-only copy** | canonical at `outcome_math.lua:75` |
| `distCopy` | ❌ | ✅ 127 | legacy-only copy | `outcome_math.lua:94` |
| `distAddInPlace` | ❌ | ✅ 137 | legacy-only copy | `outcome_math.lua:105` |
| `distClampAndNormalize` | ❌ | ✅ 144 | legacy-only copy | `outcome_math.lua:113` |
| `shiftApplies` | ❌ | ✅ 166 | legacy-only copy | `outcome_math.lua:132` |
| `sumFills` | ❌ | ✅ 172 | **legacy-only copy, DRIFTED** | see F1 |
| `fillRatio` | ❌ | ✅ 185 | **legacy-only copy, DRIFTED** | see F2 |
| `lerpDist` | ❌ | ✅ 198 | legacy-only copy | `outcome_math.lua:189` |
| `buildOutcome` | ❌ | ✅ 212 | **legacy-only copy, DRIFTED** | inherits F1+F2 |
| `sampleOutcome` | ❌ | ✅ 325 | **legacy-only copy, DRIFTED** | see F3 |
| `applyTierShift` | ❌ | ✅ 351 | legacy-only copy | `outcome_math.lua:358` — behaviourally identical |
| `rollTierMagnitude` | ❌ | ✅ 363 | legacy-only copy | `outcome_math.lua:501` — identical |
| `tierAvgBB` | ❌ | ✅ 963 | legacy-only copy | `outcome_math.lua:509` — identical |

**13 pure-copy math functions live only in `Table_legacy.lua` (lines 102-370, ~270 LOC).**
Four of them have silently drifted from the canonical `models/outcome_math.lua`.
This is the whole problem in one sentence: `Table.lua` was refactored to *call*
`outcome_math`; `Table_legacy.lua` still *contains* a fork of it frozen at
commit `7eea9bb` (2026-05-27), with one hand-applied patch (`8df7a58`).

#### 2b. `models/HandScript.lua` (574) vs `models/HandScript_legacy.lua` (420)

| function | new | legacy | identical? | notes |
|---|---|---|---|---|
| `urand`, `pickWeighted`, `r2`, `splitPot`, `beat`, `emit`, `emitDeal`, `actionOrder` | ✅ | ✅ | **yes (0 diff lines each)** | |
| `HandScript.write` | ✅ 517 | ✅ 363 | **yes (0)** | orchestrator unchanged |
| `plan` | ✅ 173 | ✅ 135 | **NO (108)** | all additions are alive-seat / forced-winner / bust-target logic |
| `newWriterState` | ✅ 374 | ✅ 262 | **NO (21)** | adds `stack_remaining` |
| `emitBlinds` | ✅ 431 | ✅ 300 | **NO (12)** | adds `capChips` on blinds |
| `runStreet` | ✅ 450 | ✅ 311 | **NO (37)** | adds all-in / capped-call emission |
| `capChips` | ✅ 362 | ❌ | new only | |
| `nextAlive` / `firstAliveAt` | ✅ 153/163 | ❌ | new only | |

**Verdict: HandScript's divergence is safe.** Every new branch degrades to the
legacy behaviour when `alive_seats` and `seat_stacks` are nil, which is exactly
what cash tables pass (`newWriterState`: "cash games leave seat_stacks=nil → all
entries default to huge, no caps trigger"; `capChips` returns `(requested, false)`
when `stack_remaining` is nil). No cash-game behaviour change. **The 154-line
delta is 100% MTT-KO feature, 0% drift.** `HandScript_legacy.lua` has exactly one
commit (`7eea9bb`, its own creation) and has never been patched.

#### 2c. `models/MttSession.lua` (450) vs `models/MttSession_legacy.lua` (79)

These are not two versions of one thing — they are two different designs sharing
five method names.

| method | new | legacy | identical? |
|---|---|---|---|
| `new` | ✅ 63 | ✅ 25 | **NO** — new adds `last_finish`, `plan` |
| `begin` | ✅ 74 | ✅ 33 | **NO** — legacy zeroes `hands_won`; new does not (deliberate: it's a lifetime counter there) |
| `isPlaying`, `winHand`, `drainPayout` | ✅ | ✅ | **yes** |
| `settle` | ✅ 423 | ✅ 60 | **NO** — new keys `payouts[n_seats - finish + 1]`; legacy keys `payouts[hands_won]` |
| `reset` | ✅ 442 | ✅ 72 | **NO** — new also nils `last_finish`, `plan` |
| `planRun`, `currentHand`, `advanceHand`, `reconcile`, `_pickSurvivor`, `_placeBusts` | ✅ | ❌ | new only (371 of the 450 lines) |

`models/MttSession_legacy.lua:1` still declares `-- models/MttSession.lua` in its
header — **Nit**, but it is the kind of thing that makes a grep-based mirror check
miss the file.

### 3. Drift that is already a live bug

Git proves the drift rather than suggesting it. Since `7eea9bb` created the
legacy trio (2026-05-27), the commit sets are:

```
git log --oneline -- models/Table.lua          # 30 commits, 4 post-fork
5b79adc  Add payout multiplier breakdown UI, outcome math refactor...   BOTH
f64112f  Payouts stop pretending to be table money                      BOTH
aa1b09c  Deck overhaul: generic capability effects                      Table.lua ONLY  <-- F1-F5
5487b73  8-max KO rebalance: 10bb turbo stacks                          Table.lua ONLY  (MTT-only, benign)
4321963  Tutorial hint system                                           Table.lua ONLY  (comment only)
45f7609  Readability pass: Gold Chip currency, tier glyphs, EV tooltips Table.lua ONLY  <-- F6

git log --oneline -- models/Table_legacy.lua   # 5 commits total
8df7a58  Juice + readability pass                                       Table_legacy ONLY <-- F7 (reverse drift)
```

`aa1b09c` is the single commit responsible for almost all of the live damage. Its
own message says it introduced *"per-resolve tier-bump/payout-double"*,
*"tier floors/ceilings, tier-scoped WC fills"*, *"per-tier and bankroll-scaled
earnings"*, *"fill-window widen/cascade"* — all of it into `Table.lua` and
`outcome_math.lua` and none of it into `Table_legacy.lua`.

---

**F0 — CRITICAL. Loading a prototype-build save in a KO build crashes on the first MTT deal.**

`models/Table.lua:410-413`:
```lua
            local n_seats = (gtype.seats or 0) + 1
            local alive_opps = 0
            for s = 1, n_seats do
                if s ~= self.player_seat_fixed and not self.seat_busted[s] then
```
Chain: a prototype build autosaves mid-tournament, so `active_table_mtt_state[i] = "playing"`
while `active_table_seat_stacks` is never written (Table_legacy has no such field).
Load that save in a `MTT_KO = true` build:
1. `models/TablePool.lua:89-91` restores `t.mtt.state = "playing"`, `t.mtt.plan = nil`.
2. `models/TablePool.lua:96-101` `if gt and gt.binary_outcome then` — **does not fire**, because in a KO build `data/game_types.lua` swapped the entry and it carries no `binary_outcome` field. The exploit guard is flag-coupled to the wrong side.
3. `models/TablePool.lua:102` `if seat_stacks[i] then` — false, so `t.seat_stacks`, `t.seat_busted`, `t.player_seat_fixed` all stay **nil**.
4. `models/Table.lua:380` `_initChipStackIfNeeded` → line 259 `if self.mtt:isPlaying() then return end` → returns immediately, per-seat state never built.
5. `models/Table.lua:381` `if not self.mtt:isPlaying()` → false → `planRun` never runs, `plan` stays nil.
6. `models/Table.lua:398` `currentHand()` returns nil → the "plan exhausted" branch at 410-417 indexes `self.seat_busted[s]`.

**Cost:** hard Lua error, `attempt to index a nil value (field 'seat_busted')`, on the
first tournament DEAL after a cross-build load. The itch build ships
`PROTOTYPE_MODE = true` and the next build presumably ships `false`, so **every itch
player with an in-progress MTT table hits this on the update**. `(verified by code
trace; confirm by loading a save whose active_table_specs has an mtt entry and
active_table_mtt_state[i] == "playing" into a dev build)`

---

**F1 — HIGH. Tier-scoped fill descriptors ignore their `tier_min` / `tier_max` on the legacy path.**

`models/Table_legacy.lua:172-179`:
```lua
local function sumFills(list, gtype)
    if not list then return 0 end
    local total = 0
    for _, d in ipairs(list) do
        if shiftApplies(d, gtype) then
            total = total + (d.strength or 1)
```
vs `models/outcome_math.lua:142-152`, which also checks `d.tier_min` / `d.tier_max`
and `ctx.fill_cascade`. `models/poker_effects.lua:68-69` pushes those bounds onto
every fill descriptor. **Cost:** a T4+-only win-chance fill fills at T1 in a
prototype build — the player gets a win-rate boost at low stakes the design
explicitly scoped away, and the EV readout (which uses the new math) disagrees
with the hands being dealt.

**F2 — HIGH. `fill_window_widen` and `fill_cascade` are no-ops on the legacy path.**

`models/Table_legacy.lua:185-189` takes no `ctx`:
```lua
local function fillRatio(units, window)
    if not window then return 1 end
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)
```
`models/outcome_math.lua:165-186` widens `start`/`complete` from
`ctx.fill_window_widen` and opens the window from 0 on `ctx.fill_cascade`.
**Cost:** `data/catalog.lua:724-739` **"Filing Cabinet"** (`cost_chip = 24`,
`effect_text = "Upgrades reach one level further."`) does nothing at all in a
prototype build except its `shove_rate_add`. The player pays 24 chips for a lie.
The deck source at `data/decks.lua:295,299` is DECKS-gated so it is
prototype-unreachable and does not compound this.

**F3 — HIGH. Tier floors/ceilings are no-ops on the legacy path.**

`models/Table_legacy.lua:347-349` — `sampleOutcome` ends at
```lua
    local tier = sampleDist(won and win_dist or loss_dist) or "small"
    return won, tier
end
```
`models/outcome_math.lua:340-348` adds the `clampTierFloor` / `clampTierCeiling`
pass. **Cost:** two catalog items are dead in a prototype build —
`data/catalog.lua:913-931` **"Fire Extinguisher"** (35 chips,
`effect_text = "Losses never roll {l:stack}."`) and `data/catalog.lua:932-950`
**"Claw-Foot Tub"** (36 chips, `"Wins never roll {w:small}."`). Both promise an
absolute rule and deliver nothing. (Tub's unlock is `decks_maxed`, also
prototype-unreachable; Fire Extinguisher's is `total_stack_losses >= 250`,
plainly reachable.)

**F4 — HIGH. `tier_bump_chance` and `payout_double_chance` are no-ops on the legacy path.**

`models/Table.lua:437-450` (added by `aa1b09c`):
```lua
    local payout_double = 1.0
    if ctx then
        if ctx.tier_bump_chance and love.math.random() < ctx.tier_bump_chance then
```
has no counterpart anywhere in `Table_legacy.lua` —
`grep -n "tier_bump_chance\|payout_double" models/Table_legacy.lua` returns nothing.
**Cost:** `data/catalog.lua:688-705` **"Chrome Toaster"** (22 chips, *"8% chance a
pot bumps one tier."*) and `data/catalog.lua:760-778` **"Microwave Oven"** (28
chips, *"5% chance a pot pays double."*) are both purchasable and both completely
inert in a prototype build.

**F5 — HIGH, and the nastiest one: the pot cap is applied on the wrong side of `earnings_mult`.**

`models/Table_legacy.lua:571-579` (frozen pre-`aa1b09c`):
```lua
        if won then
            local raw_win = magnitude_bb * stake.bb * earnings_mult * jackpot_mult
            ...
            self.outcome_delta = math.min(raw_win, 2 * (self.stack or 0))
```
`models/Table.lua:465-473` (post-`aa1b09c`):
```lua
    if won then
        local raw_win = magnitude_bb * stake.bb
        ...
        local capped_win = math.min(raw_win, 2 * (self.stack or 0))
        self.outcome_delta = capped_win * earnings_mult * jackpot_mult * payout_double
```
This is not a missing feature, it is **two different economies**. On the legacy
path every earnings multiplier is *swallowed by the 2×stack cap* whenever the raw
pot already exceeds it — which is exactly the jackpot case those multipliers get
bought for. On the new path they multiply on top of the cap. With a ×4 earnings
stack and a capped jackpot the same hand pays **4× more in the dev build than in
the shipped build**. Nothing flags it; the divergence is invisible to the player,
to the readouts, and to every balance table in `data/`.

**F6 — HIGH. Every EV / bb/h / Stack-% number shown to the player comes from the new math, in both builds.**

`views/TablePanelStats.lua:902` and `:910` and `views/GrindView.lua:617-618,655-656`
call `OutcomeMath` **directly and unconditionally**:
```lua
    local s = OutcomeMath.evStats(controller and controller.ctx, gtype, stake)
```
`models/payout_breakdown.lua` (rendered from `views/TablePanelStats.lua:852`) does
the same. **Cost:** in a prototype build the readouts are computed by a pipeline
that includes tier floors, tier bumps, payout doubles, tier-scoped fills and the
post-cap multiplier order — none of which the dealt hands actually run. Everything
F1-F5 makes wrong in the model is *also* wrong in the readout, in the opposite
direction. `Table_legacy:debugStats/:estimateStats` (lines 979 / 1013) at least
stayed self-consistent with the legacy model, but only
`views/TablePanelStats.lua:895` and `:930` still route through them, so the panel
mixes both sources on the same screen.

Caught by the same trace, not strictly a fork issue: `views/GrindView.lua:606`
calls `OutcomeMath.sumFills(ctx[fill_key], gt)` with **two** arguments, so
`tier_idx` and `ctx` arrive nil and the "upgrade is maxed" check counts
tier-scoped fills that do not apply at this stake. **Medium.**

**F7 — MEDIUM, reverse drift. `8df7a58` patched the legacy side only, twice.**

- `models/MttSession_legacy.lua:33-43` — the "instant win on the first hand after a tournament save" reset (`self.hands_won = 0` inside `begin`). Correctly *not* mirrored (in the new session `hands_won` is a lifetime deck-XP counter), but nothing in either file records that the asymmetry is deliberate.
- `models/Table_legacy.lua:290-307` — jackpot-emergence ramp, hand-copied with the comment `"MUST mirror models/outcome_math step 7 — this is the Table_legacy copy"`. Verified byte-equivalent to `models/outcome_math.lua:288-303` today. This is the one place the mirror discipline actually held, and it needed a 17-line hand-copy plus a shouting comment to hold it.

**F8 — MEDIUM. The tournament-reload money exploit guard keys on the wrong field.**

`models/TablePool.lua:96-101`:
```lua
            local gt = findGtype(gtype_id)
            if gt and gt.binary_outcome then
                t.mtt.hands_won = 0
                t.mtt.state     = nil
            end
```
Guards on `binary_outcome`, which exists only when `MTT_KO` is off. Since
`data/game_types.lua` rewrites that same field from the same flag, the guard
silently disarms itself in the other build — the mechanism behind F0.

### 4. Which flags are dead

`data/constants.lua` has no `FLAGS` table; the feature switches live in
`C.FEATURES` (lines 29-80), plus `C.DEBUG` (lines 96-113) and `C.STAKE_BAND_GATE`
(lines 89-94). **Every `FEATURES` entry is derived from the single boolean
`C.PROTOTYPE_MODE` on line 19 and none is individually overridden**, so strictly
speaking no branch is statically dead — flipping one line resurrects all of them
at once. That is exactly what makes the flags dangerous rather than safe: there is
no build in which a given branch is *permanently* gone, so nothing rots loudly.

Effective values with `C.PROTOTYPE_MODE = false`:

| flag | effective value | both branches reachable? | code that is dead **today** |
|---|---|---|---|
| `DEMO_CUT` (`:31`) | **false** | yes (flip line 19) | true-branch: `models/shove_rate.lua:107-121`, `states/ShoveState.lua:183-190`, `views/ShoveView.lua:351`, `views/ShoveView.lua:1033`, and **the whole of `views/PrototypeEndModal.lua`** — nothing can open it |
| `HIGH_TIER_STAKES` (`:36`) | **true** | yes | false-branch: the early `return false` at `controllers/GrindController.lua:1159` |
| `DEV_HOTKEYS` (`:40`) | **true** | yes | false-branch: the guards at `main.lua:259`, `states/GrindState.lua:378`, `states/ShoveState.lua:401` |
| `DECKS` (`:45`) | **true** | yes | false-branch: `models/Decks.lua:26` short-circuit, `views/GrindView.lua:222` collapsed cluster |
| `POKER_THEATER` (`:52`) | **true** | yes for cash; **NO in combination — see below** | false-branch: the timeline walker set up at `models/Table.lua:657-665` and consumed in `:update`, plus `controllers/GrindController.lua:1476` `_emitDealChips` and the `not theater_on` spill at `:1595` |
| `MTT_KO` (`:62`) | **true** | yes | false-branch: **`models/Table_legacy.lua` (1044), `models/HandScript_legacy.lua` (420), `models/MttSession_legacy.lua` (79) — 1543 lines**, plus `data/game_types.lua:69-83`, `views/TablePanel.lua:754-800` (`drawLegacyMttLadder`) and its call guard at `:883`, `controllers/GrindController.lua:232-233` (`won_legacy`) and `:504-512` (`is_binary` floater ramp), `views/GrindView.lua:328-339` (legacy MTT blurb) |
| `QUIT_DISABLED` (`:67`) | **false** | yes | true-branch: `views/SettingsModal.lua:312` |
| `TUTORIAL` (`:74`) | **true** | yes | false-branch: `views/OnboardingModal.lua:24-30` (`INTRO`), the `run0` catalog entries stripped at `data/catalog.lua:997-1001`, the forced-purchase paths at `views/CatalogModal.lua:328`, `:403`, `:1104`, and `views/GrindView.lua:1624`, `:1859`, `:2248` |
| `ONBOARDING_MODAL` (`:79`) | **false** | yes | true-branch: `states/GrindState.lua:209` |
| `DEBUG.START_IN_SHOVE` (`:99`) | false | yes (hand-edit) | — |
| `DEBUG.SHOW_DEBUG_OVERLAY` (`:105`) | false | yes (`D` hotkey re-enables) | — |
| `DEBUG.HAND_ANALYTICS` (`:112`) | **true** | yes | — |

**F9 — HIGH. One flag combination is silently broken, and the file invites it.**

`data/constants.lua:21-24` says: *"override an individual entry below the
assignment if you need a non-default mix for testing"*. Take that up with
`MTT_KO = true` and `POKER_THEATER = false` and chip-stack tournaments stop
working: `Table:_reconcileChipFlow` is called from exactly one place,
`models/Table.lua:686`'s script-walker branch (`if self.script then` … the
settling transition). With theater off, `self.script` is nil (`models/Table.lua:661`
sets `self.script = nil`), so no seat stack is ever decremented, no seat ever
busts, `alive_opps` never reaches 0, and the tournament runs until the plan
exhausts and settles the player at last place. **Cost:** the documented testing
workflow produces a silently wrong tournament. `(unverified at runtime; confirmed
by tracing the single call site of _reconcileChipFlow)`

**F10 — MEDIUM. `data/mtt_payouts.lua` is indexed with two different meanings by the two families, and its doc comment only describes one.**

```lua
-- MTT payout multiplier table. Indexed by ctx.mtt_payout_boost (0/1/2,
-- ...) and by hands cleared.
    [0] = { [6] = 3, [7] = 6,  [8] = 20 },   -- baseline (no perks)
```
`models/MttSession_legacy.lua:60-64` reads `payouts_for_boost[self.hands_won]` —
hands cleared, as documented. `models/MttSession.lua:423-431` reads
`payouts_for_boost[(n_seats) - (finish_position) + 1]` — with `n_seats = 8` that
is 8 for 1st, 7 for 2nd, 6 for 3rd, nothing below. Same numbers, coincidentally
compatible ranges, entirely different semantics, and the comment above them is
now false for the live build. Any balance edit made by reading that comment lands
wrong.

**F11 — LOW. Flag-adjacent copy drift.** `views/GrindView.lua:328` describes the
KO tournament as *"sit down with 100bb chips"*; `data/game_types.lua:58` sets
`starting_stack_bb = 10` (changed by `5487b73`, "10bb turbo stacks"). The
MTT_KO-on tooltip has been wrong since that commit.

**F12 — LOW. There is no automated parity check.** `sim/run.lua:12-14` requires
only `data.balance`, `data.catalog` and `models.shove_rate` — the headless
simulator never instantiates either `Table` family, so neither the fork nor the
drift can be caught by running it. Nothing in the repo executes
`models/Table_legacy.lua` except a hand-flipped build.

---

### 5. A concrete de-forking plan

**Can the legacy models be deleted? Yes — but not first.** They are held alive by
exactly four things, in dependency order:

1. `data/constants.lua:19` — `PROTOTYPE_MODE` is documented (`:14-18`) as the itch
   build switch: *"Set back to true before building for itch."* As long as that is
   the shipping procedure, `Table_legacy` is a shipping artifact, not dead code.
2. `models/TablePool.lua:17-19` — the load-time `require` fork.
3. `data/game_types.lua:35-84` — the `mtt` gtype swap. `Table_legacy` is
   *functionally required* by the `binary_outcome` gtype and nothing else; delete
   that gtype shape and the legacy model has no work to do.
4. The three UI/controller paths keyed on `binary_outcome` / `hand_count`:
   `views/TablePanel.lua:754-800` + `:883`, `controllers/GrindController.lua:232-233`,
   `controllers/GrindController.lua:504-512`.

Nothing else references them: `grep -rn "_legacy" --include=*.lua .` returns only
`TablePool.lua:19`, `Table_legacy.lua:51`, `Table_legacy.lua:60`, and comments.

**Ordered steps.**

**Step 0 — decide the shipping question first.** Everything below assumes the
answer to *"will a future itch build ever ship `PROTOTYPE_MODE = true` again?"* is
**no**. If it is yes, stop: the correct move is not de-forking but fixing
F1-F5 by making `Table_legacy` call `OutcomeMath` (step 2 alone), and the
1543 lines stay. **This is the user's call and it is the only real decision here.**
*Risk if skipped: deleting code that a future ship still needs.*

**Step 1 — kill the crash before anything else (F0/F8).** In
`models/TablePool.lua:96-101`, replace the `gt.binary_outcome` guard with a
positive check that the restored chip-stack state is actually complete:

```lua
if mstate[i] == "playing" and not (seat_stacks[i] and mtt_plans[i]) then
    t.mtt.hands_won = 0
    t.mtt.state     = nil
end
```
This makes an incomplete tournament restart cleanly regardless of which family
wrote the save, and it keeps the legacy reload-exploit fix (`8df7a58`) working
because a legacy save has neither `seat_stacks` nor `plan`. **Independent of the
de-fork and shippable on its own.** *Risk: low. Verify by loading a save with
`active_table_mtt_state[i] == "playing"` and no `active_table_seat_stacks` and
dealing an MTT hand.*

**Step 2 — collapse the math fork without deleting anything.** Delete
`models/Table_legacy.lua:102-370` (the 13 copied helpers) and repoint
`buildOutcome` / `sampleOutcome` / `applyTierShift` / `rollTierMagnitude` /
`tierAvgBB` / `TIER_KEYS` at `models.outcome_math`, exactly as `Table.lua` does.
Then port the four `Table.lua:437-482` blocks (`tier_bump_chance`,
`payout_double_chance`, `earnings_per_tier`, and **the post-cap multiplier
order**) into `Table_legacy.lua:556-586`. This alone fixes F1-F5 and cuts
`Table_legacy` from 1044 to roughly 700 lines. *Risk: **this changes prototype-build
balance**, materially — F5 in particular. Do not do it silently. Verify with a
before/after `OutcomeMath.evStats` comparison at each stake with a maxed catalog.*

**Step 3 — make the fork observable.** Add a one-line boot log of the resolved
flag set (`MTT_KO`, `POKER_THEATER`, `TUTORIAL`, `DEMO_CUT`) and assert the broken
combination from F9: if `MTT_KO and not POKER_THEATER` then error at load. *Risk:
none. This is what should have existed since `7eea9bb`.*

**Step 4 — remove the three cross-family requires.** `controllers/GrindController.lua:13`,
`views/TablePanel.lua:38`, `views/PokerEventAnims.lua:25` all import
`models.Table` solely for `Table.anchorKey`. Move `anchorKey` to a tiny
poker-agnostic module (it is a pure string builder — `services/AnchorRegistry` is
the natural home) and have all four callers plus both Table files use it. *Risk:
low, mechanical. Verify: `grep -rn 'require("models.Table")' --include=*.lua .`
returns only `models/TablePool.lua`.*

**Step 5 — retire the legacy `mtt` gtype.** Delete `data/game_types.lua:35-83`'s
`else` branch and make `mtt_entry` an unconditional table (which also restores
Rule 3: `data/` stops holding an `if`). Then delete the now-unreachable
`binary_outcome` / `hand_count` consumers: `views/TablePanel.lua:754-800` and
`:883`, `controllers/GrindController.lua:232-233`, `:504-512`, and the legacy
blurb at `views/GrindView.lua:328-339`. *Risk: medium — this is the point of no
return for any save that has an in-flight legacy tournament. Step 1 must be
merged first, and must be verified, or those saves crash instead of degrading.*

**Step 6 — delete the three legacy files and the flag.** `models/Table_legacy.lua`,
`models/HandScript_legacy.lua`, `models/MttSession_legacy.lua`; collapse
`models/TablePool.lua:16-19` to a plain `require("models.Table")`; delete
`FEATURES.MTT_KO` and its remaining read at `views/GrindView.lua:327`.

**Verification checklist before deleting (step 6):**
- `grep -rn "_legacy" --include=*.lua .` returns nothing outside `docs/`.
- `grep -rn "binary_outcome\|hand_count" --include=*.lua .` returns nothing outside `docs/`.
- `grep -rn "FEATURES.MTT_KO" --include=*.lua .` returns nothing.
- A save written by the current shipped prototype loads, its MTT tables degrade to "idle, click DEAL", and a full tournament completes and pays.
- `data/mtt_payouts.lua`'s header comment is rewritten to describe finish-position keying (F10).
- `views/GrindView.lua:328`'s "100bb" is corrected to match `starting_stack_bb` (F11).

**What this buys:** 1543 lines deleted, one `if` removed from `data/`, five
High-severity silent-no-op perks fixed, the two-economies problem (F5) closed, and
the "mirror per-hand math into BOTH" rule — which the project's own memory notes
list as a standing hazard and which git shows failed on 4 of 6 post-fork commits —
stops existing.

---

### 6. Save compatibility of collapsing the fork

`C.SAVE.VERSION = 1` (`data/constants.lua:151`) has never been bumped;
`models/GameState.lua` migrates by field-presence backfill (`:325-360`) plus one
named flag (`deck_overhaul_migrated`, `:331-334`). There is no versioned migration
ladder to hang a fork migration on.

**Serialized keys, by family.** All are written from
`models/TablePool.lua:_syncStateList` (`:114-145`) and declared on GameState at
`:150-169` / serialized at `:515-526`. All are **parallel arrays indexed by
position in `active_table_specs`**, which is itself the migration hazard: nothing
keys them by table identity, so any change to how specs are ordered desynchronizes
every one of them.

| key | legacy build writes | KO build writes | on cross-load |
|---|---|---|---|
| `active_table_specs` | yes | yes | shared; `"<stake>:<gtype>"`, and `mtt` is a valid id in both — no rename needed |
| `active_table_mutes`, `active_table_rebuy_mutes` | yes | yes | shared, identical meaning |
| `active_table_mtt_hands_won` | yes — **hands cleared this tournament, 0-8, load-bearing** (`MttSession_legacy:settle` keys the payout off it) | yes — **lifetime hands won, unbounded, cosmetic** | **semantic collision.** A legacy value of 7 loaded into a KO build is harmless (nothing reads it for payout); a KO value of 340 loaded into a legacy build would index `mtt_payouts[340]` → nil → 0 payout. Not a crash, but a silently voided tournament. |
| `active_table_mtt_state` | yes (`nil` \| `"playing"`) | yes (same domain) | **the F0 vector** — `"playing"` means "mid 8-hand run" to one family and "mid chip-stack run with a `plan`" to the other |
| `active_table_mtt_plans` | never (field absent on `MttSession_legacy`) | yes, a nested plan table | absent → `t.mtt.plan = nil` while `state == "playing"` → F0 |
| `active_table_seat_stacks` | never | yes | absent → per-seat state never restored → F0 |
| `active_table_seat_busted` | never | yes | same |
| `active_table_player_seat` | never | yes | same |
| `active_table_button_seat` | never | yes | same |
| `active_table_bust_order` | never | yes | same |
| `active_table_stack` | written (`t.stack` exists on both) but **only restored inside the `if seat_stacks[i]` guard**, `models/TablePool.lua:102-108` | written and restored | a KO save loaded in a legacy build restores a *tournament chip stack* as a *cash table stack* — wrong units, real money. Low likelihood (downgrade direction), noted for completeness |

**No key needs renaming**, so the project's back-compat rule is not violated by the
de-fork itself. The problem is purely **semantic**: `active_table_mtt_hands_won` and
`active_table_mtt_state` mean different things in the two families while carrying
the same name and the same value domain.

**What a migration must do**, minimally — and all of it belongs in
`models/TablePool.lua:rebuildFromState`, not in `GameState`, because that is where
the parallel arrays are unpacked:

1. **Treat an incomplete chip-stack restore as "no tournament in progress."** The
   step-1 guard above is the migration: `state == "playing"` without both
   `seat_stacks[i]` and `mtt_plans[i]` must reset to `hands_won = 0, state = nil`.
   That covers every legacy-written save with one condition and needs no version
   stamp, no flag, and no `deck_overhaul_migrated`-style one-shot.
2. **Decide what `active_table_mtt_hands_won` means, once.** Either keep it as the
   lifetime counter the KO family uses and accept that legacy saves contribute a
   0-8 seed, or rename it (`active_table_mtt_hands_won_lifetime`) with a
   presence-backfill in `GameState:325-360`. The seed is small enough that
   accepting it is defensible; what is not defensible is leaving two meanings on
   one name after the legacy family is deleted.
3. **Nothing else.** The six chip-stack-only arrays are already absent-tolerant
   (`or {}` at `models/TablePool.lua:65-74`), and `active_table_stack` becomes
   unambiguous the moment only one family writes it.

One thing a migration **cannot** fix: F5. A player who accumulated bankroll under
the legacy cap-before-multiplier order has a save whose numbers were produced by a
different economy. Collapsing the fork changes their earnings rate going forward
and there is no honest way to migrate that — it is a balance change to disclose,
not a data change to convert.

---

## Gameplay math and simulation correctness

### 1. HandEval.lua — evaluator is CORRECT (proven by exhaustive test)

No defects found. I ran two exhaustive proofs over all C(52,5) = 2,598,960 five-card
hands using the project's own `models/Card.lua` + `models/HandEval.lua`:

**Proof A — category census matches the canonical frequencies exactly:**

```
high card       1302540 / 1302540   pair  1098240 / 1098240
two pair         123552 /  123552   trips    54912 /   54912
straight          10200 /   10200   flush     5108 /    5108
full house         3744 /    3744   quads      624 /     624
straight flush       40 /      40
```

**Proof B — distinct rank tuples = 7462**, the exact number of 5-card equivalence
classes in Hold'em. This proves the tiebreaker vectors neither over-collapse
(two different-strength hands sharing a tuple) nor over-split (two equal hands
getting different tuples). Kickers, flush ordering, quads/full-house kicker and
two-pair kicker are all exactly right.

Targeted boundary cases, all PROVEN correct:
- Wheel `As2h3d4c5s` -> `{STRAIGHT,5}` "5-high straight"; loses to 6-high straight (compare = -1). Correct.
- Steel wheel `As2s3s4s5s` -> `{STRAIGHT_FLUSH,5}`; loses to `6s5s4s3s2s`. Correct.
- Ace-high straight -> `{STRAIGHT,14}`; royal -> `{SF,14}`.
- SF > quads, FH > flush, flush > straight orderings all correct.
- Exact tie returns `compare == 0`.
- 7-card and 9-card `bestFiveOfN` pick the correct best 5 (board-plays case included) and do **not** mutate the input table.

`detectStraight` (HandEval.lua:89-102) handles the wheel via an explicit
`unique_desc[1] == 14 and seen[2..5]` branch after the sliding-window scan, which
is the correct order (a real straight is found first, so `A5432` can't shadow a
higher one).

#### Finding M-1 (Nit, `models/HandEval.lua:177-179`) — `bestFiveOfN` aliases the caller's table on the n==5 path
```lua
    if n == 5 then
        return HandEval.rank(cards), cards
    end
```
Every other path returns a fresh 5-element copy. A caller that holds the returned
combo and later mutates the array it passed in silently corrupts the recorded
showdown hand. PROVEN: `cb == h5` is `true` for n=5, `false` for n>5. Cheap fix is
to copy. No current caller does this, so it is latent only.

### 2. RNG — seeding, determinism, bypassed streams

#### Finding M-2 (High, `utils/rng.lua` whole file + 70 call sites) — nothing ever seeds the RNG, so no run is reproducible and `sim/` cannot replay
`grep -rn "setRandomSeed\|randomseed"` over the whole repo returns exactly **one hit, and it is a comment**:

```lua
-- models/Deck.lua:5
-- love.math.setRandomSeed(seed) before constructing.
```

No code path anywhere calls `love.math.setRandomSeed` or `math.randomseed`. The
headless simulator (`sim/run.lua`) has no seed argument either. Cost: a balance
regression found in the sim can never be reproduced, and the "for deterministic
tests, call setRandomSeed" contract in `models/Deck.lua` is a promise no caller
can keep. `utils/rng.lua`'s own header ("so a deterministic seed can be swapped
in for tests / replays") describes a facility that does not exist.

#### Finding M-3 (Medium, 5 sites) — `math.random` (bare Lua) bypasses the `love.math` stream entirely
These are the only `math.random` calls outside `love.math.random`:

```
models/GameState.lua:17    return string.format("%d_%05d", os.time(), math.random(10000, 99999))
models/Cursor.lua:52,53,55  self.target_x = margin + math.random() * ...
services/CursorPool.lua:59,60  local cx = W * (0.3 + math.random() * 0.4)
```

`models/GameState.lua:17` is the load-bearing one: it generates the **save id**.
LÖVE runs LuaJIT (Lua 5.1 semantics), where `math.random` without a prior
`math.randomseed` yields the *same sequence every process launch*. `os.time()`
gives second granularity, so two saves created in the same second in two fresh
launches of the game collide on `"<t>_<same 5 digits>"`. `love.math.random` is
auto-seeded by LÖVE at boot; `math.random` is not. `Cursor`/`CursorPool` are
cosmetic, but they are also the two sites that would break a future replay.

#### Finding M-4 (Low, `utils/rng.lua:14-21`) — `weightedPick` can return a zero-weight entry
```lua
    local r = love.math.random() * total
    local acc = 0
    for _, entry in ipairs(list) do
        acc = acc + (weight_fn(entry) or 0)
        if r <= acc then return entry end
```
`love.math.random()` returns `[0, 1)`, so `r == 0` is attainable; with `r == 0`
and a leading zero-weight entry, `acc == 0` and `r <= acc` is true — the
zero-weight entry is picked. `<` instead of `<=` on the comparison (with the
`list[#list]` fallback already present at line 22) removes it. Same `<=`
pattern, same latent behaviour, in `models/outcome_math.lua:86`,
`models/HandScript.lua:87`, `models/HandScript_legacy.lua:71`,
`models/Table_legacy.lua:109`.

#### Finding M-5 (Medium, `models/outcome_math.lua:75-89`) — `sampleDist` iterates with `pairs`, which makes any future seeded replay non-reproducible
```lua
    local r = love.math.random() * total
    local acc = 0
    for k, p in pairs(dist) do
        acc = acc + p
        if r <= acc then return k end
    end
```
The mapping from the single random draw to a returned key depends on `pairs`
iteration order over a string-keyed hash table, which Lua does not define and
which changes with insertion history and table internals. The marginal
probabilities are still correct, so this is not a distribution bug — but it
means the same seed + same code cannot be guaranteed to produce the same tier,
which is the whole point of M-2. Iterating `TIER_KEYS` in order costs nothing
and fixes it. (Note `MttSession.lua:187` calls the same function on an *array*
`finish_weights`, where the array part does iterate 1..n — two different
iteration regimes through one function.)

#### Verified NOT buggy
- `models/Deck.lua:30-35` and `models/Gauntlet.lua:116-121`,
  `models/MttSession.lua:205-208`, `models/HandScript.lua:300-303` are all
  textbook backwards Fisher-Yates with inclusive `love.math.random(1, i)`. No
  modulo bias, no off-by-one.
- `love.math.random(lo, hi)` is inclusive on both ends; every `(1, #t)` call
  site I checked guards `#t > 0` first (`MttSession.lua:113`,
  `HandScript.lua:222`).

### 3. Money math — NaN, caps and readouts

#### Finding M-6 (CRITICAL, `controllers/GrindController.lua:357-358`) — negative bankroll + the Bank capstone turns every payout into NaN and permanently corrupts the save
```lua
        if self.ctx and self.ctx.earnings_scale_by_bankroll then
            local br = self.game.state.bankroll or 0
            r.delta = r.delta * (1.0 + math.log10(br + 1) * 0.1)
        end
```
Bankroll going negative is **by design**: `controllers/GrindController.lua:402-405`
deliberately removes the zero floor in Act 3 —
```lua
                if state.shove_r2_won and stake and stake.band == "ultra" then
                    local excess_loss = -new_stack
                    tbl.stack = 0
                    state.bankroll = state.bankroll - excess_loss
```
— and `data/constants.lua:139` sets `UNDERFLOW_THRESHOLD = -100000000000`. The Bank
deck (`data/decks.lua:168`, `{ kind = "earnings_scale_by_bankroll" }`) is meta-side,
so it survives into Act 3.

PROVEN (ran it):
```
bankroll=-0.9   mult= 0.9            win_delta(+$10) ->  9.0
bankroll=-1     mult=-inf            win_delta(+$10) -> -inf
bankroll=-2     mult=-nan            win_delta(+$10) -> -nan
bankroll=-500   mult=-nan            win_delta(+$10) -> -nan
```
Concrete failure: player owns the Bank capstone, has cleared R2, sits an `ultra`
table, and drops to bankroll `-$2.00`. The very next resolved hand computes
`r.delta = NaN`. Downstream at line 424-431 the guard is `if new_bankroll < 0`,
and **`NaN < 0` is false** (also proven), so the NaN is written straight into
`state.bankroll` and never recovered. Same for the table path: `new_stack > cap`
and `new_stack < 0` are both false for NaN, so `tbl.stack = NaN`. Both are
AutoSerializer-persisted, so the save is bricked — every money readout shows
`-nan` forever. Fix: guard `br <= -1` (or clamp `math.max(0, br)`).

The identical expression appears twice more and has the same NaN behaviour:
- `models/outcome_math.lua:494-496` `mult = mult * (1.0 + math.log10((opts.bankroll or 0) + 1) * 0.1)` — poisons every EV readout.
- `models/payout_breakdown.lua:231` `.. string.format("%.2f", math.log10(br + 1))` — the cache key becomes the constant `"-nan"`, so the breakdown modal freezes on a stale value for the rest of the session.

#### Finding M-7 (High, `models/Table.lua:475` vs `models/outcome_math.lua:476-498`) — the 2×-stack pot cap exists in the game but not in any readout
`models/Table.lua:468-478`:
```lua
        local raw_win = magnitude_bb * stake.bb
        local capped_win = math.min(raw_win, 2 * (self.stack or 0))
        self.outcome_delta = capped_win * earnings_mult * jackpot_mult * payout_double
```
`OutcomeMath.payoutMult` / `evStats` / `PayoutBreakdown.profile` model the win as
`avg_bb × bb × mult` with no cap at all. Concrete: NL10 (`bb = 0.10`, buy-in
`$10`), table stack ground down to `$1.00`. A jackpot win rolls
`magnitude_bb ≈ 100` → `raw_win = $10.00`, capped to `2 × 1.00 = $2.00`. The
stats panel and the payout breakdown both quote the uncapped `$10.00` — a **5×**
overstatement of the jackpot cell, and the per-hand EV number is wrong in the
same direction for every low-stack table. This is not a rounding nit; the cap
binds hardest exactly when the player is losing and reading the panel to decide
whether to keep the table.

#### Finding M-8 (Medium, `models/Table.lua:470-475`) — the pot cap is applied before the multipliers, contradicting its own stated invariant
```lua
        -- Pot cap: a hand's pot is at most 2× your at-table stack
        -- ... So the most you can WIN from a hand is 2× stack.
        local capped_win = math.min(raw_win, 2 * (self.stack or 0))
        self.outcome_delta = capped_win * earnings_mult * jackpot_mult * payout_double
```
`earnings_mult`, `jackpot_mult` and `payout_double` all multiply *after* the
clamp, so with a fully-built catalog (`earnings_mult` in the 4× range,
`jackpot_mult` on top, `payout_double = 2`) a `$1.00` stack can return well over
`$16` from a single hand against a documented ceiling of `$2.00`. Order matters
here and the two readings disagree — decide which one is the rule and make the
comment and the code say the same thing.

#### Finding M-9 (Medium, `models/Table.lua:485`) — `payout_double_chance` doubles LOSSES as well as wins
```lua
        self.outcome_delta = -magnitude_bb * stake.bb * loss_mult * payout_double
```
The Maniac deck grants `payout_double_chance = 0.5` (`data/decks.lua:117`), so
half of all its losses are also doubled. `OutcomeMath.payoutMult:480` applies
`1 + p` to both branches too, so the EV model is at least self-consistent — but
the effect is registered and named as a *payout* double
(`data/effects.lua:320-323`), and nothing in the catalog copy tells the player
their losses double. Either the loss branch should drop `payout_double` or the
effect needs a different name; as written a player buying "payout double" is
buying variance they were not told about.

#### Finding M-10 (Low, `models/outcome_math.lua:480`) — `payoutMult` returns an expectation, not a realisable multiplier
```lua
    local mult = 1 + (ctx.payout_double_chance or 0)
```
`Table:deal` rolls an actual 1× / 2× coin flip. With Maniac
(`payout_double_chance = 0.5`) the breakdown modal quotes `×1.5` — a multiplier
no hand ever pays. Correct as an EV term, misleading as the label on a
"where does 166× come from" row, which is what `payout_breakdown.lua` renders it as.

#### Verified NOT buggy
- `models/HandScript.lua:122` `r2(x) = math.floor(x * 100 + 0.5) / 100` rounds
  half-up on cents and `splitPot` (`:126-148`) closes the residual on the last
  element, so per-street pot shares sum back to the target within one cent.
  The `out[n] < 0` guard at `:141-144` correctly reclaims an over-rounded tail.
- `poker_action_apply.lua:28-35` `commit` guards `amount <= 0` and mirrors every
  contribution into both `per_seat_committed` and `per_seat_total`;
  `pot_push:121-125` stashes `pot_at_push` before zeroing, so the pot reconciles.

---

## Save/load, serialization, and back-compat

### 1. The full serialized schema

Four distinct files reach disk. Only three go through `SaveService`.

| File | Written by | Wrapper | Versioned |
|---|---|---|---|
| `meta.save` | `GameState:serializeMeta()` via `SaveService:write` | `{version, timestamp, data}` | yes |
| `run.save` | `GameState:serializeRun()` via `SaveService:write` | `{version, timestamp, data}` | yes |
| `settings.save` | `g.settings` table (main.lua:194) via `SaveService:saveSettings` | `{version, timestamp, data}` | yes (shares `SAVE.VERSION`) |
| `analytics_<save_id>.json` | `services/HandAnalytics.lua:50` raw `love.filesystem.write` | none | **no** |

No other persistence exists. `views/RoomView.lua:1352 serializeLayout()` only `print()`s a Lua literal to stdout for the developer to paste into `data/`; it never touches the filesystem. There is no per-slot save selection: exactly one save, three fixed filenames.

#### `meta.save` → `data` (models/GameState.lua:457-506)

| Key | Type | Notes |
|---|---|---|
| `save_id` | string | `"<os.time>_<5 digits>"`, analytics identity; names the analytics file |
| `shove_count` | number | incremented by `resetRun()` |
| `has_shoved` | boolean | tutorial SHOVE gate |
| `chips` | number | meta currency |
| `owned_items` | array of catalog item id strings | |
| `cleared` | boolean | gauntlet beaten |
| `shove_r1_won`, `shove_r2_won` | boolean | |
| `anti_chips` | number | Act 3 currency |
| `corrupted_items` | array of catalog id strings | |
| `peeled_items` | array of catalog id strings | COMING SOON stickers peeled |
| `ultra_unlocked` | boolean | |
| `deck_overhaul_migrated` | boolean | **the only migration flag in the codebase** |
| `onboarded`, `catalog_seen` | boolean | |
| `hints_seen` | map hint_id string → true | |
| `hints_queued` | array of hint id strings | |
| `unlocked_decks` | array of deck id strings | |
| `deck_levels`, `deck_xp` | map deck_id string → number | |
| `active_deck_id` | string or nil | |
| `lifetime_money_won`, `lifetime_money_lost`, `lifetime_jackpot_count`, `lifetime_mtt_hands_won`, `lifetime_hands_played`, `lifetime_hands_at_4plus_tables`, `lifetime_rebuys`, `lifetime_upgrades_bought`, `lifetime_hands_overwhelmed`, `lifetime_chips_banked` | number | deck-unlock gates |
| `total_hands_played`, `total_big_outcomes`, `total_denied_stacks`, `total_busts`, `total_stack_losses`, `total_jackpots`, `total_rebuys`, `total_upgrade_levels`, `total_hands_overwhelmed`, `total_hands_at_4plus`, `total_chips_banked`, `total_mtt_wins` | number | catalog-unlock gates |
| `total_hands_by_gtype` | map game_type_id string → number | |
| `highest_stake_idx` | number | |
| `last_run_money_lost` | number | Dishwasher seed |

#### `run.save` → `data` (models/GameState.lua:510-538)

| Key | Type | Notes |
|---|---|---|
| `bankroll` | number ($) | |
| `current_stake_id` | string | e.g. `"s001"` |
| `run_upgrade_levels` | map upgrade_id string → number | |
| `active_table_specs` | array of `"<stake_id>:<gtype_id>"` strings | the index key for 10 parallel arrays |
| `active_table_mutes`, `active_table_rebuy_mutes` | array of boolean | dense |
| `active_table_mtt_hands_won` | array of number | dense |
| `active_table_mtt_state` | **sparse** array (nil for cash tables) | encodes as JSON object |
| `active_table_mtt_plans` | **sparse** array of `MttSession.plan` tables: `{finish_position, n_hands, n_hands_max, player_seat, n_seats, bust_schedule[], hands[], next_hand_idx, last_bust_count}` (models/MttSession.lua:317-327) | |
| `active_table_seat_stacks`, `active_table_seat_busted`, `active_table_bust_order` | **sparse** arrays of per-seat arrays | |
| `active_table_player_seat`, `active_table_button_seat`, `active_table_stack` | **sparse** arrays of number | |
| `stakes_won_this_run`, `anti_stakes_won_this_run` | map stake_id string → true | |
| `chips_this_run`, `anti_chips_this_run` | number | |
| `first_loss_voided_this_run`, `first_stack_loss_voided_this_run`, `denied_copied_this_run`, `first_bounty_this_run` | boolean | |
| `hands_since_last_bank`, `run_money_lost` | number | |

#### `settings.save` → `data` (main.lua:194-197)

| Key | Type |
|---|---|
| `volume` | number 0-1 |
| `analytics_consent` | boolean (never nil — see §7) |

#### `analytics_<save_id>.json` (unversioned, unwrapped)

`{ save_id, shoves = [ { shove_count, started_at, deck_id, catalog_levels, run_upgrade_levels, shove_rate{r1,r2,r3,clear,catalog,mult,bankroll}, gauntlet_result, chips_earned, events[], hands[] } ] }`

### 2. Migration handling

There is a version number (`data/constants.lua:157 VERSION = 1`) and **no migration path keyed to it**. `git log -S"VERSION           = " -- data/constants.lua` returns exactly one commit — the initial skeleton. It has never been bumped, which is the only reason live saves still load.

**Critical — `services/SaveService.lua:61-63`: bumping `SAVE.VERSION` deletes every player's save with no warning and no migration hook.**

```lua
    if decoded.version ~= VERSION then
        return nil, "version mismatch"
    end
```

`read()` returns nil on any mismatch. `loadAll()` hands `{meta=nil, run=nil}` to `GameState:new`, which falls through to fresh-game defaults, and the next 30-second autosave tick (main.lua:337) overwrites the file. The player boots to $2 bankroll, 0 chips, empty catalog, and their old save is physically gone one autosave later. The check is also `~=`, not `<`, so a *downgrade* (player rolls back to an older itch build) is equally fatal. This is a loaded gun: the schema is under active change (three of the last five commits touched `models/GameState.lua`), and the correct instinct — "I changed the shape, bump the version" — is exactly the action that wipes the install base.

**High — no migration dispatch exists.** The entire migration surface is ad-hoc code inside `GameState:applySaved` (models/GameState.lua:307-401):
- one real rename fixup, `pp` → `chips` (models/GameState.lua:320-325), guarded on `self.pp ~= nil`;
- one flagged one-shot, `_migrateDeckState()` gated on `deck_overhaul_migrated` (models/GameState.lua:329-332);
- ~40 lines of `x = x or default` backfills.

There is no `MIGRATIONS[from_version]` table, no ordered chain, and no way to express "this key changed shape" (only "this key might be missing"). Every future schema change has to be hand-written into this function forever, and the `or` idiom cannot distinguish "absent" from "legitimately false/0" — see below.

#### Load-time behaviour, traced case by case

| Case | Result | Verdict |
|---|---|---|
| Key missing (new field, old save) | `AutoSerializer.apply` skips it; the `:new()` default survives; explicitly backfilled for ~35 keys at GameState.lua:334-401 | **graceful** for backfilled keys |
| Key missing and **not** in the backfill list | keeps `:new()` default. Currently every field is defaulted in `:new()`, so no nil-index crash | graceful (by luck, not by construction) |
| Key present with wrong type (e.g. `chips` is a string) | `AutoSerializer.apply` copies verbatim, no type check (services/AutoSerializer.lua:64 `instance[k] = v`). First arithmetic use crashes: `GameState.lua:717 self.chips - item.cost_chip` → "attempt to perform arithmetic on a string" | **crash**, unrecoverable without deleting the save |
| `owned_items` holds a deleted catalog id | `computeEffects` (GameState.lua:566) builds `owned_set` from the save then iterates `catalog`, so the stale id never matches | degrades silently — the player's spent {chip} vanish with no refund and no notice |
| `run_upgrade_levels` holds a removed upgrade id | GameState.lua:628 iterates `run_upgrades` and looks up by item id; the stale key is inert | graceful, silent loss |
| `unlocked_decks` / `deck_levels` holds a removed deck id | `_migrateDeckState` (GameState.lua:404-450) prunes it and repairs `active_deck_id` — **but only once ever**, because `deck_overhaul_migrated` is set true at GameState.lua:331 and never cleared. A deck removed in a *future* build will not be pruned for any player who already ran this migration | **latent bug** — the only real migration is single-use |
| `active_table_specs` holds an unknown game-type id | explicit fallback, models/TablePool.lua:82 `if not gtypeExists(gtype_id) then gtype_id = "six_max" end` | graceful, and the right pattern |
| `active_table_specs` holds a **renamed/removed stake id** | **no fallback**. `Table:new` stores it (Table.lua:117-122), `stack` falls to 0 (Table.lua:142), and `Table:deal` bails forever at Table.lua:363 `if not stake or not gtype then return false end` | degrades to a **permanently dead table** the player paid a buy-in for and that never deals again; no self-heal, no removal |
| `current_stake_id` renamed | harmless — the key is written at GameState.lua:513 and **never read anywhere in the repo** (dead payload) | Nit |
| `hints_seen` holds a retired hint id | inert map lookup | graceful |
| Malformed / truncated JSON | `json.decode` pcalls internally and returns `nil` (lib/json.lua:219-226); `SaveService:read` catches it at line 58 and returns nil | **silent total wipe** — same path as version mismatch: fresh game, then autosaved over 30s later |

**High — `models/GameState.lua:334-401`: the `x = x or default` backfill idiom cannot distinguish "absent" from "false".** For booleans this is harmless because the default *is* false, but it is a trap that already had to be worked around twice:

```lua
    if self.has_shoved == nil then
        self.has_shoved = (self.shove_count or 0) > 0
    end
```

The comment at GameState.lua:391-395 explains the near-miss: writing `has_shoved = has_shoved or (...)` would promote a live save every load. `shove_r1_won`, `shove_r2_won`, `ultra_unlocked`, `cleared`, `onboarded`, and the four `*_this_run` flags all still use the `or` form. Any of them that later needs a non-false default silently re-fires on every load.

**Medium — there is no backup, no `.bak`, and no way for a player to recover.** Every failure above (version mismatch, decode error, type crash) ends with the save being overwritten by fresh-game state at the next autosave. Nothing writes a rolling copy.

### 3. Rename risk — git history audit

I enumerated every id that has ever appeared in each `data/` file across its full history and diffed against the current file.

**Ids deleted at some point in history:**

| File | Deleted ids | Latest deletion |
|---|---|---|
| `data/catalog.lua` | better_mouse, calm_hands, canary, cheap_coaching, coaster, cold_read, damage_control, dual_monitors, eagle_eyes, endorsement_deal, ergonomic_chair, hotkeys_mastery, hu_specialist, lamp, lucky_charm, lucky_charm_pp, mousepad, mug, plant, pokertracker_hud, pot_odds_master, sticky_note, teddy_bear (23) | **2026-05-01** (`7d75b3d`) |
| `data/run_upgrades.lua` | big_pots, coffee, concentration, energy_drink, focus_drink, hire, iron_nerves, lucky_charm, patience, pot_building, single_session (11) | **2026-05-18** (`7eea9bb`, the ship pass itself) |
| `data/stakes.lua` | nl2, nl10, nl50 → `s001`..`s006` | **2026-04-27** (`682a732`, pre-launch) |
| `data/decks.lua` | fish, patterns, acorns, low_stakes_hero, multi_tabler, tournament_pro | 2026-07-17 (`aa1b09c`) — **has a migration** |
| `data/game_types.lua` | nine_max | — TablePool has a fallback |

**Conclusion on post-launch safety:** the itch ship is `7eea9bb` / `f36cece` (2026-05-18 → 2026-07-05). Only **one** serialized key has been renamed since, and it is correctly migrated:

```lua
    if self.pp ~= nil then self.chips = self.pp; self.pp = nil end
    if self.pp_this_run ~= nil then
        self.chips_this_run = self.pp_this_run; self.pp_this_run = nil
    end
```
(models/GameState.lua:320-325, from `45f7609` 2026-05-31). Every other post-launch GameState change is purely additive. I verified this by running `applySaved` headlessly against a synthetic pre-rename payload: `pp=42` → `chips=42`, `pp_this_run=5` → `chips_this_run=5`, deck roster `{"fish","patterns"}` → pruned to `{"standard"}` at L0. **Old saves do load.**

#### The two recent "shape change" commits did NOT reach the save file — verified

- **`0cc33fa` "Chip piles are collections, not numbers"** — the new collection lives entirely in `views/ChipPile.lua` (module-level, reset by `ChipPile.clearAll()` at states/GrindState.lua:306). Nothing in it is referenced by `serializeMeta`/`serializeRun`. Its only `models/GameState.lua` change is **additive**: `has_shoved` (see the bug below).
- **`f64112f` "Payouts stop pretending to be table money"** — `git show f64112f -- models/Table.lua models/Table_legacy.lua` is a 5-line addition of `self._script_pace` in each. `_script_pace` is a Table field, and `TablePool:_syncStateList` (models/TablePool.lua:116-145) writes a **fixed hand-listed set** of Table fields, so a new Table field cannot leak into the save. `data/chips.lua` denominations are pure data, never persisted.
- **`5b79adc`** — `models/GameState.lua` change is the `exclude` parameter on `computeEffects` plus the cache guard. No schema touch.

**None of the three changed the on-disk shape.** An old save still loads across all three.

#### Critical — the two `== nil` migration guards in `applySaved` are dead code

**`models/GameState.lua:390-399`** — verified by execution, not inspection:

```lua
    if self.has_shoved == nil then
        self.has_shoved = (self.shove_count or 0) > 0
    end
    if self.catalog_seen == nil then
        self.catalog_seen = (self.shove_count or 0) > 0
    end
```

`GameState:new` sets `instance.has_shoved = false` (line 74) and `instance.catalog_seen = false` (line 57) **before** calling `applySaved` (line 194). A save that predates the field leaves the instance value at `false`, never `nil`, so neither branch can ever fire. Running the real code with `{meta = {shove_count = 3, ...}}` and no `has_shoved` key prints:

```
has_shoved   =	false	 catalog_seen=	false
```

Both migrations were written specifically to stop a veteran losing their buttons, and both are inert.

Player-visible consequence, on the **currently live** config (`PROTOTYPE_MODE = false` → `FEATURES.TUTORIAL = true`):
- `controllers/GrindController.lua:1052 return state.has_shoved or (state.chips_this_run or 0) >= SHOVE_UNLOCK_CHIPS` — a returning player whose save predates 2026-08-10 finds the **SHOVE button gone** until they bank 3 {chip} in the current run. Their entire prestige loop, and the credits/Act-3 path behind it, is hidden.
- `views/GrindView.lua:1524 return (not Constants.FEATURES.TUTORIAL) or self.game.state.catalog_seen` — the same save loses its **top-bar CATALOG button** until it re-opens the post-shove catalog, which requires shoving, which requires the hidden SHOVE button. For a player mid-run with under 3 banked chips this reads as a progression softlock.

The fix pattern the codebase already uses correctly elsewhere would be to read the raw payload (`saved.meta.has_shoved == nil`) rather than the post-apply instance field.

#### Medium — `highest_stake_idx` persists a positional index, not an id

`models/GameState.lua:503 highest_stake_idx = self.highest_stake_idx` stores a 1-based index into `data/stakes.lua`. Inserting a stake anywhere but the tail silently rewrites what every existing save's stored index means, mis-gating every catalog item that reads it. The ladder has already grown once (`8c5418d`, s007-s010 appended); the next insert in the middle is a silent regression with no error. Every other cross-reference in the save is by string id.

#### Low — `current_stake_id` is write-only

`models/GameState.lua:513` persists it; `grep -rn current_stake_id` finds no reader anywhere in the repo. Dead payload that still constrains future renames.


### 4. AutoSerializer

**High — `services/AutoSerializer.lua:19 AutoSerializer.serialize` is dead code, and three header comments assert the opposite.**

`grep -rn AutoSerializer` over the repo (excluding `build/`) yields exactly two call sites, both `.apply`:

```lua
        AutoSerializer.apply(self, saved.meta, GameState.REFS, function() return nil end)
```
(models/GameState.lua:311, and again at :314 for `saved.run`). **Nothing anywhere calls `.serialize`.** The write side is the hand-maintained allowlist `GameState:serializeMeta()` (models/GameState.lua:457-506) and `GameState:serializeRun()` (:510-538). The pipeline is asymmetric: auto on load, manual on save.

Three comments teach the wrong contract:
- `models/GameState.lua:7-8` — "AutoSerializer-driven. Adding a new persistent field = adding the field; everything that's not in TRANSIENTS or REFS saves automatically."
- `services/AutoSerializer.lua:7-8` — "Adding a new data field to a model costs zero — it will persist."
- `services/SaveService.lua:15` — "`data = <table from model:serialize() / AutoSerializer.serialize>`".

#### What it auto-includes / excludes (if it ran)

`AutoSerializer.serialize(obj, transients, refs)` walks `pairs(obj)` and, per key: skips anything in `transients`; skips values of type `function` / `userdata` / `thread` (:13-17); maps `refs` entries to `item[r.kind]` ids; **and copies everything else by reference**, including nested tables it has never seen.

#### Trace: what happens when a field is added to a model

| Case | Actual behaviour |
|---|---|
| New data field added to `GameState:new` | **Silently does NOT persist.** `serializeMeta`/`serializeRun` never learn about it, so it is absent from the payload; `AutoSerializer.apply` never sets it on load; the `:new()` default wins every launch. |
| A dev follows the documented contract and only adds the field | The field resets to its default on every boot forever. No error, no warning. Given `GameState` already carries 30+ counters that gate catalog/deck unlocks, an unlock that "won't stick" is the likely first symptom, days after the change. |
| Field added and forgotten in `wipeAll()` | Survives a "new game", leaking old progress into a fresh save. |

I checked for existing drift by extracting every `instance.X =` in `:new()` and every `X = self.X` in the two serializers. **Currently in sync** — the only unpersisted field is `effects_cache`, correctly declared in `TRANSIENTS`. So this is a latent trap, not present data loss, and there is no test asserting the two lists match.

**Medium — `GameState.TRANSIENTS` and `GameState.REFS` are themselves dead.** `TRANSIENTS` (models/GameState.lua:26-28) is never passed to anything, since only `.serialize` reads it. `REFS` is passed to `.apply` but is `{}` (:29), with a resolver hardcoded to `function() return nil end`. The declarations look load-bearing and are decorative.

#### Can it persist a runtime-only field and blow up json encoding? (if the auto path were switched on)

Yes for two of the three, PROVEN by execution against `lib/json.lua`:

| Runtime value | Result |
|---|---|
| Top-level closure / view method | Skipped by `shouldSkipType` (:13-17) — safe |
| **Closure nested one level down** (e.g. `self.ui = { on_click = fn }`) | `json.encode: unsupported type 'function'` — `pcall(json.encode, {a={f=function() end}})` → `false  lib/json.lua:91` |
| **Table cycle** (view → model → view) | Does not crash: `lib/json.lua:47` emits `null` for a re-entered table. `json.encode(c)` where `c.self = c` → `{"name":"root","self":null}`. **The field is silently lost rather than flagged**, which contradicts the comment at services/AutoSerializer.lua:36-38 promising "the JSON encoder will barf, which is a deliberate loud signal" |
| LÖVE `userdata` (Image, Source, Canvas) nested in a table | Falls to `error("json.encode: unsupported type 'userdata'")` at lib/json.lua:91 |

The encode error is **not caught**: `services/SaveService.lua:75 local encoded = json.encode(wrapper, true)` has no pcall, so it propagates out of `love.update` (the autosave tick) or `love.quit` as a LÖVE crash screen. See §6.

**Medium — `AutoSerializer.apply` validates nothing:**

```lua
        else
            instance[k] = v
        end
```
(services/AutoSerializer.lua:63-65). Every key in the decoded payload is written onto the live model regardless of type or whether the model declares it. A corrupted or hand-edited save with `chips = "lots"` is accepted at load and crashes at the first arithmetic (`models/GameState.lua:717 self.chips - item.cost_chip`, "attempt to perform arithmetic on a string") rather than being rejected. It also means a retired key sticks to the instance until something deletes it — which is precisely why the `pp` migration must write `self.pp = nil` (models/GameState.lua:320).

### 5. lib/json.lua robustness

All claims below marked **PROVEN** were executed against the real `lib/json.lua` (script: `scratchpad/jsonprobe.lua`, Lua 5.4.6). Where in-game behaviour differs from the test interpreter (LuaJIT under LÖVE 11.4), that is called out.

**Critical — `lib/json.lua:41-43`: infinity encodes to a token the library's own decoder cannot read, destroying the whole file.**

```lua
    elseif t == "number" then
        if val ~= val then return "null" end  -- NaN guard
        return tostring(val)
```

NaN is guarded, infinity is not; `tostring(math.huge)` is `"inf"`. **PROVEN:**

```
encode: {"data":{"bankroll":inf},"version":1}
decode: nil    lib/json.lua:212: json.decode: unexpected character 'i' at position 21
encode -inf: {"x":-inf}   decode: nil
```

`-inf` fails differently but just as fatally: `decode_number`'s pattern `^-?%d+%.?%d*[eE]?[+-]?%d*` (lib/json.lua:141) does not match `-inf`. Either way `SaveService:read` (services/SaveService.lua:57-60) sees a nil and returns "decode failed" — identical to "no save" — so the player boots to a fresh game and the next 30s autosave overwrites the file. **Reachability of `inf` into a persisted number is REASONED, not proven**: no `math.huge` is assigned to a serialized field (`models/poker_effects.lua:273 ctx.loss_tier_ceiling = math.huge` lands only in the transient `effects_cache`), but `bankroll` is grown multiplicatively by uncapped stacking payout multipliers in Act 3. Confirming would need a fuzz of the payout chain. The encoder gap itself is certain and the blast radius is the entire save.

**High — NaN silently deletes the field rather than corrupting it. PROVEN:**

```
encode: {"bankroll":null,"keep":7}
bankroll key present after decode: false   keep: 7
```

`decode_value` returns nil for `null` (lib/json.lua:200), so `obj[key] = nil` leaves the key **absent from the decoded table**. `AutoSerializer.apply` iterates `pairs(data)` and therefore never touches it, and the `:new()` default survives. A NaN `bankroll` doesn't crash — the player silently reloads at $2 with their run intact, which reads as a bug report of "the game ate my money".

**Medium — precision loss on every non-trivial float. PROVEN:**

```
1234567.891234567 -> {"v":1234567.8912346}      roundtrip equal: false
2^53+1            -> {"v":9.007199254741e+15}
```

`tostring` is `%.14g`. Money is stored in dollars-and-cents (`bankroll`, `run_money_lost`, `active_table_stack`, `chips_this_run`), so a late-game bankroll past 14 significant digits loses cents on every save/load cycle and `bankroll` becomes non-reproducible across reloads. Encoding through `string.format("%.17g", v)` would round-trip exactly.

**Medium — `coerceIntKeys` will corrupt any future numeric-looking string key. PROVEN:**

```lua
        if type(k) == "string" and k:match("^%-?%d+$") then
            renames[k] = tonumber(k)
        end
```
(services/SaveService.lua:33-35). Test: `deck_levels = {["1"]=5, ["s001"]=2}` → after decode+coerce, `deck_levels["1"]` is **nil** and `deck_levels[1]` is 5. Inert today because every persisted map keys on an alphanumeric id (`"s001"`, `"six_max"`, hint ids, catalog ids). The first numeric id anywhere in `data/` silently breaks every `t[id]` lookup on load, with no error. Note the coercion also runs *after* the version gate, so it cannot help a migration.

**Low (working as intended) — sparse arrays round-trip correctly. PROVEN:**

```
encode: {"a":{"1":"x","3":"y"}}
after coerceIntKeys  a[1]: x   a[3]: y
```

`is_array` (lib/json.lua:22-29) rejects any table with a hole, so the nine sparse `active_table_*` parallel arrays (nil at every cash-table index) encode as objects and `coerceIntKeys` restores integer keys. Dense arrays stay arrays (`{"a":["p","q","r"]}`) and an empty table encodes as `[]`, decoding to a table that works as either. This is the one part of the pipeline built correctly for its data.

**Low — no recursion depth limit, but not reachable. PROVEN:** encoding a 60,000-deep chain raises `lib/json.lua:23: stack overflow`; *decoding* 60,000 nested `[` succeeded in Lua 5.4 (LuaJIT's limits differ — REASONED). Max real nesting is ~4 (`data → active_table_mtt_plans → [i] → hands → [j]`). A decode-side overflow would be caught by `json.decode`'s internal pcall anyway and degrade to "decode failed".

**Low — control characters emitted unescaped. PROVEN:** `encode_string` (lib/json.lua:12-20) escapes only `\ " \n \r \t`, so `"a\1b\bc"` becomes `{"s":"a<01>b<08>c"}` — accepted by this decoder, rejected by any spec-compliant one. That matters for exactly one consumer: `services/HandAnalytics.lua:141 print(ANALYTICS_MARKER .. json.encode(_file_data))` is `JSON.parse`d by the Cloudflare worker, so one control byte in a player-visible string silently drops that player's whole analytics upload.

**Low — `\u` escapes decode to `?` in-game.** `lib/json.lua:129` does `utf8 and utf8.char(tonumber(hex,16))`. In my Lua 5.4 test the `utf8` global exists and `"é"` decoded to `é`; under LuaJeit/LÖVE `utf8` is **not a global** (it requires `require("utf8")`), so the branch falls through to `'?'` (REASONED). Surrogate pairs are unhandled in either case. Inert today because the encoder never emits `\u` — it passes UTF-8 bytes through raw.

**Low — malformed input is handled cleanly. PROVEN:** `json.decode` pcalls internally and returns `nil, err` for `""`, `"{"`, `'{"a":}'`, `"not json"`, `'{"a":1,}'`, and a UTF-8 BOM. A truncated file (crash mid-write, §6) yields `json.decode: unterminated string`. All land on `SaveService:read`'s `type(decoded) ~= "table"` check → "decode failed" → fresh game.

**Nit — `SaveService:read`'s pcall is redundant and its error branch unreachable.**

```lua
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
```
(services/SaveService.lua:57-58). `json.decode` already pcalls internally (lib/json.lua:219-225), so `ok` is always true and the real error message is discarded. PROVEN: `pcall(json.decode,"garbage")` → `true, nil, "…unexpected character 'g'…"`. Nothing logs why a save failed to load, which is why a corrupted save is indistinguishable from a fresh install in a bug report.

**Nit — non-string/non-number keys are silently dropped** (lib/json.lua:72-78): `json.encode({[true]="x", y=1})` → `{"y":1}`, no error.

### 6. Write safety

**Critical — the save is not atomic. `services/SaveService.lua:76` writes straight over the live file.**

```lua
    local encoded = json.encode(wrapper, true)
    local ok, err = love.filesystem.write(filename, encoded)
```

`love.filesystem.write` opens the target path with mode `"w"`, which **truncates first**. There is no temp file, no `os.rename`, no `.bak`, and no fsync. Any interruption between truncate and completion — power loss, OS kill, browser tab close, a LÖVE crash on another thread — leaves `meta.save` truncated or empty. PROVEN downstream: a save truncated to 60% decodes to `nil` with `json.decode: unterminated string`, which `SaveService:read` reports as "decode failed", which `loadAll` reports as nil, which `GameState:new` treats as a fresh game. **The player loses everything and the game shows no error.** The one-line fix is write-to-`meta.save.tmp` then rename.

**High — `json.encode` is not pcall'd, so an encode failure crashes the game instead of skipping a save.** `services/SaveService.lua:75` runs outside any protected call, on the `love.update` autosave path (main.lua:337) and the `love.quit` path (main.lua:418). Any unsupported nested type (§4) becomes a LÖVE error screen mid-session; on the quit path it turns a clean exit into a crash, and — because `love.quit` is where the last 30s of progress is flushed — that progress is lost.

**High — meta and run are two independent non-atomic writes, so a crash between them tears the save into an exploitable state.**

```lua
function SaveService:saveAll(meta_payload, run_payload)
    if meta_payload then self:write(Constants.SAVE.META_FILE, meta_payload) end
    if run_payload  then self:write(Constants.SAVE.RUN_FILE,  run_payload)  end
end
```
(services/SaveService.lua:94-97). A {chip} bounty credits `state.chips` (meta.save) while the once-per-run lock lives in `state.stakes_won_this_run` (run.save, set at controllers/GrindController.lua:276 and :630). If `meta.save` lands and `run.save` does not, the reload keeps the chips **and** loses the lock, letting the player re-bank the same stake bounty. The inverse ordering loses banked chips while keeping the lock. Both slots need to be written through temp files and renamed together.

**Concurrent writes: no true race, but real gaps.** LÖVE is single-threaded; the autosave tick (main.lua:337), `SettingsModal`'s manual SAVE (views/SettingsModal.lua:137), `GrindState:quickReset` (:185), `ShoveState` (:176, :197), `CreditsState` (:70) and `love.quit` (main.lua:418) all run sequentially on the main thread, so no interleaving is possible. The gaps are behavioural:

- **Medium — autosave is suppressed while any "idle modal" is open** (main.lua:326-333: `catalog_modal`, `prestige_modal`, `prototype_end_modal`, `deck_select_modal`, `onboarding_modal`). Buying catalog items is a `state.chips` mutation that happens *inside* the catalog modal. A player who spends 20 minutes in the catalog and then crashes or force-quits loses every purchase back to the last pre-modal autosave.
- **Medium — `love.quit` does NOT flush unconditionally**, contradicting its own comment at main.lua:322 ("love.quit flushes unconditionally"). main.lua:416 gates on `current == "grind" or current == "shove"`, so quitting from `title`, `credits`, or `room` writes nothing. `RoomState` mutations and the credits-screen path rely on their own explicit saves.
- **Low — `AUTOSAVE_INTERVAL = 30`** (data/constants.lua:153). Worst-case unsaved window is 30s of grinding, or unbounded with a modal open.

**High (web/itch) — on love.js, `love.quit` never fires when the tab closes, and IDBFS flushes asynchronously.** The itch build is the web export (`conf.lua:12-17` detects web by a failed `require("ffi")`; `Constants.FEATURES.QUIT_DISABLED` exists at data/constants.lua:67 precisely because "love.event.quit() hard-errors the canvas"). Closing the browser tab or navigating away stops the Emscripten main loop without running `love.quit`, so the final-flush path at main.lua:409-420 is dead on the platform players actually use. `love.filesystem.write` writes into MEMFS/IDBFS and the persist to IndexedDB is asynchronous, so even a completed `write()` can be lost if the tab closes before the sync callback runs — a second, platform-level way to get a torn or missing file. Nothing registers a `beforeunload`/`visibilitychange` flush. (REASONED from the build setup and the existing web-specific workarounds in this repo; confirming needs a love.js run.)

**Low — no slots, no backup, no recovery.** Exactly three fixed filenames (`meta.save`, `run.save`, `settings.save` — data/constants.lua:152-158) under identity `poker-idle` (conf.lua:26). There is no slot picker, no rolling backup, and no export/import. Every failure mode in §2 and §5 ends with the corrupt or unreadable file being replaced by fresh-game state at the next autosave, so the player cannot even recover by hand-editing.

**Low — the analytics file is rewritten in full on every autosave tick.** `services/HandAnalytics.lua:50 love.filesystem.write(_filename, json.encode(_file_data, true))` re-encodes *every hand of every shove ever recorded* on this save, every 30 seconds, pretty-printed, on the main thread — and `DEBUG.HAND_ANALYTICS` is `true` (data/constants.lua:115). It grows without bound and is never pruned. `SaveService:clearAll()` (services/SaveService.lua:107-112) removes only the two `.save` files, so `analytics_<save_id>.json` is orphaned on every "new game" and accumulates forever, since `wipeAll` mints a fresh `save_id` (models/GameState.lua:296).

### 7. Settings and consent persistence

**Separate file, but the same version gate.** `settings.save` is written by `SaveService:saveSettings` → `SaveService:write` (services/SaveService.lua:117-123), so it gets the identical `{version, timestamp, data}` wrapper and passes through the same `decoded.version ~= VERSION` rejection at :61. The header comment at services/SaveService.lua:114-116 claims settings "aren't versioned with the run schema" — **they are**. Bumping `SAVE.VERSION` to migrate gameplay data silently also resets everyone's volume and revokes their analytics consent, which is the one setting that should never be silently flipped.

Payload is just `{ volume, analytics_consent }` (main.lua:194-197). It survives `clearAll()` (which removes only meta/run), and `g.startNewGame` explicitly re-writes `analytics_consent = false` on a wipe (main.lua:245-248) — correct, conservative behaviour.

**Medium — consent is coerced to a boolean at load, which erases the "not yet asked" state and makes the consent modal unreachable in the live build.**

```lua
        analytics_consent = prefs.analytics_consent == true,  -- nil → false
```
(main.lua:196). `g.settings.analytics_consent` is therefore never nil. The only place that tests for "unasked" is:

```lua
        elseif self.game.settings
               and self.game.settings.analytics_consent == nil then
            self.analytics_modal = AnalyticsConsentModal:new(self.game)
```
(states/GrindState.lua:211-214) — **dead code**, same class of bug as the `== nil` migration guards in §3. With `FEATURES.ONBOARDING_MODAL = C.PROTOTYPE_MODE` (data/constants.lua:79) and `PROTOTYPE_MODE = false` (:19), the `if` branch (`self:openHelp()`) is also skipped, so on the currently live config a fresh install runs straight to `_finalizeOnboarding()` and **the player is never asked about analytics at all**. Consent defaults to declined, so no data leaves the machine — the failure is conservative — but `views/AnalyticsConsentModal.lua` is unreachable and the onboarding checkbox path (states/GrindState.lua:146-156) never runs either. The escalation modal only exists in the prototype build.

Where the consent flow *is* reachable (prototype build), it behaves correctly: `_dismissOnboarding` (states/GrindState.lua:146-156) escalates to the full modal only on a true first run with the box unchecked, `_saveConsent` (:165-170) persists immediately, and `SettingsModal`'s toggle merge-writes the whole settings table so volume is not clobbered (views/SettingsModal.lua:38-44).

**Critical — `views/SettingsModal.lua:115-118`: the in-game LOAD button wipes the player's live progress before it knows whether a save exists.**

```lua
function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    g.state:wipeAll()
    local saved = g.save_service:loadAll() or {}
```

`wipeAll()` runs unconditionally and first. `SaveService:loadAll` (services/SaveService.lua:86-91) **always returns a table** — `{meta = nil, run = nil}` when both slots are missing or unreadable — so the `or {}` guard is dead and `applySaved` is then called with nothing to apply. Pressing LOAD when the save files are absent (after `startNewGame`, which calls `clearAll()` at main.lua:243) or unreadable (version mismatch, truncation, an `inf` in the payload — all of §2 and §5) **destroys the entire in-memory game**: chips, owned items, decks, lifetime counters, the active run. The state machine then switches to `grind` and the 30-second autosave commits the wiped state to disk. There is no confirmation dialog on LOAD — `new_game` and `quit` both route through `_openConfirm` (views/SettingsModal.lua:141-142) but `load` calls the handler directly (:140). This is one misclick, or one corrupt save, from total unrecoverable loss.

(Secondary: `_performLoad` is a view mutating the model and driving a state transition, which is an MVC-rule violation — flagged here only because the fix belongs in the same place.)

### Prioritised fix list

1. **Guard `SaveService:read` against version drift** (services/SaveService.lua:61-63). Replace the `~=` rejection with a migration chain keyed on `decoded.version`, and treat an *unknown newer* version as "refuse to load and refuse to overwrite" rather than "fresh game". Until that exists, `C.SAVE.VERSION` is unbumpable — worth a comment saying so at data/constants.lua:157.
2. **Never overwrite a save that failed to load.** Set a `load_failed` flag when `read` returns non-nil error other than "no save", and suppress all autosave/quit writes while it is set. This single change neutralises the player-facing consequence of §2, §5, and §6 at once.
3. **Fix the two dead `== nil` migration guards** (models/GameState.lua:390-399) — test the raw payload (`saved.meta.has_shoved == nil`), not the post-`:new()` instance field. Live saves are currently losing their SHOVE and CATALOG buttons.
4. **Make LOAD safe** (views/SettingsModal.lua:115-118) — read first, bail if both slots are nil, only then `wipeAll()`; and route it through `_openConfirm` like `new_game`.
5. **Atomic writes** — `SaveService:write` to `<file>.tmp` then rename; write both slots before renaming either so meta/run can't tear (services/SaveService.lua:69-82, :94-97).
6. **Handle infinity in `json.encode`** (lib/json.lua:41-43): extend the NaN guard to `val ~= val or val == math.huge or val == -math.huge`, and format finite numbers with `%.17g` to stop cents drifting.
7. **pcall the encode** in `SaveService:write` (services/SaveService.lua:75) and log a failure instead of crashing; log the real decode error in `read` (:57-58) instead of discarding it.
8. **Delete or implement `AutoSerializer.serialize`.** Either wire the auto path in, or delete it plus `GameState.TRANSIENTS`/`REFS` and correct the three comments (models/GameState.lua:7-8, services/AutoSerializer.lua:7-8, services/SaveService.lua:15). Add a test asserting every `:new()` field appears in `serializeMeta` ∪ `serializeRun`.
9. **Save-safe fallback for unknown stake ids in `active_table_specs`**, mirroring the gtype fallback already at models/TablePool.lua:82, so a retired stake degrades to a playable table instead of a permanently dead one.
10. **Web flush** — register a `beforeunload`/`visibilitychange` hook in `build-tools/index.html` that drives one final `saveAll`, since `love.quit` never fires on tab close.
11. **Re-ask consent on the live build** — either restore the "unasked" tri-state (store `analytics_consent` as nil/true/false instead of coercing at main.lua:196) or gate the modal on something other than `FEATURES.ONBOARDING_MODAL`.
12. **Bound the analytics file** — cap retained shoves, drop `pretty` on the write, and delete `analytics_<save_id>.json` in `SaveService:clearAll()`.
13. **Store `highest_stake_idx` as a stake id**, not a positional index (models/GameState.lua:503).

---

## Runtime performance and GC pressure


### Font and text

**Medium — `views/IconText.lua:68-98` `walk()` re-parses `{token}` markers on every call, no cache, plus a fresh closure per call.**
`IconText.draw`/`IconText.measure` both funnel through `walk()`, which re-scans the string byte-by-byte via `str:find("{([%w_:]+)}", i)` in a `while` loop every single call, and allocates a fresh `local function text(seg)` closure every call:
```lua
local function walk(game, str, x, y, font, color, alpha, draw)
    ...
    local function text(seg)          -- new closure every call
        ...
    end
    while i <= n do
        local s, e, token = str:find("{([%w_:]+)}", i)   -- re-parsed every call, no cache
        ...
```
No memoization keyed on the string — a static catalog `effect_text` or a floater message gets re-tokenized every draw it's on screen, and any call site that also calls `IconText.measure` for layout (common — measure-then-draw pairs) parses the same string twice. Cost scales with string length × call frequency; used for chip/currency copy (`{chip}`) which is pervasive per user's own convention (`feedback_use_chip_icon.md`), so this runs often. `(unverified: exact per-frame call count)` — would confirm by grepping `IconText.draw(` / `IconText.measure(` call sites inside `draw()` functions and counting.

**Low, verified-not-a-bug — `views/Chips.lua:34-42` `love.graphics.newFont` outside Theme/FontService, but correctly lazy-cached.**
```lua
local _label_font
local function getLabelFont()
    if not _label_font then
        _label_font = love.graphics.newFont(LABEL_FONT_PX, "normal", 1)
        _label_font:setFilter("nearest", "nearest")
    end
    return _label_font
end
```
Confirms the brief's suspicion that this bypasses `Theme`/`FontService` (an **architecture** rule-3 concern — literal font construction outside `data/theme.lua`/`views/Theme.lua`), but from a **performance** standpoint it is fine: built once, invalidated only by `Chips.setScale()` (called on boot/resize only, `main.lua:132`/`:393`), not per frame. Not a GC-pressure finding — flag as architecture drift only.

**Good pattern (contrast) — `views/TablePanel.lua:445-464` opponent-name ellipsis truncation IS memoized.**
```lua
if opp._lbl_w   ~= w
   or opp._lbl_fh  ~= fh
   or opp._lbl_raw ~= raw_name then
    ...
    while n > 0 and name_font:getWidth(raw_name:sub(1, n) .. ell) > w - label_pad do
        n = n - 1
    end
    ...
    opp._lbl = label; opp._lbl_w = w
```
Comment even states the intent: "Stable steady-state = zero getWidth calls in this block." This is the correct pattern and should be the template applied elsewhere (see CatalogModal finding below).

**Medium — `views/CatalogModal.lua:183-190,738,761` `clampText()` has no such cache; re-measures every draw.**
```lua
local function clampText(str, font, avail)
    str = str or ""
    if avail <= 0 or str == "" or font:getWidth(str) <= avail then return str end
    while #str > 1 and font:getWidth(str .. "...") > avail do
        str = str:sub(1, #str - 1)
    end
    return str .. "..."
end
```
Called at `views/CatalogModal.lua:738` (item name) and `:761` (item description) inside `drawItemCard` (`views/CatalogModal.lua:466-~904`, 438 lines per brief), which runs once per visible catalog card per frame while the modal is open. Each call does an uncached `while` loop of `font:getWidth()` calls (proportional to how many characters must be trimmed) — unlike the sibling pattern in `TablePanel.lua` above, there is no `item._clamped_name`/width-guard cache. Cost: (visible cards per page) × (up to ~40 chars trimmed for a long description) × `getWidth` calls, every frame the catalog is open — catalog is a modal a player can leave open for minutes while browsing (see main.lua:317-331 autosave-skip comment confirming long browse sessions are expected).

### Particle / effect systems

Overall these are well-built relative to the rest of the codebase: every removal loop checked iterates in reverse (`for i = #list, 1, -1`), so none has the classic forward-loop `table.remove` skipped-element bug, and every list is bounded. Findings below are about allocation shape, not correctness bugs.

**Good — `services/FloatingTextSystem.lua:56-105` `update()` reverse-iterates correctly; capped by `Constants.FLOATING_TEXT.MAX_ITEMS` with drop-oldest at `:27-29`. No pooling (fresh table per `emit`), but emission is per hand-resolution, not per frame — acceptable.**

**Good — `services/FlightSystem.lua:278-294` `update()` reverse-iterates correctly; capped at `MAX_IN_FLIGHT = 800` with drop-oldest via `table.remove(_flying, 1)` (`:85-90`).** Note: dropping from the *front* of a Lua array is O(n) (shifts every remaining element) — at the 800 cap that's a real but rare cost, only paid on sustained overflow (multiple simultaneous jackpot bursts). Not pooled: every `FlightSystem.emit` (`:82-` ) allocates a new entity table plus the caller supplies a fresh `render_fn` closure per entity (e.g. `services/Confetti.lua:35-47 makeQuadFn` closes over `color/size/rot_speed` per quad). `Confetti.lua` itself is dead code (its own header: "NOT CURRENTLY CALLED"), but the same per-entity-closure shape is live via the chip-burst path (`controllers/GrindController.lua:_emitAmountExplosion`/`_queueBurst`/`_queueScatter`, capped at `MAX_PER_EVENT = 7` per burst in FlightSystem). Emission is event-driven (hand resolution / payout), not per-frame, so GC pressure is bursty rather than steady — worth noting for the web build since a burst of 7-entity closures × several simultaneous table resolutions can still spike allocations right when other per-hand effects (floaters, shake, glow) also fire in the same frame.

**Good — `services/Ghosts.lua:33-43` `update()` reverse-iterates correctly, capped implicitly by click frequency, self-clears.**

**Good — `services/ClickFlash.lua:43-59` uses a nested dict (`{[ns]={[id]=alpha}}`) with `nil`-out cleanup and empty-namespace pruning — no array growth at all, cheapest of the group.**

**Good — `services/Pop.lua:25,61` uses two stable-id-keyed dicts (`_fired`, `_seen`) that self-clear (`_fired[id] = nil` once a pop finishes) — no unbounded growth, no per-frame table churn.**

**Low — `services/Decal.lua:35` `for i = 1, #key do` — forward loop, but this iterates a lookup key string being built, not an entity list being pruned; not a removal-loop bug. Not further inspected in depth given time budget.**

**services/BandStack.lua, services/Tumble.lua, views/AwardGlow.lua — not stateful particle stores (BandStack is a pure layout allocator, reused inside the per-frame `FeltLayout.compute` hot path — see "Algorithmic problems" section; Tumble/AwardGlow are stateless render-decorator helpers, not entity lists) — no pooling concern applies to them the way it does to the emitter systems above.**

### The hot draw path

Trace: `main.lua love.draw()` (`:344-368`) → `Game.state_machine:draw()` → active state's view (e.g. `states/GrindState.lua` → `views/GrindView.lua` → `views/TablePanel.draw` per table + `views/RoomView.lua`, etc.) → all drawn into a fixed `_frameCanvas` (1600×900), then the canvas is scaled to the window by one shader pass.

**Low — `main.lua:362-363` sends two fresh table literals to the scale shader every frame even though the values only change on resize.**
```lua
_scaleShader:send("u_sourceSize", { BASE_W, BASE_H })
_scaleShader:send("u_scale",      { s, s })
```
`BASE_W`/`BASE_H` never change; `s` only changes on window resize. This allocates 2 short-lived tables every single frame (unconditionally, regardless of active state) purely to feed a shader uniform that is constant almost all the time. Trivial in isolation but it's the one allocation that fires literally every frame with zero gating — cheapest possible fix (cache `s` and skip the `send` when unchanged, or send flat args instead of tables if the LÖVE version supports it).

**Medium — redundant/high-volume `setColor`/`setFont` calls per table panel, not deduplicated.**
`views/TablePanel.lua` draws one panel per active table per frame and contains 41 `Theme.setColor(...)` call sites and 19 `love.graphics.setFont(...)` call sites (`grep -c`, confirmed). With even a modest number of concurrently open tables (cap `Constants.GAMEPLAY.MAX_TABLES = 32`, `data/constants.lua:129`, though the visible grid is smaller), that is several hundred `setColor`/`setFont` calls per frame from this one view alone. LÖVE's `setColor`/`setFont` are cheap individually (no draw-call cost by themselves — they don't flush a batch), so this is not the top-priority item, but many of these calls are provably redundant in sequence (e.g. `views/TablePanel.lua:1429/1434` both set colors immediately before/after a single `rectangle("line",...)` that only fires in one branch — see below) rather than deduplicated against the last-set color. `(unverified precise count)`: would confirm with a runtime instrumentation counter around `love.graphics.setColor`; the static count above is a floor, not the true per-frame call count (some are inside conditionals).

**Medium — `views/TablePanel.lua:1434` `Theme.setColor({ 0.65, 0.35, 0.95 })` allocates a table literal AND hardcodes a literal color every draw call for anti-banked tables (also an architecture rule-3 violation — literal color outside `data/theme.lua`/`Theme.lua`).**
```lua
elseif anti_banked then
    Theme.setColor({ 0.65, 0.35, 0.95 })
    love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
end
```
Runs once per anti-banked table panel per frame. Same shape repeats at `views/TablePanelStats.lua:1019,1023` (`Theme.tier.loss.jackpot = { 0.55, 0.25, 0.85 }` and `Theme.setColor({ 0.55, 0.25, 0.85 })`) inside `drawEvReadout`'s loss-glyph branch — also a per-table-per-frame literal-table allocation plus a mutate-then-restore of a **shared Theme table** (`Theme.tier.loss.jackpot`) as a smuggled-in "parameter", which is fragile (not thread/reentrancy-safe, though LÖVE is single-threaded so this is a code-smell rather than a live bug) as well as a perf allocation.

**Medium — `views/TablePanel.lua:1450-1452` felt-tint fallback allocates a table literal per panel per frame whenever a stake has no `felt_tint` theme entry.**
```lua
local felt_color  = (stake_theme and stake_theme.felt_tint)
                    or { Theme.status.good[1], Theme.status.good[2],
                         Theme.status.good[3], 0.18 }
```
`(unverified whether any live stake actually lacks a `felt_tint`)` — would confirm by reading `data/stake_themes.lua` against `data/stakes.lua`'s id list; if all stakes are themed this fallback never fires in practice and the finding downgrades to Low/dead-code.

**Missed batching (SpriteBatch candidates), verified — chips and per-glyph shapes are drawn as individual `love.graphics.circle`/`rectangle`/`draw` calls, never through a `love.graphics.SpriteBatch` or `love.graphics.Mesh`.**
`views/Chips.lua:70-100 Chips.drawChip` issues 2 `love.graphics.circle("fill", ...)` calls (outer ring + inner disc) plus an optional `love.graphics.print` per chip, with no batching — see `Chips.lua:80-86`. A stack can hold up to `MAX_PER_COLUMN = 6` chips per column (`Chips.lua:29`) across multiple denomination columns; a table panel can show a pot pile, a player stack, and per-opponent piles simultaneously. None of this goes through a SpriteBatch, so each chip is 2-3 separate draw-call-eligible primitives with their own `setColor` before each. Procedural circles (not textured quads) can't use `SpriteBatch` directly without first becoming a stamped texture, so the fix would be "pre-render one chip texture per denomination+tint combination once, then batch-draw the texture" rather than a drop-in SpriteBatch swap — flagged as an architectural follow-up, not a one-line fix.

**`services/SpriteRenderer.lua:24-49` — verified no per-draw quad/atlas-index lookup cost beyond a single table hash (`atlas:getSprite(sprite_name)` → `self.sprites[_resolve(self, sprite_name)]`, `services/SpriteLoader.lua:154-157`).** This is a plain Lua dict lookup, O(1) amortized, not a scan — not a hotspot. No SpriteBatch here either (each `SpriteRenderer.draw` call is one `love.graphics.draw`), but since sprites are already discrete `love.Image`s (not procedural shapes), a genuine `SpriteBatch` conversion is feasible here if card/sprite draw volume ever becomes the bottleneck — lower priority than the chip case since cards are far fewer per table (2 hole + up to 5 community + 2 per opponent) than chips.

### Per-frame allocations in the biggest draw functions

**Critical, verified — `views/TablePanelStats.lua:995-1038` `drawEvReadout()` rebuilds the full EV breakdown (a heavy compute) every frame for every visible cash table, only to discard it 59 times out of 60.**
`views/TablePanel.lua:1587-1589` calls this unconditionally whenever a cash table's EV row is shown:
```lua
if L.bottom and L.bottom.ev.show and not is_tournament then
    Stats.drawEvReadout(tbl, L.bottom.ev, controller, fonts, hit_boxes, ...)
```
Inside, `hit_boxes` is always the real per-frame array (never nil during normal draw), so this branch always runs:
```lua
if hit_boxes then
    local lines = buildEvBreakdownLines(tbl, controller)   -- views/TablePanelStats.lua:1028
    if lines then
        hit_boxes[#hit_boxes + 1] = { ..., tooltip = lines }
    end
end
```
`buildEvBreakdownLines` (`:894-896`) calls `tbl:debugStats(ctx)` → `Table_legacy.lua:979-1011`, which itself calls `self:tableOutcome(ctx)` (`:969-974`) → `buildOutcome(ctx, gtype, stake)` (`Table_legacy.lua:212-`). `buildOutcome` does 3 linear scans over `ctx.win_chance_fills`/`win_dist_fills`/`loss_dist_fills` (`sumFills`, `:172-181`), 2 fresh-table allocations via `lerpDist` (`:198-206`, one new `{}` per dist, each looping `TIER_KEYS`), plus multiple `Lookups.findById`/`indexById` linear scans, then `debugStats` wraps the result in another fresh `{ stake=, gtype=, pool={...} }` table. The returned `lines` list is then built by `breakdownFromStats` via `row()`/`iconRow()` (`TablePanelStats.lua:85-104`) — `row()` allocates one table per line, `iconRow()` allocates a table **plus two closures** (`measure`, `render`) per icon line. All of this — EV math, table churn, closures — is thrown away unless the mouse happens to be hovering that exact table's EV readout at that exact frame; `renderDebugTooltip`/`stashDebugTooltipIfHover` (`:1045-1058`) is the *only* consumer of `lines` (via the hit_box's `.tooltip` field, drawn by the shared `Tooltip` widget on hover). Cost: (active cash tables, up to `MAX_TABLES = 32`) × (this full EV-math + table/closure-allocation chain) × 60/sec, for a value used only while hovering. This is the single biggest verified per-frame allocation source found in the audit and directly answers the brief's question 2 ("Check whether TablePanelStats.lua builds row tables containing closures per tooltip, and whether that is per-frame" — **confirmed: per-frame, not per-tooltip-open**).

**High, verified — `views/FeltLayout.compute()` (`views/FeltLayout.lua:66-`) is called fresh every frame per table panel (`views/TablePanel.lua:1476`) and allocates ~10+ short-lived tables + a closure to compute layout that is static between resizes/table-count changes.**
```lua
local bands = {
    { min_h = opp_min,    weight = 0 },
    { min_h = comm_min,   weight = 0 },
    { min_h = pot_min,    weight = 1 },
    { min_h = hole_min,   weight = 0 },
    { min_h = bottom_min, weight = 0 },
}
local rects = BandStack.allocate(usable_h, bands, gap)   -- FeltLayout.lua:167
```
`bands` is 1 outer table + 5 inner tables = 6 allocations; `BandStack.allocate` (`services/BandStack.lua:34-`) allocates its own `kept` table plus a `local function requiredHeight()` closure per call (`:37-40`); `scaleSizes` (`FeltLayout.lua:48-55`) returns a fresh 6-field table whenever `card_scale ~= 1` (the common case); `miniLayout()` (`:138-150`) is defined as a closure every call even on the path where it's never invoked. None of the inputs (`felt_x/y/w/h`, `n_opps`, `sizes`, `s`) change frame-to-frame outside a resize or a table being added/removed/re-staked — this is exactly the brief's "rebuilding derived data that changes once per hand" pattern (item 6), just applied to layout instead of poker state. Fix shape: cache the computed `L` on the table object, keyed on `(felt_w, felt_h, n_opps, s)` the same way `TablePanel.lua`'s opponent-label cache already does elsewhere in the same file.

**Medium — `views/RoomView.lua:368-373` rebuilds an owned-items lookup set from scratch every frame.**
```lua
local owned_set = {}
if state.owned_items then
    for _, id in ipairs(state.owned_items) do
        owned_set[id] = true
    end
end
```
`state.owned_items` only grows when the player unlocks/buys a room item — an infrequent event — yet this full array→set rebuild runs on every `RoomView:draw` call. Low-cardinality (probably tens of items) so individually cheap, but it is pure waste every frame the Room view is visible.

**Medium — `views/RoomView.lua:508-527` `render_list` is rebuilt AND depth-sorted (`table.sort` with a fresh comparator closure) every single frame.**
```lua
local render_list = {}
for _, obj in ipairs(self.placed) do
    local owned = owned_set[obj.id]
    if owned or self.editor_mode then
        render_list[#render_list + 1] = obj
    end
end
table.sort(render_list, function(a, b)     -- new closure every frame
    local depth_a = (a.gx + a.w * 0.5) + (a.gy + a.h * 0.5)
    local depth_b = (b.gx + b.w * 0.5) + (b.gy + b.h * 0.5)
    ...
end)
```
`self.placed` (the room's furniture layout) changes only in the room editor (an explicit, rare edit action) — the painter's-algorithm depth sort has no reason to re-run every frame during normal (non-editor) viewing. An O(n log n) sort plus a fresh comparator closure, every frame, for data that is frame-to-frame identical almost all the time. Fix shape: sort once when `self.placed` (or `owned_set`) actually changes, cache `render_list` until invalidated.

**Low — `views/RoomView.lua:178,292` per-frame color-tint table literals** (`color = { color[1], color[2], color[3], 0.40 }` and a hardcoded `{ 0.92, 0.72, 0.32, 0.50 }` translucent-amber preview color) — small, but same "literal table + literal color bypassing Theme" shape seen in TablePanel; low individual cost since these are per-hovered/preview-item, not per every item.

**`views/CatalogModal.lua` `drawItemCard` (`:466-~904`) — beyond the already-reported uncached `clampText` calls (Font/text section above), no additional large per-card table allocations were found distinct from ordinary per-card layout math; not further broken down given time budget.**

### GrindController:update(dt) — sampled, not read exhaustively

**Medium, verified — `controllers/GrindController.lua:178-340` runs 5 separate `ipairs(self.pool.tables)` passes every frame, unconditionally, plus 2 unconditional table allocations, before any early-out.**
```lua
function GrindController:update(dt)
    local prev_states = {}                          -- :181, fresh table every frame
    for i, t in ipairs(self.pool.tables) do
        prev_states[i] = t.state
    end
    local resolutions = self.pool:update(dt, self.ctx)   -- :186
    for i, t in ipairs(self.pool.tables) do ... end       -- :191, sound-transition scan
    for _, t in ipairs(self.pool.tables) do ... end       -- :201, pending-buyin scan
    for i = #self.pool.tables, 1, -1 do ... end           -- :213, pending-close scan (reverse, correct)
    for _, t in ipairs(self.pool.tables) do ... end       -- :223, MTT payout-drain scan
    if #resolutions == 0 then return end                  -- :342, first possible early-out
```
`models/TablePool.lua:173-183` `TablePool:update` also allocates `local resolutions = {}` fresh every frame (`:174`) even when nothing resolved. With `Constants.GAMEPLAY.MAX_TABLES = 32` (`data/constants.lua:129`) as the ceiling, this is up to 6 table-array walks + 2 fresh table allocations, every frame, regardless of whether any table actually changed state — before the function's only early-return. Individually each pass is cheap (an `ipairs` walk with no allocation inside for 4 of the 5), so this is more "several redundant passes that could be one" than a GC hotspot; the `prev_states = {}` and `resolutions = {}` allocations are the real (small) per-frame GC cost here, sized to the live table count rather than fixed.

**Low, by design (not a bug) — `Lookups.findById`/`indexById` (`utils/lookups.lua:10-28`) are called from the per-frame table-update path (`Table_legacy.lua:763,970,980,981,1014,1015` and `GrindController.lua:390`) as linear scans, but the backing data lists are tiny (`data/game_types.lua` has 3 entries, `data/stakes.lua` has 10, confirmed by count) — consistent with the file's own doc comment that this is deliberate for short lists.** Confirmed used consistently across the sampled call sites (no ad-hoc reimplementation of the scan found elsewhere in the sampled files) — matches the brief's question about `utils/lookups.lua` usage; no finding warranted beyond noting it's fine at this data size.

**Not further explored**: the resolution-application block (`GrindController.lua:342-~814`, gated behind `if #resolutions == 0 then return end`) contains `string.format`/`..` concatenation and small table literals (`floater_opts_override = {...}`, HandAnalytics record tables) — but these only run once per **hand resolution** (bounded by how often a table actually finishes a hand, i.e. seconds-to-tens-of-seconds per table, not per frame), so they were deprioritized under the time budget in favor of the confirmed per-frame paths above. `(unverified in detail — flagged for a follow-up pass if budget allows, not because a specific bug is suspected)`.

### Algorithmic problems (summary — see per-function findings above for detail)

- `views/FeltLayout.compute` recomputed from scratch every table-panel-frame instead of cached/invalidated (see Per-frame allocations section) — the clearest "rebuilding derived data that changes once per hand" instance.
- `views/RoomView.lua` `render_list` sorted every frame regardless of whether `self.placed` changed (see above).
- `views/TablePanelStats.lua` `drawEvReadout` recomputes full EV distribution math every frame per table for a hover-only tooltip (see above) — the standout algorithmic waste of the audit, both allocation-heavy and compute-heavy (multiple linear scans + lerps per call).
- `utils/lookups.lua` linear scans are used consistently and are fine at current data sizes (3-10 entries); no O(n²) risk there today, but worth a note if any data list (`data/catalog.lua`, `data/stickers` etc.) grows into the hundreds — `grep -c "^\s*{" data/catalog.lua` was not checked in this pass. `(unverified — flagged, not confirmed a problem)`.
- No other quadratic-shaped loop (nested nested loops over the same growing list) was found in the sampled hot-path files; the removal-loop audit (particle systems section) found zero forward-loop `table.remove` bugs — every list-mutating loop checked uses reverse iteration correctly.

### Shaders and canvases

**Low — `main.lua:362-363`, already reported under "hot draw path": scale-shader uniforms re-sent every frame via fresh table literals even though constant outside resize.**

**Good — `views/HintView.lua:263-269` `_drawDim` canvas is properly cached and only reallocated on a real size change:**
```lua
if not self._dim_canvas
   or self._dim_canvas:getWidth()  ~= W
   or self._dim_canvas:getHeight() ~= H then
    self._dim_canvas = love.graphics.newCanvas(W, H)
end
```
Since `love.graphics.getDimensions` is monkeypatched in `main.lua:88-90` to always return the fixed `BASE_W, BASE_H` (1600×900 design resolution), this guard means the canvas is allocated exactly once for the process lifetime in practice — correct pattern, no finding.

**No other `love.graphics.newCanvas` call was found outside `main.lua`'s one-time `_frameCanvas` and `HintView`'s cached `_dim_canvas`** (checked via `grep -rn "newCanvas" views/ services/ states/ controllers/`) — no per-frame canvas allocation anywhere in the sampled tree.

**Shader `:send()` call sites are all inside conditionally-active effect branches** (`views/DeckSelectModal.lua:166,356`, `views/GrindView.lua:1199`, `views/TablePanelEffects.lua:121-122`) sending a live `u_time`/`u_intensity`/`u_color` uniform — these are legitimately per-frame-varying values while the effect is active, not redundant unchanged-uniform sends. No finding.

### dt handling

**Good — no fixed-timestep or hardcoded-60fps assumption found.** Searched for `1/60`, `dt * 60`, accumulator patterns; the only "accumulator" is the autosave timer (`main.lua:114,333-339`, correctly `dt`-accumulated, gated to non-menu states, and flushed unconditionally on quit). `Table_legacy.lua:721-` (`Table:update`) scales every decay/rise rate by `dt` directly (`shake_trauma - d * SHAKE_DECAY_RATE`, etc.) — genuinely variable-timestep, no death-spiral risk (no `while dt > FIXED_STEP` consuming loop anywhere in the sampled files). `conf.lua` sets `t.window.vsync = 1` — standard vsync-on assumption, reasonable default; no evidence the game logic assumes vsync is honored (dt is read from LÖVE's actual frame delta, not derived from a fixed 1/60 constant).

### Load-time cost / boot print spam — brief's claim partially corrected

**Verified: the brief's "198 unconditional `print()` calls" figure is real as a grep count but is dominated by `love.graphics.print` (a draw call, not console output) and by build-tooling under `node_modules`/`build/`.** Re-running the count excluding `love.graphics.print`/`.print(` (widget helper methods) and non-project directories: **52 real console `print()` calls** in the shipped game code (`main.lua`, `controllers/`, `services/`, `states/`, `views/RoomView.lua`), not 198. Of those 52, **all are event-driven** (boot-once, debug key toggles, save-error paths, room-editor actions) — **none were found inside a `draw()` or `update()` function**, so there is no per-frame console-print cost. This corrects the brief's framing that these "fire per sprite and per shader at boot": `services/SpriteLoader.lua:115-131` has exactly 4 prints total, all one-shot summaries (`"Scanning ..."`, `"Loaded N sprites"`), **not one per sprite** — verified by reading the full scan functions (`_scan`, `scanDirectory`), neither of which contains a `print` inside its per-file loop. `services/ShaderRegistry.lua:41-61` genuinely does print once per `loadFromFile`/`loadFromSource` call (1 line on success, 1-2 on failure) — with exactly 3 shaders loaded at boot (`main.lua:286-288`: `radial_glow`, `dirty`, `foil`), that's **3 prints**, not "per shader" in any troubling volume.

**Low, still real for web — every one of the 52 real `print()` calls does go to the browser console under love.js** (per the brief's environment note), but since none are per-frame the actual web-console cost is boot-time (~7 prints: `SpriteLoader` × 4, `ShaderRegistry` × 3, `main.lua` × 1) plus occasional debug/error prints — not a running performance concern, just console noise. Downgraded from the brief's implied "Critical/High, per-frame spam" framing to **Low** based on verification.

**Load-time**: `love.load()` (`main.lua:280-297`) does `Game.sprite_loader:loadAll()` (synchronous directory walk + `love.graphics.newImage` per file, `services/SpriteLoader.lua:57-107`) and 3 synchronous shader compiles (`ShaderRegistry.loadFromFile`) before the first `love.update`/`love.draw` — this blocks the first frame by however long asset decode + shader compile takes. No count of total sprite files was taken in this pass `(unverified — would confirm via love.filesystem directory count on assets/sprites)`. This is standard eager-load-at-boot; whether it's a problem depends on total asset volume, which was not measured here. No lazy-loading path exists for sprites (`SpriteLoader:getSprite` does call `self:loadAll()` if not yet loaded, `:154-156`, so a lazy path technically exists as a fallback, but `love.load` always eager-loads first in practice).

### Top 10 fixes by payoff

1. **`views/TablePanelStats.lua:995-1038` `drawEvReadout` — stop rebuilding the EV breakdown tooltip every frame per table.** Gate `buildEvBreakdownLines`/`tbl:debugStats` behind an actual hover check (only compute when the mouse is over this table's EV readout, same as every other hover-tooltip in the codebase), or cache the result per table and invalidate on ctx/stake change. Biggest single verified win — heavy math + table/closure churn × up to 32 tables × 60fps, used ~1/60th of the time it runs.
2. **`views/FeltLayout.compute` (`views/FeltLayout.lua:66-`) — cache per table, invalidate on `(felt_w, felt_h, n_opps, s)` change.** ~10+ table allocations + a closure, per table, per frame, for layout that's static between resizes/seat changes.
3. **`views/RoomView.lua:508-527` — stop sorting `render_list` every frame.** Cache the sorted list; invalidate only when `self.placed` or ownership changes (editor actions are rare and already have their own event hooks).
4. **`views/CatalogModal.lua:183-190` `clampText` — add the same width/font/string memoization `views/TablePanel.lua:445-464` already uses for opponent-name truncation.** The pattern to copy already exists in the same codebase.
5. **`views/IconText.lua:68-98` `walk()` — cache parsed `{token}` segments keyed on the source string** (e.g. a module-level weak table or a per-caller cache field) so repeated draws of the same catalog/floater string don't re-tokenize, and so `measure`+`draw` pairs share one parse instead of two.
6. **`views/TablePanel.lua:1434` and `views/TablePanelStats.lua:1019,1023` — pull the hardcoded anti-banked/loss-purple colors into `data/theme.lua`/`Theme.lua` tokens.** Fixes both the per-frame table-literal allocation and the architecture rule-3 violation (literal colors outside Theme) in one move.
7. **`controllers/GrindController.lua:178-223` — collapse the 5 separate per-frame `ipairs(self.pool.tables)` passes into 1-2 passes**, and skip `prev_states`/sound-transition tracking entirely on frames where `TablePool:update` reports zero resolutions AND no table's `.state` changed (cheap to detect if `TablePool:update` also returns a "did anything change" flag). Lower payoff than 1-3 individually but free-standing and easy.
8. **Chip rendering (`views/Chips.lua:70-100`) — pre-render one stamped texture per (denomination × tint) combination once, then draw chips as textured quads through a `SpriteBatch`.** Currently every chip is 2 `love.graphics.circle` calls + 2 `Theme.setColor` calls + a fresh `dark`/`c` tint table, with no batching, and chip piles are the single highest-count repeated visual element in the game (up to 6 per column × multiple columns × multiple piles per table × up to 32 tables). Bigger lift than the others but the largest headroom for the web build specifically, where per-primitive draw-call overhead matters more than on desktop GL.
9. **`main.lua:362-363` — skip the shader `:send` (or send flat values instead of table literals) when `s`/`BASE_W`/`BASE_H` haven't changed since last frame.** Smallest fix on this list, but it is the one allocation that fires unconditionally on literally every frame regardless of game state — free to fix, zero risk.
10. **Downgrade the "198 print() calls / per-sprite boot spam" item off any priority list.** Verified: real console `print()` count is 52, none per-frame, boot spam is ~7 lines. Time is better spent on items 1-9 than on trimming already-harmless debug prints; if anything, only worth touching if a future contributor adds a `print()` inside a hot loop by mistake — the existing 52 are not a problem.

---

## Dead code, unreferenced assets, and duplication

### 1. Debug/dev-only code reachable in the shipped build

**CRITICAL — confirmed, not speculative.** In the current committed state of `data/constants.lua`, developer hotkeys that wipe the save, grant free bankroll, and cheat-unlock content are wired live and reachable by keypress with no other gate.

**The flag chain:**

`data/constants.lua:19` —
```lua
C.PROTOTYPE_MODE = false
```
`data/constants.lua:38-40` —
```lua
    -- Wire the developer hotkeys (F2/F6/F7/backtick/-/=, H/J in grind,
    -- R/[/]/D in shove). Off in shipping builds.
    DEV_HOTKEYS       = not C.PROTOTYPE_MODE,
```
`not false = true` → `Constants.FEATURES.DEV_HOTKEYS` evaluates to `true` right now.

`main.lua:257-275` gates the wiring on exactly this flag:
```lua
    g.input_dispatcher = InputDispatcher:new()
    g.input_controller = InputController:new(g)
    if not Constants.FEATURES.DEV_HOTKEYS then
        -- All DEV hotkeys (F2/F6/F7/backtick/-/=) are skipped ...
        ...
    else
        g.input_controller:wire()
    end
```
Because `DEV_HOTKEYS` is `true`, the `else` branch runs and `InputController:wire()` registers every dev hotkey on the global dispatcher, active in every state.

**Exact key bindings live right now (`controllers/InputController.lua`):**

| Key | Effect | Lines |
|---|---|---|
| `F6` | `state:wipeAll()` then reload from last autosave; force-switches to grind | `InputController.lua:52-66` |
| `F7` | `game.save_service:clearAll()` + `state:wipeAll()` — **deletes both save slots, resets to a fresh game**, no confirmation | `InputController.lua:68-77` |
| `` ` `` (backtick) | Toggles a per-table debug overlay showing exact win_chance/win_dist/loss_dist/EV | `InputController.lua:85-90` |
| `F3` | Cycles the EV-tooltip payout-breakdown display shape | `InputController.lua:96-105` |
| `-` | `state.bankroll = math.max(0, state.bankroll - 1000)` | `InputController.lua:112-118` |
| `=` | `state.bankroll = state.bankroll + 1000` — **free money, no limit on repeats** | `InputController.lua:119-125` |
| `F2` | Force-switches between grind ↔ shove states directly | `InputController.lua:27-32` |

Quoted evidence for the money cheat:
```lua
    dispatcher:on("keypressed",
        function(key) return key == "=" end,
        function()
            local state = game.state
            state.bankroll = state.bankroll + 1000
            print(string.format("[debug] bankroll +$1000 -> $%.2f", state.bankroll))
        end)
```

**Secondary hotkeys gated on the same (currently-true) flag, checked per-state:**

- `states/GrindState.lua:376-386` — `H` deals 1 hand instantly (bypasses the DEAL button), `J` deals every table instantly, `Y` toggles `game.state.cleared` (the gauntlet-clear / decks-unlocked flag) with no confirmation:
```lua
    if not Constants.FEATURES.DEV_HOTKEYS then return end
    if key == "h" then
        self.controller:dealHand(1)
    elseif key == "j" then
        self.controller:dealAll()
    elseif key == "y" then
        self.game.state.cleared = not self.game.state.cleared
        print("[debug] Toggled gauntlet clear state (decks unlocked = " .. tostring(self.game.state.cleared) .. ")")
    end
```
- `states/ShoveState.lua:401-429` — `SPACE` force-starts a new gauntlet outside the normal flow, `R` resets gauntlet/session stats, `[`/`]` **live-nudge the win-probability base rate** (`ShoveRate.computeFromBase`) up or down 5% at a time with no cap on repeated presses, `D` toggles `views/ShoveDebugOverlay.lua` (win-rate math HUD).

**Independent, unrelated finding — worse, because it has NO flag gate at all:** `states/RoomState.lua:123-153`, key `U`:
```lua
    if key == "u" then
        local Catalog = require("data.catalog")
        local state = self.game.state
        ...
        if any_unowned then
            for _, item in ipairs(Catalog) do
                if not owned_set[item.id] then
                    owned[#owned + 1] = item.id
                end
            end
            state.owned_items = owned
            state.cleared = true
            print("[debug] Unlocked all catalog items and decks for room testing")
```
This branch has **no `Constants.FEATURES.DEV_HOTKEYS` check whatsoever** — pressing `U` while in the Room screen unconditionally unlocks every catalog item and every deck, in every build configuration, regardless of `PROTOTYPE_MODE`. And `RoomState` is not some hidden dev-only screen: it is reached by clicking the always-visible "Room" button in the top bar of the normal grind UI —
```lua
    -- views/GrindView.lua:2227-2233
    local room_rect = self:_roomButtonRect()
    if x >= room_rect.x and x < room_rect.x + room_rect.w
       and y >= room_rect.y and y < room_rect.y + room_rect.h then
        ClickFlash.flash("room_btn", "room_btn")
        if self.game.toggleRoom then self.game.toggleRoom() end
        return
    end
```
Any player can click Room, press `U`, and own the entire catalog for free. No hotkey, no console — pure keyboard input in the shipped UI flow.

**Bottom line — answering the brief's question directly:** yes, as the source currently sits, a player of a build compiled from this exact commit can press `F7` in any state to instantly wipe their save, press `=` repeatedly for unlimited free bankroll, and press `U` in the Room screen (unconditionally, no flag) to unlock the entire catalog. `data/constants.lua:16-18` even documents the danger and the fragility of the safeguard:
```lua
-- itch/web builds ship whatever is committed here — build_web.py is a
-- pure packager, it rewrites nothing. Set back to true before building
-- for itch.
C.PROTOTYPE_MODE = false
```
There is no CI check, no build-time assertion, and no test that fails if `PROTOTYPE_MODE` is left `false` (or if `RoomState`'s `U` handler — which isn't even wired to the flag — ships as-is). The entire shipped-safety property depends on a human remembering to flip one boolean before every itch build, and one code path (`RoomState` `U`) bypasses the flag mechanism entirely regardless of what that boolean is set to.

### 2. Unreferenced public functions

Method: extracted every `function Name.foo(`/`function Name:foo(` definition (730 total across 145 files), built a whole-repo token-frequency table of `.foo`/`:foo` call-site occurrences and a separate whole-repo frequency table of quoted-string literals (to rule out data-driven dispatch by name, e.g. `data/sounds.lua`/`animations.lua`/`effects.lua` handler-name strings), then kept only definitions whose call-site count is exactly 1 (the definition itself) **and** whose quoted-string count is 0 (rules out string-keyed registry dispatch). Lifecycle/interface methods dispatched generically by the engine (`new`, `draw`, `update`, `enter`, `exit`, `keypressed`, `mouse*`, `wheelmoved`, `textinput`, `resize`, `load`, `wire`) were excluded from the sweep since they're called polymorphically through `StateMachine`/`Panel`/widget interfaces, not by name.

Two files already established as **wholly dead** (zero requires) — `services/Confetti.lua` and `views/widgets/Dropdown.lua` — are cited here only where a specific method inside them also shows in this sweep; their dead-ness is a file-level fact, not re-derived per function.

**High/Medium — real functions in live files with zero call sites and zero string references:**

| Severity | Function | Location | Evidence |
|---|---|---|---|
| High | `GrindController:changeTableStake` | `controllers/GrindController.lua:1271` | Full stake-up flow (gating, refund/cost math, `Table:setStake`, flourish sound) with no caller anywhere. `Table:setStake` itself IS called, but only via `TablePool:changeStake` (`models/TablePool.lua:167`) — the controller-level wrapper that would let a view trigger a stake change is orphaned. Looks like a shipped-then-unwired "stake up" UI affordance. |
| High | `EventBus:subscribe`, `EventBus:publish`, `EventBus:addTap`, `EventBus:removeTap` | `core/event_bus.lua:15,22,36,41` | `main.lua:14,158` requires the module and stores it as `g.event_bus`, but grep of the entire codebase turns up zero calls to any of its four methods anywhere else. The whole pub/sub service is wired into the DI container and never used — dead infrastructure carried into every future lift of `core/`. |
| Medium | `ShoveRate._formatMoney` | `models/shove_rate.lua:221` | Private-by-convention (`_` prefix) helper, zero call sites even inside its own file's other functions. |
| Medium | `RNG.weightedPick` | `utils/rng.lua:10` | Zero callers; `utils/rng.lua`'s other helpers (e.g. `intInRange` — also dead, see below) are exercised elsewhere; this one isn't. |
| Medium | `RNG.intInRange` | `utils/rng.lua:25` | Same file, also zero callers. |
| Medium | `BandStack.threeUp` | `services/BandStack.lua:95` | `BandStack.allocate` is the one actually used (`views/FeltLayout.lua:167`); `threeUp` is an alternate entry point nothing calls. |
| Medium | `Decal.unit` | `services/Decal.lua:73` | `Decal.lerp` / `Decal.place` are used extensively in `views/CatalogModal.lua`; `.unit` isn't called anywhere. |
| Medium | `HoverService.clearNamespace` | `services/HoverService.lua:38` | `HoverService.clear/.set/.is` are used throughout `views/`; the namespace-scoped clear variant has no caller (global `.clear()` is used instead, e.g. `main.lua:304`, `states/GrindState.lua:244,249`). |
| Medium | `ShaderRegistry.loadFromSource` | `services/ShaderRegistry.lua:56` | Boot only calls `.loadFromFile` three times (`main.lua:286-288`); `.loadFromSource` (load from an in-memory string rather than a file) has no caller. |
| Medium | `SoundService.stopAll` | `services/SoundService.lua:179` | `.playNamed`/`.setMasterVolume`/`.getMasterVolume` are all live; `.stopAll` isn't called from anywhere. |
| Medium | `SoundService.getKinds` | `services/SoundService.lua:91` | Same file, zero callers. |
| Low | `Chips.stackFootprint` | `views/Chips.lua:163` | Zero call sites. |
| Low | `ChipFlight.explodeAmount` | `views/ChipFlight.lua:639` | Zero call sites. |
| Low | `Panel:getActiveTab` | `views/Panel.lua:112` | Panel's other tab machinery is driven internally; this accessor has no external reader. |
| Low | `Theme.cycle` | `views/Theme.lua:42` | Zero callers; theme switching elsewhere goes through `Theme.setActive`, not `.cycle`. |
| Low | `Modal:boxRect` | `views/widgets/Modal.lua:169` | One-line accessor (`return self._box`), zero callers. |
| Low | `Row.drawSection` | `views/widgets/Row.lua:129` | Zero call sites; `Row`'s other draw helper (`drawSplit`) is equally unreferenced — see next row — suggesting the whole `Row` widget may be unused. Worth a manual check of whether `views/widgets/Row.lua` is required anywhere at all. |
| Low | `Row.drawSplit` | `views/widgets/Row.lua:74` | Zero call sites (see above). |
| Nit | `Format.percent` | `utils/format.lua:43` | Zero call sites — notable given section 5 below finds several places that format percentages inline instead of through `utils/format.lua`; this is the unused authority function for the pattern those call sites should be using. |

**Already confirmed by a parallel audit pass (cited, not re-derived):** `services/AutoSerializer.serialize` — only `.apply` is called anywhere; `.serialize` itself has no caller.

**Dropdown/Confetti-scoped items** (subsumed under the whole-file dead verdict already established, listed for completeness only): `Dropdown:wasOpen` (`views/widgets/Dropdown.lua:171`), `Dropdown:drawHeader` (:186), `Dropdown:drawPopup` (:215), `Dropdown:setItems` (:45), `Confetti.burst` (`services/Confetti.lua:64`) — every method in these two files is dead because the files themselves are never required.

**Caveat on method-style false negatives:** this sweep matches `.name(`/`:name(` call sites textually; a function invoked only through a variable holding a method reference (e.g. `local fn = obj.someMethod; fn(obj)`) would false-positive as dead. No such pattern was found via a secondary check (`grep -n '= \w\+\.\w\+$'` across `views/`, `services/`, `controllers/`, `models/`) but it isn't exhaustively ruled out for every candidate above.

### 3. Dead data entries (and the reverse: missing data)

Method: extracted the id/key vocabulary from each registry-style `data/` file, cross-referenced against every literal-string call site across the whole tree (accounting for dynamic string construction, e.g. `"pot_won_" .. tier`, before declaring anything dead), and separately checked every runtime data lookup (`Lookups.findById`, table-by-id indexing) whose key is a literal for existence in the target data table.

**Confirmed dead data entries (defined, never triggered):**

| Severity | Entry | File:line | Evidence |
|---|---|---|---|
| Low | `card_snap` sound preset | `data/sounds.lua:87` | Defined (`card_snap = { files = CARD_GIVE, volume = 0.18 }`) with a comment claiming it "fires once per individual card-deal animation," but zero code anywhere calls `playNamed("card_snap")` or constructs that string dynamically — checked all `playNamed(` call sites and all `data/animations.lua` sound-linkage. The comment describes intent that was never wired up. |
| Medium | `card_flip` animation preset | `data/animations.lua:26-29` | Only appears in its own doc comment and in `services/AnimationSystem.lua:20`'s doc-comment example (`self.game.animations:create("card_flip", ...)`) — that exact call form does not exist anywhere in real code. The one real `:create()` call site (`views/ShoveView.lua:288`) is driven by `startAnim()`'s `preset` argument, whose actual literal values are `card_deal_slide`, `cheat_card_dealt`, `hole_card_flip` only. |
| Medium | `card_bounce_in` animation preset | `data/animations.lua:31-35` | Zero references outside its own definition. |
| Medium | `pot_pulse` animation preset | `data/animations.lua` | Zero references outside its own definition. |
| Medium | `shove_fade_in` animation preset | `data/animations.lua:37-42` | Zero references outside its own definition. |
| Medium | `shove_fade_out` animation preset | `data/animations.lua:44-49` | Zero references outside its own definition. |
| Low | `hands_per_min_add` effect kind | `data/effects.lua`, registered `models/poker_effects.lua:39-41` | Self-documented as dead in its own comment: *"Held over from earlier design; nothing currently consumes this — pace is governed by game_type.pace_mult."* Confirmed: no `catalog.lua`/`run_upgrades.lua` entry emits `kind = "hands_per_min_add"`. The registry handler (`ctx.hands_per_min = (ctx.hands_per_min or 0) + e.value`) is unreachable code kept alive only by the registration call. |
| Low | `rep_decay_slow` effect kind | `data/effects.lua:240`, registered `models/poker_effects.lua:49-51` | Comment tags it `(Held over.)`. No catalog item or run upgrade emits this kind — confirmed zero emission sites. Handler is unreachable. |

Net: of the 8 animation presets in `data/animations.lua`, **5 of 8 (62%) are dead** — only `card_deal_slide`, `cheat_card_dealt`, `hole_card_flip` are ever instantiated. Of the 57 effect kinds registered in `models/poker_effects.lua` (all 57 are correctly registered — no orphaned/crash-risk kinds found there), 2 are unreachable dead code paths.

**Reverse direction — code references checked against data existence (the higher-value crash-risk direction):**

All of the following were checked and are **clean** (no latent crash found):
- Every literal game-type id used in code (`"six_max"`, `"hu"`, `"zoom"`, `"mtt"` — in `controllers/GrindController.lua`, `data/catalog.lua`, `models/Table.lua`, `models/Table_legacy.lua`, `models/TablePool.lua`, `models/catalog_unlock_rules.lua`, `models/deck_xp_rules.lua`, `views/GrindView.lua`, `views/TablePanel.lua`) exists in `data/game_types.lua`.
- Every literal deck id used in code (`"standard"` in `views/DeckSelectModal.lua:547`, `"cursor"` in `data/run_upgrades.lua:143`) exists in `data/decks.lua`.
- The hardcoded starting stake `"s001"` (`models/GameState.lua:128,204`, `data/hints.lua:124,140`) exists in `data/stakes.lua:53`.
- Every `requires = "<id>"` prerequisite gate in `data/catalog.lua` (`cursor_pool` ×3, `plastic_trophy`) resolves to a real catalog item id.
- Every item id listed inside a `data/catalog_pages.lua` department's `items = {...}` array resolves to a real `data/catalog.lua` id — none would silently vanish from the order-book via a typo.
- `SoundService.playNamed(...)` calls that pass a variable rather than a literal (`GrindController.lua:1765` via `key = (t.outcome_won and "pot_won_" or "pot_lost_") .. tier`, `FlightSystem.lua:301` via `s.name`, `ShoveView.lua:462` via `ev.sound`, `GrindController.lua:577` via `pulse_sound`) were traced back to their string sources and all resolve to entries that do exist in `data/sounds.lua` (`pot_won_small/medium/large/jackpot`, `pot_lost_small/medium/large/jackpot`, `border_pulse_win/loss`, `chip_land_you/pot/bankroll`, `gauntlet_won/lost`, `runout_won`, `cheat_card_dealt`) — these are **not** dead despite a naive literal-string grep making them look unreferenced.

**One confirmed gap (not a crash, but a silent content hole) — Medium:**
`data/stake_themes.lua` only defines theme entries for stakes `s001`-`s006`. `data/stakes.lua` defines eleven stake ids total (`s00N, s001..s010`). Every read site does `StakeThemes[tbl.stake_id]` and guards with `stake_theme and stake_theme.field` (`controllers/GrindController.lua:1581,1674`; `views/TablePanel.lua:251,599,685,967,1396,1449`; `views/PokerEventAnims.lua:237`), so this degrades gracefully to `Theme.bg.chrome`/no tint rather than crashing — but it means **5 of 11 stake tiers (`s007`-`s010`, `s00N`) never get the per-stake chip-tint/header-chrome treatment** that's a designed, documented visual feature (`views/TablePanel.lua:249-250`: *"Per-stake header chrome: T1 dim grey, T6 near-black with a gold accent."*) for the lower/mid tiers. Looks like `stake_themes.lua` was authored for the original six tiers and never extended when higher stakes (`s007`-`s010`) were added.

### 4. Unused assets

Repo has 1245 asset files under `assets/` + `shaders/` (1155 PNG, 54 WAV, 8 MP3, 4 GIF, 3 FRAG, 1 TTF, 1 JSON-adjacent). Full inventory walked; every extension bucket checked.

**Important negative finding first, to prevent a false "1000+ dead files" conclusion:** the ~1150 PNGs under `assets/sprites/isometric/` are **not** individually referenced by name anywhere in `.lua` source, but they are **not dead** — `services/SpriteLoader.lua`'s `_scan("")` walk (from `SPRITE_DIR = "assets/sprites"`) loads every file in the tree into `self.sprites` keyed by relative path, and `views/RoomView.lua:139-160` auto-enumerates every loaded sprite whose name starts with `"isometric/"` into the Room Editor's browsable furniture/decor palette, grouped by top-level folder. Every isometric sprite is reachable in-game through that browser even though no source file names it literally. A naive unreferenced-filename grep would have wrongly flagged this entire library as dead; it isn't.

**Confirmed dead/unreachable assets:**

| Severity | Asset(s) | Size | Why dead |
|---|---|---|---|
| Medium | `assets/sprites/cards/backs/01-robot.gif`, `02-castle.gif`, `04-hand.gif`, `07-beach.gif` | 12103 + 5177 + 11795 + 12871 = **41,946 bytes (~41 KB)** | `services/SpriteLoader.lua:34` — `SUPPORTED_EXTS = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }` has no `gif` entry, and the file's own header comment says why: *"LÖVE's image decoders. .gif is NOT supported — newImage() can't decode it (animated or static)."* These 4 files are never even loaded into the sprite atlas, let alone drawn. `data/constants.lua:149` already documents this for one of them (`"02-castle is .gif which LÖVE can't decode"`) but the other 3 (`01-robot`, `04-hand`, `07-beach`) aren't called out anywhere and are equally dead weight. |
| Medium | `assets/audio/uVegas.../Cards/Shuffle/Overhand/overhand_0{1-5}.wav` | 284456+231962+141668+58632+108650 = **825,368 bytes (~806 KB)** | `data/sounds.lua:19-27` builds sample sets via `expand()` for `CARD_GIVE`, `CARD_RIFFLE` (Riffle only), `CHIP_1ON1`..`CHIP_3ON2`, `CHIP_DROP_2..4`, `COINS` — there is no `CARD_OVERHAND`/`expand(... "Cards/Shuffle/Overhand/overhand_", 5)` call anywhere. The whole `Overhand/` subfolder from the purchased sample pack is unused. |
| Medium | `assets/audio/uVegas.../Chips/5on3/5on3_0{1-5}.wav` | 19244×5 = **96,220 bytes (~94 KB)** | Same pattern — `Chips/1on1`, `2on1`, `3on2` are all `expand()`-ed into named sound presets; `Chips/5on3` has no corresponding `expand()` call and no other reference. |
| Low | `assets/audio/flip_card.mp3`, `impact_heavy.mp3`, `positive_ding.mp3`, `shuffle.mp3`, `whoosh.mp3` | 8821+13836+8821+17180+8821 = **57,479 bytes (~56 KB)** | `data/sounds.lua`'s header comment says *"The legacy fanfare / game-over MP3s are kept where the pack has no equivalent"* and only 3 of the 8 top-level MP3s are actually referenced (`victory_fanfare.mp3` at `sounds.lua:42`, `game_over.mp3` at `:43`, `negative_buzz.mp3` at `:62`). The other 5 are pre-uVegas-pack legacy sound effects with zero references left in `data/sounds.lua` or anywhere else. |

**Total confirmed removable asset bloat: ~1.0 MB** (41 KB GIF + 900 KB unused WAV sample subfolders + 56 KB unused legacy MP3s) — relevant for web-build download size specifically since `build_web.py` (per `data/constants.lua` comment) packages whatever's on disk verbatim.

**Dead code adjunct (not an asset, but directly related — belongs here rather than section 7):** `services/SpriteLoader.lua:118-127` has a second directory scan:
```lua
    -- Scan assets/isometric
    local iso_dir = "assets/isometric"
    print("[SpriteLoader] Scanning " .. iso_dir)
    if love.filesystem.getInfo(iso_dir) then
        local iso_count = self:scanDirectory(iso_dir, "isometric/")
        ...
```
`assets/isometric` does not exist on disk — the real path is `assets/sprites/isometric`, already covered by the primary `_scan("")` walk two lines above. The `getInfo(iso_dir)` guard makes this harmless (always evaluates false, block never executes its body), but it is 100% dead code: a leftover from before the isometric folder was nested under `assets/sprites/`, printing a "Scanning assets/isometric" log line that never proceeds to load anything.

**Code references to asset paths that don't exist on disk:** none found among direct string-literal `"assets/..."` references (9 total checked). The only misses were directory-prefix strings (`assets/isometric`, `assets/sprites/` — see above) and `assets/sprites/aliases.json`, which is explicitly optional and guarded with `love.filesystem.getInfo(ALIASES_FILE)` before use (`services/SpriteLoader.lua:132`) — not a bug. Spot-checked dynamically-built sprite paths (`Card.lua`'s `"cards/fronts/" .. suit .. "/" .. rank`, all 8 `decks.lua` `sprite = "cards/backs/..."` fields, `views/TablePanel.lua:118`'s fallback back sprite) against the actual files in `assets/sprites/cards/` — every one resolves to a real, loadable (non-GIF) file. `data/room_layout.lua`'s `__meta.floor_theme = "Default"` / `wall_theme = "Default"` are confirmed intentional sentinels for "no theme selected" (`views/RoomView.lua:190-199`, `:1356-1357`), not broken references to a nonexistent `Floor_64_Default.png` — no such file is ever looked up because the sentinel never matches a real theme name and the code path degrades to the graybox fallback.

### 5. Duplication

**Bronze/Silver/Gold border-colour table — triplicated verbatim, byte-for-byte identical:**

| Location | Code |
|---|---|
| `views/GrindView.lua:1226-1230` | ```lua\n        local border_colors = {\n            [2] = { 0.72, 0.45, 0.20, 1.0 }, -- Bronze\n            [3] = { 0.80, 0.80, 0.85, 1.0 }, -- Silver\n            [4] = { 0.98, 0.82, 0.12, 1.0 }, -- Gold\n        }\n``` |
| `views/DeckSelectModal.lua:193-197` | identical literal table |
| `views/DeckSelectModal.lua:383-387` | identical literal table, third copy in the same file |

All three are also a **rule-3 violation** (literal colors outside `data/theme.lua`/`views/Theme.lua`) since they're raw RGBA literals, not `Theme.setColor(token)` calls. Home: a `Theme.deckLevelBorderColor(level)` accessor (or `deck_level_border` token group in `data/theme.lua`), called from all three sites.

**Formatting — `utils/format.lua` is NOT the single authority; it's actively bypassed.** Section 2 already found `Format.percent` has zero call sites anywhere. Concretely, every percent readout in the UI formats inline instead:

| File:line | Inline formatting |
|---|---|
| `models/shove_rate.lua:205,211,214` | `string.format("Catalog base: %.1f%%", ...)` etc. — 3 sites in one function |
| `states/ShoveState.lua:144` | `string.format("...%.1f%%, expected %.1f%%)", ...)` |
| `views/CatalogModal.lua:665` | `string.format("+%d%% shove", ...)` |
| `views/GrindView.lua:599,1070,1071,1383,1965` | 5 separate inline `%%` formats |
| `views/SettingsModal.lua:238` | `string.format("%d%%", vol_pct)` |
| `views/ShoveDebugOverlay.lua:81,108,117,167` | 4 separate inline `%%` formats |
| `views/ShoveView.lua:609,611,774,776` | 4 separate inline `%%` formats |
| `views/TablePanelStats.lua:78-79,949,968` | 4 separate inline `%%` formats |
| `sim/run.lua:82` | inline (sim/ is out of scope per brief but shows the pattern is repo-wide) |

24 inline percent-format call sites across 10 files, and zero call sites for the function that exists to do exactly this. Every one differs slightly in decimal-place choice (`%.0f`, `%.1f`, `%.2f`) with no shared policy — `Format.percent(frac, decimals)` already supports a decimals argument and would collapse all of them to one call style.

Money formatting is more consistent (`Format.money`/`Format.moneyExact` are both actually used) but not universally: `views/GrindView.lua:804` (`string.format("$%.2f", next_cost or 0)`) and `views/TablePanelStats.lua:55-57` reimplement a **third, different** money-precision policy:
```lua
    if math.abs(n) >= 100 then return string.format("$%.0f",  n) end
    if math.abs(n) >= 10  then return string.format("$%.1f",  n) end
    return string.format("$%.2f", n)
```
This is a bespoke tiered-precision formatter that duplicates the *intent* of `Format.moneyExact` (which has its own, different threshold at $1000/2-decimals-below) but with different thresholds and different behavior — two "precise money" policies live side by side with no indication which one a new call site should use.

**Modal scaffolding — `views/CatalogModal.lua` reimplements the shared widget instead of using it.** Of the 7 top-level modal views, `AnalyticsConsentModal`, `OnboardingModal`, `PrestigeModal`, `PrototypeEndModal` build on `views/widgets/ActionModal.lua`, and `DeckSelectModal`/`SettingsModal` build on `views/widgets/Modal.lua`. `views/CatalogModal.lua` requires neither — it hand-draws its own dim backdrop:
```lua
-- views/CatalogModal.lua:1118-1119
    -- Dim backdrop only — no hard frame to morph.
    love.graphics.setColor(0, 0, 0, 0.55)
```
versus `views/widgets/Modal.lua:92-93`'s themed equivalent:
```lua
    -- Backdrop dim.
    Theme.setColor(Theme.debug.hud_bg)
```
This is both a duplication (CatalogModal re-derives backdrop/frame logic `Modal.lua` already owns) and a rule-3 literal-color violation (`0, 0, 0, 0.55` bypasses `Theme.setColor`). Given `CatalogModal` is presented as a physical "order-book" with its own page-turn choreography, a full `Modal:new()` swap may not fit — but the backdrop dim alone should go through `Theme.debug.hud_bg` like every other modal.

**Point-in-rect hit-testing — reimplemented at least 4 separate times as named helpers, plus 54 raw inline occurrences of the same 4-comparison test:**

| Helper | Location |
|---|---|
| `CR.hitTest` | `views/ComponentRenderer.lua:523` |
| `HintLogPanel:containsPoint` | `views/HintLogPanel.lua:206-210` |
| `Scrollbar.containsPoint` / `.containsThumb` | `views/Scrollbar.lua:40-52` |
| `Modal:hitTest` | `views/widgets/Modal.lua:158-164` |

All four independently express the identical test:
```lua
x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
```
54 further call sites across the view layer inline this same 4-comparison expression directly rather than calling any of the above. None of `core/`, `lib/`, or `utils/` owns a canonical `pointInRect(x, y, rect)` (or `Rect.contains`) that any of these five+ implementations could delegate to — this is exactly the kind of primitive rule 4 (engine-agnostic) wants centralized in `utils/`, since every future idle game will need the same hit test. Proposed home: `utils/geometry.lua` (new file) with `pointInRect(px, py, x, y, w, h)`, then `Modal:hitTest`, `Scrollbar.containsPoint`, `HintLogPanel:containsPoint`, and `CR.hitTest` all reduce to one-line wrappers, and the 54 inline sites can migrate opportunistically.

**Scrollbar/list logic — `views/HintLogPanel.lua` hand-rolls scroll clamping that `views/Scrollbar.lua` already provides as a shared function.** `Scrollbar.clamp(scroll_y, track_h, content_h)` exists (`views/Scrollbar.lua:73`) and is the correct call for exactly this, but `HintLogPanel.lua:122-124` does it manually instead:
```lua
    local max_scroll = math.max(0, list_h - view_h)
    if self.scroll > max_scroll then self.scroll = max_scroll end
    if self.scroll < 0 then self.scroll = 0 end
```
`HintLogPanel` also computes its own scrollbar-thumb fraction inline at `:193` (`* (self.scroll / max_scroll)`) rather than calling `Scrollbar.thumbBounds`. Only `views/Panel.lua` and `views/widgets/ActionModal.lua` actually `require("views.Scrollbar")` — every other scrollable view (`CatalogModal`, `HintLogPanel`, `OnboardingModal`, `RoomView`, `ComponentRenderer`, `GrindView`, `widgets/Dropdown`) either doesn't scroll or reimplements its own scroll math instead of pulling in the shared module.

### 6. Near-duplicate helpers across modules

No `utils/math.lua` (or equivalent) exists — `ls utils/` is only `format.lua`, `lookups.lua`, `rng.lua`, `sample_set.lua`. The generic numeric primitives every project needs (`clamp`, `lerp`, point-in-rect — already covered in section 5) are each reinvented locally instead of living in one engine-layer home, which directly works against rule 4 (engine-agnostic infrastructure liftable into the next idle game).

| Primitive | Independent definitions | Notes |
|---|---|---|
| `clamp` (general `[lo,hi]`) | `states/ShoveState.lua:42` `local function clamp(v, lo, hi)` | Textbook `if v<lo then lo elseif v>hi then hi else v` — the exact thing every project needs and none should hand-write twice. |
| `clamp01` (`[0,1]` specialization) | `models/shove_rate.lua:87` `local function clamp01(v)` | Same primitive, 0/1 hardcoded instead of parameterized. |
| `[0,1]` clamp, inlined ad hoc (no named helper at all) | `services/SoundService.lua:113,141,194`; `views/CatalogModal.lua:371`; `views/DeckSelectModal.lua:287`; `views/widgets/Slider.lua:34,42`; `views/widgets/Stamp.lua:47`; `views/Scrollbar.lua:60,70` and others — **21 occurrences total** of `math.max(0, math.min(1, ...))` or `math.max(0, math.min(max, ...))` across the tree | None of these call `clamp`/`clamp01` above — every one reconstructs the two-`math` call by hand. |
| `distClampAndNormalize(d)` | `models/outcome_math.lua:113-124` and `models/Table_legacy.lua:144-154` | **Byte-for-byte identical** 11-line function body in two different files (verified by direct diff). `models/outcome_math.lua` exposes it as `OutcomeMath.distClampAndNormalize`; `models/Table_legacy.lua`'s copy is a private `local function` with no shared home. This one is a known-shape duplication (Table.lua/Table_legacy.lua are an intentionally-frozen fork per project convention — mirroring per-hand math is an accepted cost documented elsewhere), but the clamp-and-normalize *math* itself has nothing poker-specific in it and could live in a shared pure-math helper both files pull from without touching the fork's intentional behavioral independence. |
| `lerpDist(naked, capped, t)` | `models/outcome_math.lua:189-197` and `models/Table_legacy.lua:198-206` | Also byte-for-byte identical (verified by direct diff) — same fork-duplication pattern as above. |
| point-in-rect (`x>=r.x and x<r.x+r.w and y>=r.y and y<r.y+r.h`) | `views/ComponentRenderer.lua:523` (`CR.hitTest`), `views/HintLogPanel.lua:206-210` (`:containsPoint`), `views/Scrollbar.lua:40-45` (`.containsPoint`), `views/widgets/Modal.lua:158-164` (`:hitTest`), plus 54 further raw inline occurrences | Covered in full in section 5; repeated here because it's the textbook "near-duplicate helper, different names" case the brief calls out — four different names (`hitTest`, `containsPoint`, `containsPoint`, `hitTest`) for the identical test. |
| `round` / `approach` | none found anywhere in the codebase | Neither primitive is defined at all (searched `function.*[Rr]ound\b` and `function.*[Aa]pproach\b` repo-wide, zero matches) — not a duplication finding, but notable: any rounding currently goes through ad hoc `math.floor(x + 0.5)` call sites instead of a named `round()`, and no easing/tween "approach" helper exists despite the animation-heavy UI (`services/AnimationSystem.lua`, `services/Tumble.lua`, `services/FlightSystem.lua` all do their own per-frame interpolation math). |

**Proposed single home:** a new `utils/mathx.lua` (name deliberately avoiding a collision with the built-in `math` global) exporting `clamp(v, lo, hi)`, `clamp01(v)`, `lerp(a, b, t)`, and `round(v)`; `utils/geometry.lua` (proposed in section 5) for `pointInRect`. Both belong in `utils/` per the existing convention (`utils/format.lua`, `utils/lookups.lua` are already stateless pure-function modules with no poker knowledge), keeping them liftable into the next idle game per rule 4.

### 7. Commented-out code blocks

Swept every `.lua` file for runs of consecutive comment lines shaped like code (assignment, `if`/`for`/`while`...`then`/`do`, `self:`/`self.` calls) rather than prose, then manually inspected every hit. Nearly all candidates turned out to be legitimate doc-comment API examples (`services/ShaderRegistry.lua:14-21`'s usage snippet, `services/HandAnalytics.lua`'s function-signature list, `data/catalog.lua`'s schema-shape comment, `data/animations.lua`'s preset schema, `views/ComponentRenderer.lua`'s API summary, `views/CatalogModal.lua:240-247` and `views/DeckSelectModal.lua:157-158`'s explanatory prose) — these are prose, not disabled code, and are correctly excluded.

**One genuine commented-out code block found, and it's load-bearing — it silently disabled a real feature branch and left a dead field behind:**

`services/FloatingTextSystem.lua:76-93`:
```lua
            if tbl then
            --     -- Table-attached: NO fade at all — stays fully opaque
            --     -- while it rises, then freezes at its final position.
            --     if tbl.state == "idle" and progress >= 1.0 then
            --         -- Freeze: clamp progress, hold timer alive.
            --         progress = 1.0
            --         t.timer = 0.001
            --         t.has_persisted = true
            --     end
            --     t.alpha = 1.0
            -- else
                -- Normal floater: hold-then-fade curve.
                if progress < ALPHA_HOLD then
                    t.alpha = 1
                else
                    t.alpha = (1 - progress) / (1 - ALPHA_HOLD)
                end
            end
```
The intended design (per the still-live comment text) was: a table-attached floating text should freeze fully opaque at its final position instead of fading, by setting `t.has_persisted = true`. That whole branch — including the `else` that would gate it — is commented out, so **every** floater (table-attached or not) now falls through to the "normal floater: hold-then-fade curve" path unconditionally, regardless of `tbl`.

This has a direct, verifiable knock-on effect (a genuine dead field, per section 8's remit): `t.has_persisted` is read at line 101 —
```lua
            -- Non-persisted texts expire normally when timer hits 0.
            if t.timer <= 0 and not t.has_persisted then
                table.remove(_texts, i)
            end
```
— but the *only* place in the entire codebase that ever assigns `t.has_persisted = true` is inside this commented-out block (line 85). Grep confirms zero live assignments anywhere else. `t.has_persisted` is therefore always `nil`/falsy at line 101, so the guard against removing "persisted" floaters can never fire — dead code reachable from a live read of a field nothing sets. Either the freeze-on-table feature needs to be restored (uncomment + wire `has_persisted` through), or the dead branch and the now-meaningless `not t.has_persisted` check at line 101 should be deleted together.


---

## Room / Catalog / Modal / Widget UI layer audit


### 6. Theme compliance

**[High] Duplicated Bronze/Silver/Gold border-color literal, 3 copies, one file diverges silently.**
The exact same `{r,g,b,a}` triplet is hand-typed three times:
- `views/GrindView.lua:1227-1229`
- `views/DeckSelectModal.lua:194-198` (deck tile grid)
- `views/DeckSelectModal.lua:384-388` (deck details-panel preview, a second local copy inside the same file)

```lua
local border_colors = {
    [2] = { 0.72, 0.45, 0.20, 1.0 }, -- Bronze
    [3] = { 0.80, 0.80, 0.85, 1.0 }, -- Silver
    [4] = { 0.98, 0.82, 0.12, 1.0 }, -- Gold
}
```
Cost: any palette/rebalance pass on these tiers has to remember to touch three sites in two files; DeckSelectModal already needed two internal copies because `drawTile` and `drawDetailsPanel` don't share a helper. A future edit to one copy and not the others silently desyncs the deck grid from its own details panel. Fix: add `Theme.tier.deck_bronze / deck_silver / deck_gold` (or a `Theme.tier.level_border[lvl]` table) to `data/theme.lua`, export via `views/Theme.lua`, and replace all three literal tables with a single `Theme.tier.level_border[level]` lookup shared by both DeckSelectModal draw functions and GrindView.

**[High] `views/CatalogModal.lua` runs a second, un-themed palette.**
`grep -c "0.15, 0.15, 0.12" views/CatalogModal.lua` → 38 hits; `grep -c "Theme.setColor({" ` → 37 (of the codebase's 43 total inline-literal `Theme.setColor` calls, i.e. 37 of 43 live in this one file). Every ink/border/paper color in the catalog book is a raw literal instead of a token — e.g.:
```lua
Theme.setColor({ 0.15, 0.15, 0.12, 0.10 })   -- CatalogModal.lua:511 (locked-card wash)
Theme.setColor({ 0.15, 0.15, 0.12, 0.30 })   -- CatalogModal.lua:516 (card border)
Theme.setColor({ 0.94, 0.90, 0.83 })         -- CatalogModal.lua:920 (leaf paper)
Theme.setColor({ 0.90, 0.85, 0.76 })         -- CatalogModal.lua:992 (cover paper)
```
This is a deliberate "vintage newsprint" sub-palette (ink `0.15,0.15,0.12`, paper `0.94,0.90,0.83`/`0.90,0.85,0.76`, red stamp `0.75,0.20,0.20`, purple corruption `0.55,0.25,0.85`/`0.40,0.15,0.60`) that never got promoted to `data/theme.lua`. Cost: this look cannot be reused by any other view without copy-pasting the same 15+ literals again, it cannot be reskinned by a palette swap (`Theme.cycle()` silently does nothing to the catalog), and it is the single largest violation of the project's "no literal colors outside data/theme.lua" rule (RULES.md audit grep `love.graphics.setColor(\s*\d\d*` / `Theme.setColor({...})` both fail here). Fix: add a `Theme.catalog` (or `Theme.paper`) token group — `ink`, `ink_faint`, `ink_dim`, `paper_leaf`, `paper_cover`, `stamp_red`, `stamp_purple`, `stamp_purple_dark`, `stamp_grey` — to `data/theme.lua`'s palette tables, and mechanically replace the 38 literal-table calls in this file.

**[Medium] Numeric (non-token) `love.graphics.setColor` calls — the codebase's audit grep explicitly forbids these.**
```
CatalogModal.lua:554   love.graphics.setColor(0.15, 0.15, 0.12, 0.55)   -- locked silhouette sprite tint
CatalogModal.lua:556   love.graphics.setColor(1, 1, 1, (is_owned and not is_corruptible and not is_corrupted) and 0.40 or 1.0)
CatalogModal.lua:561   love.graphics.setColor(0.15, 0.15, 0.12, 0.15)   -- placeholder blueprint cross
CatalogModal.lua:1119  love.graphics.setColor(0, 0, 0, 0.55)            -- book backdrop dim
RoomView.lua:410       love.graphics.setColor(1, 1, 1, 1)               -- wall sprite tint reset
RoomView.lua:482       love.graphics.setColor(1, 1, 1, 1)               -- floor sprite tint reset
RoomView.lua:574       love.graphics.setColor(1, 1, 1, 0.40)            -- unowned item fade
RoomView.lua:576       love.graphics.setColor(1, 1, 1, 1)               -- owned item full tint
RoomView.lua:645       love.graphics.setColor(1, 1, 1, 0.60)            -- editor preview ghost
```
`RULES.md`'s audit (`rg "love\.graphics\.setColor\(\s*\d" --type lua` → must be empty) fails on both files. These are all straightforward `Theme.assetTint(alpha)` (the 1,1,1 cases already have a dedicated helper for exactly this — see `views/Theme.lua:70-73`) or a new `Theme.debug.backdrop_dim` / `Theme.catalog.silhouette` token. Cost: identical to above — a palette swap or accessibility high-contrast mode cannot reach these draws at all.

**[Medium] Raw color literals scattered through `views/RoomView.lua`'s data path (not just draw calls).**
`RoomView.lua:94` default fallback `color = info.color or { 0.5, 0.5, 0.5 }`, `RoomView.lua:648` `local preview_c = { 0.92, 0.72, 0.32, 0.50 } -- translucent amber`, `RoomView.lua:1131` `color = active_spec.id == "poker_poster" and { 0.82, 0.42, 0.38 } or { 0.40, 0.55, 0.75 }`. These are dev-tool graybox colors (Room Editor placeholder cubes before real sprites exist), lower priority than the CatalogModal/DeckSelectModal findings above since the editor is not player-facing, but still fail the same grep and should move to `Theme.debug.roomEditor*` tokens if the editor is kept long-term.

**[Low] `data/room_layout.lua` stores raw RGB fallback colors as data (acceptable) but they duplicate the RoomView literals above.**
`data/room_layout.lua:22-30` — `color = { 0.82, 0.42, 0.38 }` etc. per item. This is fine as pure data (rule 3 allows data tables), but note `RoomView.lua:1131` hardcodes the SAME `poker_poster` red `{0.82, 0.42, 0.38}` a second time as a placement-time literal instead of reading it from `Layout.poker_poster.color` — a copy that can drift from the saved layout value.

### 2. Modal architecture

Eight modal-ish overlays: `views/CatalogModal.lua`, `views/DeckSelectModal.lua`, `views/SettingsModal.lua`, `views/OnboardingModal.lua`, `views/PrestigeModal.lua`, `views/PrototypeEndModal.lua`, `views/AnalyticsConsentModal.lua`, plus `views/widgets/ConfirmDialog.lua` (spawned nested inside SettingsModal). Base: `views/widgets/Modal.lua` (frame + backdrop + title, `:draw`/`:endDraw`/`:hitTest`/`:boxRect`). A second base, `views/widgets/ActionModal.lua`, wraps `Modal` and adds body-layout + button-row + scroll — 4 of the 8 (PrestigeModal, PrototypeEndModal, AnalyticsConsentModal, OnboardingModal) are thin wrappers over it and inherit backdrop/scroll/button-row for free.

**Who uses what:**
| Modal | Uses `Modal` | Uses `ActionModal` | Own backdrop+frame | Own scroll | Own escape handling |
|---|---|---|---|---|---|
| PrestigeModal | via ActionModal | yes | — | — | **missing** (see §3) |
| PrototypeEndModal | via ActionModal | yes | — | — | yes (`escape` in `keys`) |
| AnalyticsConsentModal | via ActionModal | yes | — | — | yes |
| OnboardingModal | via ActionModal | yes | — | — | no ESC by design (forced ack) |
| SettingsModal | direct `Modal:new` | no | — | (no scroll; fixed row count) | delegated to host state |
| DeckSelectModal | direct `Modal:new` | no | — | **none** (grid doesn't scroll; relies on shrinking `s` instead, see §7) | yes (`escape` in own consumeKey) |
| ConfirmDialog (nested widget, not a top-level modal) | **no** — reimplements backdrop+box+title by hand | no | **yes, duplicated** (`ConfirmDialog.lua:99-111` redraws dim rect + chrome box + border from scratch instead of calling `Modal:new/:draw`) | — | yes |
| CatalogModal | **no** — reimplements everything by hand | no | **yes, duplicated** (`CatalogModal.lua:1119-1120` draws its own `love.graphics.setColor(0,0,0,0.55); rectangle("fill",0,0,W,H)` instead of `Modal`'s backdrop; the "book" itself has no Modal frame at all — deliberately, per the file's header comment, to avoid a resizing chrome box) | own page-flip scroll via a spread-index + wheelmoved, not `Scrollbar.lua` | own `consumeKey`, and it's incomplete (see §3) |

**Duplicated across the 8:**
- **Backdrop dim**: `Modal:draw` (line 92-95) draws `Theme.debug.hud_bg` full-screen; `ConfirmDialog:draw` (line 102-103) draws its own `Theme.bg.window` @ 0.85 full-screen rect; `CatalogModal:draw` (line 1119) draws a third, un-themed `love.graphics.setColor(0,0,0,0.55)` full-screen rect. Three different dim implementations, three different opacities/tokens, for what is visually the same "something modal is open" cue.
- **Chrome box + title header**: `Modal:draw` does this once, generically. `ConfirmDialog:draw` (lines 108-115) reimplements `rectangle("fill", chrome) + rectangle("line", border) + printf(title)` by hand instead of taking a `Modal` instance — the exact same 8 lines `Modal.lua` already has, with different literal padding constants (`TITLE_TOP_BASE=28` vs `Modal`'s `DEFAULT_TITLE_PAD=14`).
- **Close/Continue button**: LabelButton is used consistently (good), but hit-rect bookkeeping is reimplemented per-modal: `self._continue_rect` (CatalogModal, DeckSelectModal — different field, same pattern), `self._cancel_rect`/`self._confirm_rect` (ConfirmDialog), `self._rects[]` (ActionModal). Four separate ad hoc "remember this frame's button rect for next frame's hit-test" schemes doing the same job.
- **Escape handling**: no shared convention — see §3 for the concrete bug this produces (ActionModal has no default ESC-cancels behavior; each `keys` table has to opt in per instance, and two do not).
- **In/out animation**: only CatalogModal animates (page-flip, `flip_t`/`drawFlipped`); every other modal pops in/out with no transition at all. Not wired through `Modal` at all — a per-file bespoke system.
- **Scroll**: `Scrollbar.lua` is the shared primitive and `ActionModal` correctly builds on it (`views/widgets/ActionModal.lua:211-236`). But `DeckSelectModal` has no scroll at all — instead it shrinks its own `s` (ui_scale) down via `max_s_height`/`max_s_width` clamps (`DeckSelectModal.lua:458-469`) so the whole modal always fits without ever needing a scrollbar. That's a third strategy ("shrink everything to fit") alongside "clip + Scrollbar" (ActionModal) and "no clamp, just cap `max_h_frac`" (bare `Modal`) for the same fundamental problem (content taller than viewport).

**Refactor recommendation:**
1. Move backdrop-dim into `Modal:draw` as the *only* place that draws it (already the case) and make `ConfirmDialog` and `CatalogModal` both take a `Modal` instance instead of hand-rolling `rectangle`+`setColor`. `ConfirmDialog` is the easy win — it doesn't even need a custom size the way `CatalogModal`'s page-flip layout does; it can become a 1:1 `Modal` consumer (drop `BOX_W/BOX_H`/etc, pass `w`/`h` into `Modal:new`).
2. `CatalogModal`'s "no hard frame" design is a real, stated requirement (avoid the resize-jump), so it's the one case that legitimately can't sit on `Modal`. Give it its own named helper (`views/widgets/BookFrame.lua` or similar) instead of inlining the backdrop draw, so the backdrop token at least comes from one place instead of a fourth hand-typed `{0,0,0,0.55}`.
3. Standardize the button-rect bookkeeping into `ActionModal`-style `self._rects[]`/`consumeMouse` for every modal that has a fixed button row (ConfirmDialog, DeckSelectModal's Continue, CatalogModal's Continue/close-✕) instead of four bespoke single-rect fields.
4. Give `ActionModal` (not each caller) a default `escape -> "cancel"`-style resolution when the caller's `keys` table omits `escape`, OR make the *host state* (ShoveState/GrindState) treat "modal open, key unconsumed" as "swallow, do nothing" instead of falling through to open Settings (see §3 — this is the actual live bug, not just an architecture nit).

### 3. Layering violations (views doing controller/model orchestration)

**[Critical] `SettingsModal:_performLoad` wipes live state unconditionally BEFORE confirming a save exists to restore — "Load save" can destroy progress and load nothing.**
`views/SettingsModal.lua:114-129`:
```lua
function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    g.state:wipeAll()
    local saved = g.save_service:loadAll() or {}
    g.state:applySaved(saved)
    ...
```
`SaveService:loadAll()` (`services/SaveService.lua:86-91`) always returns a table, but its two fields come from `:read()` (`services/SaveService.lua:51-66`), which returns `nil` on a missing file, a JSON decode failure, **or a save-version mismatch**. `GameState:applySaved` (`models/GameState.lua:309-315`) guards each field independently — `if saved.meta then ... end` / `if saved.run then ... end` — so a missing/corrupt/stale-version file for either slot means that slot's data is simply never restored. But `wipeAll()` (`models/GameState.lua:242-267`) has ALREADY reset `chips`, `owned_items`, `cleared`, `anti_chips`, `corrupted_items`, `peeled_items`, deck levels/XP, and `active_deck_id` to brand-new-game defaults by the time that guard is checked — unconditionally, with no prior check that a loadable save exists. Net effect: a player who clicks Settings → Load Save with no valid save on disk (fresh browser profile, cleared site data with an in-memory run in progress, or a save written by a prior incompatible version — the "version mismatch" path in `:read`) has their current run permanently discarded and replaced with nothing, not even a restored "last good" state. This is a live, no-confirmation-dialog data-loss button one misclick away, on a game explicitly required to preserve real player saves. Fix: read-and-validate first (`local saved = g.save_service:loadAll()`; check `saved.meta or saved.run` is non-nil, or check both are present per the intended contract), and only call `wipeAll()`/`applySaved()` once a usable payload is confirmed; otherwise show an error/toast and leave the live state untouched. This whole sequence belongs in a controller (`GrindController`/a new `SaveController`) that the modal calls into — not inlined in the view (see next finding).

**[High] `SettingsModal:_performLoad` is a view directly orchestrating cross-state teardown — walks `state_machine.states` and calls `:switch()` itself.**
`views/SettingsModal.lua:114-129` (full body, confirmed from the view side — matches the audit note):
```lua
function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    g.state:wipeAll()
    local saved = g.save_service:loadAll() or {}
    g.state:applySaved(saved)
    g.state.effects_cache = nil
    if g.state_machine and g.state_machine.states then
        for _, st in pairs(g.state_machine.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then
                st:fullReset()
            end
        end
        g.state_machine:switch("grind")
    end
end
```
This is model-mutation (`wipeAll`/`applySaved`/clearing `effects_cache`) *and* cross-state lifecycle orchestration (iterating every registered state and force-calling `fullReset`, then driving the state machine directly) living inside a `views/*.lua` file, in violation of rule 2 (views render; controllers route; states compose). The exact same sequence already exists as a named, reusable operation: `controllers/InputController.lua:44-50`'s local `fullResetAllStates()` plus the F6 debug-hotkey handler (`InputController.lua:52-66`) do the identical wipe → load → applySaved → fullReset-all → switch("grind") dance. Two independent, hand-copied implementations of "reload from disk" now exist — one in the engine-agnostic input layer (correct home), one duplicated inside a view (wrong layer, and it's the one a real player's mouse can trigger, not just a dev hotkey). Fix: extract the F6 handler's body into a `GameController`/`SaveController` method (e.g. `game.save_controller:reloadFromDisk()`) that both the F6 hotkey and `SettingsModal`'s Load-save row call; the view keeps only "the button was clicked" → controller call.

**[Medium] `DeckSelectModal:consumeMouse` writes to model state directly, inconsistent with the sibling CatalogModal's controller-routed purchase path.**
`views/DeckSelectModal.lua:106-113`:
```lua
for _, tile in ipairs(self._tiles) do
    if tile.unlocked
       and mx >= tile.x and mx < tile.x + tile.w
       and my >= tile.y and my < tile.y + tile.h then
        self.game.state:setActiveDeck(tile.id)
        return true
    end
end
```
`GameState:setActiveDeck` (`models/GameState.lua:702`) is a guarded model setter, so this isn't a raw internals-poke — it's not as severe as it could be. But it is inconsistent with the pattern the catalog uses one file over: `CatalogModal.lua:303-311`'s `tryBuy` goes `game.grind:buyCatalogItem(item.id)` first, with a documented fallback to the model only "if the grind controller isn't registered yet ... contrived test setups" — i.e. the *intended* path for a state-changing click is always through a controller, and DeckSelectModal skips that entirely, calling the model setter as its only path with no controller step at all. There is no `GrindController:setActiveDeck` for it to call. Cost: today this is low-risk (`setActiveDeck` looks self-contained), but it means deck-swap has no controller seam to hang side effects on later (sound cue, analytics event, effects-cache invalidation) the way every catalog purchase already does — the next feature added to "swap decks" (e.g. a confirmation toast, an analytics ping) has no natural home and will either get bolted onto the view (repeating this violation) or require inventing the controller method retroactively. Fix: add `GrindController:setActiveDeck(id)` (or a `DeckController`) mirroring `buyCatalogItem`'s shape, route this call through it, for the same reason `tryBuy`/`tryCorrupt` exist instead of calling `state:tryBuyCatalogItem` directly.


### 3 (continued). Input handling and z-order

Routing chain: `main.lua` LÖVE callbacks → `lib/input_dispatcher.lua` (predicate-ordered handlers, first match wins) → `controllers/InputController.lua` (global hotkeys registered first, catch-all `nil`-predicate handler forwards everything else to `StateMachine`) → the active state's own `mousepressed`/`keypressed`, which is where modal-vs-background routing actually happens (`ShoveState`, `GrindState`). There is no shared "modal stack" object — each state hand-rolls its own if/elseif chain of `self.xxx_modal` fields, checked in a fixed priority order, and every mouse branch is structured to `return` unconditionally so a click can't fall through past an open modal to the view underneath it (verified for both `GrindState:mousepressed` and `ShoveState:mousepressed` — every modal branch ends in `return`). That part is sound.

**[High] Escape is not swallowed by ShoveState's modals — pressing ESC over the post-bust PrestigeModal or the forced CatalogModal opens Settings stacked on top of them.**
`states/ShoveState.lua:352-388`:
```lua
function ShoveState:keypressed(key)
    if self.settings_modal then ... return end
    if self.prototype_end_modal then ... return end          -- always returns
    if self.prestige_modal and self.prestige_modal:consumeKey(key) then
        self:_advanceToCatalog()
        return
    end                                                        -- no return if consumeKey is false!
    if self.catalog_modal and self.catalog_modal:consumeKey(key) then
        self:_dismissCatalogAndReturn()
        return
    end                                                        -- same gap
    if self.deck_select_modal and self.deck_select_modal:consumeKey(key) then
        ...
        return
    end
    if key == "escape" then
        self:openSettings()
        return
    end
    ...
```
`PrestigeModal` is a bare `ActionModal` with `keys = { space = "ok", ["return"] = "ok", kpenter = "ok" }` (`views/PrestigeModal.lua:22`) — no `escape` entry. `ActionModal:consumeKey` (`views/widgets/ActionModal.lua:109-115`) only resolves (and only ever returns `true`) for keys present in that table; any other key, escape included, makes it return `false`. Because the `if self.prestige_modal and self.prestige_modal:consumeKey(key) then` block has no `return` outside the `then`, a `false` here falls through the `catalog_modal`/`deck_select_modal` checks (both nil at this point, also false) and lands on `if key == "escape" then self:openSettings() end` — opening `SettingsModal` on top of the still-open `PrestigeModal`. The exact same gap exists for `CatalogModal` in this same function: `CatalogModal:consumeKey` (`views/CatalogModal.lua:322-336`) only returns `true` for `space`/`return`/`kpenter`; ESC (or any other key) returns `false` and falls through to `openSettings()` too, stacking Settings over the forced, purchase-poster-required catalog. Once stacked, `ShoveState:mousepressed`/`:keypressed` both check `self.settings_modal` first on every subsequent input, so the player can now drive Settings — including "Start new game" (`SettingsModal.lua:110-112`, `game.startNewGame()`) — while a `Gauntlet` model and a `PrestigeModal`/`CatalogModal` are still live underneath, mid post-bust flow. Repro: enter Shove, bust, wait for `PrestigeModal` to appear, press ESC. Fix: either give `PrestigeModal`/`CatalogModal` an explicit `escape` no-op/cancel mapping, or, better, make `ActionModal:consumeKey` swallow (return `true`, no-op) any key while unresolved by default so a modal always eats input until it resolves, matching `ConfirmDialog:consumeKey`'s existing "swallow any other key" comment/behavior (`views/widgets/ConfirmDialog.lua:83-85`) that `ActionModal` conspicuously lacks.

**[Medium] Same ESC-fallthrough gap also reaches the DEV_HOTKEYS block below it — 'r' during an open PrestigeModal silently resets the gauntlet out from under the modal.**
Continuing past the `if key == "escape"` check in the same function, `states/ShoveState.lua:401-435` runs unconditionally whenever `Constants.FEATURES.DEV_HOTKEYS` is true, which it is by default (`data/constants.lua:40`, `DEV_HOTKEYS = not C.PROTOTYPE_MODE`, and `C.PROTOTYPE_MODE = false` at `data/constants.lua:19` in the current build). Pressing `r` (no shift) while `PrestigeModal` is open falls through the same gap as ESC above and hits:
```lua
elseif key == "r" then
    ...
    self.gauntlet       = nil
    self.prestige_modal = nil
    self._ended_handled = false
    self.view:resetTimeline()
```
silently dismissing the modal and discarding the finished gauntlet without going through `_advanceToCatalog`/the chip-banking flow the modal exists to gate. Same root cause as the finding above (missing `return` after the `prestige_modal`/`catalog_modal` `if` blocks) — fixing that also fixes this.

**[High] A keyboard escape hatch bypasses every modal in GrindState, including the "most forced" one: Tab switches to RoomState unconditionally, before any modal check runs.**
`states/GrindState.lua:324-328`:
```lua
function GrindState:keypressed(key)
    if key == "tab" then
        self.game.state_machine:switch("room")
        return
    end
    -- How-to-play is the most forced modal -- it owns input while up; only its
    -- button / space-return dismisses it (ESC does not escape it).
    if self.onboarding_modal then
        ...
```
The `tab` branch runs before the `onboarding_modal`/`help_panel`/`analytics_modal`/`settings_modal`/`catalog_modal`/`deck_roster_modal` checks that follow it, none of which get a chance to swallow `tab`. The comment two lines below explicitly documents the onboarding modal as forced ("ESC does not escape it"), yet `Tab` escapes it anyway, straight to `RoomState`. `states/RoomState.lua:164` maps both `escape` and `tab` back to `grind`, so the round trip is silent and doesn't crash, but `GrindState:enter()` (`states/GrindState.lua:189-218`) never clears `self.onboarding_modal`/`self.catalog_modal`/`self.settings_modal`/etc. on re-entry, so whichever modal was open reappears exactly as left. The practical effect is "the forced onboarding modal can be shoved offscreen into the Room designer and back," not data loss, but it is a verified, concrete violation of the modal's own documented input contract, one unconditional keypress away. Fix: move the `tab` branch to the bottom of `GrindState:keypressed`, after all the modal `if...return` blocks (mirroring how `escape` is already handled last).

**[Low] Hover state is not modal-owned; every modal in this layer polls love.mouse.getPosition() directly instead of services/HoverService, so a modal itself can't leave stale hover behind — but the underlying GrindView's own hover state is only defensively cleared after the fact, not structurally prevented, while a modal sits on top of it.**
`states/GrindState.lua:230-249` calls `self.view:update(dt)` (which repopulates `HoverService` for every hoverable widget under the modal) unconditionally every frame, then, only afterward and only if `self:_modalUp()` is true, calls `HoverService.clear()` again to blank it out (with a special case carved out for `help_panel`, clearing only when the mouse is actually over the dropdown). This works today because every modal's own `:draw` fully covers the screen with an opaque/dimmed backdrop before drawing its own content, so the stale hover glow on a background button is never actually visible. But it is a clear-after-the-fact patch, not a structural guarantee: a future modal that draws a partial-screen backdrop (leaving some background UI visible, e.g. a HUD strip) would immediately expose this, since background buttons would show hover-highlight state driven by whatever the view's own hit-test decided this frame, indifferent to the modal being open. `states/ShoveState.lua` does not perform even this defensive clear at all (no `HoverService.clear()` call anywhere in the file), verified safe today only because `views/ShoveView.lua` never calls into `HoverService`/`Tooltip` in the first place (confirmed via grep, zero hits), not because `ShoveState` guards against it.


### 4. Layout math

Context: `main.lua` fixes `love.graphics.getDimensions()`/`getWidth`/`getHeight` to always report `BASE_W, BASE_H = 1600, 900` (main.lua:70-84) regardless of the real window size, and maps mouse coordinates back through `fitTransform()`. This means most of the layer is protected from "breaks at a non-default resolution" in the literal sense — every view in this audit that calls `love.graphics.getDimensions()` always gets the same 1600x900 design canvas. The real per-window variable is `game.ui_scale` (a float set from the *actual* window size via `FontService.layoutScale`, `main.lua:137/394`), which every modal multiplies its own BASE constants by. That part of the architecture is sound; the findings below are about inconsistency and duplication within it, not about the fixed-canvas premise breaking.

**[Medium] `views/RoomView.lua` hand-duplicates the Room-Editor sidebar geometry between `:draw` and `:mousepressed` instead of computing it once.**
The sidebar button block (`EXPORT`/`RESET`/`CLEAR` rows) is laid out twice with the same literals, independently:
```lua
-- :draw, RoomView.lua:701-707
local btn_w = sidebar_w - text_margin * 2
local btn_h = fl(26 * s)
local btn_gap = fl(6 * s)
local btn_x = sidebar_x + text_margin
local exp_y = sidebar_y + fl(250 * s)
```
```lua
-- :mousepressed, RoomView.lua:933-940 (same numbers, re-typed)
local btn_w = sidebar_w - text_margin * 2
local btn_h = math.floor(26 * s)
local btn_gap = math.floor(6 * s)
local btn_x = sidebar_x + text_margin
local exp_y = sidebar_y + math.floor(250 * s)
```
Both blocks also separately hardcode `sidebar_w = 270`, `sidebar_y = 56`. Nothing enforces these two copies staying in sync — a future edit to one (e.g. widening the sidebar, adding a 4th button, changing `250` to make room) that isn't mirrored in the other silently desyncs the drawn button position from its own click target. `RoomState.lua` then duplicates a THIRD, independent copy of the top-bar height/PLAY-button geometry (`RoomState.lua:61,76-79` in `:draw`, `RoomState.lua:175-179` in `:mousepressed` — same `56`/`120`/`36`/`16` literals, again typed twice within the same file, and a fourth conceptual copy of "`top_h = 56*s`" independent from RoomView's own `TOP_BAR_H = 56*s` local in `getCenter`, `RoomView.lua:244`). Cost: this specific pattern (draw-time geometry re-derived from scratch at click-time instead of stashed on `self` during draw, the way `RoomView` already does correctly for its item-browser rows via `self._list_rows`/`self._list_rect`) is exactly the class of bug the codebase's own hit-rect-vs-drawn-rect discipline exists to prevent elsewhere (`ComponentRenderer.lua`'s registry comment: "layout drift is the consequence if they diverge"). Fix: compute the sidebar button rects once (in `:draw`, or a shared `:_sidebarLayout()` helper) and stash them on `self` (`self._export_rect`, etc.) the same way `self._size_prev_rect`/`self._floor_prev_rect`/`self._wall_prev_rect` already are two blocks below — `:mousepressed` should read those stashed rects, not recompute geometry from magic numbers a second time. This is dev-tooling (Room Editor), not player-facing, so severity is capped at Medium rather than High.

**[Low] `views/RoomView.lua:1131` hardcodes the `poker_poster` placement color instead of reading it from `data/room_layout.lua`, and can drift from the saved layout.**
```lua
color = active_spec.id == "poker_poster" and { 0.82, 0.42, 0.38 } or { 0.40, 0.55, 0.75 },
```
`data/room_layout.lua:22` already stores `poker_poster`'s color as data: `color = { 0.82, 0.42, 0.38 }`. They currently match by coincidence, but nothing keeps them matched — editing the item's placed color in `data/room_layout.lua` (the file the Editor's own EXPORT button writes) does not change what color a *freshly placed* poster gets, since new placements read this separate hardcoded literal instead of the catalog/layout data.

**[Low] `DeckSelectModal` reinvents "fit everything to the viewport" instead of using the same auto-height + `max_h_frac` mechanism `Modal`/`ActionModal` already provide, and its own math has an unguarded negative-scale path.**
`views/DeckSelectModal.lua:458-469`:
```lua
local max_modal_w = W * 0.95
local max_s_width = max_modal_w / MODAL_W_BASE
local h_base = fonts.lg:getHeight() + fonts.sm:getHeight() * 2 + 76
local h_scale = 596
local max_modal_h = H * 0.90
local max_s_height = (max_modal_h - h_base) / h_scale
s = math.min(s, max_s_width, max_s_height)
if s < 0.4 then s = 0.4 end
```
If `max_modal_h < h_base` (an extreme case, but `h_base` is itself font-size-dependent so it isn't a fixed constant), `max_s_height` goes negative, `math.min` picks it, and the `if s < 0.4` floor silently overrides it back to `0.4` — meaning the "clamp to fit" guarantee the comment above this block promises ("prevents the modal box from getting capped and overlapping the button/text") is not actually guaranteed in that regime; the modal would render at a fixed minimum scale that could still overflow. Every other modal in this layer instead leans on `Modal:draw`'s existing `max_h_frac` cap (`views/widgets/Modal.lua:84-87`, unconditional and can't go negative) and lets content clip/scroll (`ActionModal`) rather than shrinking scale to fit. `DeckSelectModal` is the one modal that invented its own competing fit strategy; consolidating it onto `Modal`'s cap (plus, if needed, `Scrollbar` for the tile grid, which currently has none) would remove both the duplication and the edge case.

**[Nit] Hero-card image sizing in `CatalogModal.lua:523` divides card height inline without a named constant, mirrored nowhere else, unlike every sibling constant in the file (`CARD_H`, `LEAF_SLOTS`, `HEADER_H`) which are named module-locals.** `img_w = math.min(fl(140 * s), fl(h * 0.5))` — the `140` and `0.5` are one-off literals with no sibling reference elsewhere in the 1294-line file to check them against if the hero layout is revisited.


### 5. Correctness bugs

**[Medium] `Sticker.widthFor`/`Sticker.heightFor` over-allocate by `2*PAD(s)` after the in-progress rename from `MARGIN` to `INLAY` — verified by re-deriving the geometry `Sticker.draw` actually uses.**
`views/widgets/Sticker.lua:356-377` (current, uncommitted):
```lua
function Sticker.widthFor(font_set, scale, title, line, counter)
    ...
    return (PAD(s) * 2 + INLAY(s)) * 2 + math.max(f_title:getWidth(title or ""), detail)
end
function Sticker.heightFor(font_set, scale, has_line)
    ...
    return (PAD(s) * 2 + INLAY(s)) * 2 + inner
end
```
`Sticker.draw` computes the panel as `pw = w - inlay*2` (line 176) and the text column inside it as `text_w = pw - pad*2` (line 211), i.e. `w = text_w + inlay*2 + pad*2` is the exact rect a caller needs for its content to fit — `2*INLAY(s) + 2*PAD(s)`, once each. `widthFor`/`heightFor` compute `(PAD*2 + INLAY)*2 = 4*PAD + 2*INLAY` instead — an extra `2*PAD(s)` (roughly 4-18px depending on `s`) tacked onto the "content actually needs" size returned to callers. The git history confirms this is a regression introduced in the current uncommitted edit: the prior formula was `(PAD(s) + MARGIN(s)) * 2`, i.e. `2*PAD + 2*MARGIN` — mathematically correct — and the rename to `INLAY` also (apparently accidentally) changed `PAD(s)` to `PAD(s) * 2` in both call sites. Only caller today is `views/CatalogModal.lua:628,632` (`Sticker.heightFor(fonts, s, true)` / `Sticker.widthFor(fonts, s, STICKER_TITLE, st_line, st_counter)`), where the result (`want_w`/`st_h`) is subsequently clamped down to whatever band is available (`CatalogModal.lua:634,647`), so the practical symptom today is a slightly-larger-than-necessary sticker footprint rather than an overflow — but the function's contract (return the size the content needs) is now measurably wrong, and any future caller that trusts the return value directly (not re-clamping it) will reserve too much space. Fix: drop the stray `* 2` — `(PAD(s) + INLAY(s)) * 2 + ...` in both functions.

**[Low, latent] `views/widgets/Sticker.lua:53-55`'s `brighten` helper is dead code from the same in-progress edit — defined, never called.**
```lua
local function brighten(c, k)
    return { c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k }
end
```
`grep -n "brighten" views/widgets/Sticker.lua` finds only this definition; every other tint in the file goes through the file's own `darken` (used once, line 278: `darken(panel, 0.4)` for the panel-rim keyline) or the caller-supplied tokens. Not harmful (Lua doesn't warn on unused locals), but it's WIP debris — either the panel-rim/gloss pass was meant to call it and doesn't yet, or it should be deleted before this diff lands.

**[Low, latent] Hero-card text (`CatalogModal.lua:668-708`) has no width clamp/wrap, unlike the identical fields on the non-hero card path (`CatalogModal.lua:709-771`, which runs every string through `clampText(..., col_w)`).**
```lua
-- hero path, CatalogModal.lua:679-682 -- no clampText
love.graphics.setFont(fonts.md)
Theme.setColor(name_ink)
local nm = (item.name or "?"):upper()
love.graphics.print(nm, cxm - fonts.md:getWidth(nm) * 0.5, ty)
```
vs.
```lua
-- non-hero path, CatalogModal.lua:738-739
love.graphics.print(clampText((item.name or "?"):upper(), fonts.md, col_w),
                    text_x, name_y)
```
The hero layout (`hero = true`, used only when `item.slots >= 3`) centers `print()` directly off the *unclamped* string width for the name, the flavor `description`, and the shove-rate line, with no fallback if any of them exceeds the card's width `w`. Today this is masked: the only catalog item authored with `slots = 3` is `cursor_pool` ("Box of Mice", `data/catalog.lua:639-651`), whose name/description are both short enough to fit. But the hero path is a real, reachable code path (triggered purely by `slots >= 3` in data, not gated to this one item), and unlike its sibling non-hero path, nothing stops a future hero item with a longer name from printing past the card's left/right edges — there is no wrap, no `clampText`, no `IconText`-style word-boundary truncation on any of the three hero text lines. Fix: route the hero-path name/description/shove-line strings through `clampText` (or `printf(..., "center")` with a bounded width) exactly as the non-hero path already does, so the safety net isn't only present on the code path that happens not to need it yet.

**[Low] `views/RoomView.lua`'s item-browser label cache mutates the shared `data/catalog.lua` item tables at runtime (`_trim`/`_trim_w` fields bolted onto live Catalog rows), a `data/` purity violation surfaced from the view side.**
`RoomView.lua:850-860`:
```lua
local function trimmed(item)
    if item._trim and item._trim_w == label_w then return item._trim end
    local txt = item.name or item.id
    if sm:getWidth(txt) > label_w then
        repeat txt = txt:sub(1, -2)
        until sm:getWidth(txt .. "...") <= label_w or #txt <= 1
        txt = txt .. "..."
    end
    item._trim, item._trim_w = txt, label_w
    return txt
end
```
`item` here is drawn from `self.placeable`, which for the "Catalog" group is populated directly from the shared `data.catalog` module table (`RoomView.lua:128-133`: `placeable[#placeable + 1] = item` where `item` comes from `for _, item in ipairs(Catalog) do`) — not a copy. Writing `item._trim`/`item._trim_w` therefore adds ad hoc fields directly onto the same table objects `CatalogModal`, `GrindView`, and every save/serialize pass reference as `data/catalog.lua`'s pure-data rows, for the lifetime of the process. It's populated only in the (dev-only) Room Editor path and the fields aren't read by anything else, so no live bug results today, but it is a genuine instance of a view treating a `data/` table as a place to stash its own derived cache instead of keeping that cache modal-local (e.g. keyed by `item.id` in a table on `self`), which is exactly the coupling rule 3 exists to prevent. Fix: key the trim cache by `item.id` in a `self._trim_cache` table owned by `RoomView`, not on the item object itself.

**[Low] `CatalogModal`'s sticker-peel drag is not tied to the page it started on — a page flip mid-drag doesn't cancel it.**
`CatalogModal:_updatePeel` (`CatalogModal.lua:362-383`) tracks `self._peel = { id, x0, w, amount }` purely by item id, polled once per `:draw` from the live mouse position regardless of what page is currently showing. `:wheelmoved` (`CatalogModal.lua:340-354`) does not check `self._peel` before flipping pages (only `self.flip_t`), so a click-and-hold on a sticker followed by a scroll-wheel page turn (mouse button still down) continues advancing `p.amount` against the original sticker's id while a different page is now visible; on release, if the drag crossed `PEEL_COMMIT`, `game.grind:peelCatalogSticker(p.id)` still fires for the now off-screen item. Not a crash (the action is correctly keyed by id, not by screen position) and the window to trigger it is narrow (hold left mouse + scroll simultaneously), but it is a real stale-interaction path: the peel visually resolves on a page the player is no longer looking at, with no cancel-on-navigate. Fix: clear `self._peel` in `:wheelmoved` and in the `:consumeMouse` dog-ear-click branches before starting a flip.


### 1. Widget-layer coherence

There are three competing contracts in `views/widgets/` + the shared render helpers, not one:

- **(A) Stateful OOP widgets** — `Widget:new(opts)` returns a `setmetatable`'d instance that owns its own interaction state (drag flags, resolved value, scroll position) and exposes `:consumeKey`/`:consumeMouse`/`:mousemoved`/`:mousereleased` for the host state to forward raw input into.
- **(B) Stateless static-table widgets** — a plain module table with a `.draw(opts)` (or positional) function and *no* input methods at all; the caller hit-tests the same rect externally, every frame, using its own mouse-position logic.
- **(C) The `HoverService`-mediated pair** (`Panel` + `ComponentRenderer`) — a third convention where hover state is written to a shared namespace+id registry during a hit-test pass, then read back by *other* code (including code that didn't do the hit-testing, e.g. `AwardGlow`) during the draw pass.

| Widget | Constructor shape | Update sig | Draw sig | Input sig | Who owns hover state |
|---|---|---|---|---|---|
| `Modal` | `Modal:new(opts)` OOP | — | `:draw(fonts, body_h_request)` — self-positions (centers), returns body rect | none (exposes `:hitTest(mx,my)` → `"inside"/"outside"` string for the *caller* to build dismiss logic from) | n/a (chrome only) |
| `ActionModal` | `ActionModal:new(opts)` OOP, wraps `Modal` | — | `:draw()` — no args, reads `self.game`/`self.buttons` | `:consumeKey(key)`, `:consumeMouse(mx,my,btn)`, `:wheelmoved(_,dy)`, `:mousemoved`, `:mousereleased` | caller (`love.mouse.getPosition()` polled inline in `:draw`, `ActionModal.lua:294`) |
| `ConfirmDialog` | `ConfirmDialog:new(opts)` OOP | — | `:draw(fonts)` — self-positions, no rect args at all | `:consumeKey(key)`, `:consumeMouse(mx,my,btn)` | caller (`love.mouse.getPosition()` polled inline, `ConfirmDialog.lua:121`) |
| `Slider` | `Slider:new(opts)` OOP | *(none — value mutation happens inside the input methods themselves)* | `:draw(x,y,w,h)` — pure positional, no opts table | `:mousepressed(mx,my,btn)→bool`, `:mousemoved(mx,my)`, `:mousereleased(mx,my,btn)` | **the widget itself** — `self._dragging` is private; nothing outside can query it |
| `Panel` | `Panel:new(x,y,w,h)` OOP — positional geometry, unlike every other OOP widget above which takes an opts table | `:update(my)` (drag-continuation only — mx/full mouse pos NOT passed) | `:draw(game)` | `:handleMouseDown(x,y,btn,game)→bool`, `:handleMouseUp()`, `:handleScroll(dy)` | `HoverService`, namespace `"tab"`/`"scrollbar_thumb"` |
| `ComponentRenderer` (CR) | not a widget — a stateless module with a type registry | — | `CR.draw(components, panel_x, panel_w, game, scroll_view)` | `CR.hitTest(...)→component`, called externally by the host, not by CR itself | `HoverService`, namespace `"button"`/`"tab"` — written during `hitTest`, read during `draw` (by `CR._button` **and** by `AwardGlow.draw`, a third module) |
| `Button` (base) | none — static table | — | `Button.draw(x, y, w, h, opts, label_fn)` — positional geometry + opts hybrid | none | caller passes `opts.hovered` as a plain bool it computed however it likes |
| `LabelButton` | none — static table | — | `LabelButton.draw(opts)` — geometry folded into opts (`opts.x/y/w/h`) | none | caller passes `opts.hovered` |
| `MiniButton` | none — static table | — | `MiniButton.draw(opts)` | none | caller passes `opts.hovered` |
| `Row` | none — static table | — | `Row.draw(opts)` / `Row.drawSplit(opts)` (self-polls `love.mouse.getPosition()` internally for the split variant, `Row.lua:80`) / `Row.drawSection(opts)` | none (`.draw` returns a hit-rect table for the caller to test against next frame) | mixed: `.draw` takes `opts.hovered` from caller; `.drawSplit` computes its own hover from live mouse pos, inconsistently with its sibling function in the same file |
| `Stamp` | none — static table | — | `Stamp.draw(opts)` | none | n/a (decorative, non-interactive) |
| `Sticker` | none — static table | — | `Sticker.draw(opts)`, plus `Sticker.widthFor`/`Sticker.heightFor` measurement helpers | none | n/a; `peel` is a 0..1 float the *caller* (`CatalogModal`) tracks and passes in |
| `Scrollbar` | none — static table, no instance at all | — | `Scrollbar.draw(track_x, track_y, track_h, scroll_y, content_h, hovered)` — pure positional | `.containsPoint`, `.containsThumb`, `.scrollFromDrag`, `.scrollFromTrackClick`, `.clamp` — all pure functions the caller composes itself | caller (every one of `Panel`, `ActionModal`, and any future scroll consumer re-derives its own `hovered` bool from `Scrollbar.containsThumb(...)` + live mouse pos, independently, each in its own file) |

**The two hover conventions actually collide, not just differ stylistically.** Everything reachable from `Panel`/`ComponentRenderer` (the always-visible `GrindView` sidebar) participates in the shared `HoverService` registry — hover state persists for the frame and is inspectable by unrelated code (`AwardGlow`). Everything reachable from any of the 8 modals in this audit, plus `RoomView`, instead re-polls `love.mouse.getPosition()` inline on every single `:draw()` call and computes a throwaway local `hov`/`hovered` boolean that only that one draw call can see. Neither is wrong in isolation, but a widget that's meant to be reusable across both worlds — `Button`/`LabelButton`/`MiniButton`/`Row`, all four of which are already used from *both* sides (`CR._button` calls `Button.draw` with a `HoverService`-sourced bool; `SettingsModal`/`DeckSelectModal`/`RoomView` call `LabelButton.draw` with a `love.mouse.getPosition()`-sourced bool) — has no contract telling a new call site which one to use. The `opts.hovered` boolean parameter is the same shape either way, so nothing catches a call site that mixes conventions (e.g. computes hover from `HoverService` but forgets `HoverService.clear()` ran already this frame — see §3's stuck-hover discussion).

**Which contract should win:** for anything living inside `GrindState`'s always-on view (Panel/ComponentRenderer's territory), keep `HoverService` — it's already the shared, inspectable, namespace-keyed source of truth and `AwardGlow` already depends on being able to read someone else's hover result. For the modal layer, the inline-`love.mouse.getPosition()`-per-draw convention is fine *only* because every modal here is drawn once per frame in a fixed, singular z-order slot with no cross-widget hover queries — but it should be named and documented as the deliberate second contract it is (e.g. a one-line convention note in `views/widgets/Modal.lua`'s header: "modals compute their own hover locally; they do not participate in HoverService"), so a future modal author doesn't reach for `HoverService.set` inside a modal body and get silently overwritten/cleared by `GrindState`'s modal-up hover-clear pass (§3).

**Secondary inconsistency worth collapsing:** `Panel:new(x,y,w,h)` is the only OOP widget in this table that takes positional geometry instead of an `opts` table the way `Modal`/`ActionModal`/`ConfirmDialog`/`Slider` do — cosmetic, but it means "how do I construct a widget" has two different answers depending which one you're looking at, and `Row.drawSplit` polling `love.mouse.getPosition()` itself while its sibling `Row.draw` takes `opts.hovered` from the caller is the same inconsistency at the function level, inside one file.


### Uncommitted work in progress — code review

`git diff` on the two files with pending changes:

**`views/widgets/Sticker.lua` (+203/-59).** A visual rework of the sticker (white vinyl backing distinct from a cream "panel" base, a fill-seam divider, a gloss sweep, a starburst flourish, a serrated peel-strip edge, a text "vinyl disc" the copy prints on instead of the panel directly). The new `stock_token`/`panel_token`/`vinyl_token` three-way split (vs. the old two-token `stock_token`/`fill_token`) is a coherent, deliberate API change and its one caller (`CatalogModal.lua`, the paired +13 diff) was updated to match — `stock_token = {1,1,1}` (was the die-cut backing token, now literally white), new `panel_token`/`vinyl_token` added, `fill_token` now branches on `met` (amber while counting down, green once peelable) where before it was a single static amber. This part is finished and consistent between both files. Two loose ends found by re-deriving the geometry against the new code (both written up in full under §5 correctness bugs above, referenced here for the diff-review ask specifically):
- The `widthFor`/`heightFor` formula regression (`(PAD*2+INLAY)*2` should be `(PAD+INLAY)*2`) — introduced by this diff, not present before it (old formula `(PAD(s) + MARGIN(s)) * 2` was correct).
- The new `brighten()` helper (lines 53-55) is defined and never called anywhere in the file — dead code left over from whatever pass added the gloss/starburst details, should be deleted or wired up before this lands.

**`views/CatalogModal.lua` (+13/-8, all inside `drawItemCard`'s sticker-token block).** Purely the caller-side half of the `Sticker.lua` API change above — passes the three new tokens, computes `fill_token` conditionally on `met`. Nothing half-finished here; it's a complete, minimal update matching the widget's new contract. No other part of this large file's diff touches unrelated code.

Neither diff touches input handling, layout math, or any of the theme/architecture findings elsewhere in this report — those are all pre-existing in the committed code, not regressions from this WIP.

### 7. Copy conventions

Checked every player-facing string literal in this layer (`views/RoomView.lua`, `views/CatalogModal.lua`, `views/DeckSelectModal.lua`, `views/SettingsModal.lua`, `views/OnboardingModal.lua`, `views/PrestigeModal.lua`, `views/PrototypeEndModal.lua`, `views/AnalyticsConsentModal.lua`, everything in `views/widgets/`, `states/RoomState.lua`, `data/catalog_pages.lua`) against the "no literal 'chips', no em-dash, no filler" rules.

**Clean.** No em-dash (`—`) appears in any player-facing string in this layer (comments use them extensively throughout the codebase as the established prose style, but that's not player-facing copy and is out of scope for this rule). The only hit for the literal word "chips" is `views/OnboardingModal.lua:33`:
```lua
"Win a {stack} stack to bank {chip} gold chips, once per stake/type each run. ..."
```
— this already carries the `{chip}` icon marker immediately before the word, and "Gold Chip" is the established proper name for the currency elsewhere in the same file's own glossary (`GLOSSARY` table, `OnboardingModal.lua:62`: `"{chip} Gold Chip"`), matching the project convention (see memory: plural "gold chips" is intentional since most banks award several, not a violation of the icon-instead-of-word rule — the icon is present, "gold chips" is naming the currency, not replacing its icon). Not flagged as a defect; noted only because it's the one place the word appears at all in this layer.

No filler words ("this hand", "a fresh", "genuinely", etc.) found in any of the audited files' player-facing copy.

---

## Bootstrap, DI container, state machine, and lifecycle

### 1. The DI container

`buildGame()` in `main.lua:120-278` constructs the container `g` in this order:

1. `g.C`, `g.catalog`, `g.run_upgrades` (data tables, no deps)
2. `g.theme = Theme` (module singleton, see finding 1.1)
3. `g.fonts = FontService.build(...)`, `g.ui_scale = FontService.layoutScale(...)` — depends on `love.graphics.getDimensions()`, which main.lua has *already* monkey-patched (top of file, module load time) to always return `BASE_W, BASE_H` (1600x900)
4. Module-singleton configuration calls: `views.Chips.setScale`, `views.ComponentRenderer.setScale`, `views.widgets.ConfirmDialog.setScale`, `views.widgets.Slider.setScale`, `views.Panel.configureFromFonts`, `views.ComponentRenderer.configureFromFonts`, `views.CatalogModal.configureFromFonts`, `views.SettingsModal.configureFromFonts` — none of these go through `g`
5. `g.debug`, `g.event_bus = EventBus`, `g.time = Time:new()`, `g.camera = Camera:new(0,0,1)`, `g.sprite_loader = SpriteLoader:new()`
6. `g.sounds`, `g.animations`, `g.floating_text`, `g.hover` (module singletons assigned onto `g`)
7. `g.viewport = { w, h }`
8. `g.save_service = SaveService:new()`; `saved = g.save_service:loadAll()`; `g.state = GameState:new(saved)`
9. `g.settings` (reads `g.save_service`)
10. `g.effects`, `g.xp_rules`, `g.unlock_rules` (+`Decks.checkPendingUnlocks`), `g.hint_rules`, `g.poker_events` — all registries, all depend on `g.state` existing (step 8), verified fine
11. `g.state_machine = StateMachine:new(g)`, then `register("grind"|"shove"|"credits"|"title"|"room", *State:new(g))`
12. `g.startNewGame` closure
13. `g.input_dispatcher = InputDispatcher:new()`, `g.input_controller = InputController:new(g)`, then dispatcher wiring gated on `Constants.FEATURES.DEV_HOTKEYS`

All state constructors receive the *same* `g` table by reference (not a snapshot), so a field assigned later (e.g. `g.input_dispatcher` at step 13, after states are built at step 11) is still visible to a state at runtime as long as the state doesn't dereference it **during its own `:new()`/`:init()`**. Verified none of the five registered states read `game.input_dispatcher`/`game.input_controller` at construction time (only reads are inside `InputController.lua` itself and `main.lua`), so this ordering is safe today but is temporal coupling with no enforcement — reordering `buildGame()` could silently break it with no error (a state reading `game.input_dispatcher` in `:new()` would just get `nil`, no crash, and dispatch would quietly never receive that handler).

**Finding 1.1 - Severity: High. `views.Theme` registered on the DI container but never consumed through it; every file uses the module-singleton path instead.**
`main.lua:127`: `g.theme = Theme`. Nothing in the codebase ever reads `self.game.theme` / `game.theme` (verified via search across all `.lua` files - zero hits besides the assignment itself). Meanwhile `require("views.Theme")` is called directly in 44 other files, including every state:
```
states/GrindState.lua:13:local Theme = require("views.Theme")
states/ShoveState.lua:19:local Theme = require("views.Theme")
states/TitleState.lua:15:local Theme = require("views.Theme")
states/RoomState.lua:6:local Theme  = require("views.Theme")
states/CreditsState.lua:14:local Theme = require("views.Theme")
```
Consequence: `g.theme` is dead weight - a DI registration that's pure decoration. Every consumer bypasses DI for theme access via the require-singleton path, which is exactly the "two parallel access paths for the same shared state" anti-pattern `main.lua:170-176`'s own comment explicitly warns against for CursorPool/FlightSystem/etc. Theme just has one path in practice (require), but the container entry misleads a reader into thinking DI governs it.

**Finding 1.2 - Severity: High. `services.HoverService` and `services.SoundService` are genuinely dual-path: registered on `g` AND required directly elsewhere, with real call sites on both paths.**
`g.hover = HoverService` (`main.lua:168`) and `g.sounds = SoundService` (`main.lua:165`) are both consumed correctly via `self.game.hover`/`self.game.sounds` in some call sites:
```
views/GrindView.lua:356: local hov = game.hover.is("button", id) and not active
views/GrindView.lua:943: self.game.hover.set("hit", hb.action .. ":" .. hb.idx)
controllers/GrindController.lua:1407: local sounds = self.game.sounds
```
But the same modules are also required directly, bypassing `g`, in other files - including the very view that also uses the DI path:
```
views/GrindView.lua:395: require("services.HoverService").set("button", id)
states/GrindState.lua:33: local HoverService = require("services.HoverService")
views/TablePanel.lua:34: local Hover = require("services.HoverService")
views/Panel.lua:186,238: local HoverService = require("services.HoverService")
views/ComponentRenderer.lua:16: local HoverSvc = require("services.HoverService")
views/CatalogModal.lua:351,420,437: local SoundService = require("services.SoundService")
views/SettingsModal.lua:14: local SoundService = require("services.SoundService")
services/FlightSystem.lua:21: local SoundService = require("services.SoundService")
services/CursorPool.lua:23: local SoundService = require("services.SoundService")
```
This is not a theoretical risk - it is the fake-DI pattern happening in the same file (`GrindView.lua`) on two different lines. Consequence: no functional bug today (these modules cache a single instance at require-time so state is still effectively shared), but "no globals, DI only" (Rule 1) is violated in roughly 9 call sites across 6 files, and any future refactor that tries to give `HoverService`/`SoundService` a real per-instance lifetime (e.g. for tests, or multiple concurrent sessions) will silently miss every direct-require call site.

**Finding 1.3 - Severity: Medium. `core/event_bus.lua`'s mutable module table is both `require`d directly and hung on the container - confirmed, and currently has zero consumers anywhere.**
```
main.lua:14: local EventBus = require("core.event_bus")
main.lua:158: g.event_bus = EventBus
```
A repo-wide search for `event_bus`/`EventBus` (excluding docs) returns exactly these two lines plus the file's own definition - no file calls `:subscribe`, `:publish`, `:addTap`, or `:removeTap` anywhere. The bus is fully wired into the DI container and completely unused. This means: (a) the "two access paths to one global" risk already flagged in `docs/aug2026 audit kimi k3.md:7` is real in structure (same table reachable via `require("core.event_bus")` and `g.event_bus`) but currently inert since nothing uses either path; (b) it's also a "constructed but never used" service - dead machinery that adds surface area (anyone could `require` it directly in the future and silently sidestep DI, exactly as already happened with Theme/Hover/Sound above).

**Finding 1.4 - Severity: Medium. `core/camera.lua`'s `Camera` is constructed on the container and never used anywhere.**
```
main.lua:160: g.camera = Camera:new(0, 0, 1)
```
A repo-wide search for `.camera` returns only this one assignment line. No state or view calls `:apply()`/`:remove()`. `core/camera.lua` (23 lines) is a fully dead engine-layer service - harmless but pure clutter; if it's meant to be lifted into a future idle game, it currently has zero real-world exercise in this one.

**Finding 1.5 - Severity: Medium. DI container assembly is split between `main.lua` and `states/GrindState.lua` - a state mutates the shared container from its own constructor.**
```lua
-- states/GrindState.lua:60-77
self.controller = GrindController:new(game)
self.view       = GrindView:new(game, self.controller)
...
game.grind = self.controller
local state_self = self
game.openCatalog    = function() state_self:openCatalog()    end
game.openSettings   = function() state_self:openSettings()   end
game.openDeckRoster = function() state_self:openDeckRoster() end
game.openHelp       = function() state_self:openHelp()       end
game.quickReset     = function() state_self:quickReset()     end
game.toggleRoom     = function() state_self.game.state_machine:switch("room") end
```
`ShoveState.lua:100` (`if not self.gauntlet and self.game.grind then`), `RoomState.lua:157` (`self.game.grind and self.game.grind.invalidateEffects`), and `views/GrindView.lua:2189-2265` (`self.game.quickReset`, `self.game.openCatalog`, `self.game.openDeckRoster`, `self.game.toggleRoom`, `self.game.openHelp`) all read these fields as if they were DI dependencies. They are actually side effects of `GrindState:new()` running - which only happens because `main.lua:236` registers `"grind"` before `"shove"`/`"room"` at `main.lua:237/240`. Nothing enforces that order; swapping the registration order in `main.lua` would leave `game.grind`/`game.openCatalog` nil for the whole session with no error at any point (every read site is defensively guarded with `if game.grind then` / `if self.game.openCatalog then`) - the SHOVE cash-out logic, the CATALOG/DECK/SETTINGS/HELP top-bar buttons, and quick-reset would all silently no-op. This also means `GrindView:new(game, controller)` (`views/GrindView.lua:242`) runs before `game.grind`/`game.openCatalog` are assigned (they're set at `GrindState.lua:68-77`, after `self.view = GrindView:new(...)` at line 61) - verified `GrindView:new` does not read those fields at construction (only `game.state`, `game.fonts`, `controller:tiedUp()`), so no live bug, but it is fragile: any future field added to `GrindView:new`'s init body that reads `game.openCatalog` would get `nil` silently.

### 2. State machine correctness

`controllers/StateMachine.lua` is a flat, single-current-state machine (108 lines, read in full). Line-by-line notes:

**`switch(state_name, ...)` (lines 26-44):**
```lua
function StateMachine:switch(state_name, ...)
    if not self.states[state_name] then return end
    if self.current_state and self.current_state.exit then
        self.current_state:exit()
    end
    self.current_state = self.states[state_name]
    self.current_name  = state_name
    if self.current_state.enter then
        self.current_state:enter(...)
    end
    if self.current_state.resize then
        self.current_state:resize(love.graphics.getDimensions())
    end
end
```

**Finding 2.1 - Severity: Low. Unregistered state name fails silently.**
Line 27: `if not self.states[state_name] then return end` - no error, no log. A typo'd `switch("shvoe")` anywhere would silently do nothing (old state stays current, nothing exits/enters), with zero diagnostic. Every call site in the codebase currently uses a literal string matching a registered name, so unverified as a live bug, but there's no assertion to catch a future typo either.

**Finding 2.2 - Severity: Medium (latent/unverified as live). No re-entrancy guard - a `switch()` called from inside another `switch()`'s `enter()` would corrupt `current_state`.**
Trace: `switch(A)` sets `self.current_state = A` (line 31) *before* calling `A:enter()` (line 33-34). If `A:enter()` itself called `switch(B)`, the inner call would: exit `A` (which hasn't finished entering), set `current_state = B`, `enter()` on B, then return. Control returns to the outer `switch(A)` frame, which resumes after its own `self.current_state:enter(...)` line and executes `if self.current_state.resize then self.current_state:resize(...) end` - but `self.current_state` is now `B` (mutated by the inner call), so `B:resize()` fires a **second time** (once inside the inner `switch(B)`'s own tail, once again from the outer `switch(A)`'s leftover tail code operating on the now-stale `self.current_state` reference). Verified via full read of all five states' `enter()` methods (`TitleState:enter`, `CreditsState:enter`, `RoomState:enter`, `GrindState:enter`, `ShoveState:enter`) that **none currently call `state_machine:switch()` from inside `enter()`** - so this is not live today, but the machine has zero structural protection against it (no re-entrancy flag, no queued-transition pattern). A future state whose `enter()` conditionally redirects (e.g. "enter shove, but if no gauntlet possible, bounce to grind") would hit this exact double-resize / stale-current_state bug.

**Finding 2.3 - Severity: Medium. Switching to a state while it's already current re-runs exit+enter on the same object with no short-circuit - and this pattern is actively used for a same-state "refresh".**
Nothing in `switch()` checks `state_name == self.current_name` and skips the no-op case. `states/ShoveState.lua`'s F2 hotkey (`InputController.lua:27-32`) toggles grind<->shove but never re-enters the same state, so this isn't hit via that path. However `GrindController.lua:1782` (`self.game.state_machine:switch("shove")`) and other call sites always target the *other* state, so no current call site switches a state into itself. Confirmed non-issue in practice today, but noted because `switch()` provides no protection if that ever changes (e.g. a "restart gauntlet" flow that calls `switch("shove")` while already in shove would run `exit()` then `enter()` on the live `ShoveState` object, and `ShoveState:enter()` has cash-out/gauntlet-init logic gated on `if not self.gauntlet` - re-entering without a prior `fullReset()` would skip the buildup/cash-out branch silently, since `self.gauntlet` may still be set from the state being "current").

**Finding 2.4 - Severity: High (verified, currently benign only by code-ordering luck). `switch()` is called from *inside* a state's own `:update()` call stack with no re-entrancy guard - confirmed live call site.**
`states/ShoveState.lua:309-333`:
```lua
function ShoveState:update(dt)
    self.view:update(dt)
    if self.view:isReadyToDeal() and not self.gauntlet then
        self.view:markRunning()
        self:_beginGauntlet()
        return
    end
    if self.gauntlet
       and self.gauntlet.state == "finished"
       and not self.view:isAnimating()
       and not self._ended_handled
       ... then
        self:_onGauntletEnded()
    end
end
```
`_onGauntletEnded()` (line 151-207) calls `self.game.state_machine:switch("credits")` at line 202 on a win. This runs from *inside* `StateMachine:update(dt) -> ShoveState:update(dt) -> _onGauntletEnded()` - i.e. `switch()` fires while `ShoveState:update` is still on the call stack, and `StateMachine:update` (`controllers/StateMachine.lua:48-52`) is also still on the stack above it. It currently works only because the `switch()` call is the very last statement reachable in that branch of `ShoveState:update` (nothing runs after it in that function, and `StateMachine:update` has nothing after `self.current_state:update(dt)` either), so the stale `self.current_state` reference is never used again this frame. There is no mechanism enforcing that invariant - a future edit adding a trailing line after `self:_onGauntletEnded()` in `ShoveState:update`, or after `_onGauntletEnded`'s `switch()` call inside `_onGauntletEnded` itself, would silently execute against the *new* current state's `self` fields via a `self` that still points at the *old* `ShoveState` instance (Lua's `self` is bound at call time, not re-resolved), which is exactly the kind of bug that survives code review because it works until someone adds "just one more line."
Also present at `controllers/GrindController.lua:1775-1783` (`initiateShove()` calls `self.game.state_machine:switch("shove")`), triggered from `views/GrindView.lua:2276` inside `GrindView:mousepressed`, which also `return`s immediately after - same "safe by being the last statement" pattern, same lack of structural protection.

**Finding 2.5 - Severity: Low. `enter`/`exit` are asymmetric by convention, not enforced - most states have empty `exit()`.**
`TitleState:exit()` (line 39), `CreditsState:exit()` (line 29), `ShoveState:exit()` (line 132), and `GrindState:exit()` (line 220) are all empty no-ops; only `RoomState:exit()` (lines 35-39) does real cleanup (`self.room_view.editor_mode = false`). This is a deliberate design choice (states keep their sub-objects - modals, gauntlet, view - alive across a switch-away/switch-back so e.g. TAB to room and back preserves the grind view), not a bug, but it does mean `exit` always running (verified: `StateMachine:switch` unconditionally calls `self.current_state:exit()` if the method exists, with no pcall - see Finding 5) is not itself a safety net for anything, since nearly every state's `exit` does nothing.

**Finding 2.6 - Severity: Info. `exit` is not guaranteed to run on process quit or on an unhandled error mid-update/draw.**
`love.quit()` (`main.lua:409-421`) does not call `Game.state_machine:current_state:exit()` at all - it goes straight to `HandAnalytics.flush` and a conditional `save_service:saveAll`. And since no `love.errorhandler` is defined (see Finding 5.1), an unhandled Lua error during `update`/`draw` aborts the current state without running its `exit()`. Given every `exit()` except `RoomState`'s is a no-op, the practical impact is limited to `RoomState.editor_mode` staying `true` after a crash while the room editor was open - low impact, but confirms `exit` is not a place any future cleanup-on-crash logic could rely on without also wrapping the crash path itself.

### 3. Event bus lifecycle

This is the highest-value hunt per the brief, and the answer is unambiguous: **`core/event_bus.lua`'s pub/sub API (`:subscribe`, `:publish`, `:addTap`, `:removeTap`) has zero callers anywhere in the codebase.** A repo-wide search for `event_bus`/`EventBus` returns exactly:
```
main.lua:14:  local EventBus = require("core.event_bus")
main.lua:158: g.event_bus = EventBus
core/event_bus.lua: (the four method definitions themselves)
```
No `.lua` file outside `core/event_bus.lua` and `main.lua` mentions it. No `:subscribe(`, no `:publish(`, no `:addTap(`, no `:removeTap(` call sites exist anywhere else in `states/`, `views/`, `controllers/`, `services/`, or `models/`.

**Finding 3.1 - Severity: Medium. There is no active subscription anywhere, so there is currently no stale-callback leak - but this means the entire cross-cutting event mechanism the engine layer provides is dead code.**
Since nothing subscribes, there is nothing to unsubscribe, and therefore no "handler registered in `enter`/constructor with no matching removal in `exit`" leak to find *for the event bus specifically*. That said, `EventBus.subscribers` and `EventBus.taps` (`core/event_bus.lua:11-13`) are plain module-level tables with no reset/clear API at all - if this bus is ever adopted (the obvious lift-target use case: cross-cutting audio/analytics/achievement hooks reacting to gameplay events), any handler registered from a state's `enter()`/constructor with no corresponding `unsubscribe` in `exit()` would accumulate forever and fire against a state that's no longer current, since `StateMachine:switch()` (Finding 2) has no hook into the bus at all. The module doesn't even expose an `unsubscribe(event, callback)` counterpart to `subscribe` - only `addTap`/`removeTap` are paired; `subscribe` is one-way with no way to remove a specific subscriber short of hand-rolling identity-comparison logic the module doesn't provide. Any future adopter will need to add that API before this is safe to wire into per-state lifecycles.

**Finding 3.2 - Severity: Low. `lib/input_dispatcher.lua`'s `:on()` registrations are the only real pub/sub-shaped subscriptions in the bootstrap layer, and they are correctly one-time/permanent (no leak).**
`InputController:wire()` (`controllers/InputController.lua:19-142`) and the else-branch inline wiring in `main.lua:264-272` both call `dispatcher:on(event, predicate, handler)` exactly once, during `buildGame()`, which itself runs exactly once (`love.load`, `main.lua:280-281`). The handlers are closures over `sm` (`game.state_machine`), a stable object reference that never gets replaced - only its internal `current_state` field changes on `switch()`. So dispatch always routes through the live `sm:keypressed(...)` etc., which internally re-reads `self.current_state` each call (`controllers/StateMachine.lua:60-100`). There is no per-state input subscription/unsubscription anywhere - input routing is a single static table of handlers set up once, not a subscribe-per-state pattern - so there is nothing to leak here. Verified: `dispatcher:on(` appears only in `InputController.lua` (9 call sites) and `main.lua` (7 call sites, the `DEV_HOTKEYS`-off branch), all during the one-time `buildGame()`/`wire()` pass.

**Finding 3.3 - Severity: Info. No other ad hoc pub/sub pattern exists in the bootstrap/state layer.** Searched for `:on(`, `:subscribe(`, `:emit(` beyond the two systems above - the only other `:on(`-shaped API is `InputDispatcher:on` (Finding 3.2), and `PokerEventRegistry`/`UnlockRegistry`/`XpRuleRegistry` are lookup-table registries (register a handler *by kind string*, dispatched once by data-driven key), not observer-pattern subscriptions with a lifecycle to leak - they're populated once at boot (`main.lua:199-233`) and never added to or removed from afterward.

### 4. Input routing

Flow: `love.<event>(...)` (`main.lua:370-377`) -> `Game.input_dispatcher:dispatch(event, ...)` (`lib/input_dispatcher.lua:23-30`) -> first handler whose predicate passes, in registration order -> either a global hotkey handler or the catch-all `sm:<event>(...)` -> `StateMachine:<event>` (`controllers/StateMachine.lua:60-100`) -> `self.current_state:<event>(...)` if the method exists.

**Finding 4.1 - Severity: High (confirmed live in the current build). `Constants.FEATURES.DEV_HOTKEYS` is true in the shipped config (`PROTOTYPE_MODE = false` at `data/constants.lua:19`, `DEV_HOTKEYS = not PROTOTYPE_MODE`), so `InputController:wire()` — not the plain forwarders — is the active path, and its global hotkeys are live for any player in every state.**
`main.lua:259-275`:
```lua
if not Constants.FEATURES.DEV_HOTKEYS then
    -- (plain forwarders, no hotkeys)
else
    g.input_controller:wire()
end
```
With `DEV_HOTKEYS` true, `InputController:wire()` (`controllers/InputController.lua:19-142`) registers F2 (toggle grind<->shove), F6 (reload from disk), F7 (wipe both saves), backtick (debug overlay), F3 (payout breakdown cycle), `-`/`=` (±$1000 bankroll) as global keypressed handlers that fire **before** the catch-all forward to the active state, in every state, unconditionally. Concretely:
```lua
-- controllers/InputController.lua:27-32
dispatcher:on("keypressed",
    function(key) return key == "f2" end,
    function()
        local next_name = (sm:current() == "grind") and "shove" or "grind"
        sm:switch(next_name)
    end)
```
This calls `sm:switch()` directly, bypassing `GrindController:initiateShove()` entirely — no chip-banking (`state.chips = state.chips + state.chips_this_run`), no `state.has_shoved = true`. A player pressing F2 mid-grind jumps straight into `ShoveState:enter()` without the normal SHOVE-button contract; and pressing F2 again mid-gauntlet jumps back to `GrindState:enter()` while `ShoveState.gauntlet` is still set (`ShoveState:exit()` is a no-op, per Finding 2.5) and `_ended_handled` may be `false` with the gauntlet mid-animation. Re-entering shove later (F2 again, or clicking SHOVE) hits `if not self.gauntlet then self.view:beginBuildup(...) end` (`ShoveState.lua:127-129`) — since `self.gauntlet` is still truthy, the buildup is skipped and the state resumes whatever the stale gauntlet's internal state was, with the view's timeline not reset (`resetTimeline()` is only called from the various dismiss/finalize paths, never from a bare F2 exit). This is reachable by any player in the current build just by pressing F2, F6, F7, backtick, F3, `-`, or `=` — none of these are gated behind a debug console or dev-only build flag beyond the single `DEV_HOTKEYS` boolean, which is currently `true`.

**Finding 4.2 - Severity: Medium. Predicate-first dispatch means a global hotkey silently swallows that keypress for every state — including one bound to gameplay.** `-`/`=` (`InputController.lua:112-125`) unconditionally adjust `state.bankroll` by $1000 on every press, in every state, with no state check. If any state ever wants to bind `-`/`=` for its own purpose (e.g. a text-entry or a zoom control), the dispatcher's first-match-wins order (`lib/input_dispatcher.lua:23-30`, `dispatch` calls `h.fn(...); return` on the first passing predicate) means the global handler always wins — the per-state catch-all (registered last, `InputController.lua:132`) never even sees that keypress. This is "swallowed events" and "ordering dependence" exactly as the brief asks about: correctness here depends entirely on registration order in `wire()`, with no way for a state to opt out or claim a key back.

**Finding 4.3 - Severity: Medium. Mouse-button filtering is inconsistent across states — `TitleState` checks `button == 1`, `GrindState`/`ShoveState`/`RoomState` do not.**
```lua
-- states/TitleState.lua:174-175
function TitleState:mousepressed(x, y, button)
    if button ~= 1 then return end
```
`GrindState:mousepressed(x, y, b)` (`states/GrindState.lua:389`), `ShoveState:mousepressed(mx, my, button)` (`states/ShoveState.lua:438`), and `RoomState:mousepressed(x, y, button)` (`states/RoomState.lua:169`) never check `button` before acting — a right-click or middle-click anywhere in grind/shove/room triggers exactly the same handling as a left-click (modal dismiss, SHOVE button, catalog purchase clicks, etc.), since none of the hit-test blocks in those functions branch on `button`. Confirmed by reading all four `mousepressed` bodies in full. Not crashing, but an unintended-input surface: right-clicking the SHOVE button fires `initiateShove()` (Finding 2.4) exactly like a left-click would.

**Finding 4.4 - Severity: High. `love.mousereleased` cannot fire if the button is released outside the window, and there is no `love.focus`/`love.visible` callback to recover from it — confirmed stuck-drag risk on `views/widgets/Slider.lua`.**
```lua
-- views/widgets/Slider.lua (mousepressed / update / mousereleased)
self._dragging = true              -- set on mousepressed on the knob
...
if not self._dragging or not self._rect then return end   -- mousemoved tracks while true
...
function Slider:mousereleased(mx, my, button)
    ...
    self._dragging = false
end
```
LÖVE only delivers `mousereleased` for a release that happens while the window has mouse capture; releasing the button after the cursor has moved outside the window boundary does not fire it by default (no `love.mouse.setGrabbed` call found anywhere in the codebase). `self._dragging` then stays `true` indefinitely, and the slider keeps tracking `mousemoved` even after the button is no longer held once the cursor re-enters the window. `main.lua` defines no `love.focus`, `love.visible`, or `love.mousefocus` callback anywhere (verified: repo-wide search for those three names returns zero hits outside this note) that could force-clear such drag state on window-focus loss — a common mitigation this bootstrap layer has none of. `SettingsModal` (the only consumer of `views/widgets/Slider.lua`, the volume slider) is the concrete reachable case.

**Finding 4.5 - Severity: Low. `love.resize` is handled, but `love.filedropped`, `love.threaderror`, and `love.lowmemory` are simply absent — likely fine for this game (no file-drop UX, single-threaded), noted for completeness per the brief's checklist.** `love.textinput` is present and routed (`main.lua:376`), `love.wheelmoved` is present and routed (`main.lua:377`), `love.quit` is present (see section 6). Only `focus`/`visible`/`mousefocus` are the actually-relevant gaps (Finding 4.4).

**Finding 4.6 - Severity: none (verified correct). Hit-testing consistently uses transformed coordinates.** `love.mouse.getPosition` is globally monkey-patched at module load time (`main.lua:91-95`) to divide by the fit scale and subtract the letterbox offset, so every state's `love.mouse.getPosition()` call (used pervasively for hover/draw-time hit-testing in `TitleState.lua:104`, `RoomState.lua:102`, etc.) already returns base-design-space (1600x900) coordinates. Raw LÖVE mouse-event callbacks (`love.mousepressed/released/moved`, which receive real window-pixel coordinates, not patched by the `getPosition` override) are explicitly converted at the call site before dispatch:
```lua
-- main.lua:373-375
function love.mousepressed(x, y, b)  local s, ox, oy = fitTransform(); Game.input_dispatcher:dispatch("mousepressed",  (x-ox)/s, (y-oy)/s, b)  end
```
So both the polling path (`getPosition`) and the event path (`mousepressed`/`mousereleased`/`mousemoved`) land in the same base-design coordinate space by the time they reach any state or view. No view/state was found bypassing this — all hit-testing reviewed in this section's states (`_btn_rects`, `_shoveButtonRect`, panel hit-boxes) operates directly on the values received from `mousepressed`/`getPosition`, never on raw `love.graphics.getDimensions()`-adjacent window pixels. `love.resize` (`main.lua:379-407`) deliberately re-reads and discards the real `w,h` it's given, substituting the patched (always 1600x900) `love.graphics.getDimensions()` instead (`main.lua:383`), so layout never actually changes shape on a real resize — see section 7 for the consequence of that on font rebuilding.

### 5. Error handling

**Finding 5.1 - Severity: Critical. No `love.errorhandler` is defined anywhere in the codebase, and a confirmed, 100%-reproducible Lua error is reachable from `love.draw()` by pressing SPACE during the shove buildup — root-caused to an undefined global.**

Repo-wide search for `love.errorhandler`/`love.errhand` returns zero hits. `main.lua` never assigns either, so LÖVE falls back to its own built-in default error screen on any unhandled Lua error during `update`/`draw`/any callback. There is no custom "safe" error screen, no crash telemetry hook, and — critically — no save-flush wired into the crash path (see Finding 5.2).

The confirmed crash: `views/ShoveView.lua:399-406`
```lua
function ShoveView:skip()
    -- Buildup-skip: jump to ready-to-deal so the host fires the gauntlet
    -- on its next update tick. Player wanted out of the buildup spectacle.
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        self.phase_t = BUILDUP_TOTAL
        return
    end
```
`BUILDUP_TOTAL` is never declared anywhere in `ShoveView.lua` (verified: the only other occurrence in the file is inside a comment at line 162). Lua does not error on reading an undeclared identifier — it silently resolves to a global lookup that returns `nil`. So `self.phase_t` becomes `nil`. Compare to the field this should almost certainly have referenced: `self.buildup_total` (lowercase, an *instance* field), set from real per-shove chip-arrival timing at `ShoveView.lua:247` (`self.buildup_total = (self.buildup_chips[n] and self.buildup_chips[n].arrive_t or 0)`) and read correctly by that name in `update()`'s own buildup-phase logic at `ShoveView.lua:445` (`if self.phase_t >= (self.buildup_total or 0) then`).

Trigger path, fully traced:
1. Player enters shove; `ShoveState:enter()` calls `self.view:beginBuildup(...)`, phase becomes `"buildup"`.
2. Player presses SPACE. `ShoveState:keypressed` (`ShoveState.lua:394-399`): `if self.view:isAnimating() then self.view:skip(); return end`. `isAnimating()` (`ShoveView.lua:374-379`) returns `true` while `phase == "buildup"`.
3. `skip()` runs the branch above: `phase = "ready_to_deal"`, `phase_t = nil`.
4. Next `love.draw()` frame: `ShoveState:draw()` → `self.view:draw()` → `ShoveView.lua:879-880`: `if self.phase == "buildup" or self.phase == "ready_to_deal" then self:_drawBuildup(W, H) end` — `"ready_to_deal"` still routes into `_drawBuildup`.
5. `_drawBuildup` (`ShoveView.lua:543` onward), first line that touches the corrupted field: `ShoveView.lua:549`: `local fade_t = math.min(1, self.phase_t / BUILDUP_FADE_DURATION)` — `nil / 0.5` → **Lua runtime error: "attempt to perform arithmetic on a nil value (field 'phase_t')"**, thrown from inside `love.draw()`.

Since no `love.errorhandler` is defined, this is caught only by LÖVE's built-in error screen — the entire game session ends there, dropping straight from mid-gauntlet gameplay to a raw traceback screen, on ordinary player input (SPACE to skip the buildup they're specifically invited to skip).

**Finding 5.2 - Severity: High. The autosave path gives at most a 10-second-old save on any uncaught error; nothing flushes on crash.**
`main.lua:315-341` autosaves every `AUTOSAVE_INTERVAL = 10` seconds while in `grind`/`shove` with no modal up. Since `love.errorhandler` isn't overridden, LÖVE's default handler takes over on the Finding 5.1 crash (or any other uncaught error) and does **not** call `love.quit()` — verified by inspecting LÖVE's documented default-errhand behavior combined with the total absence of any `love.errorhandler` override here that could add a save-flush before showing the error screen. So any progress since the last autosave tick (up to 10 seconds of gameplay, including e.g. a runout that just banked chips) is lost the moment the Finding 5.1 crash fires — including the base case, since a shove buildup with no autosave yet ticked (freshly entered from grind) loses whatever bankroll/state changes happened since the last save.

**Finding 5.3 - Severity: none (verified correct, worth recording). Asset and save loading both degrade gracefully — no crash on missing/corrupt files at startup.**
- `services/SpriteLoader.lua:71,97`: `local ok, image = pcall(love.graphics.newImage, item_path)` — a missing/corrupt sprite file doesn't crash `love.load()`.
- `services/SpriteLoader.lua:138,141`: sprite-alias JSON read/decode both wrapped in `pcall`.
- `services/ShaderRegistry.lua:44,59`: shader compilation wrapped in `pcall`; `main.lua:284-288`'s comment confirms this is deliberate ("compile failures log a warning and degrade gracefully (no crash)").
- `services/SaveService.lua:57` (`local ok, decoded = pcall(json.decode, raw)`) plus explicit handling for a missing file (`:read`, line 52-54, returns `nil, "no save"`), a decode failure (line 58-60), and a version mismatch (line 61-63) — all three fall through to `nil`, and `GameState:new(saved)` (`main.lua:187`) is written to accept `nil`/partial data and produce a fresh game. No pcall wraps `GameState:new` itself, so if `GameState:new`'s own field-by-field `applySaved` logic were ever to throw on a structurally-valid-but-semantically-odd save (not verified either way — out of this section's file list), that would still be an uncaught `love.load()`-time crash with no error handler to soften it, per Finding 5.1's absence.

**Finding 5.4 - Severity: Low (latent, currently dormant). `SaveService`'s version-mismatch path is a silent full wipe with no migration, which is at odds with the project's "save back-compat is required" rule if it's ever actually exercised.**
`services/SaveService.lua:61-63`: `if decoded.version ~= VERSION then return nil, "version mismatch" end`. `Constants.SAVE.VERSION = 1` (`data/constants.lua:157`) and has apparently never been bumped — the codebase's actual migration mechanism is field-level, inside `GameState` (`models/GameState.lua:327-333`, the `deck_overhaul_migrated` one-time-flag pattern the project's own docs reference), not this file-version check. So this path is currently dead/unexercised, but if `VERSION` is ever incremented as a "proper" migration trigger, every existing player save silently resets to a fresh game with zero warning to the player and zero migration attempt — a full data-loss path sitting dormant in the persistence layer, worth flagging even though nothing currently triggers it.

**Finding 5.5 - Severity: none found. No `pcall` in the reviewed bootstrap/state files swallows an error silently in a way that would hide a real bug.** All `pcall` usages found in this section's file scope are narrowly targeted at genuinely-expected-to-fail I/O (asset load, shader compile, JSON decode) and each checks `ok` before proceeding — none of them `pcall`s a broad chunk of gameplay logic and drops the error on the floor.

### 6. Quit and shutdown

`main.lua:409-421`:
```lua
function love.quit()
    if Game then
        HandAnalytics.flush(Game.state, Game.settings and Game.settings.analytics_consent)
        local current = Game.state_machine and Game.state_machine:current()
        if current == "grind" or current == "shove" then
            local state = Game.state
            Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
        end
    end
end
```

**Finding 6.1 - Severity: High (confirmed). `love.quit` does NOT flush unconditionally, contradicting its own neighboring comment in the same file.**
`main.lua:320-322` (the autosave-timer comment block) states: *"Counter resets on each save; love.quit flushes unconditionally so anything not yet persisted lands on exit."* The actual `love.quit` body above is gated by `if current == "grind" or current == "shove" then` — it is explicitly conditional, not unconditional. Concretely: `RoomState` (reachable via TAB from `GrindState`, `GrindState.lua:325-327`) is a *third* gameplay state holding the exact same live `Game.state` (bankroll, tables, etc.) as grind/shove, but `current == "room"` fails both branches of the `if`, so **quitting while in the room view skips the save entirely** — any progress made in grind since the last 10-second autosave tick, then carried into room, then quit from there, is lost. This is a direct, verifiable contradiction between the code and the comment sitting nine lines above it in the same file, and a real data-loss path: `RoomState` has no autosave either (the autosave gate at `main.lua:332` uses the identical `cur == "grind" or cur == "shove"` condition), so room is a save-blind-spot on both the periodic and the quit path simultaneously.

**Finding 6.2 - Severity: Medium (partially unverified — web-runtime behavior, `build/` out of scope per audit brief). `love.quit` is unlikely to run at all on the web/itch export when the player simply closes the browser tab, and even the comment elsewhere in `main.lua` acknowledges the web save path is async and can stall.**
LÖVE's web target (love.js/Emscripten) does not reliably invoke a game's `love.quit` Lua callback on a browser tab close/refresh — the JS `beforeunload`/`unload` events fire in the host page, not inside the Emscripten main loop, and by the time any unload handler could run, the Lua VM's frame loop has typically already been torn down or is about to be with no guaranteed final tick. This is a well-known characteristic of Emscripten-compiled apps generally, not something this codebase can control from `main.lua` alone. The codebase's own comment corroborates awareness of exactly this class of problem from a different angle — `main.lua:317-321` (autosave-skip-during-modal comment): *"during a multi-minute post-bust catalog browse the autosave was firing every 10s and queueing JSON writes to Emscripten's IDBFS, then stalling the frame when the queue flushed on resume to grind."* That confirms `love.filesystem.write` on the web build goes through an async IndexedDB-backed layer (IDBFS) whose writes can queue and stall — meaning even in the best case where `love.quit` *did* fire on tab close, a `save_service:saveAll()` call issued from inside it is not guaranteed to complete (or even fully enqueue) before the browser actually discards the page. Net effect for the web/itch build: the periodic 10-second autosave (`main.lua:332-340`) is the *only* save mechanism a web player can actually rely on — the quit-time safety net this codebase's own comments assume exists is unlikely to fire, and likely wouldn't complete synchronously even if it did. (Marked partially unverified because confirming actual love.js unload behavior would require running the compiled web build, which is out of this audit's scope per the brief's instruction to ignore `build/`.)

**Finding 6.3 - Severity: Low. `QUIT_DISABLED` only gates the in-game Settings modal's Quit button — `TitleState`'s "Exit" button is not gated at all, and calls `love.event.quit()` unconditionally on every build, including the web build the flag exists to protect.**
```lua
-- data/constants.lua:64-67
-- Disable the Settings "Quit" button. The web/love.js build can't quit a
-- browser tab — love.event.quit() hard-errors the canvas — so the
-- prototype (web) build greys Quit out with a "disabled for web" tooltip.
QUIT_DISABLED     = C.PROTOTYPE_MODE,
```
```lua
-- states/TitleState.lua:149-156
exit = function(self)
    self._confirm = ConfirmDialog:new{
        prompt        = "Quit the game?",
        danger        = true,
        confirm_label = "Quit",
        on_confirm    = function() love.event.quit() end,
    }
end,
```
`views/SettingsModal.lua:312-314` correctly checks `Constants.FEATURES.QUIT_DISABLED` and disables/greys that button on a `PROTOTYPE_MODE` (web) build. `TitleState.lua`'s "Exit" button (title screen, present on every build) has no equivalent check — it always wires `love.event.quit()` to its confirm dialog, regardless of `QUIT_DISABLED`. On a web build, clicking Start → back to Title (not reachable normally, but Title is the boot screen itself, always visited first) → Exit → confirm would call `love.event.quit()` and, per the `QUIT_DISABLED` comment's own claim, "hard-error the canvas" — precisely the failure mode the flag exists to prevent, left open on the one screen every web player sees first.

**Finding 6.4 - Severity: Medium. In-flight shove-buildup/gauntlet animation state is not preserved across a quit, and isn't distinguished from "safe to quit" by the save-gating logic.**
`love.quit`'s `current == "shove"` branch saves `state:serializeMeta()`/`serializeRun()` unconditionally whenever the player is in the shove state, with no check for whether a gauntlet is mid-animation, mid-buildup, or sitting on an unresolved `prestige_modal`/`catalog_modal`/`deck_select_modal` (the entire post-bust ritual, `ShoveState.lua:53-58`). Since `Gauntlet`'s in-memory model state (`self.gauntlet`, `ShoveState.lua:52`) isn't part of what `GameState:serializeRun()` persists (verified by inspection of the state referenced — `state:serializeMeta()`/`serializeRun()` are `GameState` methods, not `ShoveState` fields), a quit mid-gauntlet-animation saves whatever `Game.state` fields the animation has *already committed* (e.g. `state.chips_this_run` from a completed runout) but drops the in-flight cinematic/animation entirely — reasonable for a resumable idle game (the F6 reload path explicitly handles exactly this via `ShoveState:fullReset()`, `InputController.lua:52-66`), but it does mean a player who quits mid-buildup (before any runout resolves) keeps whatever `state.bankroll` change the cash-out step already applied (`ShoveState.lua:107-108`, "every table's current stack returns to bankroll... Run only on a fresh gauntlet entry") with no gauntlet outcome to show for it on reload — not a crash or data-loss bug, but worth flagging as an asymmetric commit point: the cash-out mutates real persisted state before the gauntlet that's supposed to justify it has even started.

### 7. The fitTransform / DESIGN_W/H scaling

```lua
-- main.lua:75-95
local BASE_W, BASE_H = 1600, 900
local _realDimensions = love.graphics.getDimensions
local _realGetPos     = love.mouse.getPosition
local _frameCanvas, _scaleShader

local function fitTransform()
    local ww, wh = _realDimensions()
    if ww == 0 or wh == 0 then return 1, 0, 0 end
    local s = math.min(ww / BASE_W, wh / BASE_H)
    return s, (ww - BASE_W * s) / 2, (wh - BASE_H * s) / 2
end

love.graphics.getDimensions = function() return BASE_W, BASE_H end
love.graphics.getWidth      = function() return BASE_W end
love.graphics.getHeight     = function() return BASE_H end
love.mouse.getPosition = function()
    local x, y = _realGetPos()
    local s, ox, oy = fitTransform()
    return (x - ox) / s, (y - oy) / s
end
```

**Finding 7.1 - Severity: none (verified correct). The transform math itself is correct.** `fitTransform()` computes a uniform min-scale fit (`math.min(ww/BASE_W, wh/BASE_H)`) with symmetric centering offsets — standard, correct letterboxing/pillarboxing math. The `ww == 0 or wh == 0` guard (minimized window) returns an identity transform rather than dividing by zero. `love.mouse.getPosition` is patched once, at module-load time, before `love.load` even runs, so every consumer (including code that runs before `buildGame()`) already sees corrected coordinates. `love.mousepressed/released/moved` (raw window-pixel event callbacks, not covered by the `getPosition` patch since LÖVE passes those as call arguments, not through `getPosition`) are separately, correctly converted at each call site (`main.lua:373-375`) using the identical `fitTransform()` math. Verified no view/state bypasses this — see Finding 4.6.

**Finding 7.2 - Severity: Medium (confirmed, dead-weight not correctness). `love.resize` discarding the real window size means `FontService.rebuildInto` and all four `setScale`/`configureFromFonts` calls on every resize event are guaranteed no-ops — contradicting the adjacent comment's stated intent.**
```lua
-- main.lua:379-407
function love.resize(w, h)
    if not Game then return end
    -- The game always lays out at the base resolution; the canvas+shader handle
    -- fitting to the window. Use the (fixed) base dims, ignore the window size.
    w, h = love.graphics.getDimensions()
    if Game.viewport then
        Game.viewport.w, Game.viewport.h = w, h
    end
    local ThemeData = require("data.theme")
    FontService.rebuildInto(Game.fonts, ThemeData.font, w, h)
    Game.ui_scale = FontService.layoutScale(w, h)
    require("views.Chips").setScale(Game.ui_scale)
    ...
```
Because `love.graphics.getDimensions` was globally monkey-patched at module load (`main.lua:88-90`) to always return `BASE_W, BASE_H` (1600, 900) — before `love.resize` ever runs — the reassignment `w, h = love.graphics.getDimensions()` at line 383 always yields exactly `1600, 900`, regardless of the real `w, h` LÖVE passed into the callback. Tracing `FontService` (`services/FontService.lua`): `fontScale(1600, 900)` = `floor(min(1600/1280, 900/720))` = `floor(1.25)` = `1` (constant, always); `layoutScale(1600, 900)` = `min(1.25, 1.25)` = `1.25` (constant, always). So `Game.ui_scale` is a fixed `1.25` for the entire life of the process, and `FontService.rebuildInto` — which disposes the old font objects and rasterizes four fresh `love.graphics.newFont` atlases (`services/FontService.lua:49-59`) — runs on *every single resize event* only to rebuild bit-for-it fonts at the exact same integer size. This directly contradicts the block comment at `buildGame()` (`main.lua:128-130`): *"Fonts scale as a smooth float with the window (antialiased TTF, so any size rasterizes cleanly). love.resize rebuilds the table in place at the new window size so the atlas is always rasterized at its display size."* That comment describes a pre-fixed-canvas architecture (dynamic per-window font rasterization) that the later `BASE_W/BASE_H` + sharp-bilinear-shader system (also in this same file) has fully superseded and silently neutralized — the comment is now describing behavior that cannot occur. Consequence: every resize does real, non-trivial wasted work (font atlas rebuild + 4 module-level `setScale`/`configureFromFonts` calls touching `Panel`, `ComponentRenderer`, `CatalogModal`, `SettingsModal`, `Chips`, `ConfirmDialog`, `Slider`) for zero visible effect, and a future maintainer reading the `buildGame()` comment would reasonably but incorrectly conclude the game rasterizes fonts at native per-window resolution.

**Finding 7.3 - Severity: none found. No view bypasses the fixed-canvas + fitTransform system.** All `love.graphics.getDimensions/getWidth/getHeight` calls throughout the states reviewed in this section (`TitleState.lua:65,86`, `RoomState.lua:46,170`, `CreditsState.lua:34`, plus `GrindState`/`ShoveState`'s views) resolve through the patched functions, so they all consistently see the fixed `1600x900` base space — there is no code path in the reviewed files that queries a "real" window dimension for layout purposes (the only place the real window size is read at all is `fitTransform()`'s own `_realDimensions()` call, kept as a private local specifically so nothing else can reach it directly).

**Finding 7.4 - Severity: Low. `_frameCanvas`/`_scaleShader` are lazily created inside `love.draw()` on first call rather than in `love.load()`, and are never recreated on resize despite depending on nothing that changes — correct today, fragile if that assumption ever changes.**
```lua
-- main.lua:344-349
function love.draw()
    if not _frameCanvas then
        _frameCanvas = love.graphics.newCanvas(BASE_W, BASE_H)
        _frameCanvas:setFilter("linear", "linear")
        _scaleShader = love.graphics.newShader(SHARP_BILINEAR)
    end
```
Since `BASE_W`/`BASE_H` are compile-time constants, this canvas never needs to be recreated for the life of the process, so the lazy-init-once pattern is correct as written (no resize handler recreates it, and none is needed). It's just worth noting for future maintainers: if `BASE_W`/`BASE_H` were ever made configurable (e.g. an aspect-ratio setting), this canvas would need an explicit recreate-on-change path that doesn't currently exist anywhere.


---

## data/ content integrity and cross-file referential consistency


### Balance-data sanity — data/balance.lua + data/catalog.lua Phase-1 derivation

**CRITICAL — data/catalog.lua:1004-1025 (Phase-1 derivation loop) overwrites every hand-authored `shove_rate_add` value with one flat constant, destroying the band-tier curve.**

`data/catalog.lua` authors 47 distinct `shove_rate_add` values across the catalog, deliberately increasing by band (Band A ~0.008–0.014, Band C ~0.010–0.014, Band D ~0.014–0.022, per the band-header comments at lines 117/323/574/833). At module load, the appended loop replaces every one of them:

```lua
-- data/catalog.lua:1006-1025
for _, item in ipairs(items) do
    if not item.run0 and item.phase ~= "system" and item.id ~= "unlock_ultra" then
        ...
        if item.effects then
            for _, eff in ipairs(item.effects) do
                if eff.kind == "shove_rate_add" then
                    eff.value = Balance.getItemShoveRate(item.id)   -- <-- clobbers authored value
                    found_shove = true
                end
            end
        ...
```

`Balance.getItemShoveRate` (data/balance.lua:51-56) returns the same `K_SHOVE_PER_ITEM` constant for every item (only `poker_poster`/`no_poster_handicap`/`unlock_ultra` are exempt, and those are already skipped by the outer `if`). Verified at runtime:

```
branded_hat  authored 0.010 -> post-derivation 0.0077745383867833
wall_clock   authored 0.014 -> post-derivation 0.0077745383867833
```

Every non-exempt item in the 48-item live catalog now contributes the identical ~0.00777 shove-rate bump regardless of band, price, or hand-authored value. The `-- Locked Design Inputs` comment block and all 47 authored per-item constants (`0.005` through `0.022`) are now dead weight — the values are read, then immediately discarded on every load. If this was intentional ("replace authored curve with derived flat rate"), the 47 authored literals should be deleted, not left in the file implying they're live. If unintentional, this is a real, currently-shipping content bug: the catalog's hand-tuned pacing curve does nothing.

**HIGH — data/balance.lua:19,23,30 — `ACT1_ITEM_COUNT = 49` does not match the actual Act-1 catalog band, and the derivation comment is stale, producing a `K_SHOVE_PER_ITEM` about half the size the design math implies.**

```lua
-- data/balance.lua
Balance.ACT1_COMPLETION_AT_WIN = 0.70     -- fraction of Act 1 catalog owned at win (~18 of 25)
...
Balance.ACT1_ITEM_COUNT        = 49
...
Balance.ITEMS_AT_WIN           = Balance.ACT1_ITEM_COUNT * Balance.ACT1_COMPLETION_AT_WIN  -- 25 * 0.70 = 17.5
```

The comment says `25 * 0.70 = 17.5` (matching the `~18 of 25` note above it), but the code uses `ACT1_ITEM_COUNT = 49`, giving `49 * 0.70 = 34.3`, not `17.5`. Neither `25` nor `49` matches reality:

- Counting `data/catalog.lua`'s actual "Act 1" bands (Band A + Band B, lines 117-573, i.e. everything before "BAND C — Act 2, deck era"): **26 items** (including `poker_poster`; the `no_poster_handicap` system phantom is a 27th if counted).
- `49` is actually the *whole catalog minus the one hidden system entry* (50 total items - 1 `phase="system"` entry = 49) — i.e. `ACT1_ITEM_COUNT` looks like it was repurposed to mean "total real catalog size" but never renamed, and the `ACT1_COMPLETION_AT_WIN` comment/derivation still talks about "Act 1 catalog owned at win" and "25".

Verified with the actual constants:
```
ACT1_ITEM_COUNT      = 49
CATALOG_TARGET_ACT1  = 0.2666...
ITEMS_AT_WIN          = 34.3          (comment claims 17.5)
K_SHOVE_PER_ITEM      = 0.0077745...  (comment-implied value would be 0.01524)
Using actual Act-1-band count (26 * 0.70 = 18.2): K = 0.014652...
```

So the live `K_SHOVE_PER_ITEM` (0.00777) is roughly **half** of what the design intent in the comments implies (0.0152) and what the actual Act-1 item count would produce (0.0147). Combined with the previous finding (this constant now overwrites every catalog item's shove rate), Act 1's whole shove-rate pacing is derived from a wrong item count and is ~2x weaker than authored/intended.

**Severity note**: both of the above compound — even if `ACT1_ITEM_COUNT` were fixed to the correct Act-1 band size, the flat-overwrite bug (previous finding) would still discard the band-tier curve. Fixing the count alone does not fix the destroyed curve.

### Cross-file id references

Verified programmatically (`lua -e` loading the real modules from repo root with `package.path = "./?.lua;"..package.path`).

**Clean — catalog.lua internal self-references.** Every `requires` and `removed_by` field in `data/catalog.lua` (e.g. `box_of_mice.requires = "cursor_pool"`, `poker_poster` removed via `no_poster_handicap.removed_by = "poker_poster"`) resolves to a real catalog id. No dangling references.

**Clean — data/catalog_pages.lua item lists.** All 49 non-hidden catalog item ids referenced across the 8 departments resolve to real `data/catalog.lua` ids; zero dangling entries, zero items listed in two departments at once, and zero visible items missing from every department (would silently fall to the "&c." department, which the file's own header says is by design — didn't happen here). The department comment at catalog_pages.lua:8 ("seventeen headings for forty-nine items") independently corroborates that **49 is the whole visible catalog size** (50 items minus the 1 hidden `phase="system"` phantom), not an "Act 1" item count — reinforcing the `data/balance.lua:23` finding above (`ACT1_ITEM_COUNT = 49` is actually total-catalog-size, mislabeled and used with Act-1-scoped completion math).

**Clean — hint anchors (data/hints.lua) vs `services/AnchorRegistry`.** All static anchor names hints reference (`btn:help`, `btn:quick_reset`, `btn:catalog`, `btn:shove`, `cell:tied`, `cell:focus`, `cell:shove`, `btn:cash_out`) match a literal `AnchorRegistry.set(...)` call in `views/GrindView.lua`. The dynamic ones (`add_table:s001:six_max`, `add_table:s002:six_max`, `buy_runup_sharper_reads`, `buy_runup_focus`, `ev:1..4`, `tied:1..4`, `chip_badge:banked`) all resolve too, built from live ids at draw time (`"add_table:"..stake.id..":"..gtype_id` in GrindView.lua:551, `"buy_runup_"..up.id` in GrindView.lua:852, `"tied:"..idx` / `"ev:"..idx` in TablePanel.lua:1537/1589, `badge_anchor` read by `views/ComponentRenderer.lua:437-441`). No dangling anchor.

**Clean — hint stake/run-upgrade id references.** `data/hints.lua`'s `can_afford_stake`/`stake_table_open` conditions name `"s001"` and `"s002"` (both real `data/stakes.lua` ids); `can_afford_run_upgrade { id = "sharper_reads" }` names a real `data/run_upgrades.lua` id.

**Clean — IconText `{...}` markers used in data-file copy.** Every literal token found across `data/*.lua` (`{chip}`, `{arrow}`, `{small}` `{medium}` `{large}` `{stack}` and their `{l:...}`/`{w:...}` variants) is a token `views/IconText.lua` actually implements (`tokenWidth`/`drawToken`, backed by `views/TierGlyph.lua`'s `small/medium/large/jackpot` + `stack→jackpot` alias). The `{icon}` occurrences in `data/hints.lua:16,22` and `data/run_upgrades.lua:17` are doc-comment placeholder text describing the *mechanism*, not live data strings — no actual `{icon}` token ships. Note `data/icons.lua`'s 8 keys (`chip achip focus shove sharper_reads pot_control cursor cursor_speed`) are a **separate namespace** consumed only via `run_upgrades.lua`'s `icon = "..."` field (all 5 references — `sharper_reads`, `pot_control`, `cursor`, `cursor_speed`, `focus` — resolve), not via `{...}` markers; no confusion found in the data but worth knowing when adding new icons.

**Clean — chip denomination cross-refs (data/chips.lua).** `full_palette` lists indices 1-33 with no gap, no duplicate, no out-of-range entry, and matches `#denominations` (33) exactly. Every one of `data/stakes.lua`'s 10 stake ids (s001-s010) has a `stake_palettes` entry, each exactly 4 indices, all in range.

**No shader-name references found.** No `data/*.lua` file names a shader by string key (only descriptive comments mention "shader" conceptually in `data/feedback_intensity.lua:5` and `data/theme.lua:16`) — nothing to cross-check; shader dispatch isn't yet data-driven.

**MEDIUM — data/room_layout.lua covers only 9 of 49 live catalog items; the Room screen is a real, reachable player feature, not a dev-only tool, so 40 owned items never visually appear there.**

`data/room_layout.lua` (`views/RoomView.lua:82-99`) is read by `states/RoomState.lua`, which is reached via the top-bar `btn:room` button (`views/GrindView.lua:1567`) in normal play — it is not gated behind `DEV_HOTKEYS` or any feature flag. `RoomView:draw` only places items present in `Layout` (`data/room_layout.lua`) and, outside editor mode, only draws them `if owned` (`views/RoomView.lua:508-531`). Verified count:

```
data/room_layout.lua entries: 9  (poker_poster, branded_hat, whiteboard, lava_lamp,
                                   self_help_book, mirror, energy_drink, stress_ball,
                                   lucky_coin — all Band A)
live catalog items (48, excl. the 1 hidden system phantom minus TUTORIAL-stripped run0): 49 candidates
  present in room_layout: 9
  missing:                40
```

`data/catalog.lua`'s own header states "THE RULE — This is a catalog of OBJECTS FOR A ROOM... Every entry is a thing a department store would ship in a box" — but buying any of the 40 unplaced items (all of Band B/C/D: `worry_stone`, `rubber_duck`, `headphones`, `medical_kit`, `bathtub`, `fridge`, `toaster`, `the_sink`, `microwave`, `dishwasher`, `fire_extinguisher`, `water_cooler`, `gaming_chair`, `second_monitor`, `headset`, `wall_clock`, `projector`, `big_tv`, `calculator`, `ring_binder`, `pen`, `filing_cabinet`, `copy_machine`, `supply_closet`, `cursor_pool`, `first_cursor`, `mouse_pad`, `tireless_assistants`, `dogs_playing_poker`, `plastic_trophy`, `engraved_plaque`, `study_chart`, `tip_jar`, `pocket_cash`, `free_sit`, `discount_sits`, `punch_card`, `glass_door`, `unlock_ultra`, `sticky_notes`) has zero visual effect in the Room screen — no crash, but a silently incomplete feature the player can walk into and notice directly. `data/room_layout.lua`'s own header ("Edited via the in-game Room Editor and saved/pasted here") suggests this is WIP content rather than a code bug, but it's real enough to flag: the Room screen currently only furnishes ~18% of the catalog.

### Schema consistency within each data file

Enumerated programmatically (per-file field presence/type histogram over every top-level record).

- stakes.lua: 10 records, all 16 fields present on all 10 except anti_chip_award (only s007-s010, High/Ultra band; every consumer treats it as "or 0" - correctly optional).
- bankroll_tiers.lua: 9 records, uniform threshold/mult/label, no gaps.
- decks.lua: 12 records, uniform except unlock (11/12 - "standard" is the un-gated starter, correctly absent).
- run_upgrades.lua: 5 records, uniform core fields; requires/requires_hide only on the two cursor upgrades (correct - only those gate on cursor_pool); fill_scaled/tooltip_metric only on the two fill-based upgrades (correct, documented).
- hints.lua: 15 records, uniform id/title/anchor/text/trigger/done; sticky only on 3 (documented opt-in); anchor/text are string on 8 records and array-of-string on 7 - both shapes explicitly supported by the schema doc and by views/HintView.lua/AnchorRegistry, not an inconsistency.
- game_types.lua: 4 records; fields like chip_stack_table, starting_stack_bb, auto_deal, jackpot_emerge appear on only 1-2 of 4 - all documented MTT-only/Zoom-only in the file header. Not a defect.
- effects.lua (.kinds): 57 records, uniform description/value_shape/affects on all 57; one entry carries an extra "scale" field (intentional annotation).
- sounds.lua: 26 records. "file" (singular, 2/26) vs "files" (plural array, 24/26) - both branches explicitly handled in services/SoundService.lua:158-162 (entry.files -> random pick, elseif entry.file -> direct play); "layer" (3/26) is a documented optional secondary-sound sub-entry, also correctly consumed at SoundService.lua:166. Not a bug.
- chips.lua: hash of 5 named tables. Denomination ladder (33 entries), stake_palettes (10, one per stake, all length-4, all indices in range), full_palette (33, exact 1-33 cover, no gap/dup), tier_chip_target/tier_burst_cap (4 tier keys each, matching pot_tiers.lua naming) - internally consistent, verified programmatically.
- opponent_names.lua: 50 records, flat string array, all 50 unique.
- theme.lua: order = {"room","shove"} both present as keys under palettes; default = "room" present; no palette key missing from order and vice versa.

No missing-required-field, wrong-typed-field, or genuinely inconsistent-shape entries found once each file's own documented optional-field rules are applied. The apparent "sparse field" cases above (game_types.lua, run_upgrades.lua, decks.lua, hints.lua) are all intentional per-file design, not schema drift.

**LOW - data/run_upgrades.lua:38 and :78 - stale per-item level-count comments describe an older, shorter cost ladder than the one that actually ships.**

data/run_upgrades.lua:38 (Sharper Reads) says "18 levels; reaches T1-T5 fully, 60% of T6." but max_level = 29. data/run_upgrades.lua:78 (Pot Control) says "14 levels; reaches T1-T4 fully, 40% of T5, none of T6." but max_level = 29. Both costs arrays are correctly sized to 29 (verified #costs == max_level for all 5 upgrades, no array/max_level mismatch), so this is not a runtime bug - but the level-count and tier-coverage claims are leftover from before the ladder was extended to 29 levels each, and will mislead the next balance pass the same way the balance.lua "25 * 0.70 = 17.5" comment did. Same drift pattern, different file.

### Duplicate ids

Checked programmatically within and across catalog.lua, decks.lua, stakes.lua, run_upgrades.lua, bankroll_tiers.lua, game_types.lua, hints.lua: zero duplicate ids, either within a single file or across files. Also manually scanned the full sorted cross-file id list for case-only or near-typo collisions (e.g. cursor vs cursor_pool vs cursor_speed, focus vs focus_overload) - all distinct, legitimate ids living in non-colliding namespaces (deck ids, catalog ids, run-upgrade ids, and hint ids are never looked up against each other). No finding here.

### Ordering assumptions

- data/stakes.lua: verified the array's ipairs position exactly matches its id (stakes[1].id == "s001" through stakes[10].id == "s010"), which models/shove_rate.lua's lookupBracket and models/hint_rules.lua's bankroll_tier both rely on via straight ipairs walks. Consistent, not a bug.
- data/bankroll_tiers.lua: threshold is strictly increasing across all 9 rows (0, 2, 10, 100, 1000, 10000, 100000, 1000000, 10000000) and mult is monotonically non-decreasing (1,1,2,3,4,5,6,7,8); models/shove_rate.lua lookupBracket assumes exactly this via a single forward ipairs scan with a break on overshoot - correct as authored.
- **MEDIUM - data/bankroll_tiers.lua's ladder plateaus at $10,000,000 (mult=8) while data/stakes.lua's buy-ins run to $100,000,000,000 (Ultra, s010).** models/shove_rate.lua:56 (`if not upper then return lower.mult end`) means any bankroll above the last row's threshold gets the same flat mult = 8 forever - there is no row for the $10M-$100B range the High band (s007-s009, buy-ins up to $100M) and Ultra (s010, buy-in $100B) actually reach. The file's own header comment claims "T7+ extend the curve past the stakes ladder so endgame grinding past $1M still pushes shove rate upward" - true only up to $10M, then the climb stops entirely for the rest of the game. Given the neighboring stakes.lua comments mark the High/Ultra bands "PLACEHOLDER numbers - balance is a later pass," this is likely known-unfinished rather than a fresh bug, but it means the shove-rate formula is currently flat for the entire High/Ultra/Act-3 portion of the game.
- data/mtt_hand_count.lua / data/mtt_bust_pacing.lua / data/mtt_finish_dist.lua: all keyed [1]..[8] (finish position) or naked/capped; contiguous integer keys from 1, so ipairs-safe despite being written as explicit [N] = ... hash syntax. Verified no gap. Not a bug.
- data/pot_tiers.lua / data/feedback_intensity.lua / data/chips.lua's tier tables: all name-keyed (small/medium/large/jackpot), never iterated by numeric order anywhere consumers were checked; no ordering assumption exists to violate.

### Copy in data files (literal "chips", em-dashes, filler)

- No player-facing string uses the bare word "chips." Every hit for chips/chip in player-visible fields (data/catalog.lua effect_text/unlock.text, data/hints.lua text) already uses the {chip} marker (e.g. "{chip} banked", "First {chip} bounty each run pays +1."). The only bare-word hits are internal snake_case condition/effect kinds (total_chips_banked, chips_this_run) and code comments - not copy.
- NIT - data/stakes.lua:233 - name = "ULTRA - no limit" (em-dash) contains an em-dash. name is explicitly documented at stakes.lua:33 as "blind-structure descriptor (data doc; not rendered)" and confirmed by grep that no view/controller reads stake.name (only display_name, which is clean: "ULTRA"). Not player-facing, so not a real violation of the house style rule - flagged only because it's the one em-dash found anywhere near player-facing stake data, in case name ever does get surfaced.
- Every other em-dash found in data/*.lua (effects.lua description fields, game_types.lua/theme.lua comments) is inside a -- code comment or an internal-only doc field (data/effects.lua's Effects.kinds[...].description, read only by models/GameState.lua for dev-time validation, never rendered) - out of scope for the player-facing copy rule.
- No filler-word hits ("this hand", "a fresh", "genuinely") found in any player-facing text/effect_text/description field scanned.

---

## Tooling, build pipeline, simulator, testing, docs, and the uncommitted working tree

### 1. The uncommitted working tree, as a code review

Four files sit dirty in the working tree: `data/catalog.lua` (+26/-0), `services/FloatingTextSystem.lua` (mixed, net small), `views/CatalogModal.lua` (+13/-8), `views/widgets/Sticker.lua` (+203/-59, plus the untracked `data/balance.lua` and `sim/` already covered by the lead auditor).

#### `data/catalog.lua` -- Balance derivation loop (+26)

**Critical -- `data/` is no longer logic-free; `data/balance.lua` defines functions, a direct, grep-confirmed violation of Rule 3.**
`data/catalog.lua:1004` does `local Balance = require("data.balance")`, and `data/balance.lua` defines three functions:
```
data/balance.lua:38:function Balance.getItemCost(authored_cost)
data/balance.lua:51:function Balance.getItemShoveRate(item_id)
data/balance.lua:61:function Balance.getChipsPerRun(act1_spend)
```
The project's own mandated audit is `rg "^function|require\(['\"](services|models|controllers|views|states)" data/ --type lua` -> must be empty. Running it now returns exactly these three hits. `data/` is documented as "pure tables, logic-free" (RULES.md rule 3) -- this is a real, not theoretical, regression, and it is the one piece of this diff a strict architecture review must block on.

**Medium -- the derivation loop itself, `data/catalog.lua:1004-1027`, embeds a full mutation pass (loops, conditionals, `table.insert`) at module load time inside a data file:**
```lua
local Balance = require("data.balance")

for _, item in ipairs(items) do
    if not item.run0 and item.phase ~= "system" and item.id ~= "unlock_ultra" then
        item.authored_cost_chip = item.authored_cost_chip or item.cost_chip
        item.cost_chip = Balance.getItemCost(item.authored_cost_chip)
        ...
        if not found_shove then
            table.insert(item.effects, 1, { kind = "shove_rate_add", value = Balance.getItemShoveRate(item.id) })
        end
    end
end
```
This is exactly the shape rule 3 exists to prevent (business logic, not tables, living in `data/`). The file already carries one narrow, explicitly-justified exception a few lines above (`data/catalog.lua:998-1002`, the `Constants.FEATURES.TUTORIAL` strip), whose own comment says "the only branch in this file" (`data/catalog.lua:995-997`) -- that comment is now false, and stale. This derivation belongs in a loader/service (e.g. a `CatalogLoader` in `models/` or `services/` invoked at startup), not inlined in the data table file.

**Low/Nit -- dead branches: `Balance.getItemShoveRate`'s special-cases for `poker_poster` and `no_poster_handicap` are unreachable from this call site.** Both items have `run0 = true` (`data/catalog.lua:100`, `data/catalog.lua:123`), so the enclosing loop's `not item.run0` guard (`data/catalog.lua:1008`) already excludes them before `Balance.getItemShoveRate(item.id)` is ever called with those ids. Harmless, but signals the derivation wasn't checked against the data it runs over.

**Observation -- currently a no-op at today's settings.** `Balance.RUN_MINUTES = 20` (`data/balance.lua:15`) makes `time_scale = RUN_MINUTES / 20.0 = 1.0`, so `getItemCost` returns `math.floor(authored_cost + 0.5)` for every item, i.e. the authored costs are unchanged today (rounding aside). The `shove_rate_add` rewrite, however, IS live: every non-run0/non-system/non-ultra item's `shove_rate_add` effect gets forcibly overwritten to the single constant `Balance.K_SHOVE_PER_ITEM ~= 0.01524` (`data/balance.lua:29`), discarding whatever per-item value was hand-authored in the catalog entry itself (e.g. `branded_hat`'s authored `0.012` at `data/catalog.lua:139` gets silently replaced). If that's intended (uniform per-item shove contribution), fine -- but it means every hand-authored `shove_rate_add` value throughout `data/catalog.lua` is now dead weight, misleading anyone reading the catalog file directly.

**Idempotence:** the loop guards re-entry correctly (`item.authored_cost_chip = item.authored_cost_chip or item.cost_chip`, `found_shove` check before insert), so repeated `require` calls (Lua caches modules, but a hot-reload path that clears `package.loaded` would re-run this) don't compound. Good defensive detail.

**Verdict: do not commit as-is.** The `data/balance.lua` function-definitions issue is a clear rule violation that should be fixed before this lands (move the arithmetic into a service/loader that reads `data/balance.lua` as pure constants, or accept the rule needs an explicit carve-out and get that carve-out written into RULES.md/the audit grep). The loop's correctness looks sound; the placement does not.

#### `services/FloatingTextSystem.lua` -- half-finished debug edit, breaks table-persisted floaters (+/-20 net)

**High -- `services/FloatingTextSystem.lua:78-95`: the table-attached ("persist at the table") alpha branch has been commented out in place, silently collapsing two behaviors into one and leaving dead, unreachable code:**
```lua
78          if tbl then
79          --     -- Table-attached: NO fade at all -- stays fully opaque
80          --     -- while it rises, then freezes at its final position.
81          --     if tbl.state == "idle" and progress >= 1.0 then
82          --         -- Freeze: clamp progress, hold timer alive.
83          --         progress = 1.0
84          --         t.timer = 0.001
85          --         t.has_persisted = true
86          --     end
87          --     t.alpha = 1.0
88          -- else
89              -- Normal floater: hold-then-fade curve.
90              if progress < ALPHA_HOLD then
91                  t.alpha = 1
92              else
93                  t.alpha = (1 - progress) / (1 - ALPHA_HOLD)
94              end
95          end
```
Before this edit, `tbl`-attached floaters (floating text pinned to a table, e.g. a running total that should freeze once the table goes idle) never faded and could freeze permanently via `t.has_persisted = true`. After this edit, the `if tbl then ... else ...` two-way branch has become one unconditional block: every floater, table-attached or not, now runs the hold-then-fade curve, and `t.has_persisted` is never set (that whole sub-block is commented out), so `t.has_persisted` stays falsy forever. The removal condition a few lines below (`if t.timer <= 0 and not t.has_persisted then table.remove(...) end`) then always fires once the timer runs out -- table-attached floaters now fade and get deleted like ordinary floaters instead of freezing at their final resting position. This is a real behavioral regression, not a no-op: anything relying on `FloatingTextSystem.emit(..., {table = someTable})`'s freeze/persist contract (documented at the top of this same file and in the surviving comment describing `saw_idle` tracking) is now broken.

This reads as debug scaffolding ("comment it out, see if the bug goes away") that was never restored or cleaned up -- half-finished, and should not be committed. Either restore the original branch or, if the freeze behavior is intentionally being retired, delete the dead code and the now-inaccurate `saw_idle`/`has_persisted` machinery/comments instead of leaving them commented out in place.

**Already flagged upstream, confirmed still present:** `FloatingTextSystem.getTexts()` at `services/FloatingTextSystem.lua:108` (`return _texts`) returns the live internal table, not a copy -- any caller can mutate the module's private state through the returned reference. This encapsulation leak predates this diff and survived it untouched; still worth fixing whenever this file is next touched.

**Verdict: do not commit.** This is not a real change, it's an in-progress debugging edit left mid-flight.

#### `views/CatalogModal.lua` -- Sticker call-site palette update (+13/-8)

Straightforward: swaps the sticker's color tokens passed into `Sticker.draw{...}` (`views/CatalogModal.lua:794-816`) from a flat cream/amber pair to a richer set (`stock_token`, new `panel_token`, `fill_token` now conditional amber-to-green on `met`, new `vinyl_token`), matching the new fields `Sticker.lua` added. This is the only call site in the codebase (confirmed via a `Sticker.draw{` grep -- one hit), so there's no wiring gap; every new opt the widget accepts is supplied here. Functionally complete and consistent with the widget-side diff.

The call site continues the pre-existing pattern (present before this diff too, e.g. the old `stock_token = { 0.99, 0.97, 0.92 }`) of passing literal RGB tuples from a view file rather than named `Theme` tokens. That is a pre-existing looseness in this specific widget's calling convention, not something newly introduced by this diff -- flagged here for completeness but not attributed to this change. The file also triggers a benign Git LF/CRLF warning on this touch; see the Repo Conventions section for the `.gitattributes` fix.

**Verdict:** safe to commit alongside `Sticker.lua` -- the two are coupled (this file supplies the new `panel_token`/`vinyl_token` opts `Sticker.lua` now consumes) and read as one finished feature together.

#### `views/widgets/Sticker.lua` -- sticker visual rewrite (+203/-59)

This is a substantial, largely complete rewrite adding: a two-pass drop shadow (`views/widgets/Sticker.lua:151-157`), a white vinyl die-cut backing distinct from the printed panel, a separate "vinyl disc" the text sits on (`views/widgets/Sticker.lua:207-216`) so a saturated fill can run under it without eating glyphs, a fill/remainder seam divider (`views/widgets/Sticker.lua:186-196`), a gloss highlight over the earned fraction (`views/widgets/Sticker.lua:219-227`), a deterministic corner starburst (`views/widgets/Sticker.lua:229-245`), and a serrated zig-zag peel-strip edge (`views/widgets/Sticker.lua:247-266`). The doc header (`views/widgets/Sticker.lua:1-38`) was updated to match the new opts (`panel_token`, `vinyl_token`) and reads accurately against the code below it.

**Low -- dead code: `brighten()` helper is defined but never called.**
```lua
53: local function brighten(c, k)
54:     return { c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k }
55: end
56: local function darken(c, k)
57:     return { c[1] * (1 - k), c[2] * (1 - k), c[3] * (1 - k) }
58: end
```
`darken` is used once (`views/widgets/Sticker.lua:278`); `brighten` has zero call sites in the file or the rest of the repo. Not a bug (Lua tolerates unused locals silently, no lint step exists -- see Testing section), but it is leftover half-used scaffolding from this diff; either use it (e.g. for the gloss highlight, which currently hardcodes `{1,1,1}` at line 224 instead of `brighten(panel, ...)`) or delete it.

**Medium -- new literal-color defaults replace what used to be `Theme` token defaults, a Rule 3 regression scoped to this file.**
```lua
104: local stock = opts.stock_token or { 1, 1, 1 }
105: local panel = opts.panel_token or { 1.00, 0.97, 0.88 }
111: local vinyl = opts.vinyl_token or { 1.00, 0.98, 0.90 }
```
Before this diff, the only fallback default was `opts.stock_token or Theme.bg.widget` -- a real Theme token. Now `stock`'s fallback is a bare literal white, and the two new tokens (`panel`, `vinyl`) never had Theme-token defaults to begin with; they default straight to literal RGB triples. `SHADOW = { 0, 0, 0 }` (`views/widgets/Sticker.lua:49`) is pre-existing and unchanged. Given the sole call site (`views/CatalogModal.lua`) always supplies explicit literal tokens anyway, these defaults are currently dead in practice, but they are still new literal colors living outside `data/theme.lua`/`views/Theme.lua`, which is exactly what the rule-3 audit grep `rg "love\.graphics\.setColor\(\s*\d"` is meant to catch structurally (this particular case slips that specific grep because the literal is stored in a local first, not passed inline to `setColor` -- worth tightening the grep or adding a table-literal variant).

**Low -- comment/implementation drift: the starburst is documented as "peeking out from behind the disc" but is painted after (on top of) the vinyl disc.**
Step 5 draws the vinyl text disc (`views/widgets/Sticker.lua:207-216`); step 7 draws the starburst (`views/widgets/Sticker.lua:229-245`) -- later in paint order, so on top, not behind. Whether this is visually noticeable depends on whether the disc's bounding box (sized to the actual title/line/counter text) happens to overlap the fixed starburst position near the panel's bottom-right corner -- for short single-line stickers it likely won't overlap at all, so the comment's claim goes untested by most content. Not a functional bug, but the comment overpromises what the paint order actually guarantees; either reorder the draws (starburst before the disc) or fix the comment.

**No wiring gaps found:** `widthFor`/`heightFor` were updated in lockstep with the `PAD`/`MARGIN` -> `INLAY` rename (`views/widgets/Sticker.lua:355-374`), and the sole caller (`views/CatalogModal.lua:628,632`) doesn't need changes since it just calls the functions positionally.

**Verdict:** functionally coherent and appears complete for its scope (no half-finished paint steps, no missing opts at the call site). The two things worth fixing before commit are the literal-color defaults (Medium, rule-3-adjacent) and the dead `brighten` helper (Low/Nit) -- neither blocks committing, both are quick.

### 2. `sim/` (sim/main.lua, sim/run.lua)

**What it is:** a headless "Act 1 Pacing Simulator" (`sim/run.lua:3`), not a hand-by-hand poker simulator. It requires the real `data.catalog`, `data.balance`, and `models.shove_rate` modules directly (`sim/run.lua:12-14`) -- confirmed by reading and by actually running it (see below) -- so for the pieces it touches it exercises the LIVE model, not a stale copy. There is no duplicated game logic to drift for those three modules.

What it does NOT touch: `models/Table.lua`, `models/Table_legacy.lua`, `models/HandScript.lua`, or anything gated by `Constants.PROTOTYPE_MODE`. `grep -rn "PROTOTYPE_MODE" sim/` returns nothing. The sim never simulates an actual hand, a showdown, or variance -- it only sums each owned catalog item's `shove_rate_add` effect into a scalar (`sim/run.lua:70-73`) and feeds that into `models/shove_rate.lua`'s `computeFromBase` (the same formula used live in `states/ShoveState.lua` and the top-bar/SHOVE-button display, per that file's own header comment). So the question "is it wired to `Constants.PROTOTYPE_MODE` correctly" doesn't apply -- it isn't wired to it at all, by design, because it operates one layer above per-hand resolution. Its results describe neither build specifically; they describe the aggregate shove-rate math shared by both `Table.lua` and `Table_legacy.lua` (that formula lives in `models/shove_rate.lua`, which is not one of the files that forks on `PROTOTYPE_MODE`). Framed as a caveat: if the two Table implementations ever diverge in how they translate a given shove-rate into an actual win/loss outcome (variance, rake, edge cases), this sim would not see that divergence -- it stops at "is r1 >= target", never asks "did the shove actually win".

**Verified by running it (read-only, no game boot):**
```
cd C:/Users/chate/Documents/poker-idle && lua sim/run.lua
```
Ran cleanly with the installed Lua 5.4.6, output:
```
Shove 1    | 9        | 18.4       % | 21.0       % | 20.0 mins
...
Shove 12   | 35       | 71.4       % | 81.6       % | 240.0 mins
Act 1 Cleared in 240.0 minutes (12 runs)!
```
This also confirms `sim/run.lua` picks up the uncommitted `data/catalog.lua`/`data/balance.lua` derivation loop reviewed in section 1 -- the sim's numbers already reflect that in-flight, not-yet-committed change.

**Modeling limitation (not a bug, but a real gap):** the greedy "buy cheapest owned-candidate item every run" policy (`sim/run.lua:42-67`) is synthetic -- not what an actual player does -- and the sim assumes the player instantly "clears" the moment `r1 >= Balance.ACT1_SHOVE_TARGET` (`sim/run.lua:85-87`), with no modeling of an actual shove attempt, loss, or retry. It answers "how many owned items until shove-win-probability crosses 80%" under a best-case idealized buying order, not "how many actual playthroughs, with variance, does it take an average player to clear Act 1". The header text ("Policy: Greedy Buy-Cheapest-First") is the only caveat given; nothing in the output disclaims the "always converts the moment the odds cross the line" assumption.

**RNG / reproducibility:** `grep -rn "math.random\|randomseed" sim/` returns nothing -- the simulator itself calls no RNG at all today (its only randomness-adjacent behavior is the deterministic greedy purchase order), so its current output is trivially reproducible run-to-run. But this masks a real gap for the moment this sim is extended toward actual hand-level Monte Carlo (which `sim/main.lua`'s existence suggests is the intent -- see below): `grep -rn "randomseed" --include=*.lua .` across the entire repo returns zero hits. Nothing in the game or in `sim/` ever calls `math.randomseed`. Lua 5.4's `math.random` auto-seeds from an implementation-defined source at startup (not a fixed value), so any future hand-level simulation built on this scaffold -- or the live game's own RNG-driven hand outcomes, for that matter -- has no way to pin or replay a specific run's random sequence. Worth flagging now while the sim is still young: add an explicit `math.randomseed(seed)` call (accepting a seed as a CLI/env argument) before any Monte Carlo work lands here, or reproducing a reported bad run will never be possible.

**How it's run / documented:** there is no `sim/README.md`, no mention of `sim/` in any of the 20 docs under `docs/`, and no wrapper script. `grep -rln "sim/" docs/` returns nothing. The only two ways to invoke it are the one just demonstrated (`lua sim/run.lua` from repo root -- works because `sim/run.lua:8-9` builds `package.path` off `love.filesystem.getWorkingDirectory()` when present, falling back to `"."` otherwise) or via LÖVE: `sim/main.lua` (`sim/main.lua:1-4`) is a `love.load` callback that `require("sim.run")` then calls `love.event.quit()` -- meant to be launched as `love sim` (pointing the `love` binary at the `sim/` subfolder) run from the repo root, since `love.filesystem.getWorkingDirectory()` returns the OS process cwd, not the game-source folder, which is what lets the `package.path` trick reach `data/` and `models/` at the repo root. Neither entry point is documented anywhere a future contributor would find it. Recommendation: add a one-paragraph `sim/README.md` stating the one command that works (`lua sim/run.lua` from repo root) and the fact that it models pacing, not hand outcomes.

### 3. Build pipeline

**`build-tools/build_web.py` (143 lines) -- correctness:** the script is a clean, dependency-light packager. `ROOT` is computed relative to the script's own path (`os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`, `build-tools/build_web.py:38`), not hardcoded to a machine-specific path, and the doc's claim "run from anywhere" checks out. `LOVE_ITEMS` (`build-tools/build_web.py:33-37`) is an explicit allowlist:
```python
LOVE_ITEMS = [
    "conf.lua", "main.lua",
    "assets", "controllers", "core", "data", "lib",
    "models", "services", "shaders", "states", "utils", "views",
]
```
This confirms, by reading the code (not inferring from the doc): `docs/`, `sim/`, `.kilo/`, `analytics-worker/`, and all `node_modules` are correctly excluded from both `build/PokerIdle.love` and, downstream, `build/PokerIdle-web.zip` -- `zip_dir` (`build-tools/build_web.py:65-79`) only walks the `items` list when one is given, and step 1 always passes `LOVE_ITEMS` explicitly. The `assets/` folder alone is 17MB across 1242 files (measured directly); the full source tree shipped is modest for a 2D LÖVE game.

**Medium -- the script packages whatever is on disk, not what's committed, with no clean-tree check.** `zip_dir` walks the real filesystem (`build-tools/build_web.py:65-79`); there is no `git status --porcelain` guard anywhere in the script. Concretely: right now, running `python build-tools/build_web.py` from this working tree would silently bundle the uncommitted `data/catalog.lua` (which `require("data.balance")`, itself untracked -- see section 1 and the lead auditor's note) into the `.love` and the web zip. That specific case happens to still work today (both files exist on disk), but the script gives no signal either way -- a build produced from a dirty tree is indistinguishable from one produced from a clean, tagged commit. A one-line `git status --porcelain` check (warn, or require `--allow-dirty` to proceed) would close this.

**High -- `PROTOTYPE_MODE` is a manual, unenforced flag, and it is currently set to the wrong value for a web ship.** `data/constants.lua:16-18` documents the contract explicitly:
```lua
-- itch/web builds ship whatever is committed here -- build_web.py is a
-- pure packager, it rewrites nothing. Set back to true before building
-- for itch.
C.PROTOTYPE_MODE = false
```
I verified both halves of this. First, the claim "build_web.py ... rewrites nothing" is accurate: `grep -n "PROTOTYPE_MODE\|constants" build-tools/build_web.py build-tools/index.html` returns zero hits -- the script never touches `data/constants.lua`, so there is no automated flip. Second, `C.PROTOTYPE_MODE = false` is the current, committed value on `HEAD` right now (it is not part of this session's dirty diff). At `false`, per `data/constants.lua:36-79`, the feature set is: `DEV_HOTKEYS = true` (F2/F6/F7/backtick/-/=, dev-only hotkeys, live in a shipped web build), `QUIT_DISABLED = false` (the Settings "Quit" button is enabled) -- and `data/constants.lua:63-65`'s own comment says plainly: "The web/love.js build can't quit a browser tab -- love.event.quit() hard-errors the canvas -- so the prototype (web) build greys Quit out..." At `PROTOTYPE_MODE = false`, that greying-out doesn't happen. If `build-tools/build_web.py` were run against the repo exactly as it sits right now, the resulting web build would ship a working Quit button that crashes the canvas when clicked, plus live developer hotkeys exposed to every player, plus `HIGH_TIER_STAKES`/`DECKS`/`MTT_KO` content that (per the same file's comments) isn't meant to be in the itch build yet. There is no build-time assertion, no CI check, and no prompt in `build_web.py` that would catch this -- the only defense is a developer remembering to hand-edit one boolean before every ship. This is exactly the kind of manual step that fails under real release pressure; a one-line guard in `build_web.py` (assert on reading `data/constants.lua`'s `PROTOTYPE_MODE` value before packaging, or a `--prototype` flag the script requires you to pass explicitly) would convert a silent footgun into a loud one.

**Desktop vs. web divergence:** `docs/build-web.md`'s own "Desktop builds" section says the Windows build "is not produced by this script" and gives no script or command for producing it -- it's entirely manual (`love.exe` fusion into `build/PokerIdle-win64/`). Since there is no shared build step and no version/commit stamping tying a given `build/PokerIdle-win64.zip` to a given `build/PokerIdle-web.zip`, the two can trivially diverge (e.g. web rebuilt after a fix, desktop not, or vice versa) with nothing in the repo to detect it.

**Green-tint canvas issue:** the one WebGL-related handling in the pipeline is in `build-tools/index.html:172-178` -- a `webglcontextlost` listener that `alert()`s "WebGL context lost. You will need to reload the page." and calls `preventDefault()`. This is a full-context-loss handler (browser reclaimed the GPU context entirely), not a fix for a persistent tint/color artifact; no code anywhere in `build-tools/` or `main.lua` specifically addresses a green-tint rendering bug. (unverified) -- did not run the web build to confirm what actually causes the reported green tint, so can't say whether this handler is the intended mitigation or unrelated; flagging the absence of any tint-specific code as the finding itself.

**Notable, cross-referenced to section 4:** `build-tools/index.html:153` hardcodes the production analytics endpoint (`https://poker-idle-analytics.noicegamestudio.workers.dev`) directly in the tracked web shell HTML. This is expected -- a Cloudflare Worker URL a client-side page POSTs to has to be public and is not a secret by nature -- but it does mean the studio's Worker subdomain is visible to anyone who views source on the shipped page; see section 4 for the more serious issue with what that endpoint exposes on GET.

### 4. `analytics-worker/`

**Tracked files (verified via `git ls-files analytics-worker`):** `.gitignore`, `schema.sql`, `src/index.js`, `wrangler.toml` -- four files, 289 lines of worker code total.

**No committed credentials, API keys, or tokens found.** `wrangler.toml` (`analytics-worker/wrangler.toml`) contains only a Cloudflare D1 `database_name`/`database_id` (`155507df-0838-4079-b2d8-0c6931348e72`) -- a database identifier, not an auth secret; it grants no access on its own. `src/index.js` contains no API keys, no auth headers, no hardcoded tokens. A local Wrangler CLI cache file, `analytics-worker/.wrangler/cache/wrangler-account.json`, does exist on disk in the working tree and contains the Cloudflare account ID and the owner's Gmail address (`Noicegamestudio@gmail.com's Account`) -- but `analytics-worker/.gitignore:1` is `.wrangler/`, and `git ls-files analytics-worker` confirms this file is not tracked. Correctly excluded; not a repo-level leak. (Worth double-checking it never was committed in an earlier commit via `git log --all --full-history -- analytics-worker/.wrangler` if a fully paranoid check is wanted -- not run here.)

**What's collected** (`analytics-worker/schema.sql`): three tables keyed by `save_id` -- `shoves` (per-prestige-run: catalog/run-upgrade levels owned, the four shove-rate components, gauntlet result, chips earned), `hands` (per-hand: duration, won/lost, delta, tier, stake, game type, deck id), and `events` (economy events: item bought, level, cost in dollars/chips, bankroll at time of purchase). `save_id` is generated client-side as `os.time() .. "_" .. math.random(10000,99999)` (`models/GameState.lua:16-18`) -- a coarse timestamp+random string, not derived from hardware, account, or any identifying source. This matches the consent modal's claim of "no personal information -- no name, account, or device ID" (`views/AnalyticsConsentModal.lua:12`).

**Consent gating (client side) is implemented correctly:** `analytics_consent` defaults to `false` when unset (`main.lua:196`, `prefs.analytics_consent == true -- nil -> false`), the modal is opt-in only (`states/GrindState.lua:212-213` shows it when the setting is still `nil`), and the only place data actually leaves the machine, `services/HandAnalytics.lua:133-142`, gates on both conditions:
```lua
function HandAnalytics.flush(state, consent)
    if not _enabled or not _current_run then return end
    ...
    _writeRaw()
    if _is_web and consent then
        print(ANALYTICS_MARKER .. json.encode(_file_data))
    end
end
```
Desktop builds (`_is_web == false`) never transmit anything regardless of consent -- only the local JSON file is written. Web builds only transmit when `consent == true` explicitly. This is a sound, honest implementation of the stated opt-in policy.

**Low -- Settings modal can display "analytics on" while the actual send-gate treats the same state as off.** `views/SettingsModal.lua:278`:
```lua
local ana_on  = not (self.game.settings and self.game.settings.analytics_consent == false)
```
This reads `nil` (undecided, never having seen the consent modal) as "on" for the toggle's display, while `HandAnalytics.flush`'s gate (`services/HandAnalytics.lua:140`, `if _is_web and consent then`) treats `nil` as falsy and does not send. In the normal flow the consent modal resolves this to `true`/`false` almost immediately (`states/GrindState.lua:212-213`), so the window where this mismatch is visible is narrow, but it is a real UI/logic inconsistency worth a one-line fix (`analytics_consent == true` instead of `~= false`) whenever this file is next touched.

**High -- the analytics backend has no authentication on reads, including a "dump everything" endpoint, undermining the "anonymous... used only to spot balance problems" framing given to players.** `analytics-worker/src/index.js` handles GET with zero access control:
```js
if (request.method === "GET") {
  const url = new URL(request.url);
  const save_id = url.searchParams.get("save_id");

  if (url.searchParams.has("all")) {
    return withCors(Response.json(await exportAll(env)));
  }
  ...
```
(`analytics-worker/src/index.js:139-145`). `exportAll` (`analytics-worker/src/index.js:71-131`) returns literally every row in all three tables for every `save_id` ever recorded, as one JSON blob. There is no API key, bearer token, IP allowlist, or Cloudflare Access rule checked anywhere in the file -- and CORS is wide open (`Access-Control-Allow-Origin: "*"`, `analytics-worker/src/index.js:12`), meaning any website's client-side JS, not just the developer's own dashboard tooling, can pull the entire dataset cross-origin with a single `fetch()`. The comment at the top of the file acknowledges this is deliberate ("No auth: this is anonymous, opt-in, non-credentialed data ... so it's just capped and validated", `analytics-worker/src/index.js:3-4`), and the data itself is genuinely not classic PII (no names/emails/device IDs, as verified above) -- but it is still every opted-in player's complete play history, economy behavior, and session timing, sitting behind a guessable, undocumented-but-discoverable URL (it's right there in the shipped web page's source, `build-tools/index.html:153`) with a literal `?all` "give me everything" parameter and no rate limiting beyond the per-request row caps (`MAX_SHOVES`, `MAX_HANDS_PER_SHOVE`, `MAX_EVENTS_PER_SHOVE`, which only bound POST body size, not GET output). This is the kind of gap that reads fine in isolation ("it's just balance telemetry") but would read badly if a player or journalist found and used the `?all` endpoint themselves, especially set against the consent copy's implicit promise that the data is used only by the developer for balance tuning. Recommend: put GET behind a shared-secret query param or header checked against a Wrangler secret (`env.DASHBOARD_TOKEN`), at minimum for `?all` and unscoped listing; POST (the actual player-facing write path) can stay open since it's already capped/validated and anonymous by construction.

### 5. Testing

**There is no automated test of any kind in this repo.** Verified directly: `find . -iname "*test*" -not -path "*/node_modules/*" -not -path "*/.git/*"` returns nothing under any tracked or untracked source directory; there is no `busted` config (`.busted`), no `luarocks` test rockspec, no CI workflow directory, and no `luarocks`-installed `busted` binary on this machine (`which busted` fails; `luarocks 3.9.2` is present but nothing is installed through it). Every one of the ~38k LOC is currently verified only by hand-testing the running game. Say this plainly: for a game with real player saves live on itch and hand-ranking/payout math this intricate, zero automated coverage is a real risk, not a nitpick -- a silent regression in `models/HandEval.lua` or `services/SaveService.lua` would only surface as a wrong showdown result or a corrupted save in a player's hands.

**Recommended minimum viable setup:**
- **Test runner:** [`busted`](https://lunarmodules.github.io/busted/) (`luarocks install busted`) -- the de facto standard Lua test framework, `describe`/`it` structure, assertion library, watch mode, CI-friendly output. Not installed on this machine right now, so it can't be the very first thing dropped in without an install step.
- **What to test first**, in priority order: (1) `models/HandEval.lua` -- pure, zero dependencies, the single most consequence-bearing piece of logic in the game (a wrong showdown is a wrong game); (2) `models/shove_rate.lua` -- pure, the win-probability math the whole meta-progression is priced against, and the only one of the "payout" family with no LÖVE dependency at all; (3) `services/SaveService.lua` -- the save round trip, given save back-compat is a hard project requirement (per project memory: real player saves exist on itch); (4) once the above are solid, `models/outcome_math.lua` and `models/payout_breakdown.lua` are the natural next targets, but both pull in `love.math.random` (`models/outcome_math.lua:82,330,335,362,504`) and a wide data/model graph (`Catalog`, `RunUpgrades`, `Decks`), so they need the same `love` stub pattern demonstrated below, plus either a fixed RNG seed or restructuring the sampling functions to accept an injectable RNG for determinism.

**A concrete, runnable first test file** -- written, and actually run against this repo with the installed Lua 5.4.6 (`lua tests/test_first.lua` from repo root) to confirm it passes before reporting it here:
```
19 passed, 0 failed
```
It requires nothing beyond the `lua` binary already on this machine (no busted, no luarocks packages) -- drop it at `tests/test_first.lua` and run `lua tests/test_first.lua` from the repo root. It covers exactly the three areas asked for: `models/HandEval.lua` (including the A-2-3-4-5 wheel straight, both plain and as a straight flush, plus `bestFiveOfN`'s 7-card hole+board selection), the payout/win-rate math in `models/shove_rate.lua` (bankroll-tier interpolation, the r1 clamp, the deck-less clear invariant `sim/run.lua` already relies on), and a full `services/SaveService.lua` write/read round trip through the real `lib/json.lua` codec (including the `coerceIntKeys` integer-key restoration and a version-mismatch rejection check). It stubs only the two LÖVE surfaces the modules under test actually call (`love.math.random`, `love.filesystem.getInfo/read/write/remove`, the latter backed by real temporary files, not an in-memory fake) -- deliberately minimal, so it doesn't accidentally mask a module reaching for more of the engine than it should.

```lua
-- tests/test_first.lua
--
-- First automated test for poker-idle. There are currently ZERO tests in
-- this repo (verified: no file anywhere matches *test*, no busted config,
-- no CI). This file is meant to be dropped in at tests/test_first.lua and
-- run with:
--
--     cd poker-idle && lua tests/test_first.lua
--
-- It is a plain Lua 5.4 script with no external dependencies, so it runs
-- today with the `lua` binary already on this machine. It stubs the two
-- pieces of the LÖVE API the covered modules touch (love.math.random and
-- love.filesystem.*) so models/services can be required headless, exactly
-- the same trick sim/run.lua already uses for package.path.
--
-- Longer term, install busted (`luarocks install busted`) and either
-- convert these into busted's describe/it style (the harness below is
-- deliberately shaped the same way so the port is mechanical) or keep
-- both -- this file has zero setup cost and busted adds nicer output,
-- watch mode, and CI integration once the suite grows past a few files.
--
-- Coverage in this first pass:
--   1. models/HandEval.lua   -- hand ranking, including the A-2-3-4-5 wheel
--      straight (both plain and straight-flush), and bestFiveOfN's 7-card
--      selection.
--   2. models/shove_rate.lua -- the shove-rate/payout math (pure, no RNG):
--      bankroll-tier interpolation and the R1 clamp.
--   3. services/SaveService.lua -- a full write/read round trip through the
--      actual JSON codec (lib/json.lua) and coerceIntKeys, plus a
--      version-mismatch rejection check.

------------------------------------------------------------------------
-- 0. Tiny test harness (no dependencies)
------------------------------------------------------------------------

local _pass, _fail = 0, 0

local function describe(name, fn)
    print("\n" .. name)
    fn()
end

local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        _pass = _pass + 1
        print("  [PASS] " .. name)
    else
        _fail = _fail + 1
        print("  [FAIL] " .. name)
        print("         " .. tostring(err))
    end
end

local function assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            msg or "assertEqual", tostring(expected), tostring(actual)), 2)
    end
end

local function assertTrue(v, msg)
    if not v then error(msg or "expected true, got " .. tostring(v), 2) end
end

local function assertNear(actual, expected, eps, msg)
    eps = eps or 1e-6
    if math.abs(actual - expected) > eps then
        error(string.format("%s: expected ~%s, got %s",
            msg or "assertNear", tostring(expected), tostring(actual)), 2)
    end
end

------------------------------------------------------------------------
-- 1. LOVE stubs -- enough surface for the pure model/service layer to
--    require() cleanly outside the engine. Do NOT add more than the
--    modules under test actually call; a bigger stub risks masking a
--    real dependency-on-LOVE bug in code that should be engine-agnostic.
------------------------------------------------------------------------

_G.love = {
    math = {
        -- Real LOVE seeds this from OS entropy at startup; plain Lua's
        -- math.random is fine as a drop-in for the [0,1) / (m,n) shapes
        -- models/outcome_math.lua calls it with.
        random = math.random,
    },
    filesystem = (function()
        -- A save "filesystem" backed by real files in a throwaway
        -- directory next to this script, so SaveService's actual
        -- love.filesystem.* calls exercise real disk I/O round-tripped
        -- through lib/json.lua -- not a fake in-memory table.
        local SANDBOX = "tests_tmp_savebox"
        os.execute('mkdir "' .. SANDBOX .. '" 2>nul')          -- Windows cmd
        os.execute("mkdir -p '" .. SANDBOX .. "' 2>/dev/null") -- POSIX sh

        local function path(filename) return SANDBOX .. "/" .. filename end

        return {
            getInfo = function(filename)
                local f = io.open(path(filename), "rb")
                if not f then return nil end
                f:close()
                return { type = "file" }
            end,
            read = function(filename)
                local f = io.open(path(filename), "rb")
                if not f then return nil, "no such file" end
                local data = f:read("*a")
                f:close()
                return data, #data
            end,
            write = function(filename, data)
                local f = io.open(path(filename), "wb")
                if not f then return false, "could not open " .. filename end
                f:write(data)
                f:close()
                return true
            end,
            remove = function(filename)
                os.remove(path(filename))
                return true
            end,
            _sandboxDir = SANDBOX,
        }
    end)(),
}

------------------------------------------------------------------------
-- Module path: run this file from the repo root (`lua tests/test_first.lua`)
-- so Lua's default "./?.lua" searcher resolves "models.HandEval" the same
-- way every other file in this codebase already requires it.
------------------------------------------------------------------------

local HandEval    = require("models.HandEval")
local Card        = require("models.Card")
local ShoveRate   = require("models.shove_rate")
local SaveService = require("services.SaveService")

local function c(rank, suit) return Card:new(suit, rank) end

------------------------------------------------------------------------
-- 1. models/HandEval.lua
------------------------------------------------------------------------

describe("HandEval.rank -- hand categories", function()

    it("recognizes a pair", function()
        local hand = { c("a","spades"), c("a","hearts"), c("k","clubs"),
                       c("9","diamonds"), c("2","spades") }
        local rank = HandEval.rank(hand)
        assertEqual(rank[1], HandEval.PAIR, "category")
        assertEqual(rank[2], 14, "pair rank (Aces)")
    end)

    it("recognizes two pair, higher pair sorted first", function()
        local hand = { c("9","spades"), c("9","hearts"), c("k","clubs"),
                       c("k","diamonds"), c("2","spades") }
        local rank = HandEval.rank(hand)
        assertEqual(rank[1], HandEval.TWO_PAIR, "category")
        assertEqual(rank[2], 13, "top pair (Kings)")
        assertEqual(rank[3], 9,  "bottom pair (9s)")
    end)

    it("recognizes a normal (Broadway) straight, Ace-high", function()
        local hand = { c("a","spades"), c("k","hearts"), c("q","clubs"),
                       c("j","diamonds"), c("10","spades") }
        local rank = HandEval.rank(hand)
        assertEqual(rank[1], HandEval.STRAIGHT, "category")
        assertEqual(rank[2], 14, "high card of the straight is the Ace")
    end)

    it("recognizes the A-2-3-4-5 wheel straight as 5-high, not Ace-high", function()
        local hand = { c("a","spades"), c("2","hearts"), c("3","clubs"),
                       c("4","diamonds"), c("5","spades") }
        local rank = HandEval.rank(hand)
        assertEqual(rank[1], HandEval.STRAIGHT, "category")
        assertEqual(rank[2], 5, "wheel straight ranks as 5-high, Ace plays low")
    end)

    it("wheel straight loses to a 6-high straight", function()
        local wheel = HandEval.rank({ c("a","spades"), c("2","hearts"), c("3","clubs"),
                                       c("4","diamonds"), c("5","spades") })
        local six_high = HandEval.rank({ c("2","spades"), c("3","hearts"), c("4","clubs"),
                                          c("5","diamonds"), c("6","spades") })
        assertEqual(HandEval.compare(wheel, six_high), -1,
            "wheel (5-high) must rank below a 6-high straight")
    end)

    it("recognizes the wheel STRAIGHT FLUSH (same suit) as its own category", function()
        local hand = { c("a","clubs"), c("2","clubs"), c("3","clubs"),
                       c("4","clubs"), c("5","clubs") }
        local rank = HandEval.rank(hand)
        assertEqual(rank[1], HandEval.STRAIGHT_FLUSH, "category")
        assertEqual(rank[2], 5, "wheel straight flush is 5-high")
    end)

    it("a wheel straight flush beats quads", function()
        local wheel_sf = HandEval.rank({ c("a","clubs"), c("2","clubs"), c("3","clubs"),
                                          c("4","clubs"), c("5","clubs") })
        local quads = HandEval.rank({ c("k","spades"), c("k","hearts"), c("k","clubs"),
                                       c("k","diamonds"), c("2","spades") })
        assertEqual(HandEval.compare(wheel_sf, quads), 1,
            "even the lowest straight flush must outrank quads")
    end)

    it("full house beats flush beats straight (category ordering sanity)", function()
        local full_house = HandEval.rank({ c("9","spades"), c("9","hearts"), c("9","clubs"),
                                            c("2","diamonds"), c("2","spades") })
        local flush = HandEval.rank({ c("2","clubs"), c("5","clubs"), c("8","clubs"),
                                       c("j","clubs"), c("k","clubs") })
        local straight = HandEval.rank({ c("4","spades"), c("5","hearts"), c("6","clubs"),
                                          c("7","diamonds"), c("8","spades") })
        assertTrue(HandEval.compare(full_house, flush) > 0, "full house > flush")
        assertTrue(HandEval.compare(flush, straight) > 0, "flush > straight")
    end)

    it("describe() reads the wheel straight as 5-high, not Ace-high", function()
        local rank = HandEval.rank({ c("a","spades"), c("2","hearts"), c("3","clubs"),
                                      c("4","diamonds"), c("5","spades") })
        assertEqual(HandEval.describe(rank), "5-high straight")
    end)
end)

describe("HandEval.bestFiveOfN -- Hold'em 2-hole + 5-board selection", function()

    it("picks the wheel straight out of a 7-card hole+board when it's the best hand", function()
        -- Hole: A, 2.  Board: 3, 4, 5, K, K.  Best 5 is the A-2-3-4-5 wheel,
        -- not two pair off the board kings (5-high straight beats two pair).
        local hole  = { c("a","spades"), c("2","hearts") }
        local board = { c("3","clubs"), c("4","diamonds"), c("5","spades"),
                         c("k","hearts"), c("k","clubs") }
        local label, combo = HandEval.handLabel(hole, board)
        assertEqual(label, "5-high straight")
        assertEqual(#combo, 5)
    end)

    it("correctly prefers a flush over a made straight when both are available", function()
        local hole  = { c("a","clubs"), c("2","clubs") }
        local board = { c("3","clubs"), c("9","clubs"), c("k","clubs"),
                         c("4","diamonds"), c("5","hearts") }
        -- Board+hole also contains a wheel straight (A-2-3-4-5), but the
        -- clubs flush (A-2-3-9-K of clubs) must win.
        local rank, combo = HandEval.bestFiveOfN({
            hole[1], hole[2], board[1], board[2], board[3], board[4], board[5],
        })
        assertEqual(rank[1], HandEval.FLUSH)
        assertEqual(#combo, 5)
    end)
end)

------------------------------------------------------------------------
-- 2. models/shove_rate.lua -- payout / win-rate math (pure, no RNG)
------------------------------------------------------------------------

describe("ShoveRate.computeFromBase -- bankroll-tier interpolation and clamping", function()

    it("at bankroll 0, sits on the Sub-T1 bracket (mult = 1x)", function()
        local rates = ShoveRate.computeFromBase(0.5, 0)
        assertNear(rates.mult, 1.0, 1e-9, "Sub-T1 multiplier")
        assertNear(rates.r1, 0.5, 1e-9, "r1 = catalog * mult with mult=1")
    end)

    it("r1 grows monotonically with the catalog base, all else equal", function()
        local low  = ShoveRate.computeFromBase(0.10, 0)
        local high = ShoveRate.computeFromBase(0.30, 0)
        assertTrue(high.r1 > low.r1, "more catalog base must not lower r1")
    end)

    it("r1 never exceeds the model's ceiling regardless of an overshot catalog base", function()
        local Constants = require("data.constants")
        local cap = (Constants.FEATURES and Constants.FEATURES.DEMO_CUT) and 0.99 or 1.0
        local rates = ShoveRate.computeFromBase(50, 0)  -- absurdly large on purpose
        assertTrue(rates.r1 <= cap + 1e-9,
            "r1 must respect the current build's display cap (" .. tostring(cap) .. ")")
        assertTrue(rates.raw_r1 >= rates.r1,
            "raw_r1 (uncapped, for display) must be >= the clamped r1 actually rolled")
    end)

    it("computeFromBase never produces a deck-only clear (no master deck = clear stays 0)", function()
        -- computeFromBase always passes deck=0, so r2 = r3 = 0 and the
        -- 3-runout clear (r1*r2*r3) must be exactly 0 no matter how big
        -- the catalog base is. This is the same invariant sim/run.lua
        -- relies on implicitly when it only reads rates.r1.
        local rates = ShoveRate.computeFromBase(0.9, 1000)
        assertEqual(rates.clear, 0)
    end)
end)

------------------------------------------------------------------------
-- 3. services/SaveService.lua -- save round-trip
------------------------------------------------------------------------

describe("SaveService -- write/read round trip", function()

    it("round-trips a nested payload through the real JSON codec, including int-ish keys", function()
        local svc = SaveService:new()
        local payload = {
            bankroll   = 12.5,
            owned_items = { "poker_poster", "branded_hat" },
            deck_levels = { standard = 3, maniac = 1 },
            -- integer-like string keys, the exact case coerceIntKeys exists
            -- for (JSON object keys are always strings; Lua tables that were
            -- originally array-like with numeric keys need them restored).
            slots = { [1] = "table_a", [2] = "table_b", [10] = "table_c" },
        }
        svc:write("meta.save", payload)
        local roundtripped = svc:read("meta.save")

        assertTrue(roundtripped ~= nil, "read must find the file just written")
        assertNear(roundtripped.bankroll, 12.5, 1e-9)
        assertEqual(roundtripped.owned_items[1], "poker_poster")
        assertEqual(roundtripped.owned_items[2], "branded_hat")
        assertEqual(roundtripped.deck_levels.standard, 3)
        assertEqual(roundtripped.slots[1], "table_a")
        assertEqual(roundtripped.slots[10], "table_c")
        assertEqual(type(next(roundtripped.slots)), "number",
            "coerceIntKeys must turn back JSON's string keys into Lua numbers")
    end)

    it("loadAll/saveAll round-trip both slots independently", function()
        local svc = SaveService:new()
        svc:saveAll({ bankroll = 5 }, { shove_count = 2 })
        local all = svc:loadAll()
        assertEqual(all.meta.bankroll, 5)
        assertEqual(all.run.shove_count, 2)
    end)

    it("rejects a save written under a different schema version", function()
        local svc = SaveService:new()
        -- Write a wrapper by hand with a stale version number, bypassing
        -- SaveService:write (which always stamps the current VERSION).
        local json = require("lib.json")
        local Constants = require("data.constants")
        local stale = json.encode({
            version = Constants.SAVE.VERSION - 1,
            timestamp = os.time(),
            data = { bankroll = 999 },
        }, true)
        love.filesystem.write("meta.save", stale)

        local result, err = svc:read("meta.save")
        assertEqual(result, nil, "a version-mismatched save must not be returned")
        assertEqual(err, "version mismatch")
    end)

    it("clearAll removes both slots", function()
        local svc = SaveService:new()
        svc:saveAll({ bankroll = 1 }, { shove_count = 1 })
        svc:clearAll()
        local all = svc:loadAll()
        assertEqual(all.meta, nil)
        assertEqual(all.run, nil)
    end)
end)

------------------------------------------------------------------------
-- Cleanup + summary
------------------------------------------------------------------------

for _, f in ipairs({ "meta.save", "run.save", "settings.save" }) do
    love.filesystem.remove(f)
end
os.remove(love.filesystem._sandboxDir)  -- only succeeds once empty; fine either way

print(string.format("\n%d passed, %d failed", _pass, _fail))
os.exit(_fail == 0 and 0 or 1)
```

**Note on scope:** this deliberately does not touch `models/outcome_math.lua`'s RNG-driven sampling (`sampleDist`, the actual hand-outcome roll) or `models/Table.lua` / `models/Table_legacy.lua` directly -- those need either dependency injection of the RNG (so a test can fix the sequence and assert exact outcomes) or a statistical test (roll N times, assert the observed distribution is within a tolerance of the declared one). That's real follow-up work, not a first test; it's also entangled with the section-2 finding that nothing in the codebase ever calls `math.randomseed`, which would need to change first for that kind of test to be reproducible.

---

## Player-facing copy, text conventions, and text plumbing


### Note on process (session was interrupted once; this file was rebuilt)

First pass swept the following files for the `{chip}` rule, em-dashes, filler
words, and IconText marker validity and found **no violations**: `data/hints.lua`,
`data/decks.lua`, `data/bankroll_tiers.lua`, `data/catalog_pages.lua`,
`data/opponent_names.lua`, `data/game_types.lua` (name/short fields),
`states/TitleState.lua`, `states/CreditsState.lua`, `views/PrestigeModal.lua`,
`views/HintView.lua`, `views/HintLogPanel.lua`, `views/IconText.lua` /
`data/icons.lua` (all tokens actually used in the codebase — `chip`, `achip`,
`arrow`, `small`/`medium`/`large`/`stack` with `w:`/`l:` prefixes — resolve
correctly; no dangling marker names found anywhere).

All findings below come from an exhaustive grep sweep across `data/`, `views/`,
`states/`, `models/`, `controllers/` for: em/en-dash characters inside string
literals, the words chip/chips/Chips inside string literals, and the filler
words the project's copy rule names explicitly (`this hand`, `a fresh`,
`genuinely`, `simply`, `just`, `actually`, plus a broader pass for `really`,
`very`, `literally`, `basically`). Each hit was then read in context to
confirm player-facing status before being listed as a finding.


### 7a. Text plumbing bugs — `nil`/undefined-variable rendering (highest severity)

**Critical — `views/TablePanelStats.lua:383` — `Expected cash: nilf$X.XX per run` and the sign is stripped**

```lua
local lines = {
    row(header, "md"),
    row("1 bb = " .. fmtMoney((stats.stake and stats.stake.bb) or 0), "sm", "muted"),
    row(string.format("Expected cash: %s$%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
```
`ev_sign` and `ev_color` are never declared in `buildLegacyMttLines` (this
function) or anywhere else in the file — the only similarly-named locals
(`ev_color_token`, `ev_c`) live inside the unrelated `buildCashOverviewRenderRow`
at lines 208-212. Lua reads the undeclared identifiers as globals, which are
`nil`. `string.format("%s", nil)` prints the literal string `"nil"` rather
than erroring, so every legacy-MTT table's stats tooltip reads
`Expected cash: nil$12.40 per run` instead of `+$12.40` / `-$12.40`. Because
`math.abs(net_ev)` also strips the sign, the player has no way to tell a
profitable table from a losing one from this line.
Fix: compute sign/color locally, matching the pattern already used at 208-212:
```lua
local ev_sign  = (net_ev >= 0) and "+" or "-"
local ev_color = (net_ev > 0) and "good" or (net_ev < 0) and "error" or "muted"
...
row(string.format("Expected cash: %s%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
```
(note the original also lacks the `$` placement — `%s$%.2f` prints `-$12.40`
correctly once `ev_sign` is real, so only the two undeclared locals need fixing.)

**Critical — `views/ShoveView.lua:404` — undeclared `BUILDUP_TOTAL` crashes the skip action**

```lua
function ShoveView:skip()
    -- Buildup-skip: jump to ready-to-deal so the host fires the gauntlet
    -- on its next update tick. Player wanted out of the buildup spectacle.
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        self.phase_t = BUILDUP_TOTAL
        return
    end
```
`BUILDUP_TOTAL` is never declared anywhere in this file — the module only
declares `BUILDUP_FADE_DURATION`, `BUILDUP_LOCK_DURATION`,
`BUILDUP_FLIGHT_DURATION`, `BUILDUP_INTERVAL_START/END`, `BUILDUP_MAX_CHIPS`,
`BUILDUP_MIN_CHIPS` (lines 122-128); `BUILDUP_TOTAL` appears only once more,
in a comment at line 162. The elsewhere-used total is a per-instance field,
`self.buildup_total` (lowercase, line 445), not this identifier. So
`self.phase_t = BUILDUP_TOTAL` sets `self.phase_t` to `nil`. The very next
`:draw()` call still matches `self.phase == "ready_to_deal"` (line 879) and
runs:
```lua
local fade_alpha = 1 - math.min(1, self.phase_t / BUILDUP_FADE_DURATION)
```
`nil / 0.5` is "attempt to perform arithmetic on a nil value" — this crashes
the whole draw call, not just a stray string. Every player who presses
SPACE/skip during the buildup spectacle hits this. Fix:
```lua
self.phase_t = self.buildup_total or 0
```

**High — `views/TablePanelStats.lua` (`fmtMoney`/`fmtMoneySigned`) — inline formatting bypasses `utils/format.lua`, overflows at 7+ digits**

```lua
local function fmtMoney(n)
    n = n or 0
    if math.abs(n) >= 100 then return string.format("$%.0f",  n) end
    if math.abs(n) >= 10  then return string.format("$%.1f",  n) end
    return string.format("$%.2f", n)
end
```
This file never `require`s `utils/format.lua` and reimplements money
formatting locally, but unlike `Format.money`/`Format.formatBig` this version
never abbreviates — the `>= 100` branch is unbounded. `data/stakes.lua` goes
up to a $10,000,000 big blind (T8 "ULTRA"), so `win_avg_dollars` /
`loss_avg_dollars` / `ev_dollars` at high stakes are routinely 6-8 digit
dollar amounts. `fmtMoney(23000000)` returns the literal string
`"$23000000"` — 9 characters, no thousands separators, no `K`/`M`
abbreviation — where the rest of the game's money readouts (via
`Format.money`) would show `$23.0M`. This overflows the fixed-width stats
tooltip/panel column at high tiers and reads inconsistently with every other
money display in the game. Same bug propagates through `fmtMoneySigned`
(line 62-65, calls `fmtMoney`) and therefore through `TablePanelStats.evLabel`
(line 70-72), which is shared by the per-table readout AND the stake-add
button labels — so the overflow is not confined to a tooltip, it's on the
main HUD row once bankroll reaches high tiers.
Fix: require `utils/format.lua` and delegate:
```lua
local Format = require("utils.format")
local function fmtMoney(n) return Format.moneyExact(n) end
```
(or add abbreviation to the local function — but the duplication itself is
the underlying defect per the project's `data/`-is-logic-free /
single-source-of-truth convention; two money formatters that can drift is
already a bug independent of the overflow.)

**(unverified) — broader nil-hunt scope note.** A full static undefined-local
scan (attempted via a heuristic script) could not be completed reliably in
this session; the two Critical instances above were found by manual
cross-reference of every `string.format`/`printf` call site with player-facing
`%s` in `views/TablePanelStats.lua` and by reading `views/ShoveView.lua`'s
buildup/skip state machine end-to-end. Every other `string.format(...%s...)`
call site in `views/`, `controllers/`, `states/` was individually checked and
each argument traced to a declared local with an `or` fallback or a
provably-non-nil source (see `views/GrindView.lua:509` "table%s" plural,
`views/TablePanel.lua:923` `positionName`, `controllers/GrindController.lua:81`
`_multSuffix` — all clean). A dedicated pass with a real Lua static analyzer
(luacheck was not available in this environment) would be needed to guarantee
full coverage of `models/` and the remaining `views/` files not read in
depth (`RoomView.lua`, `ChipPile.lua`, `ChipFlight.lua`, `TablePanelEffects.lua`).


### 2. `{chip}` rule violations (literal "chip"/"chips" where the marker belongs)

**Medium — `views/OnboardingModal.lua:33` — marker AND the word together**
```lua
"Win a {stack} stack to bank {chip} gold chips, once per stake/type each run. A gold trim marks the tables and buttons you've already banked.",
```
The `{chip}` glyph already reads as "gold chip(s)" — writing the marker and
then spelling out "gold chips" right after it is redundant, and reintroduces
the literal word the rule bans. Also "a {stack} stack" repeats "stack" twice.
Corrected:
```lua
"Win a {stack} to bank {chip}, once per stake/type each run. A gold trim marks the tables and buttons you've already banked.",
```

**Medium — `views/GrindView.lua:971` — literal "chips" in a tooltip row that CAN'T take a marker as written**
```lua
{ style = "sm", color_token = "muted",
  text = "Bet everything on one all-in hand at the rate below."
      .. " Winning beats the prototype (you can keep playing"
      .. " after). Either way you bank this run's chips to spend"
      .. " in the catalog on permanent upgrades, then a new run"
      .. " starts." },
```
This is a structured `{style=..., text=...}` tooltip row. `services/Tooltip.lua`
`resolveLine`/`draw` renders `text` rows with plain `love.graphics.printf`
(line 141), never through `IconText` — only `render`/`measure` rows (like the
`chip_line` row built two lines below this one, 974-977) go through
`IconText.draw`. So even swapping the word for `{chip}` here would print the
literal braces, not the glyph — this is exactly the "tooltips need a custom
IconText render row" case the project rule calls out. The next row already
states `"Banks +%d {chip} for the catalog."` via a proper `IconText` render
row, so the fix is to drop the redundant currency mention here entirely
(also cuts a duplicate — see §8) rather than try to marker-ize plain text:
```lua
text = "Bet everything on one all-in hand at the rate below."
    .. " Winning beats the prototype; you can keep playing after."
    .. " Either way, a new run starts."
```

**Low (judgment call) — `views/GrindView.lua:328` — "100bb chips" is poker-table jargon, not the {chip} currency**
```lua
mtt = Constants.FEATURES.MTT_KO
     and "8-max KO — sit down with 100bb chips. Hands play normally; seats bust at zero. Win it all or finish top-3 to cash."
```
This describes the MTT starting stack (a poker table's physical chip stack),
not the Gold Chip meta-currency, so it's arguably outside the rule's intent
(the rule targets *currency* copy). Flagging for the user's call since "chips"
still reads ambiguously next to a game that has a real `{chip}` icon. If kept
as prose, cut the word instead of markerizing it — it isn't currency:
```lua
"8-max KO — sit down with a 100bb stack. Hands play normally; seats bust at zero. Win it all or finish top-3 to cash."
```


### 3. Em-dashes in player-facing copy

All confirmed player-facing (rendered via `love.graphics.print(f)`, `IconText.draw`,
`ui:para`, or `Tooltip.set`). `data/effects.lua` dashes and `data/stakes.lua:233`
are excluded — see §"Excluded / not player-facing" at the end.

**`views/AnalyticsConsentModal.lua:13`**
```lua
"If you opt in, the game sends anonymous gameplay summaries: hand outcomes, upgrade choices, shove rates, and session length. The data contains no personal information — no name, account, or device ID. Your IP MAY appear in standard server request logs, as with any web request (unavoidable) but is not used or looked at in any way.",
```
Corrected: `...The data contains no personal information: no name, account, or device ID. Your IP MAY appear...`

**`views/GrindView.lua:324`**
```lua
six_max  = "6-Max — the baseline. Standard pace, 5 seated opponents, no pot-shape bias.",
```
Corrected: `"6-Max: the baseline. Standard pace, 5 seated opponents, no pot-shape bias."`

**`views/GrindView.lua:325`**
```lua
hu       = "Heads-Up — duel with one opponent. Fast pace, you win less often, but pots run deep both ways.",
```
Corrected: `"Heads-Up: duel with one opponent. Fast pace, you win less often, but pots run deep both ways."`

**`views/GrindView.lua:326`**
```lua
zoom     = "Zoom — fast hands, random opponents. Easier to win, but pots smaller overall.",
```
Corrected: `"Zoom: fast hands, random opponents. Easier to win, but pots smaller overall."`

**`views/GrindView.lua:328`**
```lua
and "8-max KO — sit down with 100bb chips. Hands play normally; seats bust at zero. Win it all or finish top-3 to cash."
```
Corrected (also fixes the {chip}-wording flag above): `"8-max KO: sit down with a 100bb stack. Hands play normally; seats bust at zero. Win it all or finish top-3 to cash."`

**`views/GrindView.lua:807`**
```lua
desc_text = "open or rebuy a table first — buying now ends the run"
```
Corrected: `"open or rebuy a table first; buying now ends the run"`

**`views/GrindView.lua:919`**
```lua
iconRow("No Shove — for when you're broke and stuck."),
```
Corrected: `iconRow("No Shove: for when you're broke and stuck."),`

**`views/GrindView.lua:992`**
```lua
TooltipSvc.set(
    "Cash out all tables — refunds each table's current"
    .. " stack to your bankroll.", mx, my)
```
Corrected: `"Cash out all tables: refunds each table's current stack to your bankroll."`

**`views/GrindView.lua:1068-1069`**
```lua
TooltipSvc.set({
    "TABLES — currently open / focus capacity.",
    "FOCUS — multiplier on every $ you win or lose.",
```
Corrected:
```lua
    "TABLES: currently open / focus capacity.",
    "FOCUS: multiplier on every $ you win or lose.",
```

**`views/OnboardingModal.lua:88`** (also see filler §4 — "really")
```lua
note = "Got feedback or found a bug?\nLeave a comment — it really helps!",
```
Corrected: `"Got feedback or found a bug?\nLeave a comment, it helps!"`

**`views/PrototypeEndModal.lua:30`**
```lua
ui:para(
    "Thanks for playing!"
    .. "\n\nYou can keep grinding from here — the run resets and"
    .. " more is coming in future builds.",
    "sm", Theme.fg.muted, "center")
```
Corrected (also see tone §6 — "Thanks for playing!" is off-voice):
```lua
"\n\nYou can keep grinding from here. The run resets and more is coming in future builds."
```

**`views/TablePanel.lua:297`**
```lua
or "Close this table — refunds the current stack.",
```
Corrected: `"Close this table: refunds the current stack.",`

**`views/TablePanelStats.lua:385`**
```lua
row("Win hands in a row — one loss ends the run.", "sm", "muted"),
```
Corrected: `row("Win hands in a row. One loss ends the run.", "sm", "muted"),`

### Excluded from the em-dash list (not player-facing, confirmed)
- `data/effects.lua` (all instances): this table is documentation for
  developers registering effect kinds (comment at top: "Documentation only —
  no logic"); never `require`d by any `views/`/`states/` file, never rendered.
- `data/stakes.lua:233` — `name = "ULTRA — no limit"`: per the schema comment
  at line 33 ("blind-structure descriptor (data doc; not rendered)"), only
  `display_name` (= `"ULTRA"`) is read by `views/GrindView.lua`; confirmed by
  grep that no view reads `stake.name`.
- `views/ShoveDebugOverlay.lua`, `controllers/InputController.lua` (F6/F7
  debug prints), `models/Gauntlet.lua` (`formatResult`, console-only sim
  debug log) — developer/debug-only surfaces, not shown to players in a
  normal build.
- `models/HandEval.lua:64` (`return "—"` for a missing rank tuple) — a bare
  placeholder dash for an empty state rather than a sentence; low-severity
  nit rather than a copy violation, noted under §4/Nit below.


### 4. Filler words / redundant phrasing

**Medium — `views/GrindView.lua:918` — "a fresh" (explicitly named in the project's filler-word rule)**
```lua
iconRow("Banks your {chip} and starts a fresh $2 stake."),
```
Corrected: `iconRow("Banks your {chip} and resets to $2."),`

**Low — `data/catalog.lua:746` — "just"**
```lua
{
    id          = "copy_machine",
    name        = "Copy Machine",
    effect_text = "First denied {chip} each run banks anyway.",
    description = "It just prints another.",
```
Corrected: `description = "It prints another."`

**Low — `views/TablePanel.lua:296` — "this hand" (explicitly named in the rule)**
```lua
tooltip = pending_close
      and "Closing after this hand finishes."
       or "Close this table — refunds the current stack.",
```
Corrected: `"Closing when the hand ends."` (keeps the distinction from the
already-closed state without the flagged phrase; also fixes the sibling
em-dash line, see §3)

**Low — `views/OnboardingModal.lua:88` — "really"**
Already listed under §3 with its em-dash; the combined fix removes both:
`"Got feedback or found a bug?\nLeave a comment, it helps!"`

**Nit — `data/run_upgrades.lua:93` — ungrammatical, not filler exactly, but worth tightening alongside the rest**
```lua
description = "More {w:stack} Less {l:stack} - Drives {chip}",
```
Mid-sentence capitalization and a bare hyphen standing in for punctuation
read as unfinished copy. Corrected: `"More {w:stack}, less {l:stack}, more {chip}"`


### 5. Stack% / banking-odds wording

Checked every string describing the `{w:stack}` win-tier rate or the {chip}
banking gate. All of them correctly describe `{stack}%` as odds of *hitting a
Stack-tier outcome on a hand*, never as odds of banking a `{chip}` (the actual
bank gate is "first Stack win per stake/type per run," a separate, much
rarer, once-per-run condition layered on top of the per-hand Stack rate).
No violations found:

- `views/OnboardingModal.lua:44` — `"...The gold {w:stack} % beside it is your odds of hitting a {w:stack}."` — correctly scoped to "hitting a Stack," not banking.
- `data/hints.lua:86` — `"...The gold {w:stack} % is your chance at a {w:stack} per hand."` — explicitly "per hand," correctly distinct from the once-per-run bank gate.
- `views/GrindView.lua:674-676` — tooltip header `"{stack} rate, next level:"` for the Pot Control upgrade — describes the per-hand Stack rate the upgrade shifts, not a bank probability.
- `data/run_upgrades.lua:96` — `"Graph shows {w:stack}% increase, used to earn {chip}."` — states the causal chain (raising Stack rate → more chances to earn a chip) without claiming the percentage itself IS the bank odds. Borderline-terse but not incorrect; left as-is.
- `views/TablePanelStats.lua` win/loss mix rows — tier percentages are per-hand
  outcome-distribution shares, never labeled as bank odds.

No corrections needed in this category.


### 6. Other text plumbing checks

- **IconText marker validity**: every `{token}` used across `data/` and
  `views/` (`chip`, `achip`, `arrow`, `small`/`medium`/`large`/`stack`, and
  `w:`/`l:`-prefixed tier variants) matches a case `views/IconText.lua`'s
  `drawToken`/`tokenWidth` actually handles, and `chip`/`achip` both have
  entries in `data/icons.lua`. No dangling marker names found. Note the
  fallback behavior for an unknown token is not "blank or crash" as the
  general bug class warns — `views/IconText.lua:89-90` falls back to
  printing the raw `{token}` text literally — but that's still a real bug
  class (a typo'd marker would visibly leak literal braces to the player);
  it just didn't occur anywhere in this codebase.
- **Pluralization by concatenation**: the one spot doing manual
  singular/plural (`views/GrindView.lua:509-511`, `"table%s"` with
  `open_n == 1 and "" or "s"`) is correct — no "1 chips"-style bug found
  anywhere in the sweep.
- **Numbers formatted inline instead of via `utils/format.lua`**: see §7a
  above — `views/TablePanelStats.lua`'s local `fmtMoney`/`fmtMoneySigned`
  duplicate `utils/format.lua`'s job with a materially different (unbounded,
  non-abbreviating) implementation. This is both a duplication risk (two
  money formatters that can drift, violating the project's single-source
  convention) and the confirmed overflow bug at high stakes.
- **Per-frame string building**: not flagged as a class of bug here — this
  codebase is immediate-mode LÖVE UI where rebuilding label strings every
  `draw()` call is the norm throughout (`GrindView`, `TablePanel`,
  `TablePanelStats` all do it constantly for dynamic HUD numbers). Nothing
  found that rebuilds an unusually large or expensive string every frame
  beyond that baseline pattern.


### 8. Duplicated copy

**Low — `views/GrindView.lua:964` and `:971` say the same thing twice in one tooltip**
```lua
local chip_line  = string.format("Banks +%d {chip} for the catalog.", pending)
...
local lines = {
    { style = "sm", color_token = "muted",
      text = "Bet everything on one all-in hand at the rate below."
          .. " Winning beats the prototype (you can keep playing"
          .. " after). Either way you bank this run's chips to spend"
          .. " in the catalog on permanent upgrades, then a new run"
          .. " starts." },
    { measure = function(fonts) local f = fonts.sm
          return IconText.measure(chip_line, f), f:getHeight() end,
      render  = function(x, y, fonts)
          IconText.draw(game, chip_line, x, y, fonts.sm, chip_color, 1) end },
}
```
Both the plain-text row and the `chip_line` row tell the player their
`{chip}` gets banked to the catalog — the plain-text row says it in prose
("you bank this run's chips to spend in the catalog on permanent upgrades")
immediately above the glyph row that says the same thing precisely ("Banks
+%d {chip} for the catalog."). If the exact bank amount or the catalog
destination ever changes, only one of the two lines is likely to get
updated. Fix: cut the redundant clause from the prose row (already applied
in the §2 correction above) so the fact lives in exactly one place — the
`{chip}`-glyph row, which is also the one place that shows the live number.

**Nit (documented, not a drift risk) — `"Start a new game? Existing save will be erased."` / `"Quit the game?"` appear in both `states/TitleState.lua:130,150` and `views/SettingsModal.lua:87,95`.** A comment at `SettingsModal.lua:83` explicitly flags this as an intentional mirror ("Mirrors the title-screen 'Start' confirmation verbatim"), so it's a maintained duplicate rather than accidental drift — noting it here only so a future edit to one copy remembers to update the other.

### 6b. Tone consistency

**Low — `views/PrototypeEndModal.lua:27` — "Thanks for playing!" reads as generic warm idle-game copy, not the captor voice**
```lua
ui:para(
    "Thanks for playing!"
    .. "\n\nYou can keep grinding from here — the run resets and"
    .. " more is coming in future builds.",
    "sm", Theme.fg.muted, "center")
```
The rest of the game's voice is deadpan/institutional — `"Thanks for your
participation, open a table."` (`data/hints.lua:52`), `"you walked out."` /
`"the gauntlet cleared. the room is empty behind you."`
(`states/CreditsState.lua`). A sincere exclamation-mark "Thanks for playing!"
breaks that register. Suggested: `"That's the prototype."` (matches the
line right above it, `"That's the end of the prototype."`, and drops the
enthusiasm without losing information) or fold it into the following
sentence entirely.

No other tone breaks found — `data/hints.lua`, `views/OnboardingModal.lua`,
and `data/catalog.lua` flavor text stay consistently dry/institutional
throughout the sweep.


### 1. Inventory of player-facing strings (by file)

Grouped summary from the full sweep; see §2-8 above for every flagged line.

| File | What it holds |
|---|---|
| `data/hints.lua` | Captor-voice tutorial hint titles + bubble text (`title`, `text` fields), ~17 hints, `{icon}` markers throughout |
| `data/catalog.lua` | 40+ catalog items: `name`, `effect_text`, `description` (flavor), `unlock.text` |
| `data/catalog_pages.lua` | Department shelf titles ("Value Buys", "Bed & Bath", etc.) |
| `data/decks.lua` | 12 decks: `name`, `flavor_text`, `bonus_text`, `xp_action_text`, `capstone.text`, `unlock.text` |
| `data/stakes.lua` | `display_name` (player-facing, e.g. "NL10"); `name` is a dev-only doc field, not rendered |
| `data/game_types.lua` | `name`/`short` per game type ("Tournament"/"MTT", "6-max"/"6-MAX", etc.) |
| `data/bankroll_tiers.lua` | Tier `label`s shown in the SHOVE breakdown tooltip ("Sub-T1".."T8") |
| `data/run_upgrades.lua` | `name`, `description`, `tooltip_blurb` for 5 run upgrades |
| `data/opponent_names.lua` | Flat list of random opponent display names (pure flavor) |
| `data/effects.lua` | Dev-only schema documentation — never rendered, excluded from player-facing findings |
| `views/OnboardingModal.lua` | Full "HOW TO PLAY" modal: intro callout, THE LOOP/UPGRADES/TIPS/WINNING bullets, GLOSSARY term/definition pairs |
| `views/AnalyticsConsentModal.lua` | Consent modal body (4 paragraphs) + button labels |
| `views/PrototypeEndModal.lua` | End-of-prototype modal body + button labels |
| `views/PrestigeModal.lua` | Post-bust "BUSTED" summary copy |
| `views/GrindView.lua` | Largest surface: game-type hover blurbs, SHOVE/Cash-Out/Quick-Reset/Tied-Up/Focus tooltips, deck tooltip, upgrade row `desc_text`/`level_text`/`cost_text` |
| `views/TablePanel.lua` | Per-table hover tooltips (close/rebuy), FINISH/ALIVE counter labels, "Depth" label |
| `views/TablePanelStats.lua` | Cash-table and MTT stats readouts: EV lines, win/loss rate headers, payout ladder rows |
| `views/CatalogModal.lua` | Catalog book chrome: item cost text, "No. 0XX" index codes, "Items active in room" counter |
| `views/HintView.lua` / `HintLogPanel.lua` | Hint bubble chrome ("click to dismiss"), help-desk empty state ("Nothing on file yet"), "HELP DESK" header |
| `views/SettingsModal.lua` | Settings row labels ("Save now", "Load save", "Start new game", "Quit"), volume %, confirm-dialog prompts |
| `views/DeckSelectModal.lua` | Deck-picker chrome: "LOCKED", "ACTIVE", level text, unlock/capstone/XP-action section labels, footer notes |
| `states/TitleState.lua` | Title-screen buttons + 3 confirm-dialog prompts (new game / delete save / quit) |
| `states/CreditsState.lua` | Minimal end-of-gauntlet screen ("you walked out.", key hints) |
| `controllers/GrindController.lua` | Floating-text payout strings (`"+%d {chip}"`, pot/mult suffix) |
| `models/HandEval.lua` | `describe()` — player-readable hand rank labels ("pair of Aces", "Jack-high straight") shown on player + board hand readouts |

Numeric-heavy data files (`data/mtt_payouts.lua`, `data/mtt_finish_dist.lua`,
`data/mtt_hand_count.lua`, `data/mtt_bust_pacing.lua`, `data/pot_tiers.lua`,
`data/poker_*_weights/sizing/timings.lua`, `data/felt_layout.lua`,
`data/room_layout.lua`, `data/animations.lua`, `data/cinematic_timelines.lua`,
`data/sounds.lua`, `data/theme.lua`) were checked and contain no player-facing
string literals — pure numeric/positional tuning tables, sprite paths, or
internal ids only.


---

## Crash risk and Lua-specific defect sweep

Scope: every `.lua` outside `build/` and `build-tools/node_modules/`. Read-only audit.

### Method

Static sweep of 147 `.lua` files (36.8k LOC). Two mechanical passes backed the
manual read:

- **Compile check**: `luac -p` on every file — all 147 compile clean, no syntax defects.
- **Bytecode global-access scan**: `luac -l -l -p <file> | grep _ENV` on every file,
  which lists every global read (`GETTABUP _ENV "name"`) and every global write
  (`SETTABUP _ENV "name"`). This is exact, not heuristic.
  - **Zero `SETTABUP _ENV` in the entire repo** → there is not a single accidental
    global write (forgotten `local`) anywhere. Category 7 (write side) is clean.
  - Global *reads* resolve to stdlib/`love`/`require` everywhere **except three
    names that do not exist**: `BUILDUP_TOTAL`, `ev_sign`, `ev_color`. All three
    are reported below; the first is a hard crash in `love.draw`.

---

### CRITICAL

#### C1 — `views/ShoveView.lua:404` — pressing SPACE during the shove buildup nils `phase_t`, then `love.draw` crashes

```lua
function ShoveView:skip()
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        self.phase_t = BUILDUP_TOTAL      -- undefined global → nil
        return
    end
```

`BUILDUP_TOTAL` is not defined anywhere in the repo (confirmed by the bytecode
scan: it compiles to `GETTABUP _ENV "BUILDUP_TOTAL"`, and there is no matching
write anywhere). The intended name is the instance field `self.buildup_total`,
which is what the natural exit path at `ShoveView.lua:445` actually compares
against:

```lua
if self.phase_t >= (self.buildup_total or 0) then
    self.phase = "ready_to_deal"
```

So `skip()` sets `self.phase_t = nil`. The very next draw frame:

```lua
-- ShoveView.lua:879
if self.phase == "buildup" or self.phase == "ready_to_deal" then
    self:_drawBuildup(W, H)
-- ShoveView.lua:549 inside _drawBuildup
local fade_t = math.min(1, self.phase_t / BUILDUP_FADE_DURATION)
```

`nil / 0.5` → `attempt to perform arithmetic on a nil value (field 'phase_t')`,
thrown inside `love.draw`. Unrecoverable — the LÖVE error screen, run lost.

**Trigger sequence (a player will do this):** enter the Shove screen → the
chips-fly-into-the-pot buildup starts → press SPACE to skip the animation.
`ShoveState.lua:394-398` routes SPACE to `view:skip()` whenever
`view:isAnimating()` is true, and `isAnimating()` returns true for
`phase == "buildup"` (`ShoveView.lua:375`). This branch is **not** gated on
`FEATURES.DEV_HOTKEYS` — the gate at `ShoveState.lua:401` sits below it, with
the comment "SPACE during the cinematic = skip ... stays in every build."
Impatient players skip cinematics; this is a first-session-reachable crash.

Fix is one identifier: `self.phase_t = self.buildup_total or 0`.

### HIGH

#### H1 — `views/TablePanelStats.lua:383` — two more undefined globals, `%s`-formatted, in the prototype/itch build's tournament tooltip

```lua
local lines = {
    row(header, "md"),
    row("1 bb = " .. fmtMoney((stats.stake and stats.stake.bb) or 0), "sm", "muted"),
    row(string.format("Expected cash: %s$%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
```

`ev_sign` and `ev_color` are undefined globals (bytecode scan: `GETTABUP _ENV
"ev_sign"` / `"ev_color"` with no write anywhere). The sibling function
`buildMttLines` computes locals of those names; this one was copied without
them. Compare `TablePanelStats.lua:208-212`, which correctly builds
`ev_color_token` as a **local**.

Two consequences:
- `string.format("%s", nil)` — LuaJIT tolerates it and prints `nil`, so the
  desktop build shows `Expected cash: nil$4.00 per run`. **Vanilla Lua 5.1
  (which the love.js web build uses) raises `bad argument #2 to 'format'
  (string expected, got nil)`** — thrown inside the tooltip build, which runs
  from the draw path. `(unverified: which Lua the web export ships)` — confirm
  by checking whether the itch web export is love.js/Emscripten (no LuaJIT).
- The `%s` slot was meant to hold the sign, so even on desktop the number is
  printed via `math.abs()` with no sign at all: a negative EV renders as a
  positive one.

**Reachability:** `breakdownFromStats` (`TablePanelStats.lua:879`) dispatches to
`buildLegacyMttLines` when `gt.hand_count` is set and `gt.chip_stack_table` is
not. Per `data/game_types.lua:71-82`, the `mtt` entry has `hand_count = 8` only
when `FEATURES.MTT_KO` is false, i.e. `PROTOTYPE_MODE = true` — the itch build.
So this fires on the shipped prototype, not the current dev build.
**Trigger:** run a Tournament table, hover its `$/h` EV readout.

#### H2 — `views/TablePanelStats.lua:377,382` — `stats.stake` deref without the guard used one line later

```lua
local header = string.format("%s · %s",
    stats.stake.display_name or stats.stake.id or "?",
    gtype.short              or gtype.id       or "?")
```

Line 382 immediately below guards the same field — `(stats.stake and stats.stake.bb) or 0`
— and line 349 guards it too (`(stats.stake and stats.stake.buy_in) or 0`). Line
377 does not. If `stats.stake` is ever nil, this is `index a nil value` in a
tooltip build. Same unguarded/guarded inconsistency means one of the two beliefs
is wrong; the guarded ones are the majority. Also note `gtype` at 344 comes from
`stats.gtype` with no guard, while the caller at 877 explicitly tests `if gt and
...` — so the callee assumes non-nil what the caller treats as nullable.

#### H3 — `lib/json.lua:41-43` — `inf` / `-inf` serialize to a token this decoder cannot read; one such value silently wipes the entire save

```lua
elseif t == "number" then
    if val ~= val then return "null" end  -- NaN guard
    return tostring(val)
```

NaN is guarded, infinity is not. `tostring(math.huge)` is `"inf"` on LuaJIT / `"1e+308"`-class values are fine, but `inf` and `-inf` are not JSON. On the next load:

- `decode_value` (`json.lua:206`) sees `i`, falls through to the `else` at 211 → `error("unexpected character 'i'")`.
- `SaveService:read` (`SaveService.lua:57-60`) catches it and returns `nil, "decode failed"`.
- `main.lua:186-187` — `GameState:new(saved)` with a nil payload — starts a **brand new game**.

The player's whole run and meta progress disappear with no message. There is no
backup slot and no "corrupt save" branch anywhere in the codebase (`grep`ed:
`SaveService` has no recovery path). Same class of loss applies to any encode
error: `json.encode` is called *unprotected* at `SaveService.lua:75`, so
`error("json.encode: unsupported type 'function'")` (line 91) propagates out of
the autosave tick.

Related, same file: `decode_array` at `json.lua:185` does `table.insert(arr, val)`
where `decode_value` returns `nil` for a JSON `null` (line 207) — a null in the
middle of an array silently shortens it rather than preserving position.

#### H4 — `services/SaveService.lua:61-63` — a `SAVE.VERSION` bump deletes every existing player's progress

```lua
if decoded.version ~= VERSION then
    return nil, "version mismatch"
end
```

`VERSION` is 1 (`data/constants.lua:157`) and has never been bumped, so nothing
has fired yet. But there is no migration hook: the *first* bump silently
discards every save on itch. The migration machinery that does exist
(`GameState:applySaved`, `_migrateDeckState`) is keyed on field presence, not on
version, so it would never run — the payload is thrown away before it is
reached. Given the project rule "save back-compat is required", this is a
loaded gun rather than a live defect.

---

### Category 1 — every `table.remove` loop in the repo (exhaustive)

29 `table.remove` call sites. **None is a forward-loop removal bug.** Every
in-loop removal either walks backwards (`for i = #t, 1, -1`) or `return`s
immediately after removing. Table below is the full audit so this can be
re-checked cheaply later.

| file:line | shape | verdict |
|---|---|---|
| `controllers/HintController.lua:85` | `for i = #ids, 1, -1` | safe (reverse) |
| `core/event_bus.lua:45` | `for i = 1, #taps` **forward** | safe — `return` on the same branch, loop never continues |
| `data/catalog.lua:1000` | `for i = #items, 1, -1` | safe (reverse) |
| `models/Deck.lua:38` | `table.remove(self.cards)` (pop, no loop) | safe |
| `models/Deck.lua:50` | `for i, c in ipairs(self.cards)` **forward** | safe — `return true` immediately after |
| `models/Gauntlet.lua:150,153` | backtracking pop, no index | safe |
| `models/HandEval.lua:196` | `table.remove(picked)` pop | safe |
| `models/MttSession.lua:368` | `for i = #plan.bust_schedule, 1, -1` | safe (reverse) |
| `models/MttSession.lua:403` | `for i = #plan.bust_schedule, 1, -1` | safe (reverse) |
| `models/Table.lua:854` / `Table_legacy.lua:878` | `remove(t,1)` cap trim, no loop | safe |
| `models/TablePool.lua:160` | bounds-checked at 159, no loop | safe |
| `services/CursorPool.lua:177` | `for i = #_ripples, 1, -1` | safe (reverse) |
| `services/FlightSystem.lua:86` | `remove(_flying,1)` overflow drop, no loop | safe |
| `services/FlightSystem.lua:288,302` | `for i = #_flying, 1, -1` / `#_scheduled_sounds, 1, -1` | safe (reverse) |
| `services/FloatingTextSystem.lua:28` | `remove(_texts,1)` cap trim, no loop | safe |
| `services/FloatingTextSystem.lua:73,102` | `for i = #_texts, 1, -1` | safe (reverse) |
| `services/Ghosts.lua:40` | `for i = #_ghosts, 1, -1` | safe (reverse) |
| `views/ChipPile.lua:374` | `table.remove(b)` pop | safe |
| `views/ChipPile.lua:429` | `for i, c in ipairs(e.chips)` **forward, removes AND inserts** | safe — `return true` immediately after (see M1 below) |
| `views/ChipPile.lua:483` | `for i = #e.chips, 1, -1` | safe (reverse) |
| `views/HintView.lua:414` | `for i = #order, 1, -1` | safe (reverse) |
| `views/RoomView.lua:1109` | single removal by index, no loop | safe |
| `views/RoomView.lua:1118,1159` | `for i = #self.placed, 1, -1` | safe (reverse) |
| `views/widgets/Sticker.lua:86` | `table.remove(words)` pop | safe |

**Category 1 verdict: clean.** This is a genuinely well-disciplined codebase on
the removal-loop axis.

### Category 7 — accidental globals

**Clean, verified mechanically.** `luac -l -l -p` over all 147 files produces
**zero** `SETTABUP _ENV` instructions — there is not one accidental global write
in the repo. The only defects on the global axis are the three *reads* of names
that were never defined (C1, H1).

### Category 10 — `os.time` / `os.date` / `os.clock`

**No exposure. The game grants no offline progress at all.** Full census of
wall-clock usage:

- `services/SaveService.lua:72` — `timestamp = os.time()` written into the save
  wrapper and **never read back** (`SaveService:read` returns only `decoded.data`).
- `models/GameState.lua:17` — `string.format("%d_%05d", os.time(), math.random(10000, 99999))`
  for the analytics `save_id`.
- `services/HandAnalytics.lua:77` — `started_at = os.time()` on the analytics run record.

`os.date` and `os.clock` appear nowhere. Every gameplay/animation clock is
`love.timer.getTime()` (monotonic) or accumulated `dt`. So: no elapsed-time
computation exists, no negative-elapsed path exists, and moving the system clock
cannot produce currency. Nothing to fix.

One Nit inside that census — `models/GameState.lua:17`:

```lua
return string.format("%d_%05d", os.time(), math.random(10000, 99999))
```

`math.randomseed` is never called anywhere in the repo (grep: zero hits), and
this is plain `math.random`, not LÖVE's auto-seeded `love.math.random` (which
the rest of the codebase correctly uses for all gameplay rolls). Two players
starting a fresh save in the same second get the same `save_id`. Analytics-only
impact, no gameplay effect.


---

## Cross-validation against the prior audit (`docs/aug2026 audit kimi k3.md`)

A previous audit by another model sits in `docs/`. Re-checking its claims against
today's tree is worth doing for two reasons: it tells you which findings were
acted on, and it catches the ones that were wrong.

### Every god file has grown since that audit

The prior audit's line counts versus today's:

| File | Then | Now | Change |
|---|---:|---:|---:|
| `views/GrindView.lua` | 2,244 | 2,455 | **+211** |
| `controllers/GrindController.lua` | 1,683 | 1,800 | **+117** |
| `views/TablePanel.lua` | 1,584 | 1,725 | **+141** |
| `views/RoomView.lua` | 1,265 | 1,380 | **+115** |
| `views/CatalogModal.lua` | 1,158 | 1,294 | **+136** |
| `models/Table.lua` | 949 | 1,022 | **+73** |
| `models/GameState.lua` | 747 | 747 | 0 |

Not one god file shrank. Six of seven grew, by 793 lines in total. The
decomposition seams the prior audit proposed were not taken, and every file it
named as too big has since absorbed more. That is the single most useful number
in this document: the trend is away from the target architecture, not toward it.

### Claims re-verified as still live

- **`data/catalog.lua` load-time logic — still live, and it grew.** Lines 85 (`require("data.constants")`), 998-1003 (`table.remove` loop under `Constants.FEATURES.TUTORIAL`), and 1005-1027 (`require("data.balance")` plus a mutation loop over every item). The uncommitted `+26` lines on this file *added* the Balance derivation block, so the rule-3 violation was actively deepened since the last audit. The `if eff.kind == "shove_rate_add"` kind-chain is at line 1015.
- **`services/FloatingTextSystem.lua:108` — still returns the live internal table.**
  ```lua
  function FloatingTextSystem.getTexts()
      return _texts
  end
  ```
  Any caller can insert into or clear the service's internal list. This file is in the uncommitted diff and the leak survived the edit.
- **`services/Confetti.lua` and `views/widgets/Dropdown.lua`** — both still unreferenced.

### One prior claim is wrong, and the correction matters

The prior audit called `views/TablePanelStats.lua:383` a crash: *"references
undefined locals `ev_sign` and `ev_color`... Crashes the moment the legacy-MTT
tooltip renders. Real crash bug."*

The undefined locals are real. The crash is not. Verified:

```lua
-- views/TablePanelStats.lua:383, inside buildLegacyMttLines (starts line 342)
row(string.format("Expected cash: %s$%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
```

`ev_color_token` and `ev_c` are defined at lines 208-212 — inside a *different*
function. Inside `buildLegacyMttLines`, both `ev_sign` and `ev_color` are
undeclared, so they resolve to `nil` globals.

Neither path throws:
- `string.format("%s", nil)` renders `"nil"` rather than erroring. Confirmed by running it: `Expected cash: nil$3.50 per run`.
- `row(text, style, color)` at line 85 only stores `color_token = color`, so a nil colour degrades to the default token.

So the real defect is **a wrong string shown to the player, not a crash** — which
makes it worse in one specific way: a crash gets reported, silently wrong EV copy
does not. And the bug is compound, because `math.abs(net_ev)` strips the sign
that `ev_sign` was meant to restore:

```lua
local net_ev = buy_in * (exp_mult - 1)   -- line 345, freely negative
```

A player reading the legacy MTT tooltip sees `Expected cash: nil$12.40 per run`
with **no way to tell whether the EV is positive or negative**. A losing table
and a winning table render identically. Severity: **High**, and the fix is two
lines:

```lua
local ev_sign  = (net_ev < 0) and "-" or "+"
local ev_color = (net_ev < 0) and "error" or "good"
```

The lesson for reading the rest of this document: an unverified severity label
can be wrong in either direction. Findings below are marked PROVEN where they
were executed or directly traced, REASONED where they were not.

---
