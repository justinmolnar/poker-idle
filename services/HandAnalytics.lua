-- services/HandAnalytics.lua
--
-- Per-shove hand analytics. One append-only JSON Lines log per save slot
-- (analytics_<save_id>.jsonl); each prestige run ("shove") is a run of
-- lines within it. Gated by Constants.DEBUG.HAND_ANALYTICS on desktop; the
-- web build records regardless and uploads only with consent.
--
-- startRun(state)   — call from GrindState:enter(); names the log and
--                     writes the current shove's header. Never reads it.
-- recordHand(rec)   — encodes one hand as one line into the pending chunk.
-- flush(state, consent, writer) — writes the shove's metadata when it
--                     changed, hands the pending lines to the writer as
--                     ONE append (`writer(filename, chunk, "append")`, the
--                     save thread when the autosave passes it), and (web +
--                     opted in) pushes the run to the analytics backend.
-- fold(text)        — the log back into the { save_id, shoves } shape the
--                     tools read; the headless checks use it.
--
-- Why a log and not a document: the file used to be rewritten whole on
-- every autosave — every hand of every kept shove concatenated again, on
-- the main thread, every ten seconds, growing for as long as the session
-- ran (12 MB on disk meant ~25 MB of strings per tick), then staged,
-- verified, backed up and renamed by the writer; and entering the grind
-- parsed all of it to find the current shove. Now nothing is retained:
-- a hand is formatted once into a fixed template, the pending lines go
-- out as one append, and the module holds no row it has already handed
-- over. A torn last line (a crash mid-append) costs that line, not the
-- file; the readers skip it.
--
-- Line kinds (every line is one object, "\n"-terminated, `s` = shove):
--   {"k":"save","save_id":..}                       once, when the log is created
--   {"k":"shove","s":N,started_at,deck_id,
--        catalog_levels,run_upgrade_levels}         every startRun (readers merge, last wins)
--   {"k":"hand","s":N,...}                          one per hand
--   {"k":"event","s":N,...}                         one per recordEvent
--   {"k":"shove_update","s":N,shove_rate,
--        gauntlet_result,chips_earned,
--        run_upgrade_levels,deck_id,hands_dropped}  on flush, only when it changed
--
-- Web transport: this love.js build exports no Module.FS (no
-- FORCE_FILESYSTEM / EXPORTED_RUNTIME_METHODS), so JS on the page can't read
-- love.filesystem's virtual disk directly — there is nothing to poll or
-- guess a path for. Instead, on web, flush() print()s the payload behind a
-- marker every Emscripten build always routes through Module.print (or
-- console.log if unset) regardless of build flags. build-tools/index.html's
-- Module.print hook watches for that marker and POSTs the JSON that follows.
-- That payload is the old document shape, so the web build alone keeps the
-- current shove's hands in memory (capped) to assemble it; desktop never
-- does.

local json = require("lib.json")

local HandAnalytics = {}

local ANALYTICS_MARKER = "@@POKERIDLE_ANALYTICS@@"

-- The pending chunk goes out on its own once it holds this many lines, so
-- a burst between autosaves (a full board deals a hand every few frames)
-- never piles up more than a few hundred strings.
local PENDING_FLUSH_AT = 256

-- Web only: the backend caps a shove at 5,000 hands (analytics-worker),
-- so the in-memory assembly keeps the newest that many. Trimmed in one
-- pass once well past the cap, not one shift per hand.
local WEB_MAX_HANDS  = 5000
local WEB_MAX_EVENTS = 2000

local _enabled       = false
local _filename      = nil
local _save_id       = nil
local _shove         = nil   -- current shove number
local _pending       = {}    -- encoded lines waiting for the writer
local _n_pending     = 0
local _last_meta_sig = nil   -- the last shove_update line written
local _shove_rate    = nil   -- the run's snapshot, until the next flush writes it
local _gauntlet_result, _chips_earned = nil, nil
local _hands_total   = 0     -- hands recorded this run (the HUD / checks)
local _writer        = nil   -- the autosave's threaded writer, for the burst flush
local _created       = {}    -- logs this session has opened, by filename
local _web           = nil   -- web only: { header, hands, events, dropped }

-- love.js reports its OS as "Web" (the gate SettingsModal and Display
-- use, verified against the shipped build). Not conf.lua's failed
-- require("ffi"): the headless checks run under PUC Lua, where that fails
-- too, and they must stay on the desktop rules. Read at startRun, once
-- love.system is up.
local _is_web = false
local function detectWeb()
    return (love.system and love.system.getOS and love.system.getOS()) == "Web"
end

-- ── Encoding ────────────────────────────────────────────────────────────
-- A hand's fields are scalars, so they are formatted straight into a
-- template rather than through json.encode's type walk, sort and table
-- of parts. Strings get one gsub through a lookup (lib/json's escaper is
-- five, and leaves control characters in, which JSON.parse rejects).

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
                  ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
local function escapeString(s)
    return '"' .. s:gsub('[%c"\\]', function(ch)
        return ESCAPES[ch] or string.format("\\u%04x", ch:byte())
    end) .. '"'
end

-- Numbers follow lib/json: integers exact, the rest at 17 digits, and a
-- NaN or infinity becomes null rather than a token no parser takes.
local function scalar(v)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif t == "string" then
        return escapeString(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    end
    return "null"
end

-- Every field either recordHand call site sends (the cash path carries
-- hand_pace_mult and deck_id, the tournament payout carries hands_played);
-- a field the record lacks prints as null, which decodes back to absent.
local HAND_TEMPLATE = '{"k":"hand","s":%d,"t_start":%s,"duration":%s,"won":%s,"delta":%s'
    .. ',"tier":%s,"stake_id":%s,"stake_bb":%s,"game_type_id":%s,"hand_pace_mult":%s'
    .. ',"deck_id":%s,"demo":%s,"hands_played":%s}'

local function encodeHand(r)
    return string.format(HAND_TEMPLATE, _shove,
        scalar(r.t_start), scalar(r.duration), scalar(r.won), scalar(r.delta),
        scalar(r.tier), scalar(r.stake_id), scalar(r.stake_bb), scalar(r.game_type_id),
        scalar(r.hand_pace_mult), scalar(r.deck_id), scalar(r.demo), scalar(r.hands_played))
end

-- A line of any other kind: the kind and shove spliced ahead of the
-- object's own fields (json.encode sorts keys, so the same table always
-- prints the same line — that is what the shove_update comparison relies on).
local function encodeLine(kind, fields)
    local body = json.encode(fields)
    local head = '{"k":"' .. kind .. '","s":' .. tostring(_shove)
    if body == "{}" then return head .. "}" end
    return head .. "," .. body:sub(2)
end

-- ── The pending chunk ───────────────────────────────────────────────────

local function push(line)
    _n_pending = _n_pending + 1
    _pending[_n_pending] = line
end

local function appendInline(chunk)
    local ok, err
    if love.filesystem.append then
        ok, err = love.filesystem.append(_filename, chunk)
    else
        local old = love.filesystem.getInfo(_filename) and love.filesystem.read(_filename) or ""
        ok, err = love.filesystem.write(_filename, old .. chunk)
    end
    if not ok then
        print("[HandAnalytics] append failed: " .. tostring(err))
    end
end

-- Hands the pending lines over as one append and clears them in place.
-- `writer` is the autosave's threaded write; when it declines (no worker:
-- the web build, the quit path) the append lands inline.
local function flushPending(writer)
    if _n_pending == 0 then return end
    local chunk = table.concat(_pending, "\n", 1, _n_pending) .. "\n"
    for i = 1, _n_pending do _pending[i] = nil end
    _n_pending = 0
    if writer then
        local ok = writer(_filename, chunk, "append")
        if ok ~= false then return end
    end
    appendInline(chunk)
end

-- ── Web assembly ────────────────────────────────────────────────────────
-- The backend wants the document shape; only the web build builds it,
-- from the current shove's lines (a hand line's extra "k" and "s" fields
-- are ignored by the worker, which reads columns by name).

local function webAssemble()
    local w = _web
    local head = json.encode(w.header)
    return '{"save_id":' .. escapeString(_save_id) .. ',"shoves":[' .. head:sub(1, -2)
        .. ',"events":[' .. table.concat(w.events, ",") .. ']'
        .. ',"hands":[' .. table.concat(w.hands, ",") .. ']'
        .. ',"hands_dropped":' .. tostring(w.dropped) .. "}]}"
end

local function webKeep(list, line, cap)
    list[#list + 1] = line
    if #list > cap * 1.25 then
        local keep, drop = {}, #list - cap
        for i = drop + 1, #list do keep[#keep + 1] = list[i] end
        return keep, drop
    end
    return list, 0
end

-- ── Public ──────────────────────────────────────────────────────────────

-- The autosave's writer, kept for the burst flush recordHand triggers
-- between ticks (flush() may still be handed one explicitly).
function HandAnalytics.setWriter(writer)
    _writer = writer
end

-- Remove the current save's analytics log (a new game mints a new
-- save_id, which used to orphan the old file forever), and the document
-- an older build left under the same id.
-- `save_id` is passed rather than assumed, because the file is named after
-- it and this is called from paths that never entered the grind (the
-- title's delete, a new game before any hand) where startRun has not run
-- and the module knows no filename at all. Without it those wipes left the
-- old file behind forever, which is where the pile of orphans came from.
function HandAnalytics.deleteCurrent(save_id)
    local id = _save_id or save_id
    if id then
        local base = "analytics_" .. id
        for _, name in ipairs({ base .. ".jsonl", base .. ".json",
                                base .. ".json.bak", base .. ".json.tmp" }) do
            if love.filesystem.getInfo(name) then love.filesystem.remove(name) end
        end
        _created[base .. ".jsonl"] = nil
    end
    _filename, _save_id, _shove, _web = nil, nil, nil, nil
    _shove_rate, _gauntlet_result, _chips_earned = nil, nil, nil
    for i = 1, _n_pending do _pending[i] = nil end
    _n_pending, _last_meta_sig, _hands_total = 0, nil, 0
end

-- Called from GrindState:enter(). Names the log after the save and writes
-- the current shove's header. The log is never read back: a resume writes
-- a second header for the same shove and the readers merge them.
function HandAnalytics.startRun(state)
    local Constants = require("data.constants")
    -- The web build records whatever the flag says: consent gates the
    -- upload, not the recording, and the controller's own gate reads the
    -- flag, so it is raised here for that build.
    _is_web = detectWeb()
    if _is_web then Constants.DEBUG.HAND_ANALYTICS = true end
    _enabled = Constants.DEBUG.HAND_ANALYTICS or _is_web
    if not _enabled then return end

    -- Anything still pending belongs to the run being left.
    if _filename and _n_pending > 0 then flushPending(_writer) end

    _filename = "analytics_" .. state.save_id .. ".jsonl"
    _save_id  = state.save_id
    _shove    = state.shove_count
    _last_meta_sig, _hands_total = nil, 0
    _shove_rate, _gauntlet_result, _chips_earned = nil, nil, nil

    -- The save line goes in once, when the log is new. The session
    -- remembers the logs it opened rather than asking the disk each time:
    -- a shove ends and the next starts while the writer thread may still
    -- hold the first chunk, and the disk would say the file is not there.
    if not _created[_filename] and not love.filesystem.getInfo(_filename) then
        push('{"k":"save","save_id":' .. escapeString(_save_id) .. "}")
    end
    _created[_filename] = true
    local header = {
        started_at         = os.time(),
        deck_id            = state.active_deck_id,
        catalog_levels     = state.owned_items        or {},
        run_upgrade_levels = state.run_upgrade_levels or {},
    }
    push(encodeLine("shove", header))

    if _is_web then
        header.shove_count = _shove
        _web = { header = header, hands = {}, events = {}, dropped = 0 }
    end
end

function HandAnalytics.recordHand(record)
    if not _enabled or not _shove then return end
    local line = encodeHand(record)
    _hands_total = _hands_total + 1
    push(line)
    if _web then
        local dropped
        _web.hands, dropped = webKeep(_web.hands, line, WEB_MAX_HANDS)
        _web.dropped = _web.dropped + dropped
    end
    if _n_pending >= PENDING_FLUSH_AT then flushPending(_writer) end
end

-- Called from ShoveState:_beginGauntlet(). Snapshots shove rates at the
-- moment of commitment (catalog + bankroll mult locked in). Lands in the
-- log at the next flush, as part of the shove_update line.
function HandAnalytics.recordShoveStart(rates)
    if not _enabled or not _shove then return end
    _shove_rate = {
        r1      = rates.r1,
        r2      = rates.r2,
        r3      = rates.r3,
        clear   = rates.clear,
        catalog = rates.catalog,
        mult    = rates.mult,
        bankroll = rates.bankroll,
    }
    if _web then _web.header.shove_rate = _shove_rate end
end

-- Called from ShoveState:_onGauntletEnded().
function HandAnalytics.recordShoveResult(result, chips_earned)
    if not _enabled or not _shove then return end
    _gauntlet_result = result.won and "won" or ("lost_r" .. (result.busted_at or 1))
    _chips_earned    = chips_earned or 0
    if _web then
        _web.header.gauntlet_result = _gauntlet_result
        _web.header.chips_earned    = _chips_earned
    end
end

-- Appends a timestamped event to the current shove (upgrade purchase, etc.).
function HandAnalytics.recordEvent(event)
    if not _enabled or not _shove then return end
    local line = encodeLine("event", event)
    push(line)
    if _web then
        local dropped
        _web.events, dropped = webKeep(_web.events, line, WEB_MAX_EVENTS)
    end
end

-- Called the frame after the autosave tick and from love.quit(). Writes
-- the shove's metadata when it changed since the last write, hands the
-- pending lines over as one append, and (web + opted in) pushes the run
-- out via the print() marker. `writer(filename, chunk, "append")` is
-- optional: the autosave passes the save service's threaded append, the
-- quit path passes nothing and appends inline.
function HandAnalytics.flush(state, consent, writer)
    if not _enabled or not _shove then return end
    local meta = {
        shove_rate         = _shove_rate,
        gauntlet_result    = _gauntlet_result,
        chips_earned       = _chips_earned,
        run_upgrade_levels = state and state.run_upgrade_levels or nil,
        deck_id            = state and state.active_deck_id or nil,
        hands_dropped      = (_web and _web.dropped > 0) and _web.dropped or nil,
    }
    local line = encodeLine("shove_update", meta)
    if line ~= _last_meta_sig then
        _last_meta_sig = line
        push(line)
    end
    flushPending(writer)
    if _web then
        local h = _web.header
        h.run_upgrade_levels = meta.run_upgrade_levels or h.run_upgrade_levels
        h.deck_id            = meta.deck_id or h.deck_id
        if consent then print(ANALYTICS_MARKER .. webAssemble()) end
    end
end

-- The log back into the document shape the tools read: headers for one
-- shove merge (last wins), hands and events group under their shove, and
-- a line that will not parse — the torn tail of a crash — is skipped.
function HandAnalytics.fold(text)
    local out, by_shove, order = { save_id = nil, shoves = {} }, {}, {}
    for line in (text or ""):gmatch("[^\n]+") do
        local ok, obj = pcall(json.decode, line)
        if ok and type(obj) == "table" then
            local kind, s = obj.k, obj.s
            obj.k, obj.s = nil, nil
            if kind == "save" then
                out.save_id = out.save_id or obj.save_id
            elseif s ~= nil then
                local shove = by_shove[s]
                if not shove then
                    shove = { shove_count = s, hands = {}, events = {}, hands_dropped = 0 }
                    by_shove[s] = shove
                    order[#order + 1] = shove
                end
                if kind == "hand" then
                    shove.hands[#shove.hands + 1] = obj
                elseif kind == "event" then
                    shove.events[#shove.events + 1] = obj
                elseif kind == "shove" or kind == "shove_update" then
                    for k, v in pairs(obj) do shove[k] = v end
                end
            end
        end
    end
    table.sort(order, function(a, b) return a.shove_count < b.shove_count end)
    out.shoves = order
    return out
end

-- For the headless checks and the perf HUD.
function HandAnalytics.stats()
    return { hands = _hands_total, pending = _n_pending,
             dropped = _web and _web.dropped or 0 }
end

return HandAnalytics
