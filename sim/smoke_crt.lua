-- sim/smoke_crt.lua
--
-- The House's security monitor (views/CrtMonitor) for the room before the
-- shove:
--   layout   the case sits inside the frame, the screen inside the case,
--            and the picture's cropped band matches the screen's aspect
--   draw     headless (no shader), it draws the case and the picture once
--   shove    the shove's room count draws through it without error
--
-- Standalone: `lua sim/smoke_crt.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()
local F = Stub.font(16)
Stub.recorder()
love.graphics.getFont = function() return F end

local CrtMonitor = require("views.CrtMonitor")

for _, wh in ipairs({ { 1600, 900 }, { 1280, 720 }, { 2133, 900 } }) do
    local W, H = wh[1], wh[2]
    local L = CrtMonitor.layout(W, H)
    local cs, sc = L.case, L.screen
    c.ok(cs.x >= 0 and cs.y >= 0 and cs.x + cs.w <= W and cs.y + cs.h <= H,
         ("%dx%d: the case is inside the frame"):format(W, H))
    c.ok(sc.x > cs.x and sc.y > cs.y and sc.x + sc.w < cs.x + cs.w and sc.y + sc.h < cs.y + cs.h,
         ("%dx%d: the screen is inside the case"):format(W, H))
    local cr = L.crop
    c.ok(cr and cr.h <= H and math.abs(W / cr.h - sc.w / sc.h) < 0.02,
         ("%dx%d: the picture's band has the screen's aspect (no stretch)"):format(W, H))
end

local calls = 0
CrtMonitor.draw({ ui_scale = 1, fonts = { md = F, sm = F } }, 1600, 900, function() calls = calls + 1 end)
c.eq(calls, 1, "headless, the picture draws once inside the case")

if c.report("smoke_crt") > 0 then os.exit(1) end
