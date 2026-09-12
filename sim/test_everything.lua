-- sim/test_everything.lua
--
-- One good test per thing: every live catalog item, every run upgrade at
-- every level, every deck level and capstone, every proc and router, run
-- headlessly against the game's own modules (sim/harness.lua). Three
-- layers:
--   1. the rollup: each thing's effects land on the ctx where
--      data/effects.lua says they do (generated from the data)
--   2. behaviour: the engine does what the copy says (hand-written cases,
--      grouped by mechanic; each names the keys it vouches for)
--   3. smoke: everything owned at once, two minutes of play, no error
-- Then a coverage walk: any key with no case fails the run.
--
-- Every check is written to docs/sim-audit.md the moment it runs.
--
--   lua sim/test_everything.lua [--only <key-prefix>] [--seed n]
--   exit 1 on any failure or uncovered key

io.stdout:setvbuf("no")
package.path = package.path .. ";./?.lua"
local H = require("sim.harness")
local E, A = H.expect, H.audit

local only, seed = nil, 12345
do
    local i = 1
    while arg and arg[i] do
        if arg[i] == "--only" then only = arg[i + 1]; i = i + 2
        elseif arg[i] == "--seed" then seed = tonumber(arg[i + 1]) or seed; i = i + 2
        else i = i + 1 end
    end
end
H.seed(seed)
H.run_id = os.time()
A.load()
A.section("item",    "Catalog items")
A.section("upgrade", "Run upgrades")
A.section("deck",    "Decks")
A.section("proc",    "Procs")
A.section("router",  "Routers")
A.section("smoke",   "Smoke")

local function wanted(key) return (not only) or key:sub(1, #only) == only end
local COVERED = {}
local function covers(key) COVERED[key] = true end

-- check(key, label, pass, text): the one call a case makes per fact.
local function check(key, label, pass, text)
    covers(key)
    A.check(key, label, pass, text)
    E.ok(pass, key .. " / " .. label .. ": " .. text)
    A.flush()
end

local Catalog, RunUpgrades, DeckSpecs = H.Catalog, H.RunUpgrades, H.DeckSpecs
local Kinds = H.EffectKinds

local function liveItems()
    local out = {}
    for _, it in ipairs(Catalog) do
        if not it.hidden and not it.retired then out[#out + 1] = it end
    end
    return out
end

-- ═══════════════════════════════════════════════════════════════════════
-- Layer 1: the rollup
-- ═══════════════════════════════════════════════════════════════════════

-- The ctx field(s) a kind writes, from data/effects.lua's `affects`
-- (a scoped kind may name two: the global field and the per-gtype map).
local function fieldsOf(kind)
    local doc = Kinds[kind]
    local aff = doc and doc.affects or ""
    local out = {}
    for f in aff:gmatch("ctx%.([%w_]+)") do out[#out + 1] = f end
    return out, aff
end
local function fieldOf(kind) return fieldsOf(kind)[1] end

-- Kinds that only write under a board condition: the transient the
-- rollup needs to see them land.
local KIND_TRANSIENT = {
    pure_board_bonus = { active_tables_count = 2, board_pure_gtype = "zoom" },
    pure_board_pace  = { active_tables_count = 2, board_pure_gtype = "zoom" },
}
local function transientFor(effects)
    for _, e in ipairs(effects or {}) do
        if KIND_TRANSIENT[e.kind] then return KIND_TRANSIENT[e.kind] end
    end
    return nil
end

local function describeValue(v)
    if type(v) == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return ("table(%d)"):format(n)
    end
    return tostring(v)
end

local function sameValue(a, b)
    if type(a) == "table" and type(b) == "table" then
        return describeValue(a) == describeValue(b)
    end
    return a == b
end

local baseline = H.ctxOf({})

-- Every effect entry of `effects` landed on `ctx` (differs from the empty
-- rollup at the field the doc names). Returns pass, text.
local function effectsLanded(effects, ctx, applications)
    local notes, pass = {}, true
    for _, e in ipairs(effects or {}) do
        local kind = e.kind
        if not H.effects:has(kind) then
            pass = false; notes[#notes + 1] = kind .. " is not a registered kind"
        elseif not Kinds[kind] then
            pass = false; notes[#notes + 1] = kind .. " is not in data/effects.lua"
        else
            local fields = fieldsOf(kind)
            if #fields == 0 then
                pass = false; notes[#notes + 1] = kind .. ": affects names no ctx field"
            else
                local field, got, base
                for _, f in ipairs(fields) do
                    if ctx[f] ~= nil and not sameValue(ctx[f], baseline[f]) then field = f break end
                end
                field = field or fields[1]
                got, base = ctx[field], baseline[field]
                local landed = (got ~= nil) and not sameValue(got, base)
                if not landed then
                    pass = false
                    notes[#notes + 1] = ("%s: ctx.%s unchanged (%s)"):format(kind, field, describeValue(got))
                else
                    local extra = ""
                    if type(got) == "number" and type(e.value) == "number" and (applications or 1) > 1 then
                        extra = (" = %s after %d applications"):format(tostring(got), applications)
                    end
                    notes[#notes + 1] = ("%s -> ctx.%s = %s%s"):format(kind, field, describeValue(got), extra)
                end
            end
        end
    end
    return pass, table.concat(notes, "; ")
end

-- Items.
for _, it in ipairs(liveItems()) do
    local key = "item:" .. it.id
    if wanted(key) then
        local ctx = H.ctxOf({ items = { it.id }, transient = transientFor(it.effects) })
        local pass, text = effectsLanded(it.effects, ctx, 1)
        check(key, "copy", true, (it.effect_text or ""):gsub("\n", " "))
        check(key, "rollup", pass, text)
    end
end

-- Run upgrades, every level.
for _, up in ipairs(RunUpgrades) do
    local max = up.max_level or 1
    for L = 1, max do
        local key = ("upgrade:%s:%d"):format(up.id, L)
        if wanted(key) then
            local ctx = H.ctxOf({ upgrades = { [up.id] = L } })
            local pass, text = effectsLanded(up.effects, ctx, L)
            -- an integer-scaled kind must read exactly L x value
            for _, e in ipairs(up.effects or {}) do
                local doc = Kinds[e.kind]
                local field = fieldOf(e.kind)
                if doc and doc.scale == "integer" and field and type(e.value) == "number" then
                    local got = ctx[field]
                    if got ~= e.value * L then
                        pass = false
                        text = text .. ("; %s at L%d should be %s, is %s"):format(e.kind, L, tostring(e.value * L), tostring(got))
                    end
                end
            end
            check(key, "rollup", pass, ("level %d of %d: %s"):format(L, max, text))
        end
    end
end

-- Decks: levels 1..4 apply the per-level block, 5 adds the capstone.
for _, d in ipairs(DeckSpecs) do
    for L = 1, 5 do
        local key = ("deck:%s:%d"):format(d.id, L)
        if wanted(key) then
            local ctx = H.ctxOf({ decks = { [d.id] = L }, transient = transientFor(d.effects) })
            local pass, text = effectsLanded(d.effects, ctx, math.min(L, 4))
            if #(d.effects or {}) == 0 then pass, text = true, "no per-level effects (router or capstone-only deck)" end
            check(key, "rollup", pass, text)
        end
    end
    local ckey = ("deck:%s:capstone"):format(d.id)
    if wanted(ckey) and d.capstone then
        local at5 = H.ctxOf({ decks = { [d.id] = 5 }, transient = transientFor(d.capstone.effects) })
        local at4 = H.ctxOf({ decks = { [d.id] = 4 }, transient = transientFor(d.capstone.effects) })
        local pass5, text5 = effectsLanded(d.capstone.effects, at5, 1)
        local pass4 = true
        for _, e in ipairs(d.capstone.effects or {}) do
            local field = fieldOf(e.kind)
            if field and at4[field] ~= nil and not sameValue(at4[field], baseline[field]) then
                -- the capstone's kind may also be a per-level kind; only flag when the level block does not use it
                local shared = false
                for _, le in ipairs(d.effects or {}) do if le.kind == e.kind then shared = true end end
                if not shared then pass4 = false end
            end
        end
        check(ckey, "copy", true, (d.capstone.text or ""):gsub("\n", " "))
        check(ckey, "rollup", pass5 and pass4, text5 .. (pass4 and "; absent at level 4" or "; PRESENT AT LEVEL 4"))
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- Layer 2: behaviour, one group per file in sim/cases/
-- ═══════════════════════════════════════════════════════════════════════
local OutcomeMath = require("models.outcome_math")

-- The toolbox every case file gets.
local T = { H = H, E = E, check = check, wanted = wanted, covers = covers,
            world = H.world, ctxOf = H.ctxOf, OutcomeMath = OutcomeMath }

T.liveItems = liveItems

-- Replace tbl[name] with fn until the returned function is called.
function T.stub(tbl, name, fn)
    local old = tbl[name]
    tbl[name] = fn
    return function() tbl[name] = old end
end

-- Run fn with proc `id`'s chance forced to 1 (the def is restored after).
function T.forceChance(id, fn)
    local def = H.Procs[id]
    local old = def and def.chance
    if def then def.chance = nil end
    local ok, err = pcall(fn)
    if def then def.chance = old end
    if not ok then error(err, 0) end
end

-- Play one hand on `t` to the end. opts.won / opts.tier force the outcome
-- (through sampleOutcome), opts.bb fixes the pot's magnitude in blinds
-- (through rollTierMagnitude), opts.cursor deals it as a cursor would.
-- Returns the resolved hand { won, delta, tier } and the seconds it took.
function T.playHand(w, t, opts)
    opts = opts or {}
    local restores = {}
    if opts.won ~= nil then
        restores[#restores + 1] = T.stub(OutcomeMath, "sampleOutcome", function()
            return opts.won, opts.tier or (opts.won and "medium" or "medium")
        end)
    end
    if opts.bb then
        restores[#restores + 1] = T.stub(OutcomeMath, "rollTierMagnitude", function() return opts.bb end)
    end
    local idx = w:find(t)
    local before = t.hands_played
    if opts.cursor then w.ctrl._deal_by_cursor = true end
    local ok = w.ctrl:dealHand(idx)
    w.ctrl._deal_by_cursor = nil
    for _, r in ipairs(restores) do r() end   -- the outcome is sampled at deal
    if not ok then return nil, 0, "deal refused" end
    local t0 = H.clock
    local guard = 0
    while t.hands_played == before and guard < 4000 do w:tick(0.05); guard = guard + 1 end
    local r = t.last_results[#t.last_results]
    return r, H.clock - t0
end

-- Tick until table `t` has finished `n` more hands (punch auto-deals).
function T.untilHands(w, t, n, max_s)
    local target = t.hands_played + n
    local t0 = H.clock
    while t.hands_played < target and H.clock - t0 < (max_s or 120) do w:tick(0.05) end
    return t.hands_played >= target
end

local CASE_FILES = { "procs", "odds", "board", "rolls", "hands", "cursors", "money", "gates", "smoke", "board_rate" }
for _, name in ipairs(CASE_FILES) do
    local path = "sim/cases/" .. name .. ".lua"
    local f = io.open(path, "r")
    if f then
        f:close()
        local chunk = assert(loadfile(path))
        local ok, fn = pcall(chunk)            -- the file returns function(T)
        if ok and type(fn) == "function" then ok, fn = pcall(fn, T) end
        if not ok then
            E.ok(false, ("case file %s threw: %s"):format(name, tostring(fn)))
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- Coverage
-- ═══════════════════════════════════════════════════════════════════════
local expected = {}
for _, it in ipairs(liveItems()) do expected[#expected + 1] = "item:" .. it.id end
for _, up in ipairs(RunUpgrades) do
    for L = 1, (up.max_level or 1) do expected[#expected + 1] = ("upgrade:%s:%d"):format(up.id, L) end
end
for _, d in ipairs(DeckSpecs) do
    for L = 1, 5 do expected[#expected + 1] = ("deck:%s:%d"):format(d.id, L) end
    if d.capstone then expected[#expected + 1] = ("deck:%s:capstone"):format(d.id) end
end
local proc_ids, router_ids = {}, {}
for id in pairs(H.Procs) do proc_ids[#proc_ids + 1] = id end
for id in pairs(H.Routers) do router_ids[#router_ids + 1] = id end
table.sort(proc_ids); table.sort(router_ids)
for _, id in ipairs(proc_ids) do expected[#expected + 1] = "proc:" .. id end
for _, id in ipairs(router_ids) do expected[#expected + 1] = "router:" .. id end

local uncovered = {}
if not only then
    for _, k in ipairs(expected) do
        local e = A.entries[k]
        if not (e and e.run == H.run_id) then uncovered[#uncovered + 1] = k end
    end
    A.uncovered(uncovered)
end
A.dirty = true
A.flush()

print(("\n%d checks passed, %d failed, %d uncovered keys"):format(E.passes, #E.failures, #uncovered))
if #E.failures > 0 or #uncovered > 0 then os.exit(1) end
