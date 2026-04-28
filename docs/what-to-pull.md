# What to Pull from Cosmic Courier and 10000-games

*Captured 2026-04-27 after surveying both sibling LÖVE2D projects.*

Both existing projects are technically idle games but vastly different in scope from Poker Idle. Most of their domain code is dead weight, but several pieces of generic infrastructure took real effort and would be wasted to re-derive. This doc is the opinionated pick — when both projects offer the same thing, the better one is named explicitly rather than listing both.

## Pull from Cosmic Courier (the foundation layer)

These cover most of the engine needs:

- `core/event_bus.lua` — pub/sub with taps. Wire prestige, currency changes, hand resolutions through it.
- `core/time.lua` + `core/camera.lua` — delta tracker and camera (yes, even single-room benefits from camera for the shove zoom).
- `services/SaveService.lua` + `services/AutoSerializer.lua` — declarative TRANSIENTS/REFS serializer with versioning. The dual-slot pattern (run save vs. meta save) maps directly onto bankroll-resets-but-PP-persists.
- `services/FloatingTextSystem.lua` — "+$500" / "+12 PP" popups during grind and shove. Critical idle-game feel; don't rebuild.
- `services/SoundService.lua` — procedural sine/sweep tones. Lets you prototype shove sfx and prestige dings without sourcing audio. Big win given the design doc names audio as critical-but-late.
- `views/Panel.lua`, `views/ComponentRenderer.lua`, `views/components/Modal.lua`, `views/Scrollbar.lua` — UI primitives. The catalog grid is essentially a Panel + ComponentRenderer instantiation.
- `data/theme.lua` — centralized tokens with multi-palette support. Two palettes: "room" and "shove." That's the mode-shift for free.
- `lib/input_dispatcher.lua` — predicate-routed input. Useful when shove mode needs to suppress grind clicks.
- `shaders/fog_of_war.glsl` — domain-warped FBM. Reparameterize for vignette/darkening when shove begins.

## Pull from 10000-games (the runtime/scene layer)

- `src/controllers/state_machine.lua` — clean enter/exit/update/draw/input. **This is the grind ↔ shove transition.** Don't roll your own.
- `src/utils/game_components/animation_system.lua` — timer-based flip and bounce with callbacks. **This is the card reveal sequence.** The bounce curve is exactly what cinematic card flips want.
- `main.lua` (as a template) — mature LÖVE callbacks, DI container, 30s auto-save loop, debug hotkeys. Steal the skeleton.
- `src/utils/sprite_loader.lua` — directory scan with caching and JSON aliases. Useful for catalog item sprites and the card deck.

## Pick one, drop the other

Both projects offer overlapping primitives. When that happens:

- **Event bus**: take Cosmic Courier's. Both work; CC's is the one already wired into a save/event system also being taken.
- **UI components**: take Cosmic Courier's. More composable; 10000-games' is more game-screen-shaped.
- **Theme**: take Cosmic Courier's. Multi-palette is exactly what the two-mode design needs.

## Build from scratch

Neither project has these — don't waste time looking:

- **Card / deck / hand evaluator** — neither has a single line of poker logic. Pull a small Lua hold'em evaluator (or write one; 5-card eval is ~150 lines).
- **Abbreviated number formatting** ("1.2M", "42K") — both projects use plain `string.format`. Write a 20-line `formatBig(n)` helper.
- **Weighted RNG pick** — extract the pattern from CC's `services/TripGenerator.lua` lines 26–38 into a standalone helper.
- **The room itself** — visual-accumulation-of-objects is the game's signature; don't try to retrofit either project's view layer for it.

## Don't pull (would just be noise)

**From Cosmic Courier:** anything in `services/` named Map/City/World/Pathfinding/Dispatch, all of `models/vehicles/`, `views/DataGrid*`, `models/EntityManager.lua`. The whole entity-grid/dispatch-rules world is the wrong shape for a single-room game.

**From 10000-games:** window/desktop chrome, VM/demo recorder, cheat engine, all minigame base classes and their components. The Win98-sim layer is dead weight.

## Bottom line

Skeleton can be standing in ~2 days by lifting CC's foundation + 10000-games' state machine and animation system, vs. ~5+ days from blank.

The single highest-leverage pull is **10000-games' animation_system.lua + CC's FloatingTextSystem + CC's SoundService** — together they're 80% of what makes the shove sequence land, which the design doc correctly identifies as the riskiest beat.
