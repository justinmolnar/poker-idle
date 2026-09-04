-- services/Display.lua
--
-- Window mode + resolution for the desktop build. The web build's canvas is
-- the iframe and nothing here applies to it (isDesktop is false there, and
-- every caller gates on it). Three modes:
--
--   windowed    a resizable window at display_w × display_h
--   borderless  fullscreen at the desktop size (LÖVE's "desktop" type)
--   fullscreen  exclusive fullscreen at display_w × display_h, which must be
--               one of the monitor's own modes (modes() lists them)
--
-- Settings keys (g.settings, merge-written by SettingsModal's persist):
-- display_mode, display_w, display_h. defaults() fills any that are missing
-- or invalid, so an old settings.save with none of them boots windowed at
-- the conf.lua size.
--
-- Whatever the window ends up as, main.lua's dynamic base width follows it
-- (love.resize fires after a successful setMode), so no mode shows bars
-- wider than 16:9 and none changes the UI scale.
--
-- Only setMode / getMode / getFullscreenModes / getDesktopDimensions are
-- used, with the flags both LÖVE 11 and 12 accept (no display/displayindex,
-- no highdpi: DPI is decided at boot in conf.lua).

local Display = {}

Display.MODES = { "windowed", "borderless", "fullscreen" }
Display.MODE_LABELS = {
    windowed   = "Windowed",
    borderless = "Borderless",
    fullscreen = "Fullscreen",
}

local DEFAULT_W, DEFAULT_H = 1600, 900
-- Smallest window offered. Below the 1600-wide base frame the whole frame
-- scales down through main.lua's sharp-bilinear blit; 1280×720 is 0.8×,
-- still readable. Mirrors conf.lua's minwidth/minheight.
local MIN_W, MIN_H = 1280, 720

local function isMode(m)
    for _, k in ipairs(Display.MODES) do if k == m then return true end end
    return false
end

function Display.isDesktop()
    if not (love and love.window and love.window.setMode) then return false end
    local os_name = love.system and love.system.getOS and love.system.getOS() or ""
    return os_name ~= "Web" and os_name ~= "Emscripten"
end

-- Fill missing / invalid keys in place. Returns the same table.
function Display.defaults(settings)
    if not isMode(settings.display_mode) then settings.display_mode = "windowed" end
    local w, h = tonumber(settings.display_w), tonumber(settings.display_h)
    if not (w and h and w >= MIN_W and h >= MIN_H) then
        w, h = DEFAULT_W, DEFAULT_H
    end
    settings.display_w, settings.display_h = math.floor(w), math.floor(h)
    return settings
end

-- One dropdown value per size: "1920x1080". modes() and the picker speak
-- these strings; Display.parseSize turns one back into numbers.
function Display.sizeKey(w, h) return string.format("%dx%d", w, h) end

function Display.parseSize(key)
    local w, h = tostring(key or ""):match("^(%d+)x(%d+)$")
    if not w then return nil end
    return tonumber(w), tonumber(h)
end

local function desktopSize()
    local ok, dw, dh = pcall(love.window.getDesktopDimensions, 1)
    if ok and dw and dh and dw > 0 and dh > 0 then return dw, dh end
    return nil
end

-- The sizes the primary display supports, largest first, plus the desktop
-- size and the current setting so the picker always shows what's active.
-- Each entry: { w, h, label, value } where value is sizeKey(w, h).
function Display.modes(settings)
    local seen, out = {}, {}
    local function add(w, h)
        if not (w and h) then return end
        w, h = math.floor(w), math.floor(h)
        if w < MIN_W or h < MIN_H then return end
        local key = Display.sizeKey(w, h)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { w = w, h = h, value = key, label = string.format("%d x %d", w, h) }
    end
    local ok, list = pcall(love.window.getFullscreenModes, 1)
    if ok and type(list) == "table" then
        for _, m in ipairs(list) do add(m.width, m.height) end
    end
    add(desktopSize())
    add(DEFAULT_W, DEFAULT_H)
    if settings then add(settings.display_w, settings.display_h) end
    table.sort(out, function(a, b)
        if a.w ~= b.w then return a.w > b.w end
        return a.h > b.h
    end)
    return out
end

local function wantedFlags(mode)
    if mode == "borderless" then return true, "desktop" end
    if mode == "fullscreen" then return true, "exclusive" end
    return false, nil
end

-- True when the live window already is what the settings ask for, so boot
-- with the default settings never re-creates the window conf.lua opened.
local function matches(settings)
    local ok, w, h, flags = pcall(love.window.getMode)
    if not (ok and flags) then return false end
    local fs, kind = wantedFlags(settings.display_mode)
    if (flags.fullscreen or false) ~= fs then return false end
    if fs then
        if flags.fullscreentype ~= kind then return false end
        if kind == "desktop" then return true end
    end
    return w == settings.display_w and h == settings.display_h
end

local function setMode(mode, w, h)
    local flags = {
        vsync     = 1,
        minwidth  = MIN_W,
        minheight = MIN_H,
        resizable = true,
    }
    if mode == "borderless" then
        flags.fullscreen, flags.fullscreentype = true, "desktop"
        local dw, dh = desktopSize()
        w, h = dw or w, dh or h
    elseif mode == "fullscreen" then
        flags.fullscreen, flags.fullscreentype = true, "exclusive"
        flags.resizable = false
    else
        flags.fullscreen = false
    end
    return love.window.setMode(w, h, flags)
end

-- Apply the settings to the window. On failure (a size the display can't
-- do exclusively, a driver refusal) fall back to windowed 1600×900, write
-- that into the settings, and return false so the caller persists the
-- fallback rather than retrying the broken mode next boot.
function Display.apply(settings)
    if not Display.isDesktop() then return false end
    Display.defaults(settings)
    if matches(settings) then return true end
    local ok, res = pcall(setMode, settings.display_mode, settings.display_w, settings.display_h)
    if ok and res ~= false then return true end
    pcall(print, ("[display] %s %dx%d failed (%s); falling back to windowed %dx%d")
        :format(settings.display_mode, settings.display_w, settings.display_h,
                ok and "refused" or tostring(res), DEFAULT_W, DEFAULT_H))
    settings.display_mode = "windowed"
    settings.display_w, settings.display_h = DEFAULT_W, DEFAULT_H
    pcall(setMode, "windowed", DEFAULT_W, DEFAULT_H)
    return false
end

-- Change one or more keys, apply, persist. `changes` is a partial
-- { display_mode=, display_w=, display_h= }. Persisting goes through the
-- same merge-write every other setting uses so nothing else is wiped.
function Display.commit(settings, save_service, changes)
    if not (settings and Display.isDesktop()) then return false end
    for k, v in pairs(changes or {}) do settings[k] = v end
    local ok = Display.apply(settings)
    if save_service and save_service.saveSettings then
        save_service:saveSettings(settings)
    end
    return ok
end

-- The mode after `mode` in MODES order, wrapping.
function Display.nextMode(mode)
    for i, k in ipairs(Display.MODES) do
        if k == mode then return Display.MODES[i % #Display.MODES + 1] end
    end
    return Display.MODES[1]
end

-- F11: borderless <-> windowed.
function Display.toggleBorderless(settings, save_service)
    local next_mode = settings.display_mode == "borderless" and "windowed" or "borderless"
    return Display.commit(settings, save_service, { display_mode = next_mode })
end

return Display
