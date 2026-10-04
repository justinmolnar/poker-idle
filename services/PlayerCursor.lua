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

-- The art with its rim: one pixel of `rim` around the outline on every
-- side ("O"), the grid grown by one each way. Built once.
local _art
local function art()
    if _art then return _art end
    local rows = Cfg.rows
    local w, h = #rows[1] + 2, #rows + 2
    local g = {}
    for y = 1, h do
        g[y] = {}
        for x = 1, w do
            local r = rows[y - 1]
            g[y][x] = (r and x > 1 and x <= w - 1) and r:sub(x - 1, x - 1) or "."
        end
    end
    if Cfg.rim then
        local out = {}
        for y = 1, h do
            out[y] = {}
            for x = 1, w do
                local ch = g[y][x]
                if ch == "." then
                    for dy = -1, 1 do
                        for dx = -1, 1 do
                            local n = g[y + dy] and g[y + dy][x + dx]
                            if n == "X" then ch = "O" end
                        end
                    end
                end
                out[y][x] = ch
            end
        end
        g = out
    end
    _art = { grid = g, w = w, h = h }
    return _art
end
PlayerCursor.art = art

-- The cursor's ImageData at `px` screen pixels per art pixel, and the hot
-- spot (the tip, inside the rim).
function PlayerCursor.imageData(px)
    local a = art()
    local data = love.image.newImageData(a.w * px, a.h * px)
    local colors = { X = Cfg.outline, ["#"] = Cfg.fill, O = Cfg.rim }
    for y = 1, a.h do
        for x = 1, a.w do
            local c = colors[a.grid[y][x]]
            if c then
                for yy = 0, px - 1 do
                    for xx = 0, px - 1 do
                        data:setPixel((x - 1) * px + xx, (y - 1) * px + yy, c[1], c[2], c[3], 1)
                    end
                end
            end
        end
    end
    return data, px, px
end

function PlayerCursor.apply()
    if not (love.mouse and love.mouse.newCursor and love.mouse.setCursor and love.image
            and love.image.newImageData) then return false end
    local px = PlayerCursor.pixelSize(love.graphics and love.graphics.getHeight and love.graphics.getHeight())
    if px == _px and _cursor then return true end
    local ok, cur = pcall(function()
        local data, hx, hy = PlayerCursor.imageData(px)
        return love.mouse.newCursor(data, hx, hy)
    end)
    if not ok or not cur then return false end
    love.mouse.setCursor(cur)
    if _cursor and _cursor.release then _cursor:release() end
    _px, _cursor = px, cur
    return true
end

return PlayerCursor
