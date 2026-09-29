-- services/SaveService.lua
--
-- One save file, plus a settings file.
--
--   save.json      the game. { version, saved_at, meta = {...}, run = {...} }
--   settings.save  volumes, display, motion, consent. Same wrapper shape.
--
-- The two halves of the game live in ONE file because they describe one
-- moment. The old two-slot layout staged and committed meta and run
-- separately, so a crash (or a quit racing the writer thread) between the
-- two commits left a save whose halves disagreed — a banked bounty in meta
-- with its once-per-run lock rolled back in run. One file, one commit, no
-- torn pair.
--
-- Write safety, in order: encode → write `save.json.tmp` → verify the bytes
-- that landed → rename the live file to `save.json.bak` → rename the tmp
-- over the live file. A crash at any point leaves at least one readable
-- copy, and `load()` tries all three in newest-first order.
--
-- Version: a file whose version is not VERSION is REFUSED, not migrated.
-- `load()` returns nil and `refused` is set; the file is left on disk and
-- nothing overwrites it until the player starts a new game. There are no
-- field-level migrations anywhere any more — models/GameState is an
-- explicit key list, and an old save is simply not this game.
--
-- The `load_failed` latch is for `save.json` alone: a settings file that
-- will not parse is not worth refusing a session over, and it used to
-- suspend every progress save for the whole session.

local SaveService = {}

local Constants = require("data.constants")
local json      = require("lib.json")
local Perf      = require("services.Perf")

local VERSION = Constants.SAVE.VERSION
local FILE    = Constants.SAVE.FILE

-- JSON decode produces string keys for all object fields; Lua wants the
-- integer-keyed ones back (a table's `seat_stacks` and `in_seats` go sparse
-- the moment a seat folds, and sparse arrays encode as objects).
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

-- ── The writer thread ──────────────────────────────────────────────────
-- Desktop hands the disk work to services/save_worker. The encode stays
-- here; a string crosses the channel, not the payload tables (pushing a
-- table deep-copies it, which would cost about what the encode does on the
-- thread we are trying to keep free).
local _is_web = false
do
    local ok = pcall(require, "ffi")
    if not ok then _is_web = true end
end

local function threadsAvailable()
    return love.thread ~= nil and not _is_web
end

function SaveService:new()
    return setmetatable({
        load_failed = false,
        refused     = nil,   -- "old" when the file on disk is another version
        has_save    = nil,   -- cached; hasSave() must not hit the disk per frame
        _pushed     = 0,
        _reported   = 0,
    }, { __index = self })
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
-- frame from love.update, and in a loop by flushWorker.
function SaveService:drainResults()
    local ch = self._results
    if not ch then return end
    while true do
        local r = ch:pop()
        if not r then break end
        self._reported = self._reported + 1
        if not r.ok then
            print("SaveService: " .. tostring(r.filename) .. " — " .. tostring(r.err))
            if r.filename == FILE then self.load_failed = true end
        end
    end
    local t = self._worker_thread
    if t then
        local err = t:getError()
        if err then
            print("SaveService: writer thread died (" .. tostring(err)
                  .. "); saves fall back to the main thread")
            self._worker_thread, self._jobs, self._results = nil, nil, nil
            self._reported = self._pushed
        end
    end
end

-- Wait for every queued write to report. The quit path calls this before
-- its own inline write, so a queued autosave cannot commit older bytes
-- over the final save after we have gone.
function SaveService:flushWorker(timeout)
    if not self._results then return true end
    local deadline = (love.timer and love.timer.getTime() or 0) + (timeout or 2.0)
    self:drainResults()
    while self._reported < self._pushed do
        if not self._results:demand(0.1) then
            -- demand consumed nothing within the slice; drain and re-check
            -- so a result that arrived between the pop and the demand counts.
            self:drainResults()
        else
            -- demand popped one for us; put the count straight.
            self._reported = self._reported + 1
            self:drainResults()
        end
        if love.timer and love.timer.getTime() > deadline then
            print("SaveService: writer did not finish within the flush window")
            return false
        end
    end
    return true
end

-- ── Reading ────────────────────────────────────────────────────────────

-- One raw read attempt. Returns (wrapper, nil) or (nil, reason).
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
    return decoded, nil
end

-- The game file. Returns the payload `{ meta = , run = }`, or nil plus a
-- reason: "no save", "old" (another version, left alone), or a read error
-- (which latches load_failed).
--
-- Tries the live file, then a `.tmp` left by a crash between stage and
-- commit, then the `.bak` kept from the previous good commit.
function SaveService:load()
    self.refused = nil
    local sources = { FILE, FILE .. ".tmp", FILE .. ".bak" }
    local first_reason = nil
    for i, name in ipairs(sources) do
        local wrapper, reason = tryRead(name)
        if wrapper then
            if wrapper.version ~= VERSION then
                -- Another version of the game wrote this. Refuse it, keep
                -- it, and say so; New Game is the way past.
                print(string.format("SaveService: %s is v%s, this build reads v%s — refusing it",
                    name, tostring(wrapper.version), tostring(VERSION)))
                self.refused  = "old"
                self.has_save = false
                return nil, "old"
            end
            if i > 1 then
                print("SaveService: recovered the save from " .. name)
            end
            local payload = {
                meta = type(wrapper.meta) == "table" and wrapper.meta or nil,
                run  = type(wrapper.run) == "table" and wrapper.run or nil,
            }
            coerceIntKeys(payload)
            self.has_save = true
            return payload
        end
        first_reason = first_reason or reason
    end

    if first_reason ~= "no save" then
        -- The file is there and unreadable, and neither backup helped.
        -- Never let an autosave replace it with fresh-game state.
        self.load_failed = true
        print("SaveService: LOAD FAILED (" .. tostring(first_reason)
            .. ") — saves suspended until a new game is started")
    end
    self.has_save = false
    return nil, first_reason
end

-- Is there a loadable save? Answered from the last load/save/clear, so the
-- title screen can ask every frame without touching the disk.
function SaveService:hasSave()
    if self.has_save == nil then self:load() end
    return self.has_save == true
end

-- ── Writing ────────────────────────────────────────────────────────────

function SaveService:_encode(payload)
    -- Compact, not pretty-printed: no human reads the save in place (the
    -- tools all work from the repo), and the indentation roughly doubled
    -- every byte we encode, write, read back and verify.
    local wrapper = { version = VERSION, saved_at = os.time(),
                      meta = payload.meta, run = payload.run }
    local ok, encoded = pcall(json.encode, wrapper)
    if not ok or type(encoded) ~= "string" then
        print("SaveService: encode failed: " .. tostring(encoded))
        return nil
    end
    return encoded
end

-- Write `<file>.tmp` and verify the bytes that landed. Never touches the
-- live file. The failure this guards is a SHORT write — a full disk, a
-- killed process, Emscripten's IDBFS flushing badly — so a length and
-- terminator check is exactly the right test and far cheaper than a parse.
local function stage(filename, encoded)
    local tmp = filename .. ".tmp"
    local ok, err = love.filesystem.write(tmp, encoded)
    if not ok then
        print("SaveService: stage write failed for " .. tmp .. ": " .. tostring(err))
        return false
    end
    local back = love.filesystem.read(tmp)
    if not back or #back ~= #encoded or back:sub(-1) ~= "}" then
        print("SaveService: staged " .. tmp .. " failed verification, keeping the old save")
        return false
    end
    return true
end

-- Commit a verified tmp over the live file, keeping one backup.
--
-- The rename path keeps `<file>.bak`; the copy fallback does not. That
-- fallback is the web build's normal path (IDBFS has no working
-- os.rename), where a read-plus-two-writes on every autosave is the stall
-- the writer thread exists to avoid — and the tmp is verified either way,
-- so a crash there still leaves a recoverable copy.
local function commit(filename)
    local tmp = filename .. ".tmp"
    if not love.filesystem.getInfo(tmp) then return false end
    local dir = love.filesystem.getSaveDirectory()
    if dir and dir ~= "" then
        local bak = filename .. ".bak"
        pcall(os.remove, dir .. "/" .. bak)
        pcall(os.rename, dir .. "/" .. filename, dir .. "/" .. bak)
        local renamed = pcall(function()
            assert(os.rename(dir .. "/" .. tmp, dir .. "/" .. filename))
        end)
        if renamed then return true end
        -- The rename failed after the live file was moved aside; put it back
        -- so the copy fallback below is not writing over a hole.
        if not love.filesystem.getInfo(filename) then
            pcall(os.rename, dir .. "/" .. bak, dir .. "/" .. filename)
        end
    end
    local raw = love.filesystem.read(tmp)
    if not raw then return false end
    if not love.filesystem.write(filename, raw) then return false end
    love.filesystem.remove(tmp)
    return true
end

SaveService.commitFile = commit   -- shared with services/save_worker

-- Save the game. `payload` is `{ meta = , run = }`. On desktop the disk
-- work goes to the writer thread and this returns at once; `sync` (quit,
-- the crash handler, the shove commit) forces the inline write and first
-- waits for anything already queued.
function SaveService:save(payload, sync)
    if self.load_failed then
        print("SaveService: refusing to save after a failed load")
        return false
    end
    -- Timed on its own so the F4 HUD can tell the encode from the
    -- serialize when a save tick shows in the frame.
    Perf.enter("save.encode")
    local encoded = self:_encode(payload)
    Perf.exit("save.encode")
    if not encoded then return false end

    if not sync and self:_worker() then
        self:drainResults()
        self._pushed = self._pushed + 1
        self._jobs:push({ filename = FILE, encoded = encoded })
        self.has_save = true
        return true
    end

    if sync then self:flushWorker() end
    if not stage(FILE, encoded) then return false end
    if not commit(FILE) then
        print("SaveService: commit failed")
        return false
    end
    self.has_save = true
    return true
end

-- One already-encoded file through the writer thread: the analytics log
-- rides with the save. Returns false when there is no worker, so the
-- caller writes inline itself. Never consults load_failed — a broken game
-- save is no reason to stop logging.
function SaveService:writeAsync(filename, encoded)
    if not self:_worker() then return false end
    self:drainResults()
    self._pushed = self._pushed + 1
    self._jobs:push({ filename = filename, encoded = encoded })
    return true
end

-- A chunk onto the end of a file through the writer thread (the analytics
-- log's pending lines). Same contract as writeAsync: false when there is
-- no worker, so the caller appends inline itself.
function SaveService:appendAsync(filename, chunk)
    if not self:_worker() then return false end
    self:drainResults()
    self._pushed = self._pushed + 1
    self._jobs:push({ filename = filename, append = chunk })
    return true
end

-- Delete the save and everything staged or backed up with it, and lift the
-- failed-load latch. This is the explicit way past an unreadable or
-- foreign save.
function SaveService:clear()
    for _, name in ipairs({ FILE, FILE .. ".tmp", FILE .. ".bak" }) do
        if love.filesystem.getInfo(name) then love.filesystem.remove(name) end
    end
    self.load_failed = false
    self.refused     = nil
    self.has_save    = false
end

-- ── Settings ───────────────────────────────────────────────────────────
-- Their own file, their own rules: a settings file that will not parse
-- costs the player their volume, not their save.

function SaveService:loadSettings()
    local wrapper = tryRead(Constants.SAVE.SETTINGS_FILE)
    if not wrapper or type(wrapper.data) ~= "table" then return nil end
    coerceIntKeys(wrapper.data)
    return wrapper.data
end

function SaveService:saveSettings(payload)
    local ok, encoded = pcall(json.encode,
        { version = VERSION, saved_at = os.time(), data = payload })
    if not ok or type(encoded) ~= "string" then return false end
    local name = Constants.SAVE.SETTINGS_FILE
    if not stage(name, encoded) then return false end
    return commit(name)
end

return SaveService
