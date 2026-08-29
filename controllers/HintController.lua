-- controllers/HintController.lua
--
-- Tutorial hint dispatch. Walks data/hints.lua in order — STICKY specs
-- only now (instructions with a button, e.g. quick reset): at most ONE
-- active at a time, highlight + bubble up until the `done` condition
-- passes or the player clicks the bubble away.
--
-- The info-hint [i] queue is RETIRED: teaching moved to story beats
-- (data/story.lua) and the glossary (data/glossary.lua). GameState drains
-- state.hints_queued from old saves on load; a non-sticky spec in the
-- data is simply never delivered.
--
-- If a spec's `done` condition already passes when it would first fire,
-- the hint is marked seen WITHOUT showing — a post-shove veteran or a
-- pre-hints save has nothing to learn from "press DEAL", so the early
-- teaching silently retires. No save migration needed.
--
-- Seen-ness persists as state.hints_seen (meta-side set, id → true); the
-- main.lua autosave picks it up — no explicit save here.

local Hints     = require("data.hints")

local HintController = {}
HintController.__index = HintController

-- Trigger/done conditions are cheap state reads; re-evaluating every
-- frame is waste. 0.15 s is imperceptible for "a hint appeared".
local CHECK_INTERVAL = 0.15

-- One instance for the whole game, owned by main.lua and ticked from
-- love.update, so a hint can fire on any screen. It used to belong to
-- GrindState and take the GrindController as an argument, which meant the
-- House could only ever speak on the felt: nothing on the shove screen, in
-- the catalog, in deck select or in the room could be taught.
--
-- The grind-shaped reads (table counts, tiedUp, focus) go through
-- game.grind, which GrindState sets at boot; on other screens the pool is
-- empty and every pool rule reads 0, which is the correct answer there.
-- The ctx (controllers/hint_ctx.lua) is built by the host once per tick
-- and shared with the story director, so a beat and a popup read the
-- same frame.
--
-- `paused` is set by the host while a story beat is running: nothing new
-- starts, and the active sticky is hidden by the view rather than
-- cancelled here. He does not talk over himself.
function HintController:new(game)
    return setmetatable({
        game    = game,
        enabled = true,
        paused  = false,
        active  = nil,   -- the currently-showing STICKY spec, or nil
        _timer  = 0,
    }, HintController)
end

function HintController:activeHint()
    return self.active
end

-- Player clicked the active sticky hint's bubble — counts as taught.
function HintController:dismissActive()
    if not self.active then return end
    self:_markSeen(self.active.id)
    self.active = nil
end

-- Drop the active hint without marking it seen. Called on hard resets
-- (F6/F7 wipe) so a stale spec doesn't linger over the fresh game; the
-- seen-set lives on GameState and is wiped there.
function HintController:reset()
    self.active = nil
    self._timer = 0
end

function HintController:_markSeen(id)
    local seen = self.game.state.hints_seen
    if seen then seen[id] = true end
end

function HintController:update(dt, ctx)
    if not self.enabled then return end
    self._timer = self._timer + (dt or 0)
    if self._timer < CHECK_INTERVAL then return end
    self._timer = 0

    local state = self.game.state
    local seen  = state.hints_seen
    if not seen then return end
    local reg   = self.game.hint_rules
    if not ctx then
        local grind = self.game.grind
        ctx = { state = state, pool = grind and grind.pool, grind = grind }
    end

    -- Active sticky hint completes on its done-condition, beat or no beat.
    if self.active and self.active.done and reg:check(self.active.done, ctx) then
        self:_markSeen(self.active.id)
        self.active = nil
    end

    -- While the House is telling a story, no popup starts.
    if self.paused then return end

    -- Scan for new firings. Sticky specs respect the one-at-a-time slot.
    for _, spec in ipairs(Hints) do
        if not seen[spec.id] and spec ~= self.active then
            -- `retire` is the silent-suppression predicate; `done` is a
            -- sticky hint's completion. They used to be one field, which
            -- meant a completion condition could delete a hint the player
            -- had never seen. Falling back to `done` keeps every spec that
            -- has not been migrated evaluating exactly as before.
            local retire = spec.retire or spec.done
            if retire and reg:check(retire, ctx) then
                self:_markSeen(spec.id)   -- already past this lesson
            elseif spec.sticky then
                if not self.active and reg:check(spec.trigger, ctx) then
                    self.active = spec
                end
            end
            -- Non-sticky specs: no longer delivered (the [i] queue is
            -- retired; beats and the glossary carry the teaching).
        end
    end
end

return HintController
