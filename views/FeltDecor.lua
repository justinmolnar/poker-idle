-- views/FeltDecor.lua
--
-- Everything the poker-table felt is made of that isn't a card, a chip or a
-- number: the rail, the playing surface, the vignette, the community plate,
-- seat plates and the dealer button.
--
-- Sibling of views/TablePanelStats and views/TablePanelEffects — TablePanel
-- requires all three and routes calls through them. The split here is decor
-- (static structure of the table) vs. VFX (tweened reactions to a result);
-- Effects owns the second and borrows this module's vignette mask for it.
--
-- ── This module makes NO decisions ────────────────────────────────────
-- Every gate lives in views/FeltLayout, which publishes a rect or nil. Each
-- draw here begins with a nil check and returns. That is deliberate: the
-- thresholds are a layout concern (they cost the cards pixels) and having them
-- in one place is what keeps the felt from turning to mud at 32 panels. If an
-- ornament is showing up where it shouldn't, the bug is in FeltLayout, not
-- here.
--
-- ── The vignette mask ─────────────────────────────────────────────────
-- One 64x64 ImageData whose alpha ramps from 0 at the centre to 1 past the
-- corners, built once at boot and stretched to whatever felt rect it is handed.
--
-- A texture rather than a shader on purpose. Stretching a small smooth ramp
-- with bilinear filtering is exactly the case magnification is good at, so it
-- costs one batched draw per panel, produces no banding, gives an ELLIPTICAL
-- vignette matching the rect's aspect for free, and cannot fail to compile on
-- the love.js web build the way services/ShaderRegistry entries can.

local Theme       = require("views.Theme")
local Style       = require("data.felt_style")
local FontService = require("services.FontService")

local FeltDecor = {}

local _mask = nil   -- love.Image | nil, built by configure()
local _font = nil   -- for the button's "D"

-- Multiply a colour toward black. Returns a plain {r,g,b} so it can go through
-- Theme.setColor like any token.
local function darken(c, k)
    if not c then return nil end
    return { (c[1] or 0) * k, (c[2] or 0) * k, (c[3] or 0) * k }
end

-- DI hook, same convention as views/Chips.configureFont and
-- views/CardSprites.configure. Wired in main.lua at boot and on resize.
-- Idempotent: the mask is built once and reused, so a resize costs nothing.
function FeltDecor.configure(fonts)
    _font = fonts and (fonts.sm or fonts.xs) or nil
    if _mask then return end
    if not (love and love.image and love.graphics) then return end

    local cfg = Style.vignette
    local n     = cfg.mask_px or 64
    local inner = cfg.inner or 0.5
    local outer = cfg.outer or 1.3
    local power = cfg.power or 1.5
    local span  = math.max(1e-6, outer - inner)

    local ok, data = pcall(love.image.newImageData, n, n)
    if not ok or not data then return end
    for py = 0, n - 1 do
        for px = 0, n - 1 do
            -- Recentre to -1..1, so r == 1 at an edge midpoint and ~1.41 at a
            -- corner. Same normalisation shaders/radial_glow.frag uses.
            local dx = (px + 0.5) / n * 2 - 1
            local dy = (py + 0.5) / n * 2 - 1
            local r  = math.sqrt(dx * dx + dy * dy)
            local a  = math.min(1, math.max(0, (r - inner) / span)) ^ power
            data:setPixel(px, py, 0, 0, 0, a)
        end
    end
    local img_ok, img = pcall(love.graphics.newImage, data)
    if not img_ok or not img then return end
    img:setFilter("linear", "linear")
    pcall(img.setWrap, img, "clamp", "clamp")
    _mask = img
end

-- Paint the mask over a rect in `color` at `alpha`. Shared by the resting felt
-- vignette and the win/loss flash in views/TablePanelEffects.
function FeltDecor.drawMask(x, y, w, h, color, alpha)
    if not _mask or alpha <= 0.001 or w <= 0 or h <= 0 then return end
    local mw, mh = _mask:getWidth(), _mask:getHeight()
    Theme.setColor(color or { 0, 0, 0 }, alpha)
    love.graphics.draw(_mask, x, y, 0, w / mw, h / mh)
end

function FeltDecor.hasMask() return _mask ~= nil end

-- ── Rail + playing surface ───────────────────────────────────────────

-- The outer ring. Filled, not stroked: a table's rail is a solid band the felt
-- is recessed into, and stroking it would just give a thicker version of the
-- border line the felt already had.
--
-- Colour comes from stake_themes' `rail_color`, which is its OWN key rather
-- than a derivation of border_color. Deriving it was the first version and it
-- was wrong twice over: border_color runs T1..T4 as one hue getting brighter,
-- so the rail just looked "more gold" as stakes climbed instead of looking like
-- a different table; and T6's border is the same gold as Theme.currency.chip,
-- which is the banked-bounty trim around the panel, so the two competed.
--
-- A rail is wood or leather. It progresses by MATERIAL -- vinyl, oak, walnut,
-- oxblood, violet leather, lacquer -- and gold stays reserved for chips.
function FeltDecor.drawRail(rail, stake_theme)
    if not rail then return end
    local cfg  = Style.rail
    -- Fallback path (a stake with no rail_color): darken border_color so it at
    -- least reads as a ring rather than a bright trim line.
    local ring = (stake_theme and stake_theme.rail_color)
                 or darken((stake_theme and stake_theme.border_color)
                           or Theme.border.default, cfg.darken or 0.5)

    Theme.setColor(ring, 1)
    love.graphics.rectangle("fill", rail.x, rail.y, rail.w, rail.h, rail.radius)

    -- Inner edge, so the surface reads as sunk into the ring rather than
    -- painted on top of it.
    local rw = rail.width
    love.graphics.setLineWidth(1)
    Theme.setColor(darken(ring, 0.55), cfg.edge_alpha or 0.5)
    love.graphics.rectangle("line", rail.x + rw, rail.y + rw,
                            rail.w - 2 * rw, rail.h - 2 * rw,
                            math.max(0, (rail.radius or 0) - 1))
    love.graphics.setLineWidth(1)
end

-- The playing surface. `rect` is the felt rect when there is no rail, or the
-- inset surface when there is — the caller passes whichever, so this doesn't
-- need to know. Draws the stake tint, then the resting vignette on top of it
-- and under everything else.
function FeltDecor.drawSurface(x, y, w, h, felt_color, radius)
    Theme.setColor(felt_color)
    love.graphics.rectangle("fill", x, y, w, h, radius)
    FeltDecor.drawMask(x, y, w, h, nil, Style.vignette.static_alpha or 0)
end

-- ── Plates ───────────────────────────────────────────────────────────

-- Recessed strip behind the five community slots, so an empty slot reads as a
-- place at the table rather than a hole in the felt.
function FeltDecor.drawCommPlate(rect, felt_color)
    if not rect then return end
    local cfg = Style.comm_plate
    Theme.setColor(darken(felt_color, cfg.darken or 0.5), cfg.alpha or 0.3)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h,
                            Theme.space.radius)
end

-- Backing behind one opponent's name + cards. `alpha_mul` is the seat's own
-- alpha, so a folded or busted seat dims its plate with the rest of it.
function FeltDecor.drawSeatPlate(rect, felt_color, alpha_mul)
    if not rect then return end
    local cfg = Style.seat_plate
    Theme.setColor(darken(felt_color, cfg.darken or 0.6),
                   (cfg.alpha or 0.25) * (alpha_mul or 1))
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h,
                            Theme.space.radius)
end

-- ── Dealer button ────────────────────────────────────────────────────

-- Bone disc with a "D" when it is big enough to hold one, plain disc when it
-- is not — the same shrink-then-drop rule the card plates and seat names
-- follow. `cx, cy` is the disc's CENTRE.
function FeltDecor.drawButton(cx, cy, d, alpha)
    if not d or d <= 0 then return end
    alpha = alpha or 1
    local r = d * 0.5
    Theme.setColor(Theme.card.face, alpha)
    love.graphics.circle("fill", cx, cy, r)
    love.graphics.setLineWidth(1)
    Theme.setColor(Theme.card.edge, alpha * 0.85)
    love.graphics.circle("line", cx, cy, r)
    love.graphics.setLineWidth(1)

    if not _font then return end
    local gw = _font:getWidth("D")
    -- Measured against the INK, positioned against the LINE box: an 8px face
    -- draws 1.25em of ink inside a 2.625em box, so a box-height test would
    -- reject a "D" that fits the disc with room to spare. Same rule as
    -- views/CardSprites.frontPlate.
    if gw + 2 > d or FontService.inkHeight(_font) + 1 > d then return end
    local prev = love.graphics.getFont()
    love.graphics.setFont(_font)
    Theme.setColor(Theme.card.black, alpha)
    love.graphics.print("D", math.floor(cx - gw * 0.5),
                             math.floor(cy - _font:getHeight() * 0.5))
    -- Unconditional, including when prev is nil: setFont(nil) is setFont(), the
    -- documented "back to the default font" call. Guarding on prev would leave
    -- this module's font set for whoever draws next.
    love.graphics.setFont(prev)
end

return FeltDecor
