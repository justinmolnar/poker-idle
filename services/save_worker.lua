-- services/save_worker.lua
--
-- The thread that puts bytes on disk. Started by services/SaveService on
-- desktop; the web build has no threads and keeps the inline path.
--
-- The main thread encodes and hands over a STRING. Deliberately not the
-- payload tables: pushing a table through a Channel deep-copies it, and a
-- full board's save is large enough that the copy would cost about what
-- the encode does, on the thread we are trying to keep free.
--
-- What crosses:
--   "poker_save_jobs"    <- { filename, encoded }
--   "poker_save_results" -> { filename, ok, err }
--
-- Every job reports exactly once, whether it succeeded or not:
-- SaveService:flushWorker counts pushes against reports to know when the
-- queue is empty, and a job that reported nothing would hang the quit.
--
-- The write is the same stage-then-commit as the inline path: write
-- <file>.tmp, check the bytes that landed, keep the live file as <file>.bak,
-- then swap the tmp over the real file. A crash between the two leaves the
-- tmp, which SaveService:load recovers.

require("love.filesystem")
require("love.system")

local jobs    = love.thread.getChannel("poker_save_jobs")
local results = love.thread.getChannel("poker_save_results")

-- Identical to the commit in services/SaveService: the rename path keeps a
-- backup, the copy fallback (a filesystem without a working os.rename,
-- which is the web build) does not.
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

while true do
    local job = jobs:demand()
    if type(job) == "table" and job.filename and job.encoded then
        local filename, encoded = job.filename, job.encoded
        local tmp = filename .. ".tmp"
        local ok, err = love.filesystem.write(tmp, encoded)
        if not ok then
            results:push({ filename = filename, ok = false,
                           err = "stage write failed: " .. tostring(err) })
        else
            -- Verify what actually landed. The failure this guards against
            -- is a SHORT write — a full disk, a killed process — so the
            -- length and the closing brace are exactly the right check, and
            -- far cheaper than parsing the save back.
            local back = love.filesystem.read(tmp)
            if not back or #back ~= #encoded or back:sub(-1) ~= "}" then
                results:push({ filename = filename, ok = false,
                               err = "staged file failed verification" })
            elseif not commit(filename) then
                results:push({ filename = filename, ok = false,
                               err = "commit failed" })
            else
                results:push({ filename = filename, ok = true })
            end
        end
    else
        -- Not a job we understand. Report anyway so the flush count stays
        -- honest.
        results:push({ filename = "?", ok = false, err = "malformed job" })
    end
end
