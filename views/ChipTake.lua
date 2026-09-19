-- views/ChipTake.lua
--
-- THE TAKE: the chips a run banked, thrown onto the felt after the shove,
-- one physical chip per chip banked, before the catalog and the flyer
-- land on top of them. A handful falls in a loose cluster; a big run
-- floods the felt. Each lands with a warm glow that settles to a faint
-- rest and stays there until the player leaves.
--
-- Pure functions over a record ShoveView holds (`view.take`), the way
-- TablePanelDrag is functions over GrindView's latch. Built on what the
-- buildup's pour already does (views/ShoveView: per-chip records with an
-- emit time, an arrive time and a Tumble-wrapped render function, drawn
-- by hand with an ease-out and a sine arc, chip_land_pot on each landing):
--
--   spots   services/Decal.place, keyed "take:<throw>:<i>" so every landing
--           is stable across frames and different from every other
--   chip    views/Chips.drawGlyph, the currency gold by default
--   flight  services/Tumble.wrap with the pour's preset (ShoveView passes it)
--   glow    views/ShoveDecor.drawLight, the soft quad the room's emitters use
--   knobs   data/shove_style.lua `take`
--
-- Motion: the flights tumble on the "chips" group; at LOW the chips are
-- simply there, fading in, with no landings to ramp.

local Chips      = require("views.Chips")
local Theme      = require("views.Theme")
local Decal      = require("services.Decal")
local Tumble     = require("services.Tumble")
local Motion     = require("services.Motion")
local ShoveDecor = require("views.ShoveDecor")
local Style      = require("data.shove_style")

local ChipTake = {}

local function cfg() return Style.take or {} end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function easeOut(t) return 1 - (1 - t) ^ 3 end

-- Push a chip of radius r at (x, y) out of `rect` by the shortest way, with
-- a little gap: up or down off the BANKED line's wide strip, sideways off
-- the book or the flyer when that is nearer. Returns x, y.
local function pushOut(x, y, r, rect, gap)
    if not rect then return x, y end
    if not (x + r > rect.x and x - r < rect.x + rect.w
            and y + r > rect.y and y - r < rect.y + rect.h) then
        return x, y
    end
    local left  = (x + r) - rect.x
    local right = (rect.x + rect.w) - (x - r)
    local up    = (y + r) - rect.y
    local down  = (rect.y + rect.h) - (y - r)
    local m = math.min(left, right, up, down)
    if     m == up    then y = rect.y - r - gap
    elseif m == down  then y = rect.y + rect.h + r + gap
    elseif m == left  then x = rect.x - r - gap
    else                   x = rect.x + rect.w + r + gap end
    return x, y
end

-- Build the take: `n` chips, keyed off `key`, landing around the felt's
-- rest point and clear of every rect in `avoid` (the BANKED line's, the
-- book's, the flyer's), each pushed out the shortest way. `preset` is the
-- tumble the pour uses. Returns nil for no chips.
function ChipTake.begin(n, key, W, H, s, avoid, preset)
    n = math.floor(n or 0)
    if n <= 0 then return nil end
    local C   = cfg()
    local r   = math.max(4, math.floor((C.chip_r or 14) * (s or 1)))
    local I   = C.interval or {}
    local spacing = clamp((I.total or 1.4) / n, I.min or 0.02, I.max or 0.12)
    -- A handful lands in a loose cluster; a flood covers the felt. The
    -- spread grows with the square root of the count so the density
    -- stays readable, floored so even one chip has somewhere to be.
    local SP   = C.spread or {}
    local grow = math.min(1, math.sqrt(n / 60))
    local sx   = math.max((SP.min_x or 60) * s, W * (SP.x or 0.42) * grow)
    local sy   = math.max((SP.min_y or 40) * s, H * (SP.y or 0.26) * grow)
    local rest_x, rest_y = W * 0.5, H * (C.rest_y or 0.58)
    local low  = Motion.level("chips") <= Motion.LOW
    local take = {
        t = 0, n = n, r = r, landed = 0, low = low,
        spacing = spacing, flight = C.flight_secs or 0.45,
        arc = (C.arc_lift or 110) * (s or 1),
        W = W, H = H, chips = {},
    }
    for i = 1, n do
        local dx, dy, angle = Decal.place(key .. ":" .. i, { dx = sx, dy = sy, angle = 0.8 })
        local x = clamp(math.floor(rest_x + dx), r + 4, W - r - 4)
        local y = clamp(math.floor(rest_y + dy), r + 4, H - r - 4)
        -- Two passes: clearing one rect can land a chip on another.
        for _ = 1, 2 do
            for _, rect in ipairs(avoid or {}) do
                x, y = pushOut(x, y, r, rect, 6 * (s or 1))
            end
        end
        x = clamp(x, r + 4, W - r - 4)
        y = clamp(y, r + 4, H - r - 4)
        local emit = (i - 1) * spacing
        local c = {
            x = x, y = y, angle = angle,
            emit_t = emit, arrive_t = emit + take.flight,
            -- A fan from above the frame, not a single hole in the ceiling.
            from_x = math.floor(rest_x + (x - rest_x) * 0.3),
            from_y = math.floor((C.from_y or -60) * (s or 1)),
            landed = low, landed_at = low and 0 or nil,
        }
        if not low then
            -- Rolled once here: Tumble randomises its axis and spin per
            -- wrap, so wrapping in the draw would reroll every frame.
            c.render_fn = Tumble.wrap(function(px, py, _t, _squash)
                Chips.drawGlyph(px, py, r, 1, 1)
            end, preset, "chips")
        end
        take.chips[i] = c
    end
    if low then take.landed = n end
    return take
end

-- Advance the clock; land what has arrived, with the pour's rising
-- landing sound (the mix's own min_gap throttles a flood).
function ChipTake.update(take, dt, sounds)
    if not take then return end
    take.t = take.t + (dt or 0)
    local P = cfg().land_pitch or {}
    for i, c in ipairs(take.chips) do
        if not c.landed and take.t >= c.arrive_t then
            c.landed, c.landed_at = true, take.t
            take.landed = take.landed + 1
            if sounds and sounds.playNamed then
                local pitch = sounds.rampPitch
                    and sounds.rampPitch(i, take.n, P.from or 0.9, P.to or 1.4) or 1
                sounds.playNamed("chip_land_pot", { pitch = pitch })
            end
        end
    end
end

function ChipTake.done(take)
    return take ~= nil and take.landed >= take.n
end

-- The glow under every landed chip: bright on landing, settling to a
-- faint rest, breathing a little at high motion. Additive, like the
-- room's lightmap; nothing draws when the light quad was never built
-- (the headless stub).
function ChipTake.drawLights(take)
    if not take or not ShoveDecor.hasLight() then return end
    local G = cfg().glow or {}
    local d = take.r * (G.d_mult or 3.2)
    local breathe = Motion.at("shine", Motion.HIGH)
        and (1 + 0.08 * math.sin(take.t * 2.2)) or 1
    local a0, a1, fade = G.alpha or 0.30, G.rest or 0.07, G.fade_secs or 2.5
    love.graphics.setBlendMode("add")
    for _, c in ipairs(take.chips) do
        if c.landed then
            local age = take.t - (c.landed_at or 0)
            local k   = math.min(1, age / fade)
            local a   = (a0 + (a1 - a0) * k) * breathe
            if take.low then a = a * math.min(1, take.t / 0.5) end
            ShoveDecor.drawLight(c.x - d / 2, c.y - d / 2, d, d, G.color or Theme.currency.chip, a)
        end
    end
    love.graphics.setBlendMode("alpha")
end

-- The chips: landed ones still, at their spot and lean; airborne ones on
-- the pour's flight (ease-out toward the spot, a sine arc, the tumble on
-- raw t), each throwing a shadow onto the spot it is falling toward.
function ChipTake.drawChips(take)
    if not take then return end
    local r = take.r
    for _, c in ipairs(take.chips) do
        if c.landed then
            local a = take.low and math.min(1, take.t / 0.5) or 1
            love.graphics.push()
            love.graphics.translate(c.x, c.y)
            love.graphics.rotate(c.angle or 0)
            Chips.drawGlyph(0, 0, r, a, 1)
            love.graphics.pop()
        elseif take.t >= c.emit_t then
            local t = clamp((take.t - c.emit_t) / take.flight, 0, 1)
            local et = easeOut(t)
            local x  = c.from_x + (c.x - c.from_x) * et
            local y  = c.from_y + (c.y - c.from_y) * et - take.arc * math.sin(math.pi * t)
            local height = math.sin(math.pi * t)
            -- The shadow lands before the chip does: on the spot, small
            -- and faint while the chip is high, full as it arrives.
            Theme.setColor({ 0, 0, 0 }, 0.35 * (1 - 0.5 * height) * et)
            love.graphics.ellipse("fill", c.x, c.y + r * 0.35,
                                  r * (1.1 - 0.4 * height), r * 0.55 * (1.1 - 0.4 * height))
            if c.render_fn then c.render_fn(x, y, t) else Chips.drawGlyph(x, y, r, 1, 1) end
        end
    end
end

return ChipTake
