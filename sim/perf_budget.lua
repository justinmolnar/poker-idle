-- sim/perf_budget.lua
--
-- The allocation budget: how many KB of Lua garbage one frame of a busy
-- 22-table Zoom board makes, headless, with the real controller, the real
-- view and the recorder stub for love.graphics. The in-game HUD's
-- heap/frame reads a floor of this (a GC step hides the rise); here the
-- collector is stopped for the measured window, so the number is the
-- allocation itself.
--
-- Two figures, printed every run so the trend is visible in the output:
--   update   the controller tick alone (the model, the pool, the procs)
--   frame    a whole frame: hover/tooltip clear, the tick, the view's
--            update and draw (panels, sidebars, rail, floaters, piles)
-- and one check each against a budget. The budgets start where the
-- performance pass left them and are meant to be tightened, never
-- loosened: a number that climbs is the regression this file exists to
-- catch.
--
-- Standalone: `lua sim/perf_budget.lua` from the repo root. Exit code 1
-- when a budget is blown.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local H = require("sim.harness")
local F = Stub.font(16)
local w = H.world({ bankroll = 1e9 })
local g = w.game
local ctrl = w.ctrl
g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
g.state_machine = { states = {}, switch = function() end,
                    current = function() return "grind" end }
local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
              getDimensions = function() return 32, 32 end,
              setFilter = function() end, release = function() end }
g.sprite_loader = {
    getSprite = function() return img end, getSpriteFor = function() return img end,
    hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
    setSprite = function() end, itemArt = function() return img end,
}
Stub.recorder()
love.graphics.newFont = function() return F end
love.graphics.getFont = function() return F end

local HoverService = require("services.HoverService")
local Tooltip      = require("services.Tooltip")
local ClickFlash   = require("services.ClickFlash")
local GrindView    = require("views.GrindView")

-- The board: 22 NL100 Zooms under the focus cap (max Focus and the Swarm
-- deck at five, a 34-table capacity), so the hands run at the tables' own
-- pace; over the cap the focus slowdown would idle the board.
w:upgrade("focus", 5)
w:deck("swarm", 5)
for _ = 1, 22 do w:open("s003", "zoom") end
w:tick(1 / 60)
local view = GrindView:new(g, ctrl)

-- Cursors deal in the game; here every idle table is dealt each frame,
-- which is the busiest the board gets.
local function dealIdle()
    for i, t in ipairs(w:tables()) do
        if t.state == "idle" then ctrl:dealHand(i) end
    end
end

local function tick(dt)
    H.clock = H.clock + dt
    dealIdle()
    w.bus:beginFrame()
    ctrl:update(dt)
    w.bus:drain()
end

local function frame(dt)
    H.clock = H.clock + dt
    HoverService.clear()
    Tooltip.clear()
    ClickFlash.update(dt)
    dealIdle()
    w.bus:beginFrame()
    ctrl:update(dt)
    w.bus:drain()
    view:update(dt)
    view:draw(nil)
end

local STEP = 1 / 60

-- Warm up: every cache filled, every pool grown, the first hands settled.
for _ = 1, 240 do frame(STEP) end

local function measure(fn, n)
    collectgarbage("collect")
    collectgarbage("stop")
    local kb0 = collectgarbage("count")
    for _ = 1, n do fn(STEP) end
    local kb = collectgarbage("count") - kb0
    collectgarbage("restart")
    return kb / n
end

local N = 300
local upd_kb   = measure(tick, N)
for _ = 1, 30 do frame(STEP) end
local frame_kb = measure(frame, N)

-- Budgets (KB per frame). Tighten as phases land; never loosen.
local BUDGET_UPDATE = 40
local BUDGET_FRAME  = 250

print(("[perf_budget] 22 Zooms, %d frames each: update %.1f KB/frame, frame %.1f KB/frame (hands played %d)"):format(
    N, upd_kb, frame_kb, (function() local n = 0; for _, t in ipairs(w:tables()) do n = n + t.hands_played end; return n end)()))

local fails = 0
local function check(ok, msg)
    if not ok then fails = fails + 1; print("FAIL " .. msg) end
end
check(upd_kb <= BUDGET_UPDATE, ("update path allocates %.1f KB/frame, budget %d"):format(upd_kb, BUDGET_UPDATE))
check(frame_kb <= BUDGET_FRAME, ("a whole frame allocates %.1f KB/frame, budget %d"):format(frame_kb, BUDGET_FRAME))
print(("perf_budget: 2 checks, %d failures"):format(fails))
if fails > 0 then os.exit(1) end
