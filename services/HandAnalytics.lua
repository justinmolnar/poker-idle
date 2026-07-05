-- services/HandAnalytics.lua
--
-- Per-shove hand analytics. One JSON file per save slot; each prestige run
-- ("shove") is a separate entry within that file. Gated by
-- Constants.DEBUG.HAND_ANALYTICS.
--
-- startRun(state)   — call from GrindState:enter(); loads or creates the
--                     per-save file and finds/creates the current shove entry.
-- recordHand(rec)   — appends one hand record to the current shove.
-- flush(state)      — snapshots final run metadata and writes the file.

local json = require("lib.json")

local HandAnalytics = {}

local _enabled      = false
local _filename     = nil
local _file_data    = nil   -- { save_id, shoves = [...] }
local _current_run  = nil   -- reference into _file_data.shoves[i]

local function _readRaw(filename)
    if not love.filesystem.getInfo(filename) then return nil end
    local raw = love.filesystem.read(filename)
    if not raw then return nil end
    local ok, parsed = pcall(json.decode, raw)
    return (ok and type(parsed) == "table") and parsed or nil
end

local function _writeRaw()
    if not _file_data or not _filename then return end
    local ok, err = love.filesystem.write(_filename, json.encode(_file_data, true))
    if not ok then
        print("[HandAnalytics] write failed: " .. tostring(err))
    end
end

-- Called from GrindState:enter(). Loads (or creates) the per-save analytics
-- file, then finds or creates the entry for state.shove_count.
function HandAnalytics.startRun(state)
    local Constants = require("data.constants")
    _enabled = Constants.DEBUG.HAND_ANALYTICS
    if not _enabled then return end

    _filename  = "analytics_" .. state.save_id .. ".json"
    _file_data = _readRaw(_filename) or { save_id = state.save_id, shoves = {} }

    -- Find an existing entry (game resumed mid-shove and re-entered grind).
    local run = nil
    for _, s in ipairs(_file_data.shoves) do
        if s.shove_count == state.shove_count then
            run = s; break
        end
    end

    if not run then
        run = {
            shove_count        = state.shove_count,
            started_at         = os.time(),
            deck_id            = state.active_deck_id,
            catalog_levels     = state.owned_items       or {},
            run_upgrade_levels = state.run_upgrade_levels or {},
            shove_rate         = nil,
            gauntlet_result    = nil,
            chips_earned       = nil,
            events             = {},
            hands              = {},
        }
        table.insert(_file_data.shoves, run)
    end

    _current_run = run
end

function HandAnalytics.recordHand(record)
    if not _enabled or not _current_run then return end
    table.insert(_current_run.hands, record)
end

-- Called from ShoveState:_beginGauntlet(). Snapshots shove rates at the
-- moment of commitment (catalog + bankroll mult locked in).
function HandAnalytics.recordShoveStart(rates)
    if not _enabled or not _current_run then return end
    _current_run.shove_rate = {
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
    if not _enabled or not _current_run then return end
    if result.won then
        _current_run.gauntlet_result = "won"
    else
        _current_run.gauntlet_result = "lost_r" .. (result.busted_at or 1)
    end
    _current_run.chips_earned = chips_earned or 0
end

-- Appends a timestamped event to the current shove (upgrade purchase, etc.).
function HandAnalytics.recordEvent(event)
    if not _enabled or not _current_run then return end
    table.insert(_current_run.events, event)
end

-- Called from love.quit(). Updates final run-upgrade snapshot and writes.
function HandAnalytics.flush(state)
    if not _enabled or not _current_run then return end
    if state then
        _current_run.run_upgrade_levels = state.run_upgrade_levels or {}
        _current_run.deck_id = state.active_deck_id or _current_run.deck_id
    end
    _writeRaw()
end

return HandAnalytics
