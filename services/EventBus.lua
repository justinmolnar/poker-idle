-- services/EventBus.lua
--
-- The game's notification spine: something happened, and whoever cares
-- hears about it. Engine-agnostic and domain-free — it knows nothing about
-- poker, tables, or statuses. Producers name an event and move on; they
-- never learn who listened, or whether anyone did.
--
-- Promoted from core/event_bus.lua, which was a module singleton reachable
-- both by require() and off the DI container — the "two parallel access
-- paths for the same shared state" that main.lua calls a subtle form of
-- fake DI. This is an instance, so a run reset really clears it and a test
-- gets a clean one.
--
-- ─── WHY THIS EXISTS SEPARATELY FROM ProcRegistry ───────────────────────
-- ProcRegistry answers "given that a thing fired, who does it hit". It is
-- a dispatcher: somebody has to call it, at a place that knows the trigger
-- exists. That somebody was GrindController, at five hardcoded sites, and
-- every new trigger meant new controller code. The bus is the layer above:
-- the controller stops knowing what a trigger is, and ProcRegistry becomes
-- one subscriber among many.
--
-- ─── TWO VERBS, ON PURPOSE ──────────────────────────────────────────────
--   publish  a notification. Deferred to the drain, return values ignored.
--            Nobody can answer back; that is the point.
--   resolve  a question. Synchronous, and subscribers MAY answer: each one
--            can return a replacement value, folded in priority order.
--            This is how a delivery gets re-aimed ("that status was headed
--            for the table next door, but this one intercepts it") without
--            the sender or the interceptor knowing the other exists.
--
-- ─── WHY PUBLISH IS DEFERRED ────────────────────────────────────────────
-- Publishing straight into the subscribers means a subscriber can publish,
-- re-entering the bus mid-dispatch. This codebase already has the scars:
-- Table:deal re-enters _endTournament re-enters _finalizeHand re-enters
-- deal, and the cascade payload appends to the resolution list that is
-- being walked. So a publish is queued and drained at one known point per
-- frame. The drain loops until the queue is empty, so an event raised by a
-- subscriber is still handled on the SAME frame — deferral buys ordering
-- and a flat stack, and costs nothing visible.
--
-- ─── UNKNOWN EVENTS ARE SILENT (the family rule, inverted) ──────────────
-- EffectsRegistry, PokerEventRegistry, XpRuleRegistry and ProcRegistry all
-- ERROR on a kind nobody registered, because there a missing kind is a typo
-- in a data file. Here it is the opposite: an event with no subscribers is
-- the normal, healthy state of a decoupled producer. A table announcing
-- that it finished a hand must not care that nothing is listening yet.
-- Publishing into the void is free and silent, deliberately.
--
-- ─── THE EVENT TABLE BELONGS TO THE BUS ─────────────────────────────────
-- At ~35 hands/sec across a full board, one table per publish is real
-- garbage. Events are pooled: after the last subscriber runs, the table is
-- wiped and reused. NEITHER the publisher NOR a subscriber may retain it.
-- Copy what you need out of it. Borrow one with :event() to avoid
-- allocating in the first place.
--
-- Dispatch contract:
--   local tok = bus:subscribe("name", function(event) ... end, priority)
--   bus:unsubscribe(tok)
--   bus:publish("name", { ... })            -- queued; drained later
--   bus:resolve("name", { ... }, "field")   -- immediate; returns a value
--
-- Engine-agnostic: no love.*, no requires, no game nouns. It could drop
-- into a different idle game tomorrow.

local EventBus = {}
EventBus.__index = EventBus

-- Runaway stop, not the real throttle. Events are naturally limited by how
-- often the game does anything; this only catches a subscriber that feeds
-- itself. Generous enough that no legitimate frame reaches it.
local MAX_EVENTS_PER_FRAME = 512

function EventBus:new()
    return setmetatable({
        subs      = {},    -- name -> array of { fn, priority, dead }
        taps      = {},
        -- The queue is two parallel arrays rather than an array of
        -- { name, event } wrappers: a wrapper per publish would be exactly
        -- the allocation the event pool exists to avoid.
        q_name    = {},
        q_event   = {},
        q_head    = 1,
        q_tail    = 0,
        pool      = {},    -- recycled event tables
        dispatched = 0,    -- events handled this frame
        dispatching = false,
        _seq      = 0,     -- monotonic subscribe order; never reused, so a
                           -- survivor's tiebreak can't collide after compact
    }, EventBus)
end

-- ── Listening ────────────────────────────────────────────────────────────

-- Higher priority runs first. Same priority keeps subscription order, which
-- matters wherever money is counted: the ordering inside the old resolution
-- loop is preserved by giving those subscribers explicit priorities rather
-- than trusting the order they happened to register in.
local function bySubOrder(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.seq < b.seq
end

function EventBus:subscribe(name, fn, priority)
    if type(fn) ~= "function" then return nil end
    local list = self.subs[name]
    if not list then list = {}; self.subs[name] = list end
    self._seq = self._seq + 1
    local rec = { fn = fn, priority = priority or 0, name = name, seq = self._seq }
    list[#list + 1] = rec
    -- Sorting the live array mid-dispatch would shuffle it under the loop
    -- walking it (skip one subscriber, run another twice) — and subscribing
    -- during dispatch is a real path: a ratchet payload rebuilds the proc
    -- index while its own trigger is being delivered. Defer the sort; the
    -- newcomer runs in append order until the next dispatch of this name
    -- sorts the list, which keeps the same-frame contract intact.
    if self.dispatching then
        list.dirty = true
    else
        table.sort(list, bySubOrder)
    end
    return rec
end

-- Tokens are marked dead rather than removed, so unsubscribing from inside
-- a dispatch cannot shift the array out from under the loop walking it.
-- The compaction happens at the next beginFrame.
function EventBus:unsubscribe(token)
    if type(token) ~= "table" then return false end
    token.dead = true
    self._needs_compact = true
    return true
end

-- Called on EVERY publish with (name, event). The explicit alternative to a
-- subscribe("*") wildcard, which this module deliberately does not support.
function EventBus:addTap(fn)
    if type(fn) ~= "function" then return end
    self.taps[#self.taps + 1] = fn
end

function EventBus:removeTap(fn)
    for i = 1, #self.taps do
        if self.taps[i] == fn then table.remove(self.taps, i); return end
    end
end

function EventBus:has(name)
    local list = self.subs[name]
    if not list then return false end
    for i = 1, #list do if not list[i].dead then return true end end
    return false
end

-- ── Event tables ─────────────────────────────────────────────────────────

-- Borrow a pooled table to fill in and publish. Saves the allocation; the
-- bus takes it back after dispatch either way.
function EventBus:event()
    local n = #self.pool
    if n == 0 then return {} end
    local e = self.pool[n]
    self.pool[n] = nil
    return e
end

function EventBus:_recycle(e)
    if type(e) ~= "table" then return end
    for k in pairs(e) do e[k] = nil end
    self.pool[#self.pool + 1] = e
end

-- ── Publishing ───────────────────────────────────────────────────────────

-- Queue a notification. The event table becomes the bus's property.
function EventBus:publish(name, event)
    if not name then return end
    local t = self.q_tail + 1
    self.q_tail = t
    self.q_name[t]  = name
    self.q_event[t] = event or self:event()
end

function EventBus:_dispatch(name, event)
    local list = self.subs[name]
    if list then
        if list.dirty then
            list.dirty = nil
            table.sort(list, bySubOrder)
        end
        -- Walk by index over the live array. Subscribers added during a
        -- dispatch are appended (never sorted until the walk is over), and
        -- the #list read here is taken once, so they run on the next event
        -- rather than this one.
        local n = #list
        for i = 1, n do
            local rec = list[i]
            if rec and not rec.dead then rec.fn(event) end
        end
    end
    local taps = self.taps
    for i = 1, #taps do taps[i](name, event) end
end

-- Drain until empty. Anything a subscriber publishes is handled on this
-- same frame, after everything already queued.
function EventBus:drain()
    if self.dispatching then return 0 end
    self.dispatching = true
    local handled = 0
    while self.q_head <= self.q_tail
          and self.dispatched < MAX_EVENTS_PER_FRAME do
        local i = self.q_head
        local name, event = self.q_name[i], self.q_event[i]
        self.q_name[i], self.q_event[i] = nil, nil
        self.q_head = i + 1
        self.dispatched = self.dispatched + 1
        handled = handled + 1
        self:_dispatch(name, event)
        self:_recycle(event)
    end
    -- Budget blown: drop whatever is left rather than carry a growing
    -- backlog into the next frame, which would only postpone the runaway.
    for i = self.q_head, self.q_tail do
        self:_recycle(self.q_event[i])
        self.q_name[i], self.q_event[i] = nil, nil
    end
    self.q_head, self.q_tail = 1, 0
    self.dispatching = false
    return handled
end

-- ── Resolving ────────────────────────────────────────────────────────────

-- Ask a question and let subscribers answer. Each may return a replacement
-- value; the last non-nil answer wins, so a lower-priority subscriber gets
-- the final say over a higher-priority one that already spoke. Synchronous
-- by necessity: the caller needs the answer now, before it acts on it.
--
-- `field` names the key on the event carrying the current value, so a
-- subscriber can see what it is overriding.
function EventBus:resolve(name, event, field)
    local list = self.subs[name]
    local value
    if field and event then value = event[field] end
    if not list then return value end
    local n = #list
    for i = 1, n do
        local rec = list[i]
        if rec and not rec.dead then
            local answer = rec.fn(event)
            if answer ~= nil then
                value = answer
                if field and event then event[field] = answer end
            end
        end
    end
    return value
end

-- ── Frame / lifetime ─────────────────────────────────────────────────────

function EventBus:beginFrame()
    self.dispatched = 0
    if self._needs_compact then self:_compact() end
end

function EventBus:_compact()
    self._needs_compact = false
    for name, list in pairs(self.subs) do
        local out, n = {}, 0
        for i = 1, #list do
            local rec = list[i]
            if not rec.dead then n = n + 1; out[n] = rec end
        end
        -- The rebuilt list drops any pending `dirty` flag, so restore the
        -- ordering invariant here rather than carrying the flag across.
        if n > 0 then table.sort(out, bySubOrder) end
        self.subs[name] = (n > 0) and out or nil
    end
end

-- Drop every subscription and anything queued. For a run reset, matching
-- the clear()-on-reset convention the module-state services follow.
function EventBus:clear()
    self.subs = {}
    self.taps = {}
    self.q_name, self.q_event = {}, {}
    self.q_head, self.q_tail = 1, 0
    self.dispatched = 0
    self._needs_compact = false
end

return EventBus
