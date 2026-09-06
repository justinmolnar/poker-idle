-- sim/copy_fields.lua
--
-- Every player-facing copy field the game draws, in one list, so the two
-- lints (sim/lint_terms.lua for the colour code, sim/lint_copy.lua for the
-- style sheet) walk the same fields and never drift. Standalone: no LÖVE.
--
-- Returns a list of { where, text, kind, item } in display order, where
--   where  a label for the report ("catalog rubber_duck effect")
--   text   the string
--   kind   "story"   a House line (story_only words allowed)
--          "rule"    a mechanical line: effect_text, corrupt effect, deck
--                    bonus/capstone, status blurb, upgrade desc/blurb
--          "flavor"  everything else: descriptions, glossary, rail, hints,
--                    unlock stickers
--   item   the owning data entry (catalog item, deck, upgrade...) when
--          the lint needs its effects; nil otherwise
--   slot   for a catalog item: "base" or "corrupt"

love = love or { math = { random = math.random }, timer = { getTime = os.clock } }
package.path = package.path .. ";./?.lua"

local Story       = require("data.story")
local Catalog     = require("data.catalog")
local RunUpgrades = require("data.run_upgrades")
local Glossary    = require("data.glossary")
local Statuses    = require("data.statuses")
local Decks       = require("data.decks")
local Hints       = require("data.hints")
local Rail        = require("data.rail")

local fields = {}
local function add(where, text, kind, item, slot)
    if type(text) ~= "string" or text == "" then return end
    fields[#fields + 1] = { where = where, text = text, kind = kind, item = item, slot = slot }
end
local function addList(where, v, kind, item)
    if type(v) == "string" then add(where, v, kind, item)
    elseif type(v) == "table" then
        for i, l in ipairs(v) do add(("%s:%d"):format(where, i), l, kind, item) end
    end
end

for _, beat in ipairs(Story.beats) do
    for i, line in ipairs(beat.lines or {}) do
        add(("story %s:%d"):format(beat.id, i), line.text, "story")
    end
end
for k, v in pairs(Story.shove) do add("story shove:" .. k, v.text, "story") end

for _, it in ipairs(Catalog) do
    add("catalog " .. it.id .. " effect", it.effect_text, "rule", it, "base")
    add("catalog " .. it.id .. " desc", it.description, "flavor", it)
    if it.corrupt then add("catalog " .. it.id .. " corrupt", it.corrupt.effect_text, "rule", it, "corrupt") end
    if it.unlock then add("catalog " .. it.id .. " unlock", it.unlock.text, "flavor", it) end
end
for _, up in ipairs(RunUpgrades) do
    add("upgrade " .. up.id .. " desc", up.description, "rule", up)
    addList("upgrade " .. up.id .. " blurb", up.tooltip_blurb, "rule", up)
end
for _, g in ipairs(Glossary) do
    add("glossary " .. g.id .. " term", g.term, "flavor")
    addList("glossary " .. g.id, g.text, "flavor")
end
for id, st in pairs(Statuses) do
    if type(st) == "table" and st.blurb then add("status " .. tostring(id), st.blurb, "rule", st) end
end
for _, d in ipairs(Decks) do
    if d.bonus then add("deck " .. d.id .. " bonus", d.bonus.text, "rule", d, "bonus") end
    if d.capstone then add("deck " .. d.id .. " capstone", d.capstone.text, "rule", d, "capstone") end
    if d.unlock then add("deck " .. d.id .. " unlock", d.unlock.text, "flavor", d) end
end
-- (Rail.labels are the chrome's own words, plain by the colour code: not linted.)
for k, v in pairs(Rail.locked)   do add("rail locked " .. k, v, "flavor") end
for k, v in pairs(Rail.tooltips) do addList("rail tip " .. k, v, "flavor") end
for k, v in pairs(Rail.gtype)    do add("rail gtype " .. k, v, "flavor") end
for _, h in ipairs(Hints) do addList("hint " .. h.id, h.text, "flavor") end

return fields
