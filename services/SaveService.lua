-- services/SaveService.lua
--
-- Dual-slot persistence:
--   meta.save  — persistent slot. Survives a run reset.
--   run.save   — per-run slot. Wiped by clearRun().
--
-- The two slots are saved separately so a run reset is just `delete run.save`
-- without touching meta. The save format is JSON; GameState:serializeMeta /
-- :serializeRun build the payloads by hand (see models/GameState.lua), this
-- service handles the file layer.
--
-- Save schema (per slot):
--   {
--     version   = number,
--     timestamp = number (os.time),
--     data      = <table from GameState:serializeMeta()/serializeRun()>,
--   }
--
-- Write safety: every write stages to `<file>.tmp`, verifies the staged
-- bytes decode, then commits over the real file — a crash mid-write can
-- no longer truncate the only copy, and `read` recovers from a leftover
-- good tmp. If a slot EXISTS but cannot be read, `load_failed` latches
-- and further meta/run writes are refused so the unreadable file is never
-- overwritten by fresh-game state; starting a new game (clearAll) is the
-- explicit way out.

local SaveService = {}

local Constants = require("data.constants")
local json      = require("lib.json")

local VERSION = Constants.SAVE.VERSION

-- The two slots that carry progress. A failed write to either latches
-- load_failed; the settings file is not worth refusing a session over.
local function isProgressSlot(filename)
    return filename == Constants.SAVE.META_FILE
        or filename == Constants.SAVE.RUN_FILE
end

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

-- ─── The writer thread ─────────────────────────────────────────────────
-- The autosave fires every 10 s, and a full board's payload is sixteen
-- parallel arrays; encoding, writing, reading back and committing it all
-- sat on the frame. The encode stays here (it is cheap now the JSON is
-- compact) and the disk work moves to services/save_worker.
--
-- Desktop only. The web build has no threads, and the quit path always
-- writes inline so nothing can still be in flight when the process ends.
local _is_web = false
do
    local ok = pcall(require, "ffi")
    if not ok then _is_web = true end
end

local function threadsAvailable()
    return love.thread ~= nil and not _is_web
end

function SaveService:new()
    return setmetatable({ load_failed = false }, { __index = self })
end

-- Started on the first threaded save, not at boot: a session that never
-- saves never pays for it.
function SaveService:_worker()
    if not threadsAvailable() then return nil end
    if self._worker_thread then return self._worker_thread end
    local ok, thread = pcall(love.thread.newThread, "services/save_worker.lua")
    if not ok or not thread then return nil end
    self._jobs    = love.thread.getChannel("poker_save_jobs")
    self._results = love.thread.getChannel("poker_save_results")
    thread:start()
    self._worker_thread = thread
    return thread
end

-- Report anything the writer finished since the last look. Called once a
-- frame from love.update; a failure latches load_failed exactly as the
-- inline path does, so a bad disk stops the next save from overwriting.
function SaveService:drainResults()
    local ch = self._results
    if not ch then return end
    while true do
        local r = ch:pop()
        if not r then break end
        if not r.ok then
            print("SaveService: " .. tostring(r.filename) .. " — " .. tostring(r.err))
            if isProgressSlot(r.filename) then self.load_failed = true end
        end
    end
    local t = self._worker_thread
    if t then
        local err = t:getError()
        if err then
            print("SaveService: writer thread died (" .. tostring(err)
                  .. "); saves fall back to the main thread")
            self._worker_thread, self._jobs, self._results = nil, nil, nil
        end
    end
end

-- One raw read attempt against one filename. Returns (data, version) or
-- (nil, reason). Does not consult tmps and does not touch load_failed.
local function tryRead(filename)
    if not love.filesystem.getInfo(filename) then
        return nil, "no save"
    end
    local raw, err = love.filesystem.read(filename)
    if not raw then return nil, tostring(err or "read failed") end
    local decoded, derr = json.decode(raw)
    if type(decoded) ~= "table" then
        return nil, "decode failed: " .. tostring(derr)
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

-- Read a save slot. Returns the `data` field (model payload) or nil.
-- A leftover `<file>.tmp` (crash between stage and commit) is the newest
-- good copy and is recovered from; a slot that exists but cannot be read
-- latches `load_failed` so nothing overwrites it.
function SaveService:read(filename)
    local data, ver = tryRead(filename)
    if data then return data, ver end
    local reason = ver

    local tdata, tver = tryRead(filename .. ".tmp")
    if tdata then
        print("SaveService: recovered " .. filename .. " from its staged .tmp (" .. tostring(reason) .. ")")
        return tdata, tver
    end

    if reason ~= "no save" then
        -- The file is there and unreadable. Never let an autosave replace
        -- it with fresh-game state — the bytes may still be recoverable.
        self.load_failed = true
        print("SaveService: LOAD FAILED for " .. filename .. " (" .. tostring(reason)
            .. ") — saves suspended until a new game is started")
    end
    return nil, reason
end

-- ── Staged writes ───────────────────────────────────────────────────────

-- Encode + write + verify `<file>.tmp`. Returns true when the staged file
-- is confirmed readable. Never touches the real file.
function SaveService:_stage(filename, payload)
    -- Compact, not pretty-printed. A board of 36 tables writes sixteen
    -- parallel arrays; the indentation was roughly doubling the bytes to
    -- encode, write, read back and re-parse, for a file no human reads in
    -- place (the tools all work from the repo, not the save directory).
    local encoded = self:_encode(filename, payload)
    if not encoded then return false end
    local tmp = filename .. ".tmp"
    local ok, err = love.filesystem.write(tmp, encoded)
    if not ok then
        print("SaveService: stage write failed for " .. tmp .. ": " .. tostring(err))
        return false
    end
    -- Verify the bytes that actually landed, without paying for a second
    -- full parse of the save we just built. The failure this guards against
    -- is a SHORT write — a full disk, a killed process, Emscripten's IDBFS
    -- flushing badly — and that is exactly what a length-and-terminator
    -- check catches. A file that is the right length and ends in the
    -- closing brace is the string we encoded.
    local back = love.filesystem.read(tmp)
    if not back or #back ~= #encoded or back:sub(-1) ~= "}" then
        print("SaveService: staged " .. tmp .. " failed verification, keeping the old save")
        return false
    end
    return true
end

-- Commit a verified `<file>.tmp` over the real file. Rename is as close to
-- atomic as the platform gives us; the direct-write fallback covers file
-- systems without a working os.rename (the staged tmp has already been
-- verified either way, and read() recovers from the tmp if this is
-- interrupted).
function SaveService:_commit(filename)
    local tmp = filename .. ".tmp"
    if not love.filesystem.getInfo(tmp) then return false end
    local dir = love.filesystem.getSaveDirectory()
    local renamed = false
    if dir and dir ~= "" then
        pcall(os.remove, dir .. "/" .. filename)   -- Windows rename won't overwrite
        renamed = pcall(function()
            assert(os.rename(dir .. "/" .. tmp, dir .. "/" .. filename))
        end)
    end
    if not renamed then
        local raw = love.filesystem.read(tmp)
        if not raw then return false end
        local ok = love.filesystem.write(filename, raw)
        if not ok then return false end
        love.filesystem.remove(tmp)
    end
    return true
end

-- Write a save slot. `payload` is the model-serialized table.
function SaveService:write(filename, payload)
    if self.load_failed and isProgressSlot(filename) then
        print("SaveService: refusing to overwrite " .. filename .. " after a failed load")
        return false, "load failed"
    end
    if not self:_stage(filename, payload) then
        return false, "stage failed"
    end
    if not self:_commit(filename) then
        print("SaveService: commit failed for " .. filename)
        return false, "commit failed"
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

-- Convenience: write both slots from an in-memory pair. Both are staged
-- before either commits, so a crash between the two writes can't leave
-- meta and run describing different moments (a torn pair let a banked
-- {chip} bounty survive while its once-per-run lock rolled back).
-- Encode one payload for the writer. Returns the string, or nil on a
-- failure that has already been reported.
function SaveService:_encode(filename, payload)
    local wrapper = { version = VERSION, timestamp = os.time(), data = payload }
    local ok, encoded = pcall(json.encode, wrapper)
    if not ok then
        print("SaveService: encode failed for " .. filename .. ": " .. tostring(encoded))
        return nil
    end
    return encoded
end

-- The autosave path. On desktop the disk work is handed to the writer
-- thread and this returns immediately; `sync` (the quit and crash paths)
-- forces the inline write so nothing is in flight when the process ends.
function SaveService:saveAll(meta_payload, run_payload, sync)
    if self.load_failed then
        print("SaveService: refusing to save after a failed load")
        return false
    end

    if not sync and self:_worker() then
        self:drainResults()
        local jobs = self._jobs
        local queued = true
        if meta_payload then
            local enc = self:_encode(Constants.SAVE.META_FILE, meta_payload)
            if enc then jobs:push({ filename = Constants.SAVE.META_FILE, encoded = enc })
            else queued = false end
        end
        if run_payload then
            local enc = self:_encode(Constants.SAVE.RUN_FILE, run_payload)
            if enc then jobs:push({ filename = Constants.SAVE.RUN_FILE, encoded = enc })
            else queued = false end
        end
        return queued
    end

    local meta_ok = meta_payload and self:_stage(Constants.SAVE.META_FILE, meta_payload)
    local run_ok  = run_payload  and self:_stage(Constants.SAVE.RUN_FILE,  run_payload)
    if meta_ok then self:_commit(Constants.SAVE.META_FILE) end
    if run_ok  then self:_commit(Constants.SAVE.RUN_FILE)  end
    return (meta_payload == nil or meta_ok) and (run_payload == nil or run_ok)
end

local function removeWithTmp(filename)
    if love.filesystem.getInfo(filename) then
        love.filesystem.remove(filename)
    end
    local tmp = filename .. ".tmp"
    if love.filesystem.getInfo(tmp) then
        love.filesystem.remove(tmp)
    end
end

-- Wipe the run slot. Called by game-side reset paths.
function SaveService:clearRun()
    removeWithTmp(Constants.SAVE.RUN_FILE)
end

-- Wipe both slots. Used by the credits-screen reset and the F7 debug hotkey.
-- An explicit wipe is the player choosing to abandon an unreadable save, so
-- the load_failed latch clears with it.
function SaveService:clearAll()
    self:clearRun()
    removeWithTmp(Constants.SAVE.META_FILE)
    self.load_failed = false
end

-- Settings slot — separate from meta/run since user preferences (volume,
-- analytics consent) survive a "delete save" wipe. Settings writes are not
-- blocked by load_failed: they carry no progress.
function SaveService:loadSettings()
    return self:read(Constants.SAVE.SETTINGS_FILE)
end

function SaveService:saveSettings(payload)
    if payload then self:write(Constants.SAVE.SETTINGS_FILE, payload) end
end

return SaveService
