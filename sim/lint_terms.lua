-- sim/lint_terms.lua
--
-- The colour-code lint for copy. Walks every copy field the game draws
-- through views/IconText (sim/copy_fields.lua) and checks the
-- {c:<meaning>:<word>} markers against data/terms.lua:
--
--   ERROR  a tinted word that its meaning does not own ({c:heat:catalog})
--   ERROR  a meaning that does not exist ({c:warm:heat})
--   ERROR  a story-only word tinted outside a story beat ("on fire")
--   WARN   a bare mechanic word in a block that does not tint that word
--          anywhere (the author may have chosen not to; the lint just asks)
--
--   lua sim/lint_terms.lua           (exit 1 on any ERROR)
--   lua sim/lint_terms.lua --quiet   (errors only)
--
-- The style sheet itself (retired words, number forms) is sim/lint_copy.lua.
-- Standalone: no LÖVE. The data files' require graph is pure Lua.

io.stdout:setvbuf("no")
package.path = package.path .. ";./?.lua"

local Terms  = require("data.terms")
local Fields = require("sim.copy_fields")

local quiet = arg and arg[1] == "--quiet"
local errors, warns = 0, 0

-- word → meaning, from the terms map (lower case)
local OWNER = {}
for cat, words in pairs(Terms.words) do
    for _, w in ipairs(words) do OWNER[w:lower()] = cat end
end
local OPTIONAL = {}
for _, w in ipairs(Terms.optional or {}) do OPTIONAL[w:lower()] = true end
local STORY_ONLY = {}
for _, w in ipairs(Terms.story_only or {}) do STORY_ONLY[w:lower()] = true end

local function normalize(w) return (w:gsub("_", " ")):lower() end

local function check(where, text, kind)
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
            elseif STORY_ONLY[w] and kind ~= "story" then
                errors = errors + 1
                print(("ERROR %s: %q is the House's word; rule copy says %q in %q"):format(where, w, "heater", text))
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

for _, f in ipairs(Fields) do check(f.where, f.text, f.kind) end

print(("\n%d error%s, %d warning%s"):format(errors, errors == 1 and "" or "s", warns, warns == 1 and "" or "s"))
os.exit(errors > 0 and 1 or 0)
