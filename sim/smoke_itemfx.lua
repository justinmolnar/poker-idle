-- sim/smoke_itemfx.lua
--
-- Items shown where they act (views/ItemStream, data/item_fx.lua):
--   attribution  an item_fired event names the table that set it off and
--                the tables it landed on, with a word for what it did
--                (an Energy Drink deal: "dealt", on the neighbour it dealt)
--   pop          a fire on its own table pops there with its word
--   flight       a fire that landed elsewhere flies there, then pops
--   merge        the same item on the same table again merges (a count)
--   cap          the stream never holds more than its cap
--
-- Standalone: `lua sim/smoke_itemfx.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local H = require("sim.harness")
local AR = require("services.AnchorRegistry")
local TableModel = require("models.Table")
local ItemStream = require("views.ItemStream")
local Fx = require("data.item_fx")

local w = H.world({ bankroll = 1e9 })
local g = w.game
local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
              getDimensions = function() return 32, 32 end, setFilter = function() end, release = function() end }
g.sprite_loader = { itemArt = function() return img, nil, nil, false end }

-- ── attribution ────────────────────────────────────────────────────────
local a = w:open("s001", "zoom")
local b = w:open("s001", "zoom")
w:own("energy_drink")
w:tick(0.05)
-- Centre anchors where the view would put them (side by side).
AR.set(TableModel.anchorKey(a, "center"), 100, 100, 200, 150)
AR.set(TableModel.anchorKey(b, "center"), 320, 100, 200, 150)
local seen = {}
-- The bus recycles an event once delivered: keep a copy.
g.event_bus:subscribe("item_fired", function(e)
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    seen[#seen + 1] = copy
end)
local slots_adjacent = math.abs((a.slot or 0) - (b.slot or 0)) == 1
w.ctrl:dealHand(w:find(a))
w:tick(0.05)
g.event_bus:drain()
local ev
for _, e in ipairs(seen) do if e.item_id == "energy_drink" then ev = e end end
if slots_adjacent then
    c.ok(ev ~= nil, "an Energy Drink deal announces itself")
    c.ok(ev and ev.table_id == a._id, "naming the table that set it off")
    c.ok(ev and ev.targets and ev.targets[1] and ev.targets[1].id == b._id, "and the neighbour it dealt")
    c.ok(ev and ev.what and ev.what.text == "dealt", "with what it did: dealt")
else
    c.ok(true, "(the two tables are not side by side; attribution skipped)")
end

-- A direct call with targets: the event carries their rects.
seen = {}
w.ctrl:procFired("gaming_chair", a, { b }, Fx.payload.apply_status.heater)
g.event_bus:drain()
local e2 = seen[#seen]
c.ok(e2 and e2.targets and e2.targets[1].x == 320 and e2.what.text == "heater",
     "a fire aimed elsewhere carries where it landed and what it did")

-- ── pop / flight / merge / cap ─────────────────────────────────────────
ItemStream.clear()
ItemStream.spawn(g, "candle", 100, 100, 200, 150, { what = Fx.payload.apply_status.heater })
local icons = ItemStream.debugIcons()
c.ok(#icons == 1 and icons[1].kind == "pop" and icons[1].x0 == 100, "a fire on its own table pops there")
ItemStream.spawn(g, "candle", 100, 100, 200, 150, { what = Fx.payload.apply_status.heater })
c.ok(#icons == 1 and icons[1].count == 2, "the same item on the same table again merges into a count")

ItemStream.clear()
ItemStream.spawn(g, "gaming_chair", 100, 100, 200, 150,
    { what = Fx.payload.apply_status.heater, targets = { { x = 320, y = 100, w = 200, h = 150 } } })
icons = ItemStream.debugIcons()
local fly, pop
for _, ic in ipairs(icons) do
    if ic.kind == "fly" then fly = ic elseif ic.kind == "pop" then pop = ic end
end
c.ok(fly and fly.x0 == 100 and fly.x1 == 320, "a fire that landed elsewhere flies from the source to the target")
c.ok(pop and pop.x0 == 320 and pop.t < 0, "and pops on the target once it lands")
ItemStream.update(Fx.fly_time + 0.01)
c.ok(pop.t > 0, "the pop shows after the flight")

ItemStream.clear()
for i = 1, Fx.max_live + 30 do
    ItemStream.spawn(g, "candle", i * 40, 100, 30, 30, nil)
end
c.ok(#ItemStream.debugIcons() <= Fx.max_live, "the stream holds at most " .. Fx.max_live .. " icons")

ItemStream.clear()
ItemStream.spawn(g, "trophy_shelf", nil, nil, nil, nil, { what = Fx.kinds.bounty_double_chance })
icons = ItemStream.debugIcons()
c.ok(#icons == 1 and icons[1].kind == "float", "a fire with no table floats up the table area")

-- ── the last run ────────────────────────────────────────────────────────
-- What each item did is frozen when the run resets, so the shove's recap
-- and the catalog card can still say it once the next run's counts start.
do
    local st = w.state
    st.item_fires_run = { energy_drink = 292, dogs_playing_poker = 3 }
    st.item_heaters_run = { dogs_playing_poker = 11 }
    local live = st:itemRecap(4)
    c.ok(live[1] and live[1].id == "energy_drink" and live[1].fires == 292, "the recap reads the live run, most active first")
    st:resetRun()
    c.ok(next(st.item_fires_run) == nil and next(st.item_heaters_run) == nil, "the reset starts the counts over")
    local rows = st:itemRecap(4)
    c.ok(#rows == 2 and rows[2].id == "dogs_playing_poker" and rows[2].heaters == 11,
         "and the recap reads the frozen last run, heaters included")
    local CR = require("views.CatalogReceipt")
    local Lookups = require("utils.lookups")
    local Catalog = require("models.catalog_loader").deriveAll(require("data.catalog"))
    local card = CR.itemCard(g, Lookups.findById(Catalog, "dogs_playing_poker"), false)
    local said = false
    for _, r in ipairs(card or {}) do
        if type(r.text) == "string" and r.text:find("Last run: fired 3 times, 11 heaters", 1, true) then said = true end
    end
    c.ok(said, "the catalog card says what it did last run")
end

-- ── the header's item row (models/table_modifiers) ─────────────────────
do
    local TM = require("models.table_modifiers")
    local ctx = { odds_per_empty_adjacent = 0.05, lonely_winnings_mult = 1.5,
                  zoom_block_pace = 0.10, stack_odds_per_hu_table = 0.02, hu_table_count = 3,
                  sources = { odds_per_empty_adjacent = { "yellow_sticky_note" },
                              lonely_winnings_mult = { "throw_pillow" },
                              zoom_block_pace = { "receipt_printer" },
                              hu_stack_odds_per_hu_table = { "mirror" } } }
    local t = { game_type_id = "zoom", _empty_adjacent = 2, _lonely = false, _zoom_neighbours = 1 }
    local n, sig = TM.stamp(t, ctx)
    c.ok(n == 2 and t._mods[1].item == "yellow_sticky_note" and t._mods[1].text == "+10%",
         "a gap table shows the Sticky Note at +10% (2 empty sides)")
    c.ok(t._mods[2].item == "receipt_printer" and t._mods[2].text == "+10%", "and the Receipt Printer's Zoom neighbour")
    local first = t._mods[1].tip
    local n2, sig2 = TM.stamp(t, ctx)
    c.ok(sig2 == sig and t._mods[1].tip == first, "a steady board keeps its signature (the panel does not rebuild)")
    t._empty_adjacent = 3
    local _, sig3 = TM.stamp(t, ctx)
    c.ok(sig3 ~= sig and t._mods[1].text == "+15%", "a neighbour moving changes the row")
    local h = { game_type_id = "hu", _empty_adjacent = 0, _lonely = true }
    TM.stamp(h, ctx)
    c.ok(h._mods_n == 2 and h._mods[1].item == "throw_pillow" and h._mods[2].item == "mirror",
         "a lone Heads-Up table shows the Pillow and the Mirror")
end

-- ── counters where they act ─────────────────────────────────────────────
do
    -- The pace's speed-up, readable on its own (the badge's number).
    local z = w:open("s001", "zoom")
    z._zoom_neighbours = 2
    local base_mult, boost0 = z:paceParts({})
    local _, boost = z:paceParts({ zoom_block_pace = 0.10 })
    c.ok(math.abs(boost - boost0 * 1.2) < 1e-9, "two Zoom neighbours with the Receipt Printer: x1.2 pace")

    -- The board on screen: the badge and the rail's live counters.
    local F = Stub.font(16)
    g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
    g.state_machine = { states = {}, switch = function() end, current = function() return "grind" end }
    g.sprite_loader = { getSprite = function() return img end, getSpriteFor = function() return img end,
        hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
        setSprite = function() end, itemArt = function() return img, nil, nil, false end }
    Stub.recorder()
    love.graphics.newFont = function() return F end
    love.graphics.getFont = function() return F end
    love.graphics.newShader = function() return { send = function() end } end
    w:own("receipt_printer"); w:own("hybrid_console"); w:own("desk_speakers")
    w:tick(0.05)
    local view = require("views.GrindView"):new(g, w.ctrl)
    g.sim_frozen = true
    local printed = {}
    local pr = love.graphics.print
    love.graphics.print = function(t, ...) if type(t) == "string" then printed[#printed + 1] = t end return pr(t, ...) end
    for _ = 1, 3 do
        AR.tick(); require("services.HoverService").clear()
        view:update(1 / 60); view:draw(nil)
    end
    love.graphics.print = pr
    local badge = false
    for _, t in ipairs(printed) do if t:find(" pace", 1, true) then badge = true end end
    c.ok(badge, "a sped-up Zoom table shows its pace badge")
    local function hasAnchor(comps, name)
        for _, cmp in ipairs(comps or {}) do
            if cmp.anchor == name then return true end
            if cmp.children and hasAnchor(cmp.children, name) then return true end
        end
        return false
    end
    local rail = view:_buildRailComponents()
    c.ok(hasAnchor(rail, "cell:hands_s") and hasAnchor(rail, "cell:heaters"),
         "the rail shows HANDS/S and HEATERS while their items are owned")
end

if c.report("smoke_itemfx") > 0 then os.exit(1) end
