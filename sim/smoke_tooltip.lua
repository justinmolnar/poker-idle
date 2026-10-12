-- sim/smoke_tooltip.lua
--
-- The tooltip keeps clear of the pointer (services/Tooltip.setCursorClearance,
-- from services/PlayerCursor.extents): the chunky pixel pointer and its "?"
-- badge must never lie on the words.
--   extents  the pointer's reach is positive on every side the art has
--   below    the default spot is below the pointer's art, not 14 px down
--   above    flipped over an avoid rect, it clears the art above the hot spot
--   clamp    pushed up by the screen's bottom edge, it moves off the pointer
--   edge     in a corner where above does not fit, it goes beside
--
-- Standalone: `lua sim/smoke_tooltip.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local PlayerCursor = require("services.PlayerCursor")
local Tooltip      = require("services.Tooltip")
local F = Stub.font(16)
local fonts = { sm = F, md = F }

-- extents
local ext = PlayerCursor.extents(4)
c.ok(ext.right > 0 and ext.down > 0, ("the pointer reaches right and down (%d, %d)"):format(ext.right, ext.down))
c.ok(ext.left >= 0 and ext.up >= 0, "and never negatively")

local cur = { left = 8, up = 8, right = 40, down = 48 }
Tooltip.setCursorClearance(cur)
local function cursorRect(mx, my)
    return { x = mx - cur.left - 2, y = my - cur.up - 2, w = cur.left + cur.right + 4, h = cur.up + cur.down + 4 }
end
local function overlaps(t, r)
    return t.x < r.x + r.w and t.x + t.w > r.x and t.y < r.y + r.h and t.y + t.h > r.y
end
local function place(mx, my, avoid)
    Tooltip.setAvoid(avoid)
    Tooltip.pin({ "Your bankroll: the money you play with." }, mx, my)
    Tooltip.draw(fonts)
    return Tooltip.last
end

-- below
local t = place(400, 300)
c.ok(t and t.y >= 300 + cur.down, ("the default spot is below the pointer's art (y %s)"):format(t and t.y))
c.ok(t and not overlaps(t, cursorRect(400, 300)), "and clear of it")

-- above
t = place(400, 300, { x = 0, y = 340, w = 1600, h = 300 })
c.ok(t and t.y + t.h <= 300 - cur.up, ("over an avoid rect it goes above the art (bottom %s)"):format(t and t.y + t.h))
c.ok(t and not overlaps(t, cursorRect(400, 300)), "and clear of the pointer")
Tooltip.setAvoid(nil)

-- clamp
t = place(400, 890)
c.ok(t and not overlaps(t, cursorRect(400, 890)), "clamped at the bottom edge, it moves off the pointer")
c.ok(t and t.y + t.h <= 890 - cur.up, "above it")

-- edge: bottom-right corner with an avoid rect above — beside, not under
t = place(1500, 890, { x = 0, y = 0, w = 1600, h = 850 })
c.ok(t and not overlaps(t, cursorRect(1500, 890)), "in a corner with nowhere above, it goes beside the pointer")

if c.report("smoke_tooltip") > 0 then os.exit(1) end
