-- models/Cursor.lua
--
-- A single autonomous on-screen cursor. State machine:
--   wandering → seeking → wandering
--   seeking   → cleaning / stunned
--
--   wandering — no claimed target. Drifts toward a random wander point in
--               the window; scans visible hit-boxes for targets.
--   seeking   — has a target. Travels in a straight line toward the target.
--               On arrival (within CLICK_RADIUS), dispatches click.
--   cleaning  — trackball pause every 10 clicks. Spins in place for 2.5s.
--   stunned   — collision recoil pause for 0.35s when bumping another cursor.
--
-- Engine-agnostic: holds pure state (x, y, angle, target, timers);
-- rendering lives in services/CursorPool.

local Cursor = {}
Cursor.__index = Cursor

local SCAN_INTERVAL = 0.25      -- seconds between target scans while wandering
local WANDER_REPICK = 2.5       -- average seconds before picking a new drift point
local CLICK_RADIUS  = 6         -- px from button center to count as "arrived"

function Cursor:new(x, y)
    return setmetatable({
        x                 = x or 0,
        y                 = y or 0,
        angle             = 0,                     -- rotation angle in radians (for cleaning spin)
        target_idx        = nil,                   -- claimed hit-box.idx, or nil
        target_x          = x or 0,
        target_y          = y or 0,
        state             = "wandering",           -- wandering | seeking | cleaning | stunned
        scan_timer        = 0,                     -- 0 = scan immediately on first tick
        wander_timer      = 0,
        seek_timer        = 0,                     -- elapsed time seeking (memory timeout)
        click_count       = 0,                     -- total clicks since last trackball cleaning
        clean_timer       = 0,                     -- timer for trackball cleaning spin
        stun_timer        = 0,                     -- timer for collision recoil/stun
        recoil_vx         = 0,                     -- recoil velocity x on collision
        recoil_vy         = 0,                     -- recoil velocity y on collision
    }, Cursor)
end

-- Drop current claim. Pool removes entry from claims map separately.
function Cursor:releaseTarget()
    self.target_idx = nil
    self.state      = "wandering"
    self.scan_timer = 0
    self.seek_timer = 0
end

-- Trigger collision recoil stun
function Cursor:triggerStun(vx, vy, duration)
    self:releaseTarget()
    self.state      = "stunned"
    self.stun_timer = duration or 0.35
    self.recoil_vx  = vx or 0
    self.recoil_vy  = vy or 0
end

local function pickWanderPoint(self, W, H)
    local margin = 24
    self.target_x = margin + math.random() * math.max(1, W - margin * 2)
    self.target_y = margin + math.random() * math.max(1, H - margin * 2)
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

-- Find target hit_box and claim it.
-- When allow_duplicate is true (un-synchronized), uses distance-weighted
-- random sampling so mice spread naturally across open tables instead of all
-- 50 mice deterministically dogpiling on the exact same single button.
local function tryClaim(self, deal_hbs, claims, allow_duplicate)
    local candidates = {}
    local total_weight = 0
    local best_unclaimed, best_unclaimed_d2 = nil, math.huge
    local best_any, best_any_d2 = nil, math.huge

    for idx, hb in pairs(deal_hbs) do
        local cx = hb.x + hb.w * 0.5
        local cy = hb.y + hb.h * 0.5
        local dx = cx - self.x
        local dy = cy - self.y
        local d2 = dx * dx + dy * dy
        local dist = math.sqrt(d2)

        if not claims[idx] then
            if d2 < best_unclaimed_d2 then
                best_unclaimed_d2 = d2
                best_unclaimed    = hb
            end
        end
        if d2 < best_any_d2 then
            best_any_d2 = d2
            best_any    = hb
        end

        if allow_duplicate then
            -- Inverse-distance weight: closer tables are more likely, but mice
            -- will pick different tables across the room.
            local weight = 1.0 / (dist + 60.0)
            candidates[#candidates + 1] = { hb = hb, weight = weight }
            total_weight = total_weight + weight
        end
    end

    local chosen = nil
    if not allow_duplicate then
        -- Synced: strictly pick nearest unclaimed table
        chosen = best_unclaimed
    else
        -- Un-synced: roll distance-weighted random selection
        if total_weight > 0 and #candidates > 0 then
            local roll = math.random() * total_weight
            local accum = 0
            for _, c in ipairs(candidates) do
                accum = accum + c.weight
                if roll <= accum then
                    chosen = c.hb
                    break
                end
            end
            chosen = chosen or candidates[1].hb
        end
    end

    if chosen then
        self.target_idx = chosen.idx
        self.state      = "seeking"
        self.seek_timer = 0
        if not allow_duplicate then
            claims[chosen.idx] = true
        end
    end
end

-- Per-frame update.
function Cursor:update(dt, deal_hbs, claims, speed_px, W, H, dispatcher, ctx)
    local allow_duplicate = not (ctx and ctx.cursor_sync_unlocked)
    local memory_unlocked = (ctx and ctx.cursor_memory_unlocked)
    local optical_sensor  = (ctx and ctx.cursor_optical_sensor)

    -- 1. Handle STUNNED state (dramatic collision launch & friction slide)
    if self.state == "stunned" then
        self.stun_timer = self.stun_timer - dt
        if self.stun_timer <= 0 then
            self.state = "wandering"
            self.recoil_vx, self.recoil_vy = 0, 0
            pickWanderPoint(self, W, H)
        else
            -- Physics motion + friction deceleration (slides to a halt)
            local friction = math.max(0, 1.0 - dt * 3.5)
            self.x = self.x + self.recoil_vx * dt
            self.y = self.y + self.recoil_vy * dt
            self.recoil_vx = self.recoil_vx * friction
            self.recoil_vy = self.recoil_vy * friction

            -- Wall bounce elasticity on screen borders
            local margin = 16
            if self.x < margin then
                self.x = margin
                self.recoil_vx = -self.recoil_vx * 0.8
            elseif self.x > W - margin then
                self.x = W - margin
                self.recoil_vx = -self.recoil_vx * 0.8
            end
            if self.y < margin then
                self.y = margin
                self.recoil_vy = -self.recoil_vy * 0.8
            elseif self.y > H - margin then
                self.y = H - margin
                self.recoil_vy = -self.recoil_vy * 0.8
            end
        end
        return
    end

    -- 2. Handle CLEANING state (trackball cleaning spin)
    if self.state == "cleaning" then
        self.clean_timer = self.clean_timer - dt
        self.angle = self.angle + dt * math.pi * 4.0
        if self.clean_timer <= 0 then
            self.angle = 0
            self.state = "wandering"
            pickWanderPoint(self, W, H)
        end
        return
    end

    -- Brief hold right after click
    if ctx and ctx.cursor_zero_click_delay then
        self._hold = 0
    elseif self._hold and self._hold > 0 then
        self._hold = self._hold - dt
        return
    end

    local step = speed_px * dt

    -- 3. Handle SEEKING state
    if self.state == "seeking" then
        local hb = deal_hbs[self.target_idx]
        if not hb then
            self:releaseTarget()
            pickWanderPoint(self, W, H)
        else
            self.target_x = hb.x + hb.w * 0.5
            self.target_y = hb.y + hb.h * 0.5
            stepToward(self, step)
            local dx, dy = self.target_x - self.x, self.target_y - self.y
            if (dx * dx + dy * dy) <= (CLICK_RADIUS * CLICK_RADIUS) then
                if dispatcher then dispatcher(hb) end
                self._just_dispatched = true
                self._hold = (ctx and ctx.cursor_zero_click_delay) and 0.0 or 0.22
                if not allow_duplicate then
                    claims[self.target_idx] = nil
                end
                self:releaseTarget()

                -- Trackball cleaning check (every 10 clicks unless optical sensor owned)
                self.click_count = self.click_count + 1
                if not optical_sensor and self.click_count >= 10 then
                    self.click_count = 0
                    self.state = "cleaning"
                    self.clean_timer = 2.5
                else
                    pickWanderPoint(self, W, H)
                end
            end
        end
    end

    -- 4. Handle WANDERING state
    if self.state == "wandering" then
        if self.wander_timer <= 0 or
           ((self.x - self.target_x) ^ 2 + (self.y - self.target_y) ^ 2) < 16 then
            pickWanderPoint(self, W, H)
        else
            self.wander_timer = self.wander_timer - dt
        end
        stepToward(self, step * 0.55)
        local interval = (ctx and ctx.cursor_zero_click_delay) and 0.0 or SCAN_INTERVAL
        self.scan_timer = self.scan_timer - dt
        if self.scan_timer <= 0 then
            self.scan_timer = interval
            tryClaim(self, deal_hbs, claims, allow_duplicate)
        end
    end
end

return Cursor
