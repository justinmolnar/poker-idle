-- sim/lint_terms.lua
--
-- The colour-code lint for copy. Walks every copy field the game draws
-- through views/IconText and checks the {c:<meaning>:<word>} markers
-- against data/terms.lua:
--
--   ERROR  a tinted word that its meaning does not own ({c:heat:catalog})
--   ERROR  a meaning that does not exist ({c:warm:heat})
--   WARN   a bare mechanic word in a block that does not tint that word
--          anywhere (the author may have chosen not to; the lint just asks)
--
--   lua sim/lint_terms.lua           (exit 1 on any ERROR)
--   lua sim/lint_terms.lua --quiet   (errors only)
--
-- Standalone: no LÖVE. The data files' require graph is pure Lua.

io.stdout:setvbuf("no")
love = love or { math = { random = math.random }, timer = { getTime = os.clock } }
package.path = package.path .. ";./?.lua"

local Terms       = require("data.terms")
local Story       = require("data.story")
local Catalog     = require("data.catalog")
local RunUpgrades = require("data.run_upgrades")
local Glossary    = require("data.glossary")
local Statuses    = require("data.statuses")
local Decks       = require("data.decks")
local Hints       = require("data.hints")

local quiet = arg and arg[1] == "--quiet"
local errors, warns = 0, 0

-- word → meaning, from the terms map (lower case)
local OWNER = {}
for cat, words in pairs(Terms.words) do
    for _, w in ipairs(words) do OWNER[w:lower()] = cat end
end
local NEVER = {}
for _, w in ipairs(Terms.never or {}) do NEVER[w:lower()] = true end
local OPTIONAL = {}
for _, w in ipairs(Terms.optional or {}) do OPTIONAL[w:lower()] = true end

local function normalize(w) return (w:gsub("_", " ")):lower() end

local function check(where, text)
    if type(text) ~= "string" or text == "" then return end
    -- 1. every marker
    local tinted = {}
    for cat, word in text:gmatch("{c:([%w_]+):?([^}]*)}") do
        local w = normalize(word ~= "" and word or cat)
        if not Terms.words[cat] then
            errors = errors + 1
            print(("ERROR %s: unknown meaning {c:%s} in %q"):format(where, cat, text))
        else
            local owner = OWNER[w]
            -- plural/possessive tolerance: strip a trailing s or 's
            if not owner then owner = OWNER[(w:gsub("'s$", ""))] end
            if not owner then owner = OWNER[(w:gsub("s$", ""))] end
            if owner ~= cat then
                errors = errors + 1
                print(("ERROR %s: %q tinted %s but belongs to %s in %q"):format(where, w, cat, tostring(owner), text))
            end
            tinted[w] = true
        end
    end
    -- 2. bare mechanic words (outside markers), unless the block tints that word
    if quiet then return end
    local bare = text:gsub("{[^}]*}", " ")
    local lower = bare:lower()
    local seen = {}
    for w, cat in pairs(OWNER) do
        if not tinted[w] and not seen[w] and not OPTIONAL[w] then
            local s = lower:find("%f[%w]" .. w:gsub("%-", "%%-") .. "%f[%W]")
            if s then
                seen[w] = true
                warns = warns + 1
                print(("warn  %s: bare %-12s (%s) in %q"):format(where, w, cat, text))
            end
        end
    end
end

-- ── walk ──────────────────────────────────────────────────────────────
for _, beat in ipairs(Story.beats) do
    for i, line in ipairs(beat.lines or {}) do
        check(("story %s:%d"):format(beat.id, i), line.text)
    end
end
for k, v in pairs(Story.shove) do check("story shove:" .. k, v.text) end

for _, it in ipairs(Catalog) do
    check("catalog " .. it.id .. " effect", it.effect_text)
    check("catalog " .. it.id .. " desc", it.description)
    if it.corrupt then check("catalog " .. it.id .. " corrupt", it.corrupt.effect_text) end
    if it.unlock then check("catalog " .. it.id .. " unlock", it.unlock.text) end
end
for _, up in ipairs(RunUpgrades) do
    check("upgrade " .. up.id .. " desc", up.description)
    local tb = up.tooltip_blurb
    if type(tb) == "string" then check("upgrade " .. up.id .. " blurb", tb)
    elseif type(tb) == "table" then for i, l in ipairs(tb) do check(("upgrade %s blurb:%d"):format(up.id, i), l) end end
end
for _, g in ipairs(Glossary) do
    check("glossary " .. g.id .. " term", g.term)
    if type(g.text) == "string" then check("glossary " .. g.id, g.text)
    else for i, l in ipairs(g.text or {}) do check(("glossary %s:%d"):format(g.id, i), l) end end
end
for id, st in pairs(Statuses) do
    if type(st) == "table" and st.blurb then check("status " .. tostring(id), st.blurb) end
end
for _, d in ipairs(Decks) do
    if d.bonus then check("deck " .. d.id .. " bonus", d.bonus.text) end
    if d.capstone then check("deck " .. d.id .. " capstone", d.capstone.text) end
    if d.unlock then check("deck " .. d.id .. " unlock", d.unlock.text) end
end
for _, h in ipairs(Hints) do
    if type(h.text) == "string" then check("hint " .. h.id, h.text)
    else for i, l in ipairs(h.text or {}) do check(("hint %s:%d"):format(h.id, i), l) end end
end

print(("\n%d error%s, %d warning%s"):format(errors, errors == 1 and "" or "s", warns, warns == 1 and "" or "s"))
os.exit(errors > 0 and 1 or 0)
