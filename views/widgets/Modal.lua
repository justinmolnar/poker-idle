-- views/widgets/Modal.lua
--
-- Centered modal frame: dim backdrop + chrome box + optional title.
-- Engine-agnostic. Knows about fonts (passed in via :draw) and theme
-- color tokens; nothing about poker. Usable by any LÖVE2D project that
-- has views.Theme exposing the same chrome/border/fg tokens.
--
-- Pins the "room" palette for the duration of :draw and restores after,
-- so a host state's tinted palette (e.g. shove's red) doesn't bleed
-- into modal chrome. Set pin_palette = false if you want the modal to
-- inherit the active palette.

local Theme = require("views.Theme")

local Modal = {}
Modal.__index = Modal

local DEFAULT_PAD       = 24
local DEFAULT_TITLE_PAD = 14

-- opts:
--   title         (string, optional)         — header text
--   w             (integer, default 480)     — modal width
--   h             (integer, optional)        — fixed height; if nil,
--                                              caller sizes via body_h
--                                              callback or natural fit
--   max_h_frac    (number, default 0.90)     — cap as fraction of viewport
--   header_h      (integer, optional)        — explicit header height;
--                                              else derived from font + pad
--   pin_palette   (string, default "room")   — palette pinned during draw;
--                                              false to inherit
--   pad           (integer, default 24)      — body padding
function Modal:new(opts)
    opts = opts or {}
    return setmetatable({
        title       = opts.title,
        w           = opts.w or 480,
        h           = opts.h,                              -- optional fixed
        max_h_frac  = opts.max_h_frac or 0.90,
        header_h    = opts.header_h,
        pin_palette = (opts.pin_palette == nil) and "room" or opts.pin_palette,
        pad         = opts.pad or DEFAULT_PAD,
        _box        = nil,                                  -- last-drawn rect
    }, Modal)
end

function Modal:setTitle(title) self.title = title end

-- Compute header height from font (or use explicit override).
local function headerH(self, fonts)
    if self.header_h then return self.header_h end
    if not (fonts and fonts.lg) then return 56 end
    return fonts.lg:getHeight() + DEFAULT_TITLE_PAD * 2
end

-- Draw the frame and return the inner body rect for the caller to
-- render into. body_h_request is optional — when given, the modal
-- attempts to size itself to title + body + 2*pad (capped by
-- max_h_frac). When nil, the caller is responsible for self.h being
-- set (or accepts the natural cap).
function Modal:draw(fonts, body_h_request)
    local W, H  = love.graphics.getDimensions()
    local hh    = headerH(self, fonts)

    local prior_palette
    if self.pin_palette and Theme.active ~= self.pin_palette then
        prior_palette  = Theme.active
        Theme.setActive(self.pin_palette)
    end

    -- Decide modal height.
    local modal_h
    if self.h then
        modal_h = self.h
    elseif body_h_request then
        modal_h = hh + body_h_request + self.pad * 2
    else
        modal_h = math.floor(H * self.max_h_frac)
    end
    local cap = math.floor(H * self.max_h_frac)
    if modal_h > cap then modal_h = cap end

    local bx = math.floor((W - self.w) / 2)
    local by = math.floor((H - modal_h) / 2)

    -- Backdrop dim.
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Chrome box.
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", bx, by, self.w, modal_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", bx, by, self.w, modal_h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- Title.
    if self.title and fonts and fonts.lg then
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.lg)
        love.graphics.printf(self.title, bx, by + DEFAULT_TITLE_PAD, self.w, "center")
    end

    self._box = { x = bx, y = by, w = self.w, h = modal_h }

    if prior_palette then
        -- Restore at end of frame; caller draws body in pinned palette.
        -- Defer the restore to :endDraw().
        self._restore_palette = prior_palette
    end

    return {
        x = bx + self.pad,
        y = by + hh,
        w = self.w - self.pad * 2,
        h = modal_h - hh - self.pad,
    }
end

-- Call after the body is drawn to restore the pre-modal palette. Only
-- needed when pin_palette was set to a non-active palette.
function Modal:endDraw()
    if self._restore_palette then
        Theme.setActive(self._restore_palette)
        self._restore_palette = nil
    end
end

-- "inside" if (mx,my) lies within the chrome box; "outside" otherwise.
function Modal:hitTest(mx, my)
    local b = self._box
    if not b then return "outside" end
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then
        return "inside"
    end
    return "outside"
end

-- Last-drawn box rect, in case the caller needs absolute coords for
-- popups / scrollbars / tooltips that anchor outside the body inset.
function Modal:boxRect() return self._box end

return Modal
