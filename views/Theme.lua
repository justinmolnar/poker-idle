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
Theme.paper = PaletteData.paper

-- ─── Active-palette dispatch ────────────────────────────────────────
-- Per-palette tables (bg/fg/border/data/status/tint) are repointed by
-- setActive. Consumers MUST read Theme.bg.widget per-frame, not cache.

Theme.active = nil

function Theme.setActive(name)
    local p = PaletteData.palettes[name] or PaletteData.palettes[PaletteData.default]
    Theme.bg     = p.bg
    Theme.border = p.border
    Theme.fg     = p.fg
    Theme.sem    = p.sem
    Theme.status = p.status
    Theme.status_fx = p.status_fx
    Theme.tier   = p.tier
    Theme.tint   = p.tint
    Theme.active = (PaletteData.palettes[name] and name) or PaletteData.default
    -- The frame canvas is cleared to this, so no screen has to paint a
    -- full-window quad to get the page colour under everything.
    if love and love.graphics and love.graphics.setBackgroundColor then
        local w = p.bg and p.bg.window
        if w then love.graphics.setBackgroundColor(w[1], w[2], w[3], 1) end
    end
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

-- A meaning's colour by name: "heat" → Theme.sem.heat. Accepts the
-- status aliases (good → won, error → lost) and the fg names (heading,
-- muted, faint, primary) so one resolver serves every data-driven
-- color_token field and the {c:…} copy token. nil for an unknown name.
local SEM_ALIAS = { good = "won", error = "lost", amber = "won", bad = "lost" }
function Theme.semColor(name)
    if not name then return nil end
    local sem = Theme.sem
    if sem and sem[name] then return sem[name] end
    local alias = SEM_ALIAS[name]
    if alias and sem then return sem[alias] end
    if Theme.fg and Theme.fg[name] then return Theme.fg[name] end
    if Theme.paper and Theme.paper[name] then return Theme.paper[name] end
    return nil
end

-- Relative luminance of a colour token, 0..1.
function Theme.luminance(token)
    if not token then return 0 end
    return 0.2126 * token[1] + 0.7152 * token[2] + 0.0722 * token[3]
end

-- Digits on a pill filled in `fill`: dark ink on a light fill, paper on a
-- dark one. Which "dark" and "light" are the paper's, so a pill reads the
-- same on the catalog and on the felt.
function Theme.contrastFor(fill)
    if Theme.luminance(fill) > 0.5 then return Theme.paper.ink end
    return Theme.paper.page_light
end

-- The halo an embossed keyword is printed in, from the text colour it sits
-- in: dark text (ink on paper) gets a faint copy of itself, light text (on
-- the felt) gets the floater's black ring. Returns {r, g, b, a}.
function Theme.embossFor(color)
    color = color or Theme.fg.heading
    if Theme.luminance(color) < 0.5 then
        return { color[1], color[2], color[3], 0.30 }
    end
    return { 0, 0, 0, 0.85 }
end

-- A colour token from data (data/catalog_pages.lua `tab`): "sem:heat",
-- "gtype:zoom" (data/game_type_themes.lua chrome_color), "paper:ink".
-- Unknown tokens fall back to the paper's tan so a typo is visible, not a
-- crash.
local GameTypeThemes = require("data.game_type_themes")
function Theme.tabColor(token)
    local kind, name = tostring(token or ""):match("^(%w+):([%w_]+)$")
    if kind == "sem" then return Theme.semColor(name) or Theme.paper.sticker_counting end
    if kind == "gtype" then
        local gt = GameTypeThemes[name]
        return (gt and gt.chrome_color) or Theme.paper.sticker_counting
    end
    if kind == "paper" then return Theme.paper[name] or Theme.paper.sticker_counting end
    return Theme.paper.sticker_counting
end

-- Tint for drawing pixel-art assets. Reads the active palette's tint.world
-- so a future "haunted" palette could route everything through a hue.
function Theme.assetTint(alpha)
    local t = Theme.tint and Theme.tint.world or { 1, 1, 1 }
    love.graphics.setColor(t[1], t[2], t[3], alpha or 1)
end

-- The four cardinal 1px offsets a haloed / embossed string is printed at
-- before the string itself. Four callers had their own copy of this list,
-- each rebuilding it inside a draw — the emboss in IconText, the stat glow
-- in ComponentRenderer, the corrupt line in CatalogModal, and the rail's
-- underflow glow. One list, no per-frame allocation.
Theme.HALO_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- ─── One colour resolver ───────────────────────────────────────────────
-- There were five of these, each with a slightly different chain, and one
-- of them ran a pattern match per call per effect per frame. This is the
-- union of what they all accepted:
--
--   a table              -> itself (callers hand it live colours)
--   "won" / "heat" / …   -> Theme.sem, through the good/error aliases
--   "heading" / "muted"  -> Theme.fg, then Theme.paper
--   "status_fx.heater"   -> Theme[group][key], the dotted form
--   "sem:heat"           -> the same, colon form (data/catalog_pages tabs)
--
-- `fallback` is returned when nothing matches, so a caller can stop writing
-- `or Theme.fg.heading` after every call.
function Theme.color(token, fallback)
    if token == nil then return fallback end
    if type(token) == "table" then return token end

    local direct = Theme.semColor(token)
    if direct then return direct end
    if Theme.status and Theme.status[token] then return Theme.status[token] end

    local group, key = token:match("^([%w_]+)[%.:]([%w_]+)$")
    if group then
        local t = Theme[group]
        if t and t[key] then return t[key] end
    end
    return fallback
end

-- Multiply a colour's channels, keeping its alpha. `dst`, when given, is
-- written into rather than allocating — the button chrome and the felt
-- decor call this per widget per frame.
--
-- NOTE the sense of `f`: it is the fraction KEPT, so 0.5 is half as bright.
-- views/widgets/Sticker had its own darken(c, k) where k was the amount
-- REMOVED; those call sites pass 1 - k here.
function Theme.darken(c, f, dst)
    if not c then return nil end
    dst = dst or {}
    dst[1] = (c[1] or 0) * f
    dst[2] = (c[2] or 0) * f
    dst[3] = (c[3] or 0) * f
    dst[4] = c[4]
    return dst
end

return Theme
