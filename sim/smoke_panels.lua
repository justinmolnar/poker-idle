-- sim/smoke_panels.lua
--
-- The panel cache (views/PanelSheet + views/TablePanel.prepare, phase 6 of
-- the performance work). The risk of a cached picture is the same as any
-- cache: a rebuild when nothing moved, or no rebuild when something did;
-- and this one has two more: a replayed anchor or hit box left behind at
-- the render's position, and a live layer painted twice or not at all.
-- So this drives the real GrindView through real frames on the recorder
-- stub and counts sheets, rebuilds, bypasses, blits, primitives, hit boxes
-- and anchors.
--
-- Sections:
--   cold      the first frame makes one sheet and rebuilds every panel
--   rest      ten frozen frames rebuild nothing; the hit boxes and the
--             anchors are replayed every frame at the same place
--   parity    the cache off and a cold cache on draw the same primitives,
--             plus one blit and one slot clear per panel
--   hover     the DEAL felt's dwell rebuilds its panel once, and once on
--             leaving
--   deal      a dealt hand bypasses (or rebuilds) exactly one panel
--   residue   the finished hand rebuilds once, then the residue's shader
--             pair is baked: no switch on the frame after
--   palette   a palette change rebuilds every panel
--   resize    a fourth table means a new sheet, the old one released
--
-- Standalone: `lua sim/smoke_panels.lua` from the repo root.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()

local c = Stub.checker()

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
local rec = Stub.recorder()
love.graphics.newFont = function() return F end
love.graphics.getFont = function() return F end
-- A shader that compiles: the residue's desaturate pair then runs for
-- real (a bind is counted), which is what the residue section watches.
love.graphics.newShader = function() return { send = function() end } end
love.timer.getDelta = love.timer.getDelta or function() return 1 / 60 end

local Constants      = require("data.constants")
local HoverService   = require("services.HoverService")
local Tooltip        = require("services.Tooltip")
local ClickFlash     = require("services.ClickFlash")
local AnchorRegistry = require("services.AnchorRegistry")
local Perf           = require("services.Perf")
local ShaderRegistry = require("services.ShaderRegistry")
local FlightSystem   = require("services.FlightSystem")
local ChipPile       = require("views.ChipPile")
local Theme          = require("views.Theme")
local Table          = require("models.Table")
local PanelSheet     = require("views.PanelSheet")
local TablePanel     = require("views.TablePanel")
local GrindView      = require("views.GrindView")

ShaderRegistry.loadFromSource("desaturate", "")
Perf.setEnabled(true)
Constants.FEATURES.PANEL_CACHE = true

w:open("s001", "zoom")
w:open("s001", "zoom")
w:open("s001", "zoom")
-- A second of world so the seats' reroll fade (Table:update decays it)
-- is over: a frozen board still carrying it would bypass every frame.
w:tick(1)

local view = GrindView:new(g, ctrl)

-- One frame the way main.lua runs it: the anchor stamp advanced, the
-- per-frame hover and tooltip state cleared, `pre` (a hover, say) applied,
-- the controller ticked unless frozen, flights and piles advanced, the
-- view updated and drawn. Perf's tallies roll at the end so the counters
-- read THIS frame's numbers.
local function frame(dt, pre)
    dt = dt or 1 / 60
    H.clock = H.clock + dt
    AnchorRegistry.tick()
    HoverService.clear()
    Tooltip.clear()
    if pre then pre() end
    if not g.sim_frozen then
        w.bus:beginFrame()
        ctrl:update(dt)
        w.bus:drain()
    end
    FlightSystem.update(dt)
    ChipPile.update(dt)
    ClickFlash.update(dt)
    view:update(dt)
    view:draw(nil)
    Perf.beginFrame(0)
end
local function frames(n, dt) for _ = 1, n do frame(dt) end end

local function counters()
    return Perf.counter("panel_rebuild"), Perf.counter("panel_bypass"),
           Perf.counter("panel_cached"), Perf.counter("panel_blit")
end

local tables = ctrl.pool.tables
local function dealBoxes()
    local out = {}
    for _, hb in ipairs(view.hit_boxes) do
        if hb.action == "deal" then out[hb.table_id] = hb end
    end
    return out
end

-- ── cold ────────────────────────────────────────────────────────────────

-- One frame with the cache off first: the chip atlas and the felt mask
-- make their own canvases on first use, and they are not the sheet.
g.sim_frozen = true
Constants.FEATURES.PANEL_CACHE = false
frame()
Constants.FEATURES.PANEL_CACHE = true
rec.reset()
frame()
do
    local rebuilds, bypass, cached, blits = counters()
    c.eq(rec.canvases, 1, "the first frame makes one sheet")
    c.eq(rebuilds, 3, "the first frame rebuilds every panel")
    c.eq(bypass, 0, "nothing bypasses at rest")
    c.eq(cached, 3, "every panel is cached")
    c.eq(blits, 3, "every panel is blitted")
    c.ok((rec.calls.draw or 0) >= 3, "the blits are texture draws")
    c.ok((Perf.gaugeValue("sheet_mb") or 0) > 0, "the sheet's size is gauged")
    local n, sw, sh = PanelSheet.debugSize()
    c.eq(n, 3, "the sheet holds three slots")
    for i, t in ipairs(tables) do
        local mode, slot = TablePanel.debugPanelMode(t)
        c.eq(mode, 2, "table " .. i .. " is in cached mode")
        c.eq(slot, i, "table " .. i .. " sits in its own slot")
    end
end

-- ── rest ────────────────────────────────────────────────────────────────

-- The buy-in bursts fly on the first controller tick after the view has
-- registered the stack anchors (GrindController's _pending_buyin), and a
-- pile with chips in the air is drawn live, not cached. Two seconds of
-- world so they land, then the board is frozen and at rest.
g.sim_frozen = false
frames(120)
g.sim_frozen = true
frame()
do
    local n_boxes = #view.hit_boxes
    c.ok(n_boxes >= 3, "the first frame has hit boxes")
    local first = {}
    for id, hb in pairs(dealBoxes()) do first[id] = { hb.x, hb.y, hb.visual_x, hb.visual_y } end
    c.ok(next(first) ~= nil, "every table has a DEAL box")
    for i = 2, 11 do
        frame()
        local rebuilds, bypass = counters()
        c.eq(rebuilds, 0, "frame " .. i .. " rebuilds nothing")
        c.eq(bypass, 0, "frame " .. i .. " bypasses nothing")
        c.eq(#view.hit_boxes, n_boxes, "frame " .. i .. " replays the same number of hit boxes")
        local now = dealBoxes()
        for id, f in pairs(first) do
            local hb = now[id]
            c.ok(hb ~= nil and hb.x == f[1] and hb.y == f[2]
                 and hb.visual_x == f[3] and hb.visual_y == f[4],
                 "frame " .. i .. " keeps table " .. id .. "'s DEAL box in place")
        end
        for _, t in ipairs(tables) do
            c.eq(AnchorRegistry.age(Table.anchorKey(t, "cards_you_1")), 0,
                 "frame " .. i .. " replays table " .. t._id .. "'s card anchor")
            c.eq(AnchorRegistry.age(Table.anchorKey(t, "you")), 0,
                 "frame " .. i .. " sets table " .. t._id .. "'s stack anchor")
        end
    end
    -- The replayed entries are the same objects every frame, carrying the
    -- index the click handler resolves against.
    local a = dealBoxes()
    frame()
    local b = dealBoxes()
    for id, hb in pairs(a) do
        c.ok(b[id] == hb, "table " .. id .. "'s DEAL box is one entry replayed")
        c.ok(hb.idx ~= nil, "the replayed box carries its index")
    end
end

-- ── parity ──────────────────────────────────────────────────────────────

do
    Constants.FEATURES.PANEL_CACHE = false
    rec.reset()
    frame()
    local off_total, off_boxes = rec.total(), #view.hit_boxes
    c.eq(rec.canvases, 0, "the cache off makes no sheet")
    c.eq(PanelSheet.available(), false, "the cache off releases the sheet")
    Constants.FEATURES.PANEL_CACHE = true
    rec.reset()
    frame()
    local rebuilds = counters()
    c.eq(rebuilds, 3, "a cold cache rebuilds every panel")
    -- One blit and one slot clear (a replace-blend rect) per panel over
    -- the immediate frame's primitives; the body itself is the same set.
    c.eq(rec.total(), off_total + 3 + 3,
         "a cold cached frame draws the immediate frame's primitives plus a blit and a clear per panel")
    c.eq(#view.hit_boxes, off_boxes, "the cached frame has the immediate frame's hit boxes")
    frame()
    c.eq((counters()), 0, "and the frame after rebuilds nothing")
end

-- ── hover ───────────────────────────────────────────────────────────────

do
    local t   = tables[1]
    local key = "deal:" .. t._id
    local hover = function() HoverService.set("hit", key) end
    frame(1 / 60, hover)
    c.eq((counters()), 0, "the first hovered frame is before the dwell: nothing rebuilds")
    frame(1, hover)
    c.eq((counters()), 1, "the felt's hover dwell rebuilds its panel once")
    frame(1 / 60, hover)
    c.eq((counters()), 0, "held, it rebuilds nothing")
    frame()
    c.eq((counters()), 1, "leaving rebuilds it once")
    frame()
    c.eq((counters()), 0, "and then nothing")
end

-- ── deal ────────────────────────────────────────────────────────────────

local dealt = tables[2]
do
    c.ok(ctrl:dealIdleTable(dealt), "the second table deals")
    w:tick(1 / 60)
    frame()
    local rebuilds, bypass = counters()
    -- The stub's clock is the harness's (H.clock), so the deal's gates and
    -- the felt light both read as in motion: a bypass. Either way, one
    -- panel and only one.
    c.eq(rebuilds + bypass, 1, "the dealt table alone bypasses or rebuilds")
    local mode = TablePanel.debugPanelMode(dealt)
    c.ok(mode == 1 or rebuilds == 1, "the dealt table is the one")
    c.ok(dealt._deal_fx and dealt._deal_fx.settled_at ~= nil, "the deal notes when its cards are at rest")
end

-- ── residue ─────────────────────────────────────────────────────────────

do
    w:tick(10)
    local guard = 0
    while dealt.state ~= "idle" and guard < 10 do w:tick(1); guard = guard + 1 end
    c.eq(dealt.state, "idle", "the hand is over")
    c.ok(dealt.last_hand ~= nil, "the finished hand is on the felt")
    -- Flights from the hand land and the piles settle before the frame
    -- that caches the residue, so the stack pile is quiet.
    for _ = 1, 240 do FlightSystem.update(1 / 60); ChipPile.update(1 / 60) end
    H.clock = H.clock + 1
    frame()
    local rebuilds = counters()
    c.ok(rebuilds >= 1, "the residue rebuilds the panel")
    for _ = 1, 240 do FlightSystem.update(1 / 60); ChipPile.update(1 / 60) end
    frame()
    local r2 = counters()
    c.eq(r2, 0, "the residue frame after rebuilds nothing")
    c.eq(Perf.counter("shader_switch"), 0, "the residue's shader pair is baked: no switch on the frame after")
    local mode = TablePanel.debugPanelMode(dealt)
    c.eq(mode, 2, "the residue panel is cached")
    c.eq(ChipPile.quiet(Table.anchorKey(dealt, "you")), true, "the stack pile is quiet")
end

-- ── palette ─────────────────────────────────────────────────────────────

do
    frames(3)
    c.eq((counters()), 0, "at rest again")
    Theme.cycle()
    frame()
    c.eq((counters()), 3, "a palette change rebuilds every panel")
    frame()
    c.eq((counters()), 0, "once")
    Theme.cycle()
    frame()
end

-- ── resize ──────────────────────────────────────────────────────────────

do
    local old = PanelSheet.debugCanvas()
    local released = false
    old.release = function() released = true end
    rec.reset()
    w:open("s001", "zoom")
    w:tick(1)
    frame()
    c.eq(rec.canvases, 1, "a fourth table means one new sheet")
    c.ok(released, "the old sheet is released")
    c.ok(PanelSheet.debugCanvas() ~= old, "the sheet is a new canvas")
    local n = PanelSheet.debugSize()
    c.eq(n, 4, "the new sheet holds four slots")
    c.eq((counters()), 4, "every panel rebuilds into the new sheet")
    frame()
    c.eq((counters()), 0, "and rests")
end

os.exit(c.report("smoke_panels") == 0 and 0 or 1)
