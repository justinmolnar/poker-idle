-- services/Profiler.lua
--
-- A sampling profiler for the running game (LuaJIT's jit.profile). The
-- HUD's scopes say which section a frame spends its time in; this says
-- which LINES, which is the question the scopes cannot answer once the
-- section is "grid" or "live". Dev only, behind the HUD's hotkey
-- (Ctrl+F4 in controllers/InputController): samples for a few seconds and
-- writes the hottest leaf lines and the hottest three-deep stacks to a
-- text file in the save directory, then prints the path.
--
-- Sampling, not instrumenting: a 1 ms timer interrupts the VM and records
-- where it is, so the game runs at speed while it is measured and the
-- counts are proportional to time. Allocation is not sampled directly,
-- but the lines that allocate are the lines the collector's work lands
-- on, so the heavy allocators surface here too.
--
-- Absent outside LuaJIT 2.1 (PUC Lua, the sims): every call is a no-op.

local Profiler = {}

local _ok, _prof = pcall(require, "jit.profile")
if not _ok then _prof = nil end

local _running   = false
local _until     = 0
local _leaf      = {}     -- "file:line" -> samples
local _stack     = {}     -- "a < b < c" -> samples
local _samples   = 0
local SECS_DEFAULT = 5

local function now()
    return (love and love.timer and love.timer.getTime()) or os.clock()
end

local function onSample(thread, samples, vmstate)
    _samples = _samples + samples
    -- The leaf line, and the three-deep stack it sits in.
    local leaf = _prof.dumpstack(thread, "pl", 1)
    _leaf[leaf] = (_leaf[leaf] or 0) + samples
    local st = _prof.dumpstack(thread, "pl < ", 3)
    _stack[st] = (_stack[st] or 0) + samples
end

function Profiler.available() return _prof ~= nil end
function Profiler.running()   return _running end

-- Start sampling for `secs` (default 5). Returns false when unavailable.
function Profiler.start(secs)
    if not _prof or _running then return false end
    _leaf, _stack, _samples = {}, {}, 0
    _until   = now() + (secs or SECS_DEFAULT)
    _running = true
    -- "li1": line-level, 1 ms interval.
    _prof.start("li1", onSample)
    print(("[profiler] sampling for %ds"):format(secs or SECS_DEFAULT))
    return true
end

local function top(map, n)
    local list = {}
    for k, v in pairs(map) do list[#list + 1] = { k, v } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

-- Called once per frame (main.lua's love.update): stops the run when its
-- time is up and writes the report.
function Profiler.update()
    if not _running then return end
    if now() < _until then return end
    _prof.stop()
    _running = false
    local lines = {}
    lines[#lines + 1] = ("profile: %d samples (1 ms each) over %ds"):format(_samples, SECS_DEFAULT)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "hottest lines (leaf):"
    for _, e in ipairs(top(_leaf, 40)) do
        lines[#lines + 1] = ("%6d  %5.1f%%  %s"):format(e[2], 100 * e[2] / math.max(1, _samples), (e[1]:gsub("\n", "")))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "hottest stacks (leaf < caller < caller):"
    for _, e in ipairs(top(_stack, 40)) do
        lines[#lines + 1] = ("%6d  %5.1f%%  %s"):format(e[2], 100 * e[2] / math.max(1, _samples), (e[1]:gsub("\n", "")))
    end
    local text = table.concat(lines, "\n") .. "\n"
    local name = ("profile_%d.txt"):format(math.floor(now()))
    local ok = love and love.filesystem and love.filesystem.write and love.filesystem.write(name, text)
    if ok then
        print(("[profiler] wrote %s/%s"):format(love.filesystem.getSaveDirectory(), name))
    else
        print(text)
    end
end

return Profiler
