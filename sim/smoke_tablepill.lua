-- sim/smoke_tablepill.lua
--
-- The table pill ({t:<id>}, views/IconText): every table reference in the
-- copy is one felt-green pill with a tabletop icon and a short code.
--   parse    {t:zoom} is one table element reading ZOOM
--   width    it measures wider than its code alone (pill padding + icon)
--   draw     a filled pill, the tabletop's rects, and the code printed
--   unknown  {t:nope} stays literal text
--   copy     no rule line still writes the old table keywords
--
-- Standalone: `lua sim/smoke_tablepill.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()
local F = Stub.font(16)
local rec = Stub.recorder()
love.graphics.getFont = function() return F end

local IconText = require("views.IconText")

local spans = IconText.spans("Deal a {t:zoom}: every {t:adjacent} {t:zoom}.", F)
local tables = {}
for _, sp in ipairs(spans) do if sp.kind == "table" then tables[#tables + 1] = sp end end
c.eq(#tables, 3, "three table pills in the Energy Drink line")
c.ok(tables[1] and tables[1].text == "ZOOM" and tables[1].token == "zoom", "the first reads ZOOM (id zoom)")
c.ok(tables[2] and tables[2].text == "ADJACENT", "the second reads ADJACENT")

local w_pill = IconText.measure("{t:hu}", F)
c.ok(w_pill > F:getWidth("HU"), ("a pill is wider than its code (%d vs %d)"):format(w_pill, F:getWidth("HU")))

rec.reset()
IconText.draw({}, "{t:6m}", 0, 0, F, { 1, 1, 1 }, 1)
local printed = false
local pr = love.graphics.print
love.graphics.print = function(t, ...) if t == "6M" then printed = true end return pr(t, ...) end
IconText.draw({}, "{t:6m}", 0, 0, F, { 1, 1, 1 }, 1)
love.graphics.print = pr
c.ok((rec.calls.rectangle or 0) >= 4, ("the pill and the tabletop draw as rects (%d)"):format(rec.calls.rectangle or 0))
c.ok(printed, "the code 6M is printed")

local bare = IconText.spans("{table} ADD TABLE", F)
c.ok(bare[1] and bare[1].kind == "icon" and bare[1].token == "table" and bare[1].w > 0,
     "{table} is the tabletop icon alone (ADD TABLE's header)")

local lit = IconText.spans("{t:nope}", F)
c.eq(#lit, 0, "an unknown {t:…} stays literal text")

local hits = 0
for _, path in ipairs({ "data/catalog.lua", "data/decks.lua", "data/run_upgrades.lua" }) do
    local fh = io.open(path, "rb"); local s = fh:read("*a"); fh:close()
    for line in s:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then
            for _, k in ipairs({ "{k:Zoom}", "{k:Heads-Up}", "{k:6-Max}", "{k:tournament}", "{k:every_table}", "{k:adjacent}", "{k:a_random_table}" }) do
                if line:find(k, 1, true) then hits = hits + 1 end
            end
        end
    end
end
c.eq(hits, 0, "no copy still writes an old table keyword")

if c.report("smoke_tablepill") > 0 then os.exit(1) end
