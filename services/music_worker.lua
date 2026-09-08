-- services/music_worker.lua
--
-- Decodes the music and applies the intercom filter, off the frame.
--
-- Why this exists: while the player does not own the Desk Speakers — all of
-- Act 1 — every decoded chunk went through a per-SAMPLE Lua loop on the
-- main thread: two highpass stages, drive, a cubic soft clip, a one-pole
-- lowpass, a bitcrush sample-hold and a static mix, with a getSample and a
-- setSample per sample per channel. At 44.1 kHz stereo that is about 180k
-- C calls per second of audio, and it arrived in bursts because the refill
-- loop tops the queue up to sixteen chunks at a time.
--
-- The split: this thread owns the Decoder and the filter and pushes
-- finished SoundData (a shareable LOVE object) across. The main thread
-- keeps the QueueableSource — audio objects stay on one thread — and only
-- pops and queues. The filter maths below is character-for-character the
-- same as the inline version it replaces, so it sounds identical.
--
-- Channels:
--   "poker_music_ctl"    <- { cmd = "track", path = }        load and start
--                        <- { cmd = "grime", value = }       filter targets
--                        <- { cmd = "echo",  value = }
--                        <- { cmd = "seek",  pos = }         seconds
--                        <- { cmd = "want",  n = }           chunks wanted
--                        <- { cmd = "quit" }
--   "poker_music_chunks" -> { data = SoundData, frames = , rate = , ch = }
--   "poker_music_state"  -> { event = "ended" | "failed" }

require("love.sound")
require("love.filesystem")
require("love.timer")

local ctl    = love.thread.getChannel("poker_music_ctl")
local chunks = love.thread.getChannel("poker_music_chunks")
local state  = love.thread.getChannel("poker_music_state")

-- Filter constants: identical to services/MusicDirector's.
local GRIME_VOL_CUT = 0.45
local EASE_SECS     = 0.5
local HP_DIRTY_HZ   = 480
local LP_DIRTY_HZ   = 2600
local LP_CLEAN_HZ   = 18000
local DRIVE_MAX     = 3.5
local MAKEUP        = 1.8
local CRUSH_HOLD    = 4
local STATIC_LEVEL  = 0.07
local FAR_LP_HZ     = 1000

local _dec, _rate, _channels = nil, 44100, 2
local _lp, _hp, _hp2 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local _hold_v, _hold_n = { 0, 0 }, 0
local _static, _static_n, _static_i = nil, 0, 0
local _grime, _grime_t = 1, 1
local _echo = 0
local _pos, _want = 0, 0

local function loadStatic()
    local ok, items = pcall(love.filesystem.getDirectoryItems, "assets/audio/radio/open")
    if not (ok and items) then return end
    for _, name in ipairs(items) do
        local ext = name:match("%.(%w+)$")
        if ext and (ext == "mp3" or ext == "ogg" or ext == "wav" or ext == "flac") then
            local ok2, sd = pcall(love.sound.newSoundData,
                                  "assets/audio/radio/open/" .. name)
            if ok2 and sd then
                _static   = sd
                _static_n = math.floor(sd:getDuration() * sd:getSampleRate())
                return
            end
        end
    end
end
loadStatic()

local function processChunk(sd, dt_chunk)
    local frames = math.floor(sd:getDuration() * sd:getSampleRate() + 0.5)
    local k = math.min(1, (dt_chunk or 0.05) / EASE_SECS)
    _grime = _grime + (_grime_t - _grime) * k
    local g, e = _grime, _echo
    if g < 0.003 and e < 0.003 then return end   -- clean passthrough

    local cutoff = LP_CLEAN_HZ + (LP_DIRTY_HZ - LP_CLEAN_HZ) * g
    cutoff = cutoff + (math.min(cutoff, FAR_LP_HZ) - cutoff) * e
    local alpha  = 1 - math.exp(-2 * math.pi * cutoff / _rate)
    local hp_a   = 1 - math.exp(-2 * math.pi * HP_DIRTY_HZ / _rate)
    local hp_mix = g
    local makeup = 1 + (MAKEUP - 1) * g
    local drive  = 1 + DRIVE_MAX * g
    local inv_dr = 1 / drive
    local hold_len = 1 + math.floor(CRUSH_HOLD * g + 0.5)
    local st_lvl = STATIC_LEVEL * g

    for f = 0, frames - 1 do
        _hold_n = _hold_n + 1
        local refresh = _hold_n >= hold_len
        if refresh then _hold_n = 0 end
        local st = 0
        if _static and st_lvl > 0 then
            _static_i = _static_i + 1
            if _static_i >= _static_n then _static_i = 0 end
            st = _static:getSample(_static_i) * st_lvl
        end
        for c = 1, _channels do
            local v = sd:getSample(f, c)
            _hp[c] = _hp[c] + hp_a * (v - _hp[c])
            v = v - _hp[c] * hp_mix
            _hp2[c] = _hp2[c] + hp_a * (v - _hp2[c])
            v = (v - _hp2[c] * hp_mix) * makeup
            v = v * drive
            if v > 1 then v = 1 elseif v < -1 then v = -1 end
            v = v * (1.5 - 0.5 * v * v)   -- cubic soft clip
            v = v * inv_dr * (1 + 0.6 * g)
            _lp[c] = _lp[c] + alpha * (v - _lp[c])
            v = _lp[c]
            if refresh or hold_len <= 1 then _hold_v[c] = v end
            v = _hold_v[c]
            v = v + st
            if v > 1 then v = 1 elseif v < -1 then v = -1 end
            sd:setSample(f, c, v)
        end
    end
end

local function openTrack(path)
    _dec = nil
    local ok = pcall(function()
        _dec      = love.sound.newDecoder(path, 8192)
        _rate     = _dec:getSampleRate()
        _channels = _dec:getChannelCount()
    end)
    if not ok or not _dec then
        _dec = nil
        state:push({ event = "failed" })
        return
    end
    _pos = 0
    _lp, _hp, _hp2, _hold_v, _hold_n = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, 0
    state:push({ event = "opened", rate = _rate, channels = _channels,
                 depth = _dec:getBitDepth() })
end

local function handle(msg)
    if type(msg) ~= "table" then return true end
    local cmd = msg.cmd
    if cmd == "quit"  then return false end
    if cmd == "track" then openTrack(msg.path)
    elseif cmd == "grime" then _grime_t = msg.value or 0
    elseif cmd == "echo"  then _echo    = msg.value or 0
    elseif cmd == "want"  then _want    = math.max(_want, msg.n or 0)
    elseif cmd == "seek"  then
        if _dec and pcall(function() _dec:seek(msg.pos or 0) end) then
            _pos = math.floor((msg.pos or 0) * _rate)
        end
    end
    return true
end

while true do
    -- Drain the control channel, then produce whatever was asked for.
    local msg = ctl:pop()
    while msg do
        if not handle(msg) then return end
        msg = ctl:pop()
    end

    if _dec and _want > 0 then
        _want = _want - 1
        local ok, chunk = pcall(function() return _dec:decode() end)
        if not ok or not chunk then
            state:push({ event = "ended" })
            _dec, _want = nil, 0
        else
            local frames = math.floor(chunk:getDuration() * chunk:getSampleRate() + 0.5)
            pcall(processChunk, chunk, frames / _rate)
            _pos = _pos + frames
            chunks:push({ data = chunk, frames = frames, pos = _pos })
        end
    else
        -- Nothing to do: wait on the control channel rather than spin.
        local waited = ctl:demand(0.05)
        if waited and not handle(waited) then return end
    end
end
