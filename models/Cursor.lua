-- models/Cursor.lua
--
-- A single autonomous on-screen cursor. State machine:
--   wandering → seeking → wandering
--   seeking   → cleaning / stunned
--
--   wandering — no claimed target. Drifts toward a random wander point in
--               the window; scans visible hit-boxes for targets.
--   seeking   — has a target. Travels with organic steering & wrist-arc
--               curvature toward the target. On arrival (within CLICK_RADIUS),
--               dispatches click.
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
        vx                = 0,                     -- current velocity x (px/sec)
        vy                = 0,                     -- current velocity y (px/sec)
        start_x           = x or 0,                -- leg start x
        start_y           = y or 0,                -- leg start y
        total_dist        = 1,                     -- initial distance of current leg
        arc_sign          = 1,                     -- +1 or -1 for lateral wrist curve
        arc_scale         = 0.2,                   -- curvature intensity
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
    self.target_idx      = nil
    self.target_offset_x = nil
    self.target_offset_y = nil
    self.state           = "wandering"
    self.scan_timer      = 0
    self.seek_timer      = 0
end

-- Trigger collision recoil stun
function Cursor:triggerStun(vx, vy, duration)
    self:releaseTarget()
    self.state      = "stunned"
    self.stun_timer = duration or 0.35
    self.recoil_vx  = vx or 0
    self.recoil_vy  = vy or 0
    self.vx         = vx or 0
    self.vy         = vy or 0
end

local function pickWanderPoint(self, W, H)
    local margin = 24
    local tx = margin + math.random() * math.max(1, W - margin * 2)
    local ty = margin + math.random() * math.max(1, H - margin * 2)
    self.target_x = tx
    self.target_y = ty
    self.wander_timer = WANDER_REPICK * (0.6 + math.random() * 0.8)

    self.start_x    = self.x
    self.start_y    = self.y
    local dx        = tx - self.x
    local dy        = ty - self.y
    self.total_dist = math.max(1, math.sqrt(dx * dx + dy * dy))
    self.arc_sign   = (math.random() < 0.5) and 1 or -1
    self.arc_scale  = 0.15 + math.random() * 0.20
end

-- Move toward target_x/target_y using organic steering & lateral wrist curvature.
local function moveOrganic(self, dt, target_speed)
    local dx = self.target_x - self.x
    local dy = self.target_y - self.y
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist <= 0.001 then
        self.x, self.y = self.target_x, self.target_y
        self.vx, self.vy = 0, 0
        return 0
    end

    -- Base unit vector toward target
    local ux, uy = dx / dist, dy / dist

    -- Perpendicular unit vector (lateral wrist curve)
    local px, py = -uy, ux

    -- Progress [0, 1] along the current travel leg
    local total = self.total_dist or dist
    if total < 1 then total = 1 end
    local progress = math.max(0, math.min(1.0, 1.0 - (dist / total)))

    -- Natural wrist arc: sine curve peaking at mid-flight (progress = 0.5)
    local arc_sign = self.arc_sign or 1
    local arc_scale = self.arc_scale or 0.20
    local lateral = math.sin(math.pi * progress) * arc_sign * arc_scale

    -- Composite target direction vector
    local dir_x = ux + px * lateral
    local dir_y = uy + py * lateral
    local dir_len = math.sqrt(dir_x * dir_x + dir_y * dir_y)
    if dir_len > 0.001 then
        dir_x = dir_x / dir_len
        dir_y = dir_y / dir_len
    else
        dir_x, dir_y = ux, uy
    end

    -- Ease-out / Fitts's law deceleration near target
    local eff_speed = target_speed
    if dist < 50 and self.state == "seeking" then
        eff_speed = target_speed * math.max(0.35, dist / 50.0)
    end

    local desired_vx = dir_x * eff_speed
    local desired_vy = dir_y * eff_speed

    -- Steering responsiveness (higher when close so cursor doesn't orbit)
    local turn_rate = 10.0
    if dist < 60 then
        turn_rate = 10.0 + (60 - dist) * 0.45
    end

    local blend = math.min(1.0, dt * turn_rate)
    self.vx = (self.vx or 0) + (desired_vx - (self.vx or 0)) * blend
    self.vy = (self.vy or 0) + (desired_vy - (self.vy or 0)) * blend

    local step_vx = self.vx * dt
    local step_vy = self.vy * dt
    local step_len = math.sqrt(step_vx * step_vx + step_vy * step_vy)

    if dist <= step_len then
        self.x = self.target_x
        self.y = self.target_y
        self.vx, self.vy = 0, 0
        return 0
    else
        self.x = self.x + step_vx
        self.y = self.y + step_vy
        return dist - step_len
    end
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
        local bx = hb.visual_x or hb.x
        local by = hb.visual_y or hb.y
        local bw = hb.visual_w or hb.w
        local bh = hb.visual_h or hb.h
        local cx = bx + bw * 0.5
        local cy = by + bh * 0.5
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
        local bx        = chosen.visual_x or chosen.x
        local by        = chosen.visual_y or chosen.y
        local bw        = chosen.visual_w or chosen.w
        local bh        = chosen.visual_h or chosen.h
        local ox        = (0.20 + math.random() * 0.60) * bw
        local oy        = (0.20 + math.random() * 0.60) * bh
        self.target_offset_x = ox
        self.target_offset_y = oy
        local tx        = bx + ox
        local ty        = by + oy
        self.target_x   = tx
        self.target_y   = ty

        self.start_x    = self.x
        self.start_y    = self.y
        local dx        = tx - self.x
        local dy        = ty - self.y
        self.total_dist = math.max(1, math.sqrt(dx * dx + dy * dy))
        self.arc_sign   = (math.random() < 0.5) and 1 or -1
        self.arc_scale  = 0.15 + math.random() * 0.20

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
            self.vx, self.vy = 0, 0
            pickWanderPoint(self, W, H)
        else
            -- Physics motion + friction deceleration (slides to a halt)
            local friction = math.max(0, 1.0 - dt * 3.5)
            self.x = self.x + self.recoil_vx * dt
            self.y = self.y + self.recoil_vy * dt
            self.recoil_vx = self.recoil_vx * friction
            self.recoil_vy = self.recoil_vy * friction
            self.vx = self.recoil_vx
            self.vy = self.recoil_vy

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

    -- 2. Handle CLEANING state (trackball cleaning wobble)
    if self.state == "cleaning" then
        self.clean_timer = self.clean_timer - dt
        self.angle = math.sin((1.4 - self.clean_timer) * 12.0) * 0.25
        if self.clean_timer <= 0 then
            self.angle = 0
            self.state = "wandering"
            self.vx, self.vy = 0, 0
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

    -- 3. Handle SEEKING state
    if self.state == "seeking" then
        local hb = deal_hbs[self.target_idx]
        if not hb then
            self:releaseTarget()
            pickWanderPoint(self, W, H)
        else
            local bx = hb.visual_x or hb.x
            local by = hb.visual_y or hb.y
            local bw = hb.visual_w or hb.w
            local bh = hb.visual_h or hb.h
            local ox = self.target_offset_x or (bw * 0.5)
            local oy = self.target_offset_y or (bh * 0.5)
            self.target_x = bx + ox
            self.target_y = by + oy
            moveOrganic(self, dt, speed_px)
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
                    self.clean_timer = 1.4
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
        moveOrganic(self, dt, speed_px * 0.55)
        local interval = (ctx and ctx.cursor_zero_click_delay) and 0.0 or SCAN_INTERVAL
        self.scan_timer = self.scan_timer - dt
        if self.scan_timer <= 0 then
            self.scan_timer = interval
            tryClaim(self, deal_hbs, claims, allow_duplicate)
        end
    end
end

return Cursor
