-- services/SpriteLoader.lua
-- Centralized sprite loading. Recursively scans assets/sprites/ for image
-- files at startup, caches each as a love.Image. Sprite names are the file
-- path relative to assets/sprites/ with the extension stripped — e.g.
-- assets/sprites/cards/fronts/clubs/a.png → "cards/fronts/clubs/a".
-- Optional aliases.json at the sprite root remaps lookup names.
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

-- LÖVE's image decoders. .gif is intentionally excluded — newImage doesn't
-- support animated GIFs and treating them as still frames is unreliable.
local SUPPORTED_EXTS = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }

function SpriteLoader:init()
    self.sprites = {}
    self.loaded = false
    self.aliases = nil
    self._warned_missing = {}
end

local function isSupported(filename)
    local ext = filename:match("%.([^%.]+)$")
    return ext and SUPPORTED_EXTS[ext:lower()] or false
end

local function stripExt(filename)
    return (filename:gsub("%.[^%.]+$", ""))
end

-- Recursive directory walk. Builds sprite names by joining the relative
-- path components with '/'. dir is "" for the root scan, "cards/" for a
-- nested call, etc.
function SpriteLoader:_scan(rel_dir)
    local full_dir = SPRITE_DIR .. rel_dir
    local items = love.filesystem.getDirectoryItems(full_dir)
    local count = 0
    for _, item in ipairs(items) do
        local item_path  = full_dir .. item
        local rel_path   = rel_dir .. item
        local info = love.filesystem.getInfo(item_path)
        if info then
            if info.type == "directory" then
                count = count + self:_scan(rel_path .. "/")
            elseif info.type == "file" and isSupported(item) then
                local sprite_name = stripExt(rel_path)
                local ok, image = pcall(love.graphics.newImage, item_path)
                if ok and image then
                    self.sprites[sprite_name] = image
                    count = count + 1
                end
            end
        end
    end
    return count
end

function SpriteLoader:loadAll()
    if self.loaded then return end

    print("[SpriteLoader] Scanning " .. SPRITE_DIR)

    if not love.filesystem.getInfo(SPRITE_DIR) then
        print("[SpriteLoader] " .. SPRITE_DIR .. " does not exist; no sprites loaded.")
        self.loaded = true
        return
    end

    local sprite_count = self:_scan("")
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
