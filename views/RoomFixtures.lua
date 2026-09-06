-- views/RoomFixtures.lua
--
-- The room's own fittings, baked into the sprite loader at boot through
-- the same wall bake THE HOUSE's print uses (HouseArt.bakeWallSprite):
-- painted flat, sheared onto the left-wall plane, downsampled, injected
-- under a sprite name so the layout places them like any kit sprite.
--
-- The light switch: a plate with a toggle, two states. `light_switch` is
-- the nub up (the fixture on); `light_switch_off` the nub down. RoomView
-- swaps the sprite by the view's fixture_off; RoomState flips it on click.

local Theme    = require("views.Theme")
local HouseArt = require("views.HouseArt")

local RoomFixtures = {}

local PLATE_W, PLATE_H = 10, 14   -- sprite pixels, flat

-- The flat plate: warm off-white with a darker edge, two screws, and the
-- toggle, up when on and down when off. fw/fh are the supersampled size;
-- ss the supersample, so one sprite pixel is ss canvas pixels.
local function paintPlate(off)
    return function(fw, fh, ss)
        local px = ss
        Theme.setColor({ 0.55, 0.50, 0.42 })
        love.graphics.rectangle("fill", 0, 0, fw, fh)
        Theme.setColor({ 0.90, 0.86, 0.76 })
        love.graphics.rectangle("fill", px, px, fw - 2 * px, fh - 2 * px)
        Theme.setColor({ 0.45, 0.42, 0.36 })
        love.graphics.rectangle("fill", math.floor(fw * 0.5) - px * 0.5, px * 1.5, px, px)
        love.graphics.rectangle("fill", math.floor(fw * 0.5) - px * 0.5, fh - px * 2.5, px, px)
        local nub_w, nub_h = 3 * px, 4 * px
        local nx = math.floor((fw - nub_w) * 0.5)
        local ny = off and math.floor(fh * 0.5) or (math.floor(fh * 0.5) - nub_h)
        Theme.setColor({ 0.30, 0.28, 0.24 })
        love.graphics.rectangle("fill", nx, ny, nub_w, nub_h)
        Theme.setColor(off and { 0.62, 0.58, 0.50 } or { 0.98, 0.95, 0.86 })
        love.graphics.rectangle("fill", nx + px * 0.5, ny + px * 0.5, nub_w - px, nub_h - px)
    end
end

function RoomFixtures.bake(sprite_loader)
    local a = HouseArt.bakeWallSprite(sprite_loader, "light_switch",     PLATE_W, PLATE_H, paintPlate(false))
    local b = HouseArt.bakeWallSprite(sprite_loader, "light_switch_off", PLATE_W, PLATE_H, paintPlate(true))
    return a and b
end

return RoomFixtures
