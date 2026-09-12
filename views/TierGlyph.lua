-- views/TierGlyph.lua
--
-- THE single source of truth for the outcome-tier glyph (Small / Medium /
-- Large / Stack). Four SILHOUETTES of overlapping chips at one radius, so
-- a tier reads by shape at a glance rather than by counting chips in a
-- tiny column: one chip, a pair side by side, a pyramid of three, a
-- column of four. Colored by the per-tier win/loss ramp (data/theme
-- tier.win / tier.loss) — the same one the history bars use.
-- One implementation so the tiers look identical everywhere they appear — the
-- EV tooltip (views/TablePanelStats) and inline in prose (views/IconText)
-- both call this; nothing reimplements it.
--
-- Accepts either the internal tier key ("stack") or the display token
-- ("stack") — both resolve to the same glyph.

local Chips = require("views.Chips")
local Theme = require("views.Theme")

local TierGlyph = {}

-- The tier key IS the display token: small / medium / large / stack.
-- Each shape is a list of { dx, row, rise, front }: dx in chip-centre
-- steps sideways (COL_STEP x r, so neighbours overlap by a radius), row
-- up from the base (ROW_STEP x r, the stack's overlap), an extra rise in
-- radii, and front = true for a chip drawn over the rest. Otherwise the
-- chips in front are the lower, further-right ones (views/Chips
-- .drawGlyphShape draws them last). The pyramid's top chip is the one
-- exception: it sits ON the pair, in front and a little higher, so the
-- three read as a heap rather than a chip behind two.
local COL_STEP = 1.0
local ROW_STEP = 0.55
local SHAPES = {
    small  = { { 0, 0 } },
    medium = { { -0.5, 0 }, { 0.5, 0 } },
    large  = { { -0.5, 0 }, { 0.5, 0 }, { 0, 1, 0.25, true } },
    stack  = { { 0, 0 }, { 0, 1 }, { 0, 2 }, { 0, 3 } },
}

function TierGlyph.has(tier) return SHAPES[tier] ~= nil end

-- Radius for a glyph that fits a `size`-tall box (the 4-stack just fits).
function TierGlyph.radius(size) return math.max(2, math.floor(size * 0.30)) end

-- Footprint of a shape at radius r: the pair and the pyramid are a radius
-- wider than a chip; the column is a chip wide. Height counts the rows.
function TierGlyph.width(tier, r)
    local pts = SHAPES[tier] or SHAPES.small
    local lo, hi = 0, 0
    for _, p in ipairs(pts) do
        if p[1] < lo then lo = p[1] end
        if p[1] > hi then hi = p[1] end
    end
    return math.ceil(r * 2 + (hi - lo) * COL_STEP * r)
end

function TierGlyph.height(tier, r)
    local pts = SHAPES[tier] or SHAPES.small
    local top = 0
    for _, p in ipairs(pts) do
        local h = p[2] * math.max(1, math.floor(r * ROW_STEP)) + (p[3] or 0) * r
        if h > top then top = h end
    end
    return r * 2 + top
end

-- Color for a tier under a win/loss outcome ("win" default). Uses the same
-- per-tier win/loss ramp the history bars use, so a tier is one color
-- everywhere it appears.
function TierGlyph.color(tier, outcome)
    local ramp = Theme.tier and Theme.tier[outcome or "win"]
    return (ramp and ramp[tier]) or Theme.currency.chip
end

-- Draw the tier's shape with its base row centred on (cx, baseline_y),
-- radius r, colored by the win/loss ramp. Returns the drawn width.
-- The same shape in an explicit colour: the anti-chip readout draws the
-- Stack glyph in corruption's purple without touching the tier ramp.
function TierGlyph.drawColored(cx, baseline_y, tier, r, color, alpha)
    Chips.drawGlyphShape(cx, baseline_y, SHAPES[tier] or SHAPES.small, r, color, alpha,
                         COL_STEP, ROW_STEP)
    return TierGlyph.width(tier, r)
end

function TierGlyph.draw(cx, baseline_y, tier, r, outcome, alpha)
    Chips.drawGlyphShape(cx, baseline_y, SHAPES[tier] or SHAPES.small, r,
                         TierGlyph.color(tier, outcome), alpha, COL_STEP, ROW_STEP)
    return TierGlyph.width(tier, r)
end

return TierGlyph
