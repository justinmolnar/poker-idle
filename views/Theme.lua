-- views/Theme.lua
--
-- Access layer over data/theme.lua. Loads the palette tables, exposes
-- per-palette tokens via re-pointed fields (Theme.bg, Theme.fg, etc.) so
-- consumers read them per-frame, and provides setActive / cycle / setColor
-- helpers.
--
-- Why this lives in views/ instead of data/:
--   data/theme.lua is pure data (no functions, no LÖVE calls). The dispatch
--   helpers (setActive, setColor, assetTint) call into love.graphics so they
--   belong on the view side. data/ stays load-bearing-data-only.

local Theme = {}

local PaletteData = require("data.theme")

-- Re-export the theme-invariant tables straight through.
Theme.size  = PaletteData.size
Theme.space = PaletteData.space
Theme.font  = PaletteData.font
Theme.debug = PaletteData.debug
Theme.currency = PaletteData.currency
Theme.card  = PaletteData.card

-- ─── Active-palette dispatch ────────────────────────────────────────
-- Per-palette tables (bg/fg/border/data/status/tint) are repointed by
-- setActive. Consumers MUST read Theme.bg.widget per-frame, not cache.

Theme.active = nil

function Theme.setActive(name)
    local p = PaletteData.palettes[name] or PaletteData.palettes[PaletteData.default]
    Theme.bg     = p.bg
    Theme.border = p.border
    Theme.fg     = p.fg
    Theme.data   = p.data
    Theme.status = p.status
    Theme.status_fx = p.status_fx
    Theme.tier   = p.tier
    Theme.tint   = p.tint
    Theme.active = (PaletteData.palettes[name] and name) or PaletteData.default
end

function Theme.cycle()
    local order = PaletteData.order
    local idx = 0
    for i, n in ipairs(order) do
        if Theme.active == n then idx = i; break end
    end
    idx = (idx % #order) + 1
    Theme.setActive(order[idx])
    return Theme.active
end

Theme.setActive(PaletteData.default)

-- ─── Helpers ────────────────────────────────────────────────────────

-- Use this instead of love.graphics.setColor with literals. Token = an
-- {r,g,b} or {r,g,b,a} table from a Theme.* namespace.
function Theme.setColor(token, alpha)
    if not token then return end
    if alpha ~= nil then
        love.graphics.setColor(token[1], token[2], token[3], alpha)
    else
        love.graphics.setColor(token[1], token[2], token[3], token[4] or 1)
    end
end

-- Tint for drawing pixel-art assets. Reads the active palette's tint.world
-- so a future "haunted" palette could route everything through a hue.
function Theme.assetTint(alpha)
    local t = Theme.tint and Theme.tint.world or { 1, 1, 1 }
    love.graphics.setColor(t[1], t[2], t[3], alpha or 1)
end

return Theme
