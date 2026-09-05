-- views/IconText.lua
--
-- Inline icon + text renderer. Parses {token} markers in a string and draws
-- text runs interleaved with inline procedural icons, so data strings
-- (catalog effect_text, floaters) read with REAL icons instead of jargon.
--
-- Tokens:
--   {chip}                           → the Gold Chip currency glyph
--   {arrow}                          → a right-pointing "becomes" arrow
--   {small} {medium} {large} {stack} → outcome-tier glyphs via TierGlyph; a
--                                      win/loss prefix may be given as
--                                      "{l:large}" / "{w:small}" (absent → win)
--   {c:<meaning>:<text>}             → <text> printed in Theme.sem[<meaning>]
--                                      (data/theme.lua's colour code; the
--                                      words per meaning in data/terms.lua).
--                                      "_" in <text> is a space. {c:heat}
--                                      alone prints the meaning's name. An
--                                      unknown meaning prints literally.
--   {c:<meaning>:<text>}             → <text> printed in Theme.sem[<meaning>]
--                                      (data/theme.lua's colour code; the
--                                      words per meaning in data/terms.lua).
--                                      "_" in <text> is a space. {c:heat}
--                                      alone prints the meaning's name. An
--                                      unknown meaning prints literally.
--   {c:<meaning>:<text>}             → <text> printed in Theme.sem[<meaning>]
--                                      (data/theme.lua's colour code; the
--                                      words per meaning in data/terms.lua).
--                                      "_" in <text> is a space. {c:heat}
--                                      alone prints the meaning's name. An
--                                      unknown meaning prints literally.
--
-- Single line, no wrapping. DI: takes `game` for the sprite atlas; the actual
-- love.graphics work stays in views/Chips / services/SpriteRenderer.

local Icons     = require("views.Icons")
local TierGlyph = require("views.TierGlyph")
local Theme     = require("views.Theme")

local IconText = {}

-- A simple right-pointing arrow (shaft + head) filled in `color`, centered
-- vertically in a `size`-tall box at (x, y). The pixel font has no "→" glyph,
-- so this is the standardized "becomes" connector for tier transforms.
local function drawArrow(x, y, size, color, alpha)
    Theme.setColor(color or Theme.fg.muted, alpha)
    local cy      = math.floor(y + size * 0.5)
    local shaft_w = math.floor(size * 0.55)
    local th      = math.max(2, math.floor(size * 0.16))
    love.graphics.rectangle("fill", x, cy - math.floor(th / 2), shaft_w, th)
    local hx = x + shaft_w
    local hh = math.max(2, math.floor(size * 0.30))
    love.graphics.polygon("fill", hx, cy - hh, hx, cy + hh, x + size, cy)
end

local OUTCOME = { w = "win", l = "loss" }

-- A {c:…} token → its display text and colour, or nil when it is not one.
local function tintedWord(token)
    local cat, text = token:match("^c:([%w_]+):?(.*)$")
    if not cat then return nil end
    local color = Theme.semColor and Theme.semColor(cat) or nil
    if not color then return nil end
    if text == "" then text = cat end
    return (text:gsub("_", " ")), color
end

-- Width of a {token}'s glyph at `size` (0 = not a known icon token).
local function tokenWidth(token, size, font)
    local word = tintedWord(token)
    if word then return font and font:getWidth(word) or 0 end
    if token == "chip" or token == "achip" or token == "arrow" then return size end
    local _, name = token:match("^(%w+):(%w+)$")
    name = name or token
    if TierGlyph.has(name) then return TierGlyph.radius(size) * 2 end
    return 0
end

-- Draw a {token} icon at (x, y). Width comes from tokenWidth.
local function drawToken(game, token, x, y, size, color, alpha, font)
    local word, tint = tintedWord(token)
    if word then
        Theme.setColor(tint, alpha)
        love.graphics.setFont(font)
        love.graphics.print(word, x, y)
        return
    end
    if token == "chip" then
        Icons.drawChip(game, x, y, size, alpha)
    elseif token == "achip" then
        Icons.drawAntiChip(game, x, y, size, alpha)
    elseif token == "arrow" then
        drawArrow(x, y, size, color, alpha)
    else
        local pre, name = token:match("^(%w+):(%w+)$")
        name = name or token
        if TierGlyph.has(name) then
            local r = TierGlyph.radius(size)
            TierGlyph.draw(x + r, y + size - r, name, r, OUTCOME[pre or ""] or "win", alpha)
        end
    end
end

-- Walk `str`, drawing glyphs/text when `draw` is true and accumulating width.
-- One implementation backs both IconText.draw and IconText.measure.
local function walk(game, str, x, y, font, color, alpha, draw)
    str = str or ""
    local size = font:getHeight()
    local gap  = math.max(1, math.floor(size * 0.12))
    local cx, i, n = x, 1, #str

    local function text(seg)
        if seg == "" then return end
        if draw then
            if color then Theme.setColor(color, alpha) end
            love.graphics.setFont(font)
            love.graphics.print(seg, cx, y)
        end
        cx = cx + font:getWidth(seg)
    end

    while i <= n do
        local s, e, token = str:find("{([%w_:]+)}", i)
        if not s then text(str:sub(i)); break end
        text(str:sub(i, s - 1))
        local iw = tokenWidth(token, size, font)
        if iw == 0 then
            text(str:sub(s, e))            -- unknown token → literal text
        elseif tintedWord(token) then
            -- A tinted word is text: no icon gap, its own width.
            if draw then drawToken(game, token, cx, y, size, color, alpha, font) end
            cx = cx + iw
        else
            if draw then drawToken(game, token, cx, y, size, color, alpha) end
            cx = cx + iw + gap
        end
        i = e + 1
    end
    return cx - x
end

-- Render `str` left-anchored at (x, y) in `font`. `color` is the text Theme
-- token (icons keep their own colors); `alpha` fades the whole thing. Returns
-- total drawn width.
function IconText.draw(game, str, x, y, font, color, alpha)
    return walk(game, str, x, y, font, color, alpha or 1, true)
end

-- Total rendered width of `str` in `font`, without drawing.
function IconText.measure(str, font)
    return walk(nil, str, 0, 0, font, nil, 1, false)
end

-- Greedy word wrap to `max_w`, measured through IconText so an inline icon
-- counts at its drawn width. Markers never contain spaces, so splitting on
-- them never splits a {token}. Returns a list of lines (at least one).
function IconText.wrap(str, font, max_w)
    local lines, cur = {}, nil
    for word in tostring(str or ""):gmatch("%S+") do
        local try = cur and (cur .. " " .. word) or word
        if cur and IconText.measure(try, font) > max_w then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    lines[#lines + 1] = cur or ""
    return lines
end

return IconText
