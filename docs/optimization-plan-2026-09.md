# Optimization plan, 2026-09-08

The phased plan for `docs/optimization-audit-2026-09.md`. Ten phases, ordered by frame time saved per unit of
risk, with dependencies so a phase never needs a later one. Every phase ends with the same gate: the sim lints
pass, the F4 HUD numbers move in the right direction, and a side-by-side screenshot at 1 / 12 / 36 tables shows
no visible difference.

Ground rules that hold for the whole plan:

- **Nothing the player can see changes.** Same pixels, same timings, same sounds, same copy. The one place that
  cannot be pixel-identical (the chip atlas, Phase 4) has its own A/B gate and a fallback.
- **Save files stay compatible.** No serialized key changes. Derived sets (corrupted set, id indexes) live beside
  the lists, never replace them. `lua sim/verify_save_migration.lua` runs after any phase that touches the save.
- **Factor the existing thing, never write a lookalike.** When a phase needs a cache or a component, it is the
  one cache or component that every caller then uses.
- **Measure before and after every phase.** Phase 0 exists so that is possible.
- **One phase per commit series.** Each phase is independently shippable; none half-applies a change across files.

Size key: S = an hour or two, M = a day, L = several days. Gain is the audit's estimate, confirmed by Phase 0.

---

## Phase 0. Instrumentation and baselines (S, prerequisite for everything)

Nothing in this phase is visible unless F4 is on.

1. **Extend `drawPerfHud`** (`main.lua`) with: average and worst frame time over the last second, `love.update`
   ms vs `love.draw` ms, Lua heap (`collectgarbage("count")`) and heap growth per frame (a proxy for
   allocation rate), and counters for the hot calls: `evStats` calls, `buildOutcome` calls, `AnchorRegistry.set`
   calls, `IconText.parse` calls, `stackLayout` calls, chips drawn (already there). Counters are a tiny
   `services/Perf.lua` with `Perf.count(name)` and `Perf.scope(name)` that are no-ops when the HUD is off.
2. **Bench script**: move the session's headless bench into `sim/bench_perf.lua` (hand eval, gauntlet
   construction by outcome, showdown construction, evStats/buildOutcome). Print a fixed table so runs diff.
3. **Baseline capture**: a note at the bottom of this file with the HUD readings at 1, 12 and 36 tables on the
   grind, on the room, and through one full shove, plus the bench output. Every later phase appends its own row.

Exit: HUD shows the new lines; bench runs from `sim/`; baseline rows recorded.

---

## Phase 1. Foundations: indexes, revisions, in-place tables (M)

Small, mechanical changes that later phases depend on. Zero behaviour change.

1. **Id indexes on the data modules.** `data/stakes.lua` and `data/game_types.lua` export `by_id` and `index_of`
   built once at load (the pattern `Decks.specById` already uses). `utils/lookups.lua` gains `Lookups.indexList`
   so any list can get one. Replace every `Lookups.findById(Stakes, …)` / `findById(GameTypes, …)` /
   `indexById` call site (10 in `TablePanel`, 18 in `GrindController`, 19 in `Table`, plus `TablePanelStats`,
   `GrindView`, `PokerEventAnims`, `outcome_math.koFinishFill`, `payoutMult`, `buildOutcome`). Keep `findById`
   for the rare dynamic list.
2. **Revision counters.** `GrindController.ctx_rev` bumps in `invalidateEffects` and whenever the per-frame ctx
   fields it mutates in `update` actually change value (`hu_table_count`, `heater_count`, `lanes_seated`,
   `hands_per_second`, `_zoom_neighbours`). `TablePool.rev` bumps on add / remove / move / stake change.
   `GameState.owned_rev` bumps on buy / corrupt / peel / wipe. These are the cache keys for Phases 2, 3, 8.
3. **`Table.anchorKey` cache.** Each table owns `_anchor_keys = {}`; `anchorKey(t, slot)` returns
   `t._anchor_keys[slot]`, building the string once. Same call signature.
4. **`AnchorRegistry.set` in place.** Overwrite the four numbers and the frame stamp of the existing entry instead
   of allocating a new table. `get` callers that hold a reference already read it the same frame, and the two
   that stash it (`GrindView` seat KO burst, `TablePanel` stack union) copy the numbers they need.
5. **`Card.sprite_name`** precomputed in `Card:new`; `spriteName()` returns it. `Deck` and `HandClass.realize`
   go through `Card:new` already.
6. **Hoist literal tables.** The four-direction `ipairs{ {1,0},… }` in `GrindController.update` (two sites),
   `ComponentRenderer._stat`, `CatalogModal` line 1369, `GrindView._brokenGlow`, `ShoveView._drawCheatCards`
   (`{6, 7}`), `GrindView.update` (`{ left, right, rail }`), `Effects.drawHoverShadow` layers (keep the three
   layer tables, fill the numbers in place).
7. **Frame-cached mouse.** `main.lua` computes the frame-space mouse once at the top of `love.update` and once
   at the top of `love.draw`; the `love.mouse.getPosition` override returns the cached pair. Input callbacks keep
   their own conversion.
8. **`GameState.corrupted_set`** maintained beside `corrupted_items` (rebuilt in `applySaved`, `tryCorruptItem`,
   `wipeAll`, the debug unlock). `isCorrupted` reads the set. Not serialized.
9. **`ItemStream`**: catalog `by_id` map (it already caches names) and a `RoomView:layoutEntryIndex()` built once
   per layout revision instead of the per-spawn linear scan with a pattern match per entry.

Exit: bench unchanged (these are not the hot loops), HUD allocation-per-frame drops measurably at 36 tables,
`sim/test_everything.lua` and the four lints pass.

---

## Phase 2. Cache the UI model (L, the largest steady-state win)

The sidebars, rail and tooltips are rebuilt every frame. This phase makes the expensive leaves memoized and the
text pipeline cache its work, without changing the tree-per-frame architecture (that split is deferred, see
Deferred). Structure:

1. **One EV cache.** `controllers/GrindController.lua` gains `ctrl:evStats(stake, gtype)` and
   `ctrl:tableStats(tbl)`, memoized in a table keyed by `ctx_rev .. stake.id .. gtype.id` (and for tables,
   `tbl._status_rev` and `#tbl.opponents`). Every caller of `OutcomeMath.evStats` / `tbl:estimateStats` /
   `tbl:debugStats` on the draw path goes through it: `TablePanelStats.evPerHand`, `breakdownLinesFor`,
   `evMetrics`, `buildEvBreakdownLines`, `StoryDynamic.stackOdds`. The cache clears when `ctx_rev` changes.
2. **One tooltip-lines cache.** `services/TooltipCache.lua`: `get(key, builder)` with the key a string the caller
   builds from what can change the lines. Callers: `TablePanelStats.breakdownLinesFor` (key: ctx_rev, stake,
   gtype, `pool:count()`, `currentFocusMult` bucket, payout shape), `GrindView._buildRangeTooltip` (ctx_rev,
   upgrade id, level), `GrindView._deckTooltip` (deck id, level, xp), `ShoveRate.formatBreakdown` via the rail
   (ctx_rev, bankroll bucket), `CatalogReceipt.itemCard` (item id, corrupted flag, owned_rev). Lines tables are
   immutable once built; `Tooltip.set` already treats them as read-only.
3. **Range tooltip math.** `_winChanceRows` / `_stackRateRows` stop deep-copying `ctx`; they build the `nextctx`
   overlay once per cache miss. With the cache this runs once per level change instead of every frame.
4. **Per-frame pool summary.** `GrindController.update` computes once per frame a `pool_summary` keyed by
   `stake:gtype` with `open`, `deal_muted`, `rebuy_muted`, `pending_close` counts. `typeCursorState`,
   `typePendingCloses`, `tiedUp`, `_noLiveTables`, `_allGamesOpen` read it. `tiedUp` also drops its two lookups
   per table via Phase 1.
5. **`IconText` caches.** `parse(str, pills)` memoized in a weak-keyed table by string (two tables, pills on and
   off); `measure(str, font, opts)` memoized by `(font, string)` in a weak table per font; `walk` for draw reuses
   the parsed elements. `wrap` memoized by `(font, max_w, string)`. Cache entries are the element lists, which
   callers never mutate.
6. **`ComponentRenderer` measured heights.** `lineRenderedHeight` result stored on the line table as
   `line._rh` with `line._rh_w = content_w`; `buttonH` stores `comp._bh`/`comp._bh_w`. `CR.hitTest` and `_button`
   then wrap each line once per rebuild instead of three to four times per frame.
7. **`Tooltip` layout cache.** `layout(lines, fonts, default_font, max_w)` memoized on the lines table identity
   (weak) and `max_w`; `Tooltip.hover` caches the spans per row per `Tooltip.last` generation.
8. **`GrindView.update` award-glow sweep** becomes event-driven: `bountyBanked` state is compared against a
   `banked_rev` bumped by the two award sites in the controller; the sweep runs only when the rev changed.
9. **Rail closures.** The `face_fn`s for gear / book / room / deck are built once in `GrindView:new` and reused;
   the rail builder only fills in the per-frame numbers.

Exit: at 36 tables the HUD's `evStats` counter is single digits per frame at rest, `IconText.parse` calls drop
by an order of magnitude, frame time at rest drops visibly. Screenshots identical.

---

## Phase 3. Table panel per-frame cost (M)

Depends on Phases 1 and 2.

1. **`evMetrics` once per table per frame.** `measureEvReadout` and `drawEvReadout` share one call: compute in
   `TablePanel.draw`, pass the metrics table down. The `RollingValue` keys are precomputed per table (Phase 1
   style cache on `tbl._rv_keys`).
2. **Lazy hit-box tooltips.** Hit boxes carry `tooltip_fn` (a builder) or a cache key instead of prebuilt lines;
   `GrindView.update` resolves the tooltip only for the box under the mouse. `Tooltip.set` gains a one-line
   branch for a function argument. The EV readout, the tournament band, the header buttons all switch.
3. **`liveStats` cached** on the table, rebuilt in `setStake` and `new`.
4. **`tiedText` once per panel**: compute full and short strings once, pass to `FeltLayout` and `drawPlayerSeat`.
5. **`FeltLayout.compute` memo** keyed on its numeric inputs (a concatenated key of the ~12 numbers). The result
   is treated as read-only by callers (verify `TablePanel` does not mutate `L`; it does not today).
6. **Hoist the `desatOn`/`desatOff` closures** to module-level functions taking the amount; hoist the REBUY label
   table (cache per table on `cost`).
7. **`drawTournamentLadder` finishes list** memoized per payout boost; `shortPos` hoisted.
8. **`drawOpponentSeat`**: the per-seat `Lookups.findById` calls go away with Phase 1; the `script_seat` and
   busted-finish scan stay (cheap).
9. **Hit-box pooling** is deferred (small).

Exit: HUD heap growth per frame at 36 tables at rest is close to the 1-table figure; screenshots identical.

---

## Phase 4. Chips: cached layout, then the face atlas (M + L, A/B gated)

Two halves. The first is invisible and lands on its own. The second is the largest draw-call win in the game but
is not pixel-identical, so it gets its own gate.

**4a. Cached pile layout (M, invisible).**
1. `ChipPile`: each pile keeps `e.layout` and `e.layout_key` (the settled denomination list joined with the place
   fields). `draw`, `slotsByPos`, `tidy` reuse it until the key changes. `denomList` writes into a reused scratch
   when only the count is needed.
2. `Chips.stackLayout` reuses its `groups`/`columns`/`row_of` scratch tables between calls; `slotRotation` and
   `shadeFor` are cheap and stay.
3. `Denoms.breakdown`: the sorted palette is cached per palette table (weak key).
4. `ShoveView._drawShoveStatus` / `_drawPot`: the buildup `chip_indices` list is built once when the chips are
   set and reused.

**4b. Chip face atlas (L, gated).**
1. Bake each `(denomination, tint, label on/off, detail, escale bucket)` face on first use into a small canvas
   held by `Chips`, drawn with nearest filter at 1:1. Two layers per chip: the rim+spots layer (drawn with the
   slot rotation) and the face+inlay+label layer (unrotated). Each chip becomes two `love.graphics.draw` calls of
   the same texture, which LÖVE batches.
2. `escale` is bucketed to 1/8 steps; the bucket is what the vector path already effectively produces after
   `math.floor` on the plate metrics. Buried and edge detail levels stay vector (they are cheap and few).
3. **Gate:** capture the bankroll pile, a pot pile at three panel sizes, and a flight mid-tumble with the vector
   path and with the atlas; overlay diff. Accept only if the difference is sub-pixel (rotated spot edges). If
   not acceptable, keep 4a and drop 4b; the layout cache alone still removes the per-frame sort and allocations.

Exit (4a): `stackLayout` HUD counter is zero at rest. Exit (4b): draw calls at 36 tables fall by an order of
magnitude; A/B accepted.

---

## Phase 5. The gauntlet stall (L)

Two independent halves; either alone removes the hitch, both together make the sim faster too.

**5a. Construction off the frame.**
1. `Gauntlet:beginAsync(forced_outcomes)` runs `_constructJointly` inside a coroutine; `Gauntlet:step(budget_ms)`
   resumes it for at most `budget_ms` per call and returns whether it finished. The attempt loop yields between
   attempts (and inside `_planCheatCards` between c6 tries).
2. `ShoveState`: start the construction the moment the buildup phase begins (`view:beginBuildup`), step it every
   `update` with a 4 ms budget, and treat `isReadyToDeal` as "the view is ready **and** the gauntlet finished".
   The buildup is seconds long; the construction hides behind it. If the player skips the buildup before it
   finishes, `step(math.huge)` finishes synchronously (rare, and fast after 5b).
3. Resumed shoves (`state.shove_pending.outcomes`) go through the same path; the outcomes are still rolled and
   persisted before the theater starts, so quit-and-reload behaviour is unchanged.

**5b. Allocation-free evaluation.**
1. `HandEval.score(cards, n)`: a 5-to-9 card evaluator using rank-count and suit-count scratch arrays that
   returns a single comparable integer (category in the high digits, kickers below), with no combination
   enumeration and no allocation. `HandEval.rank` (the tuple) stays for `describe` and for the final evals the
   view reads; `bestFiveOfN` stays for the combo the view highlights, called once per runout, not in the search.
2. `Gauntlet._compare` / `_classifyRunnerCards` / `_shows` use `score` with two reused scratch arrays;
   `Deck:remaining()` gains an in-place variant that fills a caller-owned array; `c7_cands` is built by swapping
   `c6` out of the reused list.
3. `HandRealism.rank7` and `redealOpponent.oppRank` use `score`; the legacy fallback reuses one shuffled index
   array instead of `Deck:new()` per attempt. `Table:deal` gets the ranks back from `constructShowdownHand`
   instead of re-evaluating both hands in `handLabel` (`handLabel` gains an optional precomputed-rank argument).
4. **Equivalence test** in `sim/`: 200k random 5-to-9 card sets, assert `score` ordering equals
   `HandEval.compare(bestFiveOfN(a), bestFiveOfN(b))` ordering. `sim/verify_showdown_realism.lua` and
   `sim/test_everything.lua` pass. The RNG consumption order changes, so any sim that pins a specific dealt hand
   by seed is updated (none is known to; check `sim/cases`).

Exit: bench worst case for `Gauntlet:begin` under 20 ms in PUC Lua; no visible hitch at the deal; showdown
construction under 0.3 ms.

---

## Phase 6. Controller and model churn (M)

1. **`invalidateEffects` as a dirty flag.** Callers set `self._effects_dirty = true`; `update` recomputes once
   at the top of the frame if dirty (and the two callers that need the fresh ctx immediately, `GrindState:enter`
   and `RoomState`'s debug unlock, call `flushEffects()` explicitly). `_rebuildProcIndex` diffs the proc id list
   and router list against the previous and only unsubscribes/resubscribes when they changed.
2. **`_syncStateList` in place.** Write into the existing sixteen `state.active_table_*` arrays (trim the tail
   when the count shrinks). Same serialized content.
3. **`GrindController.update` scratch.** Reuse the `stakes` / `occupied` / `slots` / `cells` tables across
   frames; hands-per-second window as a ring buffer with a head index; `_hand_times` pruned by index.
4. **Resolution loop**: the `floater_opts` merge builds one table, not two; the stake index lookups go through
   Phase 1; `Decks.checkPendingUnlocks` runs once per frame after the loop when any resolution happened, not per
   resolution (it is idempotent).
5. **`RoomState._drawCount`**: `countedItems` cached on `owned_rev`.
6. **`GameState:computeEffects`**: the `unbanked` key strings come from a static `stake:gtype` key table built once.

Exit: HUD heap growth per frame during a cursor-swarm burst is flat; bank-heavy sessions show no rebuild spikes.

---

## Phase 7. Save, music, device (M)

1. **Save path.** `SaveService:_stage` encodes compact (drop the `pretty` flag; whitespace only, decoders
   unaffected, `sim/verify_save_migration.lua` confirms). The verify step compares the written byte length to the
   encoded length and decodes only the first 64 bytes for the version header instead of the whole file. On
   desktop (`love.thread` available, not web) the encode + write + verify + rename of both files runs on one
   worker thread fed by a channel with the two payload tables; the main thread never blocks. Web keeps the
   synchronous path with the cheaper verify. `load_failed` semantics unchanged.
2. **Music DSP.** Desktop: the decoder and `processChunk` move to a `love.thread`; the thread owns the `Decoder`,
   produces processed `SoundData` chunks, and pushes them on a channel; `MusicDirector.update` only queues what
   arrived and sends grime / echo targets and seek requests down a second channel. If the thread is unavailable
   (web) the current in-line loop stays. A cheaper second option if threading proves awkward: keep it inline but
   run the per-sample loop over `SoundData:getFFIPointer()` with FFI (LuaJIT only, ~10× faster), current loop as
   the fallback.
3. **`AudioDevice.tick`**: measure `getPlaybackDevices` cost first (Phase 0 scope). If it is under 0.2 ms, leave
   it. If not, run the poll on the music thread and only reopen from the main thread.

Exit: no periodic spike on the HUD's worst-frame line at 10 s intervals; music refills never exceed 1 ms on the
main thread.

---

## Phase 8. Room, sprites, canvases (L)

1. **Room resolve on a revision.** `RoomView` keeps `_layout_rev` (bumped by editor edits, draft load, layout
   migration) and reads `GameState.owned_rev`; `resolveAll`, `_resolveSet`, the render list sort and
   `_hit_rects` are rebuilt only when either changes. The per-frame path becomes: walk the cached render list,
   `itemArt` per animated item only (still items cache their sprite on the rect), draw.
2. **Floor and walls in a `SpriteBatch`** rebuilt on tile set / room size / flip / courses change. Editor grid
   lines stay immediate (editor only).
3. **Room thumbnail**: one persistent canvas; rerender on `owned_rev`, `corrupted` count, lights flag,
   `room_unseen` count, size. No string key.
4. **Scratch canvas service.** `services/ScratchCanvas.lua` holds one base-frame-sized canvas (reallocated on
   resize only); `HintView._drawDim`, `RoomLighting.draw`, `TitleView` menu fade, `ShoveView:snapshot` check it
   out and back in. The credits backdrop copies to its own canvas once.
5. **Sprites.** (a) Confirm via `aliases.json`, `data/catalog.lua`, `data/room_layout.lua`, `data/icons.lua`,
   `data/room_tiles.lua` which of the two isometric trees is referenced; migrate any stragglers, delete the other.
   (b) `SpriteLoader:loadAll` scans filenames only; `getSprite`/`hasSprite` load on first miss from the name
   index; card backs (LOD chain) and the referenced set (catalog + layout + icons + tiles) load eagerly at boot so
   nothing hitches on first draw. (c) Decode once: `newImageData` then `newImage(data)`, strip detection on the
   already-decoded data. (d) Skip `.gif` by extension.

Exit: room screen frame time flat with item count; boot time and texture memory on the HUD down; no first-draw
hitch on the grind, room, shove or catalog.

---

## Phase 9. The reuse pass (L, structural)

Last, because it is the biggest refactor and every phase above is independent of it. It is what keeps the list
from growing back.

1. **`views/widgets/Paper.lua`.** Throw-to-felt tween, land, open/close tween, hinge flip (the one
   `drawFlipped`/`hinged`), felt spot, scrim, alpha, hit list, `isOpen`/`isLanded`/`resolved`. `CatalogModal` and
   `DeckFlyer` become content callbacks on a `Paper`; `CatalogReceipt` uses its slide and hit list. Their public
   methods (`consumeMouse`, `consumeKey`, `openFromFelt`, `closeToFelt`, `feltRect`, `isOpen`, `isLanded`) stay so
   `ShoveState` / `GrindState` are untouched.
2. **One modal frame.** `widgets/Modal.lua` grows the scrim and the story-band avoid rule; `HintView`,
   `DemoEndModal`, `AnalyticsConsentModal`, `ConfirmDialog`, `GlossaryPanel`, `ShoveDebugOverlay` draw through
   it.
3. **One hit registry.** `services/HitRegistry.lua`: `add(rect, payload)` per frame, `at(x, y)` returns the
   topmost. `GrindView.hit_boxes`, `CR.hitTest` results, `CatalogModal._cells`, `DeckFlyer._tiles`,
   `SettingsModal._row_rects`, `CatalogReceipt._row_rects`, `RoomView._hit_rects` register into it; the hover pass
   in `GrindView.update` becomes one lookup. Entries are pooled.
4. **One token resolver.** `Theme.color(token)` covers sem / status / fg / paper / `group.key`; `ComponentRenderer`,
   `Tooltip`, `TablePanelEffects`, `GrindView`, `TablePanelStats` call it.
5. **One wrapper, one icon row, one `now`, one `darken`.** `IconText.wrap` absorbs `HintView.wrapLines`;
   `TablePanelStats.iconRow` becomes `Tooltip.iconRow` (it already exists there) and `GrindView.iconRows` calls
   it; `now()` copies use `love.timer.getTime` directly; `darken` moves to `Theme.darken` with an optional
   destination table so hot callers (`Button.draw`) do not allocate.
6. **One radial texture baker** in `FeltDecor` used by `HouseArt.glowTex` and `ShoveDecor.configure`.

Exit: line counts drop, the three paper surfaces share one file for their motion, and the HUD numbers from
Phases 2 to 4 hold.

---

## Deferred or dropped, and why

Listed so nobody re-audits them.

- **Splitting the sidebar/rail into a retained structure plus a per-frame value refresh.** Only if Phase 2's
  memoization leaves the tree rebuild itself visible on the HUD. The rebuild is ~50 small tables; the math it
  used to do per frame was the cost.
- **`AudioDevice` poll interval.** A longer poll delays the headphone switch, which is player-visible. Measure
  first (Phase 7.3); leave it if cheap.
- **`CursorPool` O(n²) clash test and `panelAt` per cursor.** Cursor counts stay small.
- **`HintCtx.build` per frame, `FloatingTextSystem` front-shift, `Confetti` closures, `Tumble`/`makeRenderFns`
  closures per flight, `HandScript.write` allocations, `_fireProcs` event tables, `KoSession.planRun`.** Per event
  or tiny; not worth the churn.
- **`GlyphMorph` and `StoryView` re-wrapping while typing.** Only during a story line, a few seconds.
- **`Effects` shader batching across tables.** Only matters with many simultaneous heaters; revisit if the HUD
  shows shader switches after Phase 4.
- **Hit-box pooling in `TablePanel`.** Small; folds into Phase 9.3 anyway.
- **`Decks.checkPendingUnlocks` throttling beyond once per frame.** Cheap.
- **Rewriting `HandScript` / `KoSession`.** Per deal, fine.
- **A LuaJIT-specific FFI path for chips or anchors.** Web build has no FFI; not worth two code paths.
- **Pretty-printed save files.** Dropped in Phase 7; the only cost is human readability of the raw file, and the
  tools decode it anyway.

---

## Verification, every phase

1. `lua sim/lint_copy.lua`, `lua sim/lint_terms.lua`, `lua sim/lint_catalog_economy.lua`, `lua sim/test_everything.lua`,
   plus `lua sim/verify_save_migration.lua` for Phases 6 and 7 and `lua sim/verify_showdown_realism.lua` for Phase 5.
1b. `lua sim/smoke_boot.lua`, added after this pass shipped a boot crash past every check above. The engine suite
   never loads a view or a service, so a file that compiles and dies the moment `love.load` calls it had no
   coverage at all. It scans every file for a local read before its declaration (the exact shape that crashed:
   legal Lua, silent under `luac -p`, nil at run time), requires every module under `core/ controllers/ data/
   models/ services/ states/ utils/ views/`, then scans the real sprite tree and runs the boot preload against
   it. Run it before claiming a change is safe.
2. `lua sim/bench_perf.lua` diffed against the previous phase's row.
3. In game with F4: the HUD rows at 1 / 12 / 36 tables at rest and during a swarm burst; one full shove; the room;
   the catalog open over the grind.
4. Screenshots at the same three table counts, same seed, same save, before and after; overlay diff must be
   empty (Phase 4b excepted, with its own gate).
5. The player-facing checklist: same copy, same sounds, same timings, same order of events. If any phase needs a
   visible change to land, it stops and asks.

---

## Baseline rows

In game: press F4 and read the HUD. The meters to watch are `heap/frame`, `draw calls`, and the six counters at
the bottom (`evStats`, `buildOutcome`, `anchors`, `text parse`, `text wrap`, `pile layout`) — each should fall
toward zero at rest as the phases land. Fill a row per phase.

| Phase | Where | fps | frame avg / worst ms | update / draw ms | draw calls | heap/frame KB | evStats | anchors | parse |
|---|---|---|---|---|---|---|---|---|---|
| 0 | grind, 1 table | | | | | | | | |
| 0 | grind, 12 tables | | | | | | | | |
| 0 | grind, 36 tables | | | | | | | | |
| 0 | room | | | | | | | | |
| 0 | shove | | | | | | | | |

Headless bench, `lua sim/bench_perf.lua`, PUC Lua 5.4, seed 20260908.

| case | Phase 0 avg / worst ms | after Phase 6 avg / worst ms | change |
|---|---|---|---|
| bestFiveOfN(7) | 0.107 | 0.125 | reference path, unchanged |
| score(7) | n/a | 0.001 | the new fast path |
| gauntlet R1 loss | 0.73 / 2 | 0.35 / 1 | 2× |
| gauntlet R1w R2 loss | 67.8 / 198 | 1.20 / 2 | **56×** |
| gauntlet R1w R2w R3 loss | 384.9 / 1068 | 3.23 / 7 | **119×** |
| gauntlet full clear | 173.9 / 278 | 2.53 / 4 | **69×** |
| constructShowdownHand small | 1.10 / 4 | 0.045 / 1 | **24×** |
| constructShowdownHand stack | 2.51 / 13 | 0.54 / 4 | **5×** |
| evStats cash | 0.013 | 0.007 | 2× (and now cached per frame) |
| buildOutcome | 0.006 | 0.006 | unchanged (call count fell instead) |

The gauntlet's worst case went from **1068 ms to 7 ms**. That is the stall behind "slowdown in gauntlet", and it is gone without the coroutine Phase 5a proposed — see "Deferred" below.

## Landed

Phases 0, 1, 2, 3, 4a, 5, 6, plus the low-risk halves of 7 and 8. Verified after every phase with the four
lints, `sim/test_everything.lua` (675 checks), `sim/verify_save_migration.lua` (41 checks),
`sim/verify_showdown_realism.lua`, the new `sim/verify_hand_score.lua` (60,156 comparisons) and two scratch
harnesses that check the caches against their uncached results.

The strongest signal: `docs/sim-audit.md`, regenerated against a clean `git worktree` at HEAD, is
**byte-identical** before and after. The sim drives thousands of Monte Carlo hands through the evaluator, the
showdown construction and the redeal path, so identical output means identical decisions, identical RNG
consumption, identical balance.

## Deferred, with reasons

- **Phase 5a, the gauntlet coroutine.** Unnecessary: 5b's evaluator took the worst case to 7 ms in PUC Lua,
  which is 1–2 ms under LuaJIT. Adding coroutine machinery to hide that would be complexity for nothing.
- **Phase 4b, the chip atlas.** Not attempted. It is the largest remaining draw-call win, but it cannot be
  pixel-identical and it touches the most carefully tuned art in the game. 4a (the pile layout cache) landed
  and removed the per-frame re-solve, which was the allocation half of the problem.
- **Phase 7 threads.** The save now encodes compact and verifies by length rather than a second full parse.
  Moving the write and the music DSP onto `love.thread` is still open; it is the larger risk and the split
  desktop/web path.
- **Phase 8, the duplicate sprite pack.** Investigated, not deleted — deletion is destructive and is the
  user's call. Findings: `assets/sprites/isometric/` and `assets/sprites/TinyHouse_0.17(@Pixel_Salvaje)/` are
  **content-identical** in their overlap (0 differing files, 0 files unique to `isometric/`); TinyHouse merely
  carries extra `.DS_Store`, `.gif` and credit files. Both are loaded. `isometric/` is referenced from exactly
  one place — `data/room_tiles.lua` line 27, `folder = "isometric/Floor_Wall_Tiles_%d/"` — while TinyHouse is
  referenced by `data/room_layout.lua` (7) and `assets/sprites/aliases.json` (76). TinyHouse also has the
  `Floor_Wall_Tiles_32/64/128` folders. **So: point that one line at
  `TinyHouse_0.17(@Pixel_Salvaje)/Floor_Wall_Tiles_%d/` and delete `assets/sprites/isometric/`** — 1,114 files
  and ~13 MB, halving the boot decode. One line changed, one directory removed.
- **Phase 8, lazy sprite loading and the room revision.** Open. The double decode is fixed (each file is now
  decoded once instead of twice), which was the pure-win half.
- **Phase 9, the reuse pass.** Open, except the pieces that fell out of the work above: one halo-offset
  constant (`Theme.HALO_OFFSETS`) replacing four copies, one `Table.rollingKey` replacing four key-building
  sites, one `Lookups` index serving every id lookup, `services/Memo.lua` as the one result cache.
- Small items skipped on purpose: the rail's four `face_fn` closures, `itemCard` memoization (its fire counter
  is live, and caching it would freeze a number the player watches), `Decks.checkPendingUnlocks` batching (it
  would reorder unlock announcements), the update loop's four scratch tables, the hands-per-second front-shift.

---

## Size-driven detail on the felt (2026-09-08)

At 36 tables with everything unlocked the board ran at ~29 fps with the whole cost in draw: a panel cost
the same at 165x125 as at 1040x780, because the panel scale only multiplied sizes and skipped nothing.
Four changes, all gated by the per-element flags `views/FeltLayout` already publishes:

1. **Chip piles take a detail level.** `pile.micro_below_d` (data/felt_layout.lua) → `L.pot.detail` /
   `L.bottom.detail` → `ChipPile.place{detail}` → `Chips.drawColumn`: one pill, one disc, one outline per
   column and no shadow, in place of ~7 arcs per buried chip. Draw-only; it never re-solves the layout.
2. **Card backs plate in the deck's primary colour.** `card.back_plate_below_w` → `back_plate` on every
   card band → `CardSprites.back(..., plate)`; the colour is `SpriteLoader:dominantColor(name)`, read off
   the art once at load (fullest histogram bucket of the inner 80%, so a checker is red or blue, not
   purple). A back called with no decision never plates, so flights and the deck flyer are unchanged.
3. **Shadows before cards.** `CardSprites.batchBegin/batchEnd` hold `back`/`front` calls and replay them
   after the band, so every shadow rect lands first and the backs batch. The dealer button is parked by
   its seat and drawn after the replay so it stays above its card.
4. **No strings on the per-table draw path.** The bake cache is nested tables (shade bucketed to a
   thousandth, as `%.3f` did); slot and index names are built once (`named` in TablePanel); money, EV,
   pct, pot, tied-up and header strings memoize on the table by their displayed digits; floater text is
   split once per floater. Nothing visible changes.

Thresholds were set from the solved layout at 1600x900: the player's pile is 34px at 12 tables, 26 at 16,
20 at 24 and 12 at 36, and the pot pile is 22 at 12 and 17 at 16 (dropped from 24 up); an opponent card
is 22, 16, 12 and 6 px. So 12 tables and fewer draw exactly as before; 16 draws its pot as columns; 24
plates its opponent backs and draws both piles as columns; 36 plates every back.

Two corrections from the first run in game, and a fifth change:

- **The plate colour is the mean, not the dominant colour.** The backs are pixel art in pure CGA
  primaries with black outlines; the biggest single colour of a blue-and-red checker is a pure red that
  looks nothing like the card, and by raw count the outline won on half the decks. The mean of the inner
  80% is what the mip chain was already showing at six pixels. `SpriteLoader:backColor(name)`.
- **Backs keep their art until they are specks.** `card.back_plate_below_w` is 10, not 16: at 13 tables
  the art still reads, so only 36 tables plates. Plates and columns also lost every line-mode primitive
  (fill + inset fill instead), since line mode tessellates joins and never batches.
- **5. No theater below a panel width.** `anims.min_panel_w` (350) and `anims.floaters_min_panel_w`
  (200) in `data/felt_layout.lua`. Below the first, `TablePanel.draw` consumes the hand's script events
  without dispatching them to `PokerEventAnims` (no chip flights, mucks, thrown cards) and the pot
  detonation becomes a clear. Below the second, `FloatingTextSystem.emit` drops floaters whose table
  is that small (`tbl.panel_w`, stamped per draw). Low motion was already reaching the 50s at 36 tables
  where Full sat in the 30s, which is what said the theater was the remaining cost.
  **Then re-keyed on table count** (`anims.min_tables = 20`; the floaters stay at every count, the
  designer wants to see them always, `anims.floaters_min_tables` is the unset knob): the board
  packs six wide in reading order, so 13 and 36 tables share a panel width, and the designer's "nothing
  until 20+" is a count. `TablePanel` stamps `tbl.board_n` each draw for `FloatingTextSystem`.
- **6. The periodic stall was the analytics log.** `Constants.DEBUG.HAND_ANALYTICS` is on by default;
  every hand on every table appended a record to an uncapped list, and each 10 s autosave `json.encode`d
  the whole file (every hand of up to 50 kept shoves) and wrote it synchronously on the main thread. At
  36 tables that is ~1,000 hands a minute, 20,000 hands encode in ~250 ms of plain Lua and make a 4 MB
  file, and it grew for the whole session. `services/HandAnalytics` now encodes each hand once when it is
  recorded, holds every earlier shove as one string, caps a run at 20,000 newest hands (`hands_dropped`
  in the file), assembles the file by `table.concat`, and hands the write to the save worker through
  `SaveService:writeAsync`. Same file shape. The quit path still writes inline.
 Knobs: `card.plate_below_w`, `card.back_plate_below_w`,
`pile.micro_below_d`. Checks: `sim/smoke_views.lua` (column, detail-no-resolve, held queue, bake bucket)
and `sim/smoke_boot.lua` (dominant colour).

## The second pass (2026-09-29): the big board at 60 fps

The F4 HUD at 22 tables read 18 fps (53 ms, draw 33 ms, 1,259 draw calls, 110 MB of textures); at 34 tables,
40 fps just after opening and 7 fps a few minutes later with draw at 150 ms and textures at 212 MB, the same
board recovering when closed and reopened. Update was 2-4 ms throughout. Three read-only audits (the draw path,
the theater layer, the update path) found the cost entirely in draw and mostly in things that grew with time in
play, and a plan of eight phases landed as eight commits, each with its own headless checks:

0. **Meters.** Perf allocates nothing per frame, gains gauges, an allocation EMA, freed/s and cycles/s, and an
   exact mode (Shift+F4); the draw is scoped (rail, grid with static and live, sidebars, floaters, piles, flights,
   post passes, the blit); every shader bind counts; the HUD's rows are persistent. The palette sets love's
   background colour, and GrindView's full-window fill is gone.
1. **Analytics.** `DEBUG.HAND_ANALYTICS` is false; when on, an append-only JSON Lines log (a flush concatenates
   at most 256 pending lines and the worker appends; nothing is ever rebuilt or read back). The 12 MB document
   rebuilt as 25 MB of strings every ten seconds, the 368 ms worst frame, is gone.
2. **Leaks and the update side.** The event bus's recycle pool is bounded (every publish handed it a table it
   never asked for back); closing a table drops its rolled values, pops, anchors, stats slots and piles; the
   per-frame scratch on the update side is reused (the pool's resolutions, the stats shelf, the hover maps, the
   cursor closures, the hint context).
3. **The display revision.** The live counters (hands per second, heaters, Heads-Up tables, lanes) no longer
   empty every EV cache and memo twenty times a second: they bump only when an owned item reads them, at most
   twice a second; an EV cache hit allocates nothing.
4. **Retained sidebars and rail.** A tab declares `inputs` and `refresh`; `build` runs only when its inputs
   move; the rail's numbers refresh in place; tooltips build on hover and memoize; the builders' side effects
   and clocks live in `GrindView:_tickRail`. `sim/smoke_ui.lua`.
5. **One chip atlas, a batch per pile, incremental layout, pooled flights.** The bake cache (canvases created
   inside the draw, keyed on shade to a thousandth, never evicted: the 110 → 212 MB) is replaced by one atlas
   built once (3.75 MB at 1x); each pile is a SpriteBatch rebuilt only on its revision; a landing chip inserts
   into its column without a full solve; a chip projectile is a pooled record drawn through one batch, not
   three closures and seven tables. `sim/smoke_chips.lua`.
6. **The panel cache.** A resting panel is a slot in one shared canvas, re-rendered on a 46-field dirty key
   and blitted with the live layers on top; a continuous animation bypasses to the immediate path; transforms
   apply to the blit; the residue's desaturation is baked (it was eight shader binds a panel). The immediate
   path's per-panel garbage is gone with it. `FEATURES.PANEL_CACHE` is the kill switch. `sim/smoke_panels.lua`.
7. **The passes.** The focus strain draws once into a second frame canvas and the layers above keep drawing
   there; its uniforms and the blit's are sent on change. GC tuning is left for after an in-game read.

`sim/perf_budget.lua` prints KB per frame for the controller tick and for a whole frame at 22 tables and checks
them against budgets meant only to tighten (17 and 107 KB at the end of the pass, headless). The numbers to read
in game, F4 at 12 / 24 / 34 tables at rest and dealing, before and after: `draw` flat over ten minutes at 34
tables, `texture mem` flat, `draw calls` from four figures to two at rest, `shader sw` 0 on a residue board,
`evStats` and `text wrap` 0 at rest, `panels` 0 at rest with `cached/bypass` mostly cached, `pile batch` 0 at
rest, `heap` flat across a session. What is not pixel-identical: chips are sharper (fixed radius tiers) and
their highlight arcs dim with shade; the strip's hover is the button's own tint. Phase 4b of the first pass,
the chip atlas, is the one deferred item that landed.
