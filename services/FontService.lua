-- services/FontService.lua
--
-- Builds the canonical `game.fonts` table from the type scale in
-- data/theme.lua. Three universal sizes (sm/md/lg) consumed across
-- views via DI (game.fonts.X).
--
-- Fonts are built at exact data/theme.lua sizes — no per-window
-- scaling. With the push canvas we render the entire UI
-- at a fixed virtual size and scale-blit to the actual window, so
-- font sizes stay constant and the canvas-blit handles "look bigger
-- on a 4K display".
--
-- Engine-agnostic.

local FontService = {}

local function newFont(font_data, size)
    if font_data.path_main then
        return love.graphics.newFont(font_data.path_main, size)
    end
    return love.graphics.newFont(size)
end

function FontService.build(font_data)
    return {
        sm = newFont(font_data, font_data.size_sm or 16),
        md = newFont(font_data, font_data.size_md or 22),
        lg = newFont(font_data, font_data.size_lg or 48),
    }
end

return FontService
