> **Legacy (moved 2026-08-25). Line numbers are stale.** Second-opinion code audit from 2026-08-19 against the same tree as `audit-aug2026-full.md`; same caveat. Findings are a punch list, not a description of the current code.

The verdict in one paragraph
The four rule-greps come back mostly clean — no Game. leaks outside main.lua, no poker vocabulary in core/lib/utils, no commented-out code graveyards, near-zero TODO debt. The real problems are: god files in the view/controller layer (GrindView 2244 lines, GrindController 1683, TablePanel 1584), Rule 3 broken in data/catalog.lua (a 1030-line data file that requires modules, loops, and rewrites itself at load), Table_legacy's outcome pipeline has silently drifted from outcome_math beyond the intentional duality, and GameState hand-rolls four field census lists that any forgotten field turns into a silent save bug.

Rule violations, by rule
Rule 1 — DI only / no globals / no service locators

core/event_bus.lua:10-13 — exported as a mutable module table (EventBus = { subscribers = {} }), but main.lua also puts the same table on g.event_bus. Two access paths to one global bus — the exact fake-DI thing.
services/SoundService, FlightSystem, CursorPool, Tooltip, FloatingTextSystem, Ghosts are all module-level mutable singletons requiring each other directly (FlightSystem.lua:21 requires SoundService internally). Six services are proper DI instances; these aren't. The two idioms coexist and nothing enforces which one a new service should pick.
main.lua:139-151, 395-402 — require("views.Chips").setScale(...) and configureFromFonts across 7 view modules configures views as module singletons. main.lua's own comment at 170-176 argues against this pattern, then does it.
Rule 2 — MVC separation

models/ is genuinely clean — zero love.graphics calls, zero view imports. Best layer in the codebase.
services/ harbors render code: CursorPool draws polygons (line 153-184), Tooltip, FloatingTextSystem, Ghosts, FlightSystem all have draw() issuing love.graphics calls. The services layer is being used as a second view layer.
views/SettingsModal.lua:113-128 — _performLoad calls state:wipeAll(), state:applySaved, walks state_machine.states, switches state. A view doing teardown orchestration.
views/DeckSelectModal.lua:110 — calls state:setActiveDeck() directly from consumeMouse; CatalogModal routes purchases through GrindController, this one doesn't.
views/TablePanelStats.lua:1019-1021 — mutates the Theme table itself mid-frame (Theme.tier.loss.jackpot = {...} then restores it) to force a glyph color. Order-dependent, pollutes shared palette, breaks Theme's read-only contract.
views/TablePanel.lua:1312-1313 — draw loop writes tbl.x = x; tbl.y = y onto the model from the render side.
states/RoomState.lua — renders top-bar/bankroll/PLAY button directly, keypressed mutates state.owned_items/state.cleared (lines 148-156). Worst MVC offender in states/.
states/ShoveState.lua:100-115, 151-206 — state file mutates pool.tables, state.bankroll, writes shove_r1_won/cleared, calls resetRun(). Controller-level work living in a state file.
Rule 3 — data-driven / no kind-chains / no literal colors

data/catalog.lua:85, 998-1027 — the worst single violation in the repo. A data file requiring data.constants and data.balance, looping over items at load, rewriting cost_chip, walking effects lists, injecting/overwriting shove_rate_add values, and table.remove-ing items under a feature flag. The if eff.kind == "shove_rate_add" at 1015 is real. Business logic embedded in a data file, squarely against the rule.
data/balance.lua:38-64 — the three Balance.getItemCost/getItemShoveRate/getChipsPerRun functions. Verified: pure arithmetic, no cross-layer deps. The exception is justified; the problem isn't balance.lua having the functions, it's catalog.lua calling them to mutate itself.
data/sounds.lua:14-27 — requires utils.sample_set and calls expand(...) to build lists at load. Logic in data.
views/CatalogModal.lua — 13+ hardcoded literal colors (554, 561, 568-574, 809-812, 833-856, 1114). The comment at 807 says "the widget holds no literal colors" — false, they're inlined two lines later. The "black ink" 0.15,0.15,0.12 appears 4+ times; belongs in theme tokens.
views/RoomView.lua:410-645 — setColor(1,1,1,alpha) hand-rolled instead of Theme.assetTint() (only SpriteRenderer uses the sanctioned helper).
Duplicate Bronze/Silver/Gold border literal table in three places: GrindView.lua:1227-1229, DeckSelectModal.lua:194-197, DeckSelectModal.lua:385-387.
views/Chips.lua:38 — love.graphics.newFont outside Theme. Rule says only Theme hosts newFont.
services/DenominationBreakdown.lua:38-54 — if/elseif tier ladder (if magnitude < 5 return "small"...) hardcodes tier names and thresholds in a service; new tier = edit code, not data.
views/GrindView.lua:2317-2371 — _handleSidebarButton is a id:match("^add_table:") string-prefix parse chain. The kind-chain anti-pattern restated on button ids.
Rule 4 — engine-agnostic infra

services/HandAnalytics.lua — saturated: @@POKERIDLE_ANALYTICS@@ marker, shove_count, gauntlet_result, bankroll, chips_earned. Poker through and through; should be a generic RunAnalytics or move to models/.
services/CursorPool.lua:70-81 — hardcodes poker actions (hb.action == "deal", cursor_rebuy_unlocked) in the input-targeting layer.
Minor comment leaks in Tumble ("chip/pot/felt"), Pop ("bankroll tier"), RollingValue, SoundService, SpriteLoader.
God files — the part you asked about
views/GrindView.lua (2244) — 8-9 cohesive views fused into one file. It owns: the top-bar stat bar (10+ tweened cells), the top-bar 5-button strip, the left sidebar (game-type strip + add-table buttons), the right sidebar (upgrade list + per-stake fill-grid tooltips), THE HOUSE poster + help, SHOVE button + quick-reset, the center table grid with layout-freeze, the bottom bankroll chip pile, floating-text overlay, tooltip hit-testing for 9 districts, and mouse routing for ~10 regions. Natural extraction seams:

views/TopBar.lua — lines 1114-1636 (stat cells + button strip, the 5 near-identical _drawXButton functions become one data-driven list)
views/SidebarLeft.lua — 310-579 (game-type strip + add-table)
views/SidebarRight.lua — 581-868 (upgrades tab + range tooltip)
views/ShovePanel.lua — 1776-2000 (SHOVE + House + face)
views/TableGrid.lua — 1653-1772 + part of draw
Mouse routing (2177-2371) shrinks accordingly once regions live on their components.
controllers/GrindController.lua (1683) — the update method alone is 178-810, 632 lines, six unrelated concerns: sound triggers, deferred buy-in bursts, MTT payout drain + bounty, focus-mult/earnings-capstone/stack-overflow, floater label formatting, resolution chip bursts, chip bounty/copy-machine/anti-chip, deck XP bookkeeping, pool resync. Beyond update, the file owns 9 more concerns: chip-flight queueing, focus/capacity policy, bounty policy, upgrade commerce, table lifecycle, cursor-mute policy, chip-flight palette/anchor composition, audio dispatch, state transitions. Seams:

controllers/BountyController.lua — 832-877 + 596-698
controllers/CommerceController.lua — 879-1146 (upgrades + catalog)
controllers/TableLifecycle.lua — 1155-1409 (add/remove/cashout/rebuy/deal)
controllers/ChipEmitter.lua — 1422-1679 (palette/anchor/emit)
Resolution loop splitting out MTT-payout + floater-label blocks.
views/TablePanel.lua (1584) — TablePanel.draw at 1282-1710 is a ~430-line orchestrator. Plus drawOpponentSeat 171 lines, drawHeader 155, drawPotLabel 155, three ladder variants. Extract views/TablePanelHeader.lua, views/TablePanelSeats.lua.

views/RoomView.lua (1265) — RoomView:draw at 357-917 is a 560-line god function: floor/wall loops, item render+sort, editor preview, sidebar chrome, instructions, buttons, selector rows, item browser with scrollbar and truncation cache. Plus mousepressed 248 lines, new 150. Extract views/RoomRenderer and views/RoomEditor.

views/CatalogModal.lua (1158) — drawItemCard at 466-893 is a ~427-line god renderer. Plus the 13+ literal colors.

models/GameState.lua (747) — 5 jobs: ~60-field state container, save lifecycle, effects rollup, commerce, run-start seeding. The persistence risk: resetRun, wipeAll, serializeMeta, serializeRun each hand-enumerate ~25 fields, applySaved hand-backfills ~30 more. Forget a field in one of the four lists = silent persistence/prestige bug. Evidence it's already biting: wipeAll calls resetRun() then has to re-fix shove_count at line 304 because resetRun just bumped it. The file's own header says "adding a field = adding the field" — the code doesn't deliver that.

models/Table.lua (949) — three state machines glued together: cash per-hand machine, MTT chip-stack lifecycle (246-325, 893-964), and FX decay state (shake/vignette/glow — view-impulse state living on a model). They're coupled through self._last_ctx, a field that's never declared in :new, written in deal() and update(), read in _finalizeHand and _endTournament — exists solely to avoid threading ctx, would silently wedge a tournament if a third deal trigger ever appears.

Legacy drift beyond the intentional duality
The dual Table/Table_legacy setup is known and fine. But the audit verified the mirror and found it incomplete:

Step 7 (jackpot_emerge ramp): confirmed fixed — Table_legacy.lua:297-307 matches outcome_math.lua:293-303 exactly.
Steps 1-2 diverge: legacy's sumFills ignores descriptor tier_min/tier_max, fill_window_widen, and fill_cascade. Net: Tier Manipulator / High Roller do nothing in prototype builds, silently.
sampleOutcome diverges: legacy never applies deck-capstone win_tier_floor/loss_tier_ceiling (Nit capstone, Standard capstone no-op).
deal diverges: legacy never applies tier_bump_chance / payout_double_chance (Maniac capstone no-ops).
EV readouts diverge: legacy's debugStats/estimateStats (979-1042) re-derive EV with their own math and can report numbers a real hand can't produce.
The durable fix is the one in your memory: delete legacy's 200-line buildOutcome copy and require outcome_math. Hand-mirroring keeps failing.
Bugs found
views/TablePanelStats.lua:383 — references undefined locals ev_sign and ev_color inside buildLegacyMttLines. Crashes the moment the legacy-MTT tooltip renders. Real crash bug.
services/FloatingTextSystem.lua:108 — getTexts() returns the live internal list; callers can mutate service state.
models/GameState + TablePool — 13 index-parallel arrays on GameState (seat_stacks, bust_order, player_seat...). Index skew class of bugs; one per-table record fixes it.
Dead code: urand in both HandScript files, unused require("utils.rng") in both Table files, dead slam_t field in both Table files, dead DEBUG_TIP constants in TablePanelStats, no-op update in RoomState.
Stale numbers: balance.lua:30 comment says "25 * 0.70 = 17.5" but ACT1_ITEM_COUNT = 49; catalog bands tally to 48 items, not 49 — off-by-one between authored data and balance constant.
Priority order
TableStats:383 crash bug — fix first, it's live.
Table_legacy outcome pipeline — perks silently no-op in prototype builds (F1/F2/F4/F5 above). Delete the duplicate, call outcome_math.
data/catalog.lua logic-at-load — worst rule-3 violation; move derivation to a boot-time transform.
GameState serialization census — four hand-rolled field lists; the shove_count double-fix shows it's already drifting. This is the highest-risk design smell in the repo.
GrindView split — 2244 lines, but the seams are clean and the file is well-organized internally; it's big, not tangled. Do it when the size actively hurts.
GrindController update split; TableStats Theme mutation; singleton services idiom cleanup; CatalogModal color tokenization.
The codebase is in decent shape overall — the rules are enforced in most places and the violations are concentrated, not diffuse. The drift risk is almost entirely in the legacy-mirror and the GameState census, both of which are "correct until someone forgets" mechanisms.