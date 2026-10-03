-- services/MusicLayers.lua
--
-- Looping beds under (or instead of) the music, each a streamed Source of
-- its own (assets/audio/layers/, credited in its MANIFEST). Not in
-- assets/audio/music/: MusicDirector plays every file there as a track.
-- Driven from main.lua right after MusicDirector.update, so a bed plays
-- even with no music loaded.
--
--   hiss   the vinyl bed: Act 3 (the second runout won) on the grind and
--          in the room, quiet, louder once the bankroll has underflowed
--   drone  the gauntlet's low tone: the shove past its room phase (the
--          director's dead air), a step up in pitch per runout result shown
--
-- Levels ride the music volume (MusicDirector's MUSIC_BASE times master
-- and music), and ease in and out over FADE seconds. On the grind the hiss
-- slows with the focus strain like everything else.

local SoundService = require("services.SoundService")
local ShoveRate    = require("models.shove_rate")

local MusicLayers = {}

local MUSIC_BASE = 0.4      -- services/MusicDirector's base level
local FADE       = 0.5
local DIR        = "assets/audio/layers/"

local LAYERS = {
    hiss  = { file = DIR .. "hiss.ogg",           level = 0.35, level_broken = 0.8 },
    drone = { file = DIR .. "gauntlet_drone.ogg", level = 0.55,
              -- One step per runout result shown: none, one, two, three.
              steps = { 1.0, 1.06, 1.12, 1.18 } },
}
local ORDER = { "hiss", "drone" }
-- The strain's pitch floor (data/sounds _mix.strain pitch_min).
local STRAIN_PITCH_MIN = 0.5

local _src, _vol = {}, {}

local function source(name)
    local s = _src[name]
    if s == nil then
        local ok, made = pcall(love.audio.newSource, LAYERS[name].file, "stream")
        s = ok and made or false
        if s then s:setLooping(true) end
        _src[name] = s
    end
    return s or nil
end

-- What each bed wants this frame: a level 0..1 and a pitch.
local function wants(game)
    local sm     = game.state_machine
    local screen = sm and sm.current and sm:current() or nil
    local cur    = sm and sm.current_state
    local st     = game.state or {}
    local hiss, drone, drone_pitch, hiss_pitch = 0, 0, 1, 1

    if st.shove_r2_won and (screen == "grind" or screen == "room") then
        hiss = ShoveRate.underflowed(st.bankroll) and LAYERS.hiss.level_broken or LAYERS.hiss.level
        if screen == "grind" then
            hiss_pitch = 1 - (1 - STRAIN_PITCH_MIN) * (SoundService.getStrain() or 0)
        end
    end

    if screen == "shove" then
        local view = cur and cur.view
        local ph = view and view.phase
        if ph and ph ~= "room" then
            drone = LAYERS.drone.level
            local shown = 0
            for _, v in ipairs(view.chip_visible or {}) do if v then shown = shown + 1 end end
            local steps = LAYERS.drone.steps
            drone_pitch = steps[math.min(#steps, shown + 1)]
        end
    end
    return hiss, hiss_pitch, drone, drone_pitch
end

function MusicLayers.update(dt, game)
    if not (love and love.audio and game) then return end
    local hiss, hiss_pitch, drone, drone_pitch = wants(game)
    local target = { hiss = hiss, drone = drone }
    local pitch  = { hiss = hiss_pitch, drone = drone_pitch }
    local gain = MUSIC_BASE * SoundService.getMasterVolume() * SoundService.getMusicVolume()
    local step = math.min(1, (dt or 0) / FADE)
    for _, name in ipairs(ORDER) do
        local v = _vol[name] or 0
        v = v + (target[name] - v) * step
        if target[name] == 0 and v < 0.002 then v = 0 end
        _vol[name] = v
        if v > 0 then
            local s = source(name)
            if s then
                s:setVolume(v * gain)
                s:setPitch(pitch[name])
                if not s:isPlaying() then s:play() end
            end
        else
            local s = _src[name]
            if s and s:isPlaying() then s:pause() end
        end
    end
end

-- Silence every bed now (a debug wipe, quitting).
function MusicLayers.stopAll()
    for name, s in pairs(_src) do
        if s then s:stop() end
        _vol[name] = 0
    end
end

return MusicLayers
