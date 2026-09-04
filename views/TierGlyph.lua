-- views/TierGlyph.lua
--
-- THE single source of truth for the outcome-tier glyph (Small / Medium /
-- Large / Stack). Rendered as a 1 / 2 / 3 / 4 chip stack at a uniform radius
-- (taller = bigger; the chips never shrink), colored by the per-tier win/loss
-- ramp (data/theme tier.win / tier.loss) — the same one the history bars use.
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
local COUNT = { small = 1, medium = 2, large = 3, stack = 4 }

function TierGlyph.has(tier) return COUNT[tier] ~= nil end

-- Radius for a glyph that fits a `size`-tall box (the 4-stack just fits).
function TierGlyph.radius(size) return math.max(2, math.floor(size * 0.30)) end

-- Color for a tier under a win/loss outcome ("win" default). Uses the same
-- per-tier win/loss ramp the history bars use, so a tier is one color
-- everywhere it appears.
function TierGlyph.color(tier, outcome)
    local ramp = Theme.tier and Theme.tier[outcome or "win"]
    return (ramp and ramp[tier]) or Theme.currency.chip
end

-- Draw the tier as a chip-stack, bottom chip centered at (cx, baseline_y),
-- radius r, colored by the win/loss ramp. Returns the drawn width.
function TierGlyph.draw(cx, baseline_y, tier, r, outcome, alpha)
    local count = COUNT[tier] or 1
    Chips.drawGlyphStack(cx, baseline_y, count, r, TierGlyph.color(tier, outcome), alpha)
    return r * 2
end

return TierGlyph
