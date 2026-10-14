-- views/Icons.lua
--
-- Game-layer icon helper. Maps a logical icon id (data/icons.lua) to a
-- sprite and draws it through the engine-agnostic services/SpriteRenderer,
-- resolving the tint token against the live Theme.
--
-- SILENT on missing sprite: unshipped icons render NOTHING (never the
-- debug-magenta SpriteRenderer would draw for an unexpected miss). That
-- lets us wire icon slots now and light them up later by dropping a PNG
-- into assets/sprites/ui/icons/ — no code change.
--
-- DI: every entry point takes `game` and reaches game.sprite_loader. No
-- globals (rule 1). love.graphics stays inside SpriteRenderer / Chips (rule 2).

local IconData       = require("data.icons")
local SpriteRenderer = require("services.SpriteRenderer")
local Chips          = require("views.Chips")
local Theme          = require("views.Theme")

local Icons = {}

-- Resolve a dotted Theme token path ("fg.heading") against the live Theme
-- each frame, so palette swaps take effect. nil path → nil (asset tint).
local function resolveTint(path)
    if not path then return nil end
    local node = Theme
    for part in string.gmatch(path, "[^.]+") do
        node = node and node[part]
        if node == nil then return nil end
    end
    return node
end

local function spriteReady(game, sprite)
    local atlas = game and game.sprite_loader
    return sprite and atlas and atlas:hasSprite(sprite) and atlas or nil
end

-- Draw logical icon `id` into (x, y, w, h). Returns true if a sprite
-- rendered, false if absent (nothing drawn — by design, until art lands).
function Icons.draw(game, id, x, y, w, h)
    local spec  = id and IconData[id]
    if not spec then return false end
    local atlas = spriteReady(game, spec.sprite)
    if not atlas then return false end
    SpriteRenderer.draw(atlas, spec.sprite, x, y, w, h, resolveTint(spec.tint))
    return true
end

-- The Gold Chip currency glyph, drawn to fill a `size`×`size` box at
-- (x, y). Uses the real sprite if present, else the procedural gold chip
-- (views/Chips.drawGlyph) so the currency always reads as an icon.
function Icons.drawChip(game, x, y, size, alpha, shade)
    local spec  = IconData.chip
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    local r = math.floor(size / 2)
    Chips.drawGlyph(x + r, y + r, r, alpha, shade)
end

function Icons.drawAntiChip(game, x, y, size, alpha, shade)
    local spec  = IconData.achip
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    -- The same glyph in another color, not a second drawing of a chip.
    -- This used to be its own pair of circles, so every improvement to the
    -- chip skipped the anti-chip and the two drifted apart.
    local r = math.floor(size / 2)
    Chips.drawGlyph(x + r, y + r, r, alpha, shade,
                    { Theme.currency.achip, Theme.currency.achip_ring })
end

-- The gear: settings, the way every UI has said it. Art from
-- data/icons `settings` when it ships; a procedural gear until then, the
-- same rule as the chip glyph.
function Icons.drawGear(game, x, y, size, color)
    local spec  = IconData.settings
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    local cx, cy = x + size / 2, y + size / 2
    local r_out  = size * 0.5
    local r_in   = size * 0.36
    local r_hole = size * 0.14
    local teeth  = 8
    local tw     = r_out * 0.55
    Theme.setColor(color or Theme.fg.heading)
    for i = 1, teeth do
        local a = (i - 1) / teeth * math.pi * 2
        love.graphics.push()
        love.graphics.translate(cx, cy)
        love.graphics.rotate(a)
        love.graphics.rectangle("fill", -tw * 0.5, -r_out, tw, r_out - r_in + 1)
        love.graphics.pop()
    end
    love.graphics.circle("fill", cx, cy, r_in)
    Theme.setColor(Theme.bg.chrome)
    love.graphics.circle("fill", cx, cy, r_hole)
end

-- The status glyphs that sit before a tinted heat or tilt word in copy
-- (views/IconText). Art from data/icons `heater` / `tilt` when it ships; a
-- procedural glyph until then, the chip's rule. Both fill a `size` box.

-- A flame: a wide base tongue with a narrower one rising off-centre.
function Icons.drawFlame(game, x, y, size, alpha)
    local spec  = IconData.heater
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    local s = size
    Theme.setColor(Theme.sem.heat, alpha)
    love.graphics.polygon("fill",
        x + s * 0.50, y,
        x + s * 0.92, y + s * 0.62,
        x + s * 0.70, y + s,
        x + s * 0.30, y + s,
        x + s * 0.08, y + s * 0.62,
        x + s * 0.34, y + s * 0.42)
    Theme.setColor(Theme.paper.page_light, (alpha or 1) * 0.85)
    love.graphics.polygon("fill",
        x + s * 0.50, y + s * 0.45,
        x + s * 0.68, y + s * 0.78,
        x + s * 0.50, y + s,
        x + s * 0.32, y + s * 0.78)
end

-- Tilt: three short bars leaning right, the top one furthest, a stack
-- about to go over.
function Icons.drawTilt(game, x, y, size, alpha)
    local spec  = IconData.tilt
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    local s  = size
    local bh = math.max(1, math.floor(s * 0.22))
    local bw = math.floor(s * 0.62)
    Theme.setColor(Theme.sem.tilt, alpha)
    for i = 0, 2 do
        local lean = math.floor((2 - i) * s * 0.14)
        love.graphics.rectangle("fill", x + lean, y + math.floor(i * (s - bh) / 2), bw, bh)
    end
end

-- The knockout mark ({ko} in copy; the table's KO float; the catalog's
-- knockout lines): the sprite when it ships, else a small plate in the
-- error red with "KO" cut out of it — the same mark everywhere it is said.
function Icons.drawKo(game, x, y, size, alpha)
    local spec  = IconData.ko
    local atlas = spec and spriteReady(game, spec.sprite)
    if atlas then
        SpriteRenderer.draw(atlas, spec.sprite, x, y, size, size, resolveTint(spec.tint))
        return
    end
    local s = size
    local r = math.max(1, math.floor(s * 0.18))
    Theme.setColor(Theme.status.error, alpha)
    love.graphics.rectangle("fill", x, y, s, s, r)
    -- "K" and "O" as strokes, so the mark reads at any size.
    local t = math.max(1, math.floor(s * 0.14))
    local px, py, pw, ph = x + math.floor(s * 0.14), y + math.floor(s * 0.2), math.floor(s * 0.32), math.floor(s * 0.6)
    Theme.setColor(Theme.paper.page_light, alpha)
    love.graphics.rectangle("fill", px, py, t, ph)                                  -- K stem
    love.graphics.polygon("fill", px + t, py + math.floor(ph / 2), px + pw, py, px + pw, py + t, px + t + t, py + math.floor(ph / 2) + 1)
    love.graphics.polygon("fill", px + t, py + math.floor(ph / 2), px + pw, py + ph, px + pw, py + ph - t, px + t + t, py + math.floor(ph / 2) - 1)
    local ox, ow = x + math.floor(s * 0.54), math.floor(s * 0.32)
    love.graphics.setLineWidth(t)
    love.graphics.rectangle("line", ox + t / 2, py + t / 2, ow - t, ph - t, math.floor(ow * 0.3))   -- O
    love.graphics.setLineWidth(1)
end

return Icons
