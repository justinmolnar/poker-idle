-- services/FontService.lua
--
-- Builds the canonical `game.fonts` table from the type scale in
-- data/theme.lua. Three universal sizes (sm/md/lg) consumed across
-- views via DI (game.fonts.X).
--
-- The game renders at a FIXED base resolution into a canvas (main.lua), so the
-- pixel font is rasterized once at a clean integer scale — 1-bit (mono) +
-- nearest, perfectly crisp, no fractional artifacts — and the finished frame is
-- then scaled to the window by a sharp-bilinear shader. Reference 1280×720.
--
-- Engine-agnostic.

local FontService = {}

local REF_W, REF_H = 1280, 720

-- Font scale is INTEGER (1×, 2×, 3×) so the pixel font lands on its grid.
-- Layout scale is FLOAT so panel sizes grow smoothly.
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
    -- 1-bit "mono" hinting + nearest filter = hard pixel glyphs, no AA. Because
    -- the frame is rendered at a fixed base resolution and scaled by a sharp-
    -- bilinear shader (main.lua), the font is only ever rasterized at clean
    -- integer sizes here — crisp, no gridlines, no uneven strokes.
    local f
    if font_data.path_main then
        f = love.graphics.newFont(font_data.path_main, size, "mono", 1)
    else
        f = love.graphics.newFont(size, "normal", 1)
    end
    f:setFilter("nearest", "nearest")
    return f
end

function FontService.build(font_data, W, H)
    if not (W and H) then W, H = love.graphics.getDimensions() end
    local s    = fontScale(W, H)
    local base = font_data.size_sm or 8
    return {
        xs = newFont(font_data, base * math.max(1, s - 1)),
        sm = newFont(font_data, base * s),
        md = newFont(font_data, (font_data.size_md or 16) * s),
        lg = newFont(font_data, (font_data.size_lg or 24) * s),
    }
end

-- Mutate game.fonts in place so existing references update on the next frame.
function FontService.rebuildInto(fonts_table, font_data, W, H)
    local fresh = FontService.build(font_data, W, H)
    for k in pairs(fonts_table) do fonts_table[k] = nil end
    for k, v in pairs(fresh)     do fonts_table[k] = v   end
end

function FontService.fontScale(W, H)   return fontScale(W, H)   end
function FontService.layoutScale(W, H) return layoutScale(W, H) end
function FontService.scale(W, H)       return layoutScale(W, H) end

return FontService
