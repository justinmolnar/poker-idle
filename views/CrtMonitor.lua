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
    shadow    = { 0.00, 0.00, 0.00 },
    case_hi   = { 0.58, 0.57, 0.53 },
    case      = { 0.40, 0.39, 0.36 },
    case_lo   = { 0.24, 0.23, 0.22 },
    bezel_top = { 0.07, 0.07, 0.08 },
    bezel_bot = { 0.30, 0.29, 0.28 },
    bezel_sid = { 0.15, 0.15, 0.16 },
    glass     = { 0.015, 0.02, 0.025 },
    strip     = { 0.20, 0.20, 0.19 },
    button    = { 0.31, 0.31, 0.30 },
    label     = { 0.66, 0.65, 0.60 },
    screw     = { 0.52, 0.51, 0.48 },
    led       = { 0.35, 0.95, 0.40 },
    rec       = { 0.95, 0.20, 0.18 },
    ink       = { 0.92, 0.94, 0.92 },
}

local CURVE    = 0.085  -- the tube's bulge (crt.frag u_curve)

local function setC(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

-- The housing and the screen for a frame W x H: the screen keeps the
-- frame's aspect (the picture fits it unstretched); the case is a margin
-- round it, deeper at the bottom for the control strip. The opening is the
-- recessed bezel between the case face and the tube.
function CrtMonitor.layout(W, H)
    -- The case fills the frame, a thin margin round it. Top and bottom
    -- are fixed shares of the height; the screen keeps the frame's aspect,
    -- so whatever width is left over is plastic at the sides (the speaker
    -- grilles live there).
    local margin = math.max(4, math.floor(H * 0.035))
    local cw, ch = W - margin * 2, H - margin * 2
    local top, bottom = math.floor(ch * 0.065), math.floor(ch * 0.12)
    local sh = ch - top - bottom
    local sw = math.floor(sh * W / H)
    if sw > cw - math.floor(ch * 0.10) then
        sw = cw - math.floor(ch * 0.10)
        sh = math.floor(sw * H / W)
        local spare = ch - sh
        top    = math.floor(spare * 0.35)
        bottom = spare - top
    end
    local side = math.floor((cw - sw) / 2)
    local cx, cy = margin, margin
    local inset = math.floor(sh * 0.045)
    -- The strip sits in the band between the bezel's foot and the case's.
    local below = (cy + ch) - (cy + top + sh + inset)
    local st_h  = math.floor(below * 0.55)
    return {
        case    = { x = cx, y = cy, w = cw, h = ch },
        opening = { x = cx + side - inset, y = cy + top - inset,
                    w = sw + inset * 2, h = sh + inset * 2 },
        screen  = { x = cx + side, y = cy + top, w = sw, h = sh },
        side    = side,
        strip   = { x = cx + side, y = cy + top + sh + inset + math.floor((below - st_h) / 2),
                    w = sw, h = st_h },
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

-- The case: moulded plastic, lit from above (a lighter top half, a bright
-- top edge, a dark lower edge) with a soft shadow under it and a screw in
-- each corner; the bezel sloping in to the tube (dark above, catching the
-- light below); a recessed control strip with its channel buttons, a
-- maker's plate and the power light.
local function drawCase(game, L, s)
    local c, op, sc, st = L.case, L.opening, L.screen, L.strip
    local fl = math.floor
    local r  = fl(18 * s)

    -- Shadow, then the body, then the light on its upper half.
    for i = 3, 1, -1 do
        setC(C.shadow, 0.10)
        love.graphics.rectangle("fill", c.x - i * 2, c.y + i * 4, c.w + i * 4, c.h + i * 2, r + i * 2)
    end
    setC(C.case)
    love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, r)
    -- Light from above, fading down the face in soft bands.
    local bands = 12
    for i = 0, bands - 1 do
        local a = 0.20 * (1 - i / bands)
        setC(C.case_hi, a)
        local y0 = c.y + fl(c.h * 0.5 * i / bands)
        local y1 = c.y + fl(c.h * 0.5 * (i + 1) / bands)
        if i == 0 then
            love.graphics.rectangle("fill", c.x, y0, c.w, y1 - y0 + r, r)
        else
            love.graphics.rectangle("fill", c.x, y0 + r, c.w, y1 - y0)
        end
    end
    setC(C.case_hi, 0.75)
    love.graphics.setLineWidth(math.max(1, fl(2 * s)))
    love.graphics.line(c.x + r, c.y + 1, c.x + c.w - r, c.y + 1)
    setC(C.case_lo, 0.9)
    love.graphics.line(c.x + r, c.y + c.h - 1, c.x + c.w - r, c.y + c.h - 1)
    love.graphics.setLineWidth(1)

    -- Screws in the corners.
    local sr = math.max(2, fl(4 * s))
    local m  = fl(r * 0.9)
    for _, p in ipairs({ { c.x + m, c.y + m }, { c.x + c.w - m, c.y + m },
                         { c.x + m, c.y + c.h - m }, { c.x + c.w - m, c.y + c.h - m } }) do
        setC(C.case_lo)
        love.graphics.circle("fill", p[1], p[2] + 1, sr)
        setC(C.screw)
        love.graphics.circle("fill", p[1], p[2], sr)
        setC(C.case_lo)
        love.graphics.line(p[1] - sr * 0.6, p[2] - sr * 0.3, p[1] + sr * 0.6, p[2] + sr * 0.3)
    end

    -- The bezel: four sloped faces from the opening down to the tube.
    local ox1, oy1, ox2, oy2 = op.x, op.y, op.x + op.w, op.y + op.h
    local sx1, sy1, sx2, sy2 = sc.x, sc.y, sc.x + sc.w, sc.y + sc.h
    setC(C.bezel_top)
    love.graphics.polygon("fill", ox1, oy1, ox2, oy1, sx2, sy1, sx1, sy1)
    setC(C.bezel_bot)
    love.graphics.polygon("fill", sx1, sy2, sx2, sy2, ox2, oy2, ox1, oy2)
    setC(C.bezel_sid)
    love.graphics.polygon("fill", ox1, oy1, sx1, sy1, sx1, sy2, ox1, oy2)
    love.graphics.polygon("fill", sx2, sy1, ox2, oy1, ox2, oy2, sx2, sy2)
    setC(C.case_lo)
    love.graphics.rectangle("line", ox1 + 0.5, oy1 + 0.5, op.w - 1, op.h - 1, fl(4 * s))
    -- The tube's glass behind the picture, square to the bezel's inner
    -- edge (the tube's rounded corners show dark glass, never the case).
    setC(C.glass)
    love.graphics.rectangle("fill", sx1, sy1, sc.w, sc.h)

    -- Speaker grilles in the side plastic: rows of short slots, centred
    -- in each side panel beside the tube.
    local panel = op.x - c.x
    if panel > fl(30 * s) then
        local gw   = fl(panel * 0.42)
        local slot = math.max(2, fl(3 * s))
        local gap  = slot * 2
        local rows = fl(sc.h * 0.45 / gap)
        local gy0  = sc.y + fl(sc.h * 0.5 - rows * gap * 0.5)
        for _, gx in ipairs({ c.x + fl((panel - gw) / 2), op.x + op.w + fl((panel - gw) / 2) }) do
            for k = 0, rows - 1 do
                local yy = gy0 + k * gap
                setC(C.case_lo, 0.95)
                love.graphics.rectangle("fill", gx, yy, gw, slot, slot * 0.5)
                setC(C.case_hi, 0.25)
                love.graphics.line(gx + 1, yy + slot + 0.5, gx + gw - 1, yy + slot + 0.5)
            end
        end
    end

    -- The control strip, recessed.
    setC(C.case_lo)
    love.graphics.rectangle("fill", st.x - 1, st.y - 1, st.w + 2, st.h + 2, fl(5 * s))
    setC(C.strip)
    love.graphics.rectangle("fill", st.x, st.y + 1, st.w, st.h - 1, fl(5 * s))
    local fonts = game and game.fonts or {}
    local lf = fonts.xs or fonts.micro or fonts.sm
    -- The channel buttons: raised keys with their label on the key, the
    -- first one lit (the channel on the screen).
    local bh = fl(st.h * 0.66)
    local bw = lf and math.max(fl(bh * 1.9), lf:getWidth("CH4") + fl(bh * 0.8)) or fl(bh * 1.9)
    local by = st.y + fl((st.h - bh) / 2)
    for i = 0, 3 do
        local bx = st.x + fl(st.h * 0.35) + i * (bw + fl(bh * 0.35))
        setC(C.case_lo)
        love.graphics.rectangle("fill", bx, by + 2, bw, bh, fl(3 * s))
        setC(C.button)
        love.graphics.rectangle("fill", bx, by, bw, bh, fl(3 * s))
        setC(C.case_hi, 0.35)
        love.graphics.line(bx + 3, by + 1, bx + bw - 3, by + 1)
        if lf then
            love.graphics.setFont(lf)
            local t = "CH" .. (i + 1)
            if i == 0 then setC(C.led, 0.9) else setC(C.label, 0.75) end
            love.graphics.print(t, bx + fl((bw - lf:getWidth(t)) / 2), by + fl((bh - lf:getHeight()) / 2))
        end
    end
    if lf then
        love.graphics.setFont(lf)
        local plate = "SECURITY MONITOR"
        setC(C.case_lo, 0.9)
        love.graphics.print(plate, fl(st.x + (st.w - lf:getWidth(plate)) / 2) + 1, fl(st.y + (st.h - lf:getHeight()) / 2) + 1)
        setC(C.label, 0.75)
        love.graphics.print(plate, fl(st.x + (st.w - lf:getWidth(plate)) / 2), fl(st.y + (st.h - lf:getHeight()) / 2))
    end
    local lr = math.max(2, fl(st.h * 0.12))
    local lx, ly = st.x + st.w - fl(st.h * 0.9), st.y + st.h * 0.5
    setC(C.led, 0.18)
    love.graphics.circle("fill", lx, ly, lr * 3)
    setC(C.led, 0.35)
    love.graphics.circle("fill", lx, ly, lr * 1.8)
    setC(C.led)
    love.graphics.circle("fill", lx, ly, lr)
    if lf then
        setC(C.label, 0.7)
        local t = "POWER"
        love.graphics.print(t, lx - lr * 3 - fl(lf:getWidth(t)) - 2, fl(ly - lf:getHeight() / 2))
    end
end

-- Draw the monitor with drawPicture(W, H) on its screen. drawPicture draws
-- the full frame as it would without the monitor; it is captured whole.
function CrtMonitor.draw(game, W, H, drawPicture)
    local s    = (game and game.ui_scale) or 1
    local L    = CrtMonitor.layout(W, H)
    local anim = Motion.at("shine", Motion.HIGH)
    drawCase(game, L, s)

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
