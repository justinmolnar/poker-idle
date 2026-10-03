-- sim/smoke_bar.lua
--
-- The outcome bar (views/OutcomeBar) and the upgrade preview:
--   segments  eight segments, as wide as their absolute chances, filling the
--             bar exactly; the win/loss split where the win chance says
--   tooltip   pot_control's and sharper_reads' tooltips carry a bar row
--             (custom measure/render) instead of the per-stake grids
--   preview   hovering an upgrade gives every table it moves a next-level
--             preview (tbl._preview), drawn as a live layer: no panel
--             rebuilds for it; un-hovering clears it
--   disabled  a disabled upgrade still reports hover (it previews)
--
-- Standalone: `lua sim/smoke_bar.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local OutcomeBar = require("views.OutcomeBar")

-- ── segments ────────────────────────────────────────────────────────────
do
    local stats = { win_chance = 0.6,
                    win_dist  = { small = 0.5, medium = 0.3, large = 0.15, stack = 0.05 },
                    loss_dist = { small = 0.6, medium = 0.25, large = 0.1, stack = 0.05 } }
    local segs = OutcomeBar.segments(stats, 0, 200)
    local total = 0
    for _, side in ipairs({ "loss", "win" }) do
        for _, t in ipairs({ "small", "medium", "large", "stack" }) do total = total + segs[side][t][2] end
    end
    c.eq(total, 200, "the eight segments fill the bar exactly")
    c.ok(math.abs(segs.win.small[1] - 80) <= 1, "the split sits at the loss share (40% of 200)")
    c.ok(segs.loss.stack[1] == 0, "the stack loss is the left edge")
    local sx, sw = OutcomeBar.segmentRect(stats, 0, 200, "win", "stack")
    c.ok(sx + sw == 200 and sw >= 1, "the stack win is the right edge")
end

-- ── a board ─────────────────────────────────────────────────────────────
local H = require("sim.harness")
local F = Stub.font(16)
local w = H.world({ bankroll = 1e9 })
local g = w.game
g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
g.state_machine = { states = {}, switch = function() end, current = function() return "grind" end }
local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
              getDimensions = function() return 32, 32 end, setFilter = function() end, release = function() end }
g.sprite_loader = { getSprite = function() return img end, getSpriteFor = function() return img end,
    hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
    setSprite = function() end, itemArt = function() return img end }
Stub.recorder()
love.graphics.newFont = function() return F end
love.graphics.getFont = function() return F end
love.graphics.newShader = function() return { send = function() end } end
for _ = 1, 3 do w:open("s001", "zoom") end
w:tick(1)
local HoverService = require("services.HoverService")
local Perf         = require("services.Perf")
local GrindView    = require("views.GrindView")
local RunUpgrades  = require("data.run_upgrades")
local Lookups      = require("utils.lookups")
local view = GrindView:new(g, w.ctrl)
g.sim_frozen = true
local function frame(pre)
    H.clock = H.clock + 1 / 60
    require("services.AnchorRegistry").tick()
    HoverService.clear()
    if pre then pre() end
    view:update(1 / 60)
    view:draw(nil)
    Perf.beginFrame(0)
end
Perf.setEnabled(true)
for _ = 1, 4 do frame() end

-- ── tooltip ─────────────────────────────────────────────────────────────
for _, id in ipairs({ "pot_control", "sharper_reads" }) do
    local up = Lookups.findById(RunUpgrades, id)
    local rows = view:_buildRangeTooltipUncached(up)
    local bar = false
    for _, r in ipairs(rows or {}) do
        if type(r) == "table" and r.measure and r.render then
            local bw, bh = r.measure(g.fonts)
            if bw > 50 and bh < 40 then bar = true end
        end
    end
    c.ok(bar, id .. "'s tooltip carries an odds bar row")
end

-- ── preview ─────────────────────────────────────────────────────────────
local hover = function() HoverService.set("button", "buy_runup_pot_control") end
frame(hover)
frame(hover)
local with = 0
for _, t in ipairs(w:tables()) do if t._preview then with = with + 1 end end
c.ok(with > 0, "hovering Pot Control previews on the tables it moves (" .. with .. ")")
frame(hover)
c.eq(Perf.counter("panel_rebuild"), 0, "the preview rebuilds no panel (a live layer)")
frame()
local left = 0
for _, t in ipairs(w:tables()) do if t._preview then left = left + 1 end end
c.eq(left, 0, "un-hovered, the preview is gone")

-- ── disabled ────────────────────────────────────────────────────────────
do
    local CR = require("views.ComponentRenderer")
    HoverService.clear()
    local comp = { type = "button", id = "buy_runup_test", disabled = true,
                   lines = { { text = "x", style = "small" } } }
    CR.hitTest({ comp }, 0, 200, 10, 10, g)
    c.ok(HoverService.is("button", "buy_runup_test"), "a disabled button still reports hover")
end

if c.report("smoke_bar") > 0 then os.exit(1) end
