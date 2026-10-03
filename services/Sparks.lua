-- services/Sparks.lua
--
-- The specks a click throws: square, pixel-sized, a few at a time, gone in
-- a third of a second, and an optional square ring pressed out from the
-- point (a click into cloth). Pooled: records come off a free stack and go
-- back to it, so a board of cursors clicking all evening allocates nothing
-- once the pool has grown. Drawn by main.lua over the state, in frame
-- space, so a spark on a modal sits on the modal.
--
-- `burst(x, y, spec, opts)` takes a spec in data/clicks.lua's shape (specks,
-- colors, speed, up, gravity, life, size, ring); opts: tint (the colour
-- when the spec has none), scale (a multiplier on the count).
--
-- Motion "ui": None throws nothing; Low half the specks and no ring.

local Motion = require("services.Motion")
local Data   = require("data.clicks")

local Sparks = {}

local _live, _free = {}, {}
local MAX = Data.max_specks or 600
local WHITE = { 1, 1, 1 }

local function acquire()
    local r = _free[#_free]
    if r then _free[#_free] = nil; return r end
    return {}
end

local function rnd(a, b) return a + (b - a) * love.math.random() end

local function spawn(x, y, vx, vy, g, life, size, color, ring)
    if #_live >= MAX then return end
    local r = acquire()
    r.x, r.y, r.vx, r.vy, r.g = x, y, vx, vy, g
    r.t, r.life, r.size, r.color, r.ring = 0, life, size, color, ring
    _live[#_live + 1] = r
end

function Sparks.burst(x, y, spec, opts)
    if not spec then return end
    local lvl = Motion.level("ui")
    if lvl <= Motion.NONE then return end
    local scale = (opts and opts.scale) or 1
    if lvl <= Motion.LOW then scale = scale * 0.5 end
    local n = math.floor((spec.specks or 0) * scale + 0.5)
    local colors = spec.colors
    local tint = opts and opts.tint
    local smin, smax = (spec.size and spec.size[1]) or 2, (spec.size and spec.size[2]) or 3
    local speed, up = spec.speed or 60, spec.up or 0
    for _ = 1, n do
        local a = rnd(0, 2 * math.pi)
        local sp = speed * rnd(0.5, 1.0)
        local vx, vy = math.cos(a) * sp, math.sin(a) * sp
        vy = vy * (1 - up) - sp * up                 -- bias upward
        local c = (colors and colors[love.math.random(1, #colors)]) or tint or WHITE
        spawn(x, y, vx, vy, spec.gravity or 0, (spec.life or 0.3) * rnd(0.8, 1.15),
              love.math.random(smin, smax), c, false)
    end
    if spec.ring and lvl > Motion.LOW then
        spawn(x, y, 0, 0, 0, 0.28, 2, tint or (colors and colors[1]) or WHITE, true)
    end
end

function Sparks.update(dt)
    if not dt or dt <= 0 then return end
    local w = 0
    for i = 1, #_live do
        local r = _live[i]
        r.t = r.t + dt
        if r.t >= r.life then
            _free[#_free + 1] = r
        else
            r.vy = r.vy + r.g * dt
            r.x, r.y = r.x + r.vx * dt, r.y + r.vy * dt
            w = w + 1
            _live[w] = r
        end
    end
    for i = #_live, w + 1, -1 do _live[i] = nil end
end

function Sparks.draw()
    local n = #_live
    if n == 0 then return end
    local lg = love.graphics
    local r0, g0, b0, a0 = lg.getColor()
    for i = 1, n do
        local r = _live[i]
        local p = r.t / r.life
        local a = (p < 0.5) and 1 or (1 - (p - 0.5) * 2)
        local c = r.color
        lg.setColor(c[1], c[2], c[3], a)
        if r.ring then
            local half = 4 + p * 22
            lg.setLineWidth(2)
            lg.rectangle("line", math.floor(r.x - half) + 0.5, math.floor(r.y - half) + 0.5, half * 2, half * 2)
        else
            local s = r.size
            lg.rectangle("fill", math.floor(r.x - s / 2), math.floor(r.y - s / 2), s, s)
        end
    end
    lg.setColor(r0, g0, b0, a0)
end

function Sparks.count() return #_live end
function Sparks.clear()
    for i = #_live, 1, -1 do _free[#_free + 1] = _live[i]; _live[i] = nil end
end

return Sparks
