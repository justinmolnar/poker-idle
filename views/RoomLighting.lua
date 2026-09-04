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

local RoomLighting = {}

local _canvas = nil

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

local function scaled(color, k)
    return { color[1] * k, color[2] * k, color[3] * k }
end

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
        local ok, c = pcall(love.graphics.newCanvas, W, H)
        if ok and c then _canvas = c end
    end
    if not _canvas then return end

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
        local now = (love.timer and love.timer.getTime()) or 0
        for _, r in ipairs(room_view._hit_rects or {}) do
            local id = r.obj and r.obj.id
            local e  = id and Lights.emitters[id]
            if e and (not L.lit or L.lit(id)) then
                local al = e.alpha
                if e.pulse then
                    al = al * (1 + e.pulse.amount * math.sin(now * 2 * math.pi / e.pulse.secs))
                end
                local d  = r.w * e.radius * 2
                local cx, cy = r.x + r.w * 0.5, r.y + r.h * 0.5
                ShoveDecor.drawLight(cx - d * 0.5, cy - d * 0.5, d, d, e.color, al)
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

    -- The bloom: over-bright while the tube is still settling.
    if level > 1 then
        love.graphics.setBlendMode("add")
        Theme.setColor(F.color, math.min(1, level - 1))
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
    love.graphics.setBlendMode("alpha")
end

return RoomLighting
