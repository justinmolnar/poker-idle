-- services/CursorPool.lua
--
-- Stateless module — autonomous-cursor swarm. Mirrors the HoverService
-- convention: no instance, no constructor; module-private state lives in
-- file-local upvalues; callers invoke `update` and `draw` once per frame.
--
-- Lifecycle:
--   1. Each frame, the active state's update calls
--      CursorPool.update(dt, hit_boxes, ctx, dispatcher).
--   2. The pool sizes itself to ctx.cursor_count (gated by
--      ctx.cursor_unlocked); each cursor's state machine advances; on
--      click-arrival, dispatcher(hit_box) is invoked — the same path mouse
--      clicks use.
--   3. The active view's draw calls CursorPool.draw() last so cursors
--      render above panels and sidebars.

local Cursor       = require("models.Cursor")
local Theme        = require("views.Theme")
local SoundService = require("services.SoundService")

local CursorPool = {}

-- Module-private state.
local _cursors = {}               -- list of Cursor instances
local _last_W, _last_H = 1280, 720  -- last seen screen dimensions, for spawn-on-grow
local _ripples = {}               -- {x, y, t} click ripples
local _sparks  = {}               -- {x, y, t, angle} collision starbursts

-- Speed expressed as a fraction of screen diagonal per second
local BASE_CURSOR_SPEED = 0.10

-- Wipe pool. Called on fullReset and prestige.
function CursorPool.reset()
    _cursors = {}
    _ripples = {}
    _sparks  = {}
end

-- Per-frame update. dispatcher(hb) fires when a cursor reaches the center of claimed hit-box.
function CursorPool.update(dt, hit_boxes, ctx, dispatcher)
    local W, H = love.graphics.getDimensions()
    _last_W, _last_H = W, H

    local unlocked = ctx and ctx.cursor_unlocked
    local desired  = (ctx and math.max(0, math.floor(ctx.cursor_count or 0))) or 0
    if not unlocked then desired = 0 end

    -- Resize pool toward `desired`.
    while #_cursors < desired do
        local cx = W * (0.3 + math.random() * 0.4)
        local cy = H * (0.3 + math.random() * 0.4)
        _cursors[#_cursors + 1] = Cursor:new(cx, cy)
    end
    while #_cursors > desired do
        _cursors[#_cursors] = nil
    end

    if desired == 0 then return end

    -- Build the map of claimable hit-boxes (by idx) — skip muted tables.
    local rebuy_unlocked = ctx and ctx.cursor_rebuy_unlocked
    local deal_hbs = {}
    if hit_boxes then
        for _, hb in ipairs(hit_boxes) do
            if hb.action == "deal" and not hb.cursor_muted and hb.idx then
                deal_hbs[hb.idx] = hb
            elseif rebuy_unlocked and hb.action == "rebuy"
                   and not hb.cursor_rebuy_muted and hb.idx then
                deal_hbs[hb.idx] = hb
            end
        end
    end

    -- Pre-validate each seeking cursor's claim against this frame's hit-boxes
    local claims = {}
    for _, c in ipairs(_cursors) do
        if c.state == "seeking" and c.target_idx then
            if deal_hbs[c.target_idx] then
                claims[c.target_idx] = true
            else
                c:releaseTarget()
            end
        end
    end

    -- Compute speed in px/sec from screen diagonal × ctx multiplier.
    local diag       = math.sqrt(W * W + H * H)
    local speed_frac = BASE_CURSOR_SPEED * ((ctx and ctx.cursor_speed_mult) or 1)
    local speed_px   = speed_frac * diag

    -- Dynamic launch speed proportional to current cursor travel speed (min 600 px/sec floor)
    local launch_speed = math.max(600, speed_px * 3.8)

    -- Pairwise mouse collision checks (unless ghost phasing is unlocked).
    -- Allows flying stunned mice to ping-pong off other mice for chain reactions!
    local phasing = ctx and ctx.cursor_collision_phasing
    if not phasing and #_cursors > 1 then
        for i = 1, #_cursors - 1 do
            local c1 = _cursors[i]
            if c1.state ~= "cleaning" then
                for j = i + 1, #_cursors do
                    local c2 = _cursors[j]
                    if c2.state ~= "cleaning" then
                        local dx, dy = c2.x - c1.x, c2.y - c1.y
                        local dist2 = dx * dx + dy * dy
                        if dist2 < 20 * 20 then
                            local dist = math.sqrt(dist2)
                            if dist < 0.001 then dist = 0.001; dx, dy = 1, 0 end
                            local nx, ny = dx / dist, dy / dist

                            -- Relative velocity along collision normal (prevents re-triggering while flying apart)
                            local rvx = (c2.recoil_vx or 0) - (c1.recoil_vx or 0)
                            local rvy = (c2.recoil_vy or 0) - (c1.recoil_vy or 0)
                            local vel_along_normal = rvx * nx + rvy * ny

                            if vel_along_normal < 0 or c1.state ~= "stunned" or c2.state ~= "stunned" then
                                local v1 = math.sqrt((c1.recoil_vx or 0)^2 + (c1.recoil_vy or 0)^2)
                                local v2 = math.sqrt((c2.recoil_vx or 0)^2 + (c2.recoil_vy or 0)^2)
                                local impulse = math.max(launch_speed, math.max(v1, v2) * 1.1)

                                c1:triggerStun(-nx * impulse, -ny * impulse, 0.55)
                                c2:triggerStun(nx * impulse, ny * impulse, 0.55)
                                SoundService.playNamed("cursor_tap")

                                -- Record collision starburst fanfare at mid-point
                                local mid_x = (c1.x + c2.x) * 0.5
                                local mid_y = (c1.y + c2.y) * 0.5
                                _sparks[#_sparks + 1] = {
                                    x = mid_x,
                                    y = mid_y,
                                    t = love.timer.getTime(),
                                    angle = math.random() * math.pi,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    for _, c in ipairs(_cursors) do
        c:update(dt, deal_hbs, claims, speed_px, W, H, dispatcher, ctx)
        if c._just_dispatched then
            c._just_dispatched = nil
            _ripples[#_ripples + 1] = { x = c.x, y = c.y, t = love.timer.getTime() }
            SoundService.playNamed("cursor_tap")
        end
    end
end

-- Polygon star generator (used for collision starbursts & dizzy stars)
local function drawStar(cx, cy, r_in, r_out, points, angle, mode)
    local coords = {}
    local step = math.pi / points
    for i = 0, points * 2 - 1 do
        local r = (i % 2 == 0) and r_out or r_in
        local a = angle + i * step
        coords[#coords + 1] = cx + math.cos(a) * r
        coords[#coords + 1] = cy + math.sin(a) * r
    end
    love.graphics.polygon(mode or "fill", coords)
end

-- Arrow-cursor polygon
local CURSOR_POLY = {
    0,  0,
    15, 15,
    8,  15,
    12, 23,
    9,  24,
    5,  16,
    0,  21,
}
local CURSOR_TRIS = love.math.triangulate(CURSOR_POLY)

local function drawShape(c, mode)
    love.graphics.push()
    love.graphics.translate(c.x, c.y)
    if c.angle and c.angle ~= 0 then
        love.graphics.rotate(c.angle)
    end
    if mode == "fill" then
        for _, tri in ipairs(CURSOR_TRIS) do
            love.graphics.polygon("fill", tri)
        end
    else
        love.graphics.polygon("line", CURSOR_POLY)
    end
    love.graphics.pop()
end

function CursorPool.draw()
    if #_cursors == 0 and #_ripples == 0 and #_sparks == 0 then return end
    local tnow = (love.timer and love.timer.getTime()) or 0

    if #_cursors > 0 then
        Theme.setColor(Theme.fg.heading, 0.95)
        for _, c in ipairs(_cursors) do
            drawShape(c, "fill")
        end
        Theme.setColor(Theme.border.strong, 1.0)
        love.graphics.setLineWidth(1)
        for _, c in ipairs(_cursors) do
            drawShape(c, "line")
        end

        -- Dizzy cartoon stars orbiting stunned flying mice
        for _, c in ipairs(_cursors) do
            if c.state == "stunned" then
                local spin_a = tnow * 10.0
                for s = 1, 3 do
                    local sa = spin_a + (s * math.pi * 2 / 3)
                    local sx = c.x + math.cos(sa) * 14
                    local sy = c.y - 8 + math.sin(sa) * 6
                    Theme.setColor(Theme.status.warn, 0.95)
                    drawStar(sx, sy, 2.5, 6, 4, sa * 2, "fill")
                    Theme.setColor(Theme.border.strong, 0.8)
                    love.graphics.setLineWidth(1)
                    drawStar(sx, sy, 2.5, 6, 4, sa * 2, "line")
                end
            end
        end
    end

    -- Click ripples
    for i = #_ripples, 1, -1 do
        local rp = _ripples[i]
        local k  = (tnow - rp.t) / 0.35
        if k >= 1 then
            table.remove(_ripples, i)
        else
            Theme.setColor(Theme.fg.heading, (1 - k) * 0.8)
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", rp.x, rp.y, 8 + k * 18)
        end
    end

    -- Collision starburst fanfare
    for i = #_sparks, 1, -1 do
        local sp = _sparks[i]
        local k  = (tnow - sp.t) / 0.30
        if k >= 1 then
            table.remove(_sparks, i)
        else
            local alpha = 1.0 - k
            local scale = 0.5 + k * 1.8
            -- Outer shockwave ring
            Theme.setColor(Theme.status.warn, alpha * 0.9)
            love.graphics.setLineWidth(3 - k * 2)
            love.graphics.circle("line", sp.x, sp.y, scale * 16)

            -- 6-point comic starburst
            Theme.setColor(Theme.fg.heading, alpha)
            drawStar(sp.x, sp.y, scale * 5, scale * 20, 6, sp.angle + k * 2, "fill")
            Theme.setColor(Theme.status.warn, alpha * 0.8)
            drawStar(sp.x, sp.y, scale * 5, scale * 20, 6, sp.angle + k * 2, "line")
        end
    end
end

return CursorPool
