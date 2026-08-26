-- controllers/StoryDirector.lua
--
-- Plays the House's story beats (data/story.lua) in order. Each tick, if a
-- beat is running it drives that beat's timeline (services/Timeline);
-- otherwise it looks for the first unseen beat whose trigger passes and
-- starts it. One beat at a time. A beat is marked seen (state.story_seen)
-- when its last line is done, and never plays again.
--
-- There are no skip conditions. An old save hears each beat the first
-- time its trigger passes, however far along it is.
--
-- A beat belongs to a screen. On any other screen, or while its band is
-- not drawn, it PAUSES: the clock stops, the current line stays, nothing
-- is cancelled, and it resumes when the screen comes back. A line about a
-- widget that is not on screen pauses too, for a grace period; after that
-- the line is shown without its mark and the beat moves on.
--
-- deps = { game, rules = UnlockRegistry (hint kinds), story = data/story,
--          save = fn() }

local Timeline  = require("services.Timeline")

local StoryDirector = {}
StoryDirector.__index = StoryDirector

local CHECK_INTERVAL = 0.15   -- idle scan throttle, same as the hints
local ANCHOR_GRACE   = 3.0    -- seconds to wait for a line's widget

function StoryDirector:new(deps)
    return setmetatable({
        game     = deps.game,
        rules    = deps.rules,
        story    = deps.story,
        save     = deps.save,
        enabled  = true,
        beat     = nil,
        timeline = nil,
        _timer   = 0,
        _paused  = false,
        _anchor_missing_t = 0,
    }, StoryDirector)
end

-- ── Queries ───────────────────────────────────────────────────────────

function StoryDirector:isActive()    return self.beat ~= nil end
function StoryDirector:isPaused()    return self._paused end
function StoryDirector:currentLine() return self.timeline and self.timeline:line() or nil end

function StoryDirector:isHoldingClick()
    return self.timeline ~= nil and self.timeline:isHolding()
end

function StoryDirector:anchorGraceElapsed()
    return self._anchor_missing_t >= ANCHOR_GRACE
end

-- Lines the player has heard, in script order, for the help desk.
function StoryDirector:seenLines()
    local out  = {}
    local seen = self.game.state and self.game.state.story_seen or {}
    for _, beat in ipairs(self.story.beats) do
        if seen[beat.id] then
            for _, line in ipairs(beat.lines) do
                out[#out + 1] = { beat_id = beat.id, text = line.text, anchor = line.anchor }
            end
        end
    end
    return out
end

-- ── Control ───────────────────────────────────────────────────────────

-- The player clicked the band (or SPACE) on a line that was waiting for
-- it. The band goes empty until the next line lands, so a line gated on
-- a condition (S2's "you can afford that now") arrives into silence.
function StoryDirector:advance()
    if not self:isHoldingClick() then return false end
    self.timeline:advance()
    self.timeline:setLine(nil)
    self._anchor_missing_t = 0
    return true
end

-- Drop the running beat without marking it seen (hard resets).
function StoryDirector:reset()
    self.beat     = nil
    self.timeline = nil
    self._timer   = 0
    self._paused  = false
    self._anchor_missing_t = 0
end

-- ── Tick ──────────────────────────────────────────────────────────────

function StoryDirector:update(dt, ctx)
    if not self.enabled or not ctx then return end
    local state = self.game.state
    if not (state and state.story_seen) then return end

    if self.beat then
        self:_drive(dt, ctx)
        return
    end

    self._timer = self._timer + (dt or 0)
    if self._timer < CHECK_INTERVAL then return end
    self._timer = 0
    -- No band, no beat: nothing can start on a screen with nowhere to
    -- speak (the title).
    if not (ctx.anchor_fresh and ctx.anchor_fresh("story:band")) then return end
    for _, beat in ipairs(self.story.beats) do
        if not state.story_seen[beat.id] and self.rules:check(beat.trigger, ctx) then
            self:_start(beat, ctx)
            return
        end
    end
end

function StoryDirector:_drive(dt, ctx)
    local beat, tl = self.beat, self.timeline
    local fresh = ctx.anchor_fresh or function() return true end
    local paused = (ctx.screen ~= beat.screen) or not fresh("story:band")
    local line = tl:line()
    if not paused and line and line.anchor and not self:_anyFresh(fresh, line.anchor) then
        self._anchor_missing_t = self._anchor_missing_t + (dt or 0)
        if self._anchor_missing_t < ANCHOR_GRACE then paused = true end
    elseif not paused then
        self._anchor_missing_t = 0
    end
    self._paused = paused
    if paused then return end

    local rules = self.rules
    tl:update(dt, function(cond) return not rules:check(cond, ctx) end)
    if tl:isDone() then self:_finish() end
end

function StoryDirector:_anyFresh(fresh, names)
    if type(names) ~= "table" then return fresh(names) end
    for _, n in ipairs(names) do if fresh(n) then return true end end
    return false
end

-- Compile a beat's lines onto a timeline. t advances only through timed
-- holds; clicks and waits pin it, so every line is placed at the moment
-- the previous one released.
function StoryDirector:_start(beat, ctx)
    local tl = Timeline:new()
    local t  = 0
    for i, line in ipairs(beat.lines) do
        t = t + (line.delay or 0)
        if line.show then tl:wait(t, line.show) end
        tl:say(t, { beat = beat.id, index = i, text = line.text,
                    anchor = line.anchor, font = line.font })
        local hold = line.hold
        if hold == nil and line.wait == nil then hold = "click" end
        if hold == "click" then
            tl:hold(t, i)
        elseif type(hold) == "number" then
            t = t + hold
        end
        if line.wait then tl:wait(t, line.wait) end
    end
    self.beat     = beat
    self.timeline = tl
    self._paused  = false
    self._anchor_missing_t = 0
    -- Land the first line now rather than a tick later.
    local rules = self.rules
    tl:update(0, function(cond) return not rules:check(cond, ctx) end)
    if tl:isDone() then self:_finish() end
end

function StoryDirector:_finish()
    local state = self.game.state
    if state and state.story_seen and self.beat then
        state.story_seen[self.beat.id] = true
    end
    self.beat     = nil
    self.timeline = nil
    self._paused  = false
    self._anchor_missing_t = 0
    if self.save then self.save() end
end

return StoryDirector
