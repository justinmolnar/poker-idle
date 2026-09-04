-- views/DeckArt.lua
--
-- A deck, drawn at any size: its card-back art plus the ONE language for
-- what a level looks like. The roster tiles, the roster's preview and the
-- top-bar cell all draw through here, so a deck reads the same everywhere.
-- (The felt's face-down cards keep views/CardSprites.back, which owns the
-- mip chain; they carry no level marks.)
--
--   • Art: cover-scaled into the rect, cropped by scissor.
--   • Level: five PIPS along the top edge, filled to the level. The fifth
--     pip is the capstone — a diamond, gold when earned. At the cap the art
--     itself draws through the foil shader (shaders/foil.frag, the loud
--     polychrome) inside a border whose colour runs round the spectrum.
--     Nothing else changes with level: no colour tables, no dirty overlay.
--   • Locked: the art is grey and dim above a FILL LINE and full colour
--     below it, filling bottom-up with progress toward the unlock (the
--     desaturate shader, two scissored passes). The line is a readout and
--     never animates.
--
-- Stateless. opts:
--   level        (0..max_level)      — pips filled; foil at the cap
--   max_level    (default 5)
--   locked_frac  (0..1 or nil)       — nil = unlocked; else the fill-up
--   scale        (default game.ui_scale)
--   pips         (default true)      — false to draw the art only
--   alpha        (default 1)

local Theme          = require("views.Theme")
local ShaderRegistry = require("services.ShaderRegistry")

local Motion         = require("services.Motion")
local DeckArt = {}

local PIP_BASE       = 9     -- pip side, px at scale 1
local PIP_GAP_BASE   = 4
local PIP_INSET_BASE = 6     -- from the top edge
-- Grey band above the fill line: fully desaturated and pushed down so the
-- coloured part below reads as the earned part, not merely the brighter one.
local LOCKED_DIM     = 0.45
local FILL_LINE_BASE = 1
local FOIL_EDGE_BASE = 3     -- the prismatic border at the cap

local function hsv(h, sv, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p, q, t = v * (1 - sv), v * (1 - f * sv), v * (1 - (1 - f) * sv)
    if i == 0 then return v, t, p elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v else return v, p, q end
end

local function coverRect(sprite, x, y, w, h)
    local sw, sh = sprite:getWidth(), sprite:getHeight()
    local scale  = math.max(w / sw, h / sh)
    local dw, dh = sw * scale, sh * scale
    return x + math.floor((w - dw) / 2), y + math.floor((h - dh) / 2), scale
end

-- The art once, clipped to `cy, ch` (a horizontal band of the rect).
local function drawBand(sprite, x, y, w, h, cy, ch, shader, r, g, b, a)
    if ch <= 0 then return end
    local sx, sy, sw, sh = love.graphics.getScissor()
    love.graphics.setScissor(x, cy, w, ch)
    if shader then love.graphics.setShader(shader) end
    local dx, dy, scale = coverRect(sprite, x, y, w, h)
    love.graphics.setColor(r, g, b, a)
    love.graphics.draw(sprite, dx, dy, 0, scale, scale)
    if shader then love.graphics.setShader() end
    if sx then love.graphics.setScissor(sx, sy, sw, sh) else love.graphics.setScissor() end
end

local function drawPips(x, y, w, s, level, max_level, alpha)
    local side  = math.max(3, math.floor(PIP_BASE * s))
    local gap   = math.max(1, math.floor(PIP_GAP_BASE * s))
    local inset = math.floor(PIP_INSET_BASE * s)
    local total = max_level * side + (max_level - 1) * gap
    local px    = x + math.floor((w - total) / 2)
    local py    = y + inset
    -- A dark pill behind the row so the pips read on any art.
    Theme.setColor(Theme.bg.window, 0.85 * alpha)
    love.graphics.rectangle("fill", px - gap * 2, py - gap, total + gap * 4, side + gap * 2, side * 0.5)
    local gold = Theme.currency and Theme.currency.chip or Theme.fg.heading
    for i = 1, max_level do
        local cx = px + (i - 1) * (side + gap)
        local filled = i <= level
        if i == max_level then
            -- The capstone pip: a diamond, gold once earned.
            local mx, my, r = cx + side / 2, py + side / 2, side / 2 + 0.5
            local poly = { mx, my - r, mx + r, my, mx, my + r, mx - r, my }
            if filled then
                Theme.setColor(gold, alpha)
                love.graphics.polygon("fill", poly)
            else
                Theme.setColor(Theme.bg.sunken, alpha)
                love.graphics.polygon("fill", poly)
                Theme.setColor(Theme.fg.muted, alpha)
                love.graphics.polygon("line", poly)
            end
        else
            if filled then
                Theme.setColor(Theme.fg.heading, alpha)
                love.graphics.rectangle("fill", cx, py, side, side, 1)
            else
                Theme.setColor(Theme.bg.sunken, alpha)
                love.graphics.rectangle("fill", cx, py, side, side, 1)
                Theme.setColor(Theme.fg.muted, alpha)
                love.graphics.rectangle("line", cx, py, side, side, 1)
            end
        end
    end
end

function DeckArt.draw(game, spec, x, y, w, h, opts)
    opts = opts or {}
    local s         = opts.scale or (game and game.ui_scale) or 1
    local alpha     = opts.alpha or 1
    local level     = opts.level or 0
    local max_level = opts.max_level or (spec and spec.max_level) or 5
    local sprite    = spec and game and game.sprite_loader
                      and game.sprite_loader:getSprite(spec.sprite)

    -- Backing, for the art's rounded-corner pixels and the missing-art case.
    Theme.setColor(Theme.bg.sunken, alpha)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)

    if sprite then
        if opts.locked_frac ~= nil then
            local frac  = math.max(0, math.min(1, opts.locked_frac))
            local split = y + h - math.floor(h * frac)
            local desat = ShaderRegistry.get("desaturate")
            if desat then desat:send("u_amount", 1.0) end
            drawBand(sprite, x, y, w, h, y, split - y, desat,
                     LOCKED_DIM, LOCKED_DIM, LOCKED_DIM, alpha)
            drawBand(sprite, x, y, w, h, split, y + h - split, nil, 1, 1, 1, alpha)
            if frac > 0 and frac < 1 then
                local lw = math.max(1, math.floor(FILL_LINE_BASE * s))
                Theme.setColor(Theme.fg.heading, alpha)
                love.graphics.rectangle("fill", x, split - lw, w, lw)
            end
        else
            local shader = nil
            -- Motion: High drops the sparkles; below High the foil and its
            -- border hold still.
            local now = Motion.time("shine", (game and game.time and game.time.total_time) or 0)
            if level >= max_level then
                shader = ShaderRegistry.get("foil")
                if shader then
                    shader:send("u_time", now)
                    pcall(shader.send, shader, "u_sparkle", Motion.at("shine", Motion.FULL) and 1 or 0)
                end
            end
            drawBand(sprite, x, y, w, h, y, h, shader, 1, 1, 1, alpha)
            if level >= max_level then
                -- The prismatic border: four edges, each a different point
                -- on the spectrum, all of it turning.
                local lw = math.max(2, math.floor(FOIL_EDGE_BASE * s))
                local edges = {
                    { x, y, w, lw }, { x, y + h - lw, w, lw },
                    { x, y, lw, h }, { x + w - lw, y, lw, h },
                }
                for i, e in ipairs(edges) do
                    local r, g, b = hsv((now * 0.35 + (i - 1) * 0.25) % 1, 0.9, 1)
                    love.graphics.setColor(r, g, b, alpha)
                    love.graphics.rectangle("fill", e[1], e[2], e[3], e[4])
                end
            end
        end
    else
        local fonts = game and game.fonts
        if fonts and fonts.md then
            love.graphics.setFont(fonts.md)
            Theme.setColor(Theme.fg.faint, 0.4 * alpha)
            love.graphics.printf("?", x, y + math.floor((h - fonts.md:getHeight()) / 2), w, "center")
        end
    end

    if opts.pips ~= false then
        drawPips(x, y, w, s, level, max_level, alpha)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- Height the pip row occupies from the top of the rect, so a caller can
-- keep its own overlays clear of it.
function DeckArt.pipRowHeight(s)
    s = s or 1
    return math.floor(PIP_INSET_BASE * s) + math.max(3, math.floor(PIP_BASE * s))
           + math.max(1, math.floor(PIP_GAP_BASE * s))
end

return DeckArt
