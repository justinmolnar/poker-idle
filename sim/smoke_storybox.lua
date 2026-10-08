-- sim/smoke_storybox.lua
--
-- The House's fixed text box (views/StoryView with the "story:box" anchor,
-- registered by the grind above the House's poster):
--   fixed   the box is exactly its rect, for a short line and a long one
--   small   it speaks in the small font
--   pages   a block longer than the box holds is cut into pages, and a
--           click turns the page (nextPage) before the story moves on
--   free    without the anchor the box is the old one, sized to its text
--
-- Standalone: `lua sim/smoke_storybox.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()
local F_SM, F_MD = Stub.font(14), Stub.font(20)
Stub.recorder()
love.graphics.getFont = function() return F_SM end
love.timer.getDelta = love.timer.getDelta or function() return 0.016 end

local Anchors   = require("services.AnchorRegistry")
local StoryView = require("views.StoryView")
local game = { fonts = { sm = F_SM, md = F_MD, lg = F_MD, xs = F_SM, micro = F_SM }, ui_scale = 1 }
local sv = StoryView:new(game)

local BOX = { 900, 400, 300, 90 }
local function frame(line)
    Anchors.tick()
    Anchors.set("story:box", BOX[1], BOX[2], BOX[3], BOX[4])
    Anchors.set("story:band", 0, 600, 1200, 40)
    sv:draw(line, { holding = true })
    return sv.band_rect
end

local short = { text = "Deal.", beat = "t", index = 1 }
local r1 = frame(short)
c.ok(r1 and r1.x == BOX[1] and r1.y == BOX[2] and r1.w == BOX[3] and r1.h == BOX[4],
     "a short line fills exactly the fixed box")

local long_text = ("Every table you open is another mouth to feed and another chance to lose. "):rep(6)
local long = { text = long_text, beat = "t", index = 2 }
local r2 = frame(long)
c.ok(r2 and r2.x == BOX[1] and r2.y == BOX[2] and r2.w == BOX[3] and r2.h == BOX[4],
     "a long line is the same box, not a bigger one")
c.ok(#sv._reveal.pages > 1, "a long line is cut into pages (" .. #sv._reveal.pages .. ")")
sv:revealAll()
local pages = #sv._reveal.pages
local turned = 0
while sv:nextPage() do
    turned = turned + 1
    local r = frame(long)
    c.ok(r.y == BOX[2] and r.h == BOX[4], "page " .. (turned + 1) .. " is the same box")
    sv:revealAll()
end
c.eq(turned, pages - 1, "a click turns each page until the last")
c.ok(not sv:nextPage(), "on the last page a click goes to the story")

-- Without the fixed anchor: the old free panel.
Anchors.tick()
local function freeFrame(line)
    Anchors.tick()
    Anchors.set("story:band", 0, 600, 1200, 40)
    for _ = 1, 3 do Anchors.tick() end
    Anchors.set("story:band", 0, 600, 1200, 40)
    sv:draw(line, { holding = true })
    return sv.band_rect
end
local fr = freeFrame({ text = "Deal.", beat = "u", index = 1 })
c.ok(fr and fr.w ~= BOX[3], "without the box the panel is the free one")

if c.report("smoke_storybox") > 0 then os.exit(1) end
