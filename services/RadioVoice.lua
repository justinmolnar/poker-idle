-- services/RadioVoice.lua
--
-- The intercom's voice. The House doesn't have one — it has a speaker,
-- static, and something that might be words underneath. Two kinds of
-- clips live in assets/audio/radio/ (any of mp3/ogg/wav/flac):
--
--   open/   mic keying on. Every speech bubble starts with a SHORT
--           random chunk grabbed from a random file in here — never the
--           same key-up twice.
--   voice/  distorted voice/static beds. While the bubble's text is
--           typing out (the "speaking" window), one plays CHOPPED: the
--           playhead jars to a random position every second or so, with
--           a little pitch drift per chunk, so it never resolves into
--           anything. The moment the text is done, it cuts to silence.
--
-- No files, no folder → the module is inert; everything else about the
-- speech system works silently. Volume follows SoundService's master.
--
-- Driven by views/StoryView (lineStarted() when a new block lands) and
-- main.lua (update(dt, speaking) every frame).

local SoundService = require("services.SoundService")

local RadioVoice = {}

local DIR       = "assets/audio/radio"
local EXTS      = { mp3 = true, ogg = true, wav = true, flac = true }
local VOL_OPEN  = 0.85
local VOL_VOICE = 0.70
local OPEN_MIN  = 0.20   -- seconds of key-up static per bubble
local OPEN_MAX  = 0.50
local CHUNK_MIN = 0.35   -- seconds a voice chunk survives before it jars
local CHUNK_MAX = 1.0
local PITCH_LO  = 0.90   -- per-chunk drift: never the same mumble twice
local PITCH_HI  = 1.10

local _loaded  = false
local _opens   = {}   -- { source, ... }
local _voices  = {}   -- { source, ... }
local _voice   = nil  -- the bed picked for the current line
local _open    = nil  -- the open currently keying (runs out on its own)
local _open_left  = 0 -- seconds of open chunk remaining
local _open_block = 0 -- seconds until the voice may start
local _chunk_t    = 0 -- seconds left in the current voice chunk
local _speaking   = false

local function scanDir(dir, bucket)
    local ok, items = pcall(love.filesystem.getDirectoryItems, dir)
    if not ok or not items then return end
    for _, name in ipairs(items) do
        local ext = name:match("%.(%w+)$")
        if ext and EXTS[ext:lower()] then
            local ok2, src = pcall(love.audio.newSource,
                                   dir .. "/" .. name, "static")
            if ok2 and src then bucket[#bucket + 1] = src end
        end
    end
end

local function load()
    if _loaded then return end
    _loaded = true
    if not (love and love.filesystem and love.audio) then return end
    scanDir(DIR .. "/open", _opens)
    scanDir(DIR .. "/voice", _voices)
end

-- Silence the voice bed (the open, if one is keying, finishes its chunk).
function RadioVoice.stop()
    if _voice and _voice:isPlaying() then _voice:stop() end
    _speaking = false
end

-- A new speech bubble landed: key the mic with a short random chunk of a
-- random open, pick the voice bed this line will mumble through, and
-- hold the chopper until the key-up has played.
function RadioVoice.lineStarted()
    load()
    RadioVoice.stop()
    if _open and _open:isPlaying() then _open:stop() end
    _open, _open_left, _open_block = nil, 0, 0
    if #_opens > 0 then
        _open = _opens[math.random(#_opens)]
        _open:stop()
        local chunk = OPEN_MIN + math.random() * (OPEN_MAX - OPEN_MIN)
        local d = _open:getDuration() or 0
        if d > chunk + 0.05 then
            _open:seek(math.random() * (d - chunk))
        end
        _open:setVolume(VOL_OPEN * SoundService.getMasterVolume() * SoundService.getSfxVolume())
        _open:play()
        _open_left  = chunk
        _open_block = chunk
    end
    if #_voices > 0 then
        _voice = _voices[math.random(#_voices)]
    end
    _chunk_t = 0
end

-- `speaking` = the bubble's text is mid-typewriter. While true the voice
-- bed plays in jarred chunks; the frame it goes false, silence. The open
-- chunk runs on its own clock so a one-word line doesn't clip the key-up.
function RadioVoice.update(dt, speaking)
    dt = dt or 0
    if _open then
        _open_left = _open_left - dt
        if _open_left <= 0 then
            if _open:isPlaying() then _open:stop() end
            _open = nil
        end
    end
    if _open_block > 0 then _open_block = _open_block - dt end

    if not speaking then
        if _speaking then RadioVoice.stop() end
        return
    end
    _speaking = true
    if not _voice or _open_block > 0 then return end

    _chunk_t = _chunk_t - dt
    if _chunk_t <= 0 or not _voice:isPlaying() then
        local d = _voice:getDuration() or 0
        if d > 0.1 then
            _voice:seek(math.random() * math.max(0.01, d - 1.0))
        end
        _voice:setPitch(PITCH_LO + math.random() * (PITCH_HI - PITCH_LO))
        _voice:setVolume(VOL_VOICE * SoundService.getMasterVolume() * SoundService.getSfxVolume())
        if not _voice:isPlaying() then _voice:play() end
        _chunk_t = CHUNK_MIN + math.random() * (CHUNK_MAX - CHUNK_MIN)
    end
end

return RadioVoice
