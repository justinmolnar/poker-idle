-- services/FontService.lua
--
-- Builds the canonical `game.fonts` table at boot from the type scale in
-- data/theme.lua. Lifted UI components (Panel, ComponentRenderer) expect
-- these to be available as `game.fonts.ui`, `game.fonts.ui_small`, etc.
-- so calling `love.graphics.newFont` per-view is wasteful and inconsistent.
--
-- Engine-agnostic — knows about font sizes from the theme, not about the
-- game.

local FontService = {}

-- font_data is data/theme.lua's `font` table:
--   { path_main, size_ui_small, size_ui, size_heading, size_kpi, size_hero }
function FontService.build(font_data)
    local function newFont(size)
        if font_data.path_main then
            return love.graphics.newFont(font_data.path_main, size)
        else
            return love.graphics.newFont(size)
        end
    end

    return {
        ui_small = newFont(font_data.size_ui_small or 11),
        ui       = newFont(font_data.size_ui       or 13),
        heading  = newFont(font_data.size_heading  or 16),
        kpi      = newFont(font_data.size_kpi      or 28),
        hero     = newFont(font_data.size_hero     or 64),
    }
end

return FontService
