-- services/SaveService.lua
--
-- Dual-slot persistence:
--   meta.save  — persistent slot. Survives a run reset.
--   run.save   — per-run slot. Wiped by clearRun().
--
-- The two slots are saved separately so a run reset is just `delete run.save`
-- without touching meta. The save format is JSON; AutoSerializer handles the
-- per-model serialization, this service handles the file layer.
--
-- Save schema (per slot):
--   {
--     version   = number,
--     timestamp = number (os.time),
--     data      = <table from model:serialize() / AutoSerializer.serialize>,
--   }

local SaveService = {}

local Constants = require("data.constants")
local json      = require("lib.json")

local VERSION = Constants.SAVE.VERSION

-- JSON decode produces string keys for all object fields; Lua sometimes wants
-- integer-keyed tables. Walks decoded data and coerces integer-ish string keys
-- back to numbers. Lifted from CC's SaveService.
local function coerceIntKeys(t, seen)
    if type(t) ~= "table" then return end
    seen = seen or {}
    if seen[t] then return end
    seen[t] = true
    local renames = {}
    for k, v in pairs(t) do
        if type(k) == "string" and k:match("^%-?%d+$") then
            renames[k] = tonumber(k)
        end
        coerceIntKeys(v, seen)
    end
    for strk, numk in pairs(renames) do
        t[numk] = t[strk]
        t[strk] = nil
    end
end

function SaveService:new()
    return setmetatable({}, { __index = self })
end

-- Read a save slot. Returns the `data` field (model payload) or nil.
function SaveService:read(filename)
    if not love.filesystem.getInfo(filename) then
        return nil, "no save"
    end
    local raw, err = love.filesystem.read(filename)
    if not raw then return nil, err end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "decode failed"
    end
    if type(decoded.data) ~= "table" then
        return nil, "no data"
    end
    if decoded.version ~= VERSION then
        -- Version drift no longer refuses the save: returning nil here
        -- read as "fresh game" to every caller, which made the first
        -- VERSION bump a silent wipe of every existing player. All real
        -- migrations are field-level in GameState:applySaved; the file's
        -- version rides along for any future one that needs to branch.
        print(string.format("SaveService: %s is v%s (current v%s), applying with field-level migration",
            filename, tostring(decoded.version), tostring(VERSION)))
    end
    coerceIntKeys(decoded.data)
    return decoded.data, decoded.version
end

-- Write a save slot. `payload` is the model-serialized table.
function SaveService:write(filename, payload)
    local wrapper = {
        version   = VERSION,
        timestamp = os.time(),
        data      = payload,
    }
    local encoded = json.encode(wrapper, true)
    local ok, err = love.filesystem.write(filename, encoded)
    if not ok then
        print("SaveService: write failed for " .. filename .. ": " .. tostring(err))
        return false, err
    end
    return true
end

-- Convenience: load both slots. Returns { meta = ..., run = ... } where each
-- field is the payload table or nil. Callers handle nil = fresh game.
function SaveService:loadAll()
    return {
        meta = self:read(Constants.SAVE.META_FILE),
        run  = self:read(Constants.SAVE.RUN_FILE),
    }
end

-- Convenience: write both slots from an in-memory pair.
function SaveService:saveAll(meta_payload, run_payload)
    if meta_payload then self:write(Constants.SAVE.META_FILE, meta_payload) end
    if run_payload  then self:write(Constants.SAVE.RUN_FILE,  run_payload)  end
end

-- Wipe the run slot. Called by game-side reset paths.
function SaveService:clearRun()
    if love.filesystem.getInfo(Constants.SAVE.RUN_FILE) then
        love.filesystem.remove(Constants.SAVE.RUN_FILE)
    end
end

-- Wipe both slots. Used by the credits-screen reset and the F7 debug hotkey.
function SaveService:clearAll()
    self:clearRun()
    if love.filesystem.getInfo(Constants.SAVE.META_FILE) then
        love.filesystem.remove(Constants.SAVE.META_FILE)
    end
end

-- Settings slot — separate from meta/run since user preferences (volume,
-- resolution, display mode) survive a "delete save" wipe and aren't
-- versioned with the run schema. Returns the payload table or nil.
function SaveService:loadSettings()
    return self:read(Constants.SAVE.SETTINGS_FILE)
end

function SaveService:saveSettings(payload)
    if payload then self:write(Constants.SAVE.SETTINGS_FILE, payload) end
end

return SaveService
