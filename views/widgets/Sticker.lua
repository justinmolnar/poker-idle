-- views/widgets/Sticker.lua
--
-- An adhesive label stuck onto whatever is underneath it, whose stock fills
-- left-to-right as a progress bar.
--
-- A STICKER IS NOT A STAMP. A stamp is ink pressed into the page: rotated
-- outline, no background, the paper shows through (see the ORDERED
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
--   line2         (string, optional) — third line (a second gate, e.g. an item
--                                     prerequisite riding under the condition)
--   counter       (string, optional) — right-aligned on the title line, e.g. "2 / 3"
--   progress      (number 0..1, default 0) — how far the stock is filled
--   stock_token   (token, default Theme.bg.widget)   — die-cut backing (white vinyl)
--   panel_token   (token, default warm cream)        — base stock, the UNFILLED portion
--   fill_token    (token, default Theme.status.warn) — earned portion: saturated, obvious
--   ink_token     (token, default Theme.fg.heading)  — all text (on the vinyl disc)
--   edge_token    (token, default Theme.border.strong) — die-cut keyline
--   vinyl_token   (token, default warm cream)        — the text disc / adhesive side
--
-- The text sits on an opaque vinyl disc, not directly on the panel, so the
-- fill can be a saturated colour without ever eating a glyph.

local Theme    = require("views.Theme")
local IconText = require("views.IconText")

local Sticker = {}

-- A piece of stock sitting ON the page always throws a soft offset shadow;
-- without one the sticker reads as ink printed on the paper. The peeled flap
-- casts a larger, sharper one because it is hovering.
local SHADOW = { 0, 0, 0 }

-- Small helpers for derived tints, so one `panel` token produces a whole
-- sticker without the caller having to think about it.
local function brighten(c, k)
    return { c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k }
end
local function darken(c, k)
    return { c[1] * (1 - k), c[2] * (1 - k), c[3] * (1 - k) }
end

-- Shared metrics, so draw / widthFor / heightFor cannot drift apart.
local function PAD(s)      return math.max(2, math.floor(3 * s)) end
local function INLAY(s)    return math.max(2, math.floor(3 * s)) end
local function LINE_GAP(s) return math.max(1, math.floor(2 * s)) end

-- Headline at `md`, detail line back down at `sm`: the big word carries the
-- sticker and the condition reads as the fine print under it, which is how an
-- applied label actually prints. Everything downstream (heightFor, widthFor,
-- the draw itself) measures off these two, so changing either is a one-line
-- change here.
-- `title_style = "sm"` prints the headline at the detail size too, for a
-- sticker on something too narrow for the big word (a deck tile).
local function fonts(opts)
    local f = opts and opts.fonts
    if not (f and f.md and f.sm) then return nil, nil end
    if opts.title_style == "sm" then return f.sm, f.sm end
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
    -- White vinyl backing — the one thing every real sticker has and paper
    -- never does. The base stock is cream; the EARNED fraction is the
    -- saturated ink. Progress fills light → loud, never the reverse: a
    -- saturated field that bleaches out as it fills reads backwards.
    local stock = opts.stock_token or { 1, 1, 1 }
    local panel = opts.panel_token or { 1.00, 0.97, 0.88 }
    local fill  = opts.fill_token  or Theme.status.warn
    local ink   = opts.ink_token   or Theme.fg.heading
    local edge  = opts.edge_token  or Theme.border.strong
    -- The vinyl disc the text prints on, and the adhesive side of a peel:
    -- pale warm cream, like the back of a crack-and-peel sheet.
    local vinyl = opts.vinyl_token or { 1.00, 0.98, 0.90 }
    local underside = opts.underside_token
                      or { vinyl[1] * 0.94, vinyl[2] * 0.92, vinyl[3] * 0.86 }

    local frac = opts.progress or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    -- The panel is flush with the die-cut edge. Padding between the panel
    -- edge and the vinyl disc has to fit the serrated peel strip, so it
    -- cannot also be used for panel margin.
    local pad    = PAD(s)
    local inlay  = INLAY(s)   -- white die-cut rim width
    local radius = math.max(3, fl(6 * s))

    -- Peel: 0 stuck flat, 1 fully lifted off. Grab the left edge, pull right.
    -- The freed part FOLDS BACK over the part still stuck, so what you see to
    -- the right of the crease is the label's blank underside, and what is left
    -- of the crease is bare page. The stuck part is CLIPPED at the crease, not
    -- squeezed — squeezing narrows the printed text, which reads as the label
    -- melting rather than coming off.
    local peel   = math.max(0, math.min(1, opts.peel or 0))
    local fold_x = opts.x + w * peel          -- crease, in the caller's space

    -- A label straightens out as you pull it, which is also what makes the
    -- clip honest: setScissor is an axis-aligned screen rect, so the crease
    -- has to be vertical by the time there is enough flap to notice.
    local rot = (opts.rotation or -0.03) * math.max(0, 1 - peel * 4)

    if peel > 0 then
        -- Everything from the crease rightward is still stuck down.
        love.graphics.setScissor(fl(fold_x), fl(opts.y - h),
                                 math.ceil(opts.x + w - fold_x) + 1, fl(h * 3))
    end

    -- Everything below is drawn around the sticker's own centre so the whole
    -- label rotates as one object — shadow included, because the shadow is
    -- cast ON the rotated page by the rotated sticker and must stay welded
    -- to its lower-right.
    love.graphics.push()
    love.graphics.translate(opts.x + w * 0.5, opts.y + h * 0.5)
    love.graphics.rotate(rot)
    love.graphics.translate(-w * 0.5, -h * 0.5)
    local left, top = 0, 0

    -- 1. Drop shadow. Two soft passes, offset down-right, slightly bigger
    --    than the die cut so it reads as light falling past an edge rather
    --    than a grey frame drawn on purpose. Modern soft-shadow trick:
    --    same rounded shape, just slid out from under the object.
    local soff = math.max(1, fl(2 * s))
    Theme.setColor(SHADOW, 0.16)
    love.graphics.rectangle("fill", left + soff, top + soff, w, h, radius + soff)
    Theme.setColor(SHADOW, 0.10)
    love.graphics.rectangle("fill", left + soff * 2, top + soff * 2, w, h, radius + soff * 2)

    -- 2. The die-cut backing: white vinyl the label was punched out of,
    --    generously rounded because a die cut has no sharp corners. This
    --    white rim against the page is 80% of "that is a sticker".
    Theme.setColor(stock)
    love.graphics.rectangle("fill", left, top, w, h, radius)

    -- 3. The printed panel, inset so the backing shows around it. The
    --    unfilled portion is a subtle darken of the base stock — just enough
    --    to read as a strip, never a different colour. The fill is a
    --    separate saturated ink laid on top of this.
    local px, py = left + inlay, top + inlay
    local pw, ph = w - inlay * 2, h - inlay * 2
    local p_rad  = math.max(2, radius - inlay)
    local remainder = { panel[1] * 0.88, panel[2] * 0.84, panel[3] * 0.74 }
    Theme.setColor(remainder)
    love.graphics.rectangle("fill", px, py, pw, ph, p_rad)

    -- 4. Fill, left to right, inside the panel: the earned fraction is
    --    the saturated ink. Square corners on purpose:
    --    love.graphics rounds ALL four corners, so a rounded fill would
    --    bulge away from the panel's left edge at low fractions.
    if frac > 0 then
        local fill_w = fl(pw * frac)
        if fill_w > 0 then
            Theme.setColor(fill)
            love.graphics.rectangle("fill", px, py, fill_w, ph)
        end
    end
    -- Fill seam: a crisp dark edge where the earned stock meets the
    -- remainder, so even at a glance the eye can find the split. Without it
    -- a 40% fill reads as a gradient, not a count.
    if frac > 0 then
        local sx = px + fl(pw * frac)
        if sx < px + pw - 1 then
            Theme.setColor(edge, 0.5)
            love.graphics.setLineWidth(math.max(1, fl(1 * s)))
            love.graphics.line(sx, py + 1, sx, py + ph - 1)
            love.graphics.setLineWidth(1)
        end
    end

    -- 5. Vinyl disc the text lives on. Real sticker paper prints text on the
    --    face stock, not straight onto the dark ink, and it gives the fill
    --    somewhere to disappear behind instead of cutting through glyphs.
    local tx = px + pad
    local ty = py + pad
    local text_w = pw - pad * 2
    local text_h = f_title:getHeight()
    if opts.line and opts.line ~= "" then
        text_h = text_h + LINE_GAP(s) + f_line:getHeight()
    end
    if opts.line2 and opts.line2 ~= "" then
        text_h = text_h + LINE_GAP(s) + f_line:getHeight()
    end
    local d_rad = math.max(2, fl(3 * s))
    Theme.setColor(vinyl)
    love.graphics.rectangle("fill", tx - pad, ty - pad,
                            text_w + pad * 2, text_h + pad * 2, d_rad)

    -- 6. Gloss: a pale sweep across the panel's upper half. The fill is
    --    darker than the base, so draw the gloss over the earned fraction
    --    only where it exists — vinyl shines on the saturated ink, and a
    --    pale fill sweep against the cream base would just bruise it.
    if frac > 0 then
        local gw = fl(pw * frac)
        if gw > 4 then
            Theme.setColor({ 1, 1, 1 }, 0.18)
            love.graphics.rectangle("fill", px + 1, py + 1, gw - 2, fl(ph * 0.42), p_rad)
        end
    end

    -- 7. Starburst, bottom-right of the panel, peeking out from behind the
    --    disc — the little flash every promo sticker carries. Deterministic
    --    per sticker so it doesn't swap sides when the text reflows.
    local cx_b = px + pw - fl(9 * s)
    local cy_b = py + ph - fl(7 * s)
    local function starburst(cx, cy, r_out, r_in, points, seed)
        local pts = {}
        for i = 0, points * 2 - 1 do
            local r = (i % 2 == 0) and r_out or r_in
            local a = seed + i * math.pi / points
            pts[#pts + 1] = cx + math.cos(a) * r
            pts[#pts + 1] = cy + math.sin(a) * r
        end
        love.graphics.polygon("fill", pts)
    end
    local seed = ((w * 7 + h * 13) % 31) * 0.1
    Theme.setColor(fill, 0.9)
    starburst(cx_b, cy_b, fl(11 * s), fl(5 * s), 12, seed)

    -- 8. Serrated peel strip along the panel's right edge: the zig-zag edge
    --    of the crack-and-peel backing, which is the single most "sticker"
    --    detail there is on a promo label.
    local t0, t1 = py + pad, py + ph - pad
    local tooth = math.max(3, fl(5 * s))
    local inset = fl(2.5 * s)
    local zx = px + pw
    Theme.setColor(stock, 0.9)
    local zig = {}
    local y = t0
    local in_out = false
    zig[#zig + 1] = zx
    zig[#zig + 1] = y
    while y < t1 do
        y = math.min(y + tooth * 0.5, t1)
        in_out = not in_out
        zig[#zig + 1] = in_out and (zx - inset) or zx
        zig[#zig + 1] = y
    end
    if #zig >= 6 then love.graphics.line(zig) end

    -- 9. Keylines: a die-cut rim round the panel and a hairline round the
    --    white backing, so the silhouette reads at every scale.
    Theme.setColor(edge, 0.30)
    love.graphics.setLineWidth(math.max(1, fl(1 * s)))
    love.graphics.rectangle("line", left, top, w, h, radius)
    Theme.setColor(darken(panel, 0.4), 0.55)
    love.graphics.rectangle("line", px, py, pw, ph, p_rad)
    love.graphics.setLineWidth(1)

    -- 10. Text, on the vinyl disc. Headline, then the detail line through
    --     IconText so {chip} / {l:stack} markers render as glyphs instead of
    --     literal braces.
    Theme.setColor(ink)
    love.graphics.setFont(f_title)
    love.graphics.print(fitLine(opts.title or "", f_title, text_w), fl(tx), fl(ty))

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

    -- Second gate row: the item-prerequisite line, under the condition
    -- (or straight under the title when there is no condition row).
    if opts.line2 and opts.line2 ~= "" then
        local prev = (opts.line and opts.line ~= "") and f_line or f_title
        ty = ty + prev:getHeight() + LINE_GAP(s)
        love.graphics.setFont(f_line)
        IconText.draw(opts.game, fitLine(opts.line2, f_line, text_w),
                      tx, ty, f_line, ink)
    end

    love.graphics.pop()

    if peel <= 0 then return end
    love.graphics.setScissor()

    -- 11. The flap: the peeled length folded back over the stuck part, so it
    --    runs from the crease RIGHTWARD by exactly as much as has come away,
    --    showing the blank underside. This is the half that makes it a peel —
    --    without it the label just disappears from the left.
    local flap_len = w * peel
    love.graphics.push()
    love.graphics.translate(fold_x, opts.y + h * 0.5)
    love.graphics.rotate(rot)

    -- Curl: the far edge of the flap lifts, so it reads slightly shorter than
    -- the piece it came from.
    local curl = fl(h * 0.10 * peel)
    local y0, y1 = -h * 0.5, h * 0.5
    local far = flap_len

    -- Shadow the flap casts on whatever it is now hovering over.
    Theme.setColor(SHADOW, 0.18)
    love.graphics.polygon("fill",
        fl(3 * s), y0 + curl + fl(3 * s),
        far + fl(3 * s), y0 + curl * 2 + fl(3 * s),
        far + fl(3 * s), y1 - curl * 2 + fl(3 * s),
        fl(3 * s), y1 - curl + fl(3 * s))

    -- Underside: same stock, no print on it, a shade duller than the face
    -- because it is the adhesive side.
    Theme.setColor(underside)
    love.graphics.polygon("fill",
        0, y0, far, y0 + curl, far, y1 - curl, 0, y1)
    Theme.setColor(edge, 0.28)
    love.graphics.setLineWidth(math.max(1, fl(1 * s)))
    love.graphics.polygon("line",
        0, y0, far, y0 + curl, far, y1 - curl, 0, y1)

    -- The crease itself: the fold is the sharpest line on the whole thing.
    Theme.setColor(edge, 0.55)
    love.graphics.line(0, y0, 0, y1)
    love.graphics.setLineWidth(1)

    love.graphics.pop()
end

-- Width the content actually needs. A sticker stretched to fill whatever band
-- it was given is mostly blank paper, and a fill bar across mostly-blank paper
-- reads as nothing — size it to the text and the fill becomes legible.
-- Callers should clamp the result to the space available.
function Sticker.widthFor(font_set, scale, title, line, counter, line2, title_style)
    local f_title, f_line = fonts({ fonts = font_set, title_style = title_style })
    if not f_title then return 0 end
    local s   = scale or 1
    local gap = math.max(2, math.floor(4 * s))
    local detail = IconText.measure(line or "", f_line)
    if counter and counter ~= "" then
        detail = detail + f_line:getWidth(counter) + gap
    end
    -- A second detail row (an item-prerequisite gate riding under the
    -- condition gate) widens the sticker if it is the longest row.
    if line2 and line2 ~= "" then
        detail = math.max(detail, IconText.measure(line2, f_line))
    end
    return (PAD(s) * 2 + INLAY(s)) * 2 + math.max(f_title:getWidth(title or ""), detail)
end

-- Height needed for a title line plus optional detail lines, so a caller can
-- size the rect before drawing.
function Sticker.heightFor(font_set, scale, has_line, has_line2, title_style)
    local f_title, f_line = fonts({ fonts = font_set, title_style = title_style })
    if not f_title then return 0 end
    local s = scale or 1
    local inner = f_title:getHeight()
                  + (has_line and (f_line:getHeight() + LINE_GAP(s)) or 0)
                  + (has_line2 and (f_line:getHeight() + LINE_GAP(s)) or 0)
    return (PAD(s) * 2 + INLAY(s)) * 2 + inner
end

return Sticker
