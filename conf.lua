-- Mark the process as DPI-aware on Windows BEFORE the window gets
-- created. Without this, Windows transparently scales the window by
-- the system DPI factor (e.g. 175%), so a requested 1600×900 window
-- balloons to 2800×1575 actual pixels. With this flag, the window
-- opens at the requested physical pixel size — px is px.
--
-- love.window.highdpi alone is not enough; the OS still sees the
-- process as DPI-unaware and applies its own scaling layer. The FFI
-- call below toggles the per-process DPI awareness flag at runtime,
-- which is the same thing a manifest in love.exe would do.
-- love.js (browser) ships no FFI. Failed pcall(require, "ffi") = web build.
local IS_WEB = false
do
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        IS_WEB = true
    elseif ffi.os == "Windows" then
        pcall(function()
            ffi.cdef[[ int SetProcessDPIAware(); ]]
            ffi.load("user32").SetProcessDPIAware()
        end)
    end
end

function love.conf(t)
    t.identity = "poker-idle"
    t.version  = "11.4"
    t.console  = true

    t.window.title      = "Poker Idle"
    -- Default opens at 1600×900 — enough horizontal room for the
    -- chunky pixel font's sidebar buttons (heading + right-aligned
    -- level fit without colliding). Smaller than this the layout's
    -- dynamic-percentage sidebars get squeezed.
    -- 1600x900 on both. Web build uses itch's "click to launch in
    -- fullscreen" embed mode — the iframe takes the whole viewport
    -- and the canvas CSS-scales to fit (object-fit: contain in
    -- index.html). Internal render stays at the layout's design size.
    t.window.width      = 1600
    t.window.height     = 900
    t.window.minwidth   = 1600
    t.window.minheight  = 900
    t.window.resizable  = true
    t.window.vsync      = 1
    t.window.fullscreen = false
    -- Ask LÖVE for actual physical pixels. On desktop (with SetProcessDPIAware
    -- above) the window opens at physical px. On web, highdpi makes
    -- getPixelDimensions() report the true device resolution (3840×2160 on a
    -- 4K/150% display) while getDimensions() reports the smaller CSS size
    -- (2560×1440) — main.lua's web HiDPI layer lays the game out in that full
    -- device-pixel space so web matches the native window. (Required on: with
    -- highdpi off, pixel == CSS and that layer has nothing to scale.)
    t.window.highdpi    = true

    t.modules.physics  = false
    t.modules.joystick = false
    t.modules.video    = false
end
