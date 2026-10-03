-- sim/smoke_bar.lua
--
-- The outcome bar (views/OutcomeBar) and the upgrade preview:
--   segments  eight segments, as wide as their absolute chances, filling the
--             bar exactly; the win/loss split where the win chance says
--   tooltip   pot_control's and sharper_reads' tooltips name the stakes
--             they move ("Affects: NL2"), no graph
--   preview   hovering an upgrade gives every table it moves its own
--             metric, now and next (tbl._preview.text: "Win" for Sharper
--             Reads, "Stack win" for Pot Control), drawn as a live layer:
--             no panel rebuilds for it; un-hovering clears it
--   rows      an add-table row you can't afford has no bar
--   ease      the bar eases toward new odds instead of jumping
--   throttle  the streak multiplier reaches the readouts once a second
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
    local affects = false
    for _, r in ipairs(rows or {}) do
        if type(r) == "table" and type(r.text) == "string" and r.text:find("^Affects: NL2") then affects = true end
    end
    c.ok(affects, id .. "'s tooltip names the stakes it moves")
end

-- ── preview ─────────────────────────────────────────────────────────────
-- Hovered the way the game does it: the mouse on the button, hover cleared
-- at the top of the frame and reported by the view's own hit test (setting
-- it by hand before update hid a preview that read hover too early).
local AR = require("services.AnchorRegistry")
local function mouseOn(id)
    return function()
        local r = AR.get("buy_runup_" .. id)
        local mx, my = -1, -1
        if r then mx, my = (r.x or r[1]) + 10, (r.y or r[2]) + 10 end
        love.mouse.getPosition = function() return mx, my end
        love.mouse.getX = function() return mx end
        love.mouse.getY = function() return my end
    end
end
local hover = mouseOn("pot_control")
frame(hover)
frame(hover)
local with, stack_text = 0, true
for _, t in ipairs(w:tables()) do
    if t._preview then
        with = with + 1
        if not (t._preview.text or ""):find("^Stack win") then stack_text = false end
    end
end
c.ok(with > 0, "hovering Pot Control previews on the tables it moves (" .. with .. ")")
c.ok(stack_text, "Pot Control's preview is the stack win, now and next")
do
    local t1 = w:tables()[1]
    local pv = t1._preview
    c.ok(pv and pv.now and pv.next and pv.focus == "stack", "the table's card has now and next bars, the stack segments in focus")
    local lit = 0
    for _, comp in ipairs(view:_buildTablesTabComponents() or {}) do
        for _, line in ipairs(comp.lines or {}) do
            if line.bar and line.highlight and line.focus == "stack" then lit = lit + 1 end
        end
    end
    c.ok(lit > 0, "the add-table rows' bars light up with the next level (" .. lit .. ")")
end
frame(hover)
c.eq(Perf.counter("panel_rebuild"), 0, "the preview rebuilds no panel (a live layer)")
frame(function() love.mouse.getPosition = function() return -1, -1 end end)
local left = 0
for _, t in ipairs(w:tables()) do if t._preview then left = left + 1 end end
c.eq(left, 0, "un-hovered, the preview is gone")

do
    local sr = mouseOn("sharper_reads")
    frame(sr); frame(sr)
    local t1 = w:tables()[1]
    c.ok(t1._preview and (t1._preview.text or ""):find("^Win ") ~= nil,
         "Sharper Reads' preview is the win chance, now and next")
    c.ok(t1._preview and t1._preview.focus == "win", "with the win side in focus")
    frame()
end

-- ── rows ────────────────────────────────────────────────────────────────
do
    local saved = g.state.bankroll
    g.state.bankroll = 0
    local bars = 0
    for _, comp in ipairs(view:_buildTablesTabComponents() or {}) do
        for _, line in ipairs(comp.lines or {}) do if line.bar then bars = bars + 1 end end
    end
    c.eq(bars, 0, "no add-table row shows a bar when none can be afforded")
    -- The bar fits into the row's padding: a row is as tall with it as
    -- without (the list does not grow a scrollbar for it).
    local CR = require("views.ComponentRenderer")
    local function rowH()
        for _, comp in ipairs(view:_buildTablesTabComponents() or {}) do
            if comp.type == "button" and comp.face_color then
                return CR.types.button.measureH(comp, 260, g)
            end
        end
    end
    local h_without = rowH()
    g.state.bankroll = saved
    local h_with = rowH()
    c.ok(h_with ~= nil and h_with == h_without, "an add-table row keeps its height with the bar ("
         .. tostring(h_with) .. " vs " .. tostring(h_without) .. ")")
end

-- ── ease ────────────────────────────────────────────────────────────────
do
    local a = { win_chance = 0.4, win_dist = { small = 1 }, loss_dist = { small = 1 } }
    local b = { win_chance = 0.6, win_dist = { stack = 1 }, loss_dist = { small = 1 } }
    local d = { win_dist = {}, loss_dist = {} }
    OutcomeBar.ease(d, a, 1)
    c.ok(math.abs(d.win_chance - 0.4) < 1e-9, "a fresh bar starts at its odds")
    OutcomeBar.ease(d, b, 0.25)
    c.ok(d.win_chance > 0.4 and d.win_chance < 0.6, "one step moves part of the way")
    for _ = 1, 200 do OutcomeBar.ease(d, b, 0.25) end
    c.ok(math.abs(d.win_chance - 0.6) < 1e-6 and math.abs(d.win_dist.stack - 1) < 1e-6, "and arrives")
end

-- ── throttle ────────────────────────────────────────────────────────────
do
    local ctrl = w.ctrl
    ctrl.ctx.manual_combo = { value = 0.1, cap = 3 }
    ctrl.manual_combo = 0
    ctrl.clock = (ctrl.clock or 0) + 10
    ctrl:_evFrameConsts()
    local m0 = ctrl._ev_hand_mult
    ctrl.manual_combo = 5
    ctrl.clock = ctrl.clock + 0.2
    ctrl:_evFrameConsts()
    c.eq(ctrl._ev_hand_mult, m0, "a streak step inside the second leaves the readout alone")
    ctrl.clock = ctrl.clock + 1
    ctrl:_evFrameConsts()
    c.ok(ctrl._ev_hand_mult ~= m0, "a second later it is taken")
    ctrl.ctx.manual_combo = nil
end

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
