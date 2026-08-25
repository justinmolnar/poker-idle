-- services/SoundLoader.lua
--
-- Discovers sound files the way services/SpriteLoader discovers sprites:
-- everything under assets/audio/ becomes a sound named by its path without
-- the extension ("items/rubber_duck", "Doors/Door_2_Brown"). Nothing is
-- declared; dropping a file in pairs it with whatever shares its name.
--
-- Lookup (`resolve`) is by full name first, then by the last path segment
-- when that is unique ("rubber_duck" finds "items/rubber_duck"), and it
-- follows sprite aliases when given them, so a name that reaches a sprite
-- reaches the sound stored beside it too. Returns the file path for
-- SoundService to play, or nil.
--
-- Folders named `raw` are skipped (unprocessed sources kept beside the
-- finished files). Scanning is the only love.* use (filesystem), the same
-- allowance SpriteLoader has. Playback lives in SoundService.

local Object = require('lib.class')
local SoundLoader = Object:extend('SoundLoader')

local AUDIO_DIR = "assets/audio"
local EXTS = { mp3 = true, ogg = true, wav = true, flac = true }

local function joinPath(a, b)
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end

local function stripExt(name)
    return (name:gsub("%.[%w]+$", ""))
end

local function ext(name)
    return name:match("%.(%w+)$")
end

function SoundLoader:init(dir)
    self.dir    = dir or AUDIO_DIR
    self.paths  = {}     -- full name -> file path
    self.bases  = {}     -- last segment -> full name, or false when ambiguous
    self.loaded = false
end

function SoundLoader:_scan(rel_dir)
    local full_dir = joinPath(self.dir, rel_dir)
    local items = love.filesystem.getDirectoryItems(full_dir)
    local count = 0
    for _, item in ipairs(items) do
        local item_path = joinPath(full_dir, item)
        local rel_path  = joinPath(rel_dir, item)
        local info = love.filesystem.getInfo(item_path)
        if info then
            if info.type == "directory" then
                -- `raw/` holds source cuts beside their finished files;
                -- scanning it would make every basename ambiguous.
                if item ~= "raw" then
                    count = count + self:_scan(rel_path)
                end
            elseif info.type == "file" and EXTS[(ext(item) or ""):lower()] then
                local name = stripExt(rel_path)
                self.paths[name] = item_path
                local base = name:match("([^/]+)$")
                if self.bases[base] == nil then
                    self.bases[base] = name
                elseif self.bases[base] ~= name then
                    self.bases[base] = false      -- two files share a basename
                end
                count = count + 1
            end
        end
    end
    return count
end

function SoundLoader:loadAll()
    if self.loaded then return end
    local n = 0
    if love.filesystem.getInfo(self.dir) then
        n = self:_scan("")
    end
    self.loaded = true
    print("[SoundLoader] Discovered " .. n .. " sound files under " .. self.dir)
end

-- The file for a name, or nil. `aliases` (optional) is the sprite alias
-- table: a name that aliases to a sprite path finds a sound at that path.
function SoundLoader:resolve(name, aliases)
    if not name then return nil end
    if not self.loaded then self:loadAll() end
    local direct = self.paths[name]
    if direct then return direct end
    local base = name:match("([^/]+)$")
    local via_base = base and self.bases[base]
    if via_base then return self.paths[via_base] end
    if aliases and aliases[name] and aliases[name] ~= name then
        return self:resolve(aliases[name], nil)
    end
    return nil
end

function SoundLoader:has(name, aliases)
    return self:resolve(name, aliases) ~= nil
end

return SoundLoader
