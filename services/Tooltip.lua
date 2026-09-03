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

local Theme     = require("views.Theme")
local Constants = require("data.constants")

local Tooltip = {}

-- Module-private: the current tooltip (lines + anchor) or nil.
local _t       = nil
local _padding = 6
local _line_h  = 14   -- font row height; matches ui_small in Theme.font

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

local function tokenColor(token)
    if not token then return nil end
    return (Theme.data and Theme.data[token])
        or (Theme.status and Theme.status[token])
        or (Theme.fg and Theme.fg[token])
        or nil
end

-- font_or_fonts: either a single Font object (legacy) or a fonts table
-- like game.fonts ({ sm = Font, md = Font, lg = Font }). Structured
-- lines use the table to pick per-line sizing.
function Tooltip.draw(font_or_fonts)
    if not _t then return end
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

    -- Resolve every line to a concrete font/color so layout can measure.
    local rows = {}
    for i, line in ipairs(_t.lines) do
        rows[i] = resolveLine(line, fonts, default_font)
    end

    -- Measure content (per-row line height = that row's font height, or the
    -- custom row's self-reported size).
    local max_w  = 0
    local total_h = 0
    for _, r in ipairs(rows) do
        local w, h
        if r.render then
            w, h = 0, default_font:getHeight()
            if r.measure and fonts then w, h = r.measure(fonts) end
        else
            local wrapw, wlines = r.font:getWrap(r.text, MAX_W)
            w = wrapw
            h = math.max(1, #wlines) * r.font:getHeight()
        end
        r._h = h
        if w > max_w then max_w = w end
        total_h = total_h + h + 2
    end
    local box_w = max_w + _padding * 2
    local box_h = _padding * 2 + total_h

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

    Theme.setColor(Theme.bg.window, 0.95)
    love.graphics.rectangle("fill", x, y, box_w, box_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", x, y, box_w, box_h, Theme.space.radius)

    local cy = y + _padding
    for _, r in ipairs(rows) do
        if r.render then
            if fonts then r.render(x + _padding, cy, fonts) end
        else
            love.graphics.setFont(r.font)
            local color = tokenColor(r.color) or Theme.fg.heading
            Theme.setColor(color)
            love.graphics.printf(r.text, x + _padding, cy, MAX_W, "left")
        end
        cy = cy + (r._h or 0) + 2
    end

    -- Consume on draw: main.lua now draws the tooltip once per frame above
    -- the story layer, and the modals (catalog, settings) still draw their
    -- own — whichever runs first takes it, so nothing double-draws.
    _t = nil
end

return Tooltip
