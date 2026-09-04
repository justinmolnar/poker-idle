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
--
-- ── Sizing and scrolling ──────────────────────────────────────────────
-- The frame sizes to its content (title + body_h_request + padding) up
-- to max_h_frac of the viewport. Content taller than that SCROLLS: the
-- body is clipped to the frame while the caller draws (between :draw and
-- :endDraw), a scrollbar rides the frame's right edge, and the body rect
-- handed back is offset by the scroll so the caller lays out exactly as
-- it always did — its hit rects land where its rows are drawn. The caller
-- must (1) keep one Modal instance across frames, since the scroll lives
-- on it, (2) route wheelmoved / mousepressed / mousemoved / mousereleased
-- here first, and (3) ignore body hits outside :bodyClip() (a row drawn
-- past the clip is not on screen). Modal:inBody(mx, my) answers that.

local Theme     = require("views.Theme")
local Scrollbar = require("views.Scrollbar")

local Modal = {}
Modal.__index = Modal

local DEFAULT_PAD       = 24
local DEFAULT_TITLE_PAD = 14
local TRACK_INSET       = 4     -- scrollbar off the frame's right edge

-- opts:
--   title         (string, optional)         — header text
--   title_align   ("center"|"left", def center) — header text alignment
--   aside         (string, optional)         — secondary text drawn small &
--                                              right-aligned in the header
--                                              (e.g. a disclaimer); wraps
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
        title_align = opts.title_align or "center",
        aside       = opts.aside,
        w           = opts.w or 480,
        h           = opts.h,                              -- optional fixed
        max_h_frac  = opts.max_h_frac or 0.90,
        header_h    = opts.header_h,
        pin_palette = (opts.pin_palette == nil) and "room" or opts.pin_palette,
        pad         = opts.pad or DEFAULT_PAD,
        _box        = nil,                                  -- last-drawn rect
        _clip       = nil,                                  -- visible body rect
        _scroll     = 0,
        _content_h  = 0,
        _view_h     = 0,
        _drag       = nil,                                  -- scrollbar thumb drag
    }, Modal)
end

function Modal:setTitle(title) self.title = title end

-- Compute header height from font (or use explicit override).
local function headerH(self, fonts)
    if self.header_h then return self.header_h end
    if not (fonts and fonts.lg) then return 56 end
    return fonts.lg:getHeight() + DEFAULT_TITLE_PAD * 2
end

function Modal:overflows() return self._content_h > self._view_h + 1 end

local function trackRect(self)
    local c = self._clip
    if not c then return nil end
    return c.x + c.w - Scrollbar.width() - TRACK_INSET, c.y, c.h
end

-- Draw the frame and return the inner body rect for the caller to
-- render into. body_h_request is optional — when given, the modal
-- sizes itself to title + body + 2*pad (capped by max_h_frac) and, when
-- the body doesn't fit, clips and scrolls it. When nil, the caller is
-- responsible for self.h being set (or accepts the natural cap).
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

    -- Header text. With an aside, the title (lg) and aside (sm) are distributed
    -- space-around — each gets an equal margin, so both sit a calculated
    -- distance off their edge instead of pinned to it. Without one, the title
    -- honors title_align (centered / left).
    local has_aside = self.aside and self.aside ~= "" and fonts and fonts.sm
    if self.title and fonts and fonts.lg then
        local ty = by + DEFAULT_TITLE_PAD
        love.graphics.setFont(fonts.lg)
        if has_aside then
            local title_w     = fonts.lg:getWidth(self.title)
            local aside_w, wl = fonts.sm:getWrap(self.aside, self.w)
            local free        = self.w - title_w - aside_w
            local edge        = math.max(0, math.floor(free / 4))
            local mid         = free - edge * 2
            Theme.setColor(Theme.fg.heading)
            love.graphics.print(self.title, bx + edge, ty)
            local aside_h = #wl * fonts.sm:getHeight()
            local ay      = ty + math.max(0, math.floor((fonts.lg:getHeight() - aside_h) / 2))
            Theme.setColor(Theme.fg.muted)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf(self.aside, bx + edge + title_w + mid, ay, aside_w, "left")
        else
            local inset = (self.title_align == "left") and DEFAULT_PAD or 0
            Theme.setColor(Theme.fg.heading)
            love.graphics.printf(self.title, bx + inset, ty, self.w - inset * 2, self.title_align)
        end
    end

    self._box = { x = bx, y = by, w = self.w, h = modal_h }

    -- The body: what fits, and how far the content runs past it.
    local view_h = modal_h - hh - self.pad
    self._view_h    = view_h
    self._content_h = body_h_request or view_h
    self._clip      = { x = bx, y = by + hh, w = self.w, h = view_h }
    if not self:overflows() then self._scroll = 0 end
    self._scroll = Scrollbar.clamp(self._scroll, view_h, self._content_h)

    -- Clip the body while the caller draws it; :endDraw lifts the clip.
    if self:overflows() then
        local sx, sy, sw, sh = love.graphics.getScissor()
        self._prev_scissor = sx and { sx, sy, sw, sh } or {}
        love.graphics.setScissor(bx, by + hh, self.w, view_h)
    end

    if prior_palette then
        -- Restore at end of frame; caller draws body in pinned palette.
        -- Defer the restore to :endDraw().
        self._restore_palette = prior_palette
    end

    return {
        x = bx + self.pad,
        y = by + hh - self._scroll,
        w = self.w - self.pad * 2,
        h = view_h,
        clip = self._clip,
    }
end

-- Call after the body is drawn: lifts the body clip, draws the scrollbar
-- when the content scrolls, and restores the pre-modal palette.
function Modal:endDraw()
    if self._prev_scissor then
        love.graphics.setScissor(unpack(self._prev_scissor))
        self._prev_scissor = nil
    end
    if self:overflows() then
        local tx, ty, th = trackRect(self)
        if tx then
            local mx, my = love.mouse.getPosition()
            local hov = self._drag ~= nil or Scrollbar.containsPoint(tx, ty, th, mx, my)
            Scrollbar.draw(tx, ty, th, self._scroll, self._content_h, hov)
        end
    end
    if self._restore_palette then
        Theme.setActive(self._restore_palette)
        self._restore_palette = nil
    end
end

-- ── Scrolling input. Hosts route these before their own body hits. ────

-- True if the wheel scrolled the body.
function Modal:wheelmoved(_, dy)
    if not self:overflows() or not dy or dy == 0 then return false end
    self._scroll = Scrollbar.clamp(self._scroll - dy * Scrollbar.WHEEL_NOTCH_PX,
                                   self._view_h, self._content_h)
    return true
end

-- True if the press landed on the scrollbar (thumb drag armed, or a
-- track click that jumped the scroll).
function Modal:mousepressed(mx, my, button)
    if button ~= 1 or not self:overflows() then return false end
    local tx, ty, th = trackRect(self)
    if not tx then return false end
    if Scrollbar.containsThumb(tx, ty, th, self._scroll, self._content_h, mx, my) then
        self._drag = { y0 = my, scroll0 = self._scroll }
        return true
    end
    if Scrollbar.containsPoint(tx, ty, th, mx, my) then
        self._scroll = Scrollbar.scrollFromTrackClick(ty, th, my, self._content_h)
        self._drag = { y0 = my, scroll0 = self._scroll }
        return true
    end
    return false
end

function Modal:mousemoved(_, my)
    local d = self._drag
    if not d then return false end
    local _, _, th = trackRect(self)
    if th then
        self._scroll = Scrollbar.scrollFromDrag(th, my - d.y0, d.scroll0, self._content_h)
    end
    return true
end

function Modal:mousereleased()
    if not self._drag then return false end
    self._drag = nil
    return true
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

-- Is the point inside the VISIBLE body? A caller's body hit rects are
-- laid out through the scroll, so a rect can sit above or below the clip;
-- only a hit inside the clip is a hit on something on screen.
function Modal:inBody(mx, my)
    local c = self._clip
    if not c then return true end
    return mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h
end

-- The visible body rect (the clip), for hosts placing popups.
function Modal:bodyClip() return self._clip end

-- Last-drawn box rect, in case the caller needs absolute coords for
-- popups / scrollbars / tooltips that anchor outside the body inset.
function Modal:boxRect() return self._box end

return Modal
