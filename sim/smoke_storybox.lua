-- sim/smoke_storybox.lua
--
-- The House's fixed text box (views/StoryView with the "story:box" anchor,
-- registered by the grind above the House's poster):
--   fixed   the box is exactly its rect, for a short line and a long one
--   small   it speaks in the small font
--   pages   a block longer than the box holds is cut into pages, and a
--           click turns the page (nextPage) before the story moves on
--   screens on a screen with no grind the box is the same computed rect
--   breaks  a newline is a line, {page} a page, and a page keeps its breaks
--   cues    a click line says click; a forced line names its action
--   pulse   a block records its landing for the border pulse
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

-- A newline is a line; {page} is a page; a page keeps its breaks.
do
    local l = { text = "Payouts come in many sizes.\n{w:small} {w:stack}\nKeep playing.", beat = "nl", index = 1 }
    frame(l)
    sv:revealAll()
    local rv = sv._reveal
    c.eq(#rv.pages, 1, "three short lines fit one page")
    local n = select(2, rv.pages[1]:gsub("\n", ""))
    c.eq(n, 2, "the page keeps its two line breaks")
    local l2 = { text = "First page.{page}Second page.", beat = "pg", index = 1 }
    frame(l2)
    c.eq(#sv._reveal.pages, 2, "{page} ends a page")
    c.eq(sv._reveal.pages[1], "First page.", "the first page is what came before {page}")
    sv:revealAll()
    c.ok(sv:nextPage() and sv._reveal.pages[sv._reveal.page] == "Second page.", "the click turns to the second page")
end

-- The bottom row: a click line says click; a forced line says its cue.
do
    local texts
    local orig_print = love.graphics.print
    love.graphics.print = function(t, ...) if type(t) == "string" then texts[t] = true end end
    local function printed(line)
        frame(line)
        sv:revealAll()
        texts = {}
        frame(line)
        return texts
    end
    local t1 = printed({ text = "Deal.", beat = "cue", index = 1 })
    c.ok(t1["click anywhere to continue"], "a click line shows the continue cue")
    local t2 = printed({ text = "Deal.", beat = "cue", index = 2, forced = true, cue = "Deal" })
    c.ok(t2["Deal"] and not t2["click anywhere to continue"], "a forced line shows its own cue instead")
    local t3 = printed({ text = "Deal.", beat = "cue", index = 3, forced = true })
    c.ok(t3["Your move"], "a forced line with no cue says Your move")
    love.graphics.print = orig_print
end

-- The landing pulse decays.
do
    local Motion = require("services.Motion")
    local t0 = 100
    love.timer.getTime = function() return t0 end
    local l = { text = "Hello.", beat = "pulse", index = 1 }
    frame(l)
    local landed = sv._reveal.landed
    c.ok(landed == t0, "a block records when it landed")
    love.timer.getTime = function() return t0 + 2 end
    frame(l)
    c.ok(sv._reveal.landed == t0, "the landing time holds while the block is up (the pulse has decayed)")
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

-- Another screen (no grind, no "story:box" anchor): the same box, the
-- same place, computed for the window.
for _ = 1, 3 do Anchors.tick() end
Anchors.set("story:band", 0, 600, 1200, 40)
sv:draw({ text = "Deal.", beat = "u", index = 1 }, { holding = true })
local want = require("views.GrindView").storyBoxRect(game)
local got = sv.band_rect
c.ok(got and got.x == want.x and got.y == want.y and got.w == want.w and got.h == want.h,
     "on another screen the box is the same rect the grind gives it")

-- The hover lesson's tooltip: visible only once drawn; held while the next
-- line explains it; released on the click that moves on.
do
    local Tooltip = require("services.Tooltip")
    local clock = 0
    love.timer.getTime = function() return clock end
    local F2 = Stub.font(16)
    c.ok(not Tooltip.visible(), "no tooltip drawn, none visible")
    for _ = 1, 30 do Tooltip.set({ "Odds at every size." }, 100, 100); clock = clock + 0.05 end
    Tooltip.draw({ sm = F2, md = F2 })
    c.ok(Tooltip.visible(), "a drawn tooltip is visible")
    c.ok(Tooltip.hold(), "it can be held")
    clock = clock + 5
    Tooltip.draw({ sm = F2, md = F2 })          -- no set() this frame: the pointer left
    c.ok(Tooltip.visible(), "the held tooltip stays up with the pointer gone")
    Tooltip.release()
    clock = clock + 5
    Tooltip.draw({ sm = F2, md = F2 })
    c.ok(not Tooltip.visible(), "released, it goes")
end

if c.report("smoke_storybox") > 0 then os.exit(1) end
