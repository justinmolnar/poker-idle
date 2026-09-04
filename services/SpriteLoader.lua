-- services/SpriteLoader.lua
-- Centralized sprite loading + lookup. Recursively scans assets/sprites/
-- for image files at startup, caches each as a love.Image. Sprite names
-- are the file path relative to assets/sprites/ with the extension
-- stripped — e.g. assets/sprites/cards/fronts/clubs/a.png →
-- "cards/fronts/clubs/a". Optional aliases.json at the sprite root remaps
-- lookup names.
--
-- The atlas is intentionally rendering-free; sprite drawing lives in
-- services/SpriteRenderer (load+lookup vs. draw is split into two small
-- modules with a clean atlas → renderer dependency).
--
-- API:
--   sl = SpriteLoader:new()
--   sl:loadAll()
--   sl:getSprite(name)  → love.Image | nil
--   sl:getSpriteFor(name, target_w) → love.Image | nil  (mip level for a
--                         given draw width; see the card-art block below)
--   sl:hasSprite(name)  → bool

local Object = require('lib.class')
local Constants = require('data.constants')
local Motion = require("services.Motion")
local SpriteLoader = Object:extend('SpriteLoader')

local SPRITE_DIR  = "assets/sprites"
local ALIASES_FILE = "assets/sprites/aliases.json"

-- Trailing slashes on dir paths cause love.filesystem.getDirectoryItems
-- to return an empty-string entry under the fused-zip backend, which
-- self-recurses to stack overflow. Always join without a trailing slash.
local function joinPath(a, b)
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end

-- LÖVE's image decoders. .gif is NOT supported — newImage() can't decode
-- it (animated or static), so we don't pretend. Convert any decorative
-- GIF to PNG on disk before referencing it.
local SUPPORTED_EXTS = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }

-- ── Card art post-processing ─────────────────────────────────
-- The whole game is nearest-filtered pixel art (services/FontService sets it
-- explicitly on every face) except the cards, which nothing ever touched, so
-- they inherited LOVE's default linear/linear. Magnification goes nearest here
-- so big cards are pixel-exact (hole cards at a single table land at exactly
-- 2x native and used to come out soft); minification stays linear so small
-- ones still average.
--
-- Card BACKS get more than that: a mip CHAIN, built once at load.
--
-- Backs ship at 144x192 but are never drawn above ~110px, and on the felt they
-- land at 9-51px. One 2x2 bilinear tap out of a 16x16 footprint PICKS a texel
-- rather than averaging, which is why opponent seats read as noise. Decks are
-- bought content and have to stay recognisable at every size, so rather than
-- hiding them the loader keeps four levels (112x160 down to 14x20) and
-- getSpriteFor picks the smallest one still at least as wide as the draw. That
-- caps minification at under 2:1 anywhere on the felt, and the 112 level keeps
-- the shove gauntlet (which draws backs at ~110px) essentially 1:1.
--
-- Each level is a HALVING of the one above, so every step is a true box
-- average instead of a point sample. Deliberately NOT GPU mipmaps: 144x192 is
-- non-power-of-two and the love.js web build may refuse to generate them,
-- which would leave the itch build broken with no way to see it from here.
local CARD_PREFIX = "cards/"
local BACK_PREFIX = "cards/backs/"
local BACK_W, BACK_H = 112, 160
local BACK_MIN_W     = 14      -- smallest chain level. The tightest the felt
                               -- ever gets is a ~9px opponent card at 32
                               -- tables, which this level serves at 1.6:1

local function applyCardFilter(image)
    -- (min, mag): linear down, nearest up.
    pcall(image.setFilter, image, "linear", "nearest")
end

-- Resample `image` to (w, h) through a canvas and bake the result back into a
-- plain Image, so nothing downstream has to care that this sprite was
-- resampled and the render target is released. Returns nil if any part of the
-- canvas path is unavailable (headless tooling, a driver without render
-- targets) so callers keep what they had rather than losing the sprite.
local function resample(image, w, h)
    local sw, sh = image:getWidth(), image:getHeight()
    if sw <= 0 or sh <= 0 or w <= 0 or h <= 0 then return nil end

    local ok, canvas = pcall(love.graphics.newCanvas, w, h)
    if not ok or not canvas then return nil end

    local prev_canvas = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, 0, 0, 0, w / sw, h / sh)
    love.graphics.setCanvas(prev_canvas)
    love.graphics.pop()

    -- Canvas → ImageData: love.graphics.readbackTexture on 12, the
    -- Canvas method on 11 (12 deprecates it).
    local snap_ok, data = pcall(function()
        if love.graphics.readbackTexture then return love.graphics.readbackTexture(canvas) end
        return canvas:newImageData()
    end)
    if not snap_ok or not data then return nil end
    local img_ok, img = pcall(love.graphics.newImage, data)
    if not img_ok or not img then return nil end
    applyCardFilter(img)
    return img
end

-- Levels for one card back, largest first. Level 1 is the source normalised to
-- BACK_W; each subsequent level halves it. Always returns at least one level.
local function buildBackChain(image)
    local levels = {}
    local top = image
    if top:getWidth() ~= BACK_W then
        top = resample(image, BACK_W, BACK_H) or image
    end
    levels[1] = top

    local w, h = top:getWidth(), top:getHeight()
    while math.floor(w / 2) >= BACK_MIN_W do
        w, h = math.floor(w / 2), math.floor(h / 2)
        local level = resample(levels[#levels], w, h)
        if not level then break end
        levels[#levels + 1] = level
    end
    return levels
end

function SpriteLoader:init()
    self.sprites = {}
    self.animations = {}
    self.animation_paths = {}   -- name -> { sprite key per frame } (file-per-frame groups only)
    self.strips = {}        -- sprite name -> cells of a side-by-side sheet
    self.loaded = false
    self.aliases = nil
    -- sprite name -> { Image, ... } largest first. Only card backs build one;
    -- getSpriteFor falls back to the plain sprite for everything else.
    self.lods = {}
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
-- A sheet of N square cells laid side by side (width = N * height, N >= 3)
-- is a strip; returns its cells as Images, or nil for a plain sprite.
function SpriteLoader:_sliceStrip(item_path)
    local ok, data = pcall(love.image.newImageData, item_path)
    if not ok or not data then return nil end
    local w, h = data:getWidth(), data:getHeight()
    if h <= 0 or w % h ~= 0 or w / h < 3 then return nil end
    local frames = {}
    for i = 0, w / h - 1 do
        local cell = love.image.newImageData(h, h)
        cell:paste(data, 0, 0, i * h, 0, h, h)
        local img = love.graphics.newImage(cell)
        pcall(img.setFilter, img, "nearest", "nearest")
        frames[#frames + 1] = img
    end
    return frames
end

function SpriteLoader:_scan(rel_dir)
    local full_dir = joinPath(SPRITE_DIR, rel_dir)
    local items = love.filesystem.getDirectoryItems(full_dir)
    local count = 0
    for _, item in ipairs(items) do
        if item ~= "" and item ~= "." and item ~= ".." then
            local item_path = joinPath(full_dir, item)
            local rel_path  = joinPath(rel_dir, item)
            local info = love.filesystem.getInfo(item_path)
            if info then
                if info.type == "directory" then
                    count = count + self:_scan(rel_path)
                elseif info.type == "file" and isSupported(item) then
                    local sprite_name = stripExt(rel_path)
                    local is_card = sprite_name:sub(1, #CARD_PREFIX) == CARD_PREFIX
                    local frames = (not is_card) and self:_sliceStrip(item_path) or nil
                    if frames then
                        -- A strip (Door_2_Brown.png is 5 cells of 128x128):
                        -- the cells are the frames. _buildAnimations turns
                        -- them into a sequence, so the room, the catalog
                        -- and the frame/anim keys all see a normal
                        -- animated sprite instead of the whole strip.
                        self.strips[sprite_name] = frames
                        self.sprites[sprite_name] = frames[1]
                        count = count + 1
                    else
                        local ok, image = pcall(love.graphics.newImage, item_path)
                        if ok and image then
                            if is_card then
                                image = self:_conditionCard(sprite_name, image)
                            else
                                pcall(image.setFilter, image, "nearest", "nearest")
                            end
                            self.sprites[sprite_name] = image
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count
end

function SpriteLoader:scanDirectory(dir_path, key_prefix)
    if not love.filesystem.getInfo(dir_path) then return 0 end
    local items = love.filesystem.getDirectoryItems(dir_path)
    local count = 0
    for _, item in ipairs(items) do
        if item ~= "" and item ~= "." and item ~= ".." then
            local item_path = dir_path .. "/" .. item
            local info = love.filesystem.getInfo(item_path)
            if info then
                if info.type == "directory" then
                    count = count + self:scanDirectory(item_path, key_prefix .. item .. "/")
                elseif info.type == "file" and isSupported(item) then
                    local name = stripExt(item)
                    local sprite_name = key_prefix .. name
                    local ok, image = pcall(love.graphics.newImage, item_path)
                    if ok and image then
                        if sprite_name:sub(1, #CARD_PREFIX) == CARD_PREFIX then
                            image = self:_conditionCard(sprite_name, image)
                        else
                            pcall(image.setFilter, image, "nearest", "nearest")
                        end
                        self.sprites[sprite_name] = image
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

function SpriteLoader:_buildAnimations()
    self.animations = {}
    local groups = {}

    for key, img in pairs(self.sprites) do
        if not key:find("cards/") then
            local base_prefix, frame_num = key:match("^(.-)[%-_]Frame[%-_]?(%d+)$")
            if not frame_num then
                base_prefix, frame_num = key:match("^(.-)[%-_](%d+)$")
            end
            if not frame_num then
                base_prefix, frame_num = key:match("^(.-)[%-_/](%d+)$")
            end
            if not frame_num then
                base_prefix, frame_num = key:match("^(.-)[%-_](%a)$")
            end

            if base_prefix and frame_num then
                local num = tonumber(frame_num) or frame_num:byte()
                groups[base_prefix] = groups[base_prefix] or {}
                table.insert(groups[base_prefix], { num = num, key = key, img = img })
            end
        end
    end

    local anim_count = 0
    for name, frames in pairs(self.strips or {}) do
        self.animations[name] = frames
        anim_count = anim_count + 1
    end
    for base_prefix, frames in pairs(groups) do
        if #frames >= 2 then
            table.sort(frames, function(a, b) return a.num < b.num end)
            local seq = {}
            for _, f in ipairs(frames) do
                table.insert(seq, f.img)
            end

            self.animations[base_prefix] = seq
            local keys = {}
            for i, f in ipairs(frames) do keys[i] = f.key end
            self.animation_paths[base_prefix] = keys
            for _, f in ipairs(frames) do
                self.animations[f.key] = seq
                self.animation_paths[f.key] = keys
            end
            anim_count = anim_count + 1
        end
    end
    print("[SpriteLoader] Built " .. anim_count .. " animation sequences")
end

function SpriteLoader:loadAll()
    if self.loaded then return end

    local sprite_count = 0

    -- Scan assets/sprites
    print("[SpriteLoader] Scanning " .. SPRITE_DIR)
    if love.filesystem.getInfo(SPRITE_DIR) then
        sprite_count = sprite_count + self:_scan("")
    end

    self:loadAliases()
    self:_buildAnimations()

    print("[SpriteLoader] Loaded " .. sprite_count .. " total sprites"
        .. (self.aliases and ", with aliases" or ""))
    self.loaded = true
end

-- Inject a runtime-generated Image under a sprite name (procedural art
-- baked at boot, e.g. views/HouseArt's wall poster). Loads the disk
-- sprites first so a later lazy loadAll can't clobber the injection.
function SpriteLoader:setSprite(name, image)
    if not self.loaded then self:loadAll() end
    self.sprites[name] = image
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

-- Nearest-first filtering for every card, plus a mip chain for the backs.
-- Returns the image to store under `sprite_name` (the chain's top level when
-- there is one, so existing getSprite callers keep working unchanged).
function SpriteLoader:_conditionCard(sprite_name, image)
    if sprite_name:sub(1, #BACK_PREFIX) == BACK_PREFIX then
        local ok, levels = pcall(buildBackChain, image)
        if ok and levels and #levels > 0 then
            self.lods[sprite_name] = levels
            image = levels[1]
        end
    end
    applyCardFilter(image)
    return image
end

local function _resolve(self, sprite_name)
    if self.aliases and self.aliases[sprite_name] then
        return self.aliases[sprite_name]
    end
    return sprite_name
end

function SpriteLoader:getSprite(sprite_name, time, fps, frame)
    if not self.loaded then self:loadAll() end
    -- Motion: below High, animated art holds its first frame.
    if time ~= false and Motion.level("shine") <= Motion.MEDIUM then time = false end
    local resolved = _resolve(self, sprite_name)
    local anim = self.animations[resolved] or self.animations[sprite_name]

    if time == false then
        if anim and #anim > 0 then
            local static_idx = math.max(1, math.min(#anim, math.floor(frame or 1)))
            return anim[static_idx]
        end
        return self.sprites[resolved]
    end

    if anim and #anim > 0 then
        if time == nil or time == true then
            time = love.timer and love.timer.getTime() or 0
        end
        if type(time) == "number" then
            local anim_config = Constants and Constants.ANIMATIONS
            local default_fps = (anim_config and anim_config.DEFAULT_FPS) or 4
            local item_fps    = anim_config and anim_config.ITEM_FPS
            fps = fps or (item_fps and (item_fps[sprite_name] or item_fps[resolved])) or default_fps

            local frame_idx = (math.floor(time * fps) % #anim) + 1
            return anim[frame_idx]
        end
    end
    return self.sprites[resolved]
end

-- Lookup that knows about mip chains: hands back the smallest level still at
-- least as wide as `target_w`, so a card back drawn at 9px comes off a 28px
-- level instead of a 16:1 minification of a 144px one. Falls through to
-- getSprite for every sprite without a chain, which is all of them but the
-- card backs. Called by services/SpriteRenderer, so no draw site changes.
function SpriteLoader:getSpriteFor(sprite_name, target_w, time, fps, frame)
    if not self.loaded then self:loadAll() end
    local resolved = _resolve(self, sprite_name)
    local levels = self.lods[resolved]
    if not levels then return self:getSprite(sprite_name, time, fps, frame) end
    for i = #levels, 1, -1 do
        if levels[i]:getWidth() >= (target_w or 0) then return levels[i] end
    end
    return levels[1]
end

function SpriteLoader:hasSprite(sprite_name)
    if not self.loaded then self:loadAll() end
    local resolved = _resolve(self, sprite_name)
    return self.sprites[resolved] ~= nil or self.animations[resolved] ~= nil
end

return SpriteLoader
