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
local A = PC.art()
c.eq(PC.pixelSize(720), 3, "three screen pixels per art pixel at 720p")
c.eq(PC.pixelSize(1080), 4, "four at 1080p")
c.eq(PC.pixelSize(2160), Cfg.max_px, "capped at " .. Cfg.max_px)
c.ok(A.w == width + 2 and A.h == #Cfg.rows + 2, "the rim grows the art by one on every side")
c.eq(A.grid[1][1], "O", "the rim wraps the tip")

c.ok(PC.apply(), "the cursor is applied")
c.ok(last and last.w == A.w * 4 and last.h == A.h * 4, "the image is the art at 4x")
c.ok(hot and hot[1] == 4 and hot[2] == 4, "the hot spot is the tip, inside the rim")
local function at(ax, ay) return last.px[((ay - 1) * 4) * last.w + (ax - 1) * 4] end
local tip, rim, fill = at(2, 2), at(1, 1), at(3, 4)
c.ok(tip and tip[1] == 0 and tip[4] == 1, "the tip is the black outline")
c.ok(rim and rim[1] == 1 and rim[2] == 1 and rim[3] == 1, "the rim is white")
c.ok(fill and fill[1] == Cfg.fill[1] and fill[3] == Cfg.fill[3], "the body is the fill colour")
c.ok(at(12, 2) == nil, "clear pixels stay clear")

PC.apply()
c.eq(made, 1, "the same window size builds nothing new")
height = 720
PC.apply()
c.ok(made == 2 and set == 2 and last.w == A.w * 3, "a smaller window rebuilds it at 3x")

if c.report("smoke_cursor") > 0 then os.exit(1) end
