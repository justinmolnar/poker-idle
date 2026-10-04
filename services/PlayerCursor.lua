-- services/PlayerCursor.lua
--
-- Sets the player's mouse cursor to the chunky pixel arrow in
-- data/player_cursor.lua, as a hardware cursor (love.mouse.newCursor), so it
-- tracks the mouse with no frame of lag and draws over everything. Scaled
-- to the window height; apply() is called at load and on every resize, and
-- rebuilds only when the pixel size changes. Where the engine has no custom
-- cursors (love.js, the headless stub) the system arrow stays.

local Cfg = require("data.player_cursor")

local PlayerCursor = {}

local _px, _cursor = nil, nil

function PlayerCursor.pixelSize(window_h)
    local s = math.floor((window_h or 720) / 100 * Cfg.px_per_100h + 0.5)
    return math.max(Cfg.min_px, math.min(Cfg.max_px, s))
end

-- The cursor's ImageData at `px` screen pixels per art pixel.
function PlayerCursor.imageData(px)
    local rows = Cfg.rows
    local w, h = #rows[1] * px, #rows * px
    local data = love.image.newImageData(w, h)
    local o, f = Cfg.outline, Cfg.fill
    for ry, row in ipairs(rows) do
        for rx = 1, #row do
            local ch = row:sub(rx, rx)
            local c = (ch == "X" and o) or (ch == "#" and f) or nil
            if c then
                for yy = 0, px - 1 do
                    for xx = 0, px - 1 do
                        data:setPixel((rx - 1) * px + xx, (ry - 1) * px + yy, c[1], c[2], c[3], 1)
                    end
                end
            end
        end
    end
    return data
end

function PlayerCursor.apply()
    if not (love.mouse and love.mouse.newCursor and love.mouse.setCursor and love.image
            and love.image.newImageData) then return false end
    local px = PlayerCursor.pixelSize(love.graphics and love.graphics.getHeight and love.graphics.getHeight())
    if px == _px and _cursor then return true end
    local ok, cur = pcall(function() return love.mouse.newCursor(PlayerCursor.imageData(px), 0, 0) end)
    if not ok or not cur then return false end
    love.mouse.setCursor(cur)
    if _cursor and _cursor.release then _cursor:release() end
    _px, _cursor = px, cur
    return true
end

return PlayerCursor
