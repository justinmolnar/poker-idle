-- models/sprite_manifest.lua
--
-- Which sprite names the game's own data names, and which of those have to
-- be decoded before a screen opens.
--
-- The loader indexes every file on disk but decodes none of them: most of
-- the furniture kit is never placed, and decoding all of it spent the whole
-- boot on art nothing draws. So something has to say what IS on screen the
-- moment a screen opens. That list is game knowledge — the catalog, the
-- room layout, the icons, the decks, the tile kit the room opens with — so
-- it lives here rather than inline in main.lua, where nothing headless
-- could reach it. services/SpriteLoader stays ignorant of game data and
-- just takes a list.
--
-- Engine-agnostic: pure data reads, no love calls.

local M = {}

-- Every name reachable from data/, in the order the boot decode wants them.
-- Duplicates are fine; the loader's cache makes the second ask free.
function M.onScreenAtBoot()
    local wanted = {}
    local function want(n) if type(n) == "string" then wanted[#wanted + 1] = n end end

    for _, item in ipairs(require("data.catalog")) do want(item.sprite or item.id) end

    local Layout = require("data.room_layout")
    for id, info in pairs(Layout) do
        if id ~= "__meta" then
            want(id)
            if type(info) == "table" then want(info.sprite) end
        end
    end

    for _, spec in pairs(require("data.icons")) do
        if type(spec) == "table" then want(spec.sprite) end
    end

    -- The tiles the room actually opens with, by name from the layout's own
    -- meta rather than a guess: the kit's themes are things like
    -- "ArmyGreen" and "BeigeYellow", so an invented name would preload
    -- nothing and the floor would pop in. Floor and wall themes are
    -- separate namespaces in the kit — there is a Floor_128_BrownDark and a
    -- Wall_L_128_Bone, and no crossing.
    local Tiles  = require("data.room_tiles")
    local meta   = Layout.__meta or {}
    local set    = meta.tile_set or Tiles.default_set
    local folder = string.format(Tiles.folder, set)
    if meta.floor_theme and meta.floor_theme ~= "Default" then
        want(folder .. string.format(Tiles.floor_name, set, meta.floor_theme))
    end
    if meta.wall_theme and meta.wall_theme ~= "Default" then
        want(folder .. string.format(Tiles.wall_l_name, set, meta.wall_theme))
        want(folder .. string.format(Tiles.wall_r_name, set, meta.wall_theme))
    end

    for _, spec in ipairs(require("data.decks") or {}) do
        if type(spec) == "table" then want(spec.sprite) end
    end

    return wanted
end

return M
