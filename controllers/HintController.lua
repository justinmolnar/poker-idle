-- controllers/HintController.lua
--
-- Tutorial hint dispatch. Walks data/hints.lua in order; two behaviors
-- by spec class:
--
--   sticky — instructions ("press DEAL"). At most ONE active at a time:
--     highlight + bubble stay up until the `done` condition passes or
--     the player clicks the bubble away.
--   info (non-sticky) — FYIs ("this is your bankroll"). Triggering
--     appends them to a persisted queue (state.hints_queued) rendered as
--     hoverable [i] icons; they never steal focus, never expire, and
--     only clicking the icon dismisses them (see views/HintView).
--
-- If a spec's `done` condition already passes when it would first fire,
-- the hint is marked seen WITHOUT showing — a post-shove veteran or a
-- pre-hints save has nothing to learn from "press DEAL", so the early
-- teaching silently retires. No save migration needed. Already-queued
-- info hints are exempt: once in the queue, only the player's click
-- clears them.
--
-- Seen-ness persists as state.hints_seen (meta-side set, id → true), the
-- queue as state.hints_queued (id list); the main.lua autosave picks
-- both up — no explicit save here.
--
-- Inert unless FEATURES.TUTORIAL: prototype builds teach via the forced
-- how-to-play modal instead.

local Constants = require("data.constants")
local Hints     = require("data.hints")

local HintController = {}
HintController.__index = HintController

-- Trigger/done conditions are cheap state reads; re-evaluating every
-- frame is waste. 0.15 s is imperceptible for "a hint appeared".
local CHECK_INTERVAL = 0.15

-- `grind` is the GrindController — hint conditions read table counts via
-- its pool and derived stats (tiedUp, focus, quick-reset) through it
-- directly (see models/hint_rules.lua).
function HintController:new(game, grind)
    local by_id = {}
    for _, spec in ipairs(Hints) do by_id[spec.id] = spec end
    return setmetatable({
        game    = game,
        grind   = grind,
        by_id   = by_id,
        enabled = Constants.FEATURES.TUTORIAL,
        active  = nil,   -- the currently-showing STICKY spec, or nil
        _timer  = 0,
    }, HintController)
end

function HintController:activeHint()
    return self.active
end

-- Queued info-hint specs in queue order. Ids whose spec no longer exists
-- (renamed/cut in data) are skipped.
function HintController:queuedHints()
    local out = {}
    local ids = self.game.state.hints_queued
    if ids then
        for _, id in ipairs(ids) do
            local spec = self.by_id[id]
            if spec then out[#out + 1] = spec end
        end
    end
    return out
end

-- Player clicked the active sticky hint's bubble — counts as taught.
function HintController:dismissActive()
    if not self.active then return end
    self:_markSeen(self.active.id)
    self.active = nil
end

-- Player clicked a queue [i] icon — mark seen, drop from the queue.
function HintController:dismissQueued(id)
    self:_markSeen(id)
    local ids = self.game.state.hints_queued
    if not ids then return end
    for i = #ids, 1, -1 do
        if ids[i] == id then table.remove(ids, i) end
    end
end

-- Drop the active hint without marking it seen. Called on hard resets
-- (F6/F7 wipe) so a stale spec doesn't linger over the fresh game; the
-- seen-set and queue live on GameState and are wiped there.
function HintController:reset()
    self.active = nil
    self._timer = 0
end

function HintController:_markSeen(id)
    local seen = self.game.state.hints_seen
    if seen then seen[id] = true end
end

function HintController:_isQueued(id)
    local ids = self.game.state.hints_queued
    if not ids then return false end
    for _, qid in ipairs(ids) do
        if qid == id then return true end
    end
    return false
end

function HintController:update(dt)
    if not self.enabled then return end
    self._timer = self._timer + (dt or 0)
    if self._timer < CHECK_INTERVAL then return end
    self._timer = 0

    local state = self.game.state
    local seen, queued = state.hints_seen, state.hints_queued
    if not (seen and queued) then return end
    local reg = self.game.hint_rules
    local ctx = { state = state, pool = self.grind.pool, grind = self.grind }

    -- Active sticky hint completes on its done-condition.
    if self.active and self.active.done and reg:check(self.active.done, ctx) then
        self:_markSeen(self.active.id)
        self.active = nil
    end

    -- Scan for new firings. Sticky specs respect the one-at-a-time slot;
    -- info specs queue independently (several [i]s may pend at once).
    for _, spec in ipairs(Hints) do
        if not seen[spec.id] and spec ~= self.active
           and not self:_isQueued(spec.id) then
            if spec.done and reg:check(spec.done, ctx) then
                self:_markSeen(spec.id)   -- already learned — retire silently
            elseif spec.sticky then
                if not self.active and reg:check(spec.trigger, ctx) then
                    self.active = spec
                end
            elseif reg:check(spec.trigger, ctx) then
                queued[#queued + 1] = spec.id
            end
        end
    end
end

return HintController
