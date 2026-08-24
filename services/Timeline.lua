-- services/Timeline.lua
--
-- A scripted sequence with a clock that can be stopped. Events are placed
-- at a time; the clock runs them in order; a HOLD stops the clock until the
-- host calls advance() (the player clicked); a WAIT stops it until a
-- condition the host evaluates passes (the player can afford the thing).
--
-- Extracted from views/ShoveView's beat machine so the House's story beats
-- on every other screen run on the same engine. Engine-agnostic: no love.*,
-- no game concepts. Sounds are names handed back through on_sound; lines
-- are opaque payloads handed back through on_say.
--
--   local tl = Timeline:new{ on_sound = play, on_say = show }
--   tl:add(0.5, function() ... end, "card_flip")
--   tl:say(1.0, { text = "Welcome in." })
--   tl:hold(1.0, "welcome")          -- clock stops here until tl:advance()
--   tl:wait(1.0, cond)               -- clock stops here while wait_fn(cond)
--   tl:update(dt, wait_fn)           -- wait_fn(cond) -> true while STILL blocked
--
-- Event shapes, in the order they were added (callers add in time order):
--   { at, fire, sound }   fire always runs; sound is skipped on skip()
--   { at, hold = id }     the clock pins at `at`; advance() pops it
--   { at, wait = cond }   the clock pins at `at`; passes when wait_fn says so

local Timeline = {}
Timeline.__index = Timeline

function Timeline:new(opts)
    opts = opts or {}
    return setmetatable({
        events   = {},
        idx      = 1,
        elapsed  = 0,
        holding  = false,
        hold_id  = nil,
        waiting  = nil,     -- the cond currently blocking, or nil
        current  = nil,     -- last say() payload
        on_sound = opts.on_sound,
        on_say   = opts.on_say,
    }, Timeline)
end

function Timeline:add(at, fire, sound)
    self.events[#self.events + 1] = { at = at, fire = fire, sound = sound }
end

function Timeline:hold(at, id)
    self.events[#self.events + 1] = { at = at, hold = id }
end

function Timeline:wait(at, cond)
    self.events[#self.events + 1] = { at = at, wait = cond }
end

function Timeline:say(at, line)
    self:add(at, function()
        self.current = line
        if self.on_say then self.on_say(line) end
    end)
end

-- Run the clock. wait_fn(cond) returns true while the wait is STILL
-- blocked; it is asked again on every update, and the tick it returns
-- false the wait is consumed and draining continues in the same tick.
function Timeline:update(dt, wait_fn)
    if not self.holding and not self.waiting then
        self.elapsed = self.elapsed + (dt or 0)
    end
    while not self.holding and self.idx <= #self.events do
        local ev = self.events[self.idx]
        if ev.hold then
            if self.elapsed >= ev.at then
                self.holding = true
                self.hold_id = ev.hold
                self.elapsed = ev.at
            end
            break
        elseif ev.wait then
            if self.elapsed < ev.at then break end
            self.elapsed = ev.at
            if wait_fn and wait_fn(ev.wait) then
                self.waiting = ev.wait
                break
            end
            self.waiting = nil
            self.idx = self.idx + 1
        elseif self.elapsed >= ev.at then
            ev.fire()
            if ev.sound and self.on_sound then self.on_sound(ev.sound) end
            self.idx = self.idx + 1
        else
            break
        end
    end
end

-- The host moved on from a hold. Pops it. Never pops a wait: a wait
-- passes only when its condition does.
function Timeline:advance()
    if not self.holding then return false end
    local ev = self.events[self.idx]
    if ev and ev.hold then self.idx = self.idx + 1 end
    self.holding = false
    self.hold_id = nil
    return true
end

-- Fire everything up to and INCLUDING the next hold, sounds suppressed,
-- and stop there: a skip lands on the next thing worth reading, never past
-- it. A blocking wait also stops it. A wait with no wait_fn counts as
-- passed.
function Timeline:skip(wait_fn)
    if self.holding then self:advance(); return end
    while self.idx <= #self.events do
        local ev = self.events[self.idx]
        if ev.hold then
            self.holding = true
            self.hold_id = ev.hold
            self.elapsed = ev.at
            return
        elseif ev.wait then
            self.elapsed = ev.at
            if wait_fn and wait_fn(ev.wait) then
                self.waiting = ev.wait
                return
            end
            self.waiting = nil
            self.idx = self.idx + 1
        else
            ev.fire()
            self.idx = self.idx + 1
        end
    end
end

function Timeline:isHolding() return self.holding end
function Timeline:holdId()    return self.hold_id end
function Timeline:isWaiting() return self.waiting ~= nil end
function Timeline:isDone()    return not self.holding and self.idx > #self.events end
function Timeline:line()      return self.current end
function Timeline:setLine(v)  self.current = v end
function Timeline:seek(t)     self.elapsed = t end

function Timeline:reset()
    self.events  = {}
    self.idx     = 1
    self.elapsed = 0
    self.holding = false
    self.hold_id = nil
    self.waiting = nil
    self.current = nil
end

return Timeline
