-- views/IconText.lua
--
-- Inline icon + text renderer. Parses {token} markers in a string and draws
-- text runs interleaved with inline procedural icons, so data strings
-- (catalog effect_text, floaters) read with REAL icons instead of jargon.
--
-- Tokens (a token holds only word characters, "_", "-" and ":"):
--   {chip} {achip}                   → the Gold Chip / anti-chip glyphs
--   {arrow}                          → a right-pointing "becomes" arrow
--   {table}                          → the tabletop icon alone (the table
--                                      pills' icon, e.g. by ADD TABLE)
--   {small} {medium} {large} {stack} → outcome-tier glyphs via TierGlyph; a
--                                      win/loss prefix may be given as
--                                      "{l:large}" / "{w:small}" (absent → win)
--   {c:<meaning>:<text>}             → <text> printed in Theme.sem[<meaning>]
--                                      (data/theme.lua's colour code; the
--                                      words per meaning in data/terms.lua).
--                                      "_" in <text> is a space. {c:heat}
--                                      alone prints the meaning's name. An
--                                      unknown meaning prints literally. A
--                                      heat or tilt word gets its status
--                                      glyph in front (Icons.drawFlame /
--                                      drawTilt).
--   {t:<id>}                         → a table pill (zoom, hu, 6m, ko, any,
--                                      adjacent, random, this): felt green,
--                                      a tabletop icon and a short code
--                                      (ZOOM, HU, ADJACENT...). The pill is
--                                      the table noun. Ids and codes:
--                                      data/terms.lua `tables`.
--   {k:<text>}                       → a keyword (a knockout, a rebuy):
--                                      the word embossed, printed four times
--                                      offset by a pixel in Theme.embossFor
--                                      (the text colour) then once in the
--                                      text colour. No hue spent. The list of
--                                      keywords is data/terms.lua `keywords`;
--                                      the lint checks it, the renderer does
--                                      not.
--
-- Numbers need no markup. The three shapes the style sheet allows
-- (docs/copy-style.md) are found in plain text and drawn as pills:
--   "1 in 4"        chance   filled in Theme.sem.chance (the teal)
--   "×1.25"         multiplier  filled in the text colour, digits in contrast
--   "+10%" "-15%" "+$5" "+2"  quantity  a 1px outline in the text colour
-- A digit glued to a letter, "-", "+" or ":" is not a number (6-Max, NL2,
-- 4+ tables, 12:00), the same rule sim/lint_copy.lua uses.
--
-- Wraps through IconText.wrap (a chance pill never splits across lines).
-- IconText.spans gives every token's x/width for hit-testing. DI: takes
-- `game` for the sprite atlas; the actual love.graphics work stays in
-- views/Chips / views/Icons / services/SpriteRenderer.

local Icons       = require("views.Icons")
-- Catalog items by id, for {item:id} (built on first use).
local _items_by_id
local function itemById(id)
    if not _items_by_id then
        _items_by_id = {}
        for _, it in ipairs(require("data.catalog")) do _items_by_id[it.id] = it end
    end
    return _items_by_id[id]
end
local TierGlyph   = require("views.TierGlyph")
local Theme       = require("views.Theme")
local FontService = require("services.FontService")
local Perf        = require("services.Perf")

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

-- Table pills by id (data/terms.lua `tables`).
local TABLE_PILLS = {}
for _, t in ipairs(require("data.terms").tables or {}) do TABLE_PILLS[t.id] = t end
-- A stake as the same pill ({s:s001} → NL2): the felt tab with the stake's
-- name, where copy names the stake a thing lands at.
local STAKE_PILLS = {}
for _, st in ipairs(require("data.stakes")) do STAKE_PILLS[st.id] = st.display_name or st.id end

-- Meanings whose words wear a glyph in front.
local WORD_GLYPH = { heat = "heater", tilt = "tilt" }

-- The four one-pixel offsets of the emboss (cardinal; a pixel font's
-- strokes are axis-aligned, so diagonals only thicken the corners).
local EMBOSS = Theme.HALO_OFFSETS

-- ── Parsing ────────────────────────────────────────────────────────────

-- A {c:…} token → its display text, colour and meaning, or nil.
local function tintedWord(token)
    local cat, text = token:match("^c:([%w_]+):?(.*)$")
    if not cat then return nil end
    local color = Theme.semColor and Theme.semColor(cat) or nil
    if not color then return nil end
    if text == "" then text = cat end
    return (text:gsub("_", " ")), color, cat
end

-- A {k:…} token → its display text, or nil.
local function keyword(token)
    local text = token:match("^k:(.+)$")
    if not text then return nil end
    return (text:gsub("_", " "))
end

-- Is the byte at `i` (or "" past the ends) a character a number may sit
-- next to? Digits glued to letters/hyphens/plus/colons are not numbers.
local function looseBefore(s, i)
    if i < 1 then return true end
    local c = s:sub(i, i)
    return not c:match("[%w%-%.:%+×$]")
end
local function looseAfter(s, i)
    if i > #s then return true end
    local c = s:sub(i, i)
    return not c:match("[%w%-%+:]")
end

-- Find the first pill at or after `i` in a plain run. Returns s, e, kind.
local function findPill(run, i)
    local n = #run
    while i <= n do
        local c = run:sub(i, i)
        -- chance: "N in M"
        if c:match("%d") and looseBefore(run, i - 1) then
            local s, e = run:find("^%d+ in %d+", i)
            if s and looseAfter(run, e + 1) then return s, e, "chance" end
        end
        -- multiplier: "×N" (× is two bytes, C3 97)
        if c == "\195" and run:sub(i, i + 1) == "×" and looseBefore(run, i - 1) then
            local s, e = run:find("^×%d+%.?%d*", i)
            if s then
                if run:sub(e, e) == "." then e = e - 1 end
                if looseAfter(run, e + 1) then return s, e, "mult" end
            end
        end
        -- quantity: "+10%", "-15%", "+$5", "+$100,000", "+2"
        if (c == "+" or c == "-") and looseBefore(run, i - 1) then
            local s, e = run:find("^[%+%-]%$?%d[%d,]*%.?%d*%%?", i)
            if s then
                while run:sub(e, e) == "." or run:sub(e, e) == "," do e = e - 1 end
                if looseAfter(run, e + 1) then return s, e, "qty" end
            end
        end
        i = i + 1
    end
    return nil
end

-- Split a plain run into { {kind="text", s} | {kind="pill", s, pill} }.
local function splitRun(run, out)
    local i = 1
    while i <= #run do
        local s, e, kind = findPill(run, i)
        if not s then
            out[#out + 1] = { kind = "text", s = run:sub(i) }
            return
        end
        if s > i then out[#out + 1] = { kind = "text", s = run:sub(i, s - 1) } end
        out[#out + 1] = { kind = "pill", s = run:sub(s, e), pill = kind }
        i = e + 1
    end
end

-- `str` → a list of elements. Pure; no love calls. `pills` false leaves
-- numbers as text (the chrome, the floaters: readouts, not prose).
local function parseUncached(str, pills)
    Perf.count("icontext_parse")
    str = str or ""
    local els = {}
    local i, n = 1, #str
    local function run(seg)
        if pills then splitRun(seg, els) else els[#els + 1] = { kind = "text", s = seg } end
    end
    while i <= n do
        local s, e, token = str:find("{([%w_:%-]+)}", i)   -- "-" for 6-Max, Heads-Up
        if not s then run(str:sub(i)) break end
        if s > i then run(str:sub(i, s - 1)) end
        local word, tint, cat = tintedWord(token)
        local key = keyword(token)
        if word then
            els[#els + 1] = { kind = "tint", s = word, color = tint, cat = cat, glyph = WORD_GLYPH[cat] }
        elseif key then
            els[#els + 1] = { kind = "key", s = key }
        elseif token == "chip" or token == "achip" or token == "arrow" or token == "table" or token == "ko" then
            els[#els + 1] = { kind = "icon", token = token }
        elseif token:match("^t:[%w_]+$") and TABLE_PILLS[token:sub(3)] then
            local t = TABLE_PILLS[token:sub(3)]
            els[#els + 1] = { kind = "table", s = t.code, token = t.id }
        elseif token:match("^s:[%w_]+$") and STAKE_PILLS[token:sub(3)] then
            els[#els + 1] = { kind = "table", s = STAKE_PILLS[token:sub(3)], token = token }
        elseif token:match("^item:[%w_]+$") then
            -- A catalog item's art at text height ({item:mirror}).
            els[#els + 1] = { kind = "item", id = token:sub(6) }
        elseif token == "page" then
            -- A page break in the House's copy (views/StoryView cuts the
            -- block there before it draws); nothing on the line itself.
        else
            local pre, name = token:match("^(%w+):(%w+)$")
            name = name or token
            if TierGlyph.has(name) then
                els[#els + 1] = { kind = "tier", name = name, outcome = OUTCOME[pre or ""] or "win" }
            else
                run(str:sub(s, e))   -- unknown token → literal text
            end
        end
        i = e + 1
    end
    return els
end

-- ── Caches ─────────────────────────────────────────────────────────────
-- Nearly every string here is measured and then drawn in the same frame,
-- and most are drawn again next frame unchanged — so parsing was running
-- two to four times per string per frame, allocating an element list each
-- time. These caches make that once.
--
-- Bounded by a cap and a wipe rather than by weak tables: floaters and
-- money readouts mint genuinely new strings forever, so an unbounded cache
-- would be a slow leak. The cap is far above a frame's working set, so a
-- wipe is rare and costs one re-parse of whatever is on screen.
--
-- The element lists handed out are SHARED and must be treated as read-only;
-- walk() only reads them.
local PARSE_CAP = 1024
local _parse_pills, _parse_plain, _parse_n = {}, {}, 0

local function parse(str, pills)
    local cache = pills and _parse_pills or _parse_plain
    local hit = cache[str]
    if hit then return hit end
    local els = parseUncached(str, pills)
    if _parse_n >= PARSE_CAP then
        _parse_pills, _parse_plain, _parse_n = {}, {}, 0
        cache = pills and _parse_pills or _parse_plain
    end
    cache[str]  = els
    _parse_n = _parse_n + 1
    return els
end

-- ── Metrics ────────────────────────────────────────────────────────────

-- Derived purely from the font, and a fresh table per walk() call before
-- this. Weak keys so a font rebuilt on resize drops its entry.
local _metrics_cache = setmetatable({}, { __mode = "k" })

local function metricsUncached(font)
    local size = font:getHeight()
    local ink  = math.floor(FontService.inkHeight(font) + 0.5)
    return {
        size   = size,
        gap    = math.max(1, math.floor(size * 0.12)),
        ink    = ink,
        ink_y  = math.floor((size - ink) / 2),            -- ink top, from the line top
        pad_x  = math.max(2, math.floor(size * 0.18)),
        pad_y  = math.max(1, math.floor(size * 0.08)),
        glyph  = math.max(4, ink),                         -- a status glyph's box
    }
end

local function metrics(font)
    local m = _metrics_cache[font]
    if not m then
        m = metricsUncached(font)
        _metrics_cache[font] = m
    end
    return m
end

local function elementWidth(el, font, m)
    if el.kind == "text" then return font:getWidth(el.s) end
    if el.kind == "pill" then return font:getWidth(el.s) + m.pad_x * 2 end
    if el.kind == "tint" then
        local w = font:getWidth(el.s)
        if el.glyph then w = w + m.glyph + m.gap end
        return w
    end
    if el.kind == "key"  then return font:getWidth(el.s) + 2 end
    if el.kind == "icon" and el.token == "table" then return math.floor(m.ink * 1.5) + m.gap end
    if el.kind == "icon" and el.token == "ko"    then return Icons.koWidth(m.size) + m.gap end
    if el.kind == "icon" then return m.size + m.gap end
    if el.kind == "item" then return m.size + m.gap end
    if el.kind == "table" then
        return font:getWidth(el.s) + m.pad_x * 2 + math.floor(m.ink * 1.5) + m.gap
    end
    if el.kind == "tier" then return TierGlyph.width(el.name, TierGlyph.radius(m.size)) + m.gap end
    return 0
end

-- ── Drawing ────────────────────────────────────────────────────────────

local function currentColor()
    local r, g, b = love.graphics.getColor()
    return { r, g, b }
end

local function drawPill(el, x, y, font, m, color, alpha)
    local tw   = font:getWidth(el.s)
    local w    = tw + m.pad_x * 2
    local py   = y + m.ink_y - m.pad_y
    local ph   = m.ink + m.pad_y * 2
    local r    = Theme.space.radius
    local fill, digits
    if el.pill == "chance" then
        fill   = Theme.sem.chance or color
        digits = Theme.contrastFor(fill)
    elseif el.pill == "mult" then
        fill   = color
        digits = Theme.contrastFor(fill)
    end
    love.graphics.setFont(font)
    if fill then
        Theme.setColor(fill, alpha)
        love.graphics.rectangle("fill", x, py, w, ph, r)
        Theme.setColor(digits, alpha)
        love.graphics.print(el.s, x + m.pad_x, y)
    else
        Theme.setColor(color, alpha)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x + 0.5, py + 0.5, w - 1, ph - 1, r)
        love.graphics.print(el.s, x + m.pad_x, y)
    end
end

-- The tabletop: a rounded rail (the heading colour) around felt, iw x ih.
local function drawTabletop(ix, iy, iw, ih, alpha)
    local tp = Theme.table_pill or {}
    local ir = math.max(1, math.floor(ih * 0.4))
    Theme.setColor(Theme.fg.heading, alpha)
    love.graphics.rectangle("fill", ix, iy, iw, ih, ir)
    Theme.setColor(tp.felt or Theme.bg.felt, alpha)
    local inset = math.max(1, math.floor(ih * 0.2))
    love.graphics.rectangle("fill", ix + inset, iy + inset, iw - inset * 2, ih - inset * 2, math.max(1, ir - inset))
end

-- A table pill: the felt tab, the tabletop (a rounded rail around felt, at
-- the ink height, 1.5:1), then the code.
local function drawTable(el, x, y, font, m, alpha)
    local tp = Theme.table_pill or {}
    local iw = math.floor(m.ink * 1.5)
    local w  = font:getWidth(el.s) + m.pad_x * 2 + iw + m.gap
    local py = y + m.ink_y - m.pad_y
    local ph = m.ink + m.pad_y * 2
    local r  = Theme.space.radius
    Theme.setColor(tp.fill or Theme.sem.won, alpha)
    love.graphics.rectangle("fill", x, py, w, ph, r)
    Theme.setColor(tp.rim or Theme.fg.heading, alpha)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, py + 0.5, w - 1, ph - 1, r)
    local ix = x + m.pad_x
    drawTabletop(ix, y + m.ink_y, iw, m.ink, alpha)
    Theme.setColor(Theme.fg.heading, alpha)
    love.graphics.setFont(font)
    love.graphics.print(el.s, ix + iw + m.gap, y)
end

local function drawKeyword(el, x, y, font, color, alpha)
    love.graphics.setFont(font)
    local halo = Theme.embossFor(color)
    Theme.setColor(halo, (halo[4] or 1) * alpha)
    for _, o in ipairs(EMBOSS) do
        love.graphics.print(el.s, x + 1 + o[1], y + o[2])
    end
    Theme.setColor(color, alpha)
    love.graphics.print(el.s, x + 1, y)
end

local function drawElement(game, el, x, y, font, m, color, alpha)
    if el.kind == "text" then
        Theme.setColor(color, alpha)
        love.graphics.setFont(font)
        love.graphics.print(el.s, x, y)
    elseif el.kind == "pill" then
        drawPill(el, x, y, font, m, color, alpha)
    elseif el.kind == "tint" then
        local tx = x
        if el.glyph then
            local gy = y + m.ink_y + math.floor((m.ink - m.glyph) / 2)
            if el.glyph == "heater" then Icons.drawFlame(game, x, gy, m.glyph, alpha)
            else Icons.drawTilt(game, x, gy, m.glyph, alpha) end
            tx = x + m.glyph + m.gap
        end
        Theme.setColor(el.color, alpha)
        love.graphics.setFont(font)
        love.graphics.print(el.s, tx, y)
    elseif el.kind == "key" then
        drawKeyword(el, x, y, font, color, alpha)
    elseif el.kind == "icon" then
        if el.token == "chip" then Icons.drawChip(game, x, y, m.size, alpha)
        elseif el.token == "achip" then Icons.drawAntiChip(game, x, y, m.size, alpha)
        elseif el.token == "ko" then Icons.drawKo(game, x, y, m.size, alpha)
        elseif el.token == "table" then drawTabletop(x, y + m.ink_y, math.floor(m.ink * 1.5), m.ink, alpha)
        else drawArrow(x, y, m.size, color, alpha) end
    elseif el.kind == "table" then
        drawTable(el, x, y, font, m, alpha)
    elseif el.kind == "item" then
        local sl = game and game.sprite_loader
        local item = itemById(el.id)
        local corrupted = game and game.state and game.state.isCorrupted and game.state:isCorrupted(el.id) or false
        local sprite = item and sl and sl.itemArt and sl:itemArt(item, "catalog", nil, { corrupted = corrupted }) or nil
        if sprite then
            local sw, sh = sprite:getWidth(), sprite:getHeight()
            local sc = m.size / math.max(1, math.max(sw, sh))
            love.graphics.setColor(1, 1, 1, alpha or 1)
            love.graphics.draw(sprite, x + m.size * 0.5, y + m.size * 0.5, 0, sc, sc, sw * 0.5, sh * 0.5)
        end
    elseif el.kind == "tier" then
        local r = TierGlyph.radius(m.size)
        local w = TierGlyph.width(el.name, r)
        TierGlyph.draw(x + w / 2, y + m.size - r, el.name, r, el.outcome, alpha)
    end
end

-- Walk `str`, drawing when `draw` is true, collecting spans when `spans`
-- is a table, and returning the total width. One implementation backs
-- draw, measure and spans. `opts.pills = false` keeps numbers as text.
local function walk(game, str, x, y, font, color, alpha, draw, spans, opts)
    local m   = metrics(font)
    local els = parse(str, not (opts and opts.pills == false))
    if draw and not color then color = currentColor() end
    local cx = x
    for _, el in ipairs(els) do
        local w = elementWidth(el, font, m)
        if draw then drawElement(game, el, cx, y, font, m, color, alpha) end
        if spans and el.kind ~= "text" then
            spans[#spans + 1] = { x = cx - x, w = w, kind = el.kind, text = el.s, cat = el.cat, pill = el.pill, token = el.token or el.name }
        end
        cx = cx + w
    end
    return cx - x
end

-- Render `str` left-anchored at (x, y) in `font`. `color` is the text Theme
-- token (icons keep their own colors; nil = the colour already set); `alpha`
-- fades the whole thing. Returns total drawn width.
-- `opts` (optional, every entry point): { pills = false } draws numbers as
-- plain text. Prose (cards, tooltips, the flyer) leaves it on; chrome and
-- floaters turn it off. IconText.PLAIN is that table, shared.
IconText.PLAIN = { pills = false }

function IconText.draw(game, str, x, y, font, color, alpha, opts)
    return walk(game, str, x, y, font, color, alpha or 1, true, nil, opts)
end

-- Total rendered width of `str` in `font`, without drawing.
--
-- Cached per (font, pills, string). This is the single hottest call in the
-- text pipeline: the wrapper below asks for it once per word per candidate
-- line, and the component renderer, the tooltips and the floaters all
-- measure strings they are about to draw. Same cap-and-wipe as the parse
-- cache; a font rebuilt on resize drops its entry with the weak key.
local _measure_cache = setmetatable({}, { __mode = "k" })
local MEASURE_CAP    = 2048
local _measure_n     = 0

function IconText.measure(str, font, opts)
    if type(str) ~= "string" then
        return walk(nil, str, 0, 0, font, nil, 1, false, nil, opts)
    end
    local per_font = _measure_cache[font]
    if not per_font then
        per_font = { pills = {}, plain = {} }
        _measure_cache[font] = per_font
    end
    local bucket = (opts and opts.pills == false) and per_font.plain
                                                   or per_font.pills
    local hit = bucket[str]
    if hit then return hit end
    local w = walk(nil, str, 0, 0, font, nil, 1, false, nil, opts)
    if _measure_n >= MEASURE_CAP then
        _measure_cache = setmetatable({}, { __mode = "k" })
        _measure_n = 0
        per_font = { pills = {}, plain = {} }
        _measure_cache[font] = per_font
        bucket = (opts and opts.pills == false) and per_font.plain
                                                  or per_font.pills
    end
    bucket[str] = w
    _measure_n  = _measure_n + 1
    return w
end

-- Every non-text element of `str` with its x offset and width:
-- { {x, w, kind, text, cat, pill, token} … }. For hit-testing a word.
function IconText.spans(str, font, opts)
    local spans = {}
    walk(nil, str, 0, 0, font, nil, 1, false, spans, opts)
    return spans
end

-- Greedy word wrap to `max_w`, measured through IconText so an inline icon
-- counts at its drawn width. Markers never contain spaces, so splitting on
-- them never splits a {token}; a chance pill ("1 in 4") is kept whole.
-- Cached per (font, width, pills, string). Wrapping is O(words) measures
-- and the tooltip layout re-wraps its whole body every frame it is on
-- screen. The returned line list is SHARED — callers iterate it, none
-- mutate it.
local _wrap_cache = setmetatable({}, { __mode = "k" })
local WRAP_CAP    = 512
local _wrap_n     = 0

function IconText.wrap(str, font, max_w, opts)
    local key = (type(str) == "string") and str or nil
    if key then
        local per_font = _wrap_cache[font]
        if not per_font then per_font = {}; _wrap_cache[font] = per_font end
        local per_w = per_font[max_w]
        if not per_w then per_w = { pills = {}, plain = {} }; per_font[max_w] = per_w end
        local bucket = (opts and opts.pills == false) and per_w.plain or per_w.pills
        local hit = bucket[key]
        if hit then return hit end
        local lines = IconText.wrapUncached(str, font, max_w, opts)
        if _wrap_n >= WRAP_CAP then
            _wrap_cache = setmetatable({}, { __mode = "k" })
            _wrap_n = 0
            per_font = {}; _wrap_cache[font] = per_font
            per_w = { pills = {}, plain = {} }; per_font[max_w] = per_w
            bucket = (opts and opts.pills == false) and per_w.plain or per_w.pills
        end
        bucket[key] = lines
        _wrap_n = _wrap_n + 1
        return lines
    end
    return IconText.wrapUncached(str, font, max_w, opts)
end

function IconText.wrapUncached(str, font, max_w, opts)
    local words = {}
    for word in tostring(str or ""):gmatch("%S+") do words[#words + 1] = word end
    local units, i = {}, 1
    while i <= #words do
        local w = words[i]
        if w:match("^%d+$") and words[i + 1] == "in" and words[i + 2] and words[i + 2]:match("^%d+[%p]*$") then
            units[#units + 1] = w .. " in " .. words[i + 2]
            i = i + 3
        else
            units[#units + 1] = w
            i = i + 1
        end
    end
    local lines, cur = {}, nil
    for _, unit in ipairs(units) do
        local try = cur and (cur .. " " .. unit) or unit
        if cur and IconText.measure(try, font, opts) > max_w then
            lines[#lines + 1] = cur
            cur = unit
        else
            cur = try
        end
    end
    lines[#lines + 1] = cur or ""
    return lines
end

-- Does `str` carry anything IconText draws differently from plain print
-- (a token, or a number in one of the three shapes)? Tooltip rows use it
-- to pick the IconText path.
function IconText.hasMarkup(str)
    if type(str) ~= "string" then return false end
    if str:find("{", 1, true) then return true end
    return findPill(str, 1) ~= nil
end

return IconText
