-- sim/check_sound_names.lua
--
-- Every sound name the code plays resolves to something, and every sound
-- file placed is reachable. SoundService.playNamed fails SILENTLY on a name
-- with no preset and no file, so a typo or a file left under the wrong name
-- is a sound that never plays and nothing says so.
--
-- Checks:
--   - each literal name passed to playNamed / _playNamed in the code has a
--     preset in data/sounds.lua or a file the loader would find (full path
--     under assets/audio, or a unique basename; `raw` folders skipped, as
--     services/SoundLoader does)
--   - each preset's file (or files) exists on disk
--   - each file in assets/audio/ui, felt, layers is named by a preset, a
--     literal call, or is a bed services/MusicLayers plays
--   - each `sound` name in data/clicks.lua (the click materials) resolves
--     the same way, and counts as played
--   - each items/<id>.ogg is a catalog id (services/ItemFoley plays by id)
--
-- Standalone: `lua sim/check_sound_names.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local fails, checks = 0, 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then fails = fails + 1; print("FAIL " .. msg) end
end

local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

-- Every file under a directory, forward slashes, relative to the repo.
local function listFiles(dir)
    local out = {}
    local win = package.config:sub(1, 1) == "\\"
    local cmd = win and ('dir /s /b /a-d "' .. dir:gsub("/", "\\") .. '" 2>nul')
                     or ('find "' .. dir .. '" -type f 2>/dev/null')
    local p = io.popen(cmd)
    if not p then return out end
    local cwd = (io.popen(win and "cd" or "pwd"):read("*l") or ""):gsub("\\", "/")
    for line in p:lines() do
        line = line:gsub("\\", "/")
        if line:sub(1, #cwd) == cwd then line = line:sub(#cwd + 2) end
        out[#out + 1] = line
    end
    p:close()
    return out
end

-- The loader's view of assets/audio: name (path without extension, under
-- assets/audio) -> true, and basename -> name or false when ambiguous.
local EXTS = { mp3 = true, ogg = true, wav = true, flac = true }
local names, bases, files_on_disk = {}, {}, {}
for _, f in ipairs(listFiles("assets/audio")) do
    local rel = f:match("^assets/audio/(.+)$")
    local ext = rel and rel:match("%.(%w+)$")
    if rel and ext and EXTS[ext:lower()] and not ("/" .. rel):find("/raw/", 1, true) then
        files_on_disk[f] = true
        local name = rel:gsub("%.%w+$", "")
        names[name] = true
        local base = name:match("([^/]+)$")
        if bases[base] == nil then bases[base] = name
        elseif bases[base] ~= name then bases[base] = false end
    end
end
local function loaderHas(name)
    if names[name] then return true end
    local b = name:match("([^/]+)$")
    return b ~= nil and bases[b] and true or false
end

-- Presets.
local Stub = require("sim.love_stub"); Stub.base()
local Sounds = require("data.sounds")
local preset_files = {}
for name, entry in pairs(Sounds) do
    if name ~= "_mix" and type(entry) == "table" then
        local list = entry.files or (entry.file and { entry.file }) or {}
        for _, p in ipairs(list) do
            check(readFile(p) ~= nil, ("preset %s: file %s exists"):format(name, p))
            preset_files[p] = true
        end
        if entry.layer then
            for _, p in ipairs(entry.layer.files or (entry.layer.file and { entry.layer.file }) or {}) do
                check(readFile(p) ~= nil, ("preset %s layer: file %s exists"):format(name, p))
                preset_files[p] = true
            end
        end
    end
end

-- Literal names played in the code.
local called = {}
for _, f in ipairs(listFiles(".")) do
    if f:match("%.lua$") and not f:match("^sim/") and not f:match("^%.") and not f:match("/%.")
       and not f:match("^tools/") and not f:match("^lib/") then
        -- Comments dropped first: a doc example is not a call.
        local src = (readFile(f) or ""):gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
        for name in src:gmatch('[_%.:]playNamed%(%s*"([^"]+)"') do
            called[name] = called[name] or f
        end
    end
end
local n_called = 0
for name, where in pairs(called) do
    n_called = n_called + 1
    check(Sounds[name] ~= nil or loaderHas(name),
          ("'%s' (played in %s) has a preset or a file"):format(name, where))
end

-- Surface sounds: services/ClickFX plays each click material's `sound` by
-- name from data/clicks.lua, not by a literal playNamed call.
local Clicks = require("data.clicks")
local function walkSounds(t, path, seen)
    seen = seen or {}
    if seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        if k == "sound" and type(v) == "string" then
            check(Sounds[v] ~= nil or loaderHas(v),
                  ("'%s' (data/clicks.lua %s) has a preset or a file"):format(v, path))
            if not called[v] then n_called = n_called + 1 end
            called[v] = called[v] or "data/clicks.lua"
        elseif type(v) == "table" then
            walkSounds(v, path .. "." .. tostring(k), seen)
        end
    end
end
walkSounds(Clicks, "clicks")

-- Placed files are reachable.
local beds = { ["assets/audio/layers/hiss.ogg"] = true, ["assets/audio/layers/gauntlet_drone.ogg"] = true }
for f in pairs(files_on_disk) do
    local dir = f:match("^assets/audio/([^/]+)/")
    if dir == "ui" or dir == "felt" or dir == "layers" then
        local base = f:match("([^/]+)%.%w+$")
        check(preset_files[f] or called[base] or beds[f],
              ("%s is played by a preset, a call or MusicLayers"):format(f))
    end
end
local catalog = readFile("data/catalog.lua") or ""
local ids = {}
for id in catalog:gmatch('%f[%w_]id%s*=%s*"([a-z0-9_]+)"') do ids[id] = true end
for f in pairs(files_on_disk) do
    local id = f:match("^assets/audio/items/([^/]+)%.ogg$")
    if id then check(ids[id], ("items/%s.ogg is a catalog id"):format(id)) end
end

print(("check_sound_names: %d names played, %d checks, %d failures"):format(n_called, checks, fails))
if fails > 0 then os.exit(1) end
