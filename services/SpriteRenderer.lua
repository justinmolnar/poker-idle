-- services/SpriteRenderer.lua
--
-- Render a named sprite from a SpriteLoader atlas into an (x, y, w, h) rect.
-- Stateless module — the rendering is split out from services/SpriteLoader
-- so the atlas owns load + lookup (a stable bag of named images) and this
-- module owns the visual concerns: tint, missing-asset fallback (loud
-- magenta rect so missing assets are visible), and aspect-stretching.
--
-- Engine-agnostic: takes any atlas with :getSprite(name) -> love.Image | nil.

local Theme = require("views.Theme")

local SpriteRenderer = {}

-- Track the names we've already complained about so we don't spam the log.
-- Module-private; survives across draw frames so a missing asset only logs
-- once even though we attempt to draw it every frame.
local _warned_missing = {}

-- Draw `sprite_name` from the atlas at (x, y, w, h). `tint` is an optional
-- {r, g, b} or {r, g, b, a} table (Theme token). Returns true if the sprite
-- existed and rendered, false if it was missing (and a magenta+border rect
-- was drawn as a placeholder).
function SpriteRenderer.draw(atlas, sprite_name, x, y, width, height, tint)
    local sprite = atlas and atlas:getSprite(sprite_name)

    if not sprite then
        if not _warned_missing[sprite_name] then
            print(string.format('[SpriteRenderer] MISSING sprite "%s"',
                tostring(sprite_name)))
            _warned_missing[sprite_name] = true
        end
        Theme.setColor(Theme.debug.missing_fill)
        love.graphics.rectangle('fill', x, y, width, height)
        Theme.setColor(Theme.debug.missing_border)
        love.graphics.rectangle('line', x, y, width, height)
        return false
    end

    if tint then
        Theme.setColor(tint)
    else
        Theme.assetTint()
    end

    local sw, sh = sprite:getWidth(), sprite:getHeight()
    love.graphics.draw(sprite, x, y, 0, width / sw, height / sh)
    return true
end

return SpriteRenderer
