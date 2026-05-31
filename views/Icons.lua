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

return Icons
