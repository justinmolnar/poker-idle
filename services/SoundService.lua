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
-- Discovered sounds (services/SoundLoader) sit behind data/sounds.lua: a
-- name with no preset plays the file that shares its name, following
-- sprite aliases from `_alias_source.aliases` when one is attached.
local _loader       = nil
local _alias_source = nil
local _mix          = Sounds._mix or {}
local _damage       = 0          -- 0..1, the global damage bus (underflow)
local _last_play    = {}         -- name -> time of its last play (opts.min_gap)
local _efx_ready    = nil        -- nil untried, true set up, false unavailable

-- The OpenAL distortion effect, set up once and only where it exists
-- (desktop yes, love.js no). A failure just means the cheap damage.
local function efxReady()
    if _efx_ready ~= nil then return _efx_ready end
    local d = _mix.damage and _mix.damage.efx
    local ok = d and love.audio and love.audio.setEffect
        and pcall(love.audio.setEffect, "damage", d)
    _efx_ready = ok and true or false
    return _efx_ready
end

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
function SoundService.attachLoader(loader, alias_source)
    _loader       = loader
    _alias_source = alias_source
end

-- True when `name` is a preset or a discovered file.
function SoundService.has(name)
    if Sounds[name] then return true end
    local aliases = _alias_source and _alias_source.aliases
    return _loader ~= nil and _loader:has(name, aliases)
end

-- Global damage 0..1: everything played sounds broken (the underflow).
function SoundService.setDamage(level)
    _damage = math.max(0, math.min(1, level or 0))
end

function SoundService.getDamage()
    return _damage
end

local function rnd(lo, hi)
    local r = (love.math and love.math.random) or math.random
    return lo + (hi - lo) * r()
end

function SoundService.playFile(path, volume_mult, pitch, damaged)
    if not path then return end
    local dmg = _mix.damage
    local level = math.max(_damage, damaged and 1 or 0)
    if level > 0 and dmg then
        if rnd(0, 1) < dmg.dropout * level then return end     -- swallowed
        pitch = (pitch or 1.0) * (1 + rnd(-dmg.pitch_wobble, dmg.pitch_wobble) * level)
        volume_mult = (volume_mult or 1.0) * (1 - (1 - dmg.volume) * level)
    end
    -- Nothing repeats identically.
    local j = _mix.pitch_jitter or 0
    if j > 0 then pitch = (pitch or 1.0) * (1 + rnd(-j, j)) end
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
    if s.setPitch then s:setPitch(pitch or 1.0) end
    if s.setEffect then
        if level > 0 and efxReady() then pcall(s.setEffect, s, "damage")
        elseif _efx_ready then pcall(s.setEffect, s, "damage", false) end
    end
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
local function playEntry(entry, vol_mult, pitch, damaged)
    if not entry then return end
    vol_mult = vol_mult or 1.0
    local v  = (entry.volume or 1) * vol_mult
    if entry.pitch then pitch = (pitch or 1.0) * entry.pitch end
    if entry.files and #entry.files > 0 then
        local pick = entry.files[love.math.random(1, #entry.files)]
        SoundService.playFile(pick, v, pitch, damaged)
    elseif entry.file then
        SoundService.playFile(entry.file, v, pitch, damaged)
    elseif entry.kind then
        SoundService.play(entry.kind, v)
    end
    if entry.layer then playEntry(entry.layer, vol_mult, pitch, damaged) end
end

-- Pitch for step `i` of an accelerating sequence of `n` steps: `from` at
-- the first step rising to `to` at the last. Every sequence that speeds up
-- (a chip pour, a count, a flood of cards) uses this so they all rise the
-- same way; the numbers live with the sequence's other timings in data.
function SoundService.rampPitch(i, n, from, to)
    from, to = from or 1.0, to or 1.5
    if not n or n <= 1 then return from end
    local t = math.max(0, math.min(1, (i - 1) / (n - 1)))
    return from + (to - from) * t
end

-- Look up a semantic name in data/sounds.lua and play it. Optional opts:
--   opts.volume_mult — multiplier on the data-table's `volume` field.
--                      Used for tier-scaled feedback (quiet on Small,
--                      louder on Jackpot) without duplicating sound
--                      entries per tier.
--   opts.pitch       — playback pitch (1 = as recorded); presets and
--                      discovered files alike. See rampPitch.
--   opts.damaged     — play through the damage bus (a corrupted item).
--   opts.min_gap     — seconds; a play of the same name inside this
--                      window is skipped (returns false). Falls back to
--                      the sound entry's own `min_gap`, so a sound that
--                      should never machine-gun can say so once in
--                      data/sounds.lua instead of at every call site.
function SoundService.playNamed(name, opts)
    if name == "_mix" then return false end
    local entry = Sounds[name]
    local gap = (opts and opts.min_gap) or (entry and entry.min_gap)
    if gap and gap > 0 and love.timer then
        local now = love.timer.getTime()
        if _last_play[name] and now - _last_play[name] < gap then return false end
        _last_play[name] = now
    end
    local vol_mult = (opts and opts.volume_mult) or 1.0
    local pitch    = opts and opts.pitch
    local damaged  = opts and opts.damaged
    if entry then
        playEntry(entry, vol_mult, pitch, damaged)
        return true
    end
    if _loader then
        local aliases = _alias_source and _alias_source.aliases
        local path = _loader:resolve(name, aliases)
        if path then
            SoundService.playFile(path, vol_mult, pitch, damaged)
            return true
        end
    end
    return false
end

-- Stop every playing clone of a named sound (its files and its layers):
-- a hum that must end when its source does.
function SoundService.stopNamed(name)
    local function stopEntry(entry)
        if not entry then return end
        local files = entry.files or (entry.file and { entry.file }) or {}
        for _, path in ipairs(files) do
            for _, s in ipairs(_clone_pool[path] or {}) do
                if s:isPlaying() then s:stop() end
            end
        end
        if entry.layer then stopEntry(entry.layer) end
    end
    local entry = Sounds[name]
    if entry then stopEntry(entry); return end
    local aliases = _alias_source and _alias_source.aliases
    local path = _loader and _loader:resolve(name, aliases)
    if path then
        for _, s in ipairs(_clone_pool[path] or {}) do
            if s:isPlaying() then s:stop() end
        end
    end
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
