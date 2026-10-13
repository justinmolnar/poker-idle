-- sim/smoke_beat_browser.lua
--
-- The beat browser (controllers/BeatBrowser, F9 in dev builds), headless:
--   park     entering parks the game (saving is a no-op) and leaving
--            restores the state exactly and switches back
--   walk     every beat builds its stage and every line is reached by
--            stepping, with no error
--   anchors  the ANCHOR REPORT: per beat and line, which targets the
--            stage lit and which it did not (a gap in the stage recipe,
--            printed, never a failure here — the demo lint holds the
--            registration check)
--   notes    a note written is read back
--
-- Standalone: `lua sim/smoke_beat_browser.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Constants = require("data.constants")
local H = require("sim.harness")
Constants.FEATURES.DEV_HOTKEYS = true
Constants.FEATURES.DECKS = true

local F = Stub.font(16)
local w = H.world({ act2 = false, gates = true, bankroll = 50 })
local g = w.game
g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
              getDimensions = function() return 32, 32 end, setFilter = function() end, release = function() end }
g.sprite_loader = { getSprite = function() return img end, getSpriteFor = function() return img end,
                    hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
                    setSprite = function() end, itemArt = function() return img end }
Stub.recorder()
love.graphics.newFont = function() return F end
love.graphics.getFont = function() return F end
love.timer.getDelta = love.timer.getDelta or function() return 1 / 60 end
love.keyboard.setKeyRepeat = function() end
Stub.memoryFS()                                        -- the notes go to the stub save dir
love.filesystem.getSource = function() return "" end
g.sounds = { playNamed = function() end, stopNamed = function() end }
g.animations = require("services.AnimationSystem")

-- The story and the hints, as main.lua builds them.
local UnlockRegistry = require("services.UnlockRegistry")
local HintRules      = require("models.hint_rules")
g.hint_rules = UnlockRegistry:new()
HintRules.registerAll(g.hint_rules)
g.hints      = require("controllers.HintController"):new(g)
g.hint_view  = require("views.HintView"):new(g)
g.story      = require("controllers.StoryDirector"):new{ game = g, rules = g.hint_rules,
                                                          story = require("data.story"), save = function() g.save() end }
g.story_view = require("views.StoryView"):new(g)
local AnchorRegistry = require("services.AnchorRegistry")
local HintCtx = require("controllers.hint_ctx")
local hint_deps = { game = g, anchor_fresh = function(name) return AnchorRegistry.age(name) <= 1 end }
local hint_ctx_t = {}
g.hint_ctx = function() return HintCtx.fill(hint_ctx_t, hint_deps) end
g.state_machine = require("controllers.StateMachine"):new(g)
g.state_machine:register("grind", require("states.GrindState"):new(g))
g.state_machine:register("shove", require("states.ShoveState"):new(g))
g.state_machine:register("room",  require("states.RoomState"):new(g))
g.state_machine:register("title", require("states.TitleState"):new(g))
g.state_machine:switch("grind")

local saves = 0
g.save = function() saves = saves + 1; return true end

-- A canonical print of a table (sorted keys), for comparing states.
local function canon(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return tostring(v) end
    if depth > 12 then return "…" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) .. "\0" .. type(k) end
    table.sort(keys)
    local parts = {}
    for _, kk in ipairs(keys) do
        local name, kt = kk:match("^(.-)%z(.*)$")
        local k = (kt == "number") and tonumber(name) or name
        parts[#parts + 1] = name .. "=" .. canon(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function frame()
    AnchorRegistry.tick()
    g.state_machine:update(1 / 30)
    local ctx = g.hint_ctx()
    g.story:update(1 / 30, ctx, false)
    if g.beat_browser then g.beat_browser:update(1 / 30) end
    g.state_machine:draw()
    local line = g.story:currentLine()
    if line and not g.story:isPaused() then
        g.story_view:draw(line, { holding = g.story:isHoldingClick(), graced = g.story:anchorGraceElapsed() })
    end
end

local BeatBrowser = require("controllers.BeatBrowser")
local bb = BeatBrowser:new(g)
g.beat_browser = bb

-- park
w:open("s001", "zoom")
g.state.chips = 7
local before = canon({ meta = g.state:serializeMeta(), run = g.state:serializeRun() })
local real_save = g.save
bb:enter()
c.ok(bb:active(), "entering turns the browser on")
c.ok(g.save ~= real_save, "saving is parked")
local n0 = saves
frame(); frame()
c.eq(saves, n0, "nothing on the stage saves")

-- walk + anchors
local beats = g.story.story.beats
local report, failures = {}, 0
for i, beat in ipairs(beats) do
    local ok, err = pcall(function()
        bb:gotoBeat(i, 1)
        local guard = 0
        while bb._driver and guard < 400 do frame(); guard = guard + 1 end
        assert(not bb._driver, "the stage never finished building (" .. tostring(bb.recipe and bb.recipe.desc) .. ")")
        -- The stage is built from nothing: no tables carried over from the last one.
        local want = #(bb.recipe.tables or {})
        if not bb.recipe.shove and not bb.recipe.over_focus then
            assert(g.grind.pool:count() == want, ("%d tables on stage, the recipe has %d"):format(g.grind.pool:count(), want))
        end
        assert(g.story.beat ~= nil and g.story.beat.id == beat.id, "the beat is not on stage")
        local seen = {}
        local steps = 0
        while g.story.beat and g.story.beat.id == beat.id and steps < 40 do
            frame(); frame()
            local line = g.story:currentLine()
            local li = line and line.index
            if li and not seen[li] then
                seen[li] = true
                local src = beat.lines[li]
                local names = src and src.anchor or {}
                if type(names) == "string" then names = { names } end
                local lit, missing = {}, {}
                for _, a in ipairs(names) do
                    if require("views.HintMarks").freshAnchor(a) then lit[#lit + 1] = a else missing[#missing + 1] = a end
                end
                report[#report + 1] = { beat = beat.id, line = li, lit = lit, missing = missing,
                                        shown = line ~= nil and not g.story:isPaused() }
            end
            steps = steps + 1
            local was = bb.beat_i
            bb:step(1)
            if bb.beat_i ~= was then break end
            guard = 0
            while bb._driver and guard < 400 do frame(); guard = guard + 1 end
        end
        for li = 1, #beat.lines do
            assert(seen[li], ("line %d was never reached (%d steps)"):format(li, steps))
        end
    end)
    if not ok then failures = failures + 1 end
    c.ok(ok, beat.id .. ": builds and walks: " .. tostring(err))
end

print("\nANCHOR REPORT (the stage's gaps):")
local gaps = 0
for _, r in ipairs(report) do
    if #r.missing > 0 then
        gaps = gaps + 1
        print(("  %-18s #%d  missing: %s%s"):format(r.beat, r.line, table.concat(r.missing, " "),
              #r.lit > 0 and ("   (lit: " .. table.concat(r.lit, " ") .. ")") or ""))
    end
end
print(("  %d line(s) with a missing target, of %d"):format(gaps, #report))

-- notes
bb:gotoBeat(1, 1)
bb:_beginEdit("line"); bb:textinput("a note"); bb:_endEdit()
c.eq(bb.notes.beats[beats[1].id].lines["1"], "a note", "a line note is kept")
bb:_loadNotes()
c.eq(bb.notes.beats[beats[1].id] and bb.notes.beats[beats[1].id].lines["1"], "a note", "and read back from the file")

-- restore
bb:exit()
c.ok(not bb:active(), "leaving turns the browser off")
c.ok(g.save == real_save, "saving is back")
c.eq(g.state_machine:current(), "grind", "back on the screen it left")
local after = canon({ meta = g.state:serializeMeta(), run = g.state:serializeRun() })
c.ok(after == before, "the state is exactly what it was")
c.eq(g.state.chips, 7, "the chips are the player's")

if c.report("smoke_beat_browser") > 0 then os.exit(1) end
