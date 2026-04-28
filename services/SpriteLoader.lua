-- services/SpriteLoader.lua
-- Centralized sprite loading. Scans assets/sprites/ for PNGs at startup,
-- caches each as a love.Image, supports optional alias-JSON for renaming.
--
-- API:
--   sl = SpriteLoader:new()
--   sl:loadAll()
--   sl:getSprite(name)         → love.Image | nil
--   sl:hasSprite(name)         → bool
--   sl:drawSprite(name, x, y, w, h, tint?)  -- falls back to a magenta rect

local Object = require('lib.class')
local Theme  = require('views.Theme')
local SpriteLoader = Object:extend('SpriteLoader')

local SPRITE_DIR  = "assets/sprites/"
local ALIASES_FILE = "assets/sprites/aliases.json"

function SpriteLoader:init()
    self.sprites = {}
    self.loaded = false
    self.aliases = nil
    self._warned_missing = {}
end

function SpriteLoader:loadAll()
    if self.loaded then return end

    print("[SpriteLoader] Scanning " .. SPRITE_DIR)

    if not love.filesystem.getInfo(SPRITE_DIR) then
        print("[SpriteLoader] " .. SPRITE_DIR .. " does not exist; no sprites loaded.")
        self.loaded = true
        return
    end

    local files = love.filesystem.getDirectoryItems(SPRITE_DIR)
    local sprite_count = 0

    for _, filename in ipairs(files) do
        local sprite_name = filename:match("^(.+)%.png$")
        if sprite_name and sprite_name ~= "" then
            self:loadSprite(sprite_name)
            sprite_count = sprite_count + 1
        end
    end

    self:loadAliases()

    print("[SpriteLoader] Loaded " .. sprite_count .. " sprites"
        .. (self.aliases and ", with aliases" or ""))
    self.loaded = true
end

function SpriteLoader:loadAliases()
    if not love.filesystem.getInfo(ALIASES_FILE) then return end
    local ok, contents = pcall(love.filesystem.read, ALIASES_FILE)
    if not ok or not contents then return end
    local json = require('lib.json')
    local ok2, data = pcall(json.decode, contents)
    if ok2 and type(data) == "table" and data.aliases then
        self.aliases = data.aliases
    end
end

function SpriteLoader:loadSprite(sprite_name)
    if self.sprites[sprite_name] then return end
    local file_path = SPRITE_DIR .. sprite_name .. ".png"
    local success, image = pcall(love.graphics.newImage, file_path)
    if success and image then
        self.sprites[sprite_name] = image
    end
end

local function _resolve(self, sprite_name)
    if self.aliases and self.aliases[sprite_name] then
        return self.aliases[sprite_name]
    end
    return sprite_name
end

function SpriteLoader:getSprite(sprite_name)
    if not self.loaded then self:loadAll() end
    return self.sprites[_resolve(self, sprite_name)]
end

function SpriteLoader:hasSprite(sprite_name)
    if not self.loaded then self:loadAll() end
    return self.sprites[_resolve(self, sprite_name)] ~= nil
end

-- Draw a sprite scaled into (x,y,w,h). If the sprite is missing, draws a
-- visibly wrong magenta+border rectangle so missing assets are loud.
function SpriteLoader:drawSprite(sprite_name, x, y, width, height, tint)
    local sprite = self:getSprite(sprite_name)

    if not sprite then
        if not self._warned_missing[sprite_name] then
            print(string.format('[SpriteLoader] MISSING sprite "%s"', tostring(sprite_name)))
            self._warned_missing[sprite_name] = true
        end
        Theme.setColor(Theme.debug.missing_fill)
        love.graphics.rectangle('fill', x, y, width, height)
        Theme.setColor(Theme.debug.missing_border)
        love.graphics.rectangle('line', x, y, width, height)
        return false
    end

    if tint then
        love.graphics.setColor(tint[1], tint[2], tint[3], tint[4] or 1)
    else
        Theme.assetTint()
    end

    local sw, sh = sprite:getWidth(), sprite:getHeight()
    love.graphics.draw(sprite, x, y, 0, width / sw, height / sh)
    return true
end

return SpriteLoader
