-- views/RoomLighting.lua
--
-- Lights the drawn room. RoomView draws walls, floor and items flat; this
-- pass builds a lightmap (ambient dark, the fixture's light, each emitting
-- item's glow) and multiplies it over the room, then adds the fixture's
-- over-bright bloom while it is still settling. Data: data/room_lights.lua.
--
-- Called by RoomView:draw when opts.lighting is given:
--   lighting = {
--       fixture  = level,        -- 0 off .. 1 lit; > 1 while blooming
--       emitters = true|false,   -- things that make light (default true)
--       lit      = fn(id)->bool, -- which items are on (default: all drawn)
--   }
-- Reads room_view._view (the transform) and room_view._hit_rects (this
-- frame's item rects, room space), both left by RoomView:draw.

local Theme      = require("views.Theme")
local ShoveDecor = require("views.ShoveDecor")
local Lights     = require("data.room_lights")

local Motion     = require("services.Motion")
local ShaderRegistry = require("services.ShaderRegistry")
local RoomLighting = {}

local _canvas = nil
local _quad   = nil   -- a 1x1 white image: the shader's quad, with 0..1 tex coords

-- An emitting item's light (shaders/room_light.frag): a pool on the floor
-- at its foot, an iso ellipse, and the thing itself lit. `r` is the item's
-- rect (room space), `e` its entry in data/room_lights.lua. Without the
-- shader (it failed to compile) the old disc stands in.
local function drawEmitter(r, e, alpha, anim)
    local R  = r.w * e.radius                       -- the reach, as the disc had it
    local cx = r.x + r.w * 0.5
    local foot = r.y + r.h * 0.94                   -- the sprite's bottom, less its padding
    local shader = _quad and ShaderRegistry.get and ShaderRegistry.get("room_light")
    if not shader then
        ShoveDecor.drawLight(cx - R, r.y + r.h * 0.5 - R, R * 2, R * 2, e.color, alpha)
        return
    end
    local prx, pry = R * 1.9, R * 0.95              -- the floor from the iso angle; the disc's reach was R
    local bcx, bcy = cx, r.y + r.h * 0.5
    local brx, bry = r.w * 1.0, r.h * 0.9
    local x0 = cx - math.max(prx, brx)
    local x1 = cx + math.max(prx, brx)
    local y0 = math.min(bcy - bry, foot - pry)
    local y1 = foot + pry
    local qw, qh = x1 - x0, y1 - y0
    if qw <= 0 or qh <= 0 then return end
    ShaderRegistry.apply("room_light", {
        u_color  = { e.color[1], e.color[2], e.color[3] },
        u_alpha  = alpha,
        u_pool_c = { (cx - x0) / qw, (foot - y0) / qh },
        u_pool_r = { prx / qw, pry / qh },
        u_body_c = { (bcx - x0) / qw, (bcy - y0) / qh },
        u_body_r = { brx / qw, bry / qh },
        u_anim   = anim,
    })
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(_quad, x0, y0, 0, qw, qh)
    ShaderRegistry.apply(nil)
end

-- The fixture's level over seconds since switch-on. Fluorescent: straight
-- up to the peak, then eases down to 1.0; off is 0 and instant.
function RoomLighting.fixtureLevel(cfg, t)
    if not t or t < 0 then return 0 end
    local b = cfg and cfg.bloom
    if not b or cfg.kind ~= "fluorescent" then return 1 end
    if t < b.peak_at then
        return b.peak * (t / b.peak_at)
    elseif t < b.settle_at then
        local k = (t - b.peak_at) / (b.settle_at - b.peak_at)
        k = 1 - (1 - k) * (1 - k)
        return b.peak + (1 - b.peak) * k
    end
    return 1
end

local scaled = Theme.darken   -- the same channel multiply, one definition

function RoomLighting.draw(room_view, L, W, H)
    if not (love and love.graphics and love.graphics.newCanvas) then return end
    local F     = Lights.fixture
    local level = L.fixture or 0
    local view  = room_view._view or { cx = W * 0.5, cy = H * 0.5, zoom = 1, dy = 0 }

    -- Sized to the frame; the frame's width follows the window (main.lua),
    -- so a stale canvas is rebuilt rather than stretched or cut short.
    if _canvas and (_canvas:getWidth() ~= W or _canvas:getHeight() ~= H) then
        _canvas = nil
    end
    if not _canvas then
        local ok, c = pcall(love.graphics.newCanvas, W, H, { dpiscale = 1 })
        if ok and c then _canvas = c end
    end
    if not _canvas then return end
    if not _quad and love.image and love.image.newImageData then
        local ok, img = pcall(function()
            local d = love.image.newImageData(1, 1)
            d:setPixel(0, 0, 1, 1, 1, 1)
            return love.graphics.newImage(d)
        end)
        if ok and img then _quad = img end
    end

    -- ── The lightmap ───────────────────────────────────────────────
    local prev = love.graphics.getCanvas()
    love.graphics.setCanvas(_canvas)
    local amb = F.ambient
    love.graphics.clear(amb[1], amb[2], amb[3], 1)
    love.graphics.setBlendMode("add")

    local on = math.min(1, level)
    love.graphics.push()
    love.graphics.translate(view.cx, view.cy + (view.dy or 0))
    love.graphics.scale(view.zoom or 1, view.zoom or 1)
    love.graphics.translate(-view.cx, -view.cy)

    local b = view.bounds
    if on > 0 then
        if F.kind == "cone" then
            local c = F.cone
            Theme.setColor(scaled(F.color, c.base * on))
            love.graphics.rectangle("fill", -W, -H, W * 3, H * 3)
            if b then
                local pw, ph = (b.x2 - b.x1) * c.w, (b.y2 - b.y1) * c.h
                ShoveDecor.drawLight(b.cx - pw * 0.5, b.cy - ph * 0.5, pw, ph, F.color, c.alpha * on)
            end
        else
            Theme.setColor(scaled(F.color, F.base * on))
            love.graphics.rectangle("fill", -W, -H, W * 3, H * 3)
            if b then
                local pw, ph = (b.x2 - b.x1) * F.pool.w, (b.y2 - b.y1) * F.pool.h
                ShoveDecor.drawLight(b.cx - pw * 0.5, b.cy - ph * 0.5, pw, ph, F.color, F.pool.alpha * on)
            end
        end
    end

    if L.emitters ~= false then
        local now  = (love.timer and love.timer.getTime()) or 0
        local anim = Motion.at("shine", Motion.HIGH) and 1 or 0
        for _, r in ipairs(room_view._hit_rects or {}) do
            local id = r.obj and r.obj.id
            local e  = id and Lights.emitters[id]
            if e and (not L.lit or L.lit(id)) then
                local al = e.alpha
                if e.pulse and anim == 1 then
                    al = al * (1 + e.pulse.amount * math.sin(now * 2 * math.pi / e.pulse.secs))
                end
                drawEmitter(r, e, al, anim)
            end
        end
    end
    love.graphics.pop()
    love.graphics.setBlendMode("alpha")
    love.graphics.setCanvas(prev)

    -- ── Composite: the room times the light ─────────────────────────
    love.graphics.setBlendMode("multiply", "premultiplied")
    Theme.setColor({ 1, 1, 1 })        -- no tint: the lightmap as drawn
    love.graphics.draw(_canvas, 0, 0)

    -- The bloom: over-bright while the tube is still settling. Below High
    -- the tube is simply on.
    if level > 1 and Motion.at("shine", Motion.HIGH) then
        love.graphics.setBlendMode("add")
        Theme.setColor(F.color, math.min(1, level - 1))
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
    love.graphics.setBlendMode("alpha")
end

return RoomLighting
