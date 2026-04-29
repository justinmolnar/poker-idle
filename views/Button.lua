-- views/Button.lua
--
-- Chunky pushable button renderer — Balatro-flavoured. A button is two
-- rectangles: a darker "side" rim under a lighter face. Hover lifts the
-- face up by 1 px; press drops it down by `depth` pixels into the rim;
-- juice gives a small scale pop on the rise.
--
-- Engine-agnostic: opaque rect + opts + label callback. Caller resolves
-- state-dependent colours (fill / border) and computes hover / press
-- alpha via HoverService and ClickFlash, then passes them in. This module
-- doesn't reach into either service itself.
--
-- The whole visible envelope (face + side, hover lift + press depth) fits
-- inside the allocated rect (x, y, w, h) — no overflow into adjacent rows.

local Theme = require("views.Theme")

local Button = {}

-- ── Tunables ────────────────────────────────────────────────────────────
local LIFT_PX   = 1      -- hover lift

-- ── Curves (private) ────────────────────────────────────────────────────
local function easeOutCubic(t)  return 1 - (1 - t) ^ 3            end
local function pressCurve(a)    return easeOutCubic(a or 0)       end
local function darken(c, f)     return { c[1] * f, c[2] * f, c[3] * f } end

-- ── Public API ──────────────────────────────────────────────────────────
-- Render a chunky button at (x, y, w, h). The button's visible envelope
-- (face + side, hover lift + press depth) is contained inside the rect.
--
-- opts (all optional unless noted):
--   fill_color   {r,g,b}  REQUIRED — face colour at rest.
--   side_color   {r,g,b}  depth rim; defaults to darken(fill_color, 0.5).
--   border_color {r,g,b}  outline on the face. nil = no border.
--   hovered      bool     adds a 10% white wash + lifts face by LIFT_PX.
--   press_alpha  number   0..1 — drives press-in animation (eased).
--   depth        number   side height at rest. Default 4.
--   radius       number   corner radius. Default Theme.space.radius.
--   line_width   number   border line width. Default Theme.space.hairline.
--   disabled     bool     overrides fill_color with Theme.bg.sunken;
--                         disables hover wash and press animation.
--
-- label_fn(face_x, face_y, face_w, face_h) — called after the chrome with
-- the post-press face rect. Caller renders text/icons relative to this rect
-- so labels move with the face on hover-lift and press-in.
function Button.draw(x, y, w, h, opts, label_fn)
    opts = opts or {}
    local depth        = opts.depth or 4
    local radius       = opts.radius or Theme.space.radius
    local line_width   = opts.line_width or Theme.space.hairline
    local disabled     = opts.disabled
    local hovered      = opts.hovered and not disabled
    local press_alpha  = (not disabled) and (opts.press_alpha or 0) or 0

    -- Geometry: face_h is fixed; press shifts face_y down, side_h shrinks.
    local face_h = h - depth - LIFT_PX
    if face_h < 4 then face_h = math.max(2, h - 2) end
    local press        = pressCurve(press_alpha)
    local press_offset = press * depth
    local hover_lift   = hovered and LIFT_PX or 0
    local face_y       = y + LIFT_PX - hover_lift + press_offset
    local side_top     = face_y + face_h
    local side_h       = (depth + hover_lift) - press_offset
    if side_h < 0 then side_h = 0 end

    -- Resolve colours.
    local fill = disabled and Theme.bg.sunken or opts.fill_color
    if not fill then return end
    local side = opts.side_color or darken(fill, 0.5)

    -- 1. Side rim.
    if side_h > 0 then
        Theme.setColor(side)
        love.graphics.rectangle("fill", x, side_top, w, side_h, radius)
    end

    -- 2. Face fill.
    Theme.setColor(fill)
    love.graphics.rectangle("fill", x, face_y, w, face_h, radius)

    -- 3. Hover wash on top of face.
    if hovered then
        Theme.setColor(Theme.fg.heading, 0.10)
        love.graphics.rectangle("fill", x, face_y, w, face_h, radius)
    end

    -- 4. Border on the face.
    if opts.border_color then
        Theme.setColor(opts.border_color)
        love.graphics.setLineWidth(line_width)
        love.graphics.rectangle("line", x, face_y, w, face_h, radius)
        love.graphics.setLineWidth(1)
    end

    -- 5. Label callback receives the post-press face rect.
    if label_fn then label_fn(x, face_y, w, face_h) end
end

-- Total vertical space needed for a button with face content of `content_h`.
-- Callers (e.g. ComponentRenderer.buttonH) use this to size their layouts
-- so depth + lift fit inside the allocation.
function Button.allocatedH(content_h, depth)
    return content_h + (depth or 4) + LIFT_PX
end

return Button
