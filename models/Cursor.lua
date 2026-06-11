-- models/Cursor.lua
--
-- A single autonomous on-screen cursor. State machine:
--   wandering → seeking → wandering
--
--   wandering — no claimed target. Drifts toward a random wander point in
--               the window; every SCAN_INTERVAL seconds, scans the visible
--               DEAL hit-boxes for the closest unclaimed one. If found,
--               claims it and transitions to seeking.
--   seeking   — has a claimed target table. Travels in a straight line
--               toward the center of the hit-box. On arrival (within
--               CLICK_RADIUS), dispatches the click and returns to
--               wandering.
--
-- Engine-agnostic: this model knows about hit-boxes and dispatcher
-- callbacks, not about poker, tables, or the EffectsRegistry. Holds
-- pure state (x, y, target, timers); rendering lives in
-- services/CursorPool, which is the only thing that draws cursors.

local Cursor = {}
Cursor.__index = Cursor

-- Module-shared tunables — the pool overrides these via update args.
local SCAN_INTERVAL = 0.25      -- seconds between target scans while wandering
local WANDER_REPICK = 2.5       -- average seconds before picking a new drift point
local CLICK_RADIUS  = 6         -- px from button center to count as "arrived"

function Cursor:new(x, y)
    return setmetatable({
        x            = x or 0,
        y            = y or 0,
        target_idx   = nil,                  -- claimed hit-box.idx, or nil
        target_x     = x or 0,
        target_y     = y or 0,
        state        = "wandering",
        scan_timer   = 0,                    -- 0 = scan immediately on first tick
        wander_timer = 0,
    }, Cursor)
end

-- Drop the current claim. Pool removes our entry from `claims` separately.
function Cursor:releaseTarget()
    self.target_idx = nil
    self.state      = "wandering"
    self.scan_timer = 0
end

local function pickWanderPoint(self, W, H)
    -- Anywhere in the window, with a margin so cursors don't park at the
    -- exact edges where they look glitched.
    local margin = 24
    self.target_x = margin + math.random() * math.max(1, W - margin * 2)
    self.target_y = margin + math.random() * math.max(1, H - margin * 2)
    -- Re-pick interval has some variance so cursors don't sync.
    self.wander_timer = WANDER_REPICK * (0.6 + math.random() * 0.8)
end

-- Move toward target_x/target_y by `step` px.
local function stepToward(self, step)
    local dx, dy = self.target_x - self.x, self.target_y - self.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= step or dist <= 0.0001 then
        self.x, self.y = self.target_x, self.target_y
        return 0
    end
    self.x = self.x + (dx / dist) * step
    self.y = self.y + (dy / dist) * step
    return dist - step
end

-- Find the closest unclaimed deal hit_box and claim it. Mutates `claims`
-- so subsequent cursors in the same frame see the new claim.
local function tryClaim(self, deal_hbs, claims)
    local best, best_d2 = nil, math.huge
    for idx, hb in pairs(deal_hbs) do
        if not claims[idx] then
            local cx = hb.x + hb.w * 0.5
            local cy = hb.y + hb.h * 0.5
            local dx = cx - self.x
            local dy = cy - self.y
            local d2 = dx * dx + dy * dy
            if d2 < best_d2 then
                best_d2 = d2
                best    = hb
            end
        end
    end
    if best then
        self.target_idx = best.idx
        self.state      = "seeking"
        claims[best.idx] = true
    end
end

-- Per-frame update.
--   dt          — seconds since last frame
--   deal_hbs    — { [hit_box.idx] = hit_box } map of unmuted deal hit-boxes
--   claims      — { [idx] = true } shared claim map (mutated)
--   speed_px    — pre-computed pixels-per-second from the pool
--   W, H        — current screen dimensions (for wander bounds)
--   dispatcher  — callback fired with the hit_box on click-arrival
function Cursor:update(dt, deal_hbs, claims, speed_px, W, H, dispatcher)
    -- Brief freeze right after a click so the click pop is visible AT the button
    -- before the cursor darts off (otherwise it's a blur, especially at high
    -- Cursor Speed). The click already dispatched; this is purely the hold.
    if self._hold and self._hold > 0 then
        self._hold = self._hold - dt
        return
    end

    local step = speed_px * dt

    if self.state == "seeking" then
        local hb = deal_hbs[self.target_idx]
        if not hb then
            -- Target no longer claimable (busy / removed / muted).
            self:releaseTarget()
        else
            self.target_x = hb.x + hb.w * 0.5
            self.target_y = hb.y + hb.h * 0.5
            stepToward(self, step)
            local dx, dy = self.target_x - self.x, self.target_y - self.y
            if (dx * dx + dy * dy) <= (CLICK_RADIUS * CLICK_RADIUS) then
                if dispatcher then dispatcher(hb) end
                -- Transient flag the pool consumes this same frame to play
                -- the cursor-tap sound (distinct from the human-mouse path).
                self._just_dispatched = true
                self._hold = 0.22          -- hold in place so the click pop shows
                claims[self.target_idx] = nil
                self:releaseTarget()
                pickWanderPoint(self, W, H)
            end
        end
    end

    if self.state == "wandering" then
        if self.wander_timer <= 0 or
           ((self.x - self.target_x) ^ 2 + (self.y - self.target_y) ^ 2) < 16 then
            pickWanderPoint(self, W, H)
        else
            self.wander_timer = self.wander_timer - dt
        end
        stepToward(self, step * 0.55)   -- wander is slower than seek
        self.scan_timer = self.scan_timer - dt
        if self.scan_timer <= 0 then
            self.scan_timer = SCAN_INTERVAL
            tryClaim(self, deal_hbs, claims)
        end
    end
end

return Cursor
