-- services/FontService.lua
--
-- Builds the canonical `game.fonts` table from the type scale in
-- data/theme.lua. Three universal sizes (sm/md/lg) consumed across
-- views via DI (game.fonts.X).
--
-- Sizes scale by an INTEGER factor based on window dimensions so
-- the chunky pixel font stays on its 8-px grid (1× / 2× / 3×).
-- Reference is 1280×720; bigger windows scale up. main.lua rebuilds
-- the table in place on love.resize so consumers reading
-- game.fonts.X automatically pick up the new instances.
--
-- Engine-agnostic.

local FontService = {}

local REF_W, REF_H = 1280, 720

-- Two scales:
--   • Font scale is INTEGER (1×, 2×, 3×) so the chunky pixel font
--     stays on its 8-px grid. Floor of the smaller axis ratio.
--   • Layout scale is FLOAT (1.0, 1.5, 2.0, ...) so panel max sizes
--     and sidebar minimums grow smoothly with the window — at
--     1920×1080 you get 1.5× layout but still 1× fonts (crisp).
local function fontScale(W, H)
    if not (W and H) then return 1 end
    local s = math.floor(math.min(W / REF_W, H / REF_H))
    if s < 1 then s = 1 end
    return s
end

local function layoutScale(W, H)
    if not (W and H) then return 1 end
    local s = math.min(W / REF_W, H / REF_H)
    if s < 1 then s = 1 end
    return s
end

local function newFont(font_data, size)
    if font_data.path_main then
        return love.graphics.newFont(font_data.path_main, size)
    end
    return love.graphics.newFont(size)
end

function FontService.build(font_data, W, H)
    if not (W and H) then W, H = love.graphics.getDimensions() end
    local s = fontScale(W, H)
    return {
        sm = newFont(font_data, (font_data.size_sm or 8) * s),
        md = newFont(font_data, (font_data.size_md or 16) * s),
        lg = newFont(font_data, (font_data.size_lg or 24) * s),
    }
end

-- Mutate game.fonts in place so existing references update on the
-- next frame. Used from love.resize.
function FontService.rebuildInto(fonts_table, font_data, W, H)
    local fresh = FontService.build(font_data, W, H)
    for k in pairs(fonts_table) do fonts_table[k] = nil end
    for k, v in pairs(fresh)     do fonts_table[k] = v   end
end

-- Public accessors: callers that need the integer font scale (rare)
-- vs the float layout scale (most layout code).
function FontService.fontScale(W, H)   return fontScale(W, H)   end
function FontService.layoutScale(W, H) return layoutScale(W, H) end
-- Backward-compat alias for the old single .scale() name.
function FontService.scale(W, H)       return layoutScale(W, H) end

return FontService
