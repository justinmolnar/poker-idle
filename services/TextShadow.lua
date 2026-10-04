-- services/TextShadow.lua
--
-- A hard drop shadow under all text. install() wraps love.graphics.print
-- and love.graphics.printf once: each call draws the string again first,
-- in the shadow colour, offset down-right by a fraction of the font's
-- character width (data/text_shadow), then the string itself. Everything
-- that prints gets it with no call-site changes: the panels' cached
-- pictures, tooltips, the rail, IconText's words (its icons are shapes and
-- keep their own look).
--
-- Not shadowed: coloured-text tables (their colours are per piece), empty
-- strings, fully transparent text, and anything drawn while suspended
-- (TextShadow.suspend / resume, counted). Text objects and batches
-- (love.graphics.draw) are not prints; the floaters that use them carry
-- their own outline.
--
-- Allocation-free per call: the offset is memoized per font.

local Cfg = require("data.text_shadow")

local TextShadow = {}

local _raw_print, _raw_printf
local _offset = setmetatable({}, { __mode = "k" })
local _suspended = 0

local function offsetFor(font)
    local o = _offset[font]
    if not o then
        local cw = (font and font.getWidth and font:getWidth("0")) or 8
        o = math.max(Cfg.min_px or 1, math.floor(cw * (Cfg.char_frac or 0.3) + 0.5))
        _offset[font] = o
    end
    return o
end
TextShadow.offsetFor = offsetFor

local function shouldShadow(text)
    if _suspended > 0 or not Cfg.enabled then return false end
    local t = type(text)
    if t == "string" then return text ~= "" end
    return t == "number"
end

-- The shadow pass for one call: returns nothing; leaves the colour as it
-- found it.
local function shadow(raw, text, x, y, ...)
    local lg = love.graphics
    local r, g, b, a = lg.getColor()
    if a <= 0.01 then return end
    local o = offsetFor(lg.getFont())
    local c = Cfg.color
    lg.setColor(c[1], c[2], c[3], a * (Cfg.alpha or 1))
    raw(text, (x or 0) + o, (y or 0) + o, ...)
    lg.setColor(r, g, b, a)
end

function TextShadow.install()
    if _raw_print or not (love and love.graphics and love.graphics.print) then return end
    local lg = love.graphics
    _raw_print, _raw_printf = lg.print, lg.printf
    lg.print = function(text, x, y, ...)
        if shouldShadow(text) then shadow(_raw_print, text, x, y, ...) end
        return _raw_print(text, x, y, ...)
    end
    lg.printf = function(text, x, y, ...)
        if shouldShadow(text) then shadow(_raw_printf, text, x, y, ...) end
        return _raw_printf(text, x, y, ...)
    end
end

-- Put the originals back (tests).
function TextShadow.uninstall()
    if not _raw_print then return end
    love.graphics.print, love.graphics.printf = _raw_print, _raw_printf
    _raw_print, _raw_printf = nil, nil
end

function TextShadow.suspend() _suspended = _suspended + 1 end
function TextShadow.resume() _suspended = math.max(0, _suspended - 1) end

return TextShadow
