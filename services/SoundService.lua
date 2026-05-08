-- services/SoundService.lua
-- Sound effects. Two backends:
--   • PCM synth — built-in `kind`s (beep, chime, horn, warning, success, fail)
--     synthesized once and cached. No external audio files.
--   • File playback — load a sound file (.mp3, .wav, .ogg) once and clone the
--     source per play so successive triggers don't cut each other off.
--
-- Two interaction modes:
--   • SoundService.play("beep", 0.5)         — direct synth play.
--   • SoundService.playFile("a/b.mp3", 0.7)  — direct file play.
--   • SoundService.playNamed("event_name")    — looks up data/sounds.lua,
--     which maps a semantic name → { file=…, volume } OR { kind=…, volume }.
--     This is the preferred path for game code so call sites don't hardcode
--     synthesis details or asset paths.

local SoundService = {}

local Sounds = require("data.sounds")

-- ── State ────────────────────────────────────────────────────────────────────

local _sources      = {}   -- { [kind] = love.audio.Source }   for synth
local _file_sources = {}   -- { [path] = love.audio.Source }   prototype/cloned per play
-- Per-path clone pool: each play reuses the first idle clone, falling
-- back to a fresh clone only when every existing clone is still mid-
-- playback. Memory plateaus at the peak number of concurrent overlapping
-- plays per file; without this, every fire-and-forget play allocated a
-- new Source (hundreds per dense burst) and held the WebAudio node alive until
-- the browser GC caught up. Browser-side that GC was lazy enough to
-- compound with other heap pressure into observable lag.
local _clone_pool   = {}   -- { [path] = { source, source, ... } }
local _master       = 1.0  -- master volume 0–1

-- ── Tone generators ──────────────────────────────────────────────────────────

local SR = 44100  -- sample rate (Hz)

local function makeSine(freq, duration, vol)
    local n  = math.floor(SR * duration)
    local sd = love.sound.newSoundData(n, SR, 16, 1)
    for i = 0, n - 1 do
        local t    = i / SR
        local fade = math.min(1.0, (n - i) / (SR * 0.04))  -- 40 ms fade-out
        sd:setSample(i, math.sin(2 * math.pi * freq * t) * vol * fade)
    end
    return sd
end

local function makeSweep(f1, f2, duration, vol)
    local n     = math.floor(SR * duration)
    local sd    = love.sound.newSoundData(n, SR, 16, 1)
    local phase = 0.0
    for i = 0, n - 1 do
        local t    = i / n
        local freq = f1 + (f2 - f1) * t
        phase      = phase + 2 * math.pi * freq / SR
        local fade = math.min(1.0, (n - i) / (SR * 0.04))
        sd:setSample(i, math.sin(phase) * vol * fade)
    end
    return sd
end

local function makeSequence(freqs, each_dur, vol)
    local seg   = math.floor(SR * each_dur)
    local total = seg * #freqs
    local sd    = love.sound.newSoundData(total, SR, 16, 1)
    for part, freq in ipairs(freqs) do
        local off = (part - 1) * seg
        for i = 0, seg - 1 do
            local t    = i / SR
            local fade = math.min(1.0, (seg - i) / (SR * 0.03))
            sd:setSample(off + i, math.sin(2 * math.pi * freq * t) * vol * fade)
        end
    end
    return sd
end

-- ── Built-in synth kinds ─────────────────────────────────────────────────────

local DEFS = {
    beep    = function() return makeSine(880, 0.08, 0.45) end,
    chime   = function() return makeSine(660, 0.28, 0.35) end,
    horn    = function() return makeSine(330, 0.20, 0.50) end,
    warning = function() return makeSweep(480, 220, 0.40, 0.40) end,
    success = function() return makeSequence({523, 659, 784}, 0.10, 0.35) end,
    fail    = function() return makeSequence({784, 523, 392}, 0.10, 0.35) end,
}

-- ── Public API ───────────────────────────────────────────────────────────────

function SoundService.getKinds()
    local t = {}
    for k in pairs(DEFS) do t[#t+1] = k end
    table.sort(t)
    return t
end

-- Play a synth kind directly. Used by playNamed under the hood.
function SoundService.play(kind, volume_mult)
    local def = DEFS[kind]
    if not def then return end

    if not _sources[kind] then
        local ok, result = pcall(function()
            return love.audio.newSource(def(), "static")
        end)
        if not ok or not result then return end
        _sources[kind] = result
    end

    local src = _sources[kind]
    if src:isPlaying() then src:stop() end
    src:setVolume(math.max(0, math.min(1, (volume_mult or 1.0) * _master)))
    src:play()
end

-- Play a file-based sound. The base source is cached by path; each play
-- clones it so overlapping triggers (e.g. successive card-deal beats) don't
-- cut each other off. Cheap — clone reuses the same SoundData.
function SoundService.playFile(path, volume_mult)
    if not path then return end
    local base = _file_sources[path]
    if not base then
        local ok, src = pcall(love.audio.newSource, path, "static")
        if not ok or not src then return end
        _file_sources[path] = src
        base = src
    end
    local pool = _clone_pool[path]
    if not pool then pool = {}; _clone_pool[path] = pool end
    -- Reuse the first non-playing clone in the pool. New clone only if
    -- all existing ones are mid-playback (overlapping plays).
    local s
    for i = 1, #pool do
        if not pool[i]:isPlaying() then s = pool[i]; break end
    end
    if not s then
        s = base:clone()
        pool[#pool + 1] = s
    end
    s:setVolume(math.max(0, math.min(1, (volume_mult or 1.0) * _master)))
    s:stop()
    s:play()
end

-- Recursive playback of a sound-table entry. Entry shapes accepted:
--   { file = "path",                    volume = v }   -- single file
--   { files = { "p1", "p2", ... },      volume = v }   -- random pick per play
--   { kind = "beep" | "chime" | ...,    volume = v }   -- built-in synth
-- Any of the above may carry `layer = { ...sub-entry... }` for a secondary
-- sound played alongside (e.g. an ambient loop layered under a click).
-- Recursion lets layers themselves carry layers, but in practice we only use
-- a single level of nesting.
local function playEntry(entry, vol_mult)
    if not entry then return end
    vol_mult = vol_mult or 1.0
    local v  = (entry.volume or 1) * vol_mult
    if entry.files and #entry.files > 0 then
        local pick = entry.files[love.math.random(1, #entry.files)]
        SoundService.playFile(pick, v)
    elseif entry.file then
        SoundService.playFile(entry.file, v)
    elseif entry.kind then
        SoundService.play(entry.kind, v)
    end
    if entry.layer then playEntry(entry.layer, vol_mult) end
end

-- Look up a semantic name in data/sounds.lua and play it. Optional opts:
--   opts.volume_mult — multiplier on the data-table's `volume` field.
--                      Used for tier-scaled feedback (quiet on Small,
--                      louder on Jackpot) without duplicating sound
--                      entries per tier.
function SoundService.playNamed(name, opts)
    local vol_mult = (opts and opts.volume_mult) or 1.0
    playEntry(Sounds[name], vol_mult)
end

function SoundService.stopAll()
    for _, src in pairs(_sources) do
        if src:isPlaying() then src:stop() end
    end
    for _, src in pairs(_file_sources) do
        if src:isPlaying() then src:stop() end
    end
    for _, pool in pairs(_clone_pool) do
        for i = 1, #pool do
            if pool[i]:isPlaying() then pool[i]:stop() end
        end
    end
end

function SoundService.setMasterVolume(vol)
    _master = math.max(0, math.min(1, vol))
end

function SoundService.getMasterVolume()
    return _master
end

return SoundService
