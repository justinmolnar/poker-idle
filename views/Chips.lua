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
--
-- ─── The atlas ──────────────────────────────────────────────────────
-- Every chip on screen is textured quads out of ONE canvas, built once
-- (see "The chip atlas" below), and a pile is one SpriteBatch that is
-- rebuilt only when the pile changes. The vector painters are still here:
-- they are what paints the atlas, and they are what draws when
-- Constants.FEATURES.CHIP_ATLAS is off or canvases are unavailable.

local ChipData    = require("data.chips")
local Constants   = require("data.constants")
local Theme       = require("views.Theme")
local FontService = require("services.FontService")
local Perf        = require("services.Perf")
local Tumble      = require("services.Tumble")

local Chips = {}

-- LuaJIT has math.atan2; Lua 5.4 (the headless sims) folds it into atan.
local atan2 = math.atan2 or math.atan

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
-- throwing chips away. See stackLayoutInto.
-- Fallbacks only. Callers say how wide their pile may get, because only
-- they know what it would run into — the pot pile has community cards
-- above it, the player's pile has hole cards beside it, the bankroll band
-- has the whole width of the screen. See `max_cols` in stackLayoutInto.
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

-- ── The atlas tiers ─────────────────────────────────────────────────
-- Every chip is drawn out of a bake at one of these radii (fractions of
-- CHIP_RADIUS), scaled DOWN to its real size with linear filtering. Four
-- fixed sizes rather than one: a 44px bake shrunk to 12px with no mipmaps
-- aliases into a shimmer, and a chip pulled from a bake at most ~1.3x its
-- own size stays sharp. Never scaled up except by a flight's loft, which
-- the single bake was scaled up by as well.
local TIERS        = { 1.00, 0.78, 0.61, 0.47 }
local N_TIERS      = #TIERS
-- Spots below ~1.5px wide are an arc apiece for nothing, so the smallest
-- tier bakes with the cap the vector path applied under 10px.
local SPOT_CAP_TIER, SPOT_CAP = 4, 6
-- A buried chip's crescent is one sprite, and its edge spots are one of
-- this many phases of the slot rotation rather than the exact angle. At a
-- sliver a few pixels tall the difference between neighbouring phases is
-- under a pixel; the difference between two slivers with the SAME phase is
-- what would read as a milled cylinder, and three keep that broken.
local WALL_PHASES  = 3
-- The generic currency glyph's bake radii, at 1x. A glyph draws from the
-- smallest bake at least its own size, so its 1px ring and light arc are
-- never shrunk by more than half; the title screen's big glyphs come off
-- the largest.
local GLYPH_RADII  = { 12, 24, 48 }
local ATLAS_W      = 1024
local ATLAS_GUTTER = 2

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
local EMPTY         = {}

-- ── Atlas state ─────────────────────────────────────────────────────
-- Declared here because setScale and configureFont, defined above the
-- builder, have to be able to drop it. See "The chip atlas" below.
local _atlas        = nil    -- the one canvas (linear filter)
local _cells        = nil    -- kind -> cells, nil until built
local _atlas_gen    = 0      -- bumps on every drop; batches key on it
local _atlas_fail   = -1     -- the gen whose build failed (no retry until the next drop)
local _atlas_bytes  = 0
local _atlas_w, _atlas_h = 0, 0
local _label_w      = {}     -- denom_idx -> label width, from ensureFit
local _glyph_baked  = { 0, 0, 0, 0, 0, 0 }   -- the currency colours the glyph cells hold

-- A resize changes the chip radius and re-rasterizes the label font, so
-- every cell is stale. The canvas goes with the generation; every batch
-- built on it re-adds when it sees the new number.
local function invalidateAtlas()
    _atlas_gen = _atlas_gen + 1
    if _atlas and _atlas.release then _atlas:release() end
    _atlas, _cells = nil, nil
    _atlas_bytes = 0
end

-- ── Frame counters (dev HUD) ────────────────────────────────────────
-- Chip piles are the highest-count repeated element in the game and
-- nothing else in the codebase measures draw volume, so the renderer
-- counts itself. `scale_min` is the one that matters most: it says how
-- small chips actually get on a full grid, which decides whether any of
-- this anatomy resolves down there at all.
local _n_chips   = 0
local _scale_min = math.huge
local _scale_max = 0

local function noteScale(es)
    if es < _scale_min then _scale_min = es end
    if es > _scale_max then _scale_max = es end
end

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
    invalidateAtlas()
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
    invalidateAtlas()
end

-- Current scaled chip radius. A pile's base chip is CENTERED on the `y` passed
-- to drawStack, so callers that want the pile's visual BOTTOM at a baseline
-- pass `baseline - Chips.radius()`.
function Chips.radius() return CHIP_RADIUS end

-- The vertical step between chips in a column (negative: up), and how many
-- a column holds. Exposed so views/ChipPile can grow a column by one chip
-- without re-solving the pile.
function Chips.stackStep() return STACK_OFFSET_Y end
Chips.MAX_PER_COLUMN = MAX_PER_COLUMN

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
    -- Each label's width is kept: the atlas path asks whether a label fits
    -- once per chip and a font measure there would be a string walk each.
    local widest = 0
    for i, d in ipairs(ChipData.denominations) do
        local w = (d.label and _font:getWidth(d.label)) or 0
        _label_w[i] = w
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
-- overstate the room. `es` is the chip's real on-screen scale.
local function labelFits(denom_idx, es)
    local fw = _label_w[denom_idx]
    if not fw then return false end
    if fw * 0.5 + LABEL_PAD > _band_chord * es then return false end
    local ink_h = _font:getHeight() * INK_OF_LINE
    if ink_h * 0.5 + LABEL_PAD > _band_hh * es then return false end
    return true
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
-- The denomination plate and its label, on the vector path.
--
-- Module level rather than a closure over paintChip's locals, because it
-- must not rotate with the rim, and its label is printed at 1/escale so it
-- lands unscaled whatever size the chip is.
--
-- One decision, not two. The plate exists to carry the number; drawn
-- without it you get a blank white bar stamped across the chip, which is
-- worse than no plate at all. So the fit is worked out first and either
-- both are drawn or neither is.
local function paintStamp(spec, alpha, band_hw, escale, denom_idx)
    if not (band_hw and _font and spec.label) then return end
    if #_plate_fill == 0 then return end
    if not labelFits(denom_idx, escale or 1) then return end

    local es = escale or 1
    local fw = _label_w[denom_idx]
    local fh = _font:getHeight()

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

-- Which part of the anatomy paintChip is baking into a cell, or nil for
-- the ordinary whole-chip vector path:
--   "rim"  — outline + rim + spots, and stop
--   "face" — face + dome + arcs + lip, no outline, no rim, no plate
-- (edge, wall and flat cells are the matching `detail` painted whole.)
local _bake_kind = nil

local function paintChip(r, spec, alpha, detail, band_hw, spot_cap, rot, escale, denom_idx)
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

    if _bake_kind ~= "face" then
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
        if _bake_kind == "rim" then return end
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
    -- Its own function so that bailing out of it doesn't skip the lip
    -- below — every chip at this detail level has a lip, labelled or not.
    if not _bake_kind then paintStamp(spec, alpha, band_hw, escale, denom_idx) end

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

-- The generic currency glyph's anatomy, shared by the vector drawGlyph
-- and the atlas bake. Colours are already in the scratch tables.
local function paintGlyph(x, y, r, alpha, detailed)
    Theme.setColor(_out, alpha)
    love.graphics.circle("fill", x, y, r)
    Theme.setColor(_rim, alpha)
    love.graphics.circle("fill", x, y, r * R_RIM)

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

local function setupGlyphColors(chip, ring, shade)
    mul(_body, chip, shade)
    mul(_out,  ring, shade * 0.75)
    mul(_rim,  ring, shade)
    mul(_ring, chip, shade * 0.55)
    mixWhite(_inlay, _body, 0.35)
end

-- ─── The chip atlas ────────────────────────────────────────────────────
-- A full-detail chip is about twenty immediate-mode primitives — outline,
-- rim, eight pie arcs, face, five dome discs, two line arcs, plate, ring —
-- and none of them batch. A full board plus the bankroll pile puts
-- thousands of those in a frame.
--
-- It used to be baked into two canvases per (denomination, tint, shade,
-- spot cap), allocated inside the draw and never dropped: a settling pile
-- passes an interpolated shade every frame, so every settle frame baked
-- new canvas pairs mid-frame, and texture memory doubled over minutes.
--
-- Now everything is painted ONCE into a single canvas, keyed on nothing
-- that changes at draw time. Tint and shade are per-sprite colour
-- multiplies: exact for the outline, rim, spots, wall, face body and the
-- plate (the plate is a white cell tinted with the exact inlay colour),
-- approximate only for the face's two fixed highlight arcs, which are
-- constant white and black in the vector painter and now dim with the
-- chip. Per denomination and tier:
--
--   rim   — outline + rim + spots. Rotated at draw by the slot angle,
--           which is exact: all three are radially symmetric.
--   face  — face + dome + the light and shadow arcs + the lip. Never
--           rotated, because the light comes from a fixed direction.
--   edge  — the edge-on chip of a tumble (tiers 1 and 3 only).
--   wall  — the buried crescent, at WALL_PHASES spot phases, stored
--           half-height because that is all of it there is.
--   flat  — silhouette + rim + face at the smallest tier, for chips
--           below MIN_DETAIL_R.
--   label — the denomination, printed once at native size.
--
-- Shared: the plate and its bezel per tier (white, tinted per sprite),
-- the column shadow, and the currency glyph at GLYPH_RADII in both detail
-- levels.
--
-- The label cell is the one thing drawn 1:1. The atlas is linear-filtered
-- because the chip cells are shrunk, and a 1:1 texel-to-pixel sprite
-- samples exact texels through a linear filter ONLY when its origin lands
-- on a whole screen pixel — half a pixel off and every stem of the pixel
-- font smears across two. So the label sprite's position is snapped to a
-- whole screen pixel when it is added (see composeChip and batchOrigin),
-- which is what a nearest-filtered font under love.graphics.print did.
--
-- Everything composites premultiplied: a canvas painted under ordinary
-- alpha blending holds premultiplied texels, so each draw is wrapped in
-- setBlendMode("alpha", "premultiplied") with the colour scaled by alpha
-- in all four channels — (1, 1, 1, a) would dim the coverage and leave the
-- colour at full strength, and a half-faded chip came out brighter than a
-- solid one.

local function halfFor(r)
    -- The light arcs stroke at r*0.14 centred on r*R_LIGHT, so their ink
    -- reaches a little past the outline.
    return math.ceil(r + math.max(2, r * 0.14)) + 1
end

local function tierRadius(t) return CHIP_RADIUS * TIERS[t] end

-- Effective spot count a cell of this tier bakes for a denomination.
local function spotsAt(spec, tier)
    local n = spec.spots or 6
    if tier == SPOT_CAP_TIER and n > SPOT_CAP then n = SPOT_CAP end
    return n
end

-- The slot rotation a wall phase was baked at: the middle of its bucket
-- of the spot period.
local function wallPhaseRot(spec, tier, p)
    local step = (2 * math.pi) / spotsAt(spec, tier)
    return (p - 0.5) / WALL_PHASES * step
end

-- Which wall phase a slot rotation falls in.
local function wallPhaseOf(spec, tier, rot)
    local step = (2 * math.pi) / spotsAt(spec, tier)
    local u = (rot % step) / step
    local p = math.floor(u * WALL_PHASES) + 1
    if p > WALL_PHASES then p = WALL_PHASES end
    return p
end

-- Shelf packing: rows of cells left to right, a new row when one does not
-- fit, cells sorted tallest first so a row is as full as its height allows.
-- Returns the height used. Every cell gets `x`, `y`.
local function shelfPack(items, W)
    table.sort(items, function(a, b)
        if a.h ~= b.h then return a.h > b.h end
        return a.i < b.i
    end)
    local x, y, row_h = ATLAS_GUTTER, ATLAS_GUTTER, 0
    for _, it in ipairs(items) do
        if x + it.w + ATLAS_GUTTER > W then
            x = ATLAS_GUTTER
            y = y + row_h + ATLAS_GUTTER
            row_h = 0
        end
        it.x, it.y = x, y
        x = x + it.w + ATLAS_GUTTER
        if it.h > row_h then row_h = it.h end
    end
    return y + row_h + ATLAS_GUTTER
end

local function textureLimit()
    local lim
    if love.graphics.getSystemLimits then
        local ok, l = pcall(love.graphics.getSystemLimits)
        if ok and type(l) == "table" then lim = l.texturesize end
    end
    return lim or 4096
end

-- Paint one cell at the origin (already translated to its paint origin).
local function paintCell(it)
    local kind = it.kind
    if kind == "rim" or kind == "face" or kind == "edge" or kind == "flat" or kind == "wall" then
        local spec = ChipData.denominations[it.d]
        setupColors(spec, nil, 1)
        local r        = tierRadius(it.t)
        local spot_cap = (it.t == SPOT_CAP_TIER) and SPOT_CAP or nil
        local detail, rot = "full", 0
        if kind == "edge" then detail = "edge"
        elseif kind == "flat" then detail = "flat"
        elseif kind == "wall" then detail = "buried"; rot = wallPhaseRot(spec, it.t, it.p) end
        _bake_kind = kind
        -- alpha 1 and an unrotated rim: the sprite's colour carries the
        -- caller's alpha, and the rim is rotated when it is drawn.
        paintChip(r, spec, 1, detail, nil, spot_cap, rot, 1, it.d)
        _bake_kind = nil
    elseif kind == "label" then
        local spec = ChipData.denominations[it.d]
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setFont(_font)
        love.graphics.print(spec.label, 0, 0)
    elseif kind == "plate_fill" or kind == "plate_bezel" then
        local pts = buildPlate(_band_hw * TIERS[it.t], _band_hh * TIERS[it.t])
        love.graphics.setColor(1, 1, 1, 1)
        if kind == "plate_fill" then
            love.graphics.polygon("fill", pts)
        else
            love.graphics.setLineWidth(1)
            love.graphics.polygon("line", pts)
        end
    elseif kind == "shadow" then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.ellipse("fill", 0, 0, CHIP_RADIUS * SHADOW_RX, CHIP_RADIUS * SHADOW_RY)
    elseif kind == "glyph" or kind == "glyph_flat" then
        setupGlyphColors(Theme.currency.chip, Theme.currency.chip_ring, 1)
        paintGlyph(0, 0, it.r, 1, kind == "glyph")
    end
end

local function renderSheet(canvas, items)
    local prev = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setCanvas(canvas)
    love.graphics.setScissor()
    love.graphics.clear(0, 0, 0, 0)
    local prev_font = love.graphics.getFont()
    for _, it in ipairs(items) do
        -- Scissored to the cell: a wall's spot sliver can dip a pixel over
        -- the crescent's chord, and the gutter is the neighbour's, not ours.
        love.graphics.setScissor(it.x, it.y, it.w, it.h)
        love.graphics.push()
        love.graphics.translate(it.x + it.px, it.y + it.py)
        paintCell(it)
        love.graphics.pop()
    end
    love.graphics.setScissor()
    if prev_font then love.graphics.setFont(prev_font) end
    love.graphics.setCanvas(prev)
    love.graphics.pop()
end

-- Pack, allocate and paint the sheet. Returns true on success. nil from
-- newCanvas (headless, or a GPU that will not give us one) means the
-- vector path draws instead.
local function buildAtlas()
    ensureFit()
    local items = {}
    -- w, h: the cell; px, py: where the painter's origin sits in it;
    -- ox, oy: the sprite origin handed to draw, so a sprite at (x, y) puts
    -- the chip's centre (or the label's print origin) there.
    local function cell(kind, d, t, p, w, h, px, py, ox, oy)
        local it = { i = #items + 1, kind = kind, d = d, t = t, p = p, w = w, h = h,
                     px = px, py = py, ox = ox, oy = oy }
        items[#items + 1] = it
        return it
    end

    for d, spec in ipairs(ChipData.denominations) do
        for t = 1, N_TIERS do
            local half = halfFor(tierRadius(t))
            local full = 2 * half
            cell("rim",  d, t, nil, full, full, half, half, half, half)
            cell("face", d, t, nil, full, full, half, half, half, half)
            if t == 1 or t == 3 then
                cell("edge", d, t, nil, full, full, half, half, half, half)
            end
            for p = 1, WALL_PHASES do
                cell("wall", d, t, p, full, half, half, 0, half, 0)
            end
        end
        local h4 = halfFor(tierRadius(N_TIERS))
        cell("flat", d, N_TIERS, nil, 2 * h4, 2 * h4, h4, h4, h4, h4)
        if _font and spec.label then
            -- Two pixels of margin on every side for glyphs that overhang
            -- their advance. The draw origin puts the cell where print put
            -- the text: at floor(-fw/2), floor(-fh/2) from the chip's centre.
            local fw, fh = _label_w[d], _font:getHeight()
            cell("label", d, nil, nil, fw + 4, fh + 4, 2, 2,
                 2 - math.floor(-fw * 0.5), 2 - math.floor(-fh * 0.5))
        end
    end
    if _font and #_plate_fill > 0 then
        for t = 1, N_TIERS do
            local hw, hh = _band_hw * TIERS[t], _band_hh * TIERS[t]
            local w, h = 2 * math.ceil(hw) + 4, 2 * math.ceil(hh) + 4
            local cx, cy = w * 0.5, h * 0.5
            cell("plate_fill",  nil, t, nil, w, h, cx, cy, cx, cy)
            cell("plate_bezel", nil, t, nil, w, h, cx, cy, cx, cy)
        end
    end
    do
        local rx, ry = CHIP_RADIUS * SHADOW_RX, CHIP_RADIUS * SHADOW_RY
        local w, h = 2 * math.ceil(rx) + 4, 2 * math.ceil(ry) + 4
        -- Drawn at the chip's centre, the ellipse lands SHADOW_DY below it.
        cell("shadow", nil, nil, nil, w, h, w * 0.5, h * 0.5,
             w * 0.5, h * 0.5 - CHIP_RADIUS * SHADOW_DY)
    end
    for gi, gr0 in ipairs(GLYPH_RADII) do
        local gr = gr0 * CHIP_RADIUS / CHIP_RADIUS_BASE
        local gh = halfFor(gr)
        local g = cell("glyph",      nil, gi, nil, 2 * gh, 2 * gh, gh, gh, gh, gh)
        local f = cell("glyph_flat", nil, gi, nil, 2 * gh, 2 * gh, gh, gh, gh, gh)
        g.r, f.r = gr, gr
    end

    -- Width first, then height: the atlas is a 1024-wide strip as tall as
    -- the packing needs, rounded to 64. Only if that outgrows the GPU's
    -- texture size does it widen.
    local limit = textureLimit()
    local W = ATLAS_W
    local H
    while true do
        H = math.ceil(shelfPack(items, W) / 64) * 64
        if H <= limit or W >= limit then break end
        W = W * 2
    end
    if H > limit then return false end

    local ok, atlas = pcall(love.graphics.newCanvas, W, H)
    if not ok or not atlas then return false end
    atlas:setFilter("linear", "linear")

    renderSheet(atlas, items)
    for _, it in ipairs(items) do
        it.q = love.graphics.newQuad(it.x, it.y, it.w, it.h, W, H)
    end

    local cells = { rim = {}, face = {}, edge = {}, wall = {}, flat = {}, label = {},
                    plate_fill = {}, plate_bezel = {}, glyph = {}, glyph_flat = {} }
    for _, it in ipairs(items) do
        local k = it.kind
        if k == "rim" or k == "face" or k == "edge" then
            cells[k][it.d] = cells[k][it.d] or {}
            cells[k][it.d][it.t] = it
        elseif k == "wall" then
            cells.wall[it.d] = cells.wall[it.d] or {}
            cells.wall[it.d][it.t] = cells.wall[it.d][it.t] or {}
            cells.wall[it.d][it.t][it.p] = it
        elseif k == "flat" or k == "label" then
            cells[k][it.d] = it
        elseif k == "plate_fill" or k == "plate_bezel" or k == "glyph" or k == "glyph_flat" then
            cells[k][it.t] = it
        else
            cells[k] = it
        end
    end

    local cc, cr = Theme.currency.chip, Theme.currency.chip_ring
    _glyph_baked[1], _glyph_baked[2], _glyph_baked[3] = cc[1], cc[2], cc[3]
    _glyph_baked[4], _glyph_baked[5], _glyph_baked[6] = cr[1], cr[2], cr[3]

    _atlas, _cells = atlas, cells
    _atlas_w, _atlas_h = W, H
    _atlas_bytes = W * H * 4
    Perf.gauge("atlas_mb", _atlas_bytes / 1048576)
    return true
end

-- The atlas, built on first use. false means draw the vector way: the
-- feature flag is off, or canvases are unavailable and this generation
-- has already failed (a resize or font change is what earns a retry).
local function ensureAtlas()
    -- The flag is read every time, not only at build: flipping it off with
    -- an atlas already built has to restore the vector path at once.
    if not Constants.FEATURES.CHIP_ATLAS then return false end
    if _cells then return true end
    if _atlas_fail == _atlas_gen then return false end
    if not (love.graphics and love.graphics.newCanvas and love.graphics.newQuad) then
        _atlas_fail = _atlas_gen
        return false
    end
    if not buildAtlas() then
        _atlas_fail = _atlas_gen
        return false
    end
    return true
end

function Chips.atlasGen() return _atlas_gen end

-- pages, w, h, bytes. One page always: a SpriteBatch takes one texture, so
-- the whole ladder has to share it.
function Chips.atlasInfo()
    return _cells and 1 or 0, _atlas_w, _atlas_h, _atlas_bytes
end

-- The tier a chip at on-screen scale `es` (relative to CHIP_RADIUS) draws
-- from — the smallest bake that is still at least as big as the chip — and
-- the residual scale from that bake down to the chip.
function Chips.tierFor(es)
    for t = N_TIERS, 1, -1 do
        if es <= TIERS[t] then return t, es / TIERS[t] end
    end
    return 1, es
end
Chips.TIERS = TIERS

-- ── Sprite sinks ────────────────────────────────────────────────────
-- The chip composer below writes sprites to a SINK: either a batch (a
-- SpriteBatch on the atlas, lazily sized) or the immediate drawer, which
-- is the same calls straight to love.graphics.draw. One composer, two
-- outputs, so a chip in a pile and a chip drawn by hand cannot drift.
local Batch = {}
Batch.__index = Batch

function Batch:color(r, g, b, a) self.sb:setColor(r, g, b, a) end

function Batch:add(cell, x, y, r, sx, sy, kx)
    local n = self.n
    if n >= self.cap then
        self.cap = self.cap * 2
        self.sb:setBufferSize(self.cap)
    end
    self.n = n + 1
    self.sb:add(cell.q, x, y, r, sx, sy, cell.ox, cell.oy, kx or 0, 0)
end

-- Immediate: what drawChip and the icons use. Blend mode is the caller's.
-- No snapping frame: the caller's transform is unknown here.
local Immediate = { n = 0, chips = 0, snap = false }
function Immediate:color(r, g, b, a) love.graphics.setColor(r, g, b, a) end
function Immediate:add(cell, x, y, r, sx, sy, kx)
    love.graphics.draw(_atlas, cell.q, x, y, r, sx, sy, cell.ox, cell.oy, kx or 0, 0)
end

-- A batch for one pile (or the flight renderer). nil headless or with the
-- atlas off, and the caller draws immediately instead. Its snapping frame
-- (ox, oy, s: where drawBatch will put it) starts at the origin, unscaled.
function Chips.newBatch(capacity)
    if not ensureAtlas() then return nil end
    if not love.graphics.newSpriteBatch then return nil end
    capacity = capacity or 128
    local ok, sb = pcall(love.graphics.newSpriteBatch, _atlas, capacity, "stream")
    if not ok or not sb then return nil end
    return setmetatable({
        sb = sb, cap = capacity, n = 0,
        gen = _atlas_gen, chips = 0,
        es_lo = math.huge, es_hi = 0,
        snap = true, ox = 0, oy = 0, s = 1,
    }, Batch)
end

function Chips.releaseBatch(B)
    if not B then return end
    if B.sb and B.sb.release then B.sb:release() end
    B.sb = nil
end

function Chips.batchClear(B)
    B.sb:clear()
    B.n, B.chips = 0, 0
    B.es_lo, B.es_hi = math.huge, 0
end

-- Where the batch will be drawn (drawBatch's x, y, s), so a label sprite
-- can be snapped to a whole SCREEN pixel while it is added. Set before the
-- adds; a batch is rebuilt when its frame's fractional part moves.
function Chips.batchOrigin(B, ox, oy, s)
    B.ox, B.oy, B.s = ox or 0, oy or 0, s or 1
end

function Chips.batchCount(B) return B.n end

-- Draw a batch at (x, y) under scale s: one texture draw for the pile.
function Chips.drawBatch(B, x, y, s)
    if B.n == 0 then return end
    s = s or 1
    _n_chips = _n_chips + B.chips
    if B.es_lo < _scale_min then _scale_min = B.es_lo end
    if B.es_hi > _scale_max then _scale_max = B.es_hi end

    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(B.sb, x, y, 0, s, s)
    love.graphics.setBlendMode("alpha")
end

-- ── The chip composer ───────────────────────────────────────────────
-- Writes one chip to a sink. Returns the sprite count.
--   es       the chip's real on-screen scale (relative to CHIP_RADIUS):
--            picks the tier and decides whether the label fits
--   local_s  the scale to draw at in the sink's own space; a pile batch
--            drawn under place.scale passes 1, a screen-space flight
--            passes es itself
-- Order: rim (rotated by rot), face, then plate, bezel and the label at
-- local_s/es so it lands 1:1 on screen. depth > 0 is one wall sprite,
-- its phase from rot. Below MIN_DETAIL_R on screen it is the flat cell.
local function composeChip(S, x, y, denom_idx, alpha, with_label, tint, shade, depth, rot, es, local_s)
    local d = ChipData.denominations[denom_idx]
    if not d then return 0 end
    alpha   = alpha or 1
    shade   = shade or 1
    tint    = tint or IDENTITY_TINT
    es      = es or 1
    local_s = local_s or 1
    rot     = rot or 0
    S.chips = S.chips + 1
    local cells = _cells

    -- Premultiplied: the colour scales rgb AND alpha.
    local k = shade * alpha
    local cr, cg, cb = tint[1] * k, tint[2] * k, tint[3] * k

    if depth and depth > 0 then
        local tier = Chips.tierFor(es)
        local cell = cells.wall[denom_idx][tier][wallPhaseOf(d, tier, rot)]
        local sc   = local_s / TIERS[tier]
        S:color(cr, cg, cb, alpha)
        S:add(cell, x, y, 0, sc, sc, 0)
        return 1
    end

    if es * CHIP_RADIUS < MIN_DETAIL_R then
        local cell = cells.flat[denom_idx]
        local sc   = local_s / TIERS[N_TIERS]
        S:color(cr, cg, cb, alpha)
        S:add(cell, x, y, 0, sc, sc, 0)
        return 1
    end

    local tier = Chips.tierFor(es)
    local sc   = local_s / TIERS[tier]
    S:color(cr, cg, cb, alpha)
    S:add(cells.rim[denom_idx][tier],  x, y, rot, sc, sc, 0)
    S:add(cells.face[denom_idx][tier], x, y, 0,   sc, sc, 0)

    -- The label is the ONE thing never scaled with the chip: the plate is
    -- drawn at the chip's scale and the text at exactly 1:1 on screen, or
    -- neither is drawn.
    if with_label then
        local lcell = cells.label[denom_idx]
        local pcell = cells.plate_fill[tier]
        if lcell and pcell and labelFits(denom_idx, es) then
            setupColors(d, tint, shade)
            S:color(_inlay[1] * alpha, _inlay[2] * alpha, _inlay[3] * alpha, alpha)
            S:add(pcell, x, y, 0, sc, sc, 0)
            S:color(_bezel[1] * alpha, _bezel[2] * alpha, _bezel[3] * alpha, alpha)
            S:add(cells.plate_bezel[tier], x, y, 0, sc, sc, 0)
            local ls = local_s / es
            -- Snapped to a whole screen pixel through the sink's frame,
            -- so the 1:1 texels sample exactly (see "The chip atlas").
            local lx, ly = x, y
            if S.snap then
                local bs = S.s
                lx = (math.floor(S.ox + x * bs + 0.5) - S.ox) / bs
                ly = (math.floor(S.oy + y * bs + 0.5) - S.oy) / bs
            end
            S:color(_ink[1] * alpha, _ink[2] * alpha, _ink[3] * alpha, alpha)
            S:add(lcell, lx, ly, 0, ls, ls, 0)
            return 5
        end
    end
    return 2
end

-- ── The tumble transform, as one sprite transform ───────────────────
-- services/Tumble's chain is translate · scale(near) · rotate(axis) ·
-- scale(1, squash) · rotate(spin): a 2x2 matrix with positive determinant.
-- A sprite takes rotation, two scales and a shear, and LÖVE composes them
-- as R · S · K with K = [[1, kx], [ky, 1]] (Matrix4::setTransformation:
-- e0 = c·sx − ky·s·sy, e4 = kx·c·sx − s·sy), so QR by Gram-Schmidt on the
-- FIRST column — Q = R(θ), the triangle [[a, b], [0, d]] — is R · S(a, d)
-- · K(kx = b/a, ky = 0). The parameter names are the classic trap; the
-- smoke test maps points through both forms.
local function tumbleMatrix(axis, squash, spin, near)
    local ca, sa = math.cos(axis), math.sin(axis)
    local cs, ss = math.cos(spin), math.sin(spin)
    local p11, p12 = cs, -ss
    local p21, p22 = squash * ss, squash * cs
    return (ca * p11 - sa * p21) * near, (ca * p12 - sa * p22) * near,
           (sa * p11 + ca * p21) * near, (sa * p12 + ca * p22) * near
end

local function decompose(m11, m12, m21, m22)
    local a  = math.sqrt(m11 * m11 + m21 * m21)
    local th = atan2(m21, m11)
    local u1, u2 = m11 / a, m21 / a
    local b  = m12 * u1 + m22 * u2
    local d  = m22 * u1 - m12 * u2
    return th, a, d, b / a
end
Chips.tumbleMatrix = tumbleMatrix
Chips.decompose    = decompose

-- A chip mid-tumble, in one sprite transform. Below EDGE_SQUASH it is the
-- edge cell; otherwise rim, face and label share the one 2x2. The label
-- is not snapped here: under a turn there is no whole pixel to land on,
-- exactly as love.graphics.print had none inside Tumble's transform.
local function composeChipTumbling(S, x, y, denom_idx, alpha, with_label, tint, es, axis, squash, spin, near)
    local d = ChipData.denominations[denom_idx]
    if not d then return 0 end
    alpha = alpha or 1
    tint  = tint or IDENTITY_TINT
    es    = es or 1
    if squash >= 1 and spin == 0 and near == 1 then
        return composeChip(S, x, y, denom_idx, alpha, with_label, tint, 1, 0, 0, es, es)
    end
    S.chips = S.chips + 1
    local cells = _cells
    local m11, m12, m21, m22 = tumbleMatrix(axis, squash, spin, near)
    local th, a, dd, kx = decompose(m11, m12, m21, m22)
    local cr, cg, cb = tint[1] * alpha, tint[2] * alpha, tint[3] * alpha
    S:color(cr, cg, cb, alpha)

    local tier = Chips.tierFor(es * near)
    if squash < EDGE_SQUASH then
        local et = (tier <= 2) and 1 or 3
        local u  = es / TIERS[et]
        S:add(cells.edge[denom_idx][et], x, y, th, a * u, dd * u, kx)
        return 1
    end
    if es * CHIP_RADIUS < MIN_DETAIL_R then
        local u = es / TIERS[N_TIERS]
        S:add(cells.flat[denom_idx], x, y, th, a * u, dd * u, kx)
        return 1
    end
    local u = es / TIERS[tier]
    S:add(cells.rim[denom_idx][tier],  x, y, th, a * u, dd * u, kx)
    S:add(cells.face[denom_idx][tier], x, y, th, a * u, dd * u, kx)
    if with_label then
        local lcell = cells.label[denom_idx]
        local pcell = cells.plate_fill[tier]
        if lcell and pcell and labelFits(denom_idx, es) then
            setupColors(d, tint, 1)
            S:color(_inlay[1] * alpha, _inlay[2] * alpha, _inlay[3] * alpha, alpha)
            S:add(pcell, x, y, th, a * u, dd * u, kx)
            S:color(_bezel[1] * alpha, _bezel[2] * alpha, _bezel[3] * alpha, alpha)
            S:add(cells.plate_bezel[tier], x, y, th, a * u, dd * u, kx)
            -- The label at 1:1 under the same turn: the chip's own scale
            -- cancels, the tumble stays.
            S:color(_ink[1] * alpha, _ink[2] * alpha, _ink[3] * alpha, alpha)
            S:add(lcell, x, y, th, a, dd, kx)
            return 5
        end
    end
    return 2
end

function Chips.addChip(B, x, y, denom_idx, alpha, with_label, tint, shade, depth, rot, es, local_s)
    es = es or 1
    noteScale(es)
    if es < B.es_lo then B.es_lo = es end
    if es > B.es_hi then B.es_hi = es end
    return composeChip(B, x, y, denom_idx, alpha, with_label, tint, shade, depth, rot, es, local_s)
end

function Chips.addChipTumbling(B, x, y, denom_idx, alpha, with_label, tint, es, axis, squash, spin, near)
    return composeChipTumbling(B, x, y, denom_idx, alpha, with_label, tint, es, axis, squash, spin, near)
end

-- Cast shadow under a column base, into a batch. Black at SHADOW_ALPHA
-- through the premultiplied white ellipse.
function Chips.addShadow(B, x, y, alpha, local_s)
    B:color(0, 0, 0, (alpha or 1) * SHADOW_ALPHA)
    B:add(_cells.shadow, x, y, 0, local_s or 1, local_s or 1, 0)
end

-- ── The flight renderer ─────────────────────────────────────────────
-- services/FlightSystem hands chip records here at draw: begin once, add
-- per record, flush once. One batch in screen space; the tumble is
-- evaluated from the record's motion numbers (services/Tumble.eval).
-- Without a batch (headless, atlas off) each record paints the vector way
-- under the same transform chain Tumble.wrap builds.
local _flight_batch = nil
local flightRenderer = {}

local function flightImmediate(rec, squash, near, spin)
    local es = rec.es or 1
    love.graphics.push()
    love.graphics.translate(rec.x, rec.y)
    if near ~= 1 then love.graphics.scale(near, near) end
    love.graphics.rotate(rec.tb_axis or 0)
    love.graphics.scale(1, squash)
    love.graphics.rotate(spin)
    if es ~= 1 then love.graphics.scale(es, es) end
    if squash < EDGE_SQUASH then
        Chips.drawChipEdge(0, 0, rec.denom, rec.alpha or 1, rec.tint)
    else
        Chips.drawChip(0, 0, rec.denom, rec.alpha or 1, rec.label, rec.tint, nil, nil, es)
    end
    love.graphics.pop()
end

function flightRenderer.begin()
    if _flight_batch and _flight_batch.gen ~= _atlas_gen then
        Chips.releaseBatch(_flight_batch)
        _flight_batch = nil
    end
    -- false means the last try found no atlas; trying again is a flag
    -- check when there still is none, and the batch appears the frame the
    -- atlas does.
    if not _flight_batch then
        _flight_batch = Chips.newBatch(256) or false
    end
    if _flight_batch then Chips.batchClear(_flight_batch) end
end

function flightRenderer.add(rec)
    local squash, near, spin = Tumble.eval(rec, rec.t)
    local B = _flight_batch
    if B == nil then
        flightRenderer.begin()
        B = _flight_batch
    end
    if not B then
        flightImmediate(rec, squash, near, spin)
        return
    end
    local es = rec.es or 1
    noteScale(es * near)
    if es < B.es_lo then B.es_lo = es end
    if es > B.es_hi then B.es_hi = es end
    composeChipTumbling(B, rec.x, rec.y, rec.denom, rec.alpha, rec.label, rec.tint,
                        es, rec.tb_axis or 0, squash, spin, near)
end

function flightRenderer.flush()
    local B = _flight_batch
    if not B or B.n == 0 then return end
    Chips.drawBatch(B, 0, 0, 1)
    Chips.batchClear(B)
end

-- A failed batch is retried on the next generation (a resize, a font).
function flightRenderer.reset()
    if _flight_batch then Chips.releaseBatch(_flight_batch) end
    _flight_batch = nil
end

Chips.flightRenderer = flightRenderer

-- with_label = true draws the denomination on the inlay.
-- shade  (optional) multiplies the chip's colors — stack depth.
-- depth  (optional) chips above this one in its column; > 0 means only
--        the bottom crescent is visible and the rest is wasted work.
-- escale (optional) the caller's own love.graphics.scale factor, so the
--        detail level is picked from the chip's REAL on-screen size
--        rather than its nominal radius.
-- rot    (optional) turns this chip's edge spots. See stackLayoutInto.
function Chips.drawChip(x, y, denom_idx, alpha, with_label, tint, shade, depth, escale, rot)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    local es = escale or 1
    _n_chips = _n_chips + 1
    noteScale(es)

    -- Textured quads out of the atlas, in the caller's transform. Falls
    -- through to the vector path when there is no atlas, and the whole
    -- thing is off when C.FEATURES.CHIP_ATLAS is false.
    if ensureAtlas() then
        Immediate.chips = 0
        love.graphics.setBlendMode("alpha", "premultiplied")
        composeChip(Immediate, x, y, denom_idx, alpha, with_label, tint, shade, depth, rot, es, 1)
        love.graphics.setBlendMode("alpha")
        return
    end

    setupColors(d, tint, shade)
    local r   = CHIP_RADIUS
    local eff = r * es
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
        paintChip(r, d, alpha, detail, band_hw, spot_cap, rot, es, denom_idx)
    else
        love.graphics.push()
        love.graphics.translate(x, y)
        paintChip(r, d, alpha, detail, band_hw, spot_cap, rot, es, denom_idx)
        love.graphics.pop()
    end
end

-- A whole column as one shape: the pill of its body in the rim colour, the
-- top chip's disc on it, and an outline. What a pile draws below
-- data/felt_layout's pile.micro_below_d, where views/ChipPile hands it
-- through as detail = "micro".
--
-- Why: at 36 tables a pot chip is ~12px across and every chip but the top
-- of each column is buried, and a buried chip is painted as a cylinder
-- wall with seven tessellated arcs for a sliver a pixel tall. Half of
-- everything a small panel drew was those arcs. Three primitives here, no
-- shadow, and nothing the eye could read at that size is gone.
--
-- `n_above` is how many chips sit on the base one: the base entry's
-- `depth` from the layout, so the column top is that many STACK_OFFSET_Y
-- steps up. Called the way drawChip is, at (x, y) or at the origin under
-- the caller's scale, with `escale` the scale applied so the 1px outline
-- can stay a screen pixel.
function Chips.drawColumn(x, y, denom_idx, n_above, alpha, tint, escale)
    local d = ChipData.denominations[denom_idx]
    if not d then return end
    alpha = alpha or 1
    setupColors(d, tint, 1)
    local r   = CHIP_RADIUS
    local es  = escale or 1
    local top = y + (n_above or 0) * STACK_OFFSET_Y
    _n_chips = _n_chips + 1
    noteScale(es)

    -- Three fills and no line mode: the outline is the body disc inset a
    -- screen pixel inside the outline disc.
    Theme.setColor(_rim, alpha)
    love.graphics.rectangle("fill", x - r, top - r, 2 * r, (y - top) + 2 * r, r)
    Theme.setColor(_out, alpha)
    love.graphics.circle("fill", x, top, r)
    Theme.setColor(_body, alpha)
    love.graphics.circle("fill", x, top, math.max(1, r - 1 / es))
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
    _n_chips = _n_chips + 1
    if ensureAtlas() then
        -- The edge cell is radially symmetric, so turning the sprite turns
        -- its spots and nothing else.
        tint = tint or IDENTITY_TINT
        love.graphics.setBlendMode("alpha", "premultiplied")
        love.graphics.setColor(tint[1] * alpha, tint[2] * alpha, tint[3] * alpha, alpha)
        local cell = _cells.edge[denom_idx][1]
        love.graphics.draw(_atlas, cell.q, x, y, rot or 0, 1, 1, cell.ox, cell.oy)
        love.graphics.setBlendMode("alpha")
        return
    end
    setupColors(d, tint, 1)
    if x == 0 and y == 0 then
        paintChip(CHIP_RADIUS, d, alpha, "edge", nil, nil, rot, 1, denom_idx)
    else
        love.graphics.push()
        love.graphics.translate(x, y)
        paintChip(CHIP_RADIUS, d, alpha, "edge", nil, nil, rot, 1, denom_idx)
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
--
-- In the currency colours it is one atlas quad (the glyph cell, or the
-- flat one below MIN_DETAIL_R) from the smallest bake at least its size,
-- dimmed by `shade` as a multiply. Any other colour pair, or a theme whose
-- currency colours moved since the bake, paints the vector way.
function Chips.drawGlyph(x, y, r, alpha, shade, colors)
    alpha = alpha or 1
    shade = shade or 1
    local chip = (colors and colors[1]) or Theme.currency.chip
    local ring = (colors and colors[2]) or Theme.currency.chip_ring

    if not colors and ensureAtlas() then
        local g = _glyph_baked
        if chip[1] == g[1] and chip[2] == g[2] and chip[3] == g[3]
           and ring[1] == g[4] and ring[2] == g[5] and ring[3] == g[6] then
            local set  = (r >= MIN_DETAIL_R) and _cells.glyph or _cells.glyph_flat
            local cell = set[#set]
            for gi = 1, #set do
                if set[gi].r >= r then cell = set[gi]; break end
            end
            local sc = r / cell.r
            local k  = shade * alpha
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.setColor(k, k, k, alpha)
            love.graphics.draw(_atlas, cell.q, x, y, 0, sc, sc, cell.ox, cell.oy)
            love.graphics.setBlendMode("alpha")
            return
        end
    end

    setupGlyphColors(chip, ring, shade)
    -- Detail only where it still resolves. Below this the glyph is a
    -- handful of pixels and anatomy is noise.
    paintGlyph(x, y, r, alpha, r >= MIN_DETAIL_R)
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

-- A glyph ARRANGEMENT: `points` is a list of { dx, row, rise, front }
-- with dx in units of `col_step` (a fraction of r, centre to centre),
-- row counting up from the base (each row `row_step` x r higher), an
-- optional extra `rise` in radii, and `front = true` to draw the chip
-- over everything else. Otherwise chips draw top row first, then left
-- to right, so the ones in front (lower, further right) sit over the
-- ones behind, the way drawGlyphStack's bottom chip fronts its column.
-- views/TierGlyph owns the shapes (one chip, a pair, a pyramid, a column).
function Chips.drawGlyphShape(cx, baseline_y, points, r, color, alpha, col_step, row_step)
    alpha = alpha or 1
    color = color or Theme.currency.chip
    mul(_glyph_ring, color, 0.55)
    _glyph_colors[1], _glyph_colors[2] = color, _glyph_ring
    local step_y = math.max(1, math.floor(r * (row_step or 0.55)))
    local step_x = r * (col_step or 1.0)
    local function place(p)
        Chips.drawGlyph(cx + (p[1] or 0) * step_x,
                        baseline_y - (p[2] or 0) * step_y - (p[3] or 0) * r,
                        r, alpha, 1, _glyph_colors)
    end
    local top = 0
    for _, p in ipairs(points) do if (p[2] or 0) > top then top = p[2] end end
    for row = top, 0, -1 do
        for _, p in ipairs(points) do
            if (p[2] or 0) == row and not p[4] then place(p) end
        end
    end
    for _, p in ipairs(points) do if p[4] then place(p) end end
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
-- Solves into a flat RECORD: parallel arrays, one entry per placed chip
-- in draw order — BACK ROW FIRST, so a caller that walks the record
-- paints every chip over whatever sits behind it. No table per chip, no
-- closure, nothing allocated once the record's arrays have grown: a pile
-- re-solves on every landing, and the old per-chip tables were the
-- busiest allocation on a busy board.
--
--   n                 entries
--   x[], y[]          the chip's centre, in the caller's space
--   idx[]             denomination
--   pos[]             the chip's index in the INPUT list (or `pos_of` of
--                     it, see below). The layout groups by denomination
--                     and can clip the tail, so draw order is not input
--                     order and a caller that tracks individual chips
--                     (views/ChipPile) needs the mapping back. Chips
--                     dropped by the width budget have no entry.
--   depth[]           chips ON TOP of this one in its column: what dims
--                     it and what says only its crescent is visible
--   label[]           the top of its column, unless labels are off
--   base[]            the bottom of its column — where a shadow goes
--   rot[]             the slot's spot rotation
--   shade[]           shadeFor(depth)
--   row[]             which staggered row; 0 is the front
--   col[]             which column (index into the col_* arrays)
--   k_of_pos[]        pos -> entry; k_of_pos_n is how far it is written
--   n_cols, col_idx[], col_n[], col_x[], col_y[], col_row[], col_top_k[]
--                     the columns: denomination, chips, base centre, row,
--                     and the entry of the top chip, so a column can grow
--                     by one without a re-solve (views/ChipPile.accept)
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
-- `options.labels == false` masks every label at the source, so a pile
-- placed without them (tournament chips are not money) never says "1c" in
-- any consumer — draw, settle parts, takeAll debris.
--
-- `pos_of[i]` (optional) maps input index i to the pos the caller wants
-- written, so views/ChipPile gets entries keyed on its own chip indices
-- without a second pass.
function Chips.newLayoutRecord()
    return {
        n = 0, x = {}, y = {}, idx = {}, pos = {}, depth = {}, label = {},
        base = {}, rot = {}, shade = {}, row = {}, col = {},
        k_of_pos = {}, k_of_pos_n = 0,
        n_cols = 0, col_idx = {}, col_n = {}, col_s0 = {}, col_x = {}, col_y = {},
        col_row = {}, col_top_k = {},
    }
end

-- Solver scratch: a fixed count per denomination replaces the group
-- tables and their sort (data/chips.lua orders the ladder smallest to
-- largest, so a higher index is a bigger chip and walking the counts from
-- the top IS the sort), and a counting sort replaces the per-group source
-- lists.
local ND       = #ChipData.denominations
local _count   = {}
local _start   = {}
local _cursor  = {}
local _sorted  = {}
local _in_row  = {}
for d = 1, ND do _count[d], _start[d], _cursor[d] = 0, 0, 0 end

local function widthFor(n) return n * CHIP_DIAMETER + math.max(0, n - 1) * COL_GAP end

-- Rows alternate wide/narrow — 3, 2, 3 — and the narrow ones are
-- staggered half a pitch so they sit in the gaps of the row in front.
-- That is how chips actually end up on a table, and it packs a pile
-- into far less width than one long line.
local function colsInRow(r, base_cols)
    if r % 2 == 1 and base_cols > 1 then return base_cols - 1 end
    return base_cols
end

function Chips.stackLayoutInto(L, chips, n, options, pos_of)
    Perf.count("stack_layout")
    local kop = L.k_of_pos
    for i = 1, L.k_of_pos_n do kop[i] = nil end
    L.k_of_pos_n = 0
    L.n, L.n_cols = 0, 0
    if not chips or n == 0 then return L end
    options = options or EMPTY
    local align     = options.align or "center"
    local max_w     = options.max_w                      -- nil = unbounded width
    -- How wide and how deep this pile may get, in COLUMNS. The caller sets
    -- these; a pile has no idea what is drawn around it.
    local max_cols  = math.max(1, options.max_cols or DEFAULT_MAX_COLS)
    local max_rows  = math.max(1, options.max_rows or DEFAULT_MAX_ROWS)
    local no_labels = (options.labels == false)

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
    for d = 1, ND do _count[d] = 0 end
    for i = 1, n do
        local d = chips[i]
        _count[d] = _count[d] + 1
    end
    local off = 0
    for d = ND, 1, -1 do
        _start[d]  = off
        _cursor[d] = off
        off = off + _count[d]
    end
    for i = 1, n do
        local d = chips[i]
        local c = _cursor[d] + 1
        _cursor[d] = c
        _sorted[c] = i
    end

    -- Flatten the groups into COLUMNS. Each group breaks into vertical
    -- columns of MAX_PER_COLUMN chips; a column is the unit that gets
    -- placed, wrapped onto another row, or (last resort) dropped.
    local nc = 0
    local col_idx, col_n, col_s0 = L.col_idx, L.col_n, L.col_s0
    for d = ND, 1, -1 do
        local cnt = _count[d]
        if cnt > 0 then
            local s0   = _start[d]
            local cols = math.ceil(cnt / MAX_PER_COLUMN)
            for c = 1, cols do
                nc = nc + 1
                col_idx[nc] = d
                col_n[nc]   = math.min(MAX_PER_COLUMN, cnt - (c - 1) * MAX_PER_COLUMN)
                col_s0[nc]  = s0 + (c - 1) * MAX_PER_COLUMN
            end
        end
    end

    local pitch = CHIP_DIAMETER + COL_GAP

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

    local capacity = 0
    for r = 0, max_rows - 1 do capacity = capacity + colsInRow(r, base_cols) end
    if nc > capacity then nc = capacity end
    if nc == 0 then return L end

    -- Row 0 is the FRONT row and carries the largest denominations, since
    -- the breakdown hands them over first and the front row is the one
    -- nothing overlaps.
    local col_row = L.col_row
    local r, left = 0, colsInRow(0, base_cols)
    for i = 1, nc do
        while left == 0 do r = r + 1; left = colsInRow(r, base_cols) end
        col_row[i] = r
        left = left - 1
    end
    local n_rows = col_row[nc] + 1
    for rr = 1, n_rows do _in_row[rr] = 0 end
    for i = 1, nc do
        local rr = col_row[i] + 1
        _in_row[rr] = _in_row[rr] + 1
    end

    local lift = math.max(2, math.floor(CHIP_RADIUS * ROW_LIFT))
    local Lx, Ly, Lidx, Lpos, Ldepth = L.x, L.y, L.idx, L.pos, L.depth
    local Llabel, Lbase, Lrot, Lshade, Lrow, Lcol = L.label, L.base, L.rot, L.shade, L.row, L.col
    local col_x, col_y, col_top_k = L.col_x, L.col_y, L.col_top_k
    local kopn = 0

    -- Emit BACK row first so a simple sequential draw layers correctly:
    -- every chip is painted over whatever sits behind it.
    local k = 0
    for rr = n_rows - 1, 0, -1 do
        local count = _in_row[rr + 1]
        if count > 0 then
            local row_w = widthFor(count)
            -- Odd rows step half a pitch across, so a back column peeks out
            -- between the two in front of it instead of hiding exactly
            -- behind one.
            local stagger = (rr % 2 == 1) and math.floor(pitch * 0.5) or 0
            local origin_x
            if align == "left" then
                origin_x = stagger
            elseif align == "right" then
                origin_x = -row_w + stagger
            else
                origin_x = -row_w / 2 + stagger
            end

            local cx = origin_x + CHIP_RADIUS
            local ry = -rr * lift
            for ci = 1, nc do
                if col_row[ci] == rr then
                    local cn, s0, d = col_n[ci], col_s0[ci], col_idx[ci]
                    col_x[ci], col_y[ci] = cx, ry
                    for kk = 1, cn do
                        k = k + 1
                        local src   = _sorted[s0 + kk]
                        local pos   = pos_of and pos_of[src] or src
                        local depth = cn - kk
                        Lx[k]     = cx
                        Ly[k]     = ry + (kk - 1) * STACK_OFFSET_Y
                        Lidx[k]   = d
                        Lpos[k]   = pos
                        Ldepth[k] = depth
                        Llabel[k] = (kk == cn) and not no_labels
                        Lbase[k]  = (kk == 1)
                        Lrow[k]   = rr
                        Lcol[k]   = ci
                        Lrot[k]   = Chips.slotRotation(d, ci, kk)
                        Lshade[k] = Chips.shadeFor(depth)
                        kop[pos]  = k
                        if pos > kopn then kopn = pos end
                    end
                    col_top_k[ci] = k
                    cx = cx + pitch
                end
            end
        end
    end
    L.n, L.n_cols, L.k_of_pos_n = k, nc, kopn
    return L
end

-- Returns an array of { x, y, idx, with_label, src, depth, shade,
-- col_base, row, rot } in draw order: the allocating form of the solver
-- above, for callers that lay a pile out once (views/ChipPile.layoutAt,
-- the shove's pot, the sims' cross-check). Solved at (x, y): positions are
-- offset by the anchor here, where the record form is always at the
-- origin.
local _WL = Chips.newLayoutRecord()
function Chips.stackLayout(x, y, chip_indices, options)
    local placed = {}
    if not chip_indices or #chip_indices == 0 then return placed end
    local L = Chips.stackLayoutInto(_WL, chip_indices, #chip_indices, options)
    for k = 1, L.n do
        placed[k] = {
            x          = x + L.x[k],
            y          = y + L.y[k],
            idx        = L.idx[k],
            with_label = L.label[k],
            src        = L.pos[k],
            depth      = L.depth[k],
            shade      = L.shade[k],
            col_base   = L.base[k],
            row        = L.row[k],
            rot        = L.rot[k],
        }
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
