# Save system audit (2026-09-09)

Audit only; nothing changed. Line numbers are as of commit `a34149d`.

## Verdict

Rip out the state half and rebuild it. Keep the file half, with three fixes.

The system is two very different things bolted together. `services/SaveService.lua` (354 lines) is the
file layer: stage to `.tmp`, verify, commit, recover, a writer thread. It is small, mostly sound, and has
three real bugs. `models/GameState.lua` (1,340 lines) plus `models/TablePool.lua` is the state half, and
that is where the rot is: **30 distinct migration and backfill paths** on every load, **61 id-map entries**
across two data files, **~55 `or` defaults**, three one-shot migration flags persisted into the save itself,
a dead field still written to every save, a declared coverage test that does not exist, and a table
persistence scheme that is 16 parallel arrays which between them cannot describe a hand. Every load runs
all of it. None of it is needed once old saves are allowed to break, which the designer has said they are.

The live saves are tiny (`meta.save` 4 KB with 65 keys, `run.save` 3 KB with 34 keys). The 49 MB in the
save directory is 85 orphaned `analytics_<save_id>.json` files, one per new game, never cleaned up.

## Bug: a tilt or heater sticks forever after a reload

One root cause, five lines apart from two contradictory comments.

- `models/TablePool.lua:225` saves `t.statuses` (by reference), and `:149-153` restores it on rebuild.
- `models/Table.lua:272-275` says statuses are "transient by design: `_syncStateList` doesn't carry them,
  so they evaporate on load". That was true once and is false now.
- Heater and tilt are `lifetime = "punch"` (`data/statuses.lua:86-124`): no timer, no charges. The
  entry has `t = nil` and `charges = nil` (`Table.lua:1301-1303`), so `_tickStatuses` (`:1397`) and
  `_spendStatusCharges` (`:1424`) both skip it. The only thing that ends a punch is
  `_expirePunchStatuses`, and all three call sites gate on fields the restore never writes:
  `_forced_next_won` (`:1036`), `_interrupt_kind` (`:1684`), `_punch_live` (`:1722`). `Table:new` sets
  every one of those to nil and nothing in the 16 arrays carries them.
- "Until it gets a new one" is exactly the escape hatch: a fresh punch arms `_punch_live` through the
  auto-deal, and when that hand finalizes `_expirePunchStatuses` drops every punch entry, stale one
  included. `cleanse` (`table_procs.lua:305-329`) removes `polarity == "bad"` only, so a Cool Towel
  clears a zombie tilt but never a zombie heater.

Two mutually exclusive fixes; pick which comment is the spec: drop punch entries in `rebuildFromState`
(matches `Table.lua:272`), or persist `_forced_next_won` and re-arm it (matches `TablePool.lua:146`).
In a rebuild this disappears: a table that serializes its own punch latches has no zombie.

## Bug: tables come back empty

Two causes, and the first is not a save bug at all.

**`GrindState:enter` rebuilds every table from scratch on every entry** (`states/GrindState.lua:177`,
`self.controller.pool:rebuildFromState(...)` unconditionally). Its own comment says "the rebuild discards
every Table object". Toggling to the Room and back wipes every hand in flight, without a save or a load.

**The 16 arrays do not contain a hand.** `TablePool:_syncStateList` (`:195-267`) writes spec, slot, two
cursor mutes, five KO fields, five tournament seat fields, `stack`, and `statuses`. `rebuildFromState`
(`:68-188`) calls `Table:new` and pokes exactly those back. Everything else is the constructor default:

- the hand: `script`, `script_idx`, `script_timer`, `playback_state`, `state` (back to `"idle"`),
  `state_timer`, `view_event_cursor`
- the felt: `player_hole`, `opponent_hole`, `community`, hand names and combos, `last_hand`
- the rolled outcome: `outcome_won/tier/delta`, `_pending_resolution` (a hand one frame from settling
  pays nothing)
- `opponents` (re-rolled, new names), `button_visual_seat`, `hands_played`, `last_results` (the mini
  bar graph), `_combo` (the Washing Machine streak), every punch latch, `_next_win_tier_up`,
  `_hand_mult`, `_fast_fold_pending`, `_pending_buyin`, `pending_close`, `ko.pending_payout`,
  `untilt_t`, `GrindController.timed_buffs`
- **cash `stack`**: saved at `:239`, restored only inside the tournament branch at `:142`. Every cash
  table refills to `stake.buy_in` for free on every load. A busted table waiting on REBUY comes back
  stocked. `GameState.lua:231-233` claims the opposite.

A proper design is `Table:serialize()` / `Table.restore(rec)` owning the whole record including the
hand snapshot, the pool holding a list of records, and `GrindState:enter` not rebuilding anything
unless it just loaded.

## The shove: what happens today and what to change

Three pieces, no single function:

1. `GrindController:initiateShove` (`:2989-3003`) banks and zeroes the chips, sets `shove_pending`, and
   calls `saveAll` **without `sync`**. On desktop that is a queued write that returns true regardless;
   the 12-line comment above it calls this "one atomic fact on disk".
2. `ShoveState:enter` (`:130-135`) rolls the three outcomes into `shove_pending.outcomes` and saves, so
   a reload never rerolls.
3. `TitleState._go` (`:168-178`) routes Continue into `"shove"` whenever `shove_pending` is set.

So a reload restarts the shove from the buildup and replays the same pre-rolled gauntlet. That holds
through the showdown, the result hold, the catalog browse, and the act reveal: the only things that
clear `shove_pending` are the clear path (`ShoveState.lua:306`) and `resetRun` (`GameState.lua:341`),
and the bust path saves nothing, so quitting on the post-bust catalog puts the player back at the start
of the shove with the reveal already spent (`_recordActFlags` at `:235-252` set the act flags and saved
before the reveal played; on replay `_milestoneFor` returns nil).

The requested behaviour: once the showdown has finished, save the result (`resetRun` +
`applyStartingPerks`, the new bankroll, `shove_pending = nil`) and let a quit land in the grind. Today
`_dismissCatalogAndReturn` (`:422-436`) and `_finalizePostBustReturn` (`:441-451`) do that reset in
memory with no save, and `_resolveDemoEnd("exit")` (`:337-347`) switches to title where `flushSave`
refuses to write, so the disk keeps saying the shove is pending. The change is: at the moment the
showdown result exists, do the reset and a synchronous save right there; everything after it (catalog,
reveal, credits) is presentation over an already-settled run.

## Legacy and redundancy inventory

`services/SaveService.lua` (6): `coerceIntKeys` (`:44-60`, "lifted from CC"); version-drift tolerance
(`:138-146`, `VERSION` has been 1 since inception so it has never fired); `.tmp` recovery (`:160-164`);
the no-`os.rename` fallback (`:223-229`); `write()`'s `load_failed` guard (`:235-238`, dead, its only
caller is settings); `clearRun` (`:330-332`, no callers, and the "wiped on prestige by clearRun" comment
at `GameState.lua:960` is false).

`models/GameState.lua`, one-shots and dated migrations (7): `pp` → `chips` (`:623-626`, 2026-05);
`deck_overhaul_migrated` (`:632-635`, `:839-880`, and it zeroes every deck level unconditionally);
`stake_break_migrated` (`:669-686`, the `retired_` spec-retag); `deck_roster_migrated` (`:694-718`);
Focus `max_level` clamp (`:580-589`); `highest_stake_id` string→index (`:794-802`); `hints_queued = nil`
(`:818`). Three of those flags are persisted into every save forever.

Presence-guarded promotions (4): `has_shoved` from `shove_count` (`:765`), `hu/six_max_unlocked` from
`has_shoved` (`:774`), retro-suppressed `gtype_announced` (`:783`), `catalog_seen` (`:788`).

Id and field remaps (9 sub-paths, 61 entries): items ×49, fields ×8, gtype in specs, gtype in bounty
keys, gtype counters, run upgrades, decks ×4 sites, tier strings by depth-8 walk (`:521-615`).

Pure backfills: ~55 `or` defaults in five blocks, six of which are cross-field
(`total_* ← lifetime_*`, `:721-739`) and run on every load, not just old saves.

Dead: `zoom_sharp_banked` (init, reset, backfill, serialize; zero other references; cites a proc that
no longer exists); `GameState.TRANSIENTS` (never read); `GameState.REFS` (always empty, nil resolver);
`Constants.SAVE.AUTOSAVE_INTERVAL = 30` (unread; the real value is 10 in `main.lua:217`); two inert
catalog map lines (`whiteboard`, `copy_machine`); the `"quit"` sentinel in `save_worker.lua` that nothing
sends. The coverage test that `GameState.lua:9-10` and `AutoSerializer.lua:4-5` cite does not exist;
`loan_fresh` is already in the constructor and in neither serializer.

Two stat families, `total_*` (15 keys) and `lifetime_*` (10 keys), mirror each other with backfills
between them. Which is read where was not traced; decide which survives.

## Other bugs found, ranked

1. **A corrupt `settings.save` kills all progress saving for the session.** `SaveService:read`
   (`:166-172`) latches `load_failed` for any file; `loadSettings` goes through it; `saveAll` then
   refuses every write (`:290`) silently. Fix: latch only when `isProgressSlot(filename)`.
2. **The async autosave has the torn meta/run window the comment says was fixed.** Two jobs on one
   channel, committed one after the other (`save_worker.lua:47-73`). Also `:299-308`: if meta fails to
   encode, run is still pushed. One file with both sections removes the class.
3. **Sync quit does not drain queued worker jobs** (`main.lua:944` passes `sync`, nothing waits on the
   channel). A queued autosave can commit after the final write.
4. **Deck id map duplicates `unlocked_decks`** (`cursor`→`swarm` and `nit`→`swarm`, no dedupe at
   `:596`); `Decks.applyEffects` iterates the list, so Swarm's passive and capstone apply twice. The
   migration test seeds this exact case and passes because it only checks presence.
5. **Ten many-to-one catalog renames duplicate `owned_items`**; `_buildCountedItems` (`:1187-1205`)
   counts the raw list, inflating the shove base permanently.
6. **`room_lights_off` is written to settings and never read back**: `main.lua:335-347` rebuilds
   `g.settings` from an allowlist that omits it.
7. **`TitleState.hasSave()` disagrees with `SaveService:read`**: a save recoverable from `.tmp` hides
   Continue and lets New skip its confirm; an unreadable file offers Continue on a blank state.
8. **`startNewGame` sets `analytics_consent = false`** (`main.lua:453-456`), which the comment 110 lines
   above says must stay nil so the consent ask can fire. It never fires again.
9. **Three of four wipe paths orphan the analytics file** (only `startNewGame` calls `deleteCurrent`).
   That is the 85 files and 49 MB.
10. **The Room has no autosave** (`main.lua:711`); the post-bust catalog browse suppresses autosave for
    its whole duration (`:708`, `catalog_modal` is set as a timeline beat).
11. `_migrateDeckState` zeroes all deck progress; `_stage` verification is length + last byte, so a
    same-length corruption commits over the good file with no `.bak`; `_commit` removes the live file
    before it knows the rename will work; `json.encode` writes cycles as `null` silently.

## What the rebuild looks like

- **One save file**, `{ version, meta, run }`, plus `settings.save`. `VERSION = 2`; a version-1 file is
  refused with a message and left on disk. The torn-pair class, `clearRun`, and the meta/run
  cross-checks go away.
- **Tables own their record.** `Table:serialize()` returns everything the table needs to resume,
  including the hand snapshot and the punch latches; `Table.restore(rec, ctx)` rebuilds one. The pool
  saves a list of records. `GrindState:enter` rebuilds only when a load just happened.
- **GameState is explicit**: one list of persisted keys, no `AutoSerializer`, no migrations, no
  backfills, no one-shot flags, one stat family. The constructor is the schema; a headless check walks
  it against the list so drift fails a test, which is the test the code already claims to have.
- **SaveService stays**, with the latch scoped to progress files, the writer drained on quit, and a
  `.bak` kept from the previous good commit.
- **The shove** settles and saves synchronously the moment the showdown result exists.
- **Analytics** files deleted on every wipe path, and the existing 85 cleaned once.

Roughly: GameState loses ~500 lines, TablePool loses its 16 arrays for one loop each way, Table gains
~80 lines, the two migration data files and `verify_save_migration.lua` are deleted, and a new
`sim/verify_save_roundtrip.lua` proves a live board with hands in flight survives serialize → restore
byte-for-byte.

---

# Landed (2026-09-09)

Everything above is done, plus the two shove changes. Verified by
`sim/verify_save_roundtrip.lua` (127 checks), the save section of
`sim/smoke_views.lua` (both commit paths), and the rest of the suite green
with `docs/sim-audit.md` unchanged but for the two deck-unlock counter names.

**One file, version 2.** `save.json` holds `{ version, saved_at, meta, run }`;
`meta.save` and `run.save` are gone, and with them the torn-pair class the old
comment claimed was fixed and was not. A version that is not 2 is refused,
kept on disk, and reported to the title screen; there is no converter. The
commit keeps one `.bak` on the rename path (desktop) and `load()` falls back
through `.tmp` and `.bak`. `load_failed` now latches only for the save file, so
a corrupt `settings.save` no longer silently suspends every save for the
session. `flushWorker` counts pushes against reports so the quit path waits for
the writer instead of racing it. Everything writes through one `Game.save(sync)`
and wipes through one `Game.newGame()`, which is what makes the paths agree.

**Tables own their record.** `Table:serialize` / `Table.restore` replace the
sixteen parallel arrays. A save now carries the hand in flight (script, cursor,
cards, pot, seats, the pre-rolled outcome), the history the panel draws, the
statuses AND the latches that end them, the KO session including a payout that
had not been drained, and the opponents by name. Cash stacks restore, so a
busted table stays busted instead of being handed a free buy-in. Entering the
grind no longer rebuilds the pool: only `GrindController:reloadPool()` does,
called from the paths that replace the records.

**The status bug** is fixed by that: a heater or tilt is a punch status with no
timer and no charges, so the only thing that ends it is the hand
`_forced_next_won` obliges. Restoring the status without the latch left it
burning forever. The round-trip test asserts both burn out after a reload.

**GameState is the schema.** Three key lists, and `applySaved` assigns listed
keys and nothing else. Deleted: 30 migration and backfill paths, both id-map
files, `AutoSerializer`, three one-shot migration flags that were persisted
forever, and the `lifetime_*` family (two survivors became `total_stacks` and
`total_money_won`), `zoom_sharp_banked`, `total_big_outcomes`,
`total_tilts_absorbed`, `highest_stake_idx`, `hands_since_last_bank`,
`screen_visits`. `models/GameState.lua` lost 445 lines. The coverage test the
file has claimed since May now exists and passes.

**The shove settles when the showdown has played.** A settle beat on the
cinematic timeline, right after the summary, banks the result into
`last_shove`, records the act flags, resets the run and saves. Quit after it
and the next launch opens in the grind on the new run; quit before it and the
same shove replays from the buildup with the same pre-rolled result. The
starting perks wait for the catalog browse that follows (`perks_pending`), so
an item bought there still seeds the run it was bought for, and whoever reaches
it first pays it exactly once.

**Also fixed:** settings load through an explicit key list, so
`room_lights_off` survives a launch; the room autosaves and a modal no longer
suppresses the tick; `HandAnalytics.deleteCurrent` takes the save id so the
title's delete and F7 stop orphaning analytics files; new game no longer forces
`analytics_consent` to false, which had made the consent ask unreachable.

**Not done:** the 85 existing orphan analytics files are left on disk by the
designer's choice; only new orphans are prevented.
