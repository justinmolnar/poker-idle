-- services/AudioDevice.lua
--
-- Follow Windows' default audio output. LÖVE 12 raises `audiodisconnected`
-- only when the device it opened reports DISCONNECTED (ALC_CONNECTED goes
-- false). Headphones powering off, a Bluetooth set dropping, or the user
-- switching the default in Windows usually leaves the old endpoint
-- registered and merely changes the DEFAULT, so nothing fires and sound
-- keeps going into a device nobody is listening to. This polls the two
-- names LÖVE 12 exposes — the system default (first in getPlaybackDevices)
-- and the device actually open (getPlaybackDevice) — and reopens onto the
-- default whenever they diverge. setPlaybackDevice() with no argument is
-- the default device, and 12 reopens in place (alcReopenDeviceSOFT), so
-- every Source keeps playing across the switch.
--
-- On LÖVE 11 none of these functions exist and this is inert.

local AudioDevice = {}

local POLL_SECS     = 1.0    -- how often to compare the two names
local SETTLE_SECS   = 2.5    -- hold-off after a reopen (Windows renumbers)
local _t            = 0
local _hold         = 0
local _supported    = nil    -- decided on first tick

local function supported()
    if _supported == nil then
        _supported = love and love.audio
            and type(love.audio.getPlaybackDevices) == "function"
            and type(love.audio.getPlaybackDevice)  == "function"
            and type(love.audio.setPlaybackDevice)  == "function" or false
    end
    return _supported
end

-- The system default output's name, or nil when the engine can't say.
local function defaultName()
    local ok, list = pcall(love.audio.getPlaybackDevices)
    if ok and type(list) == "table" and list[1] and list[1] ~= "" then
        return list[1]
    end
    return nil
end

local function currentName()
    local ok, name = pcall(love.audio.getPlaybackDevice)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- Reopen onto the default. Returns true if a reopen was attempted.
function AudioDevice.reopen(reason)
    if not supported() then return false end
    local ok, err = pcall(love.audio.setPlaybackDevice)
    pcall(print, ("[audio] %s: reopened onto the default output (%s)")
        :format(reason or "reopen", ok and (currentName() or "?") or ("failed: " .. tostring(err))))
    _hold = SETTLE_SECS
    return ok
end

function AudioDevice.tick(dt)
    if not supported() then return end
    if _hold > 0 then _hold = _hold - (dt or 0); return end
    _t = _t + (dt or 0)
    if _t < POLL_SECS then return end
    _t = 0
    local want, have = defaultName(), currentName()
    if want and have and want ~= have then
        pcall(print, ("[audio] default output changed: %q -> %q"):format(have, want))
        AudioDevice.reopen("default changed")
    end
end

return AudioDevice
