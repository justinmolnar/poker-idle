-- controllers/StoryDirector.lua
--
-- Plays the House's story beats (data/story.lua) in order.
--
-- ARM, THEN PLAY. Triggers are evaluated every tick, beat running or not,
-- right screen or not, menu up or not: the moment a trigger passes, its
-- beat is ARMED (state.story_armed, persisted). A transient trigger — an
-- upgrade that was briefly affordable, a table that was briefly busted —
-- can never slip away while the House is mid-sentence or a modal is up.
-- An armed beat then plays, first in script order, as soon as no beat is
-- running, its own screen is up, and the band has somewhere to draw. One
-- beat at a time. A beat is marked seen (state.story_seen) when its last
-- line is done, and never plays again.
--
-- There are no skip conditions. An old save hears each beat the first
-- time its trigger passes, however far along it is.
--
-- While playing, a beat PAUSES on any other screen, or while its band is
-- not drawn: the clock stops, the current line stays, nothing is
-- cancelled. A line about a widget that is not on screen pauses too, for
-- a grace period; after that the line is shown without its mark and the
-- beat moves on.
--
-- FORCED LINES. A line with `force = true` and a `wait` condition demands
-- the action: the host dims everything but the line's targets and
-- swallows stray clicks until the wait passes (main.lua reads
-- forcedLine()). The dim and the lock only exist while at least one
-- target is actually on screen — a forced line must never dead-lock a
-- screen it cannot point at.
--
-- deps = { game, rules = UnlockRegistry (hint kinds), story = data/story,
--          save = fn() }

local Timeline  = require("services.Timeline")

local StoryDirector = {}
StoryDirector.__index = StoryDirector

local CHECK_INTERVAL = 0.15   -- trigger scan throttle, same as the hints
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

-- Does the running beat freeze the simulation right now? True while a
-- `pause = true` beat has a line up on its own screen, except on a forced
-- `wait` line (the action has to be able to happen). The host reads this
-- once a tick and hands dt = 0 to the tables, the cursors and the shove
-- clock; flights in the air still land.
function StoryDirector:freezesGame()
    local beat, tl = self.beat, self.timeline
    if not (beat and beat.pause and tl) or self._paused then return false end
    local line = tl:line()
    if not line then return false end
    if line.force and tl:isWaiting() then return false end
    return true
end
function StoryDirector:currentLine() return self.timeline and self.timeline:line() or nil end

function StoryDirector:isHoldingClick()
    return self.timeline ~= nil and self.timeline:isHolding()
end

function StoryDirector:anchorGraceElapsed()
    return self._anchor_missing_t >= ANCHOR_GRACE
end

-- The current line, when it demands an action (force + wait) and the beat
-- is live on its own screen. The host dims to its targets and swallows
-- clicks outside them — but only against targets that are actually fresh,
-- which the host re-checks itself, so a vanished widget releases the lock.
function StoryDirector:forcedLine()
    if self._paused then return nil end
    local line = self:currentLine()
    return (line and line.force) and line or nil
end

-- ── Control ───────────────────────────────────────────────────────────

-- The player clicked the band (or SPACE) on a line that was waiting for
-- it. The band goes empty until the next line lands, so a line gated on
-- a condition arrives into silence.
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

-- `blocked` = a menu-class surface is up (the host's hintsBlocked):
-- nothing starts and the running beat's clock stops, but triggers still
-- arm — that is the whole point of arming.
function StoryDirector:update(dt, ctx, blocked)
    if not self.enabled or not ctx then return end
    local state = self.game.state
    if not (state and state.story_seen) then return end

    self._last_ctx = ctx   -- for a line said outside the script (sayOnce)
    self._timer = self._timer + (dt or 0)
    if self._timer >= CHECK_INTERVAL then
        self._timer = 0
        self:_armTriggers(ctx)
    end

    if blocked then return end

    if self.beat then
        self:_drive(dt, ctx)
        return
    end

    -- No band, no beat: nothing can start on a screen with nowhere to
    -- speak (the title).
    if not (ctx.anchor_fresh and ctx.anchor_fresh("story:band")) then return end
    local armed = state.story_armed
    if not armed then return end
    for _, beat in ipairs(self.story.beats) do
        if armed[beat.id] and not state.story_seen[beat.id]
           and ctx.screen == beat.screen then
            self:_start(beat, ctx)
            return
        end
    end
end

function StoryDirector:_armTriggers(ctx)
    local state = self.game.state
    state.story_armed = state.story_armed or {}
    local armed, seen = state.story_armed, state.story_seen
    for _, beat in ipairs(self.story.beats) do
        if not seen[beat.id] and not armed[beat.id]
           and self.rules:check(beat.trigger, ctx) then
            armed[beat.id] = true
        end
    end
end

-- The timeline's wait check: true while the wait is STILL blocked. A
-- wait built by `wait_fresh` (see _start) has to be seen FALSE once
-- before it may pass: a hover the mouse is already making when the line
-- lands does not count, the player has to make it after reading.
function StoryDirector:_blockedFn(ctx)
    local rules = self.rules
    return function(cond)
        if cond and cond.fresh_inner then
            local ok = rules:check(cond.fresh_inner, ctx)
            if not cond.seen_false then
                if not ok then cond.seen_false = true end
                return true
            end
            return not ok
        end
        return not rules:check(cond, ctx)
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
    local blocked = self:_blockedFn(ctx)
    if paused then
        -- Off its screen the beat's clock stops, but a pending `wait` is
        -- still asked: a forced action that CHANGES screen ("go to the
        -- room") has to be able to complete the beat from over there, or
        -- the next beat on that screen could never start.
        if tl:isWaiting() then
            tl:update(0, blocked)
            if tl:isDone() then self:_finish() end
        end
        return
    end

    tl:update(dt, blocked)
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
    -- A line with `grant` acts the moment it lands (before its wait is
    -- asked, so a wait on what the grant makes possible can pass).
    local tl = Timeline:new{ on_say = function(line)
        if line.grant == "loan" and self.game.state and self.game.state.grantLoan then
            self.game.state:grantLoan()
        end
    end }
    local t  = 0
    for i, line in ipairs(beat.lines) do
        t = t + (line.delay or 0)
        if line.show then tl:wait(t, line.show) end
        tl:say(t, { beat = beat.id, index = i, text = line.text,
                    anchor = line.anchor, font = line.font,
                    force = line.force, grant = line.grant })
        local hold = line.hold
        if hold == nil and line.wait == nil then hold = "click" end
        if hold == "click" then
            tl:hold(t, i)
        elseif type(hold) == "number" then
            t = t + hold
        end
        if line.wait then
            -- wait_fresh: the condition must be seen false before it can
            -- pass (a fresh table per beat run, so the memory is per play).
            tl:wait(t, line.wait_fresh and { fresh_inner = line.wait, seen_false = false } or line.wait)
        end
    end
    self.beat     = beat
    self.timeline = tl
    self._paused  = false
    self._anchor_missing_t = 0
    -- Land the first line now rather than a tick later.
    tl:update(0, self:_blockedFn(ctx))
    if tl:isDone() then self:_finish() end
end

-- One line outside the script: an item's house_line when it is clicked
-- in the room. Said on the current screen, held a few seconds, and never
-- recorded (no id in story_seen). Nothing while a beat is up.
local ONCE_HOLD = 4.0
function StoryDirector:sayOnce(text)
    if self.beat or not text or text == "" then return false end
    local ctx = self._last_ctx
    if not ctx or not ctx.screen then return false end
    self:_start({ id = "_once", screen = ctx.screen, transient = true,
                  lines = { { text = text, hold = ONCE_HOLD } } }, ctx)
    return true
end

function StoryDirector:_finish()
    local state = self.game.state
    if state and self.beat and not self.beat.transient then
        if state.story_seen  then state.story_seen[self.beat.id] = true end
        if state.story_armed then state.story_armed[self.beat.id] = nil end
    end
    self.beat     = nil
    self.timeline = nil
    self._paused  = false
    self._anchor_missing_t = 0
    if self.save then self.save() end
end

return StoryDirector
