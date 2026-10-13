-- sim/smoke_music_aside.lua
--
-- The jazz (data/story.lua asides, controllers/StoryDirector):
--   gift    when a beat ends with NOTHING armed to follow on the grind,
--           the arrival heard and the jazz not yet given, he goes straight
--           on into the gift line (the box never empties); its click ends
--           it, it is recorded as music_gift, once
--   queued  with another beat armed for this screen, no gift: the run
--           goes on
--   music   the first beat after the gift opens with the aside, once;
--           never the gift itself, never a transient beat
--
-- Standalone: `lua sim/smoke_music_aside.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Story = require("data.story")
local UnlockRegistry = require("services.UnlockRegistry")
local rules = UnlockRegistry:new()
require("models.hint_rules").registerAll(rules)

local function director(seen, armed)
    local g = { state = { story_seen = seen, story_armed = armed or {} }, fonts = {} }
    local d = require("controllers.StoryDirector"):new{ game = g, rules = rules, story = Story, save = function() end }
    d._last_ctx = { screen = "grind" }
    return d, g
end
local function beat(id) for _, b in ipairs(Story.beats) do if b.id == id then return b end end end
local function click(d)
    if d:isHoldingClick() then d:advance() end
    d.timeline:update(0, function() return false end)
    if d.timeline:isDone() then d:_finish() end
end

c.ok(Story.asides and Story.asides.gift and Story.asides.gift.text:find("Jazz", 1, true) ~= nil, "the gift line exists and ends on the jazz")

-- gift: the beat that ends the opening, nothing queued
local d, g = director({ arrival = true })
d:_start(beat("first_payout"), {})
c.ok(d:currentLine() and d:currentLine().index == 1, "a beat opens on its own line")
click(d)
c.ok(d.beat ~= nil and d.beat.id == "music_gift", "with nothing armed to follow, the gift comes straight on")
c.ok(d:currentLine() and d:currentLine().text == Story.asides.gift.text, "and it is the jazz line")
c.ok(g.state.story_seen.music_gift == nil, "not yet given: the click gives it")
click(d)
c.ok(d.beat == nil and g.state.story_seen.music_gift == true, "the click through ends it: the jazz is given")

-- queued: another beat armed for this screen, no gift
local d2, g2 = director({ arrival = true }, { sharper_reads = true })
d2:_start(beat("first_payout"), {})
click(d2)
c.ok(d2.beat == nil and g2.state.story_seen.music_gift == nil, "with a beat armed to follow, no gift yet")

-- music: the first beat after the gift opens with the aside, once
d:_start(beat("sharper_reads"), {})
local l = d:currentLine()
c.ok(l ~= nil and l.index == 0 and l.text == Story.asides.music.text, "the first beat after the gift opens with the aside")
d:reset()
d:_start(beat("first_chip"), {})
c.ok(d:currentLine() ~= nil and d:currentLine().index == 1, "the one after opens plainly")

-- never on a transient beat
local d3, g3 = director({ arrival = true, music_gift = true })
local tr = {}; for k, v in pairs(beat("sharper_reads")) do tr[k] = v end; tr.transient = true
d3:_start(tr, {})
c.ok(g3.state.story_seen["_aside:music"] == nil, "a transient beat (a replay) never carries the aside")
local d4, g4 = director({ arrival = true })
local tr2 = {}; for k, v in pairs(beat("first_payout")) do tr2[k] = v end; tr2.transient = true
d4:_start(tr2, {}); click(d4)
c.ok(g4.state.story_seen.music_gift == nil and d4.beat == nil, "a transient beat ending never gives the gift")

if c.report("smoke_music_aside") > 0 then os.exit(1) end
