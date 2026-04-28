-- services/SoundService.lua
-- Programmatic sound effects via PCM tone synthesis. No external audio files.
--
-- Two interaction modes:
--   • SoundService.play("beep", 0.5) — direct play of a built-in synth `kind`.
--   • SoundService.playNamed("hand_won") — looks up data/sounds.lua, which
--     maps a semantic name → { kind, volume }. This is the preferred path
--     for game code so call sites don't hardcode synthesis details.

local SoundService = {}

local Sounds = require("data.sounds")

-- ── State ────────────────────────────────────────────────────────────────────

local _sources = {}   -- { [kind] = love.audio.Source }
local _master  = 1.0  -- master volume 0–1

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

-- Look up a semantic name in data/sounds.lua and play it. This is what game
-- code should call: `SoundService.playNamed("hand_won")`.
function SoundService.playNamed(name)
    local def = Sounds[name]
    if not def then return end
    SoundService.play(def.kind, def.volume)
end

function SoundService.stopAll()
    for _, src in pairs(_sources) do
        if src:isPlaying() then src:stop() end
    end
end

function SoundService.setMasterVolume(vol)
    _master = math.max(0, math.min(1, vol))
end

return SoundService
