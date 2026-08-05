-- views/widgets/Sticker.lua
--
-- An adhesive label stuck onto whatever is underneath it, whose stock fills
-- left-to-right as a progress bar.
--
-- A STICKER IS NOT A STAMP. A stamp is ink pressed into the page: rotated
-- outline, no background, the paper shows through (see the ORDERED / SOLD OUT
-- stamps in views/CatalogModal). A sticker is a separate piece of stock
-- sitting ON TOP of the page: opaque background, its own die-cut edge, a drop
-- shadow, and a slightly crooked angle because nobody applies one straight.
--
-- The fill is the point. A label that says "locked" tells you nothing; a label
-- that is two-thirds full tells you how close you are without reading a word.
--
-- Stateless — call Sticker.draw(...) per frame. The caller owns the rect and
-- computes the progress fraction. Engine-agnostic: this knows about Theme
-- tokens, font metrics and a 0..1 number. It does not know what it is
-- labelling, and must never learn.
--
-- opts:
--   x, y, w, h    (required)        — sticker rect, already ui-scaled
--   game          (required)        — DI container; IconText needs the sprite
--                                     atlas to draw inline {chip} glyphs
--   fonts         (table, required) — DI'd font set; uses .sm
--   scale         (number, default 1) — ui_scale, for padding and line widths
--   rotation      (number, default -0.03 rad) — 0 for square-on
--   title         (string, required) — top line, e.g. "COMING SOON!"
--   line          (string, optional) — second line; IconText markers supported
--   counter       (string, optional) — right-aligned on the title line, e.g. "2 / 3"
--   progress      (number 0..1, default 0) — how far the stock is filled
--   stock_token   (token, default Theme.bg.widget)   — the unfilled remainder
--   fill_token    (token, default Theme.status.warn) — the filled portion
--   ink_token     (token, default Theme.fg.heading)  — all text
--   edge_token    (token, default Theme.border.strong) — die-cut border
--
-- The ink has to stay readable across the fill boundary, so `fill_token`
-- should be a tint close in value to `stock_token` rather than a saturated
-- colour. There is no per-character contrast flip.

local Theme    = require("views.Theme")
local IconText = require("views.IconText")

local Sticker = {}

-- Shared metrics, so draw / widthFor / heightFor cannot drift apart.
local function PAD(s)      return math.max(2, math.floor(3 * s)) end
local function MARGIN(s)   return math.max(2, math.floor(3 * s)) end
local function LINE_GAP(s) return math.max(1, math.floor(2 * s)) end

-- Headline at `md`, detail line back down at `sm`: the big word carries the
-- sticker and the condition reads as the fine print under it, which is how an
-- applied label actually prints. Everything downstream (heightFor, widthFor,
-- the draw itself) measures off these two, so changing either is a one-line
-- change here.
local function fonts(opts)
    local f = opts and opts.fonts
    if not (f and f.md and f.sm) then return nil, nil end
    return f.md, f.sm
end

-- IconText is single-line with no wrapping and no truncation, so a long line
-- would draw straight through the sticker's edge. Drop trailing WORDS until it
-- fits: word boundaries never split a {marker}, which character-wise trimming
-- would (a half-eaten "{l:sta" renders as literal braces).
local function fitLine(text, font, avail)
    if text == "" or avail <= 0 then return text end
    if IconText.measure(text, font) <= avail then return text end
    local words = {}
    for word in text:gmatch("%S+") do words[#words + 1] = word end
    while #words > 1 do
        table.remove(words)
        local candidate = table.concat(words, " ") .. "..."
        if IconText.measure(candidate, font) <= avail then return candidate end
    end
    return words[1] or text
end

function Sticker.draw(opts)
    local fl    = math.floor
    local s     = opts.scale or 1
    local f_title, f_line = fonts(opts)
    if not f_title then return end

    local w, h  = opts.w, opts.h
    local stock = opts.stock_token or Theme.bg.widget
    local fill  = opts.fill_token  or Theme.status.warn
    local ink   = opts.ink_token   or Theme.fg.heading
    local edge  = opts.edge_token  or Theme.border.strong

    local frac = opts.progress or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    local pad    = PAD(s)
    local margin = MARGIN(s)
    local radius = math.max(3, fl(6 * s))

    -- Everything below is drawn around the sticker's own centre so the whole
    -- label rotates as one object. No drop shadow: a sticker is stuck flush
    -- to the paper. What sells it instead is the die-cut white margin around
    -- a printed panel, which is how an actual applied label is made.
    love.graphics.push()
    love.graphics.translate(opts.x + w * 0.5, opts.y + h * 0.5)
    love.graphics.rotate(opts.rotation or -0.03)
    local left, top = -w * 0.5, -h * 0.5

    -- 1. The die-cut backing: the blank stock the label was punched out of.
    --    Generously rounded, because a die cut has no sharp corners.
    Theme.setColor(stock)
    love.graphics.rectangle("fill", left, top, w, h, radius)

    -- 2. The printed panel, inset so the backing shows as a white margin.
    local px, py = left + margin, top + margin
    local pw, ph = w - margin * 2, h - margin * 2
    local p_rad  = math.max(2, radius - margin)
    Theme.setColor(edge, 0.14)
    love.graphics.rectangle("fill", px, py, pw, ph, p_rad)

    -- 3. Fill, left to right, inside the printed panel. Square corners on
    --    purpose: love.graphics rounds ALL four corners, so a rounded fill
    --    would bulge away from the panel's left edge at low fractions. Not
    --    setScissor — scissor is axis-aligned in screen space and we are
    --    inside a rotation, so it would clip crooked.
    if frac > 0 then
        local fill_w = fl(pw * frac)
        if fill_w > 0 then
            Theme.setColor(fill)
            love.graphics.rectangle("fill", px, py, fill_w, ph)
        end
    end

    -- 4. Keyline around the printed panel, and a hairline round the die cut.
    Theme.setColor(edge, 0.55)
    love.graphics.setLineWidth(math.max(1, fl(1 * s)))
    love.graphics.rectangle("line", px, py, pw, ph, p_rad)
    Theme.setColor(edge, 0.30)
    love.graphics.rectangle("line", left, top, w, h, radius)
    love.graphics.setLineWidth(1)

    -- 5. Text. Headline, then the detail line through IconText so {chip} /
    --    {l:stack} markers render as glyphs instead of literal braces.
    local tx = px + pad
    local ty = py + pad
    local text_w = pw - pad * 2

    Theme.setColor(ink)
    love.graphics.setFont(f_title)
    love.graphics.print(fitLine(opts.title or "", f_title, text_w), tx, ty)

    -- The count LEADS the second line rather than sitting off on the title
    -- row. "0 / 100" in one corner and "tables busted" in another are two
    -- unrelated facts; "0 / 100 tables busted" is a sentence, and a sentence
    -- is the only version that reads as a condition.
    if opts.line and opts.line ~= "" then
        ty = ty + f_title:getHeight() + LINE_GAP(s)
        love.graphics.setFont(f_line)
        local lx      = tx
        local counter = opts.counter
        if counter and counter ~= "" then
            love.graphics.print(counter, lx, ty)
            lx = lx + f_line:getWidth(counter) + math.max(2, fl(4 * s))
        end
        IconText.draw(opts.game, fitLine(opts.line, f_line, (tx + text_w) - lx),
                      lx, ty, f_line, ink)
    end

    love.graphics.pop()
end

-- Width the content actually needs. A sticker stretched to fill whatever band
-- it was given is mostly blank paper, and a fill bar across mostly-blank paper
-- reads as nothing — size it to the text and the fill becomes legible.
-- Callers should clamp the result to the space available.
function Sticker.widthFor(font_set, scale, title, line, counter)
    local f_title, f_line = fonts({ fonts = font_set })
    if not f_title then return 0 end
    local s   = scale or 1
    local gap = math.max(2, math.floor(4 * s))
    local detail = IconText.measure(line or "", f_line)
    if counter and counter ~= "" then
        detail = detail + f_line:getWidth(counter) + gap
    end
    return (PAD(s) + MARGIN(s)) * 2 + math.max(f_title:getWidth(title or ""), detail)
end

-- Height needed for a title line plus an optional detail line, so a caller can
-- size the rect before drawing.
function Sticker.heightFor(font_set, scale, has_line)
    local f_title, f_line = fonts({ fonts = font_set })
    if not f_title then return 0 end
    local s = scale or 1
    local inner = f_title:getHeight()
                  + (has_line and (f_line:getHeight() + LINE_GAP(s)) or 0)
    return (PAD(s) + MARGIN(s)) * 2 + inner
end

return Sticker
