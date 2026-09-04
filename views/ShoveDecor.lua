-- views/ShoveDecor.lua
--
-- Everything the gauntlet's table is made of that isn't a card, a chip or a
-- number: the felt band, its rim, the lighting, the recessed card slots.
--
-- Sibling of views/FeltDecor, which does the same job for the grind felt, and
-- built the same way on purpose.
--
-- ── This module makes NO decisions ────────────────────────────────────
-- views/ShoveView computes every rect and hands it over; each draw here begins
-- with a nil check and returns. If an ornament is showing up where it
-- shouldn't, the bug is in ShoveView, not here.
--
-- Unlike views/FeltDecor there are no size gates to make, because there is only
-- one scale to make them for: main.lua pins the base height at 900 and floors
-- the base width at 1600 (wider windows get a wider frame, never a smaller
-- scale), so ui_scale is always 1.25 and every rect ShoveView hands over is
-- the same size on every monitor. See the header of data/shove_style.
--
-- ── Draw hygiene ─────────────────────────────────────────────────────
-- Every function here leaves the transform stack, colour, line width, blend
-- mode, shader, canvas and font exactly as it found them.

local Theme     = require("views.Theme")
local FeltDecor = require("views.FeltDecor")
local Style     = require("data.shove_style")

local ShoveDecor = {}

local _fonts = nil
local _glow  = nil      -- love.Image | nil, built by configure()

-- Multiply a colour toward black. Returns a plain {r,g,b} so it can go through
-- Theme.setColor like any token. Same helper views/FeltDecor uses.
local function darken(c, k)
    if not c then return nil end
    return { (c[1] or 0) * k, (c[2] or 0) * k, (c[3] or 0) * k }
end

-- DI hook, same convention as views/FeltDecor.configure and
-- views/CardSprites.configure. Wired in main.lua at boot and on resize.
-- Idempotent: the glow mask is built once and reused, so a resize costs
-- nothing.
function ShoveDecor.configure(fonts)
    _fonts = fonts
    if _glow then return end
    if not (love and love.image and love.graphics) then return end

    -- Alpha ramps 1 at the centre to 0 past the edge -- the opposite of
    -- FeltDecor's vignette mask, which is authored to darken edges and so
    -- cannot stand in for a light.
    local cfg   = Style.glow
    local n     = cfg.mask_px or 64
    local inner = cfg.inner or 0
    local outer = cfg.outer or 1
    local power = cfg.power or 1.5
    local span  = math.max(1e-6, outer - inner)

    local ok, data = pcall(love.image.newImageData, n, n)
    if not ok or not data then return end
    for py = 0, n - 1 do
        for px = 0, n - 1 do
            -- Recentre to -1..1, so r == 1 at an edge midpoint and ~1.41 at a
            -- corner. Same normalisation views/FeltDecor uses.
            local dx = (px + 0.5) / n * 2 - 1
            local dy = (py + 0.5) / n * 2 - 1
            local r  = math.sqrt(dx * dx + dy * dy)
            local a  = 1 - math.min(1, math.max(0, (r - inner) / span)) ^ power
            data:setPixel(px, py, 1, 1, 1, a)
        end
    end
    local img_ok, img = pcall(love.graphics.newImage, data)
    if not img_ok or not img then return end
    img:setFilter("linear", "linear")
    pcall(img.setWrap, img, "clamp", "clamp")
    _glow = img
end

-- The table. `band` is { x, y, w, h, screen_w, screen_h } — the slab the card
-- rows sit on, plus the viewport it is painted into.
--
-- Reading order is back to front: the room, the fades, the slab, the rim, the
-- lighting. Nothing here knows what lands on top of it.
function ShoveDecor.drawBackdrop(band)
    if not band then return end
    local cfg = Style.band
    local W, H = band.screen_w, band.screen_h

    -- The room.
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    if band.felt_everywhere then
        -- Felt over the whole screen; the band (and its rail) is a frame
        -- drawn ON the felt, not the edge of it. Outside the frame the felt
        -- sits a shade darker so the framed rows still read as the table.
        Theme.setColor(Theme.bg.felt, 0.55)
        love.graphics.rectangle("fill", 0, 0, W, H)
        Theme.setColor(Theme.bg.felt, 1.00)
        love.graphics.rectangle("fill", 0, band.y, W, band.h)
    else
        -- Soft top fade, slab, soft bottom fade. Three flat rects give the
        -- gradient without needing a mesh or a shader.
        local fh = cfg.fade_h
        Theme.setColor(Theme.bg.felt, cfg.fade_alpha)
        love.graphics.rectangle("fill", 0, band.y - fh, W, fh)
        Theme.setColor(Theme.bg.felt, 1.00)
        love.graphics.rectangle("fill", 0, band.y, W, band.h)
        Theme.setColor(Theme.bg.felt, cfg.fade_alpha)
        love.graphics.rectangle("fill", 0, band.y + band.h, W, fh)
    end

    ShoveDecor.drawRail(band)
    ShoveDecor.drawGlow(band)
    ShoveDecor.drawSpotlight(band)
    ShoveDecor.drawVignette(W, H)
end

-- The rail. Two solid bands, one along each edge of the felt, with an inner
-- edge line so the surface reads as sunk between them rather than painted on.
-- Falls back to the two 1px rules when disabled, which is what shipped before.
function ShoveDecor.drawRail(band)
    if not band then return end
    local cfg = Style.rail
    local W   = band.screen_w

    if not cfg.enabled then
        Theme.setColor(Theme.border.strong, Style.band.rule_alpha)
        love.graphics.rectangle("fill", 0, band.y - 1, W, 1)
        love.graphics.rectangle("fill", 0, band.y + band.h, W, 1)
        return
    end

    local h = cfg.h
    Theme.setColor(cfg.color, 1)
    love.graphics.rectangle("fill", 0, band.y, W, h)
    love.graphics.rectangle("fill", 0, band.y + band.h - h, W, h)

    love.graphics.setLineWidth(1)
    Theme.setColor(darken(cfg.color, cfg.edge_darken), cfg.edge_alpha)
    love.graphics.rectangle("fill", 0, band.y + h, W, 1)
    love.graphics.rectangle("fill", 0, band.y + band.h - h - 1, W, 1)
    love.graphics.setLineWidth(1)
end

-- Light over the card rows, from the centre-bright mask built in configure().
-- Drawn wider and taller than the band so it bleeds past the edges instead of
-- stopping at one.
-- The radial light, anywhere: `color` (a theme colour or rgb table) at
-- `alpha`, stretched to the rect. views/RoomLighting builds its lightmap
-- from this. Blend mode is the caller's.
function ShoveDecor.drawLight(x, y, w, h, color, alpha)
    if not _glow or w <= 0 or h <= 0 or (alpha or 0) <= 0 then return end
    local mw, mh = _glow:getWidth(), _glow:getHeight()
    Theme.setColor(color or Theme.fg.heading, alpha)
    love.graphics.draw(_glow, x, y, 0, w / mw, h / mh)
end

function ShoveDecor.hasLight()
    return _glow ~= nil
end

function ShoveDecor.drawGlow(band)
    local cfg = Style.glow
    if not band or not cfg.enabled or not _glow then return end
    -- Lights the card rows (band.glow_y / glow_h) when the caller gives
    -- them; falls back to the band itself.
    local ly = band.glow_y or band.y
    local lh = band.glow_h or band.h
    local gw = band.screen_w * cfg.w_frac
    local gh = lh * cfg.h_frac
    local gx = (band.screen_w - gw) * 0.5
    local gy = ly + lh * 0.5 - gh * 0.5
    local mw, mh = _glow:getWidth(), _glow:getHeight()
    Theme.setColor(Theme.fg.heading, cfg.alpha)
    love.graphics.draw(_glow, gx, gy, 0, gw / mw, gh / mh)
end

-- Room vignette: FeltDecor's alpha ramp stretched over the whole viewport, so
-- the corners fall away and the centre reads lit. Drawn last, over the table
-- but under the cards, so the cards themselves stay clean.
function ShoveDecor.drawVignette(W, H)
    local cfg = Style.vignette
    if not cfg.enabled then return end
    FeltDecor.drawMask(0, 0, W, H, nil, cfg.alpha)
end

-- Recessed slot behind a card position, so an empty place at the table reads as
-- a place rather than a hole. `felt` is the surface colour it sits in.
function ShoveDecor.drawSlot(x, y, w, h, felt)
    local cfg = Style.slot
    if not cfg.enabled then
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
        return
    end
    Theme.setColor(darken(felt or Theme.bg.felt, cfg.darken), cfg.alpha)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
end

-- Drop-shadow offset for a gauntlet card, or 0 when shadows are off. Lives here
-- so the draw sites don't each read the style table.
function ShoveDecor.shadowOffset()
    local cfg = Style.shadow
    return cfg.enabled and cfg.offset or 0
end

-- Concentric rounded rects standing in for a light over the card rows. Wider
-- than the slab so it bleeds slightly past the edges.
function ShoveDecor.drawSpotlight(band)
    local cfg = Style.spotlight
    if not band or not cfg.enabled then return end
    local W  = band.screen_w
    local cy = band.y + band.h * 0.5
    for i = 1, cfg.layers do
        local frac  = i / cfg.layers
        local alpha = cfg.alpha * (1 - frac)
        local rw    = W * cfg.w_frac * frac + cfg.w_pad
        local rh    = band.h * cfg.h_frac * frac + cfg.h_pad
        Theme.setColor(Theme.fg.heading, alpha)
        love.graphics.rectangle("fill",
            (W - rw) * 0.5, cy - rh * 0.5,
            rw, rh, Theme.space.radius * cfg.radius_mult)
    end
end

-- The House poster and the slot under it. Same sunken card, double frame
-- and gold-roof glyph the grind's poster uses, so it is recognisably the
-- same character; drawn here rather than borrowed because a decor module
-- must not require a grind view. `rect` is the poster; the slot is drawn
-- directly beneath it at `slot_h`.
function ShoveDecor.drawHousePoster(rect, slot_h)
    local cfg = Style.house
    if not rect or not cfg.enabled then return end
    local fl = math.floor
    local s  = rect.s or 1
    local inset = fl(cfg.frame_inset * s)

    -- Poster: sunken card + double frame.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, fl(3 * s))
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", rect.x, rect.y, rect.w, rect.h, fl(3 * s))
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", rect.x + inset, rect.y + inset,
        rect.w - inset * 2, rect.h - inset * 2, fl(2 * s))

    -- House glyph, centered: gold roof, warm body, dark door.
    local pad = fl(cfg.glyph_pad * s)
    local gh  = rect.h - pad * 2
    local gw  = gh
    local gx  = rect.x + fl((rect.w - gw) * 0.5)
    local gy  = rect.y + pad
    local roof_y = gy + fl(gh * 0.42)
    Theme.setColor(Theme.currency.chip)
    love.graphics.polygon("fill",
        gx - fl(gw * 0.08), roof_y,
        gx + fl(gw * 0.5),  gy,
        gx + gw + fl(gw * 0.08), roof_y)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("fill",
        gx + fl(gw * 0.10), roof_y,
        gw - fl(gw * 0.20), gy + gh - roof_y)
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill",
        gx + fl(gw * 0.40), gy + gh - fl(gh * 0.34),
        fl(gw * 0.20), fl(gh * 0.34))

    -- The slot: a dark gap in a lip, the width of the poster, right under
    -- it. Cards are dealt out of here.
    if slot_h and slot_h > 0 then
        local sy = rect.y + rect.h
        Theme.setColor(Theme.border.strong)
        love.graphics.rectangle("fill", rect.x, sy, rect.w, slot_h, fl(2 * s))
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", rect.x + inset, sy + fl(3 * s),
            rect.w - inset * 2, slot_h - fl(6 * s), fl(2 * s))
    end
end

-- The drain bar. `frac` is the fill 0..1; `over` paints it violet for an
-- overshoot. Same track-and-fill shape as the grind's UNDERFLOW cell so the
-- two meters read as one language.
function ShoveDecor.drawMeter(x, y, w, h, frac, over)
    local cfg = Style.meter
    if not cfg.enabled or not w or w <= 0 then return end
    local r = cfg.radius or 0
    Theme.setColor(Theme.bg.sunken, cfg.track_alpha or 1)
    love.graphics.rectangle("fill", x, y, w, h, r)
    frac = math.max(0, math.min(1, frac or 0))
    if frac > 0 then
        Theme.setColor(over and Theme.data.violet or Theme.status.good)
        love.graphics.rectangle("fill", x, y, math.max(h, w * frac), h, r)
    end
end

return ShoveDecor
