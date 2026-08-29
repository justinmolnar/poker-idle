-- views/HouseArt.lua
--
-- THE HOUSE, painted. The captor's own portrait: a golden-hour hillside,
-- the gold-roofed house at the crest, windows lit because it is always
-- home. Pure procedural code-art (the game's medium) — layered flat
-- bands for the sky, a baked radial texture for glows, Decal-hashed
-- scatter so nothing vibrates, love.timer time for the drifting clouds,
-- chimney smoke and birds.
--
-- Two consumers, ONE framing: the grind poster and the room's wall print
-- show the same picture (HouseArt.paintPortrait — a fixed zoomed crop of
-- the full landscape, centred on the house), and both are stills: it is
-- a poster, not a window. `t` exists for tooling previews; the game
-- always passes 0.
--   HouseArt.paint(x, y, w, h, t)         — the full landscape.
--   HouseArt.paintPortrait(x, y, w, h, t) — the shared poster crop.
--   HouseArt.bake(sprite_loader)   — renders the room version once:
--     the scene with its own slim frame, sheared onto the left-wall
--     plane (ky = 0.5, measured off the TinyHouse kit's Poster_1..5,
--     whose slope is exactly +0.5 — the room applies NO skew at draw
--     time, the projection lives in the art), plus the kit-style drop
--     shadow, downsampled and injected as sprite "house_poster_wall".
--
-- Colors are hardcoded scene paint, deliberately not Theme tokens (the
-- palette swap on the shove screen must never repaint the portrait) —
-- except the roof, which is written in the House's gold.

local Theme = require("views.Theme")
local Decal = require("services.Decal")

local HouseArt = {}

-- ── Palette ────────────────────────────────────────────────────────────
local SKY = {   -- top → horizon
    { 0.25, 0.18, 0.36 },
    { 0.45, 0.27, 0.42 },
    { 0.74, 0.43, 0.40 },
    { 0.93, 0.64, 0.40 },
    { 0.99, 0.84, 0.55 },
}
local SUN_CORE   = { 1.00, 0.95, 0.78 }
local SUN_GLOW   = { 1.00, 0.78, 0.42 }
local CLOUD_LIT  = { 0.99, 0.83, 0.68 }
local CLOUD_BASE = { 0.58, 0.38, 0.50 }
local HILL_FAR   = { 0.33, 0.35, 0.33 }
local HILL_MID   = { 0.42, 0.47, 0.29 }
local MEADOW     = { 0.50, 0.55, 0.32 }
local PATH       = { 0.81, 0.68, 0.47 }
local PATH_EDGE  = { 0.62, 0.52, 0.36 }
local WALL_LIT   = { 0.94, 0.88, 0.74 }
local WALL_SHADE = { 0.75, 0.66, 0.54 }
local ROOF       = { 0.93, 0.75, 0.30 }   -- the House's gold
local ROOF_SHADE = { 0.72, 0.55, 0.21 }
local TRIM       = { 0.40, 0.29, 0.23 }
local DOOR       = { 0.36, 0.24, 0.19 }
local WINDOW     = { 1.00, 0.88, 0.52 }
local CHIMNEY    = { 0.52, 0.34, 0.29 }
local SMOKE      = { 0.94, 0.91, 0.87 }
local TREE_DARK  = { 0.27, 0.37, 0.23 }
local TREE_MID   = { 0.35, 0.46, 0.26 }
local TREE_LIT   = { 0.47, 0.55, 0.29 }
local TRUNK      = { 0.42, 0.30, 0.23 }
local BIRD       = { 0.29, 0.21, 0.27 }
local FLOWERS    = {
    { 0.88, 0.36, 0.36 }, { 0.96, 0.81, 0.40 },
    { 0.95, 0.92, 0.86 }, { 0.82, 0.48, 0.68 },
}

-- ── Radial glow texture (ShoveDecor's recipe): alpha 1 at centre easing
-- to 0 at the rim; stretched for the sun, the window halos, the warm
-- wash. Built once, lazily, and skipped gracefully when the graphics
-- stack isn't there (headless tooling).
local _glow
local function glowTex()
    if _glow ~= nil then return _glow or nil end
    local ok, img = pcall(function()
        local N = 64
        local data = love.image.newImageData(N, N)
        data:mapPixel(function(px, py)
            local dx, dy = (px + 0.5) / N * 2 - 1, (py + 0.5) / N * 2 - 1
            local d = math.sqrt(dx * dx + dy * dy)
            local a = math.max(0, 1 - d)
            return 1, 1, 1, a * a
        end)
        local im = love.graphics.newImage(data)
        im:setFilter("linear", "linear")
        return im
    end)
    _glow = ok and img or false
    return _glow or nil
end

local function glowAt(cx, cy, rx, ry, color, alpha)
    local g = glowTex()
    if not g then return end
    Theme.setColor(color, alpha)
    love.graphics.draw(g, cx - rx, cy - ry, 0, rx * 2 / 64, ry * 2 / 64)
end

-- Lerp between the SKY stops at 0..1.
local function skyColor(f)
    local n = #SKY
    local pos = f * (n - 1) + 1
    local i = math.min(n - 1, math.floor(pos))
    local k = pos - i
    local a, b = SKY[i], SKY[i + 1]
    return { a[1] + (b[1] - a[1]) * k,
             a[2] + (b[2] - a[2]) * k,
             a[3] + (b[3] - a[3]) * k }
end

-- ── The painting ───────────────────────────────────────────────────────
function HouseArt.paint(x, y, w, h, t)
    t = t or 0
    local fl = math.floor
    love.graphics.push("all")
    love.graphics.intersectScissor(x, y, w, h)

    local horizon = y + h * 0.60

    -- Sky: thin bands lerping through the dusk stops.
    local BANDS = 24
    local band_h = (h * 0.62) / BANDS
    for i = 0, BANDS - 1 do
        Theme.setColor(skyColor(i / (BANDS - 1)))
        love.graphics.rectangle("fill", x, y + i * band_h, w, band_h + 1)
    end

    -- The sun, low over the far hills; its glow breathes very slowly.
    local sun_x, sun_y = x + w * 0.26, y + h * 0.50
    local breathe = 0.9 + 0.1 * math.sin(t * 0.6)
    glowAt(sun_x, sun_y, w * 0.30, w * 0.24, SUN_GLOW, 0.65 * breathe)
    Theme.setColor(SUN_CORE)
    love.graphics.circle("fill", sun_x, sun_y, math.max(2, w * 0.045))
    glowAt(sun_x, sun_y, w * 0.09, w * 0.09, SUN_CORE, 0.8)

    -- Clouds: three groups drifting on t, wrapping around the frame.
    local function cloud(base_x, cy, cw, ch, speed)
        local span = w + cw * 2
        local cx = x - cw + ((base_x - x) + t * speed) % span
        Theme.setColor(CLOUD_BASE, 0.80)
        love.graphics.ellipse("fill", cx, cy, cw * 0.55, ch)
        love.graphics.ellipse("fill", cx + cw * 0.35, cy + ch * 0.25, cw * 0.40, ch * 0.75)
        Theme.setColor(CLOUD_LIT, 0.85)
        love.graphics.ellipse("fill", cx - cw * 0.18, cy - ch * 0.35, cw * 0.42, ch * 0.70)
        love.graphics.ellipse("fill", cx + cw * 0.18, cy - ch * 0.15, cw * 0.30, ch * 0.55)
    end
    cloud(x + w * 0.55, y + h * 0.13, w * 0.16, h * 0.030, w * 0.006)
    cloud(x + w * 0.15, y + h * 0.24, w * 0.22, h * 0.038, w * 0.004)
    cloud(x + w * 0.80, y + h * 0.36, w * 0.13, h * 0.026, w * 0.008)

    -- Birds: two far chevrons, drifting against the clouds.
    local function bird(bx, by, r)
        Theme.setColor(BIRD, 0.9)
        love.graphics.setLineWidth(math.max(1, r * 0.30))
        love.graphics.line(bx - r, by, bx, by - r * 0.55, bx + r, by)
        love.graphics.setLineWidth(1)
    end
    local bdx = (w * 0.40 - t * w * 0.003) % (w * 1.2) - w * 0.1
    bird(x + bdx, y + h * 0.20 + h * 0.01 * math.sin(t * 1.7),
         math.max(2, w * 0.012))
    bird(x + bdx + w * 0.06, y + h * 0.165 + h * 0.01 * math.sin(t * 1.7 + 1),
         math.max(2, w * 0.009))

    -- Hills: far silhouettes, then the mid hill the house stands on.
    Theme.setColor(HILL_FAR)
    love.graphics.ellipse("fill", x + w * 0.24, y + h * 0.78, w * 0.55, h * 0.24)
    love.graphics.ellipse("fill", x + w * 0.85, y + h * 0.80, w * 0.52, h * 0.26)
    love.graphics.rectangle("fill", x, horizon + h * 0.05, w, h)
    Theme.setColor(HILL_MID)
    love.graphics.ellipse("fill", x + w * 0.66, y + h * 0.98, w * 0.68, h * 0.30)
    love.graphics.ellipse("fill", x + w * 0.05, y + h * 1.02, w * 0.45, h * 0.28)

    -- ── The house, at the crest, right of centre ──
    local hx = x + w * 0.66            -- front-face centre
    local ground = y + h * 0.745
    local bw = w * 0.165               -- front width
    local bh = h * 0.155               -- wall height
    local side = w * 0.055             -- side-face depth

    -- Chimney first (behind the roof line), smoke rising off it.
    local ch_w = math.max(2, bw * 0.18)
    local ch_x = hx + bw * 0.22
    local ch_top = ground - bh - h * 0.115
    Theme.setColor(CHIMNEY)
    love.graphics.rectangle("fill", ch_x, ch_top, ch_w, h * 0.07)
    love.graphics.rectangle("fill", ch_x - ch_w * 0.15, ch_top, ch_w * 1.3, math.max(1, h * 0.012))
    for i = 1, 3 do
        local phase = (t * 0.16 + i * 0.33) % 1
        local puff_y = ch_top - phase * h * 0.14
        local puff_x = ch_x + ch_w * 0.5 + math.sin(t * 0.9 + i * 2.1) * w * 0.012
                       + phase * w * 0.03
        local pr = (0.35 + phase) * w * 0.016
        Theme.setColor(SMOKE, (1 - phase) * 0.45)
        love.graphics.circle("fill", puff_x, puff_y, math.max(1, pr))
    end

    -- Walls: lit front face, shaded side face.
    Theme.setColor(WALL_LIT)
    love.graphics.rectangle("fill", hx - bw * 0.5, ground - bh, bw, bh)
    Theme.setColor(WALL_SHADE)
    love.graphics.rectangle("fill", hx + bw * 0.5, ground - bh, side, bh)

    -- Roof: the gold gable with a little overhang, shaded slope over the
    -- side face, dark eave line.
    local apex_y = ground - bh - h * 0.105
    local eave_y = ground - bh
    local over = bw * 0.12
    Theme.setColor(ROOF)
    love.graphics.polygon("fill",
        hx - bw * 0.5 - over, eave_y,
        hx, apex_y,
        hx + bw * 0.5 + over * 0.4, eave_y)
    Theme.setColor(ROOF_SHADE)
    love.graphics.polygon("fill",
        hx, apex_y,
        hx + bw * 0.5 + over * 0.4, eave_y,
        hx + bw * 0.5 + side + over * 0.4, eave_y,
        hx + side * 0.9, apex_y)
    Theme.setColor(TRIM, 0.8)
    love.graphics.rectangle("fill", hx - bw * 0.5 - over, eave_y - math.max(1, h * 0.006),
        bw + over * 1.4 + side, math.max(1, h * 0.006))

    -- Windows: two lit panes and a round gable light, each with a halo.
    -- The lights hold a slow, uneasy flicker — somebody is home.
    local win_w = math.max(2, bw * 0.20)
    local win_h = math.max(2, bh * 0.38)
    local win_y = ground - bh * 0.72
    for i, wx in ipairs({ hx - bw * 0.30, hx + bw * 0.28 }) do
        local flick = 0.85 + 0.15 * math.sin(t * 1.1 + i * 2.4)
        glowAt(wx, win_y + win_h * 0.5, win_w * 2.4, win_h * 2.0, WINDOW, 0.35 * flick)
        Theme.setColor(WINDOW, flick)
        love.graphics.rectangle("fill", wx - win_w * 0.5, win_y, win_w, win_h)
        Theme.setColor(TRIM, 0.9)
        love.graphics.rectangle("line", wx - win_w * 0.5, win_y, win_w, win_h)
        love.graphics.line(wx, win_y, wx, win_y + win_h)
    end
    local gable_r = math.max(1.5, bw * 0.085)
    local gable_y = apex_y + (eave_y - apex_y) * 0.55
    glowAt(hx, gable_y, gable_r * 3.2, gable_r * 3.2, WINDOW, 0.30)
    Theme.setColor(WINDOW, 0.95)
    love.graphics.circle("fill", hx, gable_y, gable_r)
    Theme.setColor(TRIM, 0.9)
    love.graphics.circle("line", hx, gable_y, gable_r)

    -- Door: dark arch, low and waiting.
    local door_w = math.max(2, bw * 0.20)
    local door_h = bh * 0.52
    local door_x = hx - door_w * 0.5
    Theme.setColor(DOOR)
    love.graphics.rectangle("fill", door_x, ground - door_h, door_w, door_h)
    love.graphics.circle("fill", hx, ground - door_h, door_w * 0.5)

    -- The path, from the door down and out of frame, edged.
    local py0 = ground
    Theme.setColor(PATH_EDGE)
    love.graphics.polygon("fill",
        hx - door_w * 0.9, py0,
        hx + door_w * 0.9, py0,
        x + w * 0.52, y + h,
        x + w * 0.30, y + h)
    Theme.setColor(PATH)
    love.graphics.polygon("fill",
        hx - door_w * 0.62, py0,
        hx + door_w * 0.62, py0,
        x + w * 0.485, y + h,
        x + w * 0.345, y + h)

    -- Foreground meadow band, over the path's far edges.
    Theme.setColor(MEADOW)
    love.graphics.ellipse("fill", x + w * 0.10, y + h * 1.16, w * 0.52, h * 0.30)
    love.graphics.ellipse("fill", x + w * 0.95, y + h * 1.18, w * 0.55, h * 0.32)

    -- Trees: a full one on the left slope, a smaller one behind the house.
    local function tree(tx, ty, sc)
        Theme.setColor(TRUNK)
        love.graphics.polygon("fill",
            tx - w * 0.010 * sc, ty,
            tx + w * 0.010 * sc, ty,
            tx + w * 0.005 * sc, ty - h * 0.10 * sc,
            tx - w * 0.005 * sc, ty - h * 0.10 * sc)
        local cy = ty - h * 0.13 * sc
        Theme.setColor(TREE_DARK)
        love.graphics.circle("fill", tx + w * 0.020 * sc, cy + h * 0.02 * sc, w * 0.045 * sc)
        Theme.setColor(TREE_MID)
        love.graphics.circle("fill", tx, cy, w * 0.050 * sc)
        love.graphics.circle("fill", tx - w * 0.030 * sc, cy + h * 0.025 * sc, w * 0.036 * sc)
        Theme.setColor(TREE_LIT)
        love.graphics.circle("fill", tx - w * 0.022 * sc, cy - h * 0.018 * sc, w * 0.030 * sc)
    end
    tree(x + w * 0.135, y + h * 0.76, 1.25)
    tree(x + w * 0.90, y + h * 0.70, 0.8)

    -- Flowers: Decal-hashed scatter on the meadow, so they never vibrate.
    for i = 1, 16 do
        local fx = x + Decal.lerp("house_flower_x" .. i, i, w * 0.03, w * 0.97)
        local fy = y + Decal.lerp("house_flower_y" .. i, i + 40, h * 0.85, h * 0.975)
        -- Keep them off the path.
        local path_c = x + w * 0.415
        if math.abs(fx - path_c) > w * 0.09 then
            local c = FLOWERS[(i % #FLOWERS) + 1]
            local d = math.max(1, w * 0.006)
            Theme.setColor({ 0.30, 0.42, 0.24 }, 0.9)
            love.graphics.rectangle("fill", fx, fy, math.max(1, d * 0.5), d * 1.6)
            Theme.setColor(c)
            love.graphics.rectangle("fill", fx - d * 0.5, fy - d, d * 1.6, d * 1.2)
        end
    end

    -- A warm wash from the sun over everything, tying the light together.
    glowAt(sun_x, sun_y, w * 0.85, h * 0.75, SUN_GLOW, 0.10)

    love.graphics.pop()
end

-- The framing both posters share: a zoomed crop centred on the house, so
-- the print in the room is recognisably the same picture that hangs over
-- the tables. 1.4 keeps the sun's edge and the meadow on the big frame
-- while the house still reads at wall-sprite size.
local PORTRAIT_ZOOM = 1.4

-- The poster's one frozen moment: hand-picked so the cloud sits clear of
-- the chimney smoke and the sun edges the frame. A poster, not a window.
local STILL_T = 25

function HouseArt.paintPortrait(x, y, w, h, t)
    t = t or STILL_T
    local vw, vh = w * PORTRAIT_ZOOM, h * PORTRAIT_ZOOM
    local vx = x + w * 0.52 - vw * 0.66   -- house centre → window 0.52
    local vy = y + h * 0.55 - vh * 0.62   -- roof/walls → window 0.55
    love.graphics.push("all")
    love.graphics.intersectScissor(x, y, w, h)
    HouseArt.paint(vx, vy, vw, vh, t)
    love.graphics.pop()
end

-- ── The speaker ────────────────────────────────────────────────────────
-- A weathered intercom bolted to the poster's frame: THE HOUSE's
-- mouthpiece. `level` 0..1 — 0 is idle (dark LED, dead grille); above 0
-- the LED lights and a warm voice-glow breathes behind the slots. The
-- host decides what "speaking" means; this just renders it.
local SPK_BOX    = { 0.25, 0.22, 0.19 }
local SPK_EDGE   = { 0.10, 0.09, 0.08 }
local SPK_BOLT   = { 0.55, 0.50, 0.42 }
local SPK_SLOT   = { 0.07, 0.06, 0.05 }
local SPK_VOICE  = { 1.00, 0.72, 0.35 }
local LED_OFF    = { 0.33, 0.12, 0.10 }
local LED_ON     = { 0.98, 0.38, 0.24 }

function HouseArt.drawSpeaker(x, y, w, h, level, t)
    level = level or 0
    t = t or 0
    local fl = math.floor
    local r = fl(h * 0.14)

    -- The box RATTLES while he talks: two incommensurate frequencies so
    -- the shake never settles into a loop. Amplitude scales with the box
    -- so the room's tiny print rattles proportionally.
    if level > 0 then
        x = x + math.sin(t * 41) * h * 0.045 * level
        y = y + math.cos(t * 53) * h * 0.035 * level
    end

    Theme.setColor(SPK_BOX)
    love.graphics.rectangle("fill", x, y, w, h, r)
    Theme.setColor(SPK_EDGE)
    love.graphics.rectangle("line", x, y, w, h, r)
    love.graphics.rectangle("line", x + w * 0.08, y + h * 0.10,
        w * 0.84, h * 0.80, r * 0.6)

    -- Corner bolts.
    local br = math.max(1, h * 0.055)
    for _, b in ipairs({ { 0.09, 0.14 }, { 0.91, 0.14 },
                         { 0.09, 0.86 }, { 0.91, 0.86 } }) do
        Theme.setColor(SPK_BOLT)
        love.graphics.circle("fill", x + w * b[1], y + h * b[2], br)
        Theme.setColor(SPK_EDGE)
        love.graphics.circle("fill", x + w * b[1], y + h * b[2], br * 0.4)
    end

    -- Voice glow behind the grille, breathing while he talks.
    if level > 0 then
        local pulse = 0.55 + 0.45 * math.sin(t * 14) * math.sin(t * 9.3)
        glowAt(x + w * 0.5, y + h * 0.52, w * 0.42, h * 0.40,
               SPK_VOICE, 0.45 * level * (0.5 + 0.5 * pulse))
    end

    -- Grille slots.
    local slots = 4
    local sw = w * 0.58
    local sx = x + (w - sw) * 0.5
    local sh_px = math.max(1, h * 0.07)
    for i = 1, slots do
        local sy = y + h * (0.26 + (i - 1) * 0.17)
        Theme.setColor(SPK_SLOT)
        love.graphics.rectangle("fill", sx, sy, sw, sh_px, sh_px * 0.5)
        if level > 0 then
            local wob = 0.3 + 0.7 * math.abs(math.sin(t * 11 + i * 1.7))
            Theme.setColor(SPK_VOICE, 0.35 * level * wob)
            love.graphics.rectangle("fill", sx, sy, sw, sh_px, sh_px * 0.5)
        end
    end

    -- The indicator LED, lit while he has the floor.
    local lx, ly = x + w * 0.5, y + h * 0.115
    if level > 0 then
        glowAt(lx, ly, br * 4, br * 4, LED_ON, 0.6 * level)
        Theme.setColor(LED_ON)
    else
        Theme.setColor(LED_OFF)
    end
    love.graphics.circle("fill", lx, ly, br * 0.9)
end

-- Flat content size of the room bake (pre-shear, pre-supersample), sized
-- against the kit posters (~29px art in a 64 cell). Shared by the bake
-- and the wall speaker overlay, which draws in these coordinates.
local FLAT_W, FLAT_H = 38, 30
local SS = 3            -- supersample, downsampled at the end
local SHEAR = 0.5       -- the kit posters' measured wall slope

-- The speaker on the ROOM's wall print. The baked sprite is a still, so
-- the intercom draws live on top of it, run through the exact transform
-- RoomView drew the sprite with (px/py/sx/sy/ox/oy) plus the same wall
-- shear the bake used — flip_x arrives as a negative sx and mirrors the
-- shear with it, so the box sits on the poster on either wall. Inside
-- that transform we are back in the bake's FLAT coordinates.
function HouseArt.drawWallSpeaker(px, py, sx, sy, ox, oy, level, t)
    love.graphics.push("all")   -- restores color too; the LED tints
    love.graphics.translate(px, py)
    love.graphics.scale(sx, sy)
    love.graphics.translate(-ox, -oy)
    love.graphics.shear(0, SHEAR)
    local w = FLAT_W * 0.24
    local h = FLAT_H * 0.22
    HouseArt.drawSpeaker(2.5, FLAT_H - h - 2.5, w, h, level, t)
    love.graphics.pop()
end

-- ── The room bake ──────────────────────────────────────────────────────

-- Render the framed portrait flat, shear it onto the left-wall plane,
-- add the kit-style drop shadow, downsample, inject as
-- "house_poster_wall". Guarded like SpriteLoader.resample: any failure
-- leaves the loader untouched (the room falls back to its iso box).
function HouseArt.bake(sprite_loader)
    if not (sprite_loader and sprite_loader.setSprite) then return end
    local ok = pcall(function()
        local fw, fh = FLAT_W * SS, FLAT_H * SS

        -- 1. The framed flat portrait.
        local flat = love.graphics.newCanvas(fw, fh)
        local prev = love.graphics.getCanvas()
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setScissor()
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setCanvas(flat)
        love.graphics.clear(0, 0, 0, 0)
        local frame = 2 * SS
        Theme.setColor({ 0.16, 0.12, 0.10 })
        love.graphics.rectangle("fill", 0, 0, fw, fh)
        Theme.setColor({ 0.88, 0.82, 0.70 })
        love.graphics.rectangle("fill", frame * 0.5, frame * 0.5,
            fw - frame, fh - frame)
        -- The same portrait crop, same frozen frame, the grind poster shows.
        HouseArt.paintPortrait(frame, frame, fw - frame * 2, fh - frame * 2)
        love.graphics.setCanvas(prev)
        love.graphics.pop()

        -- 2. Shear onto the wall plane + drop shadow, still supersampled.
        local wall_h = fh + math.ceil(fw * SHEAR)
        local wall = love.graphics.newCanvas(fw + 2 * SS, wall_h + 2 * SS)
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setScissor()
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setCanvas(wall)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.shear(0, SHEAR)
        love.graphics.setColor(0, 0, 0, 0.35)
        love.graphics.draw(flat, 1 * SS, 2 * SS)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(flat, 0, 0)
        love.graphics.setCanvas(prev)
        love.graphics.pop()

        -- 3. Downsample to sprite size and bake to a plain Image.
        local out_w = math.ceil(wall:getWidth() / SS)
        local out_h = math.ceil(wall:getHeight() / SS)
        local final = love.graphics.newCanvas(out_w, out_h)
        wall:setFilter("linear", "linear")
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setScissor()
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setCanvas(final)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(wall, 0, 0, 0, 1 / SS, 1 / SS)
        love.graphics.setCanvas(prev)
        love.graphics.pop()

        local data = final:newImageData()
        local img = love.graphics.newImage(data)
        img:setFilter("nearest", "nearest")
        sprite_loader:setSprite("house_poster_wall", img)
    end)
    return ok
end

return HouseArt
