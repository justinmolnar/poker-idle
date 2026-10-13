-- services/MusicDirector.lua
--
-- The music layer. Tracks dropped into assets/audio/music/ play through
-- THE HOUSE's intercom — which is to say: through a live DSP chain that
-- makes them sound like they're coming out of a bolted-on speaker box
-- (lowpass muffle, soft-clip drive, bitcrush, a bed of the game's own
-- radio static). Once the player owns the desk_speakers catalog item,
-- they're listening on their own hardware: the chain opens up to clean
-- passthrough, and the House talking no longer interrupts the music.
--
-- The rules (all diegetic):
--   • Pre-speakers, the intercom has ONE channel: the music HARD-CUTS the
--     frame the House starts speaking (the typewriter window) and comes
--     back ~0.8s after he stops — skipped AHEAD by the time he talked,
--     because the broadcast kept playing; he talked over it.
--   • The room (and the shove's room-walkthrough phase) adds an
--     DISTANCE: 20% quieter (multiplicative) and duller — until speakers.
--   • The gauntlet felt (any shove phase past "room") cuts the music
--     dead. Tension. It returns on the next screen.
--   • The title is the room in the dark: the room's treatment.
--   • Credits: silence.
--
-- Engine: Decoder → per-chunk Lua DSP → QueueableSource, the pipeline
-- proven at real-time on desktop AND this repo's love.js compat build.
-- Cuts ride Source:setVolume (frame-instant, affects queued audio);
-- texture changes ease inside the chunk loop (clickless) and land a
-- queue-depth behind (~0.2s desktop / ~0.5s web) — fine for moods.
--
-- No files in the folder → the module is inert.

local SoundService = require("services.SoundService")

local MusicDirector = {}

local DIR  = "assets/audio/music"
local EXTS = { mp3 = true, ogg = true, wav = true, flac = true }

local MUSIC_BASE    = 0.4
local GRIME_VOL_CUT = 0.45    -- the intercom is also QUIET: volume × (1 - this × grime)
local SPEAK_RESUME  = 0.8     -- seconds of radio silence before music returns
local START_GRACE   = 1.5     -- boot/new-game hold so the House gets the first word
local EASE_SECS     = 0.5     -- texture (grime/echo) ease time
-- Grime chain numbers, at grime = 1. The character is a SMALL speaker:
-- a tiny driver has no low end at all, so the chain is a bandpass honk
-- (highpass ~480Hz + lowpass ~2.6kHz), driven, crushed, over static.
-- (The render rig showed ~90% of the raw track energy lives under
-- 300Hz — without the highpass everything read as one bass mud.)
local HP_DIRTY_HZ   = 480     -- small-driver highpass (off at grime 0)
local LP_DIRTY_HZ   = 2600    -- lowpass cutoff (wide open at grime 0)
local LP_CLEAN_HZ   = 18000
local DRIVE_MAX     = 3.5     -- soft-clip input gain adds v*(1+DRIVE*g)
local MAKEUP        = 1.8     -- gain to buy back the energy the bandpass cuts
local CRUSH_HOLD    = 4       -- bitcrush sample-hold length
local STATIC_LEVEL  = 0.07    -- static bed mix at grime 1
-- The room, at echo = 1 — a BIG EMPTY SPACE, not a delay pedal: three
-- staggered reflection taps at incommensurate delays, each fed back
-- gently and damped (walls eat the highs), under a slightly pulled-back
-- direct signal. Reads as air and distance rather than "echo... echo".
-- The room = DISTANCE, done honestly: quieter and duller, no delays.
-- (Feedback echo taps on full-mix music were tried and retired — they
-- fight the song's own tempo and read as a broken repeat, not a space.)
local FAR_LP_HZ     = 1000    -- highs die crossing 50ft of warehouse air
local ROOM_VOL_CUT  = 0.20    -- flat source-volume drop in the room, MULTIPLICATIVE
                              -- (20% of whatever the current volume is)
-- The focus strain, at strain = 1 (the focus floor). Read from
-- SoundService.getStrain on the grind, 0 anywhere else. The music slows
-- WITH the tables: the source's pitch, which drops the key with it (a
-- tape, not a time-stretch), held at PITCH_MIN where OpenAL stops being
-- safe; a slow wow on top; and in the chain more drive and a longer
-- crush, which apply with the Desk Speakers too — this is not the
-- intercom, it is the player.
local PITCH_MIN     = 0.5
local WOW_DEPTH     = 0.03    -- +/- pitch at strain 1
local WOW_HZ        = 0.6
local STRAIN_DRIVE  = 4.0     -- extra soft-clip gain at strain 1
local STRAIN_CRUSH  = 6       -- extra sample-hold length at strain 1

-- ── State ──────────────────────────────────────────────────────────────
local _init      = false
local _playlist  = {}     -- shuffled file paths
local _pl_i      = 0
local _dec       = nil    -- current track's Decoder
local _src       = nil    -- current track's QueueableSource
local _rate, _channels = 44100, 2
local _pos       = 0      -- decoded frames (track position)
local _cut_at    = nil    -- wall-clock the current hard cut began, or nil
local _silence_until = 0  -- speak-cut cooldown (no flapping between lines)
-- DSP state (rebuilt per track: rates differ between files)
local _lp        = { 0, 0 }          -- one-pole lowpass memory per channel
local _hp        = { 0, 0 }          -- highpass (low-tracker) memory per channel
local _hp2       = { 0, 0 }          -- second cascaded stage: a real cliff, not a slope
local _hold_v    = { 0, 0 }          -- bitcrush held value per channel
local _hold_n    = 0
local _static    = nil               -- SoundData of the game's own static
local _static_n  = 0
local _static_i  = 0
-- Texture params (0..1) and their targets. Grime EASES (the speakers
-- purchase blooms open); the room is a CUT — walking through a door is
-- instant, so _echo snaps to its target the frame the screen changes.
local _grime, _grime_t = 1, 1
local _grime_sent, _echo_sent, _strain_sent = nil, nil, nil
local _echo,  _echo_t  = 0, 0
-- The focus strain eases like grime (the chain's copy, per chunk); the
-- source's pitch eases on the main thread, per frame.
local _strain, _strain_t = 0, 0
local _pitch = 1
local _speakers_cached = nil
local _owned_count     = -1

-- ─── The decoder thread ────────────────────────────────────────────────
-- Desktop only. The per-sample filter below is the hot loop; on a host with
-- threads it runs in services/music_worker and this file only pops finished
-- SoundData and queues it. The QueueableSource stays here — audio objects
-- belong to one thread — and the inline path below is kept verbatim for the
-- web build, which has no threads.
local _is_web = false
do
    local ok = pcall(require, "ffi")
    if not ok then _is_web = true end
end

local _thread, _ctl, _chunks, _tstate = nil, nil, nil, nil
local _threaded   = false
local _t_track    = nil     -- path the worker is playing
local _t_pending  = 0       -- chunks asked for but not yet arrived

local function startWorker()
    if _threaded then return true end
    if _is_web or not love.thread then return false end
    local ok, th = pcall(love.thread.newThread, "services/music_worker.lua")
    if not ok or not th then return false end
    _ctl     = love.thread.getChannel("poker_music_ctl")
    _chunks  = love.thread.getChannel("poker_music_chunks")
    _tstate  = love.thread.getChannel("poker_music_state")
    th:start()
    _thread, _threaded = th, true
    return true
end

-- ── Setup ──────────────────────────────────────────────────────────────

-- love.math.random is properly seeded per boot (plain math.random is NOT
-- guaranteed to be in LÖVE — it gave the same "shuffle" every launch).
local function rand(n)
    if love and love.math and love.math.random then
        return love.math.random(n)
    end
    return math.random(n)
end

local function shuffle()
    for i = #_playlist, 2, -1 do
        local j = rand(i)
        _playlist[i], _playlist[j] = _playlist[j], _playlist[i]
    end
end

local function scan()
    local ok, items = pcall(love.filesystem.getDirectoryItems, DIR)
    if not ok or not items then return end
    for _, name in ipairs(items) do
        local ext = name:match("%.(%w+)$")
        if ext and EXTS[ext:lower()] then
            _playlist[#_playlist + 1] = DIR .. "/" .. name
        end
    end
    shuffle()
end

local function loadStatic()
    local ok, items = pcall(love.filesystem.getDirectoryItems,
                            "assets/audio/radio/open")
    if ok and items then
        for _, name in ipairs(items) do
            local ext = name:match("%.(%w+)$")
            if ext and EXTS[ext:lower()] then
                local ok2, sd = pcall(love.sound.newSoundData,
                                      "assets/audio/radio/open/" .. name)
                if ok2 and sd then
                    _static = sd
                    _static_n = math.floor(sd:getDuration() * sd:getSampleRate())
                    return
                end
            end
        end
    end
end

local _last_path = nil

local function nextTrack()
    if _src then pcall(function() _src:stop() end) end
    _dec, _src = nil, nil
    if #_playlist == 0 then return end
    _pl_i = _pl_i + 1
    if _pl_i > #_playlist then
        -- Reshuffle for the next lap — and never the same song twice in
        -- a row across the lap boundary.
        _pl_i = 1
        shuffle()
        if #_playlist > 1 and _playlist[1] == _last_path then
            local j = 1 + rand(#_playlist - 1)
            _playlist[1], _playlist[j] = _playlist[j], _playlist[1]
        end
    end
    local path = _playlist[_pl_i]
    _last_path = path

    if _threaded then
        -- The worker opens it and answers with the format; the source is
        -- built when that lands (drainWorker below).
        _t_track, _t_pending = path, 0
        while _chunks:pop() do end          -- drop the old track's tail
        _ctl:push({ cmd = "track", path = path })
        _pos = 0
        return
    end

    local ok = pcall(function()
        _dec = love.sound.newDecoder(path, 8192)
        _rate     = _dec:getSampleRate()
        _channels = _dec:getChannelCount()
        local depth = (love.system and love.system.getOS() == "Web") and 10 or 4
        _src = love.audio.newQueueableSource(_rate, _dec:getBitDepth(),
                                             _channels, depth)
    end)
    if not ok then _dec, _src = nil, nil; return end
    _pos = 0
    _lp, _hp, _hp2, _hold_v, _hold_n = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, 0
end

-- ── DSP ────────────────────────────────────────────────────────────────

-- Mutates the decoded chunk in place. Frame count from duration, which is
-- unambiguous across LÖVE's per-channel/interleaved sample-count quirks.
local function processChunk(sd, dt_chunk)
    local frames = math.floor(sd:getDuration() * sd:getSampleRate() + 0.5)
    -- Ease the texture toward its targets over EASE_SECS, per chunk.
    local k = math.min(1, (dt_chunk or 0.05) / EASE_SECS)
    _grime  = _grime  + (_grime_t  - _grime)  * k
    _strain = _strain + (_strain_t - _strain) * k
    local g, e, s = _grime, _echo, _strain
    if g < 0.003 and e < 0.003 and s < 0.003 then return end   -- clean passthrough

    local cutoff = LP_CLEAN_HZ + (LP_DIRTY_HZ - LP_CLEAN_HZ) * g
    -- Distance: the far room pulls the lowpass down further still.
    cutoff = cutoff + (math.min(cutoff, FAR_LP_HZ) - cutoff) * e
    local alpha  = 1 - math.exp(-2 * math.pi * cutoff / _rate)
    local hp_a   = 1 - math.exp(-2 * math.pi * HP_DIRTY_HZ / _rate)
    local hp_mix = g                    -- how much of the lows the tiny driver loses
    local makeup = 1 + (MAKEUP - 1) * g
    -- The strain drives and crushes on top of the intercom (or the clean
    -- chain): the player over focus, not the speaker.
    local drive  = 1 + DRIVE_MAX * g + STRAIN_DRIVE * s
    local inv_dr = 1 / drive
    local hold_len = 1 + math.floor(CRUSH_HOLD * g + STRAIN_CRUSH * s + 0.5)
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
            -- the tiny driver: no low end (two cascaded low trackers
            -- subtracted — 12dB/oct, an actual cliff under the cutoff)
            _hp[c] = _hp[c] + hp_a * (v - _hp[c])
            v = v - _hp[c] * hp_mix
            _hp2[c] = _hp2[c] + hp_a * (v - _hp2[c])
            v = (v - _hp2[c] * hp_mix) * makeup
            -- soft-clip drive (garish little speaker)
            v = v * drive
            if v > 1 then v = 1 elseif v < -1 then v = -1 end
            v = v * (1.5 - 0.5 * v * v)   -- cubic soft clip
            v = v * inv_dr * (1 + 0.6 * g + 0.4 * s)
            -- muffle
            _lp[c] = _lp[c] + alpha * (v - _lp[c])
            v = _lp[c]
            -- bitcrush sample-hold
            if refresh or hold_len <= 1 then _hold_v[c] = v end
            v = _hold_v[c]
            -- static bed
            v = v + st
            if v > 1 then v = 1 elseif v < -1 then v = -1 end
            sd:setSample(f, c, v)
        end
    end
end

-- ── The director ───────────────────────────────────────────────────────

local function volume()
    return MUSIC_BASE * (1 - GRIME_VOL_CUT * _grime)
                      * (1 - ROOM_VOL_CUT * _echo)
                      * SoundService.getMasterVolume()
                      * SoundService.getMusicVolume()
end

local function ownsSpeakers(state)
    local n = state and state.owned_items and #state.owned_items or 0
    if n ~= _owned_count then
        _owned_count = n
        _speakers_cached = false
        if state and state.owned_items then
            for _, id in ipairs(state.owned_items) do
                if id == "desk_speakers" then _speakers_cached = true break end
            end
        end
    end
    return _speakers_cached
end

function MusicDirector.update(dt, game)
    if not _init then
        _init = true
        if not (love and love.audio and love.filesystem) then return end
        startWorker()
        local ok = pcall(scan)
        if ok and #_playlist > 0 then
            loadStatic()
            nextTrack()
            -- The House gets the first word: on a fresh boot/new game his
            -- opening bubble lands within a couple of frames, so hold the
            -- music back rather than blipping one frame of jazz first.
            _silence_until = love.timer.getTime() + START_GRACE
        end
    end
    if _threaded then
        while true do
            local ev = _tstate:pop()
            if not ev then break end
            if ev.event == "opened" then
                local depth = (love.system and love.system.getOS() == "Web") and 10 or 4
                _rate, _channels = ev.rate, ev.channels
                local ok = pcall(function()
                    _src = love.audio.newQueueableSource(ev.rate, ev.depth,
                                                         ev.channels, depth)
                end)
                if not ok then _src = nil end
                _t_pending = 0
            elseif ev.event == "ended" or ev.event == "failed" then
                nextTrack()
            end
        end
        local err = _thread and _thread:getError()
        if err then
            pcall(print, "[music] worker died (" .. tostring(err)
                  .. "); falling back to the main thread")
            _threaded, _thread = false, nil
            nextTrack()
        end
    end

    if not (_src and game) then return end
    if not _threaded and not _dec then return end

    local now = love.timer.getTime()
    local sm  = game.state_machine
    local screen = sm and sm.current and sm:current() or nil
    local cur    = sm and sm.current_state
    local speakers = ownsSpeakers(game.state)

    -- Where are we, and what should it sound like?
    local want = false
    if screen == "grind" then
        want = true
        _grime_t, _echo_t = speakers and 0 or 1, 0
    elseif screen == "room" or screen == "title" then
        want = true
        _grime_t = speakers and 0 or 1
        _echo_t  = speakers and 0 or 1
    elseif screen == "shove" then
        local ph = cur and cur.view and cur.view.phase
        if ph == "room" then
            want = true
            _grime_t = speakers and 0 or 1
            _echo_t  = speakers and 0 or 1
        end
        -- any later phase: the gauntlet felt. Dead air, on purpose.
    end
    -- The focus strain follows the board on the grind and nowhere else
    -- (main.lua sets it 0 off the grind; this is belt over that).
    _strain_t = (screen == "grind") and SoundService.getStrain() or 0

    -- The music is his to give: nothing plays until the arrival has been
    -- heard through (its last line hands the jazz over). A fresh game is
    -- the House's voice and the room; the music starts when he stops.
    local st = game.state
    if not (st and st.story_seen and st.story_seen.arrival) then want = false end

    -- One channel on the intercom: pre-speakers, the House HAVING THE
    -- FLOOR cuts the music — any bubble on screen, not just the
    -- typewriter window. It stays down for a beat after the bubble goes.
    if not speakers then
        local bubble_up = game.story and game.story.isActive
            and game.story:isActive() and not game.story:isPaused()
            and game.story.currentLine and game.story:currentLine() ~= nil
        if bubble_up then _silence_until = now + SPEAK_RESUME end
        if now < _silence_until then want = false end
    end

    -- The room is a door, not a fade: snap the distance treatment.
    _echo = _echo_t
    if _threaded then
        if _grime_sent ~= _grime_t then
            _grime_sent = _grime_t
            _ctl:push({ cmd = "grime", value = _grime_t })
        end
        if _echo_sent ~= _echo_t then
            _echo_sent = _echo_t
            _ctl:push({ cmd = "echo", value = _echo_t })
        end
        if _strain_sent ~= _strain_t then
            _strain_sent = _strain_t
            _ctl:push({ cmd = "strain", value = _strain_t })
        end
        -- The volume curve reads _grime, which the worker now eases. Track
        -- it here at the same rate so the level moves with the sound.
        _grime = _grime + (_grime_t - _grime) * math.min(1, (dt or 0) / EASE_SECS)
    end

    if not want then
        if not _cut_at then
            _cut_at = now
            pcall(function() _src:setVolume(0) end)   -- frame-instant cut
        end
        return   -- no feeding while cut; the queue drains and waits
    end

    if _cut_at then
        -- The broadcast kept going while we were cut: rejoin it ahead.
        local silent = now - _cut_at
        _cut_at = nil
        local target = _pos / _rate + silent
        if _threaded then
            _ctl:push({ cmd = "seek", pos = target })
            _pos = math.floor(target * _rate)
        else
            local ok = pcall(function() _dec:seek(target) end)
            if ok then _pos = math.floor(target * _rate) end
        end
    end

    pcall(function() _src:setVolume(volume()) end)

    -- The strain slows the music with the tables: the pitch eases toward
    -- the board's speed (held at PITCH_MIN), then a slow wow rides on it
    -- by however much of the strain has arrived. A slower source also
    -- drains its queue slower; the feed below reads free buffers, so it
    -- simply asks for less.
    do
        local pitch_t = math.max(PITCH_MIN, 1 - (1 - PITCH_MIN) * _strain_t)
        _pitch = _pitch + (pitch_t - _pitch) * math.min(1, (dt or 0) / EASE_SECS)
        local s_now = (1 - _pitch) / (1 - PITCH_MIN)
        local p = _pitch * (1 + WOW_DEPTH * s_now * math.sin(2 * math.pi * WOW_HZ * now))
        pcall(function() _src:setPitch(p) end)
    end

    -- Feed. Each drained buffer gets decoded, dirtied, and queued back.
    if _threaded then
        -- Pop whatever the worker finished and hand it to the source. No
        -- decoding and no filtering on this thread.
        local free = _src:getFreeBufferCount()
        while free > 0 do
            local item = _chunks:pop()
            if not item then break end
            _t_pending = math.max(0, _t_pending - 1)
            _pos = item.pos or _pos
            if not pcall(function() _src:queue(item.data) end) then return end
            _src:play()
            free = free - 1
        end
        -- Ask for enough to keep the queue full, counting what is already
        -- in flight so the request does not pile up.
        local want = free - _t_pending
        if want > 0 then
            _ctl:push({ cmd = "want", n = want })
            _t_pending = _t_pending + want
        end
        return
    end

    local guard = 0
    while _src:getFreeBufferCount() > 0 and guard < 16 do
        guard = guard + 1
        local ok, chunk = pcall(function() return _dec:decode() end)
        if not ok then nextTrack(); return end
        if not chunk then nextTrack(); return end   -- track over → next
        local frames = math.floor(chunk:getDuration() * chunk:getSampleRate() + 0.5)
        pcall(processChunk, chunk, frames / _rate)
        _pos = _pos + frames
        local qok = pcall(function() _src:queue(chunk) end)
        if not qok then return end
        _src:play()
    end
end

return MusicDirector
