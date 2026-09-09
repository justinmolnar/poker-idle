-- services/HandAnalytics.lua
--
-- Per-shove hand analytics. One JSON file per save slot; each prestige run
-- ("shove") is a separate entry within that file. Gated by
-- Constants.DEBUG.HAND_ANALYTICS.
--
-- startRun(state)   — call from GrindState:enter(); loads or creates the
--                     per-save file and finds/creates the current shove entry.
-- recordHand(rec)   — appends one hand record to the current shove.
-- flush(state, consent, writer) — snapshots final run metadata, writes the
--                     file (through `writer(filename, encoded)` when given,
--                     so the autosave can hand it to the save thread), and
--                     (web + opted in) pushes it to the analytics backend.
--
-- Why the file is assembled from strings rather than encoded from tables:
-- a hand record arrives for every hand on every table, and the file is
-- rewritten on every autosave. Encoding the whole thing each time meant a
-- json.encode over every hand of every kept shove, on the main thread,
-- every ten seconds, growing for as long as the session ran — at 36 tables
-- that was a stall you could set a clock by. Now each hand is encoded ONCE
-- when it is recorded, every shove but the current one is encoded once at
-- startRun, and a flush is a table.concat plus the metadata of the current
-- run. The disk write goes to the save worker with the saves. The file's
-- shape is unchanged; the tools read it as before.
--
-- Web transport: this love.js build exports no Module.FS (no
-- FORCE_FILESYSTEM / EXPORTED_RUNTIME_METHODS), so JS on the page can't read
-- love.filesystem's virtual disk directly — there is nothing to poll or
-- guess a path for. Instead, on web, flush() print()s the payload behind a
-- marker every Emscripten build always routes through Module.print (or
-- console.log if unset) regardless of build flags. build-tools/index.html's
-- Module.print hook watches for that marker and POSTs the JSON that follows.

local json = require("lib.json")

local HandAnalytics = {}

local ANALYTICS_MARKER = "@@POKERIDLE_ANALYTICS@@"

-- The file is rewritten in full on every flush; unbounded history made
-- that write grow forever. Keep the newest runs only.
local MAX_KEPT_SHOVES = 50
-- And the newest hands only, per run. A run at 36 tables records around a
-- thousand hands a minute; without a cap a long session held every one of
-- them as a live table and the heap (and every GC pass over it) grew with
-- the session. Dropped hands are counted in the file as `hands_dropped`.
-- A field, not a local, so the headless check can lower it.
HandAnalytics.MAX_HANDS_PER_RUN = 20000

local _enabled       = false
local _filename      = nil
local _save_id       = nil
local _old_shoves    = {}   -- every shove but the current one, each already a JSON string
local _run           = nil  -- the current shove's metadata; never holds `hands`
local _hands         = {}   -- the current shove's hands, each already a JSON string
local _hands_dropped = 0

-- love.js ships no FFI; failed require("ffi") = running on web. Mirrors the
-- same check conf.lua uses for IS_WEB.
local _is_web = false
do
    local ok = pcall(require, "ffi")
    if not ok then _is_web = true end
end

local function _readRaw(filename)
    if not love.filesystem.getInfo(filename) then return nil end
    local raw = love.filesystem.read(filename)
    if not raw then return nil end
    local ok, parsed = pcall(json.decode, raw)
    return (ok and type(parsed) == "table") and parsed or nil
end

-- The whole file as a string. The current run is encoded without its
-- hands, and the hands (already strings) are spliced in after its last
-- field; `_run` always has at least shove_count, so the encode is an
-- object and the splice lands inside it.
local function _assemble()
    local cur = json.encode(_run)
    cur = cur:sub(1, -2) .. ',"hands":[' .. table.concat(_hands, ",")
          .. '],"hands_dropped":' .. tostring(_hands_dropped) .. "}"
    local n = #_old_shoves
    local parts = {}
    for i = 1, n do parts[i] = _old_shoves[i] end
    parts[n + 1] = cur
    return '{"save_id":' .. json.encode(_save_id)
           .. ',"shoves":[' .. table.concat(parts, ",") .. "]}"
end

local function _write(encoded, writer)
    if writer then
        local ok = writer(_filename, encoded)
        if ok ~= false then return end
    end
    local ok, err = love.filesystem.write(_filename, encoded)
    if not ok then
        print("[HandAnalytics] write failed: " .. tostring(err))
    end
end

-- Remove the current save's analytics file (a new game mints a new
-- save_id, which used to orphan the old file forever).
function HandAnalytics.deleteCurrent()
    if _filename and love.filesystem.getInfo(_filename) then
        love.filesystem.remove(_filename)
    end
    _filename, _save_id, _run = nil, nil, nil
    _old_shoves, _hands, _hands_dropped = {}, {}, 0
end

-- Called from GrindState:enter(). Loads (or creates) the per-save analytics
-- file, then finds or creates the entry for state.shove_count.
function HandAnalytics.startRun(state)
    local Constants = require("data.constants")
    _enabled = Constants.DEBUG.HAND_ANALYTICS
    if not _enabled then return end

    _filename = "analytics_" .. state.save_id .. ".json"
    _save_id  = state.save_id
    local file = _readRaw(_filename) or { save_id = state.save_id, shoves = {} }
    local shoves = file.shoves or {}

    local n = #shoves
    local first = math.max(1, n - MAX_KEPT_SHOVES + 1)

    _old_shoves, _hands, _hands_dropped, _run = {}, {}, 0, nil
    for i = first, n do
        local s = shoves[i]
        if type(s) == "table" and s.shove_count == state.shove_count and not _run then
            -- Resumed mid-shove: its hands come back as tables from disk
            -- and are encoded once, here, then let go.
            _run = s
            local disk = s.hands or {}
            local cap  = HandAnalytics.MAX_HANDS_PER_RUN
            local from = math.max(1, #disk - cap + 1)
            _hands_dropped = (tonumber(s.hands_dropped) or 0) + (from - 1)
            for i = from, #disk do _hands[#_hands + 1] = json.encode(disk[i]) end
            s.hands, s.hands_dropped = nil, nil
        else
            _old_shoves[#_old_shoves + 1] = json.encode(s)
        end
    end

    if not _run then
        _run = {
            shove_count        = state.shove_count,
            started_at         = os.time(),
            deck_id            = state.active_deck_id,
            catalog_levels     = state.owned_items       or {},
            run_upgrade_levels = state.run_upgrade_levels or {},
            shove_rate         = nil,
            gauntlet_result    = nil,
            chips_earned       = nil,
            events             = {},
        }
    end
end

function HandAnalytics.recordHand(record)
    if not _enabled or not _run then return end
    _hands[#_hands + 1] = json.encode(record)
    -- Trim in one pass once well past the cap, not one shift per hand.
    local cap = HandAnalytics.MAX_HANDS_PER_RUN
    if #_hands > cap * 1.25 then
        local keep, drop = {}, #_hands - cap
        for i = drop + 1, #_hands do keep[#keep + 1] = _hands[i] end
        _hands = keep
        _hands_dropped = _hands_dropped + drop
    end
end

-- Called from ShoveState:_beginGauntlet(). Snapshots shove rates at the
-- moment of commitment (catalog + bankroll mult locked in).
function HandAnalytics.recordShoveStart(rates)
    if not _enabled or not _run then return end
    _run.shove_rate = {
        r1      = rates.r1,
        r2      = rates.r2,
        r3      = rates.r3,
        clear   = rates.clear,
        catalog = rates.catalog,
        mult    = rates.mult,
        bankroll = rates.bankroll,
    }
end

-- Called from ShoveState:_onGauntletEnded().
function HandAnalytics.recordShoveResult(result, chips_earned)
    if not _enabled or not _run then return end
    if result.won then
        _run.gauntlet_result = "won"
    else
        _run.gauntlet_result = "lost_r" .. (result.busted_at or 1)
    end
    _run.chips_earned = chips_earned or 0
end

-- Appends a timestamped event to the current shove (upgrade purchase, etc.).
function HandAnalytics.recordEvent(event)
    if not _enabled or not _run then return end
    table.insert(_run.events, event)
end

-- Called from the autosave tick and love.quit(). Updates final run-upgrade
-- snapshot, writes the local file, and (web + opted in) pushes the whole
-- per-save payload out via the print() marker. `writer(filename, encoded)`
-- is optional: the autosave passes the save service's threaded write, the
-- quit path passes nothing and writes inline.
function HandAnalytics.flush(state, consent, writer)
    if not _enabled or not _run then return end
    if state then
        _run.run_upgrade_levels = state.run_upgrade_levels or {}
        _run.deck_id = state.active_deck_id or _run.deck_id
    end
    local encoded = _assemble()
    _write(encoded, writer)
    if _is_web and consent then
        print(ANALYTICS_MARKER .. encoded)
    end
end

-- For the headless checks and the perf HUD.
function HandAnalytics.stats()
    return { hands = #_hands, dropped = _hands_dropped, old_shoves = #_old_shoves }
end

return HandAnalytics
