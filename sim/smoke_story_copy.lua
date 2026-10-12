-- sim/smoke_story_copy.lua
--
-- The House's beats (data/story.lua), checked as data:
--   cues      every forced line (force + wait) has a cue
--   tokens    every {...} marker is one the renderer knows
--   anchors   every anchor a line points at is a name some view registers
--             (an exact string in a view, or a known built-from-index family)
--   pages     with LOVE's real font (run `lovec sim/story_copy` from the repo
--             root), no page of any line is taller than the box at the
--             narrowest frame; headless, the stub font approximates it
--
-- Standalone: `lua sim/smoke_story_copy.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local real_love = love and love.graphics and love.graphics.newFont and love.filesystem and love.filesystem.getInfo
local Stub = require("sim.love_stub")
if not real_love then Stub.base() end
local c = Stub.checker()

local Story    = require("data.story")
local HintView = require("views.HintView")

-- Every source a view registers anchors in.
local SRC = {}
for _, dir in ipairs({ "views", "states", "controllers" }) do
    local p = io.popen('dir /b "' .. dir .. '\\*.lua" 2>nul')
    if p then
        for f in p:lines() do
            local fh = io.open(dir .. "/" .. f, "r")
            if fh then SRC[#SRC + 1] = fh:read("*a"); fh:close() end
        end
        p:close()
    end
end
local all_src = table.concat(SRC, "\n")
-- Names built from an index or a key at runtime, by prefix.
local FAMILIES = { "ev:", "stack_pct:", "stack:", "table:", "add_table:", "add_table_chip:", "add_table_ev:",
                   "gtype:", "buy_runup_", "info:", "shove:cheat_", "catalog:", "deck:", "cell:", "chip_badge:",
                   "room:", "btn:", "rebuy:" }
local function registered(name)
    if all_src:find('"' .. name .. '"', 1, true) then return true end
    for _, fam in ipairs(FAMILIES) do
        if name:sub(1, #fam) == fam and all_src:find('"' .. fam, 1, true) then return true end
    end
    return false
end

local KNOWN = { chip = true, achip = true, page = true, arrow = true, table = true }
local function tokensOk(text)
    for tok in text:gmatch("{([^}]*)}") do
        if not (KNOWN[tok] or tok:match("^[cwlkt]:") or tok:match("^dyn:") or tok:match("^item:")) then
            return false, tok
        end
    end
    return true
end

local font, text_w, per
if real_love then
    local Theme = require("views.Theme")
    local FontService = require("services.FontService")
    local W, H = 1440, 900
    local fonts = FontService.build(Theme.font, W, H)
    font = fonts.sm
    local ui = FontService.layoutScale(W, H)
    local rw = math.max(320, math.floor(W * 0.22))
    text_w = rw - 2 * math.floor(12 * ui) - 2 * math.floor(10 * ui)
    per = 3
    print(("LOVE: font %dpx, text width %d, %d lines a page"):format(font:getHeight(), text_w, per))
else
    font, text_w, per = Stub.font(21), 266, 3
end

local n_lines, worst, worst_id = 0, 0, nil
for _, beat in ipairs(Story.beats) do
    for i, line in ipairs(beat.lines or {}) do
        local id = beat.id .. "#" .. i
        n_lines = n_lines + 1
        local text = tostring(line.text or "")
        if line.force and line.wait then
            c.ok(line.cue ~= nil and line.cue ~= "", id .. ": a forced line has a cue")
        end
        local ok, tok = tokensOk(text)
        c.ok(ok, id .. ": tokens are known" .. (ok and "" or (" (" .. tostring(tok) .. ")")))
        local anchors = line.anchor
        if type(anchors) == "string" then anchors = { anchors } end
        for _, a in ipairs(anchors or {}) do
            c.ok(registered(a), id .. ": anchor " .. a .. " is registered by a view")
        end
        -- Pages: each {page} part, wrapped, is at most `per` lines.
        for part in (text:gsub("{dyn:[^}]*}", "00000") .. "{page}"):gmatch("(.-){page}") do
            local lines = HintView.wrapLines(part, font, text_w)
            if #lines > worst then worst, worst_id = #lines, id end
            if real_love then
                c.ok(#lines <= per, id .. (": a page fits the box (%d lines)"):format(#lines))
            end
        end
    end
end
c.ok(n_lines > 60, "the beats were read (" .. n_lines .. " lines)")
print(("tallest page: %d lines (%s)"):format(worst, tostring(worst_id)))

local fails = c.report("smoke_story_copy")
if real_love then love.event.quit(fails > 0 and 1 or 0) elseif fails > 0 then os.exit(1) end
