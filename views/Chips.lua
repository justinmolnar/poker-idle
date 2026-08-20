-- views/Chips.lua
--
-- Engine-agnostic chip rendering. Operates on opaque denomination
-- indices (into data/chips.lua); no knowledge of poker. Procedural
-- top-down chips — `paintChip` is the single seam to swap in sprite
-- art later.
--
-- Pure breakdown logic (amount -> ordered token-index list, tier inference)
-- lives in services/DenominationBreakdown so non-view callers can compose
-- breakdowns without reaching across layers.
--
-- ─── Why a chip is built the way it is ──────────────────────────────
-- A chip used to be two filled circles. It read as a colored dot, the
-- denomination label sat straight on the saturated body (unreadable on
-- anything mid-tone), and a stack of them was one flat dark block.
--
-- The anatomy below is a real casino chip, in draw order: a near-black
-- silhouette, the rim, the edge spots set into it, the face, a dome
-- gradient, the inner ring, the hot-stamp inlay band, and the light and
-- shadow that make it a cylinder instead of a circle.
--
-- ─── Detail scales DOWN, not up ─────────────────────────────────────
-- Two facts bound what a chip may cost:
--
--   * A pile is up to 6 chips per column and each buried chip shows a
--     4px bottom crescent — 15% of itself. Full anatomy on a buried chip
--     is invisible by construction.
--   * Chips render between ~4px and ~20px radius (chip_scale is
--     card_scale, clamped [0.3, 1.5] in views/FeltLayout), and 32 table
--     panels can be open at once. At the small end the whole chip is
--     smaller than one edge spot.
--
-- So `detail` is not a quality knob, it is correctness: a buried chip
-- paints its visible crescent and nothing else, and a chip below
-- MIN_DETAIL_R paints flat. At small sizes the new art is SIMPLER than
-- what it replaced, not richer, because anything else is mud.

local ChipData    = require("data.chips")
local Theme       = require("views.Theme")
local FontService = require("services.FontService")

local Chips = {}

-- ── Constants (procedural rendering tunables) ────────────────────────
-- Bases are the 1x design values; the live values are recomputed by
-- Chips.setScale(s) at boot + resize so chips grow with the window.
-- 15 rather than 11 because the label sets the floor. Thin Sans has no
-- crisp size between 8 and 16 (services/FontService), so 8px is as small
-- as a denomination can legibly get, and a 26px chip left a 4-character
-- label filling the entire face. The chip has to be big enough for the
-- text, not the other way round.
local CHIP_RADIUS_BASE    = 18
-- Gap between columns, as a fraction of the RADIUS. It used to be a flat
-- 2px, set when a chip was 22px across; at 44px that is no gap at all and
-- neighbouring columns fuse into one unreadable mass. Everything about a
-- chip scales with the chip, this included.
local COL_GAP_FRAC        = 0.30
-- Chips overlap by a fraction of their own radius, not by a fixed pixel
-- count, so the stack stays as dense as the chip is big. A real chip is
-- ~8% as thick as it is wide; this is a touch more so the rim still reads.
-- How much of each chip shows in a column, as a fraction of the radius.
-- A real chip is ~8% as thick as it is wide; this is ~11%, a little loose
-- so each one stays separately visible.
--
-- It was nearly double this while the wall was painted flat, because at
-- realistic thickness a flat sliver just fused into the chip below it. Now
-- that the wall is shaded like a cylinder it reads at proper proportions —
-- and has to, because a wall thicker than a chip stops looking like an
-- edge and starts looking like a gap.
local STACK_OVERLAP       = 0.24

local CHIP_RADIUS    = CHIP_RADIUS_BASE
local CHIP_DIAMETER  = 2 * CHIP_RADIUS
local STACK_OFFSET_Y = -math.max(2, math.floor(CHIP_RADIUS * STACK_OVERLAP))
local COL_GAP        = math.max(2, math.floor(CHIP_RADIUS * COL_GAP_FRAC))
local MAX_PER_COLUMN = 6
-- A pile that runs out of width folds into staggered rows instead of
-- throwing chips away. See stackLayout.
-- Fallbacks only. Callers say how wide their pile may get, because only
-- they know what it would run into — the pot pile has community cards
-- above it, the player's pile has hole cards beside it, the bankroll band
-- has the whole width of the screen. See `max_cols` in stackLayout.
-- Unbounded by default: a caller that says nothing gets the single line it
-- always got, and only callers that opt in start wrapping. A default cap
-- here would silently reshape every pile in the game.
local DEFAULT_MAX_COLS = math.huge
local DEFAULT_MAX_ROWS = 3
-- How far back a row sits, as a fraction of the radius. Has to be big
-- enough that a back chip clears the one in front of it — at a small lift
-- the back row is four-fifths hidden and reads as debris poking out from
-- behind the pile rather than as a row of chips.
-- Nearly a full diameter, so a back row clears the row in front of it
-- almost completely instead of peering over its shoulder. Anything less
-- and the rows read as one crowded mass with debris behind it.
local ROW_LIFT       = 1.75

-- Anatomy, as fractions of the radius.
local R_RIM        = 0.92   -- rim body inside the outline
-- The face, the lip and the plate all share one radius. The plate is that
-- circle's slice, so its arc ends land exactly ON the lip instead of
-- poking out past it as a pair of pale wings.
local R_FACE       = 0.76   -- face disc — also what crops the spots
local R_INNER_RING = 0.76
local R_LIGHT      = 0.93   -- rim light / shadow arc radius
-- Narrower than a real chip's spots. On a stack all you see of a buried
-- chip is a sliver of rim, and spots wide enough to look right face-on
-- covered ~40% of that sliver in near-white, which read as static rather
-- than as chips.
local SPOT_FILL    = 0.30   -- spot angular width as a fraction of its slot

-- Color derivations from the body color.
local K_OUTLINE  = 0.34
local K_RIM      = 0.72
local K_RING     = 0.45
local K_DOME     = 1.12
local INLAY_MIX  = 0.85     -- toward white; the inlay is ALWAYS light
local INK        = { 0.10, 0.10, 0.13 }

-- Below this radius the anatomy stops resolving and turns to mud.
local MIN_DETAIL_R = 7
-- A buried chip draws only the arc the chip above doesn't cover, plus
-- whichever spots fall inside it.
local BURIED_ARC_A, BURIED_ARC_B = 0.10, math.pi - 0.10
-- Shading of the chip WALL — the sliver of a buried chip. Base tone, then
-- a translucent highlight inset from the bottom edge by this fraction of
-- the stack overlap.
-- Tones ACROSS the wall, right to left. A vertical surface curving away
-- from a light at the upper left is shaded by ANGLE, not by radius:
-- brightest where it faces the light, falling off around the curve.
--
-- Shading it radially instead — a highlight inset from the outer edge —
-- is precisely what a flat disc lit from above looks like, which is why
-- the stack read as chip TOPS peeking out from under each other rather
-- than as the sides of a stack.
-- Three steps, not four: the wall is ~5px tall and a fourth band is
-- imperceptible across it while costing an arc on every buried chip, of
-- which a busy frame draws hundreds.
local WALL_TONES = { 0.72, 0.90, 1.07 }
-- Below this foreshortening a tumbling chip is edge-on and shows its rim.
local EDGE_SQUASH = 0.30

-- Cast shadow under a column base.
local SHADOW_ALPHA = 0.20
local SHADOW_RX    = 1.02
local SHADOW_RY    = 0.42
local SHADOW_DY    = 0.35

-- How much a chip dims for each chip stacked on top of it. Without this a
-- tall column is a single flat block; with it the column falls away
-- underneath its top chip.
local SHADE_PER_DEPTH, SHADE_FLOOR = 0.05, 0.68

-- ── The inlay band ──────────────────────────────────────────────────
-- A horizontal band, not a circular plate: a circle big enough to hold a
-- four-character denomination doesn't fit inside a chip this size.
--
-- ONE size for every denomination. A plate that resized itself to each
-- label made the row look like it was breathing — the plate is part of the
-- chip's manufacture, not part of its value, and a real chip series stamps
-- the same inlay on every denomination in it.
--
-- So it is sized once, to the widest label in the ladder, and that in turn
-- is what sets the chip's radius. Measured against the real font
-- (assets/fonts/Thin Sans.ttf): every glyph advances 7px at size 8 except
-- 'M' (11px) and 'Q' (8px), and digits are 10px TALL — cap height is
-- 1.25em, not 1em, inside a 2.625em line box. The widest label is "100M"
-- at 32px, so the plate is 36px and the chip is 44px across.
local BAND_PAD_X    = 2      -- px of plate either side of the widest label
-- Fraction of the font's LINE height the band covers. Thin Sans has a very
-- tall line box relative to its ink, so wrapping the box would make the
-- band swallow the chip; this wraps the ink with a margin.
-- Also sets how much the plate's arc ends curve: the taller the plate, the
-- further round the chip's circle its ends sweep. At 0.8 the ends were a
-- pixel off straight and the plate still read as a rectangle.
local BAND_INK      = 1.00
-- How far out the band may reach. Past this its corners break the rim.
local BAND_MAX_R    = 0.96
-- Share of the font's line height that is actual ink. A property of the
-- FACE, not of chips, so it lives in services/FontService — views/CardSprites
-- measures its rank glyphs against the same number.
local INK_OF_LINE   = FontService.INK_OF_LINE
local LABEL_PAD     = 1      -- px of plate that must remain around the ink

-- ── Scratch color tables ────────────────────────────────────────────
-- drawChip is the hottest function in the renderer (up to ~800 calls a
-- frame). Deriving eight colors per chip as fresh tables was thousands of
-- allocations a frame; these are mutated in place instead.
local _body  = { 0, 0, 0 }
local _out   = { 0, 0, 0 }
local _rim   = { 0, 0, 0 }
local _ring  = { 0, 0, 0 }
local _dome  = { 0, 0, 0 }
local _inlay = { 0, 0, 0 }
local _spot  = { 0, 0, 0 }
local _ink   = { 0, 0, 0 }
local _bezel        = { 0, 0, 0 }
local _spot_dim     = { 0, 0, 0 }
local _glyph_ring   = { 0, 0, 0 }
local _glyph_colors = { nil, nil }   -- reused { body, ring } pair

local IDENTITY_TINT = { 1, 1, 1 }

-- ── Frame counters (dev HUD) ────────────────────────────────────────
-- Chip piles are the highest-count repeated element in the game and
-- nothing else in the codebase measures draw volume, so the renderer
-- counts itself. `scale_min` is the one that matters most: it says how
-- small chips actually get on a full grid, which decides whether any of
-- this anatomy resolves down there at all.
local _n_chips   = 0
local _scale_min = math.huge
local _scale_max = 0

local function mul(dst, c, k)
    dst[1] = c[1] * k
    dst[2] = c[2] * k
    dst[3] = c[3] * k
    return dst
end

local function mulc(dst, c, t, s)
    dst[1] = c[1] * t[1] * s
    dst[2] = c[2] * t[2] * s
    dst[3] = c[3] * t[3] * s
    return dst
end

local function mix(dst, a, b, t)
    dst[1] = a[1] + (b[1] - a[1]) * t
    dst[2] = a[2] + (b[2] - a[2]) * t
    dst[3] = a[3] + (b[3] - a[3]) * t
    return dst
end

local function mixWhite(dst, c, t)
    dst[1] = c[1] + (1 - c[1]) * t
    dst[2] = c[2] + (1 - c[2]) * t
    dst[3] = c[3] + (1 - c[3]) * t
    return dst
end

-- ── Label font ──────────────────────────────────────────────────────
-- The game font, not LÖVE's default. Chip faces used to be the only text
-- in the game in a foreign typeface, at the smallest size anything is
-- ever drawn, which is most of why they were unreadable.
--
-- Configured by DI (main.lua) rather than reached for from data/,
-- matching the configureFromFonts convention views/Panel and
-- views/ComponentRenderer already use.
local _font                 -- love Font, from the caller's fonts table
local _band_hw    = 0       -- plate radius, px — the SAME for every rung
local _band_hh    = 0       -- plate half-height, px
local _band_chord = 0       -- plate half-width at the LABEL's height, px
local _plate_fill = {}      -- plate outline, rebuilt only on font/scale change
local _fit_dirty = true

function Chips.configureFont(fonts)
    _font      = fonts and (fonts.sm or fonts.xs) or nil
    _fit_dirty = true
end

-- Rescale chip rendering against the live ui_scale. main.lua calls
-- this at boot + on resize.
function Chips.setScale(s)
    s = s or 1
    CHIP_RADIUS    = math.max(2, math.floor(CHIP_RADIUS_BASE * s))
    CHIP_DIAMETER  = 2 * CHIP_RADIUS
    STACK_OFFSET_Y = -math.max(2, math.floor(CHIP_RADIUS * STACK_OVERLAP))
    COL_GAP        = math.max(2, math.floor(CHIP_RADIUS * COL_GAP_FRAC))
    _fit_dirty     = true
end

-- Current scaled chip radius. A pile's base chip is CENTERED on the `y` passed
-- to drawStack, so callers that want the pile's visual BOTTOM at a baseline
-- pass `baseline - Chips.radius()`.
function Chips.radius() return CHIP_RADIUS end

-- Per-denomination band width. Computed once per font/scale change,
-- never per frame.
--
-- The label is NEVER scaled. Nothing else in the project scales this font,
-- and for good reason: it is a pixel face, so any fractional scale lands
-- its stems between pixels and turns 8px glyphs to mush. The band adapts
-- to the text instead of the text being squeezed into the band.
-- The plate is a slice of a circle concentric with the chip: straight top
-- and bottom, ARC ends. A flat-ended bar reads as something pasted onto a
-- round object, where an arc-ended one reads as printed on it — the ends
-- run parallel to the lip they sit inside.
--
-- The consequence is that the plate is narrower at the top and bottom than
-- through the middle, so the width that matters is the chord at the
-- LABEL's own height, not the widest point.
local function buildPlate(radius, half_h)
    local out  = {}
    local a    = math.asin(math.min(1, half_h / radius))
    local segs = 8
    for i = 0, segs do                        -- right end, top to bottom
        local t = -a + (2 * a) * (i / segs)
        out[#out + 1] = radius * math.cos(t)
        out[#out + 1] = radius * math.sin(t)
    end
    for i = 0, segs do                        -- left end, bottom to top
        local t = (math.pi - a) + (2 * a) * (i / segs)
        out[#out + 1] = radius * math.cos(t)
        out[#out + 1] = radius * math.sin(t)
    end
    return out
end

local function ensureFit()
    if not _fit_dirty or not _font then return end
    _fit_dirty = false
    _band_hh = math.floor(_font:getHeight() * BAND_INK * 0.5)

    -- Widest label anywhere in the ladder decides the plate for all of them.
    local widest = 0
    for _, d in ipairs(ChipData.denominations) do
        local w = (d.label and _font:getWidth(d.label)) or 0
        if w > widest then widest = w end
    end

    -- Size the plate so the widest label clears the ARC at the height the
    -- label actually occupies. Sizing it at the plate's midline instead
    -- would let the label's corners poke out through the curve.
    local ink_half = _font:getHeight() * INK_OF_LINE * 0.5
    local need_w   = widest * 0.5 + BAND_PAD_X
    local radius   = math.sqrt(need_w * need_w + ink_half * ink_half)

    -- Clipped to the lip, never past it. A plate wider than the ring it
    -- sits inside shows its ends sticking out either side.
    _band_hw    = math.min(CHIP_RADIUS * R_INNER_RING, radius)
    _band_hh    = math.min(_band_hh, math.floor(_band_hw) - 1)
    _band_chord = math.sqrt(math.max(1, _band_hw * _band_hw - ink_half * ink_half))
    _plate_fill = buildPlate(_band_hw, _band_hh)
end

-- Plate geometry and this rung's label width, so a test can prove no
-- denomination overflows the shared plate:
--   chord  — half-width at the LABEL's height (what the text must fit)
--   half_h — half-height
--   w      — this label's width
--   radius — the plate's widest point, at its midline
function Chips.bandMetrics(denom_idx)
    ensureFit()
    local d = ChipData.denominations[denom_idx]
    local w = (d and d.label and _font and _font:getWidth(d.label)) or 0
    return _band_chord, _band_hh, w, _band_hw
end

-- ── Single chip render (the seam for sprite art later) ───────────────
-- Paints one chip centered on (0, 0) at radius r. Every caller draws
-- centered — services/Tumble calls render callbacks as fn(0, 0) inside
-- its own transform, and FlightSystem aims flights at slot centers.
--
-- detail:
--   "full"   — the whole anatomy. Top-of-column chips and loose chips.
--   "buried" — the uncovered bottom crescent only.
--   "edge"   — rim and spots, no face: a chip seen edge-on mid-tumble.
--   "flat"   — silhouette + rim + face. Anything below MIN_DETAIL_R.
--
-- `rot` turns only the EDGE SPOTS, never the whole chip. The lighting has
-- to keep coming from the top-left and the inlay band has to stay level
-- under an upright label, so rotating the chip as a whole would be wrong
-- on both counts. Turning the spots costs nothing — it is one addition to
-- their starting angle — and it is the only part that needs to differ from
-- one chip to the next.
local function paintChip(r, spec, alpha, detail, band_hw, spot_cap, rot, escale)
    local n     = spec.spots or 6
    if spot_cap and n > spot_cap then n = spot_cap end
    local step  = (2 * math.pi) / n
    local half  = step * SPOT_FILL * 0.5
    local phase = math.pi / n + (rot or 0)   -- keeps a spot off the horizontal

    -- The silhouette is painted FIRST and reaches furthest out: it is what
    -- separates a chip from the felt at every stake, and it is what keeps
    -- the outer edge dark if this is ever baked to a texture.
    if detail == "buried" then
        -- What shows of a buried chip is the WALL OF A CYLINDER seen from
        -- slightly above, not the bottom of a flat disc. Painted in one
        -- flat colour it reads as a paper cut-out hovering over the chip
        -- below it, with the gap between them looking like empty space.
        --
        -- A real wall is darkest along its bottom edge and lightest where
        -- it turns over to meet the face above. Concentric arcs run in
        -- exactly that direction here — the outer radius IS the bottom
        -- edge, and smaller radii climb the wall toward the chip above —
        -- so two tones and a highlight are enough to turn the sliver into
        -- something with thickness.
        Theme.setColor(_out, alpha)
        love.graphics.arc("fill", "pie", 0, 0, r, BURIED_ARC_A, BURIED_ARC_B)

        local nt   = #WALL_TONES
        local span = (BURIED_ARC_B - BURIED_ARC_A) / nt
        for i = 1, nt do
            mul(_dome, _rim, WALL_TONES[i])
            Theme.setColor(_dome, alpha)
            -- Overlap each segment slightly into the next so the joins
            -- don't leave hairlines of the outline showing through.
            local a0 = BURIED_ARC_A + (i - 1) * span
            local a1 = a0 + span + 0.02
            love.graphics.arc("fill", "pie", 0, 0, r - 1, a0, a1)
        end

        -- Edge spots read as the milling on a chip's side, which is most
        -- of what tells you you're looking at an edge at all.
        --
        -- At HALF contrast, though. Face-on a spot has to fight its body to
        -- read; repeated down six slivers at that strength it stops reading
        -- as chips and starts reading as static. Here the shading is the
        -- signal and the spots are texture on top of it.
        mix(_spot_dim, _rim, _spot, 0.5)
        Theme.setColor(_spot_dim, alpha)
        local TAU = 2 * math.pi
        for i = 0, n - 1 do
            local a = (phase + i * step) % TAU
            if a > BURIED_ARC_A and a < BURIED_ARC_B then
                love.graphics.arc("fill", "pie", 0, 0, r - 1, a - half, a + half)
            end
        end

        return
    end

    Theme.setColor(_out, alpha)
    love.graphics.circle("fill", 0, 0, r)
    Theme.setColor(_rim, alpha)
    love.graphics.circle("fill", 0, 0, r * R_RIM)

    -- Edge-on. A chip mid-tumble is squashed to a sliver by the caller, and
    -- painting a FACE into that sliver is what made it read as a smear:
    -- turn a real chip on its side and you see the milled rim and the spots
    -- running through it, never the printed face.
    if detail == "edge" then
        Theme.setColor(_spot, alpha)
        for i = 0, n - 1 do
            local a = phase + i * step
            love.graphics.arc("fill", "pie", 0, 0, r * R_RIM, a - half, a + half)
        end
        Theme.setColor(_rim, alpha)
        love.graphics.circle("fill", 0, 0, r * 0.34)
        return
    end

    if detail == "full" then
        -- Edge spots, painted from the center outward and then cropped by
        -- the face disc below — cheaper than building annular sectors.
        Theme.setColor(_spot, alpha)
        for i = 0, n - 1 do
            local a = phase + i * step
            love.graphics.arc("fill", "pie", 0, 0, r * R_RIM, a - half, a + half)
        end
    end

    -- Face. Also what turns the spot pies into rim segments.
    Theme.setColor(_body, alpha)
    love.graphics.circle("fill", 0, 0, r * R_FACE)

    if detail ~= "full" then return end

    -- Dome. A few concentric steps read as a curved surface for far less
    -- than a gradient mesh, and at this size nobody can count the bands.
    local steps = 5
    for i = 1, steps do
        local t  = i / steps
        local rr = r * R_FACE * (1 - t * 0.62)
        _dome[1] = _body[1] + (_body[1] * K_DOME - _body[1]) * t
        _dome[2] = _body[2] + (_body[2] * K_DOME - _body[2]) * t
        _dome[3] = _body[3] + (_body[3] * K_DOME - _body[3]) * t
        Theme.setColor(_dome, alpha * 0.35)
        love.graphics.circle("fill", 0, 0, rr)
    end

    -- Light from the top-left, shadow bottom-right. What makes it read as
    -- a cylinder rather than a disc. Drawn before the plate so the plate is
    -- not lit like part of the moulding -- and, more importantly, so it
    -- stays OUTSIDE the native-pixel frame below, which would otherwise
    -- rescale these radii.
    love.graphics.setLineWidth(math.max(1, r * 0.14))
    love.graphics.setColor(1, 1, 1, alpha * 0.16)
    love.graphics.arc("line", "open", 0, 0, r * R_LIGHT, math.pi, math.pi * 1.75)
    love.graphics.setColor(0, 0, 0, alpha * 0.20)
    love.graphics.arc("line", "open", 0, 0, r * R_LIGHT, math.pi * 0.1, math.pi * 0.85)
    love.graphics.setLineWidth(1)

    -- ── Hot-stamp plate, and the label on it ──────────────────────────
    -- One decision, not two. The plate exists to carry the number; drawn
    -- without it you get a blank white bar stamped across the chip, which
    -- is worse than no plate at all. So the fit is worked out first and
    -- either both are drawn or neither is.
    --
    -- Its own function so that bailing out of it doesn't skip the lip
    -- below — every chip at this detail level has a lip, labelled or not.
    local function stamp()
        if not (band_hw and _font and spec.label) then return end
        if #_plate_fill == 0 then return end

        local bh    = _band_hh
        local es    = escale or 1
        local fw    = _font:getWidth(spec.label)
        local fh    = _font:getHeight()
        -- Ink, not line box: this face's digits are 1.25em tall inside a
        -- 2.625em line box (see the band constants above).
        local ink_h = fh * INK_OF_LINE

        -- Will the label land on the plate at native size? Piles are drawn
        -- inside love.graphics.scale(card_scale), card_scale being any
        -- fraction from 0.3 to 1.5, and a pixel font rendered at a
        -- fraction puts its stems between pixels — which is exactly why
        -- chip labels came out crisp in the bankroll band (drawn at 1.0)
        -- and mush on every table panel. There is no fractional fix: this
        -- face is sharp at 1x, 2x, 3x and nowhere in between.
        --
        -- So the label lands on whole screen pixels or the chip goes bare,
        -- and a short label survives to a smaller chip than a long one.
        -- Measured against the chord at the label's own height: the plate
        -- curves in at the top and bottom, so its midline width would
        -- overstate the room.
        if fw * 0.5 + LABEL_PAD > _band_chord * es then return end
        if ink_h * 0.5 + LABEL_PAD > bh * es then return end

        -- The plate is ONE size for every denomination and scales with the
        -- chip, so a row of chips never looks like it is breathing. It is
        -- always light, so the ink on it is always dark — which retires
        -- the old luminance flip that put light text on exactly the
        -- mid-tone bodies (the 25c green, the 5c red) where it vanished.
        Theme.setColor(_inlay, alpha)
        love.graphics.polygon("fill", _plate_fill)
        -- A real bezel, at full strength. On a pale chip (the 1c is nearly
        -- white) a light plate on a light body has no edge at all, and the
        -- whole chip reads as one blank disc.
        love.graphics.setLineWidth(1)
        Theme.setColor(_bezel, alpha)
        love.graphics.polygon("line", _plate_fill)

        love.graphics.push()
        if es ~= 1 then love.graphics.scale(1 / es, 1 / es) end
        Theme.setColor(_ink, alpha)
        local prev = love.graphics.getFont()
        love.graphics.setFont(_font)
        -- Centred on the LINE box, the same convention every other view
        -- uses (views/Panel, views/CatalogModal and views/GrindView all
        -- centre with `- font:getHeight() * 0.5`).
        love.graphics.print(spec.label,
                            math.floor(-fw * 0.5), math.floor(-fh * 0.5))
        if prev then love.graphics.setFont(prev) end
        love.graphics.pop()
    end
    stamp()

    -- ── The lip, LAST — over the plate and over the label ──────────────
    -- On a real chip the inlay is set into the face and the moulded ring
    -- runs across it; the inlay does not stop politely at the ring's edge.
    -- Drawing the ring on top is what sells that, and it retires the
    -- problem of making a straight-sided plate meet a circle exactly: the
    -- plate may overhang, because the lip is what the eye reads as the
    -- boundary.
    love.graphics.setLineWidth(math.max(1, r * 0.07))
    Theme.setColor(_ring, alpha)
    love.graphics.circle("line", 0, 0, r * R_INNER_RING)
    love.graphics.setLineWidth(1)
end

-- Derive every color this chip needs into the scratch tables.
-- `shade` dims a chip by its depth in a column; `tint` is the per-stake
-- cast. They multiply, so a buried chip on a gold table is both.
local function setupColors(spec, tint, shade)
    tint  = tint or IDENTITY_TINT
    shade = shade or 1
    mulc(_body, spec.color, tint, shade)
    mul(_out,  _body, K_OUTLINE)
    mul(_rim,  _body, K_RIM)
    mul(_ring, _body, K_RING)
    mixWhite(_inlay, _body, INLAY_MIX)
    mul(_bezel, _body, 0.28)
    mulc(_spot, spec.spot or INK, tint, shade)
    -- The ink dims with its plate, not independently, which holds the
    -- contrast RATIO steady under any stake tint.
    mulc(_ink, INK, tint, shade)
end

-- with_label = true draws the denomination on the inlay.
-- shade  (optional) multiplies the chip's colors — stack depth.
-- depth  (optional) chips above this one in its column; > 0 means only
--        the bottom crescent is visible and the rest is wasted work.
-- escale (optional) the caller's own love.graphics.scale factor, so the
--        detail level is picked from the chip's REAL on-screen size
--        rather than its nominal radius.
-- rot    (optional) turns this chip's edge spots. See stackLayout.
function Chips.drawChip(x, y, denom_idx, alpha, with_label, tint, shade, depth, escale, rot)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    setupColors(d, tint, shade)

    local r   = CHIP_RADIUS
    local es  = escale or 1
    local eff = r * es

    _n_chips = _n_chips + 1
    if es < _scale_min then _scale_min = es end
    if es > _scale_max then _scale_max = es end
    local detail
    if depth and depth > 0 then
        detail = "buried"
    elseif eff < MIN_DETAIL_R then
        detail = "flat"
    else
        detail = "full"
    end

    local band_hw
    if with_label and detail == "full" then
        ensureFit()
        band_hw = _band_hw
    end

    -- Spots below ~1.5px wide are an arc apiece for nothing.
    local spot_cap = (eff < 10) and 6 or nil

    if x == 0 and y == 0 then
        paintChip(r, d, alpha, detail, band_hw, spot_cap, rot, es)
    else
        love.graphics.push()
        love.graphics.translate(x, y)
        paintChip(r, d, alpha, detail, band_hw, spot_cap, rot, es)
        love.graphics.pop()
    end
end

-- A chip seen edge-on. Its own entry point rather than another flag on
-- drawChip, because the caller that wants it (a tumbling chip, see
-- services/Tumble) knows from its foreshortening, not from anything about
-- the chip itself.
--
-- Chips.EDGE_SQUASH is the threshold: below that much vertical squash, a
-- painted face is a smear and the rim is what a real chip shows.
Chips.EDGE_SQUASH = EDGE_SQUASH

function Chips.drawChipEdge(x, y, denom_idx, alpha, tint, rot)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    setupColors(d, tint, 1)
    _n_chips = _n_chips + 1
    if x == 0 and y == 0 then
        paintChip(CHIP_RADIUS, d, alpha, "edge", nil, nil, rot)
    else
        love.graphics.push()
        love.graphics.translate(x, y)
        paintChip(CHIP_RADIUS, d, alpha, "edge", nil, nil, rot)
        love.graphics.pop()
    end
end

-- Cast shadow under a column's base chip. Separate from drawChip on
-- purpose: a chip in flight must not drag a shadow along at its own
-- position, and every flight path calls drawChip directly.
function Chips.drawShadow(x, y, alpha, scale)
    local r = CHIP_RADIUS * (scale or 1)
    love.graphics.setColor(0, 0, 0, (alpha or 1) * SHADOW_ALPHA)
    love.graphics.ellipse("fill", x, y + r * SHADOW_DY, r * SHADOW_RX, r * SHADOW_RY)
end

-- Returns (chips_drawn, min_scale, max_scale) since the last call, and
-- resets. Called once a frame by the dev HUD.
function Chips.frameStats()
    local n, lo, hi = _n_chips, _scale_min, _scale_max
    _n_chips, _scale_min, _scale_max = 0, math.huge, 0
    return n, (lo == math.huge) and 0 or lo, hi
end

-- The spot angle for one slot in a pile.
--
-- Keyed on the SLOT (which column, which row, which denomination), not on
-- the chip that happens to be sitting in it. Every chip in a column is the
-- same denomination, so without this a column is the same rim pattern
-- repeated six times, which reads as a machine-milled cylinder rather than
-- six chips somebody stacked. Keying on the slot also means the pattern
-- holds still while a pile grows, instead of every chip re-rolling
-- whenever one is added.
--
-- Deliberately arithmetic, not bitwise: this runs under LuaJIT (5.1),
-- which has no `~` operator.
function Chips.slotRotation(denom_idx, col, row)
    local h = (denom_idx * 127 + col * 311 + row * 1543) % 997
    return (h / 997) * 2 * math.pi
end

-- How much a chip dims for each chip stacked on top of it.
function Chips.shadeFor(depth)
    return math.max(SHADE_FLOOR, 1 - SHADE_PER_DEPTH * (depth or 0))
end

-- A single generic "chip glyph" for UI use (the Gold Chip currency icon,
-- badges) — independent of the denomination palette. Centered at (x, y)
-- with radius r, in the theme-invariant currency colors.
-- views/Icons.drawChip is the seam that swaps in sprite art when it lands;
-- until then this is what makes the currency read as an icon.
-- `shade` (default 1) multiplies the chip colors toward black, so an
-- unearned/locked badge can be drawn properly dark rather than just faded.
-- `colors` (optional) { body, ring } overrides the currency palette, so
-- the anti-chip is this same glyph in another color rather than a second
-- implementation of it.
function Chips.drawGlyph(x, y, r, alpha, shade, colors)
    alpha = alpha or 1
    shade = shade or 1
    local chip = (colors and colors[1]) or Theme.currency.chip
    local ring = (colors and colors[2]) or Theme.currency.chip_ring

    mul(_body, chip, shade)
    mul(_out,  ring, shade * 0.75)
    mul(_rim,  ring, shade)
    mul(_ring, chip, shade * 0.55)
    mixWhite(_inlay, _body, 0.35)

    Theme.setColor(_out, alpha)
    love.graphics.circle("fill", x, y, r)
    Theme.setColor(_rim, alpha)
    love.graphics.circle("fill", x, y, r * R_RIM)

    -- Detail only where it still resolves. Below this the glyph is a
    -- handful of pixels and anatomy is noise.
    local detailed = (r >= MIN_DETAIL_R)

    if detailed then
        Theme.setColor(_inlay, alpha * 0.9)
        local n    = 6
        local step = (2 * math.pi) / n
        local half = step * SPOT_FILL * 0.5
        for i = 0, n - 1 do
            local a = (math.pi / n) + i * step
            love.graphics.arc("fill", "pie", x, y, r * R_RIM, a - half, a + half)
        end
    end

    Theme.setColor(_body, alpha)
    love.graphics.circle("fill", x, y, r * R_FACE)

    if detailed then
        -- Explicit width: this ring used to inherit whatever line width the
        -- last unrelated caller happened to leave set.
        love.graphics.setLineWidth(1)
        Theme.setColor(_ring, alpha)
        love.graphics.circle("line", x, y, math.max(1, r * 0.42))
        love.graphics.setColor(1, 1, 1, alpha * 0.18)
        love.graphics.setLineWidth(math.max(1, r * 0.14))
        love.graphics.arc("line", "open", x, y, r * R_LIGHT, math.pi, math.pi * 1.75)
        love.graphics.setLineWidth(1)
    end
end

-- Draw a tight vertical stack of `count` chips (radius r) in `color`,
-- bottom chip centered at (cx, baseline_y), each higher chip offset up by
-- ~0.55r. A compact "more chips = bigger tier" glyph for the outcome-tier
-- indicators in tooltips. Drawn back-to-front so lower chips sit in front.
function Chips.drawGlyphStack(cx, baseline_y, count, r, color, alpha)
    alpha = alpha or 1
    color = color or Theme.currency.chip
    mul(_glyph_ring, color, 0.55)
    _glyph_colors[1], _glyph_colors[2] = color, _glyph_ring
    local step = math.max(1, math.floor(r * 0.55))
    for i = math.max(1, count), 1, -1 do
        local cy = baseline_y - (i - 1) * step
        Chips.drawGlyph(cx, cy, r, alpha, 1, _glyph_colors)
    end
end

-- Build deferred-render closures for a chip-index list. Each closure
-- captures its denomination and renders one chip at the (x, y) the
-- caller (e.g. FlightSystem) hands back at draw time.
--
-- Lives here, not in the controller, so the controller never has to
-- name a draw function; it just hands the resulting closure list to
-- FlightSystem.emitBurst. Keeps the view layer the only producer of
-- render callbacks.
-- These may be handed to services/Tumble, so they take its `squash` and
-- flip to the edge-on chip the same way views/ChipFlight does. Only the
-- violent presets ever get low enough to trigger it; a gentle toss never
-- turns far enough to show its rim.
function Chips.makeRenderFns(chip_indices, tint)
    local fns = {}
    if not chip_indices then return fns end
    for i, idx in ipairs(chip_indices) do
        fns[i] = function(x, y, _t, squash)
            if squash and squash < EDGE_SQUASH then
                Chips.drawChipEdge(x, y, idx, 1, tint)
            else
                Chips.drawChip(x, y, idx, 1, true, tint)
            end
        end
    end
    return fns
end

-- Approximate footprint of a stack render, for layout hit-testing if
-- ever needed. Returns (width, height) in px.
function Chips.stackFootprint(chip_indices)
    if not chip_indices or #chip_indices == 0 then return 0, 0 end
    -- Quick group-count to get column count.
    local seen, groups = {}, 0
    local counts = {}
    for _, idx in ipairs(chip_indices) do
        if not seen[idx] then
            seen[idx] = true
            groups = groups + 1
        end
        counts[idx] = (counts[idx] or 0) + 1
    end
    local cols = 0
    for _, n in pairs(counts) do
        cols = cols + math.ceil(n / MAX_PER_COLUMN)
    end
    local w = cols * CHIP_DIAMETER + math.max(0, cols - 1) * COL_GAP
    local h = CHIP_DIAMETER + math.max(0, MAX_PER_COLUMN - 1) * (-STACK_OFFSET_Y)
    return w, h
end

-- ── Stack LAYOUT — where every chip in a pile sits ───────────────────
-- Returns an array of { x, y, idx, with_label, src, depth, shade,
-- col_base, row, rot } in draw order — BACK ROW FIRST, so a caller that
-- simply walks the list paints every chip over whatever sits behind it, one entry per chip that would be rendered by
-- drawStack for the same arguments. `src` is the chip's index in the
-- INPUT list — the layout groups by denomination and can clip the tail,
-- so draw order is not input order and a caller that tracks individual
-- chips (views/ChipPile) needs the mapping back. Chips dropped by the
-- max_w clip simply have no placement, so a `src` can be absent.
--
-- `row` is which staggered row the chip's column landed on: 0 is the front
-- row, higher numbers sit further back and higher up. See the width-budget
-- note below for why rows exist at all.
--
-- `depth` is how many chips sit ON TOP of this one in its column, which
-- is both what dims it and what says only its crescent is visible.
-- `col_base` marks the bottom chip of each column — where a shadow goes.
--
-- Split out from drawStack so a pile and anything that needs to act on
-- its INDIVIDUAL chips (the pot detonating out of its own pile, see
-- views/ChipFlight.explodeStack) agree on position exactly. Two
-- implementations would drift the moment the clipping rules change, and
-- the explosion would visibly start somewhere the pile wasn't.
--
-- `options.max_cols` / `options.max_rows` bound the pile in COLUMNS, and
-- the caller owns them: only it knows what its pile would collide with.
-- Columns past a row's width wrap onto the next row back, rows alternating
-- wide/narrow (3, 2, 3) with the narrow ones staggered half a pitch into
-- the gaps in front of them. Only when every row is full does the pile
-- fall back to dropping columns, still from the smallest-denomination tail.
--
-- Default align = "center" (pile centered on x). y is the BOTTOM of
-- each column in the FRONT row (chips stack upward via STACK_OFFSET_Y;
-- rows behind it step up by a further fraction of the radius).
--
-- Groups chips by denomination in their first-appearance order. A
-- showcase chip (when present) renders as its own group at the front,
-- so it visually sits on its own short column at the left end.
function Chips.stackLayout(x, y, chip_indices, options)
    local placed = {}
    if not chip_indices or #chip_indices == 0 then return placed end
    options = options or {}
    local align = options.align or "center"
    local max_w = options.max_w                      -- nil = unbounded width
    -- How wide and how deep this pile may get, in COLUMNS. The caller sets
    -- these; a pile has no idea what is drawn around it.
    local max_cols = math.max(1, options.max_cols or DEFAULT_MAX_COLS)
    local max_rows = math.max(1, options.max_rows or DEFAULT_MAX_ROWS)

    -- Group by denomination, then order the groups by DENOMINATION —
    -- biggest chips on the left, always.
    --
    -- This used to follow first-appearance order, which meant the pile's
    -- column order was really the order chips happened to arrive in. Every
    -- bet, win, or reconcile reshuffled that list, so a pile worth almost
    -- the same thing rearranged itself completely from one moment to the
    -- next: the $5 stack was on the left, then on the right, then behind.
    -- Sorting makes the arrangement a function of WHAT the pile holds
    -- rather than the history of how it got there, so a pile only moves
    -- when its contents actually change.
    --
    -- data/chips.lua orders the ladder smallest to largest, so a higher
    -- index is a bigger chip; sorting on the index keeps the denominations
    -- opaque here.
    local groups, group_for = {}, {}
    for i, idx in ipairs(chip_indices) do
        local g = group_for[idx]
        if not g then
            groups[#groups + 1] = { idx = idx, count = 1, src = { i } }
            group_for[idx]      = #groups
        else
            local gr = groups[g]
            gr.count = gr.count + 1
            gr.src[#gr.src + 1] = i
        end
    end
    table.sort(groups, function(a, b) return a.idx > b.idx end)

    -- Flatten the groups into COLUMNS. Each group breaks into vertical
    -- columns of MAX_PER_COLUMN chips; a column is the unit that gets
    -- placed, wrapped onto another row, or (last resort) dropped.
    local columns = {}
    for _, g in ipairs(groups) do
        local taken = 0
        local cols  = math.ceil(g.count / MAX_PER_COLUMN)
        for c = 1, cols do
            local in_col = math.min(MAX_PER_COLUMN, g.count - (c - 1) * MAX_PER_COLUMN)
            local col = { idx = g.idx, n = in_col, src = {} }
            for i = 1, in_col do
                taken = taken + 1
                col.src[i] = g.src[taken]
            end
            columns[#columns + 1] = col
        end
    end

    local pitch = CHIP_DIAMETER + COL_GAP
    local function widthFor(n) return n * CHIP_DIAMETER + math.max(0, n - 1) * COL_GAP end

    -- ── Fitting the width budget ───────────────────────────────────────
    -- A pile used to answer "too wide" by deleting columns, which is how a
    -- $1.96 stack ended up drawn as a single 25c chip: the number said one
    -- thing and the chips said another.
    --
    -- Instead it folds. Extra columns go onto rows STAGGERED half a pitch
    -- behind, the way chips actually sit on a table:
    --
    --     x x x
    --      x x
    --
    -- The back rows are partly hidden behind the front ones, which costs
    -- nothing — a pile is read by its bulk, and every chip is still there.
    -- Only when even MAX_ROWS rows can't hold them does it fall back to
    -- dropping columns, and it still drops from the smallest-denomination
    -- tail so the fat high-value stack always survives.
    -- Widest a row may be: the caller's column cap, tightened further if
    -- the pixel budget is even smaller than that.
    local base_cols = max_cols
    if max_w and max_w > 0 then
        base_cols = math.min(base_cols,
                             math.max(1, math.floor((max_w + COL_GAP) / pitch)))
    end

    -- Rows alternate wide/narrow — 3, 2, 3 — and the narrow ones are
    -- staggered half a pitch so they sit in the gaps of the row in front.
    -- That is how chips actually end up on a table, and it packs a pile
    -- into far less width than one long line.
    local function colsInRow(r)
        if r % 2 == 1 and base_cols > 1 then return base_cols - 1 end
        return base_cols
    end

    local capacity = 0
    for r = 0, max_rows - 1 do capacity = capacity + colsInRow(r) end
    while #columns > capacity do columns[#columns] = nil end
    if #columns == 0 then return placed end

    -- Row 0 is the FRONT row and carries the largest denominations, since
    -- the breakdown hands them over first and the front row is the one
    -- nothing overlaps.
    local row_of, in_row = {}, {}
    do
        local r, left = 0, colsInRow(0)
        for i = 1, #columns do
            while left == 0 do r = r + 1; left = colsInRow(r) end
            row_of[i] = r
            in_row[r] = (in_row[r] or 0) + 1
            left = left - 1
        end
    end
    local n_rows = 0
    for r in pairs(in_row) do n_rows = math.max(n_rows, r + 1) end

    local lift = math.max(2, math.floor(CHIP_RADIUS * ROW_LIFT))

    -- Emit BACK row first so a simple sequential draw layers correctly:
    -- every chip is painted over whatever sits behind it.
    for r = n_rows - 1, 0, -1 do
        local count   = in_row[r] or 0
        if count > 0 then
            local row_w  = widthFor(count)
            -- Odd rows step half a pitch across, so a back column peeks out
            -- between the two in front of it instead of hiding exactly
            -- behind one.
            local stagger = (r % 2 == 1) and math.floor(pitch * 0.5) or 0
            local origin_x
            if align == "left" then
                origin_x = x + stagger
            elseif align == "right" then
                origin_x = x - row_w + stagger
            else
                origin_x = x - row_w / 2 + stagger
            end

            local cx = origin_x + CHIP_RADIUS
            local ry = y - r * lift
            for i = 1, #columns do
                if row_of[i] == r then
                    local col = columns[i]
                    for k = 1, col.n do
                        local depth = col.n - k
                        placed[#placed + 1] = {
                            x          = cx,
                            y          = ry + (k - 1) * STACK_OFFSET_Y,
                            idx        = col.idx,
                            with_label = (k == col.n),
                            src        = col.src[k],
                            depth      = depth,
                            shade      = Chips.shadeFor(depth),
                            col_base   = (k == 1),
                            row        = r,
                            rot        = Chips.slotRotation(col.idx, i, k),
                        }
                    end
                    cx = cx + pitch
                end
            end
        end
    end
    return placed
end

-- ── Stack render ─────────────────────────────────────────────────────
-- Draws what stackLayout places. Kept as a separate entry point so every
-- existing caller is unaffected by the layout extraction.
--
-- Two passes, and it has to be: a cast shadow is wider than the chip it
-- belongs to and columns sit a couple of pixels apart, so interleaving
-- would drop one column's shadow on top of its neighbour's chips.
function Chips.drawStack(x, y, chip_indices, options)
    options = options or {}
    local tint   = options.tint
    local placed = Chips.stackLayout(x, y, chip_indices, options)
    for _, p in ipairs(placed) do
        if p.col_base then Chips.drawShadow(p.x, p.y, 1, 1) end
    end
    for _, p in ipairs(placed) do
        Chips.drawChip(p.x, p.y, p.idx, 1, p.with_label, tint, p.shade,
                       p.depth, 1, p.rot)
    end
end

return Chips
