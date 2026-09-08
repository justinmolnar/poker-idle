-- services/save_worker.lua
--
-- The thread that puts a save on disk. Started by services/SaveService on
-- desktop; the web build has no threads and keeps the inline path.
--
-- The main thread encodes (that part is cheap now the JSON is compact) and
-- hands over a STRING. Deliberately not the payload tables: pushing a table
-- through a Channel deep-copies it, and the save carries sixteen parallel
-- arrays for a full board — the copy would cost about what the encode does,
-- on the thread we are trying to keep free.
--
-- What crosses:
--   "poker_save_jobs"    <- { filename, encoded }      (or "quit" to stop)
--   "poker_save_results" -> { filename, ok, err }
--
-- The write itself is the same stage-then-commit as the inline path: write
-- <file>.tmp, check the bytes that landed, then swap it over the real file.
-- A crash between the two leaves the .tmp, which SaveService:read recovers.

require("love.filesystem")
require("love.system")

local jobs    = love.thread.getChannel("poker_save_jobs")
local results = love.thread.getChannel("poker_save_results")

local function commit(filename)
    local tmp = filename .. ".tmp"
    if not love.filesystem.getInfo(tmp) then return false end
    local dir = love.filesystem.getSaveDirectory()
    local renamed = false
    if dir and dir ~= "" then
        -- Windows' rename will not overwrite, so the old file goes first.
        pcall(os.remove, dir .. "/" .. filename)
        renamed = pcall(function()
            assert(os.rename(dir .. "/" .. tmp, dir .. "/" .. filename))
        end)
    end
    if not renamed then
        local raw = love.filesystem.read(tmp)
        if not raw then return false end
        if not love.filesystem.write(filename, raw) then return false end
        love.filesystem.remove(tmp)
    end
    return true
end

while true do
    local job = jobs:demand()
    if job == "quit" then break end
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
    end
end
