# Optimization audit, 2026-09-08

A full sweep of the runtime tree (`main.lua`, `states/`, `controllers/`, `views/`, `models/`, `services/`) for
performance holes. Nothing here changes what the player sees. Every item is a "same pixels, fewer cycles"
change. Nothing has been fixed; this is the list.

The one-line verdict: **the game recomputes and reallocates almost its entire UI model every frame, and the
per-table cost is high enough that the grind screen's frame time is roughly linear in table count.** The gauntlet
has one specific stall (the joint card construction) that runs synchronously on the frame the shove commits.

Read it top down. Tier 1 is stalls the player can feel as a hitch. Tier 2 is steady-state waste that lowers the
frame rate as tables and chips pile up. Tier 3 is per-event churn. Tier 4 is the reuse question (one renderer,
not three), which is also where a lot of the Tier 2 waste comes from.

---

## 0. Measured

Headless, PUC Lua 5.4 (the game runs LuaJIT, so absolute numbers are roughly 3 to 8× lower in-game for arithmetic,
but allocation-heavy code sees much less of that gain). The script is in the session scratchpad; it can be dropped
into `sim/` as a repeatable bench if wanted.

| What | Cost |
|---|---|
| `HandEval.bestFiveOfN` on 7 cards | 134 µs per call (21 combos, ~8 table allocs per combo) |
| `Gauntlet:begin`, R1 loss | 0.9 ms avg, 3 ms worst |
| `Gauntlet:begin`, R1 win / R2 loss | 73 ms avg, **479 ms worst** |
| `Gauntlet:begin`, R1 win / R2 win / R3 loss | 235 ms avg, **1250 ms worst** |
| `Gauntlet:begin`, full clear | 136 ms avg, 323 ms worst |
| `HandRealism.constructShowdownHand` (stack tier) | 2.0 ms per deal |
| `HandRealism.constructShowdownHand` (small tier) | 0.9 ms per deal |
| `OutcomeMath.evStats` cash / KO | 18 µs / 23 µs per call |
| `OutcomeMath.buildOutcome` | 6 µs per call |

Divide by ~5 for LuaJIT and the gauntlet worst case is still a 100 to 250 ms freeze on one frame, at exactly the
moment the buildup ends and the cards should deal. That matches "slowdown in gauntlet".

The in-game perf HUD already exists (F4 toggles `drawPerfHud` in `main.lua`; it prints fps, draw calls, batched
calls, chip count, texture memory). Read the draw-call line with 20+ tables open before and after any fix.

---

## Tier 1: single-frame stalls

### 1.1 Gauntlet joint construction runs synchronously and allocates like a sieve
`models/Gauntlet.lua:_constructJointly` (line ~258), `_planCheatCards`, `_classifyRunnerCards`, `_compare`.

- Up to 500 attempts (`Constants.GAUNTLET.REJECTION_RETRY_CAP`). Each attempt deals a fresh `Deck:new()` (52 `Card`
  allocations + shuffle), then `_shows` (2× bestFiveOfN), then for a survived R1: `_classifyRunnerCards` over all 43
  remaining cards (each: two 7-card arrays built with `table.insert`, 2× bestFiveOfN), then up to 5 c6 tries × 42 c7
  candidates × 2× bestFiveOfN on 8 cards (56 combos). Worst case per attempt is ~25,000 `HandEval.rank` calls.
- `Deck:remaining()` copies the 43-card list on every call; inside the c6 loop it is called again per try and then
  filtered into `c7_cands` (another copy).
- `HandEval.rank` allocates `values`, `suits`, `counts`, `groups` (with a table per group), `unique_desc`, and the
  result tuple; runs three `table.sort` calls with closure comparators. `bestFiveOfN` recurses with a closure and
  `table.insert`/`table.remove` on `picked`, and copies `best_combo` on every improvement.
- All of this happens inside `ShoveState:_beginGauntlet` on the frame `isReadyToDeal` flips.

Fix directions (any is invisible): (a) evaluate with scratch buffers and no allocation, a 7/8-card evaluator that
does not enumerate combos (rank-count + suit-count arrays are enough to classify), (b) classify runners once per
attempt for both sides against a precomputed 5-board eval instead of re-ranking 7 cards per candidate, (c) run the
construction as a coroutine with a per-frame time budget during the buildup phase, which is already several seconds
of animation the construction can hide behind. (c) alone removes the hitch; (a) makes the sim faster too.

### 1.2 Autosave is a synchronous double write with read-back verify, every 10 s
`main.lua:love.update` (autosave block), `services/SaveService.lua:_stage/_commit`, `models/GameState.lua:serializeRun`.

- Every 10 s: `serializeMeta` + `serializeRun`, then for each of the two files: `json.encode(wrapper, true)`
  (pretty-printed, string concatenation per key via `table.insert` of padded strings), `love.filesystem.write` of
  the `.tmp`, **read the `.tmp` back and `json.decode` it** (`tryRead`) to verify, then `os.remove` + `os.rename`.
  That is two encodes, two writes, two reads, two decodes, four filesystem metadata calls, on the main thread.
- The run payload carries per-table `active_table_ko_plans`, `seat_stacks`, `seat_busted`, `bust_order`,
  `statuses` for every open table (up to 36), so it grows with the board.
- `saveAll` is also called from `StoryDirector:_finish`, `ShoveState` act flags, `GrindState:_finalizeOnboarding`,
  `quickReset`, so it stacks with other work on the same frame.

Fix: compact encode (drop `pretty`), verify with a length/hash check instead of a full decode, or move the
encode+write onto a `love.thread` with the payload handed over as a string. Keep the atomic rename.

### 1.3 Room thumbnail re-renders the whole room into a brand-new fullscreen canvas
`views/GrindView.lua:_roomThumb` (line ~1033), called from the rail's room button `face_fn` every frame.

- Builds a `table.concat` key string every frame just to compare. When the key changes (any purchase, corruption,
  light toggle, unseen count, resize) it allocates a **new** `W×H` canvas, never releases the previous one, and
  draws the full room (`RoomView:draw` with lighting: placement resolve, sort, 100 floor tiles, wall courses,
  every item sprite, plus `RoomLighting` drawing into its own second fullscreen canvas).
- Canvas allocation on Windows/OpenGL is itself a stall and the abandoned canvases sit in VRAM until GC.

Fix: one persistent canvas reused in place; rerender on a numeric revision counter bumped by the events that
actually change the room, not a string compare.

### 1.4 Every sprite on disk is loaded at boot, twice-decoded, and half of them are duplicates
`services/SpriteLoader.lua:_scan`, `_sliceStrip`, `_conditionCard`; `assets/sprites/`.

- 2,300 files, 27 MB. `assets/sprites/isometric` (1,114 files, 13 MB) and
  `assets/sprites/TinyHouse_0.17(@Pixel_Salvaje)` (1,121 files, 14 MB) are the same asset pack twice. Both are
  scanned, decoded and uploaded to the GPU.
- For every non-card file `_sliceStrip` calls `love.image.newImageData(path)` to test whether it is a strip, then
  the non-strip path calls `love.graphics.newImage(path)` again: two full PNG decodes per file.
- Eight `.gif` files are attempted and fail inside `pcall` every boot.
- The catalog references 77 sprites; the room layout, cards, icons and tiles a few hundred more. Roughly 1,500 of
  the 2,300 uploads are never drawn.

Not a frame-time issue once running, but it is the boot stall, it inflates texture memory (visible on the F4 HUD),
and it is the reason `love.graphics.getStats().texturememory` is where it is. Fix: delete the duplicate tree, load
only referenced names (catalog + layout + cards + icons + tiles) eagerly and the rest lazily on first `getSprite`,
decode once (`newImageData` then `newImage(data)`).

### 1.5 Music DSP runs per sample in Lua on the main thread
`services/MusicDirector.lua:processChunk`, called from `MusicDirector.update` in `love.update`.

- While the player does not own `desk_speakers` (all of Act 1), every decoded chunk goes through a per-sample loop:
  two highpass stages, drive, cubic soft-clip, one-pole lowpass, sample-hold bitcrush, static mix, with
  `SoundData:getSample` and `setSample` C calls per sample per channel plus a `getSample` on the static bed. At
  44.1 kHz stereo that is ~180k C calls per second of audio.
- It is bursty: the refill loop runs up to 16 chunks in a single frame (`guard < 16`), and after a speak-cut it
  seeks and refills the whole queue at once, so the cost lands on one frame. On the web build `depth` is 10.

Fix: pre-render the "intercom" version of each track once at load (or lazily on first play) into a second
`SoundData`, and just switch which source plays. Same sound, zero per-frame DSP. If the ease between clean and
dirty must stay continuous, crossfade the two sources' volumes instead of easing filter coefficients.

### 1.6 `invalidateEffects` rebuilds the world on every award
`controllers/GrindController.lua:invalidateEffects` (line ~511), `_rebuildProcIndex`, `GameState:computeEffects`.

- Called on every bounty, every anti-bounty, every deck level-up, every deck unlock, every tournament payout, every
  `bank`/`ratchet` proc, `GrindState:enter`. Each call: walks the whole catalog applying effects, walks run
  upgrades (copying effect tables when a strength mult is on), walks decks, builds the 44-key `unbanked` map with
  string concatenation, then **unsubscribes and resubscribes every proc trigger on the event bus with fresh
  closures** and re-sorts each subscriber list.
- With the cursor swarm banking stacks back to back this fires several times a second in mid-game.

Fix: dirty flag consumed once per frame at the top of `update` instead of eager rebuild; keep the proc index and
only re-subscribe when the proc id list actually changed.

### 1.7 `AudioDevice.tick` enumerates playback devices once per second
`services/AudioDevice.lua`. `love.audio.getPlaybackDevices` on Windows enumerates audio endpoints; on some drivers
that is a multi-millisecond blocking call. Unmeasured, but it is a plausible source of a 1 Hz tick. Raise the poll
to 5 s, or poll from a thread.

---

## Tier 2: steady-state per-frame waste

Everything in this tier happens every frame regardless of whether anything changed. With one table it is noise.
With 36 tables and a full bankroll pile it is the frame.

### 2.1 The sidebars and the rail are rebuilt from scratch every frame
`views/Panel.lua:draw` calls `active_tab.build(game)` every frame. The three builders:

- **`GrindView:_buildTablesTabComponents`** (line ~307): per visible stake (up to 11): `TablePanelStats.evPerHand`
  (one `evStats`), `RollingValue.get` with a concatenated key, `bountyAward`, `typeCursorState` and
  `typePendingCloses` (each a full pass over the table list), then `TablePanelStats.breakdownLinesFor` (a second
  `evStats` plus `buildCashLines`, which builds render closures and `string.format`s a header) just to attach a
  tooltip that is only read on hover. Plus the game-type strip with a `RollingValue.get` per game type. Roughly 25
  `evStats` and 150 string allocations per frame before a single table is drawn.
- **`GrindView:_buildUpgradesTabComponents`** (line ~715): per upgrade: `getRunUpgradeNextCost` (fine),
  `wouldStrandRun` (scans tables and stakes), and `_buildRangeTooltip`. For the two fill upgrades the range tooltip
  **deep-copies `ctx` and runs `OutcomeMath.buildOutcome` for every visible stake × every game type × 2 (current
  and next level)**: ~110 `buildOutcome` calls and a few hundred allocations per frame, for a tooltip.
- **`GrindView:_buildRailComponents`** (line ~1125): `ShoveRate.compute`, `ShoveRate.formatBreakdown`, ~12
  `string.format`s, half a dozen closures (`face_fn`s), `Decks.specById`, `_deckTooltip` (builds icon rows),
  `currentFocusMult/Capacity`, `tiedUp` (scans tables with two `findById` each), every frame.

Then `GrindView:update` calls `CR.hitTest` on all three trees, which re-measures every component
(`lineRenderedHeight` → `font:getWrap`, a C call that allocates a table of lines) so each button line is wrapped
three to four times per frame (hit test, `buttonH`, the `total_lines_h` loop, the draw loop).

Fix: build the component trees on a revision (ctx revision + bankroll bucket + table count + hover state) and reuse
them; cache measured heights on the component; cache tooltip line tables by (ctx, stake, gtype) and invalidate on
`invalidateEffects`. This is the largest steady-state win in the file and it is entirely invisible.

### 2.2 Each table panel computes its EV three times and builds its tooltip every frame
`views/TablePanel.lua:draw` (line ~1819), `views/TablePanelStats.lua:evMetrics/measureEvReadout/drawEvReadout`.

Per table per frame:
- `Stats.measureEvReadout` → `evMetrics` → `tbl:estimateStats` → `OutcomeMath.evStats` (+ two `RollingValue.get`
  with concatenated keys + two `string.format`). Then `Stats.drawEvReadout` calls `evMetrics` **again** (a second
  `evStats`), then `buildEvBreakdownLines` → `tbl:debugStats` (a **third** `evStats`) → `buildCashLines` (closures,
  `string.format`) to attach tooltip lines to a hit box. Tournament tables call `breakdownLinesFor` (a fourth).
- `FeltLayout.compute` allocates ~15 tables (sizes, bands, rects, seats, L, button, rail).
- `tbl:liveStats()` allocates a table; `tiedText` is called twice (full and short) → two `RollingValue.get` + two
  `Format.money` (each a `string.format` + concat) before layout, then again inside `drawPlayerSeat`.
- ~10 `Lookups.findById` linear scans (`GameTypes`, `Stakes`) per panel, plus one per opponent seat in
  `drawOpponentSeat`, plus more in `drawPlayerSeat`, `drawPotLabel`, `drawTournamentLadder`.
- ~30 `Anchors.set` calls per panel, each allocating a 5-slot table, each with a `Table.anchorKey` string
  concatenation (`"table_" .. id .. "_" .. slot`): center, table:idx, pot, you, cards_you_1/2, board_1..5,
  opp_i and cards_opp_i_1/2 for 5 to 7 seats, tied, stack, ev, stack_pct. With 36 tables that is ~1,000 table
  allocations and ~1,000 string concatenations per frame from anchors alone.
- `card:spriteName()` concatenates `"cards/fronts/" .. suit .. "/" .. rank` per card per frame (up to 19 cards
  per panel: 5 board + 2 hole + 2 per opponent).
- Two closures (`desatOn`, `desatOff`) per panel per frame; `Effects.drawHoverShadow` allocates a three-layer
  table per call; the REBUY label allocates a two-string table with a `string.format`; hit boxes allocate ~6 tables
  per panel.
- `drawHistoryBars` allocates a `fit` closure; `drawTournamentLadder` builds and sorts a `finishes` list from the
  payout table every frame and allocates a `shortPos` closure.

Fix: memoize `evMetrics` per table on (ctx revision, stake, gtype); build tooltip lines lazily (store a thunk or
compute in the hover path); reuse anchor tables in place (`AnchorRegistry.set` can overwrite the four numbers of
an existing entry); precompute `Table.anchorKey` strings once per table (a small per-table cache keyed by slot);
give `Card` a precomputed `sprite_name` field; give `Stakes` and `GameTypes` an id index built once
(`Decks.specById` already does this pattern).

### 2.3 Chips: every chip is 12 to 20 immediate-mode primitives, every pile is re-laid-out every frame
`views/Chips.lua:paintChip/drawChip`, `views/ChipPile.lua:draw`, `views/ChipFlight.lua`.

- `paintChip` "full" detail: outline circle, rim circle, 6 to 8 `arc("fill","pie")` spots, face circle, 5 dome
  circles, 2 light arcs (`arc("line")` with line width changes), inlay polygon fill + line, a `setFont` + `print`
  for the label, and the inner ring. Each has its own `setColor`. None of it batches (LÖVE batches consecutive
  draws of the same texture; circles and arcs are separate geometry each time).
- With a bankroll pile (up to 10 cols × 2 rows × 6 = 120 chips), 36 pot piles and 36 stack piles, plus flights and
  confetti, the frame can be several thousand draw calls. That is what the F4 HUD's "draw calls" line will show.
- `ChipPile.draw` calls `layoutLocal` → `Chips.stackLayout` every frame for every pile: builds `groups`,
  `group_for`, `columns`, `row_of`, `in_row`, sorts the groups with a closure, allocates a table per placed chip
  (with a `rot` hash and `shade` per chip). Same again in `slotsByPos` for reserve/take. The layout only changes
  when the chip list changes.
- `ChipPile.sync` is called per pile per frame with a fresh `opts` table from the caller; `Denoms.paletteForAmount`
  per call scans the palette.
- `Chips.makeRenderFns` and `Tumble.wrap` create two closures per flying chip; `FlightSystem.emit` allocates four
  tables per entity. Fine per event, but pot explosions of 40+ chips with gather legs (a third closure each) are
  common.

Fix (biggest draw-call win, fully invisible): bake each denomination face at each `ui_scale` into a small atlas
(one canvas per scale, ~8 denominations × label/no-label × edge), then draw one quad per chip; keep the buried
"edge" variant procedural or bake it too. Cache `stackLayout` results per pile until the chip list changes.

### 2.4 `GrindController:update` allocates its own scratch every frame
`controllers/GrindController.lua:update` (line ~719).

- Four to five passes over the table list per frame.
- Two `for _, d in ipairs{ {1,0},{-1,0},{0,1},{0,-1} }` literals **inside the per-table loops** (lines ~755 and
  ~784): five table allocations per table per loop, 360 allocations per frame at 36 tables. Hoist to a module
  constant.
- Fresh `stakes`, `occupied`, `slots`, `cells` tables each frame; `TableGrid.bounds(slots)` recomputed;
  `love.timer.getTime()` sampled in several places; `table.remove(times, 1)` front-shifts the hands-per-second
  window (use a head index).
- `_syncStateList()` (16 fresh arrays) runs at the end of every frame that had a resolution, and again inside
  `_fireProcs` for every touched proc. With cursors dealing, that is most frames.

### 2.5 `GrindView:update` string-concatenates 88 keys per frame for the award glow
`views/GrindView.lua:update` (line ~886): the `AwardGlow` sweep loops all stakes × all game types every frame,
concatenating `stake.id .. ":" .. gt.id` and calling `bountyBanked` (which concatenates the same key again in
`bountyKey`). Move to an event (`on_stack_win` / tournament win already publish) or cache the key strings.

Also in `update`: `ipairs({ self.left_panel, self.right_panel, self.rail })` allocates a table per frame; the
hit-box hover loop concatenates `hb.action .. ":" .. id` per hovered box.

### 2.6 Text markup is re-parsed and re-measured on every draw
`views/IconText.lua:parse/walk/measure`, `views/GrindView.lua:_drawFloatingText`, `services/Tooltip.lua`.

- `IconText.draw` and `IconText.measure` both run `parse` (Lua pattern matching, `splitRun`, `findPill` char by
  char) and allocate an element list every call. Most call sites measure then draw the same string on the same
  frame, so every markup string is parsed twice per frame. Floaters measure each line with `gmatch` per frame.
- `Tooltip.draw` re-lays-out the whole box every frame it is showing: `IconText.wrap` is O(words²) in
  `font:getWidth` calls (it re-measures the growing line for every appended word) and runs every frame.
  `Tooltip.hover` in `love.update` re-runs `IconText.spans` over last frame's rows every frame the mouse is inside a
  tooltip.
- `StoryView:draw` calls `HintView.wrapLines` twice per frame while typing (full text and shown prefix), with
  `table.concat` of the shown words per frame.
- `CatalogReceipt.itemCard` is rebuilt every frame while hovering a catalog cell or a room item
  (`CatalogModal:draw`, `RoomState:_updateHover`, `CatalogReceipt:drawStandalone`).

Fix: a small parse cache keyed by string (strings are interned; a weak table works), a measure cache keyed by
(string, font), and tooltip layout cached until the lines table identity or the mouse anchor changes.

### 2.7 The room is fully re-resolved and re-sorted every frame it is on screen
`views/RoomView.lua:draw` (line ~637). Drawn on the room screen, the title, the shove's room-count phase, and the
grind thumbnail.

- Per frame: `owned_set`/`corrupted_set` rebuilt from the state lists, `_resolveSet`, `RoomPlacement.resolveAll`
  (copies every placed entry's fields into a new table, resolves homes recursively), a fresh `render_list`,
  `table.sort` with a comparator that recomputes depth per compare, a fresh `_hit_rects` (one table + one nested
  `draw` table per item), `Anchors.set("room:items", ...)` per item, `sprite_loader:itemArt` per item (a seven-way
  `if` chain and `getSprite` with alias resolution).
- 100 floor tiles and 2 × 10 × courses wall sprites drawn one `love.graphics.draw` at a time. They never change
  outside the editor.
- `RoomLighting.draw` renders into its own fullscreen canvas every frame and multiplies it over the scene.
- `RoomState:_drawCount` calls `GameState:countedItems(Catalog)` **every frame**: builds a 77-entry `by_id` map,
  an owned set, and scans every owned item's effects, to print one number.

Fix: resolve/sort on a layout revision (owned set, corrupted set, editor edits); cache `_hit_rects`; a
`SpriteBatch` or baked canvas for floor and walls; count once on enter.

### 2.8 `ShoveView` room phase and gauntlet draw
`views/ShoveView.lua`.

- `_drawRoomCount` draws the whole room (2.7) plus, per lit item, `itemArt` again and `state:isCorrupted(id)`
  (a linear scan of `corrupted_items`) per frame; `rects` map rebuilt per frame.
- During the gauntlet: `_drawShoveStatus` → `_drawStats` allocates two closures and does 4 to 6 `string.format`s per
  frame; `_coveredRuns` allocates; `_drawShoveStatus` builds `chip_indices` from the buildup chips every frame and
  `_drawPot` → `Chips.drawStack` re-lays-out the pot every frame (2.3); `_drawCheatCards` allocates `ipairs{6,7}`;
  `Motion.fade` keys are built with `tostring(anim)` concatenation per card per frame; `FlightSystem.draw()` is
  called twice per frame when `ending` (the pile phase draws flights twice).
- `snapshot()` allocates a fullscreen canvas on the win path (once per clear; acceptable but it is another canvas).

### 2.9 Miscellaneous per-frame allocations
- `love.mouse.getPosition` override (`main.lua`) recomputes `dpiFactor` + `fitTransform` (three window queries)
  per call; called dozens of times per frame from panels, hover, hit tests, CR. Compute once per frame in
  `love.update`.
- `HintCtx.build` allocates a 13-field table per frame; fine on its own, listed for completeness.
- `FloatingTextSystem` front-shifts with `table.remove(_texts, 1)`; `_drawFloatingText` allocates a `resolveToken`
  closure per frame.
- `CursorPool.update` is O(n²) over cursors and `panelAt` is linear over panels per cursor; fine at current counts.
- `CR._stat` allocates `ipairs{ {1,0},... }` for the glow print; `CatalogModal` line 1369 and `GrindView`
  `_brokenGlow` do the same.
- `Effects.drawGlow`/`drawStatusGlow`/`drawStatusFire` send uniforms and swap shaders per table; with many
  heaters the shader switches dominate. Batch by shader (draw all fires, then all glows) or bake the flame into a
  looping strip.

---

## Tier 3: per-hand and per-event churn

- **`Table:deal`** (`models/Table.lua:397`): `HandRealism.constructShowdownHand` is up to 16 matchups × 12 boards ×
  2 bestFiveOfN, with `HandClass.realize`/`remainingCards` allocations per matchup, then a legacy fallback of up to
  60 `Deck:new()` (52 `Card`s each). Then `HandEval.handLabel` is called twice more, re-evaluating both hands the
  construction just evaluated (the ranks are thrown away and recomputed). Then `HandScript.write` builds the event
  list. Measured 1 to 2 ms per deal in PUC Lua. With the swarm dealing 36 tables in bursts and `dealAll`, the spike
  is visible. `effectiveCtx` deep-copies `ctx` (every nested table) the first time a tilted table reads it after
  each `invalidateEffects`.
- **Resolution loop** (`GrindController:update`, resolutions half): per resolution `Decks.checkPendingUnlocks`
  (every deck spec through the unlock registry), `_grantDeckXp` (xp registry), 3 to 5 `_announce` (each a publish +
  synchronous `drain`), `Lookups.findById`/`indexById` on stakes 4 to 6 times, `floater_opts` copied twice,
  `string.format` for the label. Plus `_syncStateList` at the end.
- **Procs**: `_fireProcs` allocates a 17-field event per proc per trigger; `ProcRegistry:fire` allocates a
  delivery table per target when routers exist; `procFired`/`itemFired` → `ItemStream.spawn` →
  `Lookups.findById(Catalog)` (77 entries) + `roomEntry` → `rv:layoutEntry` (linear over placed entries with a
  pattern match per entry) + `state:isCorrupted` (linear) per fire. `ItemStream.draw` calls `itemArt` per animated
  icon per frame.
- **`GameState:isCorrupted`** is a linear scan used from hot paths (receipt rows, room items, catalog cards,
  item stream). Keep a set alongside the list.
- **Chip flights per script event**: `flyChipsToPot` → `ChipFlight.transfer` → `ChipPile.take` (full scan per
  chip taken, `breakChip` inserts) + `_reserveAcross` → `ChipPile.reserve` → `slotsByPos` → full `stackLayout`,
  then a `Denoms.breakdown` (sorts the palette every call) and closures per chip. Six to ten of these per hand per
  table.
- **`Table:update` → `Lookups.findById(GameTypesData)`** once or twice per table per frame (this is Tier 2 really,
  listed here because it is fixed by the same id index).

---

## Tier 4: reuse. One renderer, not three

This is the structural answer to the mid-turn question. Most of the per-frame cost above exists because each
surface owns a private copy of the same machinery, so nothing can be cached in one place.

### 4.1 Three paper renderers
- `views/CatalogModal.lua`: `paperSecs`, `drawFlipped` (hinge), `_enter_t`/`_throw_t`/`flip_t` tweens,
  `_feltSpot`, `_drawClosedOnFelt`, scrim, `_cells` hit list, page-turn state, sticker layer.
- `views/DeckFlyer.lua`: `hinged` (same hinge), `_throw_t`/`_open_t` tweens, `_feltSpot`, `_drawClosedOnFelt`,
  scrim, `_tiles` hit list, `col()` alpha wrapper.
- `views/CatalogReceipt.lua`: its own slide tween, paper body, `_row_rects` hit list, teeth, `rowAt`.

One `Paper` component (throw-to-felt, land, open/close, hinge flip, scrim, felt spot, alpha, hit list) with the
three as content callbacks. Then the throw tween, the felt spot, and the hit test are written once and cached once.

### 4.2 Five modal frames
`views/widgets/Modal.lua` is used by `SettingsModal` and `ActionModal`. `HintView`, `ShoveDebugOverlay`,
`DemoEndModal`, `AnalyticsConsentModal`, `ConfirmDialog`, `GlossaryPanel`, and the two paper modals each draw their
own box, border, scrim and title. One frame, one scrim, one "avoid the story band" rule.

### 4.3 Four fullscreen scratch canvases plus one per snapshot
`HintView._dim_canvas`, `RoomLighting._canvas`, `TitleView._ui`, `GrindView._room_thumb.canvas` (leaked on
rebuild), `ShoveView:snapshot()` (fresh per clear). One `ScratchCanvas` service sized to the base frame, checked
out and returned, would cut VRAM and remove the reallocation stalls.

### 4.4 Duplicated helpers (each a small cost, together a sign nothing is shared)
- `now()` in `HoverService`, `Tooltip`, `Motion`, `Pop`, `RollingValue`.
- `darken()` in `RoomView`, `Button`, `FeltDecor`, `ShoveDecor`, `Sticker` (each allocates a colour table per call;
  `Button.draw` allocates one per button per frame for the side colour).
- Colour-token resolvers: `Theme.semColor`, `ComponentRenderer.tokenColor`, `Tooltip.tokenColor`,
  `TablePanelEffects.tokenColor` (with a pattern match per call), `GrindView._drawFloatingText.resolveToken`,
  and an inline chain in `TablePanelStats.renderDebugTooltip`.
- Text wrapping: `IconText.wrap`, `HintView.wrapLines`, `font:getWrap` in `ComponentRenderer` and `Tooltip`.
- Icon rows: `TablePanelStats.iconRow` and `GrindView.iconRows`.
- Hinge flip: `CatalogModal.drawFlipped` and `DeckFlyer.hinged`.
- Radial textures baked three ways: `FeltDecor.configure` (vignette mask), `HouseArt.glowTex`,
  `ShoveDecor.configure` (light).
- `printCentered`, `clamp01`, `ifloor`, `iconWrapCentered` each exist twice.
- Hit-box systems: `GrindView.hit_boxes` (linear walk), `ComponentRenderer.hitTest` (tree walk with re-measure),
  `CatalogModal._cells`, `DeckFlyer._tiles`, `SettingsModal._row_rects`, `CatalogReceipt._row_rects`,
  `RoomView._hit_rects`, `TablePanel` felt buttons. One hit registry (rect + id + payload, cleared per frame)
  would make hover a single pass and would let the anchor registry and hit registry share tables.
- `Lookups.findById` over `Stakes`/`GameTypes`: 10 call sites in `TablePanel`, 18 in `GrindController`, 19 in
  `Table`. An id index on the data modules (as `Decks.specById` does) replaces all of them.

### 4.5 Tooltip content builders
`TablePanelStats.buildCashLines/buildKoLines/buildLegacyKoLines/appendPayoutLines`,
`GrindView._buildRangeTooltip/_deckTooltip`, `CatalogReceipt.itemCard`, `ShoveRate.formatBreakdown`. All produce
line tables with closures and formatted strings, all are called on the draw path, none are cached. One
`TooltipCache.get(key, builder)` keyed on the inputs that can change them (ctx revision, stake, gtype, level) would
make every one of them free after the first frame.

---

## What is fine (checked, no action)

- `EventBus`: pooled events, sorted subscriber lists, per-frame cap. Good.
- `Table:effectiveCtx`: revision-cached; `_tickStatuses` does not bump the revision while decaying. Good.
- `HintController` / `StoryDirector`: throttled to 0.15 s. Good.
- `MusicDirector.ownsSpeakers`: cached on owned count. Good.
- `RoomView.getSpriteBottom` / `spriteAlphaAt`: cached ImageData. Good (the hover check still walks every frame of
  an animated sprite, minor).
- `HandRealism.policyFor`: memoized. `PreflopEquity.cumulativeFor`: memoized. Good.
- `SoundService.playFile`: clone pool. Good.
- `Motion`, `Pop`, `RollingValue`, `ClickFlash`: cheap.
- `SpriteLoader.getSpriteFor` LOD chain for card backs: correct and cheap.
- `Decks.specById`: the pattern the rest of the data modules should copy.

---

## Recommended order

Ranked by (frame time saved) ÷ (risk of a visible change). None of these alter output.

1. **Cache the UI model.** Sidebar/rail component trees on a revision; per-table `evMetrics` and tooltip lines on
   (ctx revision, stake, gtype); parse/measure cache in `IconText`; tooltip layout cache. (2.1, 2.2, 2.6, 4.5)
2. **Chip face atlas + cached pile layout.** Draw calls drop by an order of magnitude with a full board. (2.3)
3. **Gauntlet construction off the frame.** Coroutine with a time budget across the buildup, and an allocation-free
   evaluator. (1.1)
4. **Stop allocating anchors, keys and scratch tables.** In-place `AnchorRegistry.set`, per-table anchor key cache,
   `Card.sprite_name`, hoisted direction constants, id indexes for stakes/game types. (2.2, 2.4, 2.5, 2.9, 4.4)
5. **`invalidateEffects` as a once-per-frame dirty flag; keep proc subscriptions.** (1.6)
6. **Save path**: compact JSON, cheap verify, or a thread. (1.2)
7. **Room**: resolve/sort on a revision, batched floor/walls, persistent thumbnail canvas, count once. (1.3, 2.7)
8. **Sprites**: delete the duplicate pack, load referenced sprites only, decode once. (1.4)
9. **Music**: pre-rendered intercom mix instead of per-sample DSP. (1.5)
10. **The reuse pass**: one `Paper`, one modal frame, one scratch canvas, one hit registry, one token resolver.
    (4.1 to 4.4) This is the one that keeps the list above from growing back.

Measure with the F4 HUD (draw calls, chips, texture memory) and `love.timer.getAverageDelta()` at 1, 12 and 36
tables before touching anything, so each step has a number.
