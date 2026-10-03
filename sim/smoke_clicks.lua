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

if c.report("smoke_clicks") > 0 then os.exit(1) end
