-- sim/smoke_cursor.lua
--
-- services/PlayerCursor: the chunky pixel arrow is built from
-- data/player_cursor.lua at a size that follows the window height, with the
-- tip as its hot spot, black outline and white fill, set as the hardware
-- cursor, and rebuilt only when its pixel size changes.
--
-- Standalone: `lua sim/smoke_cursor.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()
local Cfg = require("data.player_cursor")

local width = #Cfg.rows[1]
local same = true
for _, r in ipairs(Cfg.rows) do if #r ~= width then same = false end end
c.ok(same, "every row of the art is " .. width .. " wide")

local made, set, hot = 0, 0, nil
local height = 1080
love.graphics.getHeight = function() return height end
love.image = { newImageData = function(w, h)
    local px = {}
    return { w = w, h = h, px = px,
             setPixel = function(self, x, y, r, g, b, a) px[y * w + x] = { r, g, b, a } end }
end }
local last
love.mouse.newCursor = function(data, hx, hy) made = made + 1; last = data; hot = { hx, hy }; return { release = function() end } end
love.mouse.setCursor = function() set = set + 1 end

local PC = require("services.PlayerCursor")
c.eq(PC.pixelSize(720), 2, "two screen pixels per art pixel at 720p")
c.eq(PC.pixelSize(1080), 3, "three at 1080p")
c.eq(PC.pixelSize(2160), Cfg.max_px, "capped at " .. Cfg.max_px)

c.ok(PC.apply(), "the cursor is applied")
c.ok(last and last.w == width * 3 and last.h == #Cfg.rows * 3, "the image is the art at 3x")
c.ok(hot and hot[1] == 0 and hot[2] == 0, "the hot spot is the tip")
local tip = last.px[0]
c.ok(tip and tip[1] == 0 and tip[4] == 1, "the tip is the black outline")
local fill = last.px[(2 * 3 + 1) * last.w + (1 * 3 + 1)]   -- art (2, 3): "#"
c.ok(fill and fill[1] == 1 and fill[2] == 1 and fill[3] == 1, "the body is white")
c.ok(last.px[0 * last.w + (5 * 3)] == nil, "clear pixels stay clear")

PC.apply()
c.eq(made, 1, "the same window size builds nothing new")
height = 720
PC.apply()
c.ok(made == 2 and set == 2 and last.w == width * 2, "a smaller window rebuilds it at 2x")

if c.report("smoke_cursor") > 0 then os.exit(1) end
