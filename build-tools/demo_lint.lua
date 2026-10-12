-- build-tools/demo_lint.lua
--
-- What is left after the demo cut (demo_cut.py), checked as data against
-- the STAGED tree, then booted headless. Fails the build on anything the
-- demo would trip over or ship wrong:
--
--   flags      C.DEMO is true on the stage; STEAM_URL set (else a warning:
--              no WISHLIST sticker)
--   catalog    no Act 2 or Act 3 entry; every requires chain resolves;
--              every proc an item names exists; the Prize Vase is gone
--   stakes     s001-s003 only; game types zoom and hu only; decks: the
--              starter only
--   story      no cut beat; no line names a cut table ({t:6m}, {t:ko}); no
--              trigger names a cut game type; every anchor is a name a
--              staged view registers
--   glossary   every row's beat exists; catalog pages: every item exists,
--              no empty department
--   room       every placed catalog id is staged; every home's target is
--              placed; every Act 1 item with art has a place in the room
--              (the designer's export) — a failure, or a warning with
--              --allow-unplaced
--   lights     every emitter is a staged item or a placed entry
--   sprites    every alias names a staged item or a placed entry; every
--              alias target and every item sprite has a file (warnings:
--              the loader is silent on missing art)
--   sounds     every file data/sounds.lua names exists on the stage
--   modules    no cut module is required at the top of a file
--   boot       the staged game runs headless: a table opens, 200 hands
--              play, every screen builds and draws two frames
--
-- Run from the repo root: lua build-tools/demo_lint.lua build/stage [--allow-unplaced]

local stage = arg[1]
if not stage then
    io.stderr:write("usage: lua build-tools/demo_lint.lua <stage-dir> [--allow-unplaced]\n")
    os.exit(2)
end
local allow_unplaced = false
for i = 2, #arg do if arg[i] == "--allow-unplaced" then allow_unplaced = true end end
stage = stage:gsub("[/\\]+$", "")

-- The staged game first, the repo's sim/ (the stub, the harness) after.
package.path = stage .. "/?.lua;" .. "./?.lua;" .. package.path

local fails, warns = 0, 0
local function fail(msg) fails = fails + 1; print("  FAIL " .. msg) end
local function warn(msg) warns = warns + 1; print("  warn " .. msg) end
local function ok(cond, msg) if not cond then fail(msg) end return cond end

local function exists(rel)
    local f = io.open(stage .. "/" .. rel, "rb")
    if f then f:close(); return true end
    return false
end
local function readfile(rel)
    local f = io.open(stage .. "/" .. rel, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function listdir(rel)
    local out = {}
    local p = io.popen('dir /b "' .. (stage .. "/" .. rel):gsub("/", "\\") .. '" 2>nul')
    if p then
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    return out
end
local function luaFiles(rel)
    local out = {}
    for _, f in ipairs(listdir(rel)) do
        if f:match("%.lua$") then out[#out + 1] = rel .. "/" .. f end
    end
    return out
end
local function set(list) local s = {}; for _, v in ipairs(list) do s[v] = true end; return s end

local Stub = require("sim.love_stub"); Stub.base()
local Constants = require("data.constants")

-- ── flags ────────────────────────────────────────────────────────────
print("flags")
ok(Constants.DEMO == true, "C.DEMO is true on the stage")
ok(Constants.FEATURES.DEMO_CUT == true and Constants.FEATURES.DECKS == false
   and Constants.FEATURES.DEV_HOTKEYS == false, "the demo's feature flags follow C.DEMO")
if not (Constants.STEAM_URL and Constants.STEAM_URL ~= "") then
    warn("STEAM_URL is empty: no WISHLIST sticker on the title or the flyer")
end

-- ── catalog ──────────────────────────────────────────────────────────
print("catalog")
local Catalog = require("data.catalog")
local Procs   = require("data.procs")
local CatalogLoader = require("models.catalog_loader")
local by_id = {}
for _, it in ipairs(Catalog) do by_id[it.id] = it end
for _, it in ipairs(Catalog) do
    ok(it.act ~= 2, it.id .. ": act = 2 survived the cut")
    ok(not it.requires_act3, it.id .. ": requires_act3 survived the cut")
    if it.requires then ok(by_id[it.requires] ~= nil, it.id .. ": requires " .. tostring(it.requires) .. ", which is gone") end
    for _, e in ipairs(it.effects or {}) do
        if e.kind == "proc" then ok(Procs[e.proc] ~= nil, it.id .. ": proc " .. tostring(e.proc) .. " is gone") end
    end
    for _, e in ipairs((it.corrupt and it.corrupt.effects) or {}) do
        if e.kind == "proc" then ok(Procs[e.proc] ~= nil, it.id .. ": corrupt proc " .. tostring(e.proc) .. " is gone") end
    end
end
ok(by_id.prize_vase == nil, "the Prize Vase is gone")

-- ── stakes, game types, decks ────────────────────────────────────────
print("stakes, game types, decks")
local Stakes    = require("data.stakes")
local GameTypes = require("data.game_types")
local Decks     = require("data.decks")
local keep_stakes = { s001 = true, s002 = true, s003 = true }
for _, s in ipairs(Stakes) do ok(keep_stakes[s.id], "stake " .. tostring(s.id) .. " survived the cut") end
ok(#Stakes == 3, "three stakes (" .. #Stakes .. ")")
local gt_ids = {}
for _, g in ipairs(GameTypes) do gt_ids[g.id] = true end
ok(gt_ids.zoom and gt_ids.hu and not gt_ids.ko and not gt_ids.six_max and #GameTypes == 2,
   "the game types are zoom and hu")
ok(#Decks == 1 and Decks[1].id == "standard", "the starter is the only deck")

-- ── story ────────────────────────────────────────────────────────────
print("story")
local Story = require("data.story")
local cut_beats = set({ "six_max_open", "first_tournament", "act2", "act2_decks", "the_top_table", "underflow" })
local src = {}
for _, dir in ipairs({ "views", "states", "controllers" }) do
    for _, f in ipairs(luaFiles(dir)) do src[#src + 1] = readfile(f) or "" end
end
local all_src = table.concat(src, "\n")
local FAMILIES = { "ev:", "stack_pct:", "stack:", "table:", "add_table:", "add_table_chip:", "add_table_ev:",
                   "gtype:", "buy_runup_", "info:", "shove:cheat_", "catalog:", "deck:", "cell:", "chip_badge:",
                   "room:", "btn:", "rebuy:" }
local function registered(name)
    if all_src:find('"' .. name .. '"', 1, true) then return true end
    for _, fam in ipairs(FAMILIES) do
        if name:sub(1, #fam) == fam and all_src:find('"' .. fam, 1, true) then return true end
    end
    return false
end
local beat_ids = {}
local function triggerGtypes(t, out)
    if type(t) ~= "table" then return end
    if t.gtype then out[#out + 1] = t.gtype end
    for _, v in ipairs(t) do triggerGtypes(v, out) end
end
for _, beat in ipairs(Story.beats) do
    beat_ids[beat.id] = true
    ok(not cut_beats[beat.id], "beat " .. beat.id .. " survived the cut")
    local gts = {}
    triggerGtypes(beat.trigger, gts)
    for _, g in ipairs(gts) do ok(gt_ids[g], "beat " .. beat.id .. " triggers on game type " .. g) end
    for i, line in ipairs(beat.lines or {}) do
        local text = tostring(line.text or "")
        ok(not (text:find("{t:6m}", 1, true) or text:find("{t:ko}", 1, true)),
           beat.id .. "#" .. i .. " names a cut table")
        local anchors = line.anchor
        if type(anchors) == "string" then anchors = { anchors } end
        for _, a in ipairs(anchors or {}) do
            ok(registered(a), beat.id .. "#" .. i .. ": anchor " .. a .. " is registered by no staged view")
        end
    end
end

-- ── glossary, catalog pages ──────────────────────────────────────────
print("glossary, catalog pages")
local Glossary = require("data.glossary")
for _, row in ipairs(Glossary) do
    ok(beat_ids[row.beat], "glossary " .. tostring(row.id) .. ": beat " .. tostring(row.beat) .. " is gone")
end
local Pages = require("data.catalog_pages")
for _, d in ipairs(Pages) do
    ok(#(d.items or {}) > 0, "department " .. tostring(d.id) .. " is empty")
    for _, iid in ipairs(d.items or {}) do
        ok(by_id[iid] ~= nil, "department " .. tostring(d.id) .. " lists " .. tostring(iid) .. ", which is gone")
    end
end

-- ── room ─────────────────────────────────────────────────────────────
print("room")
local Layout = require("data.room_layout")
local Lights = require("data.room_lights")
local placed = {}
for id, info in pairs(Layout) do
    if id ~= "__meta" then
        placed[id] = true
        if type(info) == "table" and info.sprite then placed[info.sprite] = true end
    end
end
for id, info in pairs(Layout) do
    if id ~= "__meta" and type(info) == "table" then
        for _, h in ipairs(info.homes or {}) do
            ok(h.on == nil or placed[h.on], "room: " .. id .. " homes on " .. tostring(h.on) .. ", which is not placed")
        end
    end
end
local unplaced = {}
for _, it in ipairs(Catalog) do
    if CatalogLoader.isOwnable(it) and not it.retired and not it.hidden then
        local base = it.sprite or it.id
        if not (placed[it.id] or placed[base]) then unplaced[#unplaced + 1] = it.id end
    end
end
table.sort(unplaced)
if #unplaced > 0 then
    local msg = #unplaced .. " item(s) have no place in the room (the editor's EXPORT writes data/room_layout.lua): "
                .. table.concat(unplaced, ", ")
    if allow_unplaced then warn(msg) else fail(msg) end
end
for id in pairs(Lights.emitters or {}) do
    ok(by_id[id] ~= nil or placed[id], "lights: emitter " .. id .. " is neither an item nor placed")
end

-- ── sprites ──────────────────────────────────────────────────────────
print("sprites")
local json = require("lib.json")
local aliases = {}
do
    local raw = readfile("assets/sprites/aliases.json")
    local okd, parsed = pcall(json.decode, raw or "{}")
    if okd and type(parsed) == "table" and parsed.aliases then aliases = parsed.aliases end
end
local function spriteFile(name)
    return exists("assets/sprites/" .. name .. ".png")
end
for k, target in pairs(aliases) do
    if not (by_id[k] or placed[k]) then warn("alias " .. k .. " names neither an item nor a placed entry") end
    if not spriteFile(target) then warn("alias " .. k .. " -> " .. target .. ": no file") end
end
for _, it in ipairs(Catalog) do
    if not it.hidden and not it.retired then
        local name = it.sprite or it.id
        if not (aliases[name] and spriteFile(aliases[name])) and not spriteFile(name) then
            warn("item " .. it.id .. ": no sprite file for " .. name)
        end
    end
end

-- ── sounds ───────────────────────────────────────────────────────────
print("sounds")
local Sounds = require("data.sounds")
local function soundFiles(entry, out)
    if type(entry) ~= "table" then return end
    if entry.file then out[#out + 1] = entry.file end
    for _, f in ipairs(entry.files or {}) do out[#out + 1] = f end
    if entry.layer then soundFiles(entry.layer, out) end
end
local n_sounds = 0
for name, entry in pairs(Sounds) do
    if name ~= "_mix" then
        local files = {}
        soundFiles(entry, files)
        for _, f in ipairs(files) do
            n_sounds = n_sounds + 1
            ok(exists(f), "sound " .. name .. ": " .. f .. " is not on the stage")
        end
    end
end
print(("  %d sound files checked"):format(n_sounds))

-- ── modules ──────────────────────────────────────────────────────────
print("modules")
local cut_modules = { "views.RoomLayersPanel", "views.ShoveDebugOverlay", "services.Profiler",
                      "controllers.InputController", "states.CreditsState" }
for _, m in ipairs(cut_modules) do
    ok(not exists(m:gsub("%.", "/") .. ".lua"), m .. " is still on the stage")
end
for _, dir in ipairs({ "views", "states", "controllers", "services", "models" }) do
    for _, f in ipairs(luaFiles(dir)) do
        local s = readfile(f) or ""
        for _, m in ipairs(cut_modules) do
            if s:find('^local [%w_]+%s*=%s*require%("' .. m:gsub("%.", "%%.") .. '"%)')
               or s:find('\nlocal [%w_]+%s*=%s*require%("' .. m:gsub("%.", "%%.") .. '"%)') then
                fail(f .. " requires " .. m .. " at the top of the file")
            end
        end
    end
end
if exists("main.lua") then
    local s = readfile("main.lua")
    for _, m in ipairs(cut_modules) do
        if s:find('\nlocal [%w_]+%s*=%s*require%("' .. m:gsub("%.", "%%.") .. '"%)') then
            fail("main.lua requires " .. m .. " at the top of the file")
        end
    end
end

-- ── boot ─────────────────────────────────────────────────────────────
print("boot")
do
    local H = require("sim.harness")      -- sets DEMO_CUT false for its own use
    Constants.FEATURES.DEMO_CUT    = true
    Constants.FEATURES.DECKS       = false
    Constants.FEATURES.DEV_HOTKEYS = false
    Constants.FEATURES.ANALYTICS   = false
    local booted, err = pcall(function()
        local w = H.world({ act2 = false, gates = false, bankroll = 1000 })
        local ctrl = w.ctrl
        local opened = ctrl:addTable("s001", "zoom")
        assert(opened ~= false and ctrl.pool:count() >= 1, "no table opened at s001 zoom")
        local hands = 0
        for _ = 1, 4000 do
            for i = 1, ctrl.pool:count() do
                local t = ctrl.pool:get(i)
                if t and not t:isBusy() and (t.stack or 0) > 0 then
                    ctrl:dealHand(i); hands = hands + 1
                elseif t and (t.stack or 0) <= 0 then
                    ctrl:rebuyTable(i)
                end
            end
            w:tick(0.5, 0.5)
            if hands >= 200 then break end
        end
        assert(hands >= 200, "only " .. hands .. " hands played")
        -- Every screen builds and draws two frames (the stub records nothing;
        -- a nil index one frame in is what this catches).
        local F = Stub.font(16)
        local g = w.game
        g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
        g.state_machine = { states = {}, switch = function() end, current = function() return "grind" end }
        local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
                      getDimensions = function() return 32, 32 end, setFilter = function() end, release = function() end }
        g.sprite_loader = { getSprite = function() return img end, getSpriteFor = function() return img end,
                            hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
                            setSprite = function() end, itemArt = function() return img end }
        Stub.recorder()
        love.graphics.newFont = function() return F end
        love.graphics.getFont = function() return F end
        love.timer.getDelta = love.timer.getDelta or function() return 1 / 60 end
        local NAMES = { grind = "GrindState", shove = "ShoveState", title = "TitleState", room = "RoomState" }
        local built = {}
        for key, name in pairs(NAMES) do
            built[key] = require("states." .. name):new(g)
            g.state_machine.states[key] = built[key]
        end
        for key, inst in pairs(built) do
            g.state_machine.current = function() return key end
            inst:draw(); inst:draw()
        end
        return hands
    end)
    ok(booted, "the staged game boots and plays: " .. tostring(err))
    if booted then print(("  %d hands played, four screens drawn"):format(err)) end
end

print(("demo_lint: %d failure(s), %d warning(s)"):format(fails, warns))
os.exit(fails > 0 and 1 or 0)
