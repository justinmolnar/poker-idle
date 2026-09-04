-- services/AnimationSystem.lua
--
-- Reusable animation primitives. Five timer-based curve types:
--   • flip     — rotation (cards, coins)
--   • bounce   — sine-wave vertical offset
--   • fade     — alpha lerp
--   • progress — bidirectional 0↔1 (face-up / face-down)
--   • timer    — bare countdown
--
-- Each primitive is a stateless factory that returns an animation object with
-- start / update / reset / isActive plus a curve-specific getter.
--
-- Call-site convention: PREFER `:create(preset_name, overrides)` over the raw
-- `createFlipAnimation`/etc. factories. The preset name resolves through
-- data/animations.lua so durations and curves stay DATA, not literals at the
-- call site.
--
-- Reach AnimationSystem through the DI container handed to your constructor
-- (`self.game.animations`), never via a global. Example:
--   local anim = self.game.animations:create("card_flip", { on_complete = fn })
--
-- The factory dispatch is registry-keyed (no if/elseif on `type` field).

local AnimationSystem = {}

local Motion    = require("services.Motion")
local AnimsData = require("data.animations")

-- ── Curve factories ──────────────────────────────────────────────────────────

local function createFlip(config)
    local anim = {
        duration         = config.duration or 0.5,
        speed_multiplier = config.speed_multiplier or 1.0,
        on_complete      = config.on_complete,
        timer            = 0,
        rotation         = 0,
        active           = false,
    }
    function anim:start()
        self.timer, self.rotation, self.active = 0, 0, true
    end
    function anim:update(dt)
        if not self.active then return end
        self.timer    = self.timer + dt
        self.rotation = self.rotation + dt * 20 * self.speed_multiplier
        if self.timer >= (self.duration / self.speed_multiplier) then
            self.active, self.timer, self.rotation = false, 0, 0
            if self.on_complete then self.on_complete() end
        end
    end
    function anim:getRotation() return self.rotation end
    function anim:isActive() return self.active end
    function anim:reset()
        self.timer, self.rotation, self.active = 0, 0, false
    end
    return anim
end

local function createBounce(config)
    local anim = {
        duration         = config.duration or 0.5,
        height           = config.height or 20,
        speed_multiplier = config.speed_multiplier or 1.0,
        on_complete      = config.on_complete,
        timer            = 0,
        offset           = 0,
        active           = false,
    }
    function anim:start()
        self.timer, self.offset, self.active = 0, 0, true
    end
    function anim:update(dt)
        if not self.active then return end
        self.timer = self.timer + dt
        local progress = self.timer / (self.duration / self.speed_multiplier)
        if progress <= 1.0 then
            self.offset = math.sin(progress * math.pi) * self.height
        end
        if self.timer >= (self.duration / self.speed_multiplier) then
            self.active, self.timer, self.offset = false, 0, 0
            if self.on_complete then self.on_complete() end
        end
    end
    function anim:getOffset() return self.offset end
    function anim:isActive() return self.active end
    function anim:reset()
        self.timer, self.offset, self.active = 0, 0, false
    end
    return anim
end

local function createFade(config)
    local anim = {
        duration    = config.duration or 0.3,
        from_alpha  = config.from or 0,
        to_alpha    = config.to or 1,
        on_complete = config.on_complete,
        timer       = 0,
        alpha       = config.from or 0,
        active      = false,
    }
    function anim:start()
        self.timer, self.alpha, self.active = 0, self.from_alpha, true
    end
    function anim:update(dt)
        if not self.active then return end
        self.timer = self.timer + dt
        local progress = math.min(self.timer / self.duration, 1.0)
        self.alpha = self.from_alpha + (self.to_alpha - self.from_alpha) * progress
        if self.timer >= self.duration then
            self.active, self.timer, self.alpha = false, 0, self.to_alpha
            if self.on_complete then self.on_complete() end
        end
    end
    function anim:getAlpha() return self.alpha end
    function anim:isActive() return self.active end
    function anim:reset()
        self.timer, self.alpha, self.active = 0, self.from_alpha, false
    end
    return anim
end

local function createProgress(config)
    local anim = {
        duration    = config.duration or 0.5,
        direction   = config.direction or 1,
        on_complete = config.on_complete,
        progress    = config.initial or 0,
        active      = false,
    }
    function anim:start(dir)
        if dir then self.direction = dir end
        self.active = true
    end
    function anim:update(dt)
        if not self.active then return end
        self.progress = self.progress + (dt / self.duration) * self.direction
        if self.direction > 0 and self.progress >= 1 then
            self.progress, self.active = 1, false
            if self.on_complete then self.on_complete(self.direction) end
        elseif self.direction < 0 and self.progress <= 0 then
            self.progress, self.active = 0, false
            if self.on_complete then self.on_complete(self.direction) end
        end
    end
    function anim:getProgress() return self.progress end
    function anim:isActive() return self.active end
    function anim:reset(initial)
        self.progress, self.active = initial or 0, false
    end
    return anim
end

local function createTimer(config)
    local timer = {
        duration    = config.duration or 1,
        on_complete = config.on_complete,
        elapsed     = 0,
        active      = false,
    }
    function timer:start()
        self.elapsed, self.active = 0, true
    end
    function timer:update(dt)
        if not self.active then return end
        self.elapsed = self.elapsed + dt
        if self.elapsed >= self.duration then
            self.active, self.elapsed = false, 0
            if self.on_complete then self.on_complete() end
        end
    end
    function timer:getRemaining() return math.max(0, self.duration - self.elapsed) end
    function timer:getProgress() return math.min(self.elapsed / self.duration, 1.0) end
    function timer:isActive() return self.active end
    function timer:reset()
        self.elapsed, self.active = 0, false
    end
    return timer
end

-- ── Registry: type → factory ─────────────────────────────────────────────────
-- This is the single dispatch point. Adding a new curve = one entry here.
-- No if/elseif chains anywhere else in the codebase.

local FACTORIES = {
    flip     = createFlip,
    bounce   = createBounce,
    fade     = createFade,
    progress = createProgress,
    timer    = createTimer,
}

-- ── Public API ───────────────────────────────────────────────────────────────

-- Look up a preset in data/animations.lua and instantiate it. `overrides` is
-- merged into the preset's config (handy for `on_complete`).
-- `group` (optional): a services/Motion group. Medium shortens the
-- animation; Low and None make it complete on its first update, so the
-- view's own fade (Motion.fade) is the only motion left.
function AnimationSystem.create(_, preset_name, overrides, group)
    local preset = AnimsData[preset_name]
    if not preset then
        error("AnimationSystem: unknown preset '" .. tostring(preset_name) .. "'")
    end
    local config = {}
    for k, v in pairs(preset) do config[k] = v end
    if overrides then
        for k, v in pairs(overrides) do config[k] = v end
    end
    if group then
        local lvl = Motion.level(group)
        if lvl <= Motion.LOW then config.duration = 0.0001
        elseif lvl == Motion.MEDIUM then config.duration = (config.duration or 0.3) * 0.6 end
    end
    local factory = FACTORIES[preset.type]
    if not factory then
        error("AnimationSystem: unknown type '" .. tostring(preset.type) .. "' in preset '" .. preset_name .. "'")
    end
    return factory(config)
end

-- Direct-factory escape hatches for cases that genuinely need a one-off
-- (cinematic sequences, dynamically-tuned curves). Prefer .create() above.
AnimationSystem.createFlipAnimation     = createFlip
AnimationSystem.createBounceAnimation   = createBounce
AnimationSystem.createFadeAnimation     = createFade
AnimationSystem.createProgressAnimation = createProgress
AnimationSystem.createTimer             = function(duration, on_complete)
    return createTimer({ duration = duration, on_complete = on_complete })
end

return AnimationSystem
