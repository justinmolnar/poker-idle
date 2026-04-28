function love.conf(t)
    t.identity = "poker-idle"
    t.version  = "11.4"
    t.console  = true

    t.window.title      = "Poker Idle"
    t.window.width      = 1280
    t.window.height     = 720
    t.window.resizable  = true
    t.window.vsync      = 1
    t.window.fullscreen = false

    t.modules.physics  = false
    t.modules.joystick = false
    t.modules.video    = false
end
