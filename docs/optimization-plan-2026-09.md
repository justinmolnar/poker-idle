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
   fields it mutates in `update` actually change value (`hu_table_count`, `heater_count`, `stakes_seated`,
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
