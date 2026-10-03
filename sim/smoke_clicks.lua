-- sim/smoke_clicks.lua
--
-- Every click answers where it lands (services/ClickFX, docs/sound-checklist
-- section 8). Headless checks of the pieces and the outcome rules:
--   surfaces  topmost wins, nothing = the wall, records reused
--   outcomes  a press = result (the surface sound quieter, a gold burst), a
--             deny = denied (the thunk, a shake on the refused key), a
--             disabled button's surface = denied, nothing = dead
--   streak    rapid clicks climb and cap; a pause resets
--   cursor    higher, quieter, no streak, no gold
--   sparks    the pool is bounded and reused; Motion None throws nothing
--   poke      every kind moves and comes back to rest
--
-- Standalone: `lua sim/smoke_clicks.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local clock = 100
love.timer.getTime = function() return clock end

local Data          = require("data.clicks")
local Motion        = require("services.Motion")
local ClickFlash    = require("services.ClickFlash")
local ClickSurfaces = require("services.ClickSurfaces")
local Sparks        = require("services.Sparks")
local Poke          = require("services.Poke")
local ClickFX       = require("services.ClickFX")

local played = {}
ClickFX.play = function(name, opts) played[#played + 1] = { name = name, vol = opts.volume_mult, pitch = opts.pitch } end
local items, piles = {}, {}
ClickFX.onItem = function(id) items[#items + 1] = id end
ClickFX.onPile = function(key, x) piles[#piles + 1] = key end

local function frame()
    ClickSurfaces.beginFrame()
    ClickSurfaces.add("felt", 0, 0, 200, 100, { tint = { 0.1, 0.5, 0.2 }, poke = "felt:1" })
    ClickSurfaces.add("card", 20, 20, 30, 40, { poke = "card:1" })
    ClickSurfaces.add("chips", 100, 50, 40, 30, { pile = "pot:1" })
    ClickSurfaces.add("denied", 150, 10, 40, 20, { poke = "button:upg" })
    ClickSurfaces.add("item", 300, 300, 50, 50, { item = "candle", poke = "item:candle" })
end

-- ── surfaces ────────────────────────────────────────────────────────────
frame()
c.eq(ClickSurfaces.at(25, 25).material, "card", "the card over the felt wins")
c.eq(ClickSurfaces.at(5, 5).material, "felt", "the felt where no card is")
c.eq(ClickSurfaces.at(900, 900).material, "wall", "nothing registered: the wall")
local n1 = ClickSurfaces.count()
frame()
c.eq(ClickSurfaces.count(), n1, "a frame re-registers the same count (records reused)")

local function click(x, y, inside)
    ClickFX.begin(x, y)
    if inside then inside() end
    return ClickFX.finish()
end
local function last() return played[#played] end

-- ── outcomes ────────────────────────────────────────────────────────────
clock = clock + 5
played = {}
local out, surf = click(5, 5)
c.eq(out, "dead", "a click nothing took is dead")
c.eq(surf.material, "felt", "on the felt")
c.eq(last().name, "click_felt", "the felt's sound")
c.ok(Sparks.count() >= Data.materials.felt.specks, "felt specks (and the ring) thrown")
c.ok(not Poke.active("felt:1"), "the felt has no spring (its reaction is the ring)")

clock = clock + 5
played = {}
Sparks.clear()
out = click(5, 5, function() ClickFlash.press("hit", "deal:1") end)
c.eq(out, "result", "a press inside the click is a result")
c.ok(math.abs(last().vol - Data.materials.felt.volume * Data.result.surface_volume) < 1e-9,
     "the surface sound goes under a result at the result share")
c.ok(Sparks.count() >= Data.materials.felt.specks + Data.result.specks, "a gold burst over the felt's specks")

clock = clock + 5
played = {}
out = click(160, 15)
c.eq(out, "denied", "a click on a disabled button's surface is denied")
c.eq(last().name, "click_denied", "the thunk")
c.ok(Poke.active("button:upg"), "the refused button shakes")

clock = clock + 5
played = {}
out = click(5, 5, function() ClickFlash.deny("hit", "rebuy:7") end)
c.eq(out, "denied", "a handler's deny is denied")
c.ok(Poke.active("hit:rebuy:7"), "the denied control is shaken by its press key")

clock = clock + 5
played = {}
out = click(25, 25)
c.eq(last().name, "click_card", "a card: the card flick")
c.ok(Poke.active("card:1"), "the card jumps")

clock = clock + 5
played, piles = {}, {}
click(110, 60)
c.eq(piles[1], "pot:1", "a chip pile is handed to the pile hook")

clock = clock + 5
played, items = {}, {}
click(310, 310)
c.eq(items[1], "candle", "a room item plays its own foley")
c.eq(#played, 0, "and no material sound on top")

-- ── streak ──────────────────────────────────────────────────────────────
clock = clock + 5
played = {}
for _ = 1, 12 do clock = clock + 0.1; click(900, 900) end
c.eq(ClickFX.streak(), Data.streak.cap, "rapid clicks climb to the cap")
c.ok(played[#played].pitch > played[1].pitch, "the pitch climbs with the streak")
clock = clock + 2
click(900, 900)
c.eq(ClickFX.streak(), 0, "a pause resets the streak")

-- ── cursor ──────────────────────────────────────────────────────────────
clock = clock + 5
played = {}
Sparks.clear()
ClickFX.cursor(5, 5)
c.ok(math.abs(last().pitch - Data.materials.felt.pitch * Data.cursor.pitch) < 1e-9, "a cursor's click is pitched up")
c.ok(last().vol < Data.materials.felt.volume, "and quieter")
c.ok(Sparks.count() < Data.materials.felt.specks + Data.result.specks, "and no gold burst")

-- ── sparks ──────────────────────────────────────────────────────────────
Sparks.clear()
for _ = 1, 400 do Sparks.burst(0, 0, Data.materials.felt) end
c.ok(Sparks.count() <= Data.max_specks, "the pool is bounded (" .. Sparks.count() .. ")")
for _ = 1, 60 do Sparks.update(1 / 60) end
c.eq(Sparks.count(), 0, "every speck dies inside a second")
Motion.set("ui", Motion.NONE)
Sparks.burst(0, 0, Data.materials.felt)
c.eq(Sparks.count(), 0, "Motion None throws nothing")
Motion.set("ui", Motion.FULL)

-- ── poke ────────────────────────────────────────────────────────────────
for kind, k in pairs(Poke.KINDS) do
    clock = clock + 5
    Poke.hit("k:" .. kind, kind, 1, 1)
    clock = clock + k.dur * 0.3
    local dx, dy, rot, sc = Poke.offset("k:" .. kind)
    c.ok(dx ~= 0 or dy ~= 0 or rot ~= 0 or sc ~= 1, kind .. " moves")
    clock = clock + k.dur
    dx, dy, rot, sc = Poke.offset("k:" .. kind)
    c.ok(dx == 0 and dy == 0 and rot == 0 and sc == 1, kind .. " comes back to rest")
end

-- ── took ────────────────────────────────────────────────────────────────
-- A click that made its own sound (a room item): specks, no surface sound.
clock = clock + 5
frame()
played = {}
Sparks.clear()
local tout = click(5, 5, function() ClickFlash.took() end)
c.eq(tout, "took", "a click that took (its own foley) is 'took'")
c.eq(#played, 0, "no surface sound under it")
c.ok(Sparks.count() > 0, "but its specks fly")

-- ── a real grind frame ──────────────────────────────────────────────────
-- The board registers its surfaces where it draws them.
do
    local H = require("sim.harness")
    local F = Stub.font(16)
    local w = H.world({ bankroll = 1e6 })
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
    w:open("s001", "zoom")
    w:tick(1)
    local view = require("views.GrindView"):new(g, w.ctrl)
    for _ = 1, 2 do view:update(1 / 60); view:draw(nil) end
    local Anchors = require("services.AnchorRegistry")
    local function centre(name)
        local a = Anchors.get(name)
        return a and (a[1] + (a[3] or 0) * 0.5), a and (a[2] + (a[4] or 0) * 0.5)
    end
    c.ok(ClickSurfaces.count() > 5, "a grind frame registers its surfaces (" .. ClickSurfaces.count() .. ")")
    local hx, hy = centre("house")
    c.eq(hx and ClickSurfaces.at(hx, hy).material, "paper", "the House poster is paper")
    local sx, sy = centre("house:speaker")
    c.eq(sx and ClickSurfaces.at(sx, sy).material, "speaker", "its speaker is the speaker")
    local t1 = w:tables()[1]
    -- The "center" anchor is a centre point already (w and h ride along).
    local ca = Anchors.get(require("models.Table").anchorKey(t1, "center"))
    local tx, ty = ca and ca[1], ca and ca[2]
    local m = tx and ClickSurfaces.at(tx, ty).material
    c.ok(m == "felt" or m == "card" or m == "chips", "a table's middle is its felt or what lies on it (" .. tostring(m) .. ")")
    c.eq(ClickSurfaces.at(view.rail.x + 2, view.rail.y + 2).material, "rail", "the rail's corner is the rail")
end

if c.report("smoke_clicks") > 0 then os.exit(1) end
