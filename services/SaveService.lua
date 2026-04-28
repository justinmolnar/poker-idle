-- services/SaveService.lua
--
-- Dual-slot persistence:
--   meta.save  — PP, owned catalog items. Persists FOREVER (across prestige).
--   run.save   — bankroll, current stake, run upgrades. Wiped on prestige.
--
-- The two slots are saved separately so a prestige is just `delete run.save`
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
    if decoded.version ~= VERSION then
        return nil, "version mismatch"
    end
    coerceIntKeys(decoded.data)
    return decoded.data
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

-- Wipe the run slot. Called on prestige (after the gauntlet loss).
function SaveService:clearRun()
    if love.filesystem.getInfo(Constants.SAVE.RUN_FILE) then
        love.filesystem.remove(Constants.SAVE.RUN_FILE)
    end
end

return SaveService
