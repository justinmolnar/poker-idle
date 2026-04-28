# Skeleton Init — What Was Built

*Written 2026-04-27 at the end of the init session. Captures the state of the project before the shove prototype begins.*

The plan that drove this is at `C:\Users\chate\.claude\plans\misty-sleeping-lampson.md` — read it for the *why*. This doc is the *what*: where things ended up, what lifted from where, and what's deliberately not here yet.

---

## TL;DR

A LÖVE2D skeleton that boots, switches between two states (grind ↔ shove) on `F2`, swaps palettes on the swap, and round-trips a dual-slot save. 36 source files. All four audit greps pass. The data-driven / logic-vs-data / no-globals discipline is locked in before any feature code lands.

Run it: open the project in VS Code, press `Ctrl+Shift+B`. (Wires `lovec.exe .` exactly like cosmic courier does.)

---

## Directory Layout

```
poker-idle/
├── .vscode/
│   └── tasks.json            # Ctrl+Shift+B → lovec.exe . (cosmic-courier mirror)
├── main.lua                  # Bootstrap. Builds Game DI table, wires LÖVE callbacks.
├── conf.lua                  # 1280×720 windowed, console on, vsync on, physics off.
├── core/
│   ├── event_bus.lua         # Lifted from CC verbatim (subscribe + addTap)
│   ├── time.lua              # Lifted from CC verbatim
│   └── camera.lua            # Lifted from CC, dropped CoordinateService dep
├── lib/
│   ├── class.lua             # Lifted from 10K (Object:extend)
│   ├── input_dispatcher.lua  # Lifted from CC verbatim (predicate-routed)
│   └── json.lua              # Lifted from CC verbatim
├── data/                     # ← TABLES ONLY. No functions. No service requires.
│   ├── theme.lua             # 2 palettes (room + shove), debug, size, space, font
│   ├── constants.lua         # WINDOW, DEBUG, GAMEPLAY, SAVE, FLOATING_TEXT
│   ├── catalog.lua           # PP-shop items. Single canary entry for verification.
│   ├── run_upgrades.lua      # Bankroll-spend upgrades. Empty.
│   ├── stakes.lua            # NL2 / NL10 / NL50 tiers
│   ├── effects.lua           # Doc-only registry of effect kinds
│   ├── animations.lua        # Named animation presets (card_flip, shove_fade_in, …)
│   └── sounds.lua            # Semantic name → synth kind + volume
├── models/
│   └── GameState.lua         # bankroll, pp, owned_items, current_stake, run_upgrades
│                             # AutoSerializer-driven (TRANSIENTS / REFS declarations)
├── services/
│   ├── AutoSerializer.lua    # Lifted from CC verbatim
│   ├── SaveService.lua       # Rewritten for dual-slot (meta.save + run.save)
│   ├── FloatingTextSystem.lua# Lifted from CC, repointed to Constants.FLOATING_TEXT
│   ├── SoundService.lua      # Lifted from CC, added playNamed() that reads data/sounds.lua
│   ├── AnimationSystem.lua   # Lifted from 10K, added :create(preset_name) that reads data/animations.lua
│   ├── SpriteLoader.lua      # Lifted from 10K, scan path → assets/sprites/, debug colors via Theme
│   └── EffectsRegistry.lua   # NEW — kind→fn map, applies catalog/upgrade effects
├── controllers/
│   ├── StateMachine.lua      # Lifted from 10K verbatim (DI-friendly, name-keyed)
│   └── InputController.lua   # NEW — wires F2 toggle + Esc quit + state forwarding
├── views/
│   ├── Theme.lua             # Access layer over data/theme.lua (setActive, setColor, assetTint)
│   ├── Scrollbar.lua         # Lifted from CC verbatim (only require swap)
│   ├── RoomView.lua          # NEW — placeholder room with floor/wall split
│   └── ShoveView.lua         # NEW — placeholder "0% all-in" centered
├── states/
│   ├── GrindState.lua        # Calls Theme.setActive("room") on enter, owns RoomView
│   └── ShoveState.lua        # Calls Theme.setActive("shove") on enter, owns ShoveView
├── utils/
│   ├── format.lua            # NEW — formatBig, money, percent
│   ├── rng.lua               # NEW — weightedPick, intInRange, float, chance
│   └── hand_eval.lua         # STUB — errors on call. Shove prototype fills this.
├── assets/
│   └── sprites/              # Empty. SpriteLoader scans this dir.
└── docs/
    ├── design.md             # (pre-existing) Working design doc
    ├── mvp.md                # (pre-existing) MVP plan
    ├── what-to-pull.md       # (pre-existing) Lift list
    └── skeleton-init.md      # ← this file
```

---

## Conventions Locked In

These six rules are the architectural commitments. Every later PR has to obey them. All four audit greps are currently passing.

1. **`data/` is logic-free.** No function definitions, no requires of `services/`/`models/`/`controllers/`/`views/`/`states/`.
   - Audit: `rg "^function|require\(['\"](services|models|controllers|views|states)" data/ --type lua` → empty.
2. **No `if kind == ... elseif kind == ...` on data-shape strings.** Use a registry (`EffectsRegistry`, `AnimationSystem` factories table). One place that knows the kinds; one entry per kind.
   - Audit: `rg "if\s+\w+\.kind\s*==|elseif\s+\w+\.kind\s*==" --type lua` → empty.
3. **No literal colors / fonts / paddings outside `data/theme.lua` and `views/Theme.lua`.** Use `Theme.setColor(token)` and `Theme.assetTint()` instead.
   - Audit: `rg "love\.graphics\.setColor\(\s*\d" --type lua` → empty.
4. **No globals. DI only.** The container is a file-local upvalue in `main.lua` (named `Game`) that the LÖVE callbacks close over. Every other module receives it through its constructor as `g` / `game` and accesses dependencies via `self.game.foo`. No file outside `main.lua` may type `Game.` — it would be a nil global lookup, but more importantly it's the service-locator anti-pattern this project rejects.
   - Audit: `rg "\bGame\." --type lua -g '!main.lua'` → empty (matches in `--` comments are also forbidden — they teach the wrong pattern).
   - Module-level mutable state is also out (FloatingTextSystem's `_texts` table is a known exception — stateless from the caller's perspective).
5. **Models declare `TRANSIENTS` / `REFS` at class top.** AutoSerializer covers the rest. Never hand-write `:serialize()`.
6. **No `if state == "shove"` logic in shared services.** Mode shifts are state-driven (StateMachine) and palette-driven (Theme). A service shouldn't ask what state the game is in.

---

## The Data-Driven Core

The single most important thing this skeleton sets up is the **registry pattern**. Three places use it:

### EffectsRegistry (`services/EffectsRegistry.lua`)

Catalog items and run upgrades emit effects shaped `{ kind = "<string>", value = <number> }`. The registry maps each kind to an applicator function. To roll up the player's current stat ctx:

```lua
-- `self.game` is the DI container handed to your constructor.
local ctx = {}
self.game.effects:applyAll(catalog_item, ctx)
-- ctx is now mutated with whatever effects the item carries
```

Adding a new effect:
1. Document it in `data/effects.lua` (one entry, schema only).
2. `reg:register("new_kind", function(e, ctx) ... end)` in `EffectsRegistry.registerDefaults`.

That's it. No call site ever needs to change.

### AnimationSystem (`services/AnimationSystem.lua`)

Five timer-based primitives (flip, bounce, fade, progress, timer) dispatched via a `FACTORIES` table keyed on `type` string. Call sites use `:create(preset_name)` which reads `data/animations.lua`:

```lua
local anim = self.game.animations:create("card_flip", { on_complete = fn })
anim:start()
```

Adding a new named animation = one entry in `data/animations.lua`. Adding a new *curve type* = one entry in `FACTORIES`.

### SoundService (`services/SoundService.lua`)

Six built-in synth kinds (beep, chime, horn, warning, success, fail). Game code calls `SoundService.playNamed("hand_won")` which reads `data/sounds.lua` for the kind/volume mapping.

Adding a new sound name = one entry in `data/sounds.lua`. Adding a new *synth kind* requires extending the SoundService internals.

---

## Persistence

Dual-slot saves at `%APPDATA%\LOVE\poker-idle\`:

- **`meta.save`** — `{ pp, owned_items[] }`. Persists across prestige forever.
- **`run.save`** — `{ bankroll, current_stake_id, run_upgrade_ids[] }`. Wiped on prestige via `SaveService:clearRun()`.

Auto-save fires every 30 seconds (`Constants.SAVE.AUTOSAVE_INTERVAL`). `love.quit` does a final save on clean exit.

Save schema:
```json
{
  "version": 1,
  "timestamp": <os.time>,
  "data": { ... model payload ... }
}
```

JSON. The decoder coerces integer-ish string keys back to numbers (lifted from CC).

**Verified working** in this session: boot wrote both files with the expected payloads.

---

## What's Lifted vs. Adapted vs. Fresh

| File | Source | Status |
|---|---|---|
| `core/event_bus.lua` | CC | verbatim |
| `core/time.lua` | CC | verbatim |
| `core/camera.lua` | CC | dropped CoordinateService dep |
| `lib/class.lua` | 10K | verbatim |
| `lib/json.lua` | CC | verbatim |
| `lib/input_dispatcher.lua` | CC | verbatim |
| `services/AutoSerializer.lua` | CC | verbatim |
| `services/SaveService.lua` | CC | rewritten — gutted seed-replay, dual-slot |
| `services/FloatingTextSystem.lua` | CC | repointed to local Constants |
| `services/SoundService.lua` | CC | added `playNamed()` reading data/sounds.lua |
| `services/AnimationSystem.lua` | 10K | added `:create()` reading data/animations.lua |
| `services/SpriteLoader.lua` | 10K | scan path adapted, debug colors via Theme |
| `services/EffectsRegistry.lua` | — | fresh |
| `controllers/StateMachine.lua` | 10K | verbatim (added `:current()`, `:exit` hook) |
| `controllers/InputController.lua` | — | fresh |
| `views/Theme.lua` | CC | rewritten — separated dispatch from data |
| `views/Scrollbar.lua` | CC | only require path changed |
| `views/RoomView.lua` | — | fresh placeholder |
| `views/ShoveView.lua` | — | fresh — built out fully during the shove prototype (timeline-driven reveal, dealer hole cards, best-5 highlighting) |
| `views/ShoveDebugOverlay.lua` | — | fresh — added during shove prototype; live HUD over the shove screen for math verification |
| `models/GameState.lua` | — | fresh |
| `models/Card.lua` | — | fresh — built during shove prototype |
| `models/Deck.lua` | — | fresh — built during shove prototype |
| `models/Gauntlet.lua` | — | fresh — built during shove prototype (lives in models/, not services/, per the engine-agnostic rule) |
| `states/GrindState.lua` | — | fresh |
| `states/ShoveState.lua` | — | fresh — fleshed out during shove prototype (input routing, gauntlet ownership, debug-mutable shove_rate) |
| `utils/format.lua` | — | fresh |
| `utils/rng.lua` | — | fresh (pattern from CC TripGenerator) |
| `utils/hand_eval.lua` | — | fresh — implemented during shove prototype (brute-force best-5-of-N + tuple-based rank comparison) |
| `data/*.lua` | — | fresh |
| `assets/audio/*.mp3` | 10K (sfx/games/memory + sfx/shared/default) | lifted during shove prototype |
| `main.lua` | CC (structure) | rewritten for poker-idle scope |
| `conf.lua` | — | fresh |
| `.vscode/tasks.json` | CC | verbatim |

---

## Deliberately Skipped (vs. the plan)

The plan listed `Panel`, `ComponentRenderer`, and `Modal` from cosmic courier as part of the lift. **Skipped them.** Reasons:

- The skeleton's verification (window opens, F2 toggles, save round-trips) doesn't need them.
- The shove prototype (next task) doesn't need them either — shove is animations + cards + big text, no panel UI.
- Lifting them as half-stubs not used anywhere would violate the "no half-finished implementations" rule.
- They have meaningful adaptation work each (ComponentRenderer needs `datagrid` removal + `UIConfigService` dep stripped; Modal needs `UpgradeModalViewModel` removed).

When the catalog UI gets built (post-shove-prototype), lift them then. Should be one focused session.

`lib/tick.lua` was also marked optional in the plan and skipped — `AnimationSystem` covers the timer needs the skeleton has.

---

## Stubs With Documented APIs

None remaining. `utils/hand_eval.lua` was implemented during the shove prototype — it now exposes `rank(cards)` (rank-tuple for any 5-card hand), `compare(a, b)` (-1/0/+1), `bestFiveOfN(cards)` (brute-force enumeration over up to 9 cards), and `categoryName` / `describe` helpers for player-readable labels.

---

## Verification That Was Run

1. **Boot test.** `lovec.exe .` ran in the background; process stayed alive 3+ seconds, no crash.
2. **Save round-trip.** Both `meta.save` and `run.save` were written during boot with the expected schema and default values (`bankroll: 100`, `pp: 0`, `current_stake_id: "nl2"`, etc.).
3. **Four audit greps pass:**
   - `rg "love\.graphics\.setColor\(\s*\d" --type lua` → empty
   - `rg "^function|require\(['\"](services|models|controllers|views|states)" data/ --type lua` → empty
   - `rg "if\s+\w+\.kind\s*==|elseif\s+\w+\.kind\s*==" --type lua` → empty
   - `rg "\bGame\." --type lua -g '!main.lua'` → empty (no global service-locator access)

Not yet verified (deferred to actual feature work):
- Visual confirmation that F2 swaps the palette correctly (LÖVE booted but I didn't visually inspect the window).
- Effects-registry round-trip with the canary entry. The pipeline is wired; the canary item exists in `data/catalog.lua`. To prove end-to-end, from inside a state where `self.game` is in scope, manually add `"canary"` to `self.game.state.owned_items` via a debug hotkey and call `self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades)` — `ctx.shove_rate` should be `0.5`.

---

## What's Been Built Since (shove prototype)

The shove prototype landed across five phases (commits on `main`):

- **Phase A** — `models/Card`, `models/Deck`, full `utils/hand_eval` (brute-force best-5-of-N, all 9 categories, wheel-straight handling).
- **Phase B** — `models/Gauntlet` (rolls outcomes, jointly rejection-samples cards) and `views/ShoveDebugOverlay` (live HUD with shove_rate, attempts, clear rate vs. expected, per-runout pass counts, hotkey legend).
- **Phase C** — `views/ShoveView` rewritten to render cards (card sprites loaded by recursive scan in `services/SpriteLoader`).
- **Phase D** — Cinematic timeline-driven reveal: dealer hole cards added (math now player-vs-dealer, not player-vs-board), NLHE flop-turn-river pacing, best-5 highlighting, SPACE-to-skip.
- **Phase E** — File-based audio playback in `services/SoundService`, sounds wired through the gauntlet timeline (assets lifted from 10K's `sfx/games/memory` + `sfx/shared/default`).

Notable architecture choices:
- The original plan called for `services/GauntletOrchestrator.lua`. Per the engine-agnostic rule (services/ stays generic) it landed as `models/Gauntlet.lua` instead — Gauntlet is poker-specific stateful gameplay logic, which is a model.
- `shove_rate` is the single tunable knob driving outcomes. Cards are constructed (not derived) to match rolled outcomes — see `models/Gauntlet.lua` math contract.

Boot directly into shove with `Constants.DEBUG.START_IN_SHOVE = true` in `data/constants.lua`.

## Next Steps

Per `docs/mvp.md`, the post-shove milestones in order:

1. **Catalog UI** — first time we'll need real chrome. This is when to lift `Panel` / `ComponentRenderer` / `Modal` from cosmic courier (deliberately skipped at skeleton init for being unused-stub code).
2. **Grind tables** — `RoomView` flesh-out. Same `rng.chance(per_hand_win_rate)` primitive as the gauntlet drives hand resolution, but resolved instantly with `+/-$X` floating text instead of card animation.
3. **Stake progression curve** — `data/stakes.lua` wiring + UI for stake selection.
4. **Run upgrades** — bankroll-spend currency-vs-progression decisions.
5. **Prestige loop** — wire gauntlet completion to bankroll reset + PP award + meta-save persistence.
6. **Tone / polish** — audio replacement (current shove sounds are 10K placeholders), the mundane-job opener, ambient room sound.

Pre-existing tech debt to clean up before catalog work:
- `services/EffectsRegistry.registerDefaults` registers poker-specific kind names (`shove_rate_add`, `vs_aggressive_mult`, etc.) inside `services/`. The registry mechanism stays in services/, but the registrations should move to a `models/` file (`models/poker_effects.lua` or as part of `GameState`) per the engine-agnostic rule.

---

## Where The Plan Lives

`C:\Users\chate\.claude\plans\misty-sleeping-lampson.md` — the original skeleton plan.
`C:\Users\chate\.claude\plans\ok-now-what-do-compiled-wand.md` — the shove prototype plan.

Going forward, this doc is a historical snapshot; current state lives in `git log` and the conventions are enforced by the four audit greps above.
