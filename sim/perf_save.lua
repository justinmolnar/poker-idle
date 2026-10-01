-- sim/perf_save.lua
--
-- Frames on a REAL save, headless: the items, upgrades, decks and open
-- tables of an actual run through the real controller and view on the
-- recorder stub, with the Perf counters, the garbage a frame makes, and
-- where it is made. The budgets in sim/perf_budget run a synthetic board;
-- this is for the board a player is actually looking at when they say the
-- game is slow. It found the bankroll pile that grew by every chip that
-- ever flew to it and the hand evaluator that was half of every frame's
-- garbage, neither of which the synthetic board showed.
--
--   lua sim/perf_save.lua [frames] [save.json] [heap_frames]
--
-- `save.json` defaults to LÖVE's save directory for this game on Windows
-- (%APPDATA%/LOVE/poker-idle/save.json). `heap_frames`, when given, runs
-- that many more frames afterwards and prints the collected heap every
-- 3000, which is how a leak reads: a number that climbs.
--
-- Attribution wraps every function of the listed modules with a
-- collectgarbage("count") delta; a call's own garbage is its delta minus
-- its wrapped children's. The stub's sprite loader returns a fresh colour
-- per backColor call, so CardSprites.backPlate reads high here and not in
-- the game.

package.path = "./?.lua;" .. package.path

local Stub = require("sim.love_stub")
Stub.base()
local H = require("sim.harness")
local F = Stub.font(16)
local w = H.world({ bankroll = 1e9 })
local g, ctrl = w.game, w.ctrl
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

local N        = tonumber(arg[1]) or 300
local path     = arg[2] or ((os.getenv("APPDATA") or "") .. "/LOVE/poker-idle/save.json")
local HEAP     = tonumber(arg[3]) or 0

local json = require("lib.json")
local fh = io.open(path, "rb")
if not fh then print("perf_save: no save at " .. path); os.exit(1) end
local saved = json.decode(fh:read("*a")); fh:close()
g.state:applySaved(saved)
ctrl:reloadPool()

local HoverService = require("services.HoverService")
local Tooltip      = require("services.Tooltip")
local ClickFlash   = require("services.ClickFlash")
local FlightSystem = require("services.FlightSystem")
local ChipPile     = require("views.ChipPile")
local GrindView    = require("views.GrindView")
local Perf         = require("services.Perf")
local TablePanel   = require("views.TablePanel")

-- ── Attribution ─────────────────────────────────────────────────────────
local INC, EXC, CNT, measuring = {}, {}, {}, false
local stack, child = {}, {}
local function wrap(tbl, label, name)
    local orig = tbl[name]
    if type(orig) ~= "function" then return end
    local key = label .. "." .. name
    INC[key], EXC[key], CNT[key] = 0, 0, 0
    local function finish(depth, k0, ...)
        local total = collectgarbage("count") - k0
        INC[key] = INC[key] + total
        EXC[key] = EXC[key] + total - child[depth]
        CNT[key] = CNT[key] + 1
        stack[depth] = nil
        if depth > 1 then child[depth - 1] = child[depth - 1] + total end
        return ...
    end
    tbl[name] = function(...)
        if not measuring then return orig(...) end
        local depth = #stack + 1
        stack[depth], child[depth] = key, 0
        return finish(depth, collectgarbage("count"), orig(...))
    end
end
local function wrapAll(modpath, label, only)
    local ok, m = pcall(require, modpath)
    if not ok or type(m) ~= "table" then return end
    local names = {}
    for k, v in pairs(m) do if type(v) == "function" and (not only or only[k]) then names[#names + 1] = k end end
    table.sort(names)
    for _, n in ipairs(names) do wrap(m, label, n) end
end
local function set(list) local s = {}; for _, n in ipairs(list) do s[n] = true end; return s end
wrapAll("models.Table", "Table", set({ "deal", "_update", "_finalizeHand", "fillOpponents", "estimateStats", "effectiveCtx" }))
wrapAll("models.HandScript", "HandScript")
wrapAll("models.HandRealism", "HandRealism")
wrapAll("models.HandEval", "HandEval")
wrapAll("models.outcome_math", "OutcomeMath")
wrapAll("models.Card", "Card")
wrapAll("services.EventBus", "EventBus", set({ "publish", "drain" }))
wrapAll("services.FlightSystem", "FlightSystem", set({ "emit", "emitXY", "emitChip", "draw", "update" }))
wrapAll("services.Tumble", "Tumble", set({ "wrap" }))
wrapAll("views.PokerEventAnims", "PokerEventAnims")
wrapAll("controllers.GrindController", "Ctrl", set({ "dealIdleTable", "dealHand", "_fireProcs", "_announce" }))
wrapAll("views.TablePanel", "TablePanel", set({ "prepare", "draw" }))
wrapAll("views.GrindView", "GrindView", set({ "drawChrome", "_drawCenterGrid", "_drawHouse", "_drawFloatingText", "_drawBankrollChips" }))
wrapAll("views.Panel", "Panel", set({ "draw" }))
wrapAll("views.ComponentRenderer", "CR")
wrapAll("services.FloatingTextSystem", "Floaters")
wrapAll("views.CardSprites", "CardSprites")
wrapAll("views.TierGlyph", "TierGlyph")
wrapAll("views.Chips", "Chips")
wrapAll("views.FeltDecor", "FeltDecor")
wrapAll("views.TablePanelEffects", "Effects")
wrapAll("views.IconText", "IconText")
wrapAll("views.Theme", "Theme")
wrapAll("services.AnchorRegistry", "Anchors")
wrapAll("services.RollingValue", "Rolling")
wrapAll("services.Pop", "Pop")
wrapAll("views.ChipPile", "ChipPile")
wrapAll("views.ChipFlight", "ChipFlight")
wrapAll("services.DenominationBreakdown", "Denoms")

-- ── Frames ──────────────────────────────────────────────────────────────
print(("[perf_save] %s: %d tables, bankroll %.3g, focus cap %d (x%.2f), %d items"):format(
    path, ctrl.pool:count(), g.state.bankroll or 0, ctrl:currentFocusCapacity(), ctrl:currentFocusMult(),
    #(g.state.owned_items or {})))
w:tick(1 / 60)
local view = GrindView:new(g, ctrl)
Perf.setEnabled(true)
local function frame(dt)
    H.clock = H.clock + dt
    Perf.beginFrame(dt)
    HoverService.clear(); Tooltip.clear(); ClickFlash.update(dt)
    -- The cursors' work: every idle table dealt (and rebought) at once.
    for i, t in ipairs(w:tables()) do
        if t.state == "idle" then
            if (t.stack or 0) <= 0 then ctrl:rebuyTable(i) end
            ctrl:dealIdleTable(t, { by_cursor = true })
        end
    end
    w.bus:beginFrame(); ctrl:update(dt); w.bus:drain()
    FlightSystem.update(dt); ChipPile.update(dt)
    view:update(dt); view:draw(nil)
    Perf.endFrame()
end
local STEP = 1 / 60
for _ = 1, 240 do frame(STEP) end

local keys = { "panel_cached", "panel_bypass", "panel_rebuild", "evStats", "getWrap", "build",
               "buildOutcome", "anchor_set", "stack_layout", "pile_batch", "shader_switch" }
for _, r in ipairs(TablePanel.BYPASS_REASONS or {}) do keys[#keys + 1] = r end
for _, r in ipairs(TablePanel.KEY_COUNTER or {}) do keys[#keys + 1] = r end
local sums = {}
local rev0 = ctrl.display_rev or 0
local hands0 = 0; for _, t in ipairs(w:tables()) do hands0 = hands0 + t.hands_played end
collectgarbage("collect"); collectgarbage("stop")
measuring = true
local kb0 = collectgarbage("count")
for _ = 1, N do
    frame(STEP)
    Perf.beginFrame(STEP)
    for _, k in ipairs(keys) do sums[k] = (sums[k] or 0) + Perf.counter(k) end
end
local total = (collectgarbage("count") - kb0) / N
measuring = false
collectgarbage("restart")
local hands1 = 0; for _, t in ipairs(w:tables()) do hands1 = hands1 + t.hands_played end

print(("[perf_save] %d frames: %.1f KB of garbage a frame, %.1f hands a second, display_rev moved %d times"):format(
    N, total, (hands1 - hands0) / (N * STEP), (ctrl.display_rev or 0) - rev0))
print("counters a frame:")
for _, k in ipairs(keys) do if (sums[k] or 0) > 0 then print(("  %-16s %8.2f"):format(k, sums[k] / N)) end end
local rows = {}
for k, v in pairs(EXC) do if CNT[k] > 0 and v / N >= 0.3 then rows[#rows + 1] = { k, v / N, INC[k] / N, CNT[k] / N } end end
table.sort(rows, function(a, b) return a[2] > b[2] end)
print("garbage a frame by call site, exclusive (inclusive), calls a frame, exclusive bytes a call:")
for i = 1, math.min(25, #rows) do
    local r = rows[i]
    print(("  %-36s %7.1f (%7.1f)  %7.2f  %7.0f B"):format(r[1], r[2], r[3], r[4], 1024 * r[2] / r[4]))
end
print(("flights in the air: %d"):format(FlightSystem.count()))

if HEAP > 0 then
    print("collected heap:")
    for f = 1, HEAP do
        frame(STEP)
        if f % 3000 == 0 or f == HEAP then
            collectgarbage("collect"); collectgarbage("collect")
            local hands = 0; for _, t in ipairs(w:tables()) do hands = hands + t.hands_played end
            print(("  f=%6d t=%5.0fs heap=%8.0f KB hands=%6d"):format(f, H.clock, collectgarbage("count"), hands))
            io.stdout:flush()
        end
    end
end
