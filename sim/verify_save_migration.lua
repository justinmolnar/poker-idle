-- sim/verify_save_migration.lua
--
-- Loads an OLD-SHAPE save through GameState:applySaved and asserts every
-- renamed identifier came across. Expectations are derived from the
-- migration maps themselves (data/catalog_id_migrations.lua and
-- data/id_migrations.lua), so adding a rename to a map is enough for
-- this to cover it — and forgetting to add one is what this catches.
--
--   lua sim/verify_save_migration.lua        (exit 1 on any failure)
--
-- Standalone: no LÖVE. GameState's require graph is pure Lua.

io.stdout:setvbuf("no")
love = love or { math = { random = math.random }, timer = { getTime = os.clock } }
package.path = package.path .. ";./?.lua"

local GameState    = require("models.GameState")
local ItemMap      = require("data.catalog_id_migrations")
local IdMap        = require("data.id_migrations")
local Catalog      = require("data.catalog")
local GameTypes    = require("data.game_types")
local RunUpgrades  = require("data.run_upgrades")
local DeckSpecs    = require("data.decks")

local fails, checks = 0, 0
local function ok(cond, label)
    checks = checks + 1
    if cond then print("ok   " .. label) else print("FAIL " .. label); fails = fails + 1 end
end
local function liveIds(list) local s = {}; for _, e in ipairs(list) do s[e.id] = true end; return s end
local function has(list, id) for _, v in ipairs(list or {}) do if v == id then return true end end; return false end

-- ── fixture: an old-shape save ─────────────────────────────────────────
-- Legacy item ids from the map (first entry that is NOT live), plus the
-- two retired-then-reused ids that must survive untouched.
local item_live = liveIds(Catalog)
local legacy_item, legacy_target
for old, new in pairs(ItemMap) do
    if not item_live[old] and item_live[new] then legacy_item, legacy_target = old, new; break end
end
assert(legacy_item, "fixture needs at least one retired item id in catalog_id_migrations")

local meta = {
    save_id = "fixture", chips = 7, has_shoved = true, catalog_seen = true,
    owned_items     = { legacy_item, "whiteboard", "copy_machine", "corkboard" },
    corrupted_items = { legacy_item },
    peeled_items    = { legacy_item, "whiteboard" },
    unlocked_decks  = { "standard" },
    deck_levels     = { standard = 2 },
    deck_xp         = { standard = 55 },
    active_deck_id  = "standard",
    deck_overhaul_migrated = true,
    total_hands_by_gtype = { zoom = 10, hu = 5 },
    gtype_announced      = { zoom = true },
}
local run = {
    bankroll = 42,
    -- the s005 table is what the 2026-09-03 stake-break migration retags
    active_table_specs      = { "s001:zoom", "s002:hu", "s005:six_max" },
    active_table_stack      = { 2, 10, 9000 },
    stakes_won_this_run     = { ["s001:zoom"] = 1 },
    anti_stakes_won_this_run = {},
    run_upgrade_levels      = { sharper_reads = 3 },
    active_table_mtt_plans  = {},
}

-- Seed every namespace map's OLD ids into the fixture so each rename is
-- exercised the moment it's added to data/id_migrations.lua.
local FIELD_SENTINEL = 12345
local seeded = {}
for old in pairs(IdMap.field or {}) do
    -- keys the fixture already shapes (e.g. the plan list) keep their own value
    if meta[old] == nil and run[old] == nil then meta[old] = FIELD_SENTINEL; seeded[old] = true end
end
for old in pairs(IdMap.gtype or {}) do
    run.active_table_specs[#run.active_table_specs + 1] = "s003:" .. old
    run.stakes_won_this_run["s003:" .. old] = 2
    meta.total_hands_by_gtype[old] = 99
    meta.gtype_announced[old] = true
end
for old in pairs(IdMap.run_upgrade or {}) do run.run_upgrade_levels[old] = 4 end
for old in pairs(IdMap.deck or {}) do
    meta.unlocked_decks[#meta.unlocked_decks + 1] = old
    meta.deck_levels[old] = 3; meta.deck_xp[old] = 77
    meta.active_deck_id = old
end
for old in pairs(IdMap.tier or {}) do
    run.active_table_mtt_plans[#run.active_table_mtt_plans + 1] =
        { finish_position = 3, hands = { { won = true, tier = old }, { won = false, tier = "small" } } }
end

-- ── load ───────────────────────────────────────────────────────────────
local gs = GameState:new()
gs:applySaved({ meta = meta, run = run })

-- ── item ids ───────────────────────────────────────────────────────────
ok(has(gs.owned_items, legacy_target) and not has(gs.owned_items, legacy_item),
   ("owned: %s → %s"):format(legacy_item, legacy_target))
ok(has(gs.corrupted_items, legacy_target), "corrupted: legacy id remapped")
ok(has(gs.peeled_items, legacy_target) and not has(gs.peeled_items, legacy_item), "peeled: legacy id remapped")
ok(has(gs.owned_items, "whiteboard") and has(gs.owned_items, "copy_machine"),
   "live-again ids (whiteboard, copy_machine) survive the map")
ok(has(gs.peeled_items, "whiteboard"), "peeled: live-again id survives")
local dup = 0
for _, id in ipairs(gs.owned_items) do if id == "corkboard" then dup = dup + 1 end end
ok(dup == 1, "no duplicate corkboard created by the stale whiteboard line")

-- ── fields ─────────────────────────────────────────────────────────────
for old, new in pairs(IdMap.field or {}) do
    if seeded[old] then
        ok(gs[new] == FIELD_SENTINEL and gs[old] == nil, ("field %s → %s"):format(old, new))
    else
        ok(gs[new] ~= nil and gs[old] == nil, ("field %s → %s (fixture-shaped)"):format(old, new))
    end
end

-- ── gtype ──────────────────────────────────────────────────────────────
for old, new in pairs(IdMap.gtype or {}) do
    ok(has(gs.active_table_specs, "s003:" .. new) and not has(gs.active_table_specs, "s003:" .. old),
       ("spec s003:%s → s003:%s"):format(old, new))
    ok(gs.stakes_won_this_run["s003:" .. new] == 2 and gs.stakes_won_this_run["s003:" .. old] == nil,
       ("bounty key s003:%s → s003:%s"):format(old, new))
    ok(gs.total_hands_by_gtype[new] == 99 and gs.total_hands_by_gtype[old] == nil,
       ("total_hands_by_gtype %s → %s"):format(old, new))
    ok(gs.gtype_announced[new] == true and gs.gtype_announced[old] == nil,
       ("gtype_announced %s → %s"):format(old, new))
end
ok(has(gs.active_table_specs, "s001:zoom"), "untouched spec survives")

-- ── run upgrades ───────────────────────────────────────────────────────
for old, new in pairs(IdMap.run_upgrade or {}) do
    ok(gs.run_upgrade_levels[new] == 4 and gs.run_upgrade_levels[old] == nil,
       ("run_upgrade_levels %s → %s"):format(old, new))
end
ok(gs.run_upgrade_levels.sharper_reads == 3, "untouched run upgrade survives")

-- ── decks ──────────────────────────────────────────────────────────────
for old, new in pairs(IdMap.deck or {}) do
    ok(has(gs.unlocked_decks, new) and not has(gs.unlocked_decks, old), ("unlocked_decks %s → %s"):format(old, new))
    local curve
    for _, d in ipairs(DeckSpecs) do if d.id == new then curve = d.xp_curve end end
    ok(gs.deck_levels[new] == 3 and gs.deck_xp[new] == curve[3],
       ("deck progress carried for %s (level kept, xp snapped to the new curve)"):format(new))
    ok(gs.active_deck_id == new, ("active_deck_id %s → %s"):format(old, new))
end
ok(gs.deck_levels.standard == 2, "untouched deck progress survives")

-- ── 2026-09-03 stake break (one-shot) ──────────────────────────────────
ok(gs.stake_break_migrated == true, "stake break: flag set after migrating an old save")
ok(has(gs.active_table_specs, "retired_s005:six_max") and not has(gs.active_table_specs, "s005:six_max"),
   "stake break: open T4+ table retagged for TablePool's refund-and-drop path")
ok(has(gs.active_table_specs, "s001:zoom") and has(gs.active_table_specs, "s002:hu"),
   "stake break: Act 1 tables untouched")
ok(gs.deck_xp.standard == DeckSpecs[1].xp_curve[2], "stake break: standard L2 xp snapped to the new curve")
do  -- a save written by this build must NOT migrate again
    local gs2 = GameState:new()
    local meta2 = {}; for k, v in pairs(meta) do meta2[k] = v end
    meta2.stake_break_migrated = true
    meta2.deck_xp = { standard = 55 }
    local run2 = { bankroll = 1, active_table_specs = { "s005:six_max" } }
    gs2:applySaved({ meta = meta2, run = run2 })
    ok(has(gs2.active_table_specs, "s005:six_max") and gs2.deck_xp.standard == 55,
       "stake break: a flagged save is left alone")
end

-- ── tiers inside saved plans ───────────────────────────────────────────
for old, new in pairs(IdMap.tier or {}) do
    local plans = gs.active_table_ko_plans or gs.active_table_mtt_plans or {}
    local seen_new, seen_old = false, false
    for _, plan in ipairs(plans) do
        for _, h in ipairs(plan.hands or {}) do
            if h.tier == new then seen_new = true end
            if h.tier == old then seen_old = true end
        end
    end
    ok(seen_new and not seen_old, ("plan tier %s → %s"):format(old, new))
end

-- ── sanity: nothing in the maps is stale (old id still live) ───────────
for old in pairs(IdMap.gtype or {}) do ok(not liveIds(GameTypes)[old], "gtype map key not live: " .. old) end
for old in pairs(IdMap.run_upgrade or {}) do ok(not liveIds(RunUpgrades)[old], "run_upgrade map key not live: " .. old) end
for old in pairs(IdMap.deck or {}) do ok(not liveIds(DeckSpecs)[old], "deck map key not live: " .. old) end

print(("\n%d checks, %d failures"):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
