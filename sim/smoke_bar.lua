-- sim/smoke_bar.lua
--
-- The outcome bar (views/OutcomeBar) and the upgrade preview:
--   segments  eight segments, as wide as their absolute chances, filling the
--             bar exactly; the win/loss split where the win chance says
--   tooltip   pot_control's and sharper_reads' tooltips name the stakes
--             the next level moves, as one sentence, no numbers; their "i" builds the full
--             breakdown grid (stake x game type, now -> next)
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
    local header, names, pct = false, false, false
    for _, r in ipairs(rows or {}) do
        if type(r) == "table" and r.say and r.say:find("^Your next level") then header = true end
        if type(r) == "table" and r.say and r.say:find("NL") then names = true end
        if type(r) == "table" and r.text and r.text:find("%%") then pct = true end
    end
    c.ok(header and names and not pct, id .. "'s tooltip names the stakes the next level moves, no numbers")
    local info = view:_upgradeInfoRowsUncached(up)
    local grids = 0
    for _, r in ipairs(info or {}) do
        if type(r) == "table" and r.measure and r.render then
            grids = grids + 1
            local gw, gh = r.measure(g.fonts)
            c.ok(gw > 0 and gh > 0, id .. "'s breakdown grid measures")
            r.render(0, 0, g.fonts)
        end
    end
    c.ok(grids >= 1, id .. "'s i shows a breakdown grid (" .. grids .. ")")
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
    -- The cards are drawn in the top layer (after flights and cursors).
    local TP = require("views.TablePanel")
    local real, drawn = TP.flushPreviewCards, 0
    local rec_rect = love.graphics.rectangle
    TP.flushPreviewCards = function(game)
        local n0 = 0
        love.graphics.rectangle = function(...) n0 = n0 + 1; return rec_rect(...) end
        real(game)
        love.graphics.rectangle = rec_rect
        drawn = n0
    end
    frame(hover)
    TP.flushPreviewCards = real
    c.ok(drawn > 0, "the hover cards are drawn in the top layer (" .. drawn .. " rects)")
end
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

-- A table the next level can't move keeps its card and says why (it
-- used to get none, so cards came and went as Zoom tables touched the
-- win-chance ceiling with the board's hand rate).
do
    local GV = require("views.GrindView")
    local OM = require("models.outcome_math")
    local capped = { win_chance = OM.WC_ABSOLUTE_CAP, win_dist = { small = 1 }, loss_dist = { small = 1 } }
    local pv = GV.previewText("win_chance", capped, capped)
    c.ok(pv and pv.none and pv.text:find("ceiling") ~= nil, "a table at the ceiling says so: " .. tostring(pv and pv.text))
end

-- The bar's legend reads each tier's chance per hand as a percent, and
-- they add up to 100 (it once printed them a hundred times too big).
do
    local TPS = require("views.TablePanelStats")
    local t1 = w:tables()[1]
    local lines = TPS.barLegendLines(t1, w.ctrl)
    local total, ok = 0, true
    local pr = love.graphics.print
    for i = 2, #lines do
        local txt
        local IconText = require("views.IconText")
        local real = IconText.draw
        IconText.draw = function(_, str) txt = str end
        lines[i].render(0, 0, g.fonts)
        IconText.draw = real
        local v = tonumber((txt or ""):match("([%d%.]+)%%"))
        if not v or v > 100 then ok = false else total = total + v end
    end
    c.ok(ok and math.abs(total - 100) < 1, string.format("the legend's eight chances add up to 100%% (%.1f)", total))
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

-- ── hand names on top ───────────────────────────────────────────────────
-- A resolved hand's name is drawn in the top layer (flushHandLabels, after
-- the chip flights and cursors), not inside the panel under them.
do
    local TP = require("views.TablePanel")
    local real, named = TP.flushHandLabels, 0
    TP.flushHandLabels = function(game)
        local pf = love.graphics.printf
        love.graphics.printf = function(t, ...) if type(t) == "string" and t ~= "" then named = named + 1 end return pf(t, ...) end
        real(game)
        love.graphics.printf = pf
    end
    g.sim_frozen = false
    for _ = 1, 1200 do
        for _, t in ipairs(w:tables()) do if t.state == "idle" then w.ctrl:dealHand(w:find(t)) end end
        w:tick(1 / 60)
        frame()
        if named > 0 then break end
    end
    TP.flushHandLabels = real
    c.ok(named > 0, "a showdown's hand name is drawn in the top layer")
end

-- ── Pot Control counts in a tournament ──────────────────────────────────
do
    local OM = require("models.outcome_math")
    local ko = Lookups.findById(require("data.game_types"), "ko")
    local s1 = require("data.stakes")[1]
    local function first(d)
        local ctx = { win_chance_fills = {}, win_dist_fills = {}, loss_dist_fills = {} }
        for i = 1, d do ctx.win_dist_fills[i] = { strength = 1 }; ctx.loss_dist_fills[i] = { strength = 1 } end
        return OM.evStats(ctx, ko, s1).pool.pos_probs[1]
    end
    c.ok(first(5) > first(0) + 0.02, ("Pot Control raises a tournament's chance of 1st (%.1f%% -> %.1f%%)"):format(first(0) * 100, first(5) * 100))
end

-- ── right-click: the cursor switch for what is under the pointer ───────
do
    w:own({ "box_of_mice" })
    w.ctrl.ctx.cursor_unlocked = true
    view:update(0.016)
    pcall(function() view:draw() end)
    local P = view._grid_pos
    local t1 = w:tables()[1]
    local was = t1.cursor_muted == true
    -- Through the state, the way LOVE delivers it (the view alone passed
    -- while the state dropped every right-click on the floor).
    local GrindState = require("states.GrindState")
    local st = setmetatable({ view = view }, { __index = GrindState })
    st:mousepressed(P[1] + 5, P[2] + 30, 2)
    c.ok((t1.cursor_muted == true) ~= was, "right-clicking a table flips its cursor switch")
    st:mousepressed(P[1] + 5, P[2] + 30, 2)
    c.ok((t1.cursor_muted == true) == was, "right-clicking it again flips it back")
    st.catalog_modal = {}
    st:mousepressed(P[1] + 5, P[2] + 30, 2)
    c.ok((t1.cursor_muted == true) == was, "a right-click does nothing through an open modal")
    st.catalog_modal = nil
    -- An add-table row you can't afford (a disabled button) still takes
    -- the right-click: sweep down the left column until one switches.
    local bank = w.state.bankroll
    w.state.bankroll = 0
    view:update(0.016)
    pcall(function() view:draw() end)
    w.ctrl:_rebuildPoolSummary()
    local _, before = w.ctrl:typeCursorState("s001", "zoom")
    local hit_row = false
    for yy = 40, 880, 6 do
        st:mousepressed(math.floor(view.left_panel.w / 2), yy, 2)
        w.ctrl:_rebuildPoolSummary()
        local _, now = w.ctrl:typeCursorState("s001", "zoom")
        if now ~= before then hit_row = true; break end
    end
    c.ok(hit_row, "right-clicking an add-table row you can't afford switches its tables")
    w.state.bankroll = bank
    w.ctrl:setTypeCursorMute(nil, nil, false)
    view:update(0.016)
    -- The master (the Cursor upgrade's id) and a group (an add-table row).
    -- (The controller's summary is rebuilt every frame; here by hand.)
    w.ctrl:_rebuildPoolSummary()
    view:_handleSidebarButton("type_cursor_deal")
    w.ctrl:_rebuildPoolSummary()
    local total, dm = w.ctrl:typeCursorState(nil, nil)
    c.ok(dm == total, "the Cursor upgrade's switch stops them everywhere (" .. dm .. "/" .. total .. ")")
    view:_handleSidebarButton("type_cursor_deal:s001:zoom")
    w.ctrl:_rebuildPoolSummary()
    total, dm = w.ctrl:typeCursorState("s001", "zoom")
    c.ok(dm == 0, "an add-table row's switch lets them deal its tables again")
end

-- ── cursor settings carry to new tables ─────────────────────────────────
do
    local cw = H.world({ bankroll = 1e9 })
    local ctrl = cw.ctrl
    cw:open("s001", "zoom")
    ctrl:setTypeCursorMute("s001", "zoom", true)
    cw:open("s001", "zoom")
    local total, dm = ctrl:typeCursorState("s001", "zoom")
    c.ok(total == 2 and dm == 2, "a new table joins its group's cursor switch, off (" .. dm .. " of " .. total .. ")")
    ctrl:setTypeCursorMute(nil, nil, false)
    cw:open("s001", "zoom")
    total, dm = ctrl:typeCursorState("s001", "zoom")
    c.ok(total == 3 and dm == 0, "the master switch overrides the group's setting for later tables")
    ctrl:setTypeCursorMute(nil, nil, true)
    cw:open("s001", "zoom")
    total, dm = ctrl:typeCursorState("s001", "zoom")
    c.ok(total == 4 and dm == 4, "the master OFF carries to new tables")
end

if c.report("smoke_bar") > 0 then os.exit(1) end
