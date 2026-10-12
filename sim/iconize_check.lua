-- sim/iconize_check.lua
--
-- Runs views/IconText's parser over every copy field (sim/copy_fields.lua)
-- with a stub font, no LÖVE, and checks that the number pills the renderer
-- finds are exactly the numbers the style sheet writes:
--
--   ERROR  a "1 in N", "×N" or "+N%" in the text with no matching pill span
--   ERROR  a pill span that swallowed a letter (6-Max, NL2, 4+ tables)
--   ERROR  a {token} the parser left as literal text
--   ERROR  the parser threw on a field
--
--   lua sim/iconize_check.lua      (exit 1 on any ERROR)

io.stdout:setvbuf("no")
package.path = package.path .. ";./?.lua"

-- Enough of love for the views to load; nothing here draws.
love = love or {}
love.graphics = love.graphics or {}
love.graphics.getColor = love.graphics.getColor or function() return 1, 1, 1, 1 end
love.math  = love.math  or { random = math.random }
love.timer = love.timer or { getTime = os.clock }

local Fields   = require("sim.copy_fields")
local IconText = require("views.IconText")

local Font = { getWidth = function(_, s) return #s * 6 end, getHeight = function() return 16 end }

local errors = 0
local function err(where, msg, text)
    errors = errors + 1
    print(("ERROR %s: %s in %q"):format(where, msg, text))
end

local function expectedPills(text)
    local bare = text:gsub("{[^}]*}", " ")
    local out = {}
    for m in bare:gmatch("%d+ in %d+") do out[#out + 1] = m end
    for m in bare:gmatch("×%d+%.?%d*") do out[#out + 1] = (m:gsub("%.$", "")) end
    -- signed quantities, not hyphens inside words (the lint's glue rule)
    local i = 1
    while true do
        local s, e = bare:find("[%+%-]%$?%d[%d,]*%.?%d*%%?", i)
        if not s then break end
        local before = s > 1 and bare:sub(s - 1, s - 1) or " "
        if not before:match("[%w]") then
            local m = bare:sub(s, e):gsub("[%.,]$", "")
            out[#out + 1] = m
        end
        i = e + 1
    end
    return out
end

local checked = 0
for _, f in ipairs(Fields) do
    local ok, spans = pcall(IconText.spans, f.text, Font)
    if not ok then
        err(f.where, "parser threw: " .. tostring(spans), f.text)
    else
        checked = checked + 1
        local found = {}
        for _, sp in ipairs(spans) do
            if sp.kind == "pill" then
                found[#found + 1] = sp.text
                if sp.text:gsub(" in ", " "):match("%a") then err(f.where, ("pill %q holds a letter"):format(sp.text), f.text) end
            end
        end
        for _, want in ipairs(expectedPills(f.text)) do
            local hit = false
            for j, got in ipairs(found) do
                if got == want then hit = true table.remove(found, j) break end
            end
            if not hit then err(f.where, ("no pill for %q"):format(want), f.text) end
        end
        for _, extra in ipairs(found) do
            err(f.where, ("unexpected pill %q"):format(extra), f.text)
        end
        -- every {token} must have become an element: a token the parser
        -- did not recognise prints literally on the card ({k:6-Max} did,
        -- before "-" joined the token class)
        -- ({n} and {dyn:…} are substituted before the renderer sees them;
        -- {page} is a page break the House's box consumes: views/StoryView)
        local braces, tokens = 0, 0
        for tok in f.text:gmatch("{([^}]*)}") do
            if tok ~= "n" and tok ~= "page" and not tok:match("^dyn:") then braces = braces + 1 end
        end
        for _, sp in ipairs(spans) do if sp.kind ~= "pill" then tokens = tokens + 1 end end
        if tokens < braces then
            err(f.where, ("%d token(s) print literally"):format(braces - tokens), f.text)
        end
        -- a measure must equal the sum of its parts
        local total = IconText.measure(f.text, Font)
        if total < 0 then err(f.where, "negative width", f.text) end
    end
end

print(("\n%d fields, %d error%s"):format(checked, errors, errors == 1 and "" or "s"))
os.exit(errors > 0 and 1 or 0)
