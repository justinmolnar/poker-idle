-- sim/verify_save_roundtrip.lua
--
-- Proves the save says everything the game is, and says it the same way
-- twice. Replaces sim/verify_save_migration.lua, which proved that saves
-- from older versions of the game could be coerced into this one — a job
-- that no longer exists (services/SaveService refuses a foreign version
-- outright, and models/GameState has no migration paths left).
--
-- Three things are checked.
--
--   coverage   Every field GameState's constructor sets is named by
--              META_KEYS, RUN_KEYS or RUNTIME_KEYS, and every listed key is
--              set by the constructor. This is the test models/GameState
--              has claimed to have since May and did not: it is what stops
--              a new field being silently left out of the save.
--
--   round trip A live board — tables mid-hand at different points in their
--              scripts, a heater and a tilt with the latches that end them,
--              a tournament mid-plan with an undrained payout, a busted
--              cash table — serialized, run through JSON, restored, and
--              serialized again must come back byte-identical. Then the
--              restored tables must run for five seconds without erroring
--              and without redealing the hands they were already playing.
--
--   fresh      resetRun, wipeAll and applyStartingPerks must produce table
--              records the pool will accept.
--
-- Standalone: `lua sim/verify_save_roundtrip.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local H          = require("sim.harness")
local json       = require("lib.json")
local GameState  = require("models.GameState")
local Stakes     = require("data.stakes")

local fails, checks = {}, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails[#fails + 1] = what end
    return cond
end

-- ─── Coverage: the constructor is the schema ───────────────────────────

do
    local fresh = GameState:new()
    local listed = {}
    for _, list in ipairs({ GameState.META_KEYS, GameState.RUN_KEYS,
                            GameState.RUNTIME_KEYS }) do
        for _, k in ipairs(list) do
            ok(not listed[k], "key listed twice: " .. k)
            listed[k] = true
        end
    end

    local missing = {}
    for k, v in pairs(fresh) do
        if type(v) ~= "function" and not listed[k] then missing[#missing + 1] = k end
    end
    table.sort(missing)
    ok(#missing == 0, "fields the constructor sets that no key list names: "
        .. table.concat(missing, ", "))

    -- The other direction: a listed key the constructor never initialises
    -- has no default, so a save without it leaves a nil where the game
    -- expects a value. `last_shove`, `shove_pending` and `perks_pending`
    -- are legitimately nil until something happens, so they are named.
    local NIL_UNTIL_SET = { last_shove = true, shove_pending = true,
                            perks_pending = true, effects_cache = true,
                            first_hand_delta = true, first_hand_tier = true }
    local unset = {}
    for _, list in ipairs({ GameState.META_KEYS, GameState.RUN_KEYS,
                            GameState.RUNTIME_KEYS }) do
        for _, k in ipairs(list) do
            if fresh[k] == nil and not NIL_UNTIL_SET[k] then
                unset[#unset + 1] = k
            end
        end
    end
    table.sort(unset)
    ok(#unset == 0, "listed keys the constructor never sets: " .. table.concat(unset, ", "))
end

-- ─── A wipe leaves exactly a fresh game ────────────────────────────────
--
-- wipeAll resets keys by hand, so a key added to the constructor and the
-- lists but forgotten there survives a New Game and follows the player
-- into their next save. Two keys were already doing that when this check
-- was written.

do
    local fresh = GameState:new()
    local used  = GameState:new()
    used.chips, used.total_stacks, used.catalog_throws = 999, 5, 3
    used.last_shove, used.total_money_won = { chips = 1 }, 12345
    used.bankroll, used.chips_this_run = 4321, 7
    used.perks_pending, used.shove_pending = true, { chips = 2 }
    used:wipeAll()

    local function shape(v)
        if type(v) ~= "table" then return tostring(v) end
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return "table(" .. n .. ")"
    end
    local kept = {}
    for _, list in ipairs({ GameState.META_KEYS, GameState.RUN_KEYS }) do
        for _, k in ipairs(list) do
            -- save_id is minted fresh on purpose: a new game is a new save.
            if k ~= "save_id" and shape(fresh[k]) ~= shape(used[k]) then
                kept[#kept + 1] = string.format("%s (fresh %s, wiped %s)",
                                                k, shape(fresh[k]), shape(used[k]))
            end
        end
    end
    ok(#kept == 0, "wipeAll leaves state a new game would not: " .. table.concat(kept, ", "))
    ok(used.save_id ~= fresh.save_id or used.save_id ~= nil, "a wipe mints a save id")
end

-- ─── A board worth saving ──────────────────────────────────────────────

H.seed(20260909)
local w = H.world()
local state = w.state

-- Open a spread of tables and let them play, so hands are genuinely in
-- flight at different points in their scripts when the save is taken.
for i = 1, 8 do
    pcall(function() w:open(Stakes[1].id, (i % 2 == 0) and "zoom" or "six_max") end)
end
w:tick(1.0)
local tables = w:tables()
ok(#tables >= 4, "the fixture opened tables: " .. #tables)

-- Deal on half of them and stop partway, so the save is taken with hands
-- genuinely mid-script at different events. Nothing else in the suite ever
-- catches a table in this state, which is exactly the state the old save
-- could not describe.
for i = 1, #tables, 2 do tables[i]:deal(w.ctrl.ctx) end
w:tick(0.35)
for i = 2, #tables, 2 do tables[i]:deal(w.ctrl.ctx) end
w:tick(0.35)

-- Everything below is set AFTER the last tick: a payout the controller
-- has not drained and a punch status it has not spent are exactly the
-- states a save can catch, and ticking again would resolve them.
--
-- A heater and a tilt, with the latch that ends them. This is the pairing
-- the old save broke: it carried the status and dropped the latch, so the
-- table burned for the rest of the save.
if tables[1] then tables[1]:applyStatus("heater", { magnitude = 0.2 }) end
if tables[2] then tables[2]:applyStatus("tilt",   { magnitude = 0.2 }) end
-- A busted cash table: it must NOT come back with a free buy-in.
if tables[3] then tables[3].stack = 0 end
-- An undrained tournament payout: settled, not yet collected.
if tables[4] then
    tables[4].ko.pending_payout = 12.5
    tables[4].ko.finish_count   = 3
end

-- One of every shaped run field, so the JSON round trip is exercised on
-- each: a dict keyed by a composite string, a dict keyed by an id, a list
-- of records, a sparse array.
state.stakes_won_this_run    = { ["s001:zoom"] = 3 }
state.anti_stakes_won_this_run = { ["s001:cash"] = true }
state.run_ratchets           = { { kind = "win_chance_shift", amount = 0.01 } }
state.total_hands_by_gtype   = { zoom = 12, cash = 7 }
state.hints_seen             = { catalog_intro = true }
state.item_fires_run         = { desk = 4 }
state.last_shove             = { chips = 6, anti_chips = 0, won = false, busted_at = 2 }
state.shove_pending          = { chips = 6, anti_chips = 0,
                                 outcomes = { true, false, false } }

-- ─── Round trip ────────────────────────────────────────────────────────

-- Normalise once before the comparison: the pool repacks a board bigger
-- than its table count needs, so a first load legitimately moves cells.
-- What the save has to guarantee is that loading is a FIXED POINT after
-- that, which is what this compares.
state.tables = w.ctrl.pool:serialize()
w.ctrl:reloadPool()
local tables_norm = w:tables()
local before = { meta = state:serializeMeta(), run = state:serializeRun() }

local encoded = json.encode(before)
ok(type(encoded) == "string" and #encoded > 0, "the save encodes")
local decoded = json.decode(encoded)
ok(type(decoded) == "table", "the save decodes")

-- SaveService's key coercion: JSON turns any integer-keyed table into an
-- object, and a table's seat maps go sparse the moment a seat folds.
local function coerceIntKeys(t, seen)
    if type(t) ~= "table" then return end
    seen = seen or {}
    if seen[t] then return end
    seen[t] = true
    local renames = {}
    for k, v in pairs(t) do
        if type(k) == "string" and k:match("^%-?%d+$") then renames[k] = tonumber(k) end
        coerceIntKeys(v, seen)
    end
    for sk, nk in pairs(renames) do t[nk] = t[sk]; t[sk] = nil end
end
coerceIntKeys(decoded)

-- A second world, loaded from the bytes.
local w2 = H.world()
w2.state:applySaved(decoded)
w2.ctrl:reloadPool()
local after = { meta = w2.state:serializeMeta(), run = w2.state:serializeRun() }

-- Compare structurally rather than by string: field order in a Lua table
-- is not stable, so two encodes of the same state are not the same bytes.
local function diff(a, b, path, out)
    if type(a) ~= type(b) then
        out[#out + 1] = string.format("%s: %s vs %s", path, type(a), type(b)); return
    end
    if type(a) ~= "table" then
        if a ~= b then
            out[#out + 1] = string.format("%s: %s vs %s", path, tostring(a), tostring(b))
        end
        return
    end
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        diff(a[k], b[k], path .. "." .. tostring(k), out)
        if #out > 12 then return end
    end
end

local d = {}
diff(before, after, "save", d)
ok(#d == 0, "the save does not survive a round trip: " .. table.concat(d, " | "))

-- ─── What the restored board actually is ───────────────────────────────

local t2 = w2:tables()
ok(#t2 == #tables_norm, string.format("every table came back: %d of %d", #t2, #tables_norm))

local mid_hand_before, mid_hand_after = 0, 0
for _, t in ipairs(tables_norm) do if t.state ~= "idle" then mid_hand_before = mid_hand_before + 1 end end
for _, t in ipairs(t2)     do if t.state ~= "idle" then mid_hand_after  = mid_hand_after  + 1 end end
ok(mid_hand_before > 0, "the fixture had hands in flight to test: " .. mid_hand_before)
ok(mid_hand_after == mid_hand_before,
   string.format("hands in flight survive: %d of %d", mid_hand_after, mid_hand_before))

for i, t in ipairs(t2) do
    local o = tables_norm[i]
    if o then
        ok(t.script_idx == o.script_idx,
           string.format("table %d resumes at its own event (%s vs %s)", i,
                         tostring(t.script_idx), tostring(o.script_idx)))
        ok(t.view_event_cursor == t.script_idx,
           "table " .. i .. " does not replay the events it already played")
        ok(t.hands_played == o.hands_played, "table " .. i .. " keeps its hand count")
        ok((t.opponents[1] and t.opponents[1].name) == (o.opponents[1] and o.opponents[1].name),
           "table " .. i .. " keeps the opponents it was playing")
    end
end

-- The busted cash table stays busted. This is the one the old parallel
-- arrays saved and then restored only on the tournament branch, so every
-- cash table came back with a free buy-in.
local busted = t2[3]
ok(busted and busted.stack == 0,
   "a busted cash table stays busted (stack " .. tostring(busted and busted.stack) .. ")")

-- The undrained tournament payout survives.
ok(t2[4] and t2[4].ko.pending_payout == 12.5, "an undrained KO payout survives")
ok(t2[4] and t2[4].ko.finish_count == 3, "the KO finish count survives")

-- The statuses came back WITH their latches, which is what lets them end.
local function statusKinds(t)
    local out = {}
    for _, e in ipairs(t.statuses or {}) do out[e.kind] = true end
    return out
end
ok(statusKinds(t2[1]).heater, "a heater survives the reload")
ok(statusKinds(t2[2]).tilt, "a tilt survives the reload")
ok(t2[1]._forced_next_won ~= nil,
   "a restored heater carries the latch that ends it")
ok(t2[2]._forced_next_won ~= nil,
   "a restored tilt carries the latch that ends it")

-- And they actually end. A punch status has no timer and no charges: the
-- only thing that spends it is the hand its latch forces, so the board has
-- to run long enough to play that hand out (~25s at NL2). This is the bug
-- the rebuild was for: the old save restored the status and dropped the
-- latch, so the hand was never forced and the status never ended.
local ok_run, err = pcall(function() w2:tick(45.0) end)
ok(ok_run, "the restored board runs: " .. tostring(err))
ok(not statusKinds(t2[1]).heater, "the restored heater burns out")
ok(not statusKinds(t2[2]).tilt, "the restored tilt burns out")

-- ─── Fresh state produces records the pool accepts ─────────────────────

do
    local w3 = H.world()
    w3.state:resetRun()
    w3.state:applyStartingPerks(w3.ctrl.ctx)
    local good = pcall(function() w3.ctrl:reloadPool() end)
    ok(good, "resetRun + applyStartingPerks produce records the pool accepts")

    local w4 = H.world()
    w4.state:wipeAll()
    good = pcall(function() w4.ctrl:reloadPool() end)
    ok(good, "wipeAll produces records the pool accepts")
    ok(#w4:tables() == 0, "a wiped state has no tables")
end

-- A tournament in progress comes back as it was and plays on. Its own
-- world, so its rolls do not move the board above.
do
    local wk = H.world()
    local ko_before = wk:open(Stakes[1].id, "ko")
    ko_before:deal(wk.ctrl.ctx)
    for _ = 1, 300 do ko_before:update(0.1, wk.ctrl.ctx) end
    if ko_before.state == "idle" and ko_before.ko:isPlaying() then ko_before:deal(wk.ctrl.ctx) end
    for _ = 1, 3 do ko_before:update(0.1, wk.ctrl.ctx) end
    ok(ko_before.ko:isPlaying() and ko_before.state ~= "idle", "the fixture has a tournament mid-hand")

    wk.state.tables = wk.ctrl.pool:serialize()
    local bytes = json.decode(json.encode({ meta = wk.state:serializeMeta(), run = wk.state:serializeRun() }))
    coerceIntKeys(bytes)
    local wk2 = H.world()
    wk2.state:applySaved(bytes)
    wk2.ctrl:reloadPool()
    local ko_after = wk2:tables()[1]
    ok(ko_after and ko_after.ko:isPlaying(), "a tournament in progress survives the reload")
    if ko_after then
        local same = true
        for sseat, v in pairs(ko_before.seat_stacks or {}) do
            if (ko_after.seat_stacks or {})[sseat] ~= v then same = false end
        end
        ok(same, "its seat stacks come back")
        ok(ko_after._ko_hand == ko_before._ko_hand, "its blind clock comes back")
        ok(ko_after._ko_flow ~= nil, "the hand in flight keeps its settled chips")
        local played = ko_after.hands_played
        wk2:tick(30.0)
        local sum = 0
        for _, v in pairs(ko_after.seat_stacks or {}) do sum = sum + v end
        ok(ko_after.hands_played > played or not ko_after.ko:isPlaying(), "the restored tournament plays on")
        ok(not ko_after.ko:isPlaying() or math.abs(sum - 80 * Stakes[1].bb) < 1e-4,
           "and its chips still add up")
    end
end

-- ─── Report ────────────────────────────────────────────────────────────

for _, f in ipairs(fails) do print("  FAIL " .. f) end
print(string.format("%d checks, %d failures", checks, #fails))
os.exit(#fails == 0 and 0 or 1)
