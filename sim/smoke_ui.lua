-- sim/smoke_ui.lua
--
-- The retained sidebars and rail (views/Panel inputs + refresh, phase 4 of
-- the performance work). The risk of a retained tree is the same as any
-- cache: it rebuilds when nothing moved, or it does not rebuild when
-- something did. Neither shows up in the engine suite, which never draws,
-- and neither shows up in sim/smoke_views, which only checks that a frame
-- completes. So this drives the real GrindView through real frames and
-- counts the builds.
--
-- Four sections:
--   rest      after a warm-up with the simulation frozen, 120 frames build
--             nothing in any of the three panels, and hovering a game-type
--             key builds nothing either (hover is the renderer's, not a key).
--   change    one input moves and exactly the panel(s) that read it rebuild
--             once, then rest again: a rail-only key, an upgrades-only key,
--             a tables-only key, and a pool change (every panel).
--   live      the rail's numbers still move without a rebuild: the bankroll
--             tween, the run's chips, and the focus alarm's shape change.
--   tooltip   a tooltip_fn runs only under the pointer, and hands back the
--             same lines table while its inputs hold still.
--
-- Standalone: `lua sim/smoke_ui.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local c = Stub.checker()

-- ── The world: a real controller, a real view, a clock we own ───────────
-- sim/harness replaces love.timer with its own clock (H.clock), which is
-- what lets the rolled values settle on demand: a frame a second long
-- snaps every RollingValue and every tween to its target.

local H = require("sim.harness")
local F = Stub.font(16)
local w = H.world({ bankroll = 5000 })
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

local HoverService   = require("services.HoverService")
local Tooltip        = require("services.Tooltip")
local ClickFlash     = require("services.ClickFlash")
local AnchorRegistry = require("services.AnchorRegistry")
local GrindView      = require("views.GrindView")

-- Two tables on the felt, so the rail's counts and the Tables tab's rows
-- have something to say, then one controller tick so the pool summary and
-- the display revision have been polled once.
w:open("s001", "zoom")
w:open("s001", "zoom")
w:tick(1 / 60)

local view = GrindView:new(g, ctrl)

-- One frame the way main.lua and GrindState run it: the per-frame hover
-- and tooltip state cleared, the controller ticked unless the simulation
-- is frozen (a story pause), the view updated, the view drawn. The view
-- takes dt even while frozen here (GrindState hands it 0) so the money
-- tweens can be watched with the felt standing still.
local function frame(dt)
    dt = dt or 1 / 60
    H.clock = H.clock + dt
    HoverService.clear()
    Tooltip.clear()
    ClickFlash.update(dt)
    if not g.sim_frozen then
        w.bus:beginFrame()
        ctrl:update(dt)
        w.bus:drain()
    end
    view:update(dt)
    view:draw(nil)
end

local function frames(n, dt) for _ = 1, n do frame(dt) end end

local panels = { tables = view.left_panel, upgrades = view.right_panel, rail = view.rail }
local function counts()
    return { tables = panels.tables.build_count, upgrades = panels.upgrades.build_count,
             rail = panels.rail.build_count }
end
local function delta(before)
    local now = counts()
    return now.tables - before.tables, now.upgrades - before.upgrades, now.rail - before.rail
end

-- ── rest ────────────────────────────────────────────────────────────────

do
    g.sim_frozen = true
    frame()
    local n = counts()
    c.eq(n.tables, 1, "the first frame builds the Tables tab")
    c.eq(n.upgrades, 1, "the first frame builds the Upgrades tab")
    c.eq(n.rail, 1, "the first frame builds the rail")
    c.ok(view.left_panel:getComponents() ~= nil, "the Tables tab's tree is retained")
    c.ok(view.rail:getComponents() ~= nil, "the rail's tree is retained")

    -- The visible-tab list is one cached table, not a fresh one per ask.
    c.eq(view.left_panel:_visibleTabs(g), view.left_panel:_visibleTabs(g),
         "the visible-tab list is cached")

    -- Warm up: rolled values and tweens settle (a second a frame snaps them).
    frames(60, 1)
    local before = counts()
    frames(120)
    local dt_, du_, dr_ = delta(before)
    c.eq(dt_, 0, "120 frames at rest: the Tables tab does not rebuild")
    c.eq(du_, 0, "120 frames at rest: the Upgrades tab does not rebuild")
    c.eq(dr_, 0, "120 frames at rest: the rail does not rebuild")

    -- The tree the hit test reads is the one that was drawn.
    local tree = view.left_panel:getComponents()
    frame()
    c.eq(view.left_panel:getComponents(), tree, "the retained tree keeps its identity across frames")

    -- Hovering a game-type key lights it in the renderer; it is not a key
    -- of the Tables tab, so it must not rebuild the tab.
    before = counts()
    for _ = 1, 10 do
        frame()
        HoverService.set("button", "gtype:zoom")
    end
    dt_ = delta(before)
    c.eq(dt_, 0, "hovering a game-type key does not rebuild the Tables tab")

    -- The rail's row layouts are memoized on the retained rows.
    local rail_tree = view.rail:getComponents()
    local row = rail_tree[2]
    c.ok(row and row._rl ~= nil, "the rail's row layout is memoized on the row")
end

-- ── change ──────────────────────────────────────────────────────────────

do
    -- Rail only: the catalog earned (its button stops being blank).
    local before = counts()
    g.state.catalog_seen = true
    frame()
    local dt_, du_, dr_ = delta(before)
    c.eq(dr_, 1, "catalog_seen rebuilds the rail once")
    c.eq(dt_, 0, "catalog_seen leaves the Tables tab alone")
    c.eq(du_, 0, "catalog_seen leaves the Upgrades tab alone")
    before = counts()
    frames(30)
    c.eq(select(3, delta(before)), 0, "the rail rests again after the change")

    -- Upgrades only: a level bought (the row's Lv text and its price).
    before = counts()
    g.state.run_upgrade_levels.pot_control = (g.state.run_upgrade_levels.pot_control or 0) + 1
    frame()
    dt_, du_, dr_ = delta(before)
    c.eq(du_, 1, "an upgrade level rebuilds the Upgrades tab once")
    c.eq(dt_, 0, "an upgrade level leaves the Tables tab alone")
    c.eq(dr_, 0, "an upgrade level leaves the rail alone")
    before = counts()
    frames(30)
    c.eq(select(2, delta(before)), 0, "the Upgrades tab rests again after the change")

    -- Tables only: a bounty banked (the badge goes gold).
    before = counts()
    ctrl.banked_rev = (ctrl.banked_rev or 0) + 1
    frame()
    dt_, du_, dr_ = delta(before)
    c.eq(dt_, 1, "the bounty revision rebuilds the Tables tab once")
    c.eq(du_, 0, "the bounty revision leaves the Upgrades tab alone")
    c.eq(dr_, 0, "the bounty revision leaves the rail alone")
    before = counts()
    frames(30)
    c.eq((delta(before)), 0, "the Tables tab rests again after the change")

    -- The pool: a table opened moves the display revision (every panel),
    -- the summary revision and the rail's count. The controller must tick
    -- to poll it, so this frame runs unfrozen.
    local sum_rev = ctrl.summary_rev
    before = counts()
    g.sim_frozen = false
    w:open("s001", "zoom")
    frame()
    g.sim_frozen = true
    dt_, du_, dr_ = delta(before)
    c.eq(dt_, 1, "opening a table rebuilds the Tables tab once")
    c.eq(du_, 1, "opening a table rebuilds the Upgrades tab once")
    c.eq(dr_, 1, "opening a table rebuilds the rail once")
    c.ok(ctrl.summary_rev > sum_rev, "opening a table steps the pool summary's revision")
    local rc = view._rail_c
    c.eq(rc.tables.suffix.text, "3 / " .. ctrl:currentFocusCapacity(), "the rail's TABLES count follows the pool")
    -- The rows' EVs moved with the board, and a rolled EV is a Tables key
    -- at the cent: it may rebuild a few more times while the number
    -- settles, then it must rest.
    frames(60, 1)
    before = counts()
    frames(30)
    dt_, du_, dr_ = delta(before)
    c.eq(dt_ + du_ + dr_, 0, string.format("every panel rests again after the table opened (tables %d, upgrades %d, rail %d)", dt_, du_, dr_))
    c.eq(ctrl.summary_rev, sum_rev + 1, "the summary revision holds still while the pool does")
end

-- ── live ────────────────────────────────────────────────────────────────

do
    local rc = view._rail_c
    local before = counts()
    local was = rc.bank.value
    g.state.bankroll = g.state.bankroll + 123.45
    frame(1)   -- a second: the tween snaps to the target
    c.ok(rc.bank.value ~= was, "the bankroll readout moved: " .. tostring(was) .. " -> " .. tostring(rc.bank.value))
    c.eq(select(3, delta(before)), 0, "...without rebuilding the rail")
    c.ok(view.rail:getComponents()[2]._rl ~= nil, "...and the row layout memo survives the refresh")

    -- The run's chips, and the badge's colour with them.
    was = rc.chips_next.value
    g.state.chips_this_run = (g.state.chips_this_run or 0) + 3
    frame()
    c.ok(rc.chips_next.value ~= was, "the NEXT badge moved with this run's chips")
    c.eq(rc.chips_next.value_color_token, "chip", "the NEXT badge is gold with chips pending")
    c.eq(select(3, delta(before)), 0, "the chips leave the rail's shape alone")

    -- A readout at rest is not formatted again: the same string object.
    local held = rc.bank.value
    frames(30)
    c.ok(rawequal(rc.bank.value, held), "a settled readout keeps its string")

    -- The alarm: over the focus capacity the cell changes shape (label,
    -- font, colour token), which IS a rail key, and the alarm's step fires.
    local cap = ctrl:currentFocusCapacity()
    before = counts()
    g.sim_frozen = false
    while ctrl.pool:count() <= cap do w:open("s001", "zoom") end
    frame()
    g.sim_frozen = true
    frames(60, 1)
    c.ok(view._focus_over == true, "over the capacity the rail knows it is over focus")
    c.ok(select(3, delta(before)) >= 1, "going over focus rebuilds the rail")
    c.eq(rc.focus.label, "OVER FOCUS", "the cell reads OVER FOCUS")
    c.eq(rc.focus.value_style, "lg", "the value goes to the big font")
    c.ok(rc.focus.value ~= "" and rc.focus.value ~= "100%", "the value shows the slowed percent: " .. tostring(rc.focus.value))
    c.ok((view._focus_extra or 0) >= 1, "the alarm counts the tables over")
    before = counts()
    frames(60)
    c.eq(select(3, delta(before)), 0, "the rail rests while over focus holds still")
end

-- ── tooltip ─────────────────────────────────────────────────────────────

do
    local rc   = view._rail_c
    local rate = rc.rate
    c.ok(rate.tooltip == nil and type(rate.tooltip_fn) == "function", "the rate's tooltip is a tooltip_fn")
    local real, calls = rate.tooltip_fn, 0
    rate.tooltip_fn = function(comp, game) calls = calls + 1; return real(comp, game) end
    frames(30)
    c.eq(calls, 0, "a tooltip_fn is not called while nothing hovers it")

    -- The pointer over the rate cell: the hit test runs the fn.
    local cell = AnchorRegistry.get("cell:rate")
    if c.ok(cell ~= nil, "the rate cell registered its anchor") then
        -- The stub has no transform stack, so the anchor is in the
        -- panel's content space: the rail's content_y puts it on screen.
        local mx, my = cell[1] + cell[3] * 0.5, view.rail.content_y + cell[2] + cell[4] * 0.5
        love.mouse.getPosition = function() return mx, my end
        frame()
        c.eq(calls, 1, "hovering the rate cell calls its tooltip_fn once per frame")
        local first = real(rate, g)
        c.eq(real(rate, g), first, "the tooltip_fn hands back the same lines table while its inputs hold")
        c.ok(type(first) == "table" and #first > 0, "the rate tooltip has lines")
        love.mouse.getPosition = function() return -1, -1 end
        frames(5)
        c.eq(calls, 1, "off the cell the tooltip_fn is not called again")
    end

    -- SHOVE's, the same way, through its memo.
    local shove_tip = view:_shoveTooltip()
    c.ok(type(shove_tip) == "table", "the shove tooltip builds")
    c.eq(view:_shoveTooltip(), shove_tip, "the shove tooltip is memoized on its inputs")
    g.state.chips_this_run = g.state.chips_this_run + 1
    c.ok(view:_shoveTooltip() ~= shove_tip, "the shove tooltip rebuilds when this run's chips move")
end

os.exit(c.report("smoke_ui") == 0 and 0 or 1)
