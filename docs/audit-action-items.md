# Audit action items

Distilled from `docs/audit-aug2026-full.md` (7,449 lines, snapshot ~Aug 18),
cross-checked line-by-line against the tree as of **Aug 26** (post demo-gut,
post the six emergency fixes). Every item below is written so a session can
pick it up and execute it: what to do, where, and which audit lines carry the
full evidence. `[audit NNNN]` = line number in audit-aug2026-full.md.

Statuses: each item is OPEN unless marked otherwise. Severity is for the
group; individual bullets inherit it unless tagged.

---

## Already resolved — do not re-chase

- SPACE-skip crash `BUILDUP_TOTAL` — fixed Aug 24 (`902dbf1`) [audit 276-388]
- `ev_sign`/`ev_color` nil tooltip — fixed Aug 23 (`ac3bff0`) [audit 3044]
- `data/balance.lua` untracked / commit-breaks-clone — committed Aug 19 [audit 215-257]
- NaN bankroll capstone — superseded by `ShoveRate.bankrollMultiplier` (clamped) + load-time NaN repair [audit 4075-4112]
- `r.table_idx` staleness → `r.table` reference — fixed Aug 26 [audit 1949-1992]
- Room `U` catalog wipe — DEV_HOTKEYS-gated Aug 26 [audit 4913-4949]
- Load-wipes-before-check — guarded Aug 26 [audit 5260-5271]
- VERSION-bump wipe + dead `== nil` migration guards — fixed Aug 26 [audit 4255-4263, 4332-4357]
- `love.errorhandler` + quit-flush (grind/shove/room) — added Aug 26 [audit 5757-5784, 5813-5814]
- json `inf` guard — fixed Aug 26 [audit 4426-4442]
- Everything about `Table_legacy` / `HandScript_legacy` / `MttSession_legacy`,
  `PROTOTYPE_MODE`, run0, OnboardingModal, PrestigeModal, PrototypeEndModal,
  legacy MTT UI, F1-F7 drift, WC-cap duplication — the whole fork was deleted
  Aug 26 (demo gut). Sections [audit 3372-3947, 2439-2516] are history.
- Room furnishes 9/49 items — stale; the room places the full catalog since Aug 25 [audit 5987-6000]
- `ui_scale`/resize "pinned" — by design (fixed 1600x900 canvas) [audit 5871]
- MTT "100bb chips" blurb — fixed in the gut [audit 7776-7779 ref 6857]
- Print-spam finding — the audit itself downgraded it to a non-issue [audit 4818-4837]
- `services/Confetti.lua` "dead" — now live (`views/ShoveView.lua:45` requires it). `views/widgets/Row.lua` is live too (SettingsModal). Only Dropdown remains dead.

---

## 1. Save integrity hardening — HIGH (before the demo ships)

The remaining save-layer work after the Aug 26 fixes. Full fix list at
[audit 4569-4583]; write-safety evidence [audit 4498-4531].

- **Atomic writes**: `SaveService:write` truncates the live file in place.
  Write to `<file>.tmp` then rename; write both slots' tmps before renaming
  either so meta/run can't tear (a tear enables bounty re-banking:
  [audit 4511-4519]).
- **pcall the encode** in `SaveService:write` and log instead of crashing the
  autosave/quit path [audit 4509]. Log the real decode error in `read`
  (its pcall currently discards it) [audit 4488-4494].
- **Never overwrite a save that failed to load**: when `read` returns an
  error other than "no save", set a `load_failed` flag and suppress
  autosave/quit writes for the session [audit 4572]. This closes the
  "corrupt file → silent fresh game → autosave overwrites" loss path.
- **Old-itch-save MTT restore crash** (the F0 descendant, still live): a save
  with `active_table_mtt_state[i] == "playing"` but no
  `active_table_seat_stacks`/`mtt_plans` restores into the current build and
  crashes on the first MTT deal (`self.seat_busted[s]` nil-index). In
  `TablePool:rebuildFromState`: `if mstate[i] == "playing" and not
  (seat_stacks[i] and mtt_plans[i]) then hands_won = 0; state = nil end`
  [audit 3559-3583, 3817-3832]. Add the headless test the audit specifies.
  Decide `active_table_mtt_hands_won` semantics once (lifetime counter)
  [audit 3921-3935].
- **Stale stake id in `active_table_specs`** has no fallback (permanently
  dead table); mirror the six_max gtype fallback [audit 4283].
- **Serializer coverage test**: a new `GameState:new` field silently never
  persists (write side is a hand allowlist; AutoSerializer.serialize is dead
  and three comments lie about it). Add a test asserting every `:new()` field
  is in `serializeMeta ∪ serializeRun ∪ TRANSIENTS`; delete or implement
  `AutoSerializer.serialize` + the dead `TRANSIENTS`/`REFS`, fix the three
  comments [audit 4368-4398].
- **Float formatting**: encode numbers with `%.17g` so late-game bankrolls
  round-trip exactly [audit 4453-4460].
- **Analytics file**: unbounded, rewritten fully every 30s, orphaned on new
  game. Cap retained shoves, drop pretty-print, delete it in
  `SaveService:clearAll` [audit 4531].
- Low: `highest_stake_idx` persists a positional index, store the id
  [audit 4359-4361]. `current_stake_id` is write-only dead payload [audit 4363].

## 2. Web/demo ship-readiness — HIGH (demo-blocking)

- **Consent modal is unreachable — analytics never sends.** `main.lua:229`
  coerces `analytics_consent` nil→false at load, so GrindState's `== nil`
  first-run ask can never fire. Verified live today. Restore the tri-state
  (keep nil when unset) so the ask actually shows; also fix SettingsModal's
  display reading nil as "on" while the flush gate reads it as off
  [audit 4539-4551, 6231-6235]. Without this the demo produces zero telemetry.
- **Analytics GET endpoint has no auth**: `?all` dumps every player's entire
  dataset, CORS `*`, URL visible in the shipped page source. Gate reads
  behind a Wrangler secret token; POST can stay open [audit 6237-6248].
- **Tab-close save flush**: `love.quit` never fires on web and IDBFS persists
  async. Add a `beforeunload`/`visibilitychange` hook in
  `build-tools/index.html` that drives one final save [audit 4527, 5816-5817].
- **TitleState Exit button** calls `love.event.quit()` ungated — the exact
  canvas hard-error the old QUIT_DISABLED flag existed to prevent. Give it the
  same `getOS() == "Web"` gate SettingsModal now uses [audit 5819-5838].
- **build_web.py guards**: refuse (or warn) on a dirty tree; assert
  `C.DEMO == true` when building the demo (the flag is manual and unenforced)
  [audit 6193-6202]. Note for any future public build: `DEV_HOTKEYS` must be
  off — currently it keys off `not C.DEMO`, so a "full release" build needs
  its own flag.
- **Asset trim ~1MB** off the web download: 4 undecodable GIF card backs, the
  unused `Overhand/` shuffle WAVs (~806KB), `Chips/5on3` (~94KB), 5 legacy
  MP3s [audit 5025-5034]. Also delete SpriteLoader's dead `assets/isometric`
  scan block [audit 5036-5045].

## 3. Live gameplay bugs — HIGH

- **KO cash-out exploit**: `ShoveState:enter` hand-rolls cash-out
  (`pool.tables = {}`, credits `t.stack` 1:1), so a doubled tournament stack
  converts to real dollars on SHOVE, where `cashOutAll` would refund $0.
  Route through `self.game.grind:cashOutAll()` [audit 636-670]. Verify
  current line numbers; the shape was confirmed pre-gut.
- **Cursor swarm acts on stale table indices**: `CursorPool.update` runs after
  the controller may have removed tables, against last frame's `hit_boxes`,
  so an unattended cursor can close/rebuy the wrong table. Same
  index-as-identity class as the fixed `table_idx` bug; key hit boxes by
  table identity or rebuild before dispatch [audit 1994-2007].
- **Tab bypasses every modal** in GrindState (checked first). Move the `tab`
  branch below the modal blocks [audit 5352-5365].
- **ESC/dev-key fall-through over modals**: CatalogModal's `consumeKey`
  returns false for unmapped keys and the branch has no unconditional return,
  so ESC stacks Settings over the post-bust catalog (and dev `r` resets the
  gauntlet under it). Fix once in `ActionModal:consumeKey`: swallow all keys
  while unresolved (ConfirmDialog already does) + add the missing returns
  [audit 5314-5350].
- **Right/middle click acts as left** in grind/shove/room `mousepressed`
  (TitleState filters, the others don't) [audit 5724-5730]. **Stuck drag**:
  no `love.mousefocus`/`focus` handler clears drag state when the button is
  released outside the window (volume slider) [audit 5732-5744].
- **Reset leaks**: `pending_bursts` survives fullReset/quickReset (ghost chip
  flights from dead tables) [audit 2098-2104]; view tweens/caches survive a
  new game (bankroll visibly counts down from the old game's number;
  `RollingValue.reset` never called; AwardGlow has no clear) [audit 2161-2171].
- **Top-bar achip cell** isn't re-reserved when `shove_r2_won` flips
  mid-session → overlap until resize; reserve unconditionally like the deck
  cell [audit 2080-2096].

## 4. Committed-regression cleanup — MEDIUM (small, do in one sitting)

All verified still present today.

- `services/FloatingTextSystem.lua:78-95`: the table-attached freeze branch is
  commented out, so table-pinned floaters fade like normal ones and
  `has_persisted` is never set (dead read at the removal guard). Restore the
  branch or delete it + the `saw_idle`/`has_persisted` machinery
  [audit 5141-5173, 6089-6116]. Also stop `getTexts()` returning the live
  internal table [audit 7396-7402].
- `views/widgets/Sticker.lua:365,376`: `(PAD(s)*2 + INLAY(s))*2` over-allocates
  by `2*PAD`; should be `(PAD(s)+INLAY(s))*2` (regression from the
  MARGIN→INLAY rename) [audit 5420-5432]. Delete the dead `brighten` helper
  (:53) or wire it into the gloss [audit 5434-5440, 6130-6139].
- CatalogModal hero-card text has no `clampText`/wrap, unlike the non-hero
  path; a long-named `slots >= 3` item prints past the card edges
  [audit 5442-5456]. Sticker peel isn't cancelled by a page flip mid-drag
  [audit 5475-5476].
- `views/TablePanelStats.lua` local `fmtMoney` never abbreviates: 7-9 digit
  strings on the HUD at high stakes (reaches the stake-add buttons through
  `evLabel`). Delegate to `utils/format.lua` [audit 6722-6755].

## 5. Balance-data truth — needs USER decisions, then small fixes

- **`data/balance.lua` derivation is internally wrong.** The flat per-item
  shove overwrite is by design ("items are flat 1%"), but:
  `ACT1_ITEM_COUNT = 49` is actually total-catalog-size mislabeled, the
  comment math says `25 * 0.70 = 17.5` while the code computes 34.3, and the
  resulting `K_SHOVE_PER_ITEM ≈ 0.0078` is roughly **half** the ~1% the
  design notes imply. Recount post-gut (demo strips 27 items), fix the
  constants/comments, and delete the 47 dead authored `shove_rate_add`
  literals that no longer do anything [audit 5912-5967]. USER: confirm the
  intended K.
- **`data/bankroll_tiers.lua` plateaus at $10M / 8×** while stakes run to
  $100B — the BANK multiplier (now literal) is flat across all of Act 3, and
  the tier badge reads "T8" at Ultra [audit 1253-1261, 6032]. USER: extend
  the table or bless the plateau.
- **EV readouts ignore the 2×-stack pot cap** — jackpot cells can overstate
  5× exactly when the player is deciding whether to keep a drained table
  [audit 4114-4129]. **Cap order contradicts its own comment** (cap applied
  before multipliers; comment claims a hard ceiling) [audit 4131-4143].
  **`payout_double_chance` doubles losses too** with no copy saying so
  [audit 4145-4156]. All three are decide-then-one-line items.
- `data/stake_themes.lua` styles 6 of 10 stakes; NL1M+ render in default
  chrome, inverting the file's stated purpose [audit 1244-1251].

## 6. GrindController / GrindView decomposition — LARGE (the audit's best map)

Don't improvise: the audit contains a complete, verified plan.

- Concern dissection of the 633-line `update` [audit 1664-1826]; new-file
  plan with seams and line ranges [audit 1847-1897]; **safest extraction
  order** [audit 1899-1928]: ChipEmitter → TableFx → grind/Layout → TopBar →
  ShovePanel → `models/bounties.lua` (collapses the 3 copy-pasted bounty
  blocks D1 [audit 2197-2208]) → `models/payout.lua` (the money rules,
  concerns H-K) → `models/run_counters.lua` → Commerce/Lifecycle → sidebars.
- While in there, the duplication list D2-D9 [audit 2210-2286]: chip-emit
  bodies ×3, tier-FX ×2, upgrade cost ladder ×2 (button price vs charge can
  drift), 4-of-5 top-bar button pairs → data list, `moneyText` dup with
  RoomState → `utils/format` [audit 2289-2298], RoomState top-bar height
  mismatch (button jumps between screens) [audit 2300-2309].
- Controller-owns-state fixes ride along: `self.ctx` aliases
  `GameState.effects_cache`; floater formatting/tier-ramp move view-side/data
  [audit 2331-2380].

## 7. TablePanel / chip-pile cluster — LARGE

- Band decomposition plan (PanelContext + 8 band files, kills the 12-param
  functions and the per-frame `Lookups.findById`-per-opponent) [audit
  2827-2921]. D/R toggle dup → data table [audit 2916-2920]. Move the 368
  lines of F3-only debug shapes to `views/debug/` [audit 3358-3360].
- Pile lifecycle fixes (independent, small): delete the `e.n_air > 0` guard so
  the TTL sweep always runs (wedged-invisible-chip bug B-1) [audit 2993-3008,
  3062-3065]; clear a table's piles + in-flight chips on table close, not
  just full reset (B-2/B-3, chips visibly fly to stale anchors) [audit
  3067-3074]; AnchorRegistry eviction (leaks forever, C3/B-4) [audit
  2009-2022, 3076]; RollingValue per-table id leak (B-5) [audit 3079].
- API traps: `options.fabricate` means two different things in ChipFlight
  (boolean vs amount — passing the wrong shape is an arithmetic error on a
  boolean) [audit 3109-3122]; tier-target default 8 vs 12 mismatch (D-6)
  [audit 2987]; `tierFromUnit` (bb) vs `tierFromAmount` (dollars) give the
  same $50 different tiers by path (B-8) [audit 3094-3105];
  `_paletteForAmount` byte-copied controller/view (D-1) [audit 2967].

## 8. Performance pass — MEDIUM (top-10 at [audit 4826-4837])

Root cause first: `views/Panel.lua:272` rebuilds the active tab every draw
with no memo [audit 2559-2568], and tooltips are built for unhovered rows.

1. `drawEvReadout`: stop rebuilding the EV breakdown per frame per table
   (~540 table allocs/frame; compute on hover or cache per ctx-generation)
   [audit 3176-3206, 4704-4719].
2. 110 `OutcomeMath.buildOutcome` calls/frame for two tooltips (P1/P2):
   build lazily on hover [audit 2570-2606].
3. `FeltLayout.compute` cached per (felt_w, felt_h, n_opps, s) [audit 4721-4732].
4. RoomView: stop re-sorting `render_list` + rebuilding `owned_set` every
   frame [audit 4734-4760].
5. `clampText`/`IconText.walk` memoization (the TablePanel name-cache pattern
   is the template) [audit 4592-4644].
6. Collapse GrindController's 5 per-frame pool walks; skip work on quiet
   frames [audit 4768-4782]. `tiedUp()`/`ShoveRate.compute` once per tick,
   not 4×/2× per frame [audit 2622-2638].
7. Anchor tables mutated in place instead of reallocated (~100/frame)
   [audit 2640-2652]; floater lines pre-split at emit [audit 2654-2667].
8. Bigger lift, web payoff: pre-rendered chip textures + batch draw
   [audit 4697-4698, 4835].

## 9. Data-driven / theme cleanup — MEDIUM

- **Theme.catalog token group**: the catalog's second palette (38× ink
  literal, paper/stamp/purple tones) promoted to `data/theme.lua`; then the
  10 numeric `setColor` sites (4 CatalogModal, 5 RoomView, backdrop dim)
  [audit 1148-1170, 5198-5220]. Bronze/Silver/Gold deck border table ×3 →
  one token [audit 5051-5059]. Anti-chip purple literal that already has a
  token [audit 1170, 3277-3286]. TablePanelEffects literal colors + unscaled
  px constants [audit 3288-3294].
- **Loud registries**: burst kind-chain in GrindView → handler table +
  assert [audit 1042-1055]; `SoundService.playNamed` unknown-name loud under
  debug (16 of 26 names only reachable via computed strings) [audit
  1110-1119]; COUNTER_KINDS typo = silently dead unlock, assert fields exist
  [audit 1100-1108]; boot assert that every dist table has exactly the
  pot_tiers keys [audit 1263].
- **Authored flags over id checks**: `box_of_mice` in GrindView →
  `owns_global_cursor_controls` field [audit 1057-1062]; balance.lua's three
  functions → a service, exemptions as authored fields [audit 974-993];
  catalog load-time derivation → loader [audit 996-1006 + 6062-6077].
- **Magic-number batch** to data: `R1_DISPLAY_CAP`, `SAFETY_BB` (should be a
  gtype field), settling 0.4, decay rates, `PALETTE_MAX_CHIPS`,
  `WC_ABSOLUTE_CAP` [audit 1196-1237].

## 10. Services liftability + module-state — MEDIUM

The audit's ordered list [audit 1478-1490]: move `views/Theme.lua` →
`services/` (fixes all three services→views requires); rename
PokerEventRegistry → EventKindRegistry; parameterize CursorPool's claimable
actions and relocate the swarm (it's gameplay state invisible to saves —
reload silently respawns cursors) [audit 924-942, 1298-1332]; HandAnalytics →
`models/RunAnalytics` [audit 1334-1360]; DenominationBreakdown takes the tier
ladder as a parameter (5/18/80 hardcoded) [audit 1370-1391]; standardize DI
construction and audit `clear()`-on-reset for the 14 module-state services
[audit 1435-1466]. FloatingTextSystem stops holding live Table references
(owner-key + clearOwner) [audit 895-910]. Decide EventBus + Camera: both are
constructed and 100% unused — delete or adopt [audit 4962, 5590-5601]. New
`utils/mathx` (clamp/lerp/round; 21 inline clamps) and `utils/geometry`
(pointInRect ×4 helpers + 54 inline) [audit 5098-5135].

## 11. Dead code purge — LOW, mechanical (safe batch delete)

- Functions with zero callers [audit 4957-4985]: `changeTableStake` +
  `TablePool:changeStake` + `stake_up_flourish` + the stale STAKE-UP header
  doc [audit 2453-2464]; `ShaderRegistry.loadFromSource`;
  `SoundService.stopAll`/`getKinds`; `RNG.weightedPick`/`intInRange`;
  `BandStack.threeUp`; `Decal.unit`; `HoverService.clearNamespace`;
  `Chips.stackFootprint`; `ChipFlight.fly`/`explodeAmount`; `ChipPile.value`;
  `Panel:getActiveTab`; `Theme.cycle`; `Modal:boxRect`; TablePanelStats
  file-level `iconRow` + `binomCoeff`; `ShoveRate._formatMoney`;
  `Format.percent` (or better: adopt it at the 24 inline `%%` sites
  [audit 5061-5075]).
- `views/widgets/Dropdown.lua` (277 lines, still unreferenced).
- Post-gut dead: `buildLegacyMttLines` in TablePanelStats + its dispatch
  branch (carries the unguarded `stats.stake` deref too [audit 7234-7248]);
  the legacy pot-detonation block in TablePanel if still present
  [audit 3010, 3333].
- Dead data: 5 of 8 animation presets, `card_snap`, `hands_per_min_add`,
  `rep_decay_slow`, `tier_burst_cap`, felt_layout `pot_gap`/`you_pad`
  [audit 4991-5004, 3026].
- json array-null note while in `lib/json.lua`: a `null` mid-array silently
  shortens it [audit 7272-7273].

## 12. Copy pass — LOW (single sweep with the corrected strings in hand)

The audit provides exact replacement strings for every hit [audit 6638-7085]:
em-dashes in live strings (GrindView gtype blurbs :324-328 survived the gut,
plus :807/:919/:992/:1068, TablePanel :297, TablePanelStats :385,
AnalyticsConsentModal :13); filler ("a fresh" :918, "just" copy_machine,
"this hand" TablePanel :296, run_upgrades :93 grammar); the SHOVE tooltip's
literal-"chips" plain-text row duplicating the `{chip}` glyph row (drop the
prose clause) [audit 6787-6810, 7034-7059]; DemoEndModal's "Thanks for
playing!" tone flag applies to the new demo copy too [audit 7063-7080].
Stack%/banking wording verified clean, no changes [audit 6983-6999].

## 13. Testing + process — MEDIUM

- **In-repo tests**: zero exist. The audit ships a ready, verified
  `tests/test_first.lua` (19 assertions: HandEval wheel/straight-flush/
  bestFiveOfN, ShoveRate, SaveService round-trip) at [audit 6264-6632] —
  drop it in, update the version-mismatch case to the new tolerant read, and
  fold in the scratchpad suites (demo_flow, save_guard, frame_home) so they
  live in the repo instead of a session temp dir.
- **luacheck pre-commit**: the undefined-global class produced the two worst
  shipped bugs; the crash sweep proved the check catches all of them
  [audit 7134-7147, 383-388].
- **RNG**: nothing ever seeds (`sim/` can't replay; `save_id` uses unseeded
  `math.random` → same-second collisions); `sampleDist` iterates `pairs` so
  even a seed wouldn't replay. Seed at boot, iterate TIER_KEYS, route bare
  `math.random` through `love.math`/utils.rng [audit 3997-4062, 7353-7363].
- Housekeeping: `.kilo/` still not in `.gitignore` [audit 259-266];
  `.gitattributes` to stop the CRLF warning noise [audit 6122]; a
  `sim/README.md` (one command + "pacing, not hands") [audit 6179];
  boot log of resolved flags [audit 3845-3848].

## 14. MVC structure — MEDIUM, opportunistic (fix when touching the file)

- `GameState:reload(save_service)` — one home for the wipe/load/applySaved/
  fullReset/switch dance now hand-rolled in SettingsModal + InputController F6
  [audit 400-425, 5273-5293]. `GameState:beginRun` for the run-reset triad
  copy-pasted into 4 files [audit 811-823]. `GameState:recordGauntletResult`
  for the act flags set in ShoveState (now tangled with the demo gate)
  [audit 825-838]. `GameState:debugUnlockAll` + move the owned_items sanitize
  into applySaved [audit 679-685].
- DeckSelectModal's `setActiveDeck` gets a controller seam like
  `buyCatalogItem` [audit 5295-5307]. The DI closures GrindState installs →
  real container registration [audit 687-710, 5603-5618]. CatalogModal's
  fallback purchase path (second, side-effect-free buy path) dies with it.
- Smaller: `HintController.active` unpersisted (sticky hint re-fires after
  reload) [audit 604-614]; view writes `tbl.x/y` + models carrying pixels
  [audit 442-455, 515-529]; `view_event_cursor` advanced only by draw
  (culled tables queue events unboundedly) [audit 472-481]; models call
  `love.math.random` directly instead of utils/rng [audit 539-546];
  DeckSelectModal ctor granting unlocks [audit 427-440]; GrindView's
  upgrade-preview simulation → `previewRunUpgrade` on the controller
  [audit 714-735, 2388-2406]; state-name queries in views [audit 880-888];
  StateMachine: assert on unknown state, note the switch-inside-update
  "safe by last statement" hazard [audit 5642-5671].
