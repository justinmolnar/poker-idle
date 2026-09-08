-- services/Tooltip.lua
--
-- Deferred hover-tooltip rendering. Stateless module. Only one tooltip can
-- be visible at a time — the most recent Tooltip.set wins. Cleared each
-- frame from love.update; populated by hit-test passes during update; drawn
-- once per frame near the top of the render order (above gameplay layers,
-- below any debug overlays).
--
-- Filled bg rect, strong border, light text. Auto-sizes to content. Keeps
-- inside the screen via edge-clamping near the mouse cursor.
--
-- Rows go through views/IconText when they carry markup or a number in
-- one of the style sheet's shapes, so tier glyphs, tinted words, pills and
-- keywords render the same in every tooltip. A tinted word, keyword or
-- icon inside the box can open a SIDE CARD (Tooltip.hover; the host hands
-- in a resolver, typically the glossary).

local Theme     = require("views.Theme")
local Constants = require("data.constants")
local IconText  = require("views.IconText")
local Perf      = require("services.Perf")

local Tooltip = {}

-- Module-private: the current tooltip (lines + anchor) or nil.
local _t       = nil
local _padding = 6

-- Pointer-rest gate: a tooltip appears only after the pointer has been
-- STILL (within a few px) over a tooltip target for Constants.HOVER.DWELL
-- — the same resting rule the hover washes use in HoverService. Moving
-- resets the clock, so sweeping across the board shows nothing and
-- sliding from one target to the next re-earns the delay; no content
-- keys, no per-caller state.
local REST_PX = 6
local _rx, _ry, _rest_since, _last_req = nil, nil, 0, -1
local function now()
    return (love and love.timer and love.timer.getTime()) or 0
end

-- Stash a tooltip for this frame. Caller passes either a string (single
-- line), a list of strings, or a list of structured rows
-- `{ text, style, color_token }` where style ∈ "sm" | "md" | "lg" picks
-- the font from the fonts table at draw time. mx/my anchor near the
-- mouse cursor. Shown only once the pointer has rested for the dwell.
function Tooltip.set(text_or_lines, mx, my)
    if not text_or_lines then return end
    local lines
    if type(text_or_lines) == "table" then
        if #text_or_lines == 0 then return end
        lines = text_or_lines
    else
        lines = { text_or_lines }
    end
    mx, my = mx or 0, my or 0
    local t = now()
    -- Re-anchor the rest spot when the pointer strays or the request
    -- chain lapsed (no set() for a few frames = hover ended).
    if not _rx or math.abs(mx - _rx) > REST_PX or math.abs(my - _ry) > REST_PX
       or (t - _last_req) > 0.1 then
        _rx, _ry, _rest_since = mx, my, t
    end
    _last_req = t
    if (t - _rest_since) < Constants.HOVER.DWELL then return end
    _t = { lines = lines, mx = mx, my = my }
end

function Tooltip.clear()
    _t = nil
end

-- A card the player asked for (a click on the thing): shown this frame,
-- no rest needed. Same rows as set().
function Tooltip.pin(lines, mx, my)
    if type(lines) ~= "table" or #lines == 0 then return end
    _t = { lines = lines, mx = mx or 0, my = my or 0 }
end

-- A rect {x, y, w, h} the tooltip must not cover — the story panel while
-- the House is talking (a forced hover lesson's tooltip was landing under
-- the dialog). Set every frame by main.lua; nil clears it. When the
-- default below-cursor spot intersects it, the box flips above the cursor.
local _avoid = nil
function Tooltip.setAvoid(rect)
    _avoid = rect
end

local function intersects(x, y, w, h, r)
    return r ~= nil
       and x < r.x + r.w and x + w > r.x
       and y < r.y + r.h and y + h > r.y
end

-- A custom row: icon-marked text ({chip}, tier glyphs, pills) in a colour.
-- The one row builder every card uses (the receipt, the room, the glossary).
function Tooltip.iconRow(game, text, color)
    return {
        measure = function(fonts)
            return IconText.measure(text, fonts.sm), fonts.sm:getHeight()
        end,
        render = function(x, y, fonts)
            IconText.draw(game, text, x, y, fonts.sm, color)
        end,
    }
end

-- Per-line resolve: string lines render in the default font; table
-- lines pick up font / color from their style tag (resolved against
-- the fonts table when one is passed).
local function resolveLine(line, fonts, default_font)
    if type(line) == "string" then
        return { text = line, font = default_font, color = nil }
    end
    -- Custom-drawn row (icon stacks etc.): caller supplies render + measure.
    if line.render then
        return { render = line.render, measure = line.measure }
    end
    local font = default_font
    if fonts and line.style and fonts[line.style] then
        font = fonts[line.style]
    end
    return {
        text = line.text or "",
        font = font,
        color = line.color_token,    -- resolved by caller through Theme tokens
    }
end

-- A colour by name: the seven meanings, their aliases, and the fg names.
local tokenColor = Theme.color

-- Rows whose text carries {…} markers (a tier glyph, a tinted word) or a
-- number in one of the style sheet's shapes (×2, +10%, 1 in 4) lay out
-- and draw through IconText, so pills appear in every tooltip with no
-- per-site work; plain rows keep love's own wrap.
local hasMarkers = IconText.hasMarkup

-- Resolve and measure a list of lines. Returns rows, box_w, box_h.
-- Cached on the lines table's identity. A tooltip re-laid-out its whole
-- body every frame it was on screen — wrapping every row, measuring every
-- markup string. The expensive tooltips now hand back one stable table
-- (services/Memo), so this hits across frames as well as within one.
--
-- Weak keys: a caller that still builds fresh lines each frame simply
-- misses and its entry is collected.
local _layout_cache = setmetatable({}, { __mode = "k" })

-- Forward declaration: `layout` closes over the uncached builder defined
-- just below it.
local layoutUncached

local function layout(lines, fonts, default_font, max_w)
    local hit = _layout_cache[lines]
    if hit and hit.font == default_font and hit.max_w == max_w
       and hit.fonts == fonts then
        return hit.rows, hit.w, hit.h
    end
    local rows, w, h = layoutUncached(lines, fonts, default_font, max_w)
    _layout_cache[lines] = { font = default_font, max_w = max_w, fonts = fonts,
                             rows = rows, w = w, h = h }
    return rows, w, h
end

function layoutUncached(lines, fonts, default_font, max_w)
    local rows = {}
    for i, line in ipairs(lines) do
        rows[i] = resolveLine(line, fonts, default_font)
    end
    local widest, total_h = 0, 0
    for _, r in ipairs(rows) do
        local w, h
        if r.render then
            w, h = 0, default_font:getHeight()
            if r.measure and fonts then w, h = r.measure(fonts) end
        elseif hasMarkers(r.text) then
            r._lines = IconText.wrap(r.text, r.font, max_w)
            w = 0
            for _, l in ipairs(r._lines) do w = math.max(w, IconText.measure(l, r.font)) end
            h = #r._lines * r.font:getHeight()
        else
            Perf.count("getWrap")
            local wrapw, wlines = r.font:getWrap(r.text, max_w)
            w = wrapw
            h = math.max(1, #wlines) * r.font:getHeight()
        end
        r._h = h
        if w > widest then widest = w end
        total_h = total_h + h + 2
    end
    return rows, widest + _padding * 2, _padding * 2 + total_h
end

-- Draw laid-out rows in a box at (x, y). `placed` collects each IconText
-- line's spot for the word hit-test.
local function drawBox(rows, x, y, box_w, box_h, fonts, max_w, placed)
    Theme.setColor(Theme.bg.window, 0.95)
    love.graphics.rectangle("fill", x, y, box_w, box_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", x, y, box_w, box_h, Theme.space.radius)

    local cy = y + _padding
    for _, r in ipairs(rows) do
        if r.render then
            if fonts then r.render(x + _padding, cy, fonts) end
        elseif r._lines then
            local color = tokenColor(r.color) or Theme.fg.heading
            local ly = cy
            for _, l in ipairs(r._lines) do
                IconText.draw(nil, l, x + _padding, ly, r.font, color)
                if placed then placed[#placed + 1] = { x = x + _padding, y = ly, font = r.font, text = l } end
                ly = ly + r.font:getHeight()
            end
        else
            love.graphics.setFont(r.font)
            local color = tokenColor(r.color) or Theme.fg.heading
            Theme.setColor(color)
            love.graphics.printf(r.text, x + _padding, cy, max_w, "left")
        end
        cy = cy + (r._h or 0) + 2
    end
end

-- ── The side card ──────────────────────────────────────────────────────
-- Hover a tinted word, a keyword or an icon inside the tooltip and a
-- second card opens beside it: what the glossary says about that word.
-- `resolve(span)` is handed in by the host (main.lua → GlossaryPanel), so
-- this service never reaches into the views; it returns rows or nil.
-- Called from update, against LAST frame's box. A click pins the card
-- until the tooltip goes away.

-- The last box drawn: its rect and each text row's place. nil when
-- nothing was drawn last frame.
Tooltip.last = nil

local _side, _side_key, _side_since, _side_pinned = nil, nil, 0, false

function Tooltip.hover(mx, my, resolve)
    local last = Tooltip.last
    if not last or (now() - last.at) > 0.1 then
        _side, _side_key, _side_pinned = nil, nil, false
        return
    end
    if _side_pinned then return end
    local hit_key, hit_span
    for _, r in ipairs(last.rows) do
        local h = r.font:getHeight()
        if my >= r.y and my < r.y + h and mx >= r.x then
            for _, sp in ipairs(IconText.spans(r.text, r.font)) do
                if sp.kind ~= "pill" and mx >= r.x + sp.x and mx < r.x + sp.x + sp.w then
                    hit_key  = (sp.kind or "") .. ":" .. (sp.text or sp.token or "")
                    hit_span = sp
                    break
                end
            end
        end
        if hit_span then break end
    end
    if not hit_span then _side, _side_key = nil, nil return end
    if hit_key ~= _side_key then
        _side_key, _side_since = hit_key, now()
        _side = nil
    end
    if not _side and (now() - _side_since) >= Constants.HOVER.DWELL then
        _side = resolve and resolve(hit_span) or false
    end
end

-- A click while a side card shows keeps it up; a click anywhere else
-- lets it go. Returns true when the click was spent on the card.
function Tooltip.click()
    if _side and not _side_pinned then _side_pinned = true return true end
    if _side_pinned then _side, _side_key, _side_pinned = nil, nil, false end
    return false
end

-- Whether a side card is up.
function Tooltip.sideShowing() return _side ~= nil and _side ~= false end

-- font_or_fonts: either a single Font object (legacy) or a fonts table
-- like game.fonts ({ sm = Font, md = Font, lg = Font }). Structured
-- lines use the table to pick per-line sizing.
function Tooltip.draw(font_or_fonts)
    if not _t then
        if not _side_pinned then Tooltip.last = nil end
        return
    end
    local fonts, default_font
    if type(font_or_fonts) == "table" then
        fonts        = font_or_fonts
        default_font = fonts.sm or fonts.md
    else
        default_font = font_or_fonts
    end
    if not default_font then default_font = love.graphics.getFont() end
    if not default_font then return end

    -- Wrap long text to a sane max width so a tooltip never spans the screen.
    local MAX_W = math.floor(math.min(default_font:getHeight() * 20,
                                      love.graphics.getWidth() * 0.45))

    local rows, box_w, box_h = layout(_t.lines, fonts, default_font, MAX_W)

    -- Anchor near cursor; flip to the left if the right edge would clip,
    -- and clamp to screen bounds.
    local screen_w, screen_h = love.graphics.getDimensions()
    local x = _t.mx + 14
    local y = _t.my + 14
    if x + box_w > screen_w then x = _t.mx - box_w - 8 end
    if x < 4 then x = 4 end
    if y + box_h > screen_h then y = screen_h - box_h - 4 end
    -- The avoid rect wins over the default spot: go above the cursor.
    if intersects(x, y, box_w, box_h, _avoid) then
        y = _t.my - box_h - 14
    end
    if y < 4 then y = 4 end

    local placed = {}
    drawBox(rows, x, y, box_w, box_h, fonts, MAX_W, placed)

    -- The side card, beside the box: right of it, or left when the right
    -- would leave the screen. Its own rows are not hit-tested (one hop).
    if _side then
        local srows, sw, sh = layout(_side, fonts, default_font, MAX_W)
        local sx = x + box_w + 6
        if sx + sw > screen_w then sx = x - sw - 6 end
        if sx < 4 then sx = 4 end
        local sy = math.min(y, screen_h - sh - 4)
        if sy < 4 then sy = 4 end
        drawBox(srows, sx, sy, sw, sh, fonts, MAX_W, nil)
    end

    Tooltip.last = { x = x, y = y, w = box_w, h = box_h, rows = placed, at = now() }

    -- Consume on draw: main.lua now draws the tooltip once per frame above
    -- the story layer, and the modals (catalog, settings) still draw their
    -- own — whichever runs first takes it, so nothing double-draws.
    _t = nil
end

return Tooltip
