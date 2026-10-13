-- sim/smoke_music_aside.lua
--
-- The music aside (data/story.lua asides.music, controllers/StoryDirector
-- _asideFor): the first beat the House speaks after the arrival opens
-- with the aside, once; never on the arrival, a transient beat, or twice.
--
-- Standalone: `lua sim/smoke_music_aside.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Story = require("data.story")
local UnlockRegistry = require("services.UnlockRegistry")
local rules = UnlockRegistry:new()
require("models.hint_rules").registerAll(rules)

local function director(seen)
    local g = { state = { story_seen = seen, story_armed = {} }, fonts = {} }
    return require("controllers.StoryDirector"):new{ game = g, rules = rules, story = Story, save = function() end }, g
end
local function beat(id) for _, b in ipairs(Story.beats) do if b.id == id then return b end end end

c.ok(Story.asides and Story.asides.music and Story.asides.music.text ~= "", "the music aside exists")
local last = beat("arrival").lines[#beat("arrival").lines]
c.ok(last.text:find("Jazz", 1, true) ~= nil and not last.wait, "the arrival ends on the jazz, a click line")

-- before the arrival is heard: no aside
local d, g = director({})
d:_start(beat("first_hand_won"), {})
c.ok(d:currentLine() and d:currentLine().index == 1, "before the arrival, a beat opens on its own first line")

-- after: the next beat opens with the aside, once
d, g = director({ arrival = true })
d:_start(beat("first_hand_won"), {})
local l = d:currentLine()
c.ok(l and l.index == 0 and l.text == Story.asides.music.text, "after the arrival, the next beat opens with the aside")
c.ok(g.state.story_seen["_aside:music"] == true, "and it is marked spoken")
d:advance()
d.timeline:update(0, function() return true end)
c.ok(d:currentLine() and d:currentLine().index == 1, "the click moves on to the beat's own first line")
d:reset()
d:_start(beat("first_payout"), {})
c.ok(d:currentLine() and d:currentLine().index == 1, "the beat after that opens plainly: the aside was once")

-- never on the arrival itself, never on a transient beat
d, g = director({ arrival = true })
local tr = {}; for k, v in pairs(beat("sharper_reads")) do tr[k] = v end; tr.transient = true
d:_start(tr, {})
c.ok(g.state.story_seen["_aside:music"] == nil, "a transient beat (a replay) never carries the aside")

if c.report("smoke_music_aside") > 0 then os.exit(1) end
