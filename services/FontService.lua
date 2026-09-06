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

-- The layout scale follows the HEIGHT only: the base frame's height is
-- fixed (main.lua BASE_H), so this is the same 1.25 for every window, and
-- a narrow window can shrink the base width without rescaling anything.
local function layoutScale(W, H)
    if not (W and H) then return 1 end
    local s = H / REF_H
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
        xl = newFont(font_data, (font_data.size_xl or 48) * s),
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

-- ─── Ink vs. line box ────────────────────────────────────────────────
-- Share of a line's HEIGHT that is actual ink: Thin Sans draws 1.25em
-- glyphs inside a 2.625em line box. font:getHeight() returns the LINE
-- box, so a caller asking "does a glyph FIT inside this small shape?"
-- (a chip's label plate, a card's rank) has to measure the ink, not the
-- box, or it rejects labels that would have fit with room to spare.
--
-- Positioning still centres on the line box, which is what every view
-- here does and what the ink lands centred on in this face. This is the
-- FIT number only.
--
-- Lives at this layer because it is a property of the FONT, not of
-- whatever is being drawn — views/Chips and views/CardSprites both read it.
FontService.INK_OF_LINE = 1.25 / 2.625

-- Height of one line's actual ink in `font`.
function FontService.inkHeight(font)
    return font:getHeight() * FontService.INK_OF_LINE
end

return FontService
