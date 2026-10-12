-- sim/story_copy/main.lua
--
-- `lovec sim/story_copy` from the repo root: runs sim/smoke_story_copy.lua
-- with LOVE's real font, so every House line is measured as the game
-- draws it. (Plain `lua sim/smoke_story_copy.lua` checks the data only.)

local src  = love.filesystem.getSource()
local root = src:gsub("[/\\]sim[/\\]story_copy[/\\]?$", "")
package.path = root .. "/?.lua;" .. package.path

-- The game's font lives outside this source dir: read it off the disk and
-- hand LOVE the bytes (love.filesystem only sees the source and save dirs).
local newFont = love.graphics.newFont
love.graphics.newFont = function(path, ...)
    if type(path) == "string" and not love.filesystem.getInfo(path) then
        local fh = io.open(root .. "/" .. path, "rb")
        if fh then
            local bytes = fh:read("*a"); fh:close()
            return newFont(love.filesystem.newFileData(bytes, path:match("[^/\\]+$")), ...)
        end
    end
    return newFont(path, ...)
end

function love.load()
    require("sim.smoke_story_copy")
end
