-- views/CrtMonitor.lua
--
-- The House's security monitor. The room before the shove is the House
-- watching through a camera: the picture is captured whole into a
-- frame-sized canvas, the camera overlay (CAM 01, the clock, a blinking
-- REC) laid over it, and the lot drawn into the monitor's screen through
-- shaders/crt.frag (curve, scanlines, mask, fringe, grain, roll). The
-- housing round it is drawn here, in code: plastic case, dark recess, a
-- control strip with its buttons and a green power light.
--
-- One user: ShoveView:_drawRoomCount. Headless (no canvas or shader), the
-- picture draws plainly inside the housing.

local Motion         = require("services.Motion")
local ScratchCanvas  = require("services.ScratchCanvas")
local ShaderRegistry = require("services.ShaderRegistry")

local CrtMonitor = {}

-- The case and the screen, in a security monitor's greys.
local C = {
    case_hi   = { 0.46, 0.45, 0.42 },
    case      = { 0.34, 0.33, 0.31 },
    case_lo   = { 0.22, 0.21, 0.20 },
    recess    = { 0.09, 0.09, 0.10 },
    glass     = { 0.02, 0.025, 0.03 },
    strip     = { 0.17, 0.17, 0.17 },
    button    = { 0.27, 0.27, 0.26 },
    led       = { 0.35, 0.95, 0.40 },
    rec       = { 0.95, 0.20, 0.18 },
    ink       = { 0.92, 0.94, 0.92 },
}

local SCREEN_H = 0.74   -- the screen's height, of the frame's
local CURVE    = 0.085  -- the tube's bulge (crt.frag u_curve)

local function setC(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

-- The housing and the screen for a frame W x H: the screen keeps the
-- frame's aspect (the picture fits it unstretched); the case is a margin
-- round it, deeper at the bottom for the control strip.
function CrtMonitor.layout(W, H)
    local sh = math.floor(H * SCREEN_H)
    local sw = math.floor(sh * W / H)
    if sw > W * 0.86 then sw = math.floor(W * 0.86); sh = math.floor(sw * H / W) end
    local side, top, bottom = math.floor(sh * 0.07), math.floor(sh * 0.06), math.floor(sh * 0.13)
    local cw, ch = sw + side * 2, sh + top + bottom
    local cx = math.floor((W - cw) / 2)
    local cy = math.floor((H - ch) / 2) + math.floor(H * 0.03)
    return {
        case   = { x = cx, y = cy, w = cw, h = ch },
        screen = { x = cx + side, y = cy + top, w = sw, h = sh },
        strip  = { x = cx + side, y = cy + top + sh + math.floor(bottom * 0.28),
                   w = sw, h = math.floor(bottom * 0.46) },
    }
end

-- The camera overlay, in picture space (it bends with the tube).
local function drawOverlay(game, W, H, anim)
    local fonts = game and game.fonts or {}
    local f = fonts.md or fonts.sm
    if not f then return end
    love.graphics.setFont(f)
    local pad = math.floor(H * 0.06)
    local function label(txt, x, y, c)
        setC({ 0, 0, 0 }, 0.6)
        love.graphics.print(txt, x + 2, y + 2)
        setC(c or C.ink, 0.9)
        love.graphics.print(txt, x, y)
    end
    label("CAM 01", pad + math.floor(W * 0.03), pad)
    local clock = os.date("%m/%d/%Y  %H:%M:%S")
    label(clock, W - pad - math.floor(W * 0.03) - f:getWidth(clock), pad)
    local blink = (not anim) or (math.floor(love.timer.getTime() * 1.6) % 2 == 0)
    if blink then
        local rx, ry = pad + math.floor(W * 0.03), H - pad - f:getHeight()
        local rr = math.floor(f:getHeight() * 0.32)
        setC(C.rec, 0.95)
        love.graphics.circle("fill", rx + rr, ry + f:getHeight() * 0.5, rr)
        label("REC", rx + rr * 3, ry, C.rec)
    end
end

-- The case: plastic with a lit top edge and a shadowed bottom, the dark
-- recess the tube sits in, the strip with its buttons and power light.
local function drawCase(L, s)
    local c, sc, st = L.case, L.screen, L.strip
    local r = math.floor(14 * s)
    setC(C.case_lo)
    love.graphics.rectangle("fill", c.x, c.y + math.floor(4 * s), c.w, c.h, r)
    setC(C.case)
    love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, r)
    setC(C.case_hi, 0.55)
    love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
    love.graphics.line(c.x + r, c.y + 1, c.x + c.w - r, c.y + 1)
    love.graphics.setLineWidth(1)
    -- The recess: a little bigger than the tube, darker.
    local m = math.floor(sc.h * 0.025)
    setC(C.recess)
    love.graphics.rectangle("fill", sc.x - m, sc.y - m, sc.w + m * 2, sc.h + m * 2, math.floor(10 * s))
    setC(C.glass)
    love.graphics.rectangle("fill", sc.x, sc.y, sc.w, sc.h, math.floor(18 * s))
    -- The control strip: four buttons left, the power light right.
    setC(C.strip)
    love.graphics.rectangle("fill", st.x, st.y, st.w, st.h, math.floor(4 * s))
    local bw, bh = math.floor(st.h * 0.9), math.floor(st.h * 0.5)
    for i = 0, 3 do
        local bx = st.x + math.floor(st.h * 0.6) + i * (bw + math.floor(bw * 0.4))
        local by = st.y + math.floor((st.h - bh) / 2)
        setC(C.button)
        love.graphics.rectangle("fill", bx, by, bw, bh, math.floor(2 * s))
        setC(C.case_hi, 0.35)
        love.graphics.line(bx + 1, by + 1, bx + bw - 1, by + 1)
    end
    local lr = math.max(2, math.floor(st.h * 0.14))
    local lx, ly = st.x + st.w - math.floor(st.h * 0.8), st.y + st.h * 0.5
    setC(C.led, 0.25)
    love.graphics.circle("fill", lx, ly, lr * 2.2)
    setC(C.led)
    love.graphics.circle("fill", lx, ly, lr)
end

-- Draw the monitor with drawPicture(W, H) on its screen. drawPicture draws
-- the full frame as it would without the monitor; it is captured whole.
function CrtMonitor.draw(game, W, H, drawPicture)
    local s    = (game and game.ui_scale) or 1
    local L    = CrtMonitor.layout(W, H)
    local anim = Motion.at("shine", Motion.HIGH)
    drawCase(L, s)

    local shader = ShaderRegistry.get and ShaderRegistry.get("crt")
    local canvas = shader and ScratchCanvas.acquire(W, H)
    local sc = L.screen
    if not canvas then
        -- Headless or no shader: the picture, plain, in the tube's rect.
        love.graphics.push("all")
        love.graphics.translate(sc.x, sc.y)
        love.graphics.scale(sc.w / W, sc.h / H)
        drawPicture(W, H)
        drawOverlay(game, W, H, anim)
        love.graphics.pop()
        return L
    end

    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.clear(0, 0, 0, 1)
    drawPicture(W, H)
    drawOverlay(game, W, H, anim)
    love.graphics.pop()

    love.graphics.push("all")
    love.graphics.setShader(shader)
    pcall(shader.send, shader, "u_time", Motion.time("shine", love.timer.getTime()))
    pcall(shader.send, shader, "u_res", { sc.w, sc.h })
    pcall(shader.send, shader, "u_curve", CURVE)
    pcall(shader.send, shader, "u_anim", anim and 1 or 0)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, sc.x, sc.y, 0, sc.w / W, sc.h / H)
    love.graphics.pop()
    ScratchCanvas.release()
    return L
end

return CrtMonitor
