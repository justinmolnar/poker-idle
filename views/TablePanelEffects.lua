-- views/TablePanelEffects.lua
--
-- Per-panel VFX layer extracted from views/TablePanel: trauma-shake,
-- hover lift, drop shadow, border pulse on resolution, radial glow halo,
-- and the win/loss vignette. Pure draw / transform logic — reads tween
-- fields off the Table model (set by Table:update) and renders.
--
-- Sibling-module split mirrors views/TablePanelStats; TablePanel.lua
-- requires both and routes calls through them.

local Theme          = require("views.Theme")
local ShaderRegistry = require("services.ShaderRegistry")
local FeltDecor      = require("views.FeltDecor")
local FeltStyle      = require("data.felt_style")
local StatusData     = require("data.statuses")
local Pop            = require("services.Pop")

local Motion         = require("services.Motion")
-- The per-frame pop keys ("tbl_bump:<id>", "tbl_shove:<id>") come from
-- Table.rollingKey, memoized on the table: the same strings, built once
-- instead of concatenated on every panel every frame.
local TableModel     = require("models.Table")
local Perf           = require("services.Perf")
local Effects = {}

-- ── Tunables ─────────────────────────────────────────────────────────
local SHAKE_MAX_PX        = 8     -- amplitude at trauma=1; trauma² scaling
local VIGNETTE_MAX_ALPHA  = 0.65
-- The panel used to hover up 18px during a hand (LIFT_MAX_PX). It does
-- not any more: the whole panel moved, so the close X, the chrome bar and
-- every tooltip hover area moved with it, and with cursors dealing the
-- targets were never still. lift_t survives as the "in a hand" amount
-- (0..1, eased) and drives the live frame below instead.
-- The felt light. Not on the border: the gold bounty trim owns the
-- panel's frame and nothing competes with it. The cloth itself lights
-- while a hand runs (a lamp over the table) and pops brighter on the deal.
local LIGHT_COLOR         = { 1.00, 0.96, 0.86 }   -- warm lamp
local LIGHT_ALPHA         = 0.05  -- the cloth at full "in a hand": a lamp on, not a spotlight
local DEAL_FLASH_ALPHA    = 0.22  -- the deal's pop, over the light, decaying
local BORDER_PULSE_MAX_W  = 10    -- max border-line width at pulse=1
local BORDER_PULSE_ALPHA  = 1.0

local SHADOW_COLOR        = { 0, 0, 0 }
local SHADOW_DROP_X       = 4         -- horizontal drop offset (light from upper-left)
local SHADOW_DROP_Y       = 8         -- baseline vertical drop offset at rest

local GLOW_COLOR          = { 1.00, 0.85, 0.30 }   -- warm gold
local SHADER_PASS_COLOR   = { 1, 1, 1 }     -- identity tint so the shader's
                                            -- output passes through; the
                                            -- previous setColor would
                                            -- otherwise modulate it down.
local TILT_MAX_RAD        = 0.090   -- ~5 degrees; hit boxes rotate to match
local WASH_GAIN           = 16      -- status magnitude -> wash strength 0..1
local WASH_VEIL_ALPHA     = 0.30    -- the grey-ward veil over the multiply
local BUMP_MAX_PX         = 78      -- how far a shove throws a panel
local BUMP_LUNGE_PX       = 60      -- how far the shover travels into it
local BUMP_SLAM_PX        = 64      -- how far a fist drives the table down
local SLAM_RISE_PX        = 62      -- how far it rears back first
local SLAM_LIFT           = 1.26    -- ...growing toward the camera as it does
local SLAM_SQUASH         = 0.30    -- how flat it goes on the strike
-- Timing is shared with the controller via data/statuses.lua, so the
-- frame the fist lands is the frame the shockwave leaves.
local SLAM               = StatusData.slam or {}
local SLAM_RISE          = SLAM.rise or 0.60
local SLAM_STRIKE        = SLAM.strike or 0.05
local SLAM_BOUNCES       = SLAM.bounces or 2.5
local BUMP_GROW           = 0.20    -- punch when shoving several at once
local SHOVE              = StatusData.shove or {}
local BUMP_DURATION      = SHOVE.duration or 1.0
local SHOVE_RISE         = SHOVE.rise or 0.38
local SHOVE_STRIKE       = SHOVE.strike or 0.07
local SHOVE_BOUNCES      = SHOVE.bounces or 2.0
local SHOVE_PULL_PX      = 26     -- how far it draws back before thrusting
local SHOVE_LIFT         = 1.10   -- ...rearing up slightly as it does
local BUMP_ROCK_RAD       = 0.16    -- ~9 degrees of rock from taking a hit
local BUMP_ROCKS          = 3.0     -- half-cycles the impact rocks through
local UNTILT_ROTATE       = 2.0     -- lean the shake-off unwinds from
local UNTILT_ROCKS        = 3.0     -- half-cycles it rocks through
local GLOW_RECT_PAD       = 80              -- draw the glow rect this many
                                            -- px outside the panel on every
                                            -- side so the halo bleeds beyond
                                            -- panel edges instead of cutting
                                            -- off at the border.

-- ── Transforms ───────────────────────────────────────────────────────

function Effects.shakeOffset(tbl)
    local trauma = tbl.shake_trauma or 0
    if trauma <= 0 or not Motion.at("tables", Motion.FULL) then return 0, 0 end
    local amp = SHAKE_MAX_PX * trauma * trauma
    return (love.math.random() * 2 - 1) * amp,
           (love.math.random() * 2 - 1) * amp
end

-- The deal's press. The panel dips a few px and squashes toward its
-- bottom edge, then springs back, over about a quarter second, and is
-- still again: motion the player reads as "dealt" without a lifted
-- panel that holds its click targets somewhere else for the whole
-- hand. Returns dy (down is positive), sx, sy; TablePanel folds them
-- into the transform stack and the hit boxes follow dy the way they
-- followed the lift. amp comes jittered from the deal (see
-- GrindController:_dealFx), the way a sound's pitch is.
local DEAL_DIP_PX  = 4
local DEAL_SQUASH  = 0.035
function Effects.dealSpring(tbl)
    local ds = tbl.deal_spring
    if not ds or (ds.t or 0) <= 0 then return 0, 1, 1 end
    local lvl = Motion.level("tables")
    if lvl <= Motion.LOW then return 0, 1, 1 end
    local k = (lvl == Motion.MEDIUM) and 0.5 or 1
    -- One half-sine: down and back, no overshoot to settle from.
    local p = math.sin((1 - ds.t) * math.pi) * (ds.amp or 1) * k
    return DEAL_DIP_PX * p, 1 + DEAL_SQUASH * 0.6 * p, 1 - DEAL_SQUASH * p
end

-- The panel's vertical offset during a hand: only the deal's spring.
-- A panel in a hand otherwise sits exactly where it sits at rest, and so
-- do its click targets.
function Effects.liftSlamOffset(tbl)
    local dy = Effects.dealSpring(tbl)
    return dy
end

-- In a hand: the cloth lights. lift_t eases 0 -> 1 as the hand starts
-- and snaps to 0 at settle (Table:update), so the light comes up with
-- the deal and goes out on the frame the result lands, the way the lift
-- used to rise and drop. The deal itself pops the light brighter for a
-- moment (border_pulse_t with kind "deal", set by GrindController:_dealFx
-- and decayed in Table:update). Drawn on the felt SURFACE, under the
-- plate, the cards and the chips, inside the rail: the frame is the
-- bounty trim's and stays untouched. Low motion: the light holds at a
-- fixed level while a hand runs, no ramp and no pop.
function Effects.drawFeltLight(tbl, x, y, w, h, radius)
    local live = tbl.lift_t or 0
    local pop  = (tbl.border_pulse_color == "deal") and (tbl.border_pulse_t or 0) or 0
    if Motion.level("tables") <= Motion.LOW then
        live = (live > 0.5) and 1 or 0
        pop  = 0
    end
    if live <= 0.01 and pop <= 0.01 then return end
    -- One even wash over the whole cloth: a second, inset pool read as
    -- another area on the felt, so there is none.
    local a = live * LIGHT_ALPHA + pop * DEAL_FLASH_ALPHA
    Theme.setColor(LIGHT_COLOR, math.min(0.6, a))
    love.graphics.rectangle("fill", x, y, w, h, radius or 0)
end

-- ── Draw passes ──────────────────────────────────────────────────────

-- Drop shadow rendered at the panel's *base* (un-lifted) position so
-- when the panel translates upward the shadow stays put and is exposed
-- beneath the lifted panel. Three rounded-rectangle layers with
-- decreasing alpha approximate a soft edge.
--
-- Always rendered (subtle 3px / 6px offset visible at rest; bigger
-- visible footprint when lifted). Caller draws this BEFORE pushing the
-- lift transform so the shadow stays in fixed screen-space while the
-- panel translates up off it.
local _shadow_layers = { { spread = 0, alpha = 0 }, { spread = 0, alpha = 0 }, { spread = 0, alpha = 0 } }
function Effects.drawHoverShadow(tbl, x, y, w, h)
    local lift = tbl.lift_t or 0
    local r = Theme.space.radius

    -- Three layers. Outermost is biggest + most transparent for a soft
    -- edge feel; innermost is densest. Stacked behind the panel.
    --
    -- Written into a reused table rather than a fresh one per call: this
    -- runs once per panel per frame (twice while a panel is held), so at a
    -- full board it was ~150 throwaway tables a frame for three rectangles.
    local layers = _shadow_layers
    layers[1].spread, layers[1].alpha = 8 + lift * 6, 0.10 + lift * 0.05
    layers[2].spread, layers[2].alpha = 4 + lift * 4, 0.18 + lift * 0.08
    layers[3].spread, layers[3].alpha = 0,            0.45 + lift * 0.10

    for i = 1, 3 do
        local L = layers[i]
        Theme.setColor(SHADOW_COLOR, L.alpha)
        love.graphics.rectangle(
            "fill",
            x + SHADOW_DROP_X - L.spread,
            y + SHADOW_DROP_Y - L.spread,
            w + L.spread * 2,
            h + L.spread * 2,
            r + L.spread)
    end
end

-- The held panel's shadow. A panel in the player's hand is off the
-- board, so its shadow is not the resting drop under a slightly raised
-- edge (drawHoverShadow): it is thrown further down and to the right
-- the higher the panel lifts, wider and softer, and it leans with the
-- panel's sway (it is drawn rotated about the same centre, and slides
-- the opposite way the panel tilts, the way a card's shadow crosses
-- under it when you tip it). At lift 0 it is the resting shadow, so the
-- pick-up eases out of one into the other.
local HELD_SHADOW_DROP    = 18     -- extra drop (px) at full lift, down and right
local HELD_SHADOW_SPREAD  = 14     -- extra softness at full lift
local HELD_SHADOW_LEAN_PX = 90     -- lateral slide per radian of sway
local _held_layers = { {}, {}, {}, {} }
function Effects.drawHeldShadow(x, y, w, h, lift, tilt)
    lift = math.max(0, math.min(1, lift or 0))
    tilt = tilt or 0
    local r    = Theme.space.radius
    local drop = lift * HELD_SHADOW_DROP
    local sx = x + SHADOW_DROP_X + drop * 0.8 - tilt * HELD_SHADOW_LEAN_PX * lift
    local sy = y + SHADOW_DROP_Y + drop
    local cx, cy = sx + w / 2, sy + h / 2
    -- Outermost first: widest and faintest; the last sits under the panel
    -- itself and carries the weight. The whole stack dims a little as it
    -- lifts (further from the thing casting it) and spreads a lot.
    local L = _held_layers
    L[1].spread, L[1].alpha = 10 + lift * HELD_SHADOW_SPREAD,        0.06 + lift * 0.04
    L[2].spread, L[2].alpha = 5  + lift * HELD_SHADOW_SPREAD * 0.6,  0.12 + lift * 0.04
    L[3].spread, L[3].alpha = 2  + lift * HELD_SHADOW_SPREAD * 0.3,  0.20 + lift * 0.02
    L[4].spread, L[4].alpha = 0,                                      0.42 - lift * 0.10
    Effects.pushRotated(cx, cy, tilt)
    for i = 1, 4 do
        local e = L[i]
        Theme.setColor(SHADOW_COLOR, e.alpha)
        love.graphics.rectangle("fill", sx - e.spread, sy - e.spread,
                                w + e.spread * 2, h + e.spread * 2, r + e.spread)
    end
    Effects.popRotated()
end

-- Border-pulse colored frame on top of the panel chrome. Drawn AFTER
-- the panel chrome (so it overlays the regular border) but BEFORE felt
-- content (so cards/chips render on top of the colored ring).
function Effects.drawBorderPulse(tbl, x, y, w, h)
    local t = tbl.border_pulse_t or 0
    if t <= 0.001 or not tbl.border_pulse_color then return end
    -- "good" / "bad" are a result landing (the resolution loop). "deal"
    -- is the hand starting, and that one is NOT a border: the felt light
    -- (drawFeltLight) carries it, so the bounty trim keeps the frame.
    local kind = tbl.border_pulse_color
    if kind == "deal" then return end
    local color = (kind == "good") and Theme.sem.won or Theme.sem.lost
    -- Low motion: the frame at full width for as long as the pulse runs,
    -- no ramp.
    if Motion.level("tables") <= Motion.LOW then t = 1 end
    local line_w = math.max(1, math.floor(BORDER_PULSE_MAX_W * t + 0.5))
    Theme.setColor(color, t * BORDER_PULSE_ALPHA)
    love.graphics.setLineWidth(line_w)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

-- ── Shader quad ───────────────────────────────────────────────────────
-- A rect a fragment shader can actually read its position in.
-- love.graphics.rectangle hands the shader tex_coords = (0,0) at EVERY
-- fragment (verified by pixel readback), so any shader whose falloff or
-- shape keys off tex_coords renders one constant color — usually alpha 0.
-- The radial glow was silently invisible for exactly this reason. A 1×1
-- white texture drawn scaled to the rect carries real 0..1 coords.
local _quad_img
local function shaderRect(x, y, w, h)
    if not _quad_img then
        local id = love.image.newImageData(1, 1)
        id:setPixel(0, 0, 1, 1, 1, 1)
        _quad_img = love.graphics.newImage(id)
    end
    love.graphics.draw(_quad_img, x, y, 0, w, h)
end

-- Radial-glow halo via shader. Rendered additively over the panel rect
-- after all other content. Falls back to plain rendering if the shader
-- failed to compile (graceful degradation — see ShaderRegistry).
function Effects.drawGlow(tbl, x, y, w, h)
    local t = tbl.glow_t or 0
    if t <= 0.001 then return end
    -- Low motion: a still glow for the settle window, no ramp.
    if Motion.level("tables") <= Motion.LOW then t = 0.4 end
    local sh = ShaderRegistry.get("radial_glow")
    if not sh then return end
    local gx = x - GLOW_RECT_PAD
    local gy = y - GLOW_RECT_PAD
    local gw = w + GLOW_RECT_PAD * 2
    local gh = h + GLOW_RECT_PAD * 2
    Theme.setColor(SHADER_PASS_COLOR, 1)
    Perf.count("shader_switch")
    love.graphics.setShader(sh)
    sh:send("u_color",     GLOW_COLOR)
    sh:send("u_intensity", t)
    love.graphics.setBlendMode("add", "alphamultiply")
    shaderRect(gx, gy, gw, gh)
    love.graphics.setBlendMode("alpha")
    love.graphics.setShader()
end

-- ─── Table statuses (data/statuses.lua) ───────────────────────────────
-- A status is a lasting condition, not a result, so it gets treatments
-- that persist rather than decay: a heater breathes a warm halo, a tilt
-- washes the felt cold. Both scale with the status magnitude.
--
-- The strongest active status carrying a given treatment wins — statuses
-- are keyed by kind and refresh rather than stack, so there is never a
-- pile of them to blend.
local function strongestWith(tbl, field)
    local best, best_def
    local list = tbl.statuses
    if not list then return nil end
    for _, e in ipairs(list) do
        local def = StatusData[e.kind]
        if def and def[field] and (not best or e.magnitude > best.magnitude) then
            best, best_def = e, def
        end
    end
    return best, best_def
end

-- Resolve a "status_fx.heater"-style token string to a colour.
local tokenColor = Theme.color

-- Warm halo for a heater. Reuses the stack glow's shader with a
-- different colour — no new shader, no new compile. Absent (not shrunk)
-- on small panels: below the gate the border carries the signal instead,
-- because an 80px additive pad around a 137px panel is 5x the panel's own
-- area and 32 of those is a lot of fill for something that reads as mush.
function Effects.drawStatusGlow(tbl, x, y, w, h)
    if not tbl.statuses then return end
    -- Nothing shows while a blow is still in the air.
    if (tbl.impact_wait or 0) > 0 then return end
    local gates = StatusData.gates or {}
    if w < (gates.glow_min_panel_w or 0) then return end
    local e, def = strongestWith(tbl, "glow_token")
    if not e then return end
    local color = tokenColor(def.glow_token)
    local sh = ShaderRegistry.get("radial_glow")
    if not (color and sh) then return end

    -- Breathe, so a lasting status doesn't read as a frozen frame. Below
    -- High nothing loops: the halo holds.
    local pulse = Motion.at("tables", Motion.HIGH)
        and (0.80 + 0.20 * math.sin((love.timer and love.timer.getTime() or 0) * 3.0)) or 0.9
    local intensity = math.min(1, (e.magnitude or 0) * 8) * pulse
    if intensity <= 0.01 then return end

    local pad = math.min(GLOW_RECT_PAD, math.floor(w * 0.30))
    Theme.setColor(SHADER_PASS_COLOR, 1)
    Perf.count("shader_switch")
    love.graphics.setShader(sh)
    sh:send("u_color", color)
    sh:send("u_intensity", intensity)
    love.graphics.setBlendMode("add", "alphamultiply")
    shaderRect(x - pad, y - pad, w + pad * 2, h + pad * 2)
    love.graphics.setBlendMode("alpha")
    love.graphics.setShader()
end

-- The tilt wash: the lights going out on a table.
--
-- Two passes, no shader — this has to survive being on many panels at
-- once, and both passes are ordinary batched rects.
--
--   1. MULTIPLY toward the status colour. Multiply can only ever DARKEN,
--      which is the whole point: a flat alpha wash lightens the felt
--      toward the overlay, and pale reads as washed-out rather than as
--      punished. Dark reads as dead.
--   2. A neutral veil on top, pulling what survives toward grey so the
--      felt reads genuinely DESATURATED instead of merely tinted blue.
--
-- Together: darker, greyer, colder. Applied over the felt after its
-- cards and chips, so the whole table dims, not just the cloth.
function Effects.drawStatusWash(tbl, felt_x, felt_y, felt_w, felt_h)
    if not tbl.statuses then return end
    -- Nothing shows while a blow is still in the air.
    if (tbl.impact_wait or 0) > 0 then return end
    local e, def = strongestWith(tbl, "wash_token")
    if not e then return end
    local color = tokenColor(def.wash_token)
    if not color then return end
    local k = math.min(1, (e.magnitude or 0) * WASH_GAIN)
    if k <= 0.01 then return end

    -- Lerp the multiplier from white (no change) toward the status colour.
    love.graphics.setBlendMode("multiply", "premultiplied")
    love.graphics.setColor(1 - k * (1 - color[1]),
                           1 - k * (1 - color[2]),
                           1 - k * (1 - color[3]), 1)
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h,
                            Theme.space.radius)
    love.graphics.setBlendMode("alpha")

    Theme.setColor(color, k * WASH_VEIL_ALPHA)
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h,
                            Theme.space.radius)
end

-- The always-legible half: a tinted ring, at any panel size. This is what
-- says "something is happening here" when the panel is too small for a
-- glow, and it reinforces it when it isn't.
function Effects.drawStatusRing(tbl, x, y, w, h)
    if not tbl.statuses then return end
    -- Nothing shows while a blow is still in the air.
    if (tbl.impact_wait or 0) > 0 then return end
    -- The list can be EMPTY, not just nil — status removal (punch expiry,
    -- Cool Towel's cleanse) pops entries mid-frame and this draws off the
    -- same table state. Indexing [1] unguarded was a crash.
    local e = tbl.statuses[1]
    if not e then return end
    local def = StatusData[e.kind]
    if not def then return end
    local color = tokenColor(def.glow_token or def.wash_token)
    if not color then return end
    local pulse = Motion.at("tables", Motion.HIGH)
        and (0.55 + 0.45 * math.sin((love.timer and love.timer.getTime() or 0) * 3.0)) or 0.75
    Theme.setColor(color, 0.30 + 0.25 * pulse)
    love.graphics.setLineWidth(math.max(1, math.floor(2 * (w / 400))))
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

-- A tilted table sits askew until it settles — the pun made literal.
-- Returned in radians, capped hard: the panel's click targets get rotated
-- to match (see TablePanel's hit-box fixup), but the further a corner
-- swings the more a near-miss costs the player. Direction is seeded off
-- the table id so neighbours lean opposite ways instead of in formation.
function Effects.statusRotation(tbl)
    -- Low motion: nothing leans; the ring and wash carry the status.
    local lvl = Motion.level("tables")
    if lvl <= Motion.LOW then return 0 end
    local sign = ((tbl._id or 0) % 2 == 0) and 1 or -1
    local angle = 0

    local e, def
    -- A table doesn't lean until it has actually been hit.
    if tbl.statuses and (tbl.impact_wait or 0) <= 0 then
        e, def = strongestWith(tbl, "rotate")
    end
    if e and def and (def.rotate or 0) > 0 then
        angle = math.min(TILT_MAX_RAD, (e.magnitude or 0) * def.rotate) * sign
    else
        -- Shaking it off: the lean doesn't vanish between frames, it rocks
        -- through level a couple of times and settles. Amplitude decays
        -- with untilt_t (ticked in Table:update), and the oscillation runs
        -- on the same value so the rocking slows as it dies.
        local u = tbl.untilt_t or 0
        if u > 0 then
            local lean = math.min(TILT_MAX_RAD, (tbl.untilt_mag or 0) * UNTILT_ROTATE)
            angle = lean * sign * u * math.cos((1 - u) * math.pi * UNTILT_ROCKS)
        end
    end

    -- Taking a hit rocks the panel ON TOP of whatever it was already
    -- doing, so a table that gets shoved AND tilted does both. Direction
    -- follows the blow: struck from the left, it rocks clockwise.
    local p = Pop.progress(TableModel.rollingKey(tbl, "tbl_bump"), BUMP_DURATION)
    if p > 0 and not tbl.bump_out and not tbl.bump_slam then
        local lean_dir = (tbl.bump_dx or 0)
        if lean_dir == 0 then lean_dir = (tbl.bump_dy or 0) end
        if lean_dir ~= 0 then
            angle = angle + BUMP_ROCK_RAD * (lean_dir > 0 and 1 or -1)
                            * p * math.cos((1 - p) * math.pi * BUMP_ROCKS)
        end
    end
    if lvl == Motion.MEDIUM then angle = angle * 0.5 end
    return angle
end

-- The shove. A table that just affected a neighbour lunges at it and
-- returns; a table that just got affected is knocked away and settles
-- back. A table that hit everything around it at once swells instead of
-- picking a direction.
--
-- The envelope is a services/Pop entry, not a field on the table: Pop is
-- the shared-clock one-shot this game already uses for exactly this shape
-- (and that TablePanel already draws stat bumps with). So there is no new
-- timer to declare, decay, or reset.
--   returns dx, dy, scale
function Effects.bumpOffset(tbl)
    local id = tbl._id or 0
    local dx, dy, scale = 0, 0, 1

    local sx, sy = 1, 1
    local lift01 = 0
    local dur = tbl.bump_slam and (SLAM.duration or 1.5) or BUMP_DURATION
    local p = Pop.progress(TableModel.rollingKey(tbl, "tbl_bump"), dur)
    -- Motion: Low and below nothing is displaced (TablePanel flashes the
    -- border instead); High and below the shover doesn't lunge.
    local lvl = Motion.level("tables")
    if lvl <= Motion.LOW then return 0, 0, 1, 1, 0 end
    if p > 0 and tbl.bump_out and lvl <= Motion.HIGH then p = 0 end
    if p > 0 then
        -- Pop eases (p = (1 - t/dur)^2), which is right for a scale pop
        -- but wrong for a multi-phase motion: `1 - p` runs well ahead of
        -- the clock, so a phase boundary written as "60% through" would
        -- actually arrive at 37% of the wall time. Undo the ease so the
        -- phases below are real seconds — and so the frame the fist lands
        -- is genuinely `duration * rise`, which is what the controller
        -- waits before releasing the shockwave.
        local e = 1 - math.sqrt(p)   -- LINEAR elapsed fraction, 0 -> 1

        if tbl.bump_slam then
            -- THE FIST, in full, built on the same arc the gauntlet's
            -- numbers fly on (views/ShoveView:_drawNumberFlight): the
            -- thing rises AND grows toward the camera, its shadow stays
            -- down on the board so the height reads, and it lands with a
            -- pop. Same idea, far more gusto.
            --
            -- Rear back and swell → drive down hard → bounce out. The
            -- wind-up is the whole reason this reads: an impact with no
            -- anticipation is a twitch the eye skips over.
            local up, down
            if e < SLAM_RISE then
                local k = e / SLAM_RISE
                up, down = math.sin(k * math.pi * 0.5), 0     -- rear back
            elseif e < SLAM_RISE + SLAM_STRIKE then
                local k = (e - SLAM_RISE) / SLAM_STRIKE
                up, down = 1 - k, k                            -- drive down
            else
                local k = (e - SLAM_RISE - SLAM_STRIKE)
                          / math.max(1e-6, 1 - SLAM_RISE - SLAM_STRIKE)
                up   = 0
                down = (1 - k) * math.cos(k * math.pi * SLAM_BOUNCES)  -- settle
            end
            dy = (down * BUMP_SLAM_PX) - (up * SLAM_RISE_PX)
            dx = 0
            lift01 = up
            -- Grow toward the camera as it rears back; squash flat on
            -- contact. The two never overlap, so they compose cleanly.
            local swell  = up * (SLAM_LIFT - 1)
            local squash = math.max(0, down) * SLAM_SQUASH
            sx = 1 + swell + squash
            sy = 1 + swell - squash
        elseif tbl.bump_out then
            -- THE BUMP: draw back away from the target, thrust across
            -- fast, recover. Same three beats as the fist — a shove with
            -- no draw-back reads as a twitch, which is how the fist
            -- looked before it got its wind-up.
            local out
            if e < SHOVE_RISE then
                local k = e / SHOVE_RISE
                out = -SHOVE_PULL_PX * math.sin(k * math.pi * 0.5)
                lift01 = math.sin(k * math.pi * 0.5)
            elseif e < SHOVE_RISE + SHOVE_STRIKE then
                local k = (e - SHOVE_RISE) / SHOVE_STRIKE
                out = -SHOVE_PULL_PX + (BUMP_LUNGE_PX + SHOVE_PULL_PX) * k
            else
                local k = (e - SHOVE_RISE - SHOVE_STRIKE)
                          / math.max(1e-6, 1 - SHOVE_RISE - SHOVE_STRIKE)
                out = BUMP_LUNGE_PX * (1 - k) * math.cos(k * math.pi * SHOVE_BOUNCES)
            end
            dx = (tbl.bump_dx or 0) * out
            dy = (tbl.bump_dy or 0) * out
            -- Rears up a little as it draws back, like the fist does.
            local swell = lift01 * (SHOVE_LIFT - 1)
            sx, sy = 1 + swell, 1 + swell
        else
            -- Thrown by a blow: hardest at the moment of contact.
            dx = (tbl.bump_dx or 0) * p * BUMP_MAX_PX
            dy = (tbl.bump_dy or 0) * p * BUMP_MAX_PX
        end
    end

    local g = Pop.progress(TableModel.rollingKey(tbl, "tbl_shove"), BUMP_DURATION)
    if g > 0 then
        local s = Pop.scale(math.sin(math.pi * (1 - g)), 1, BUMP_GROW)
        sx, sy = sx * s, sy * s
    end
    if lvl == Motion.MEDIUM then
        dx, dy = dx * 0.5, dy * 0.5
        sx, sy = 1 + (sx - 1) * 0.5, 1 + (sy - 1) * 0.5
        lift01 = lift01 * 0.5
    end
    return dx, dy, sx, sy, lift01
end

-- Low motion's stand-in for a punch: is this table being hit right now?
-- TablePanel paints the status colour on the frame while it is.
function Effects.punchFlash(tbl)
    if Motion.level("tables") > Motion.LOW then return 0 end
    local dur = tbl.bump_slam and (SLAM.duration or 1.5) or BUMP_DURATION
    return Pop.progress(TableModel.rollingKey(tbl, "tbl_bump"), dur)
end

-- Rotate everything drawn between push and pop about a point. The held
-- drag panel does the same thing (views/TablePanelDrag), so it lives here
-- and both call it.
function Effects.pushRotated(cx, cy, angle)
    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.rotate(angle or 0)
    love.graphics.translate(-cx, -cy)
end

function Effects.popRotated()
    love.graphics.pop()
end

-- Move a point by the same rotation, so a rotated panel's click targets
-- follow its buttons instead of staying where the panel used to be.
function Effects.rotatePoint(px, py, cx, cy, angle)
    if not angle or angle == 0 then return px, py end
    local s, c = math.sin(angle), math.cos(angle)
    local ox, oy = px - cx, py - cy
    return cx + ox * c - oy * s, cy + ox * s + oy * c
end

-- Win/loss flash over the felt. Fires only on `large` and `stack`
-- resolutions (controllers/GrindController sets vignette_alpha from
-- data/feedback_intensity) and decays in Table:update.
--
-- Two layers. The flat wash is what makes a big result unmissable when you're
-- watching six other panels; the mask on top of it concentrates the colour at
-- the edges, so it reads as light coming in over the rails instead of the felt
-- swapping colour. The mask is the same one views/FeltDecor paints the resting
-- vignette with, so this costs one extra batched draw and no new texture.
function Effects.drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)
    local a = tbl.vignette_alpha or 0
    if a <= 0.001 or not tbl.vignette_kind then return end
    -- Low motion: still, at half strength, for as long as it would run.
    if Motion.level("tables") <= Motion.LOW then a = 0.5 end
    local color = (tbl.vignette_kind == "good") and Theme.sem.won
                                                  or Theme.sem.lost
    local cfg = FeltStyle.vignette
    Theme.setColor(color, a * VIGNETTE_MAX_ALPHA * (cfg.flash_flat or 1))
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h,
                            Theme.space.radius)
    FeltDecor.drawMask(felt_x, felt_y, felt_w, felt_h, color,
                       a * VIGNETTE_MAX_ALPHA * (cfg.flash_mask or 0))
end

-- ── The heater's fire ─────────────────────────────────────────────────
-- Heat looks like heat: animated flame tongues along the felt's bottom
-- edge (shaders/flame.frag), on any status kind flagged `flame = true`
-- in data/statuses.lua. Absent, not shrunk, below gates.fire_min_panel_w
-- — the ring still says "something is happening here" under that.
function Effects.drawStatusFire(tbl, x, y, w, h)
    if not tbl.statuses then return end
    -- Nothing shows while a blow is still in the air.
    if (tbl.impact_wait or 0) > 0 then return end
    local gates = StatusData.gates or {}
    if w < (gates.fire_min_panel_w or 0) then return end
    local e
    for _, s in ipairs(tbl.statuses) do
        local def = StatusData[s.kind]
        if def and def.flame then e = s; break end
    end
    if not e then return end
    -- Full blaze while the status runs; dies down over its last beat
    -- instead of vanishing between frames. Magnitude is inert on heaters
    -- (the status IS the interrupt), so remaining time is the only dial.
    local intensity = math.min(1, (e.t or 1) / 0.6)
    if intensity <= 0.01 then return end

    local fh = math.max(10, math.min(math.floor(h * 0.45), 96))
    local lvl = Motion.level("tables")
    if lvl <= Motion.LOW then
        -- Still embers: a warm band along the felt's bottom edge, no
        -- shader, no motion. Says "hot" without anything moving.
        local def = StatusData[e.kind]
        local color = tokenColor(def and def.glow_token) or Theme.fg.heading
        local bands = 4
        for i = 1, bands do
            local k  = i / bands
            local bh = math.floor(fh * (1 - (i - 1) / bands))
            Theme.setColor(color, 0.12 * k * intensity)
            love.graphics.rectangle("fill", x, y + h - bh, w, bh)
        end
        return
    end
    local sh = ShaderRegistry.get("flame")
    if not sh then return end
    local t  = (love.timer and love.timer.getTime() or 0)
    if lvl == Motion.MEDIUM then t = t * 0.5 end
    Theme.setColor(SHADER_PASS_COLOR, 1)
    Perf.count("shader_switch")
    love.graphics.setShader(sh)
    sh:send("u_time", t)
    sh:send("u_intensity", intensity)
    -- Per-panel phase: neighbouring fires must not march in step.
    sh:send("u_seed", ((tbl._id or 0) % 89) * 1.618)
    -- ~3px cells: chunky enough to read as the game's pixel art, fine
    -- enough that a tongue keeps a silhouette.
    sh:send("u_cells", { math.max(24, math.floor(w / 3)),
                         math.max(8,  math.floor(fh / 3)) })
    shaderRect(x, y + h - fh, w, fh)
    love.graphics.setShader()
end

-- ── Seat knockout flash ───────────────────────────────────────────────
-- The KO moment. A fold gets a whole card-muck animation; an elimination
-- used to be a passive alpha change on the next frame. This is its event:
-- the controller queues one intent per busted seat (GrindView drains it
-- into noteSeatKO), and while the flash runs the seat draws a red ring
-- with the finish tag stamping in over it (views/TablePanel's busted-seat
-- branch reads seatKOProgress).
--
-- Keyed by table id + script seat. Entries clean themselves up on read —
-- the busted seat queries its progress every frame it draws — so the only
-- way one lingers is a table closed mid-flash, which costs a number in a
-- table until the next KO there.
local KO_FLASH_S = 1.1
local seat_kos = {}

-- Two levels (table id -> seat -> t0), so a busted seat's per-frame query
-- indexes two tables instead of building a key string.
function Effects.noteSeatKO(tbl, seat)
    if not (tbl and seat) then return end
    local id = tbl._id or tbl
    local by_seat = seat_kos[id]
    if not by_seat then by_seat = {}; seat_kos[id] = by_seat end
    by_seat[seat] = love.timer.getTime()
end

-- 0..1 while the flash runs, nil before the KO and after it has played out.
function Effects.seatKOProgress(tbl, seat)
    local by_seat = seat_kos[tbl._id or tbl]
    local t0 = by_seat and by_seat[seat]
    if not t0 then return nil end
    local p = (love.timer.getTime() - t0) / KO_FLASH_S
    if p >= 1 then
        by_seat[seat] = nil
        return nil
    end
    return p
end

-- Is any seat of this table mid-flash (the panel cache's classifier)?
function Effects.hasSeatKO(tbl)
    local by_seat = seat_kos[tbl._id or tbl]
    if not by_seat then return false end
    return next(by_seat) ~= nil
end

-- The ring, over the seat's card region: bright at the hit, gone by the
-- end. Same always-legible treatment as drawStatusRing — a line survives
-- any panel size, so the KO moment never falls below a gate.
function Effects.drawSeatKOFlash(x, y, w, h, p)
    -- Low motion: a still ring for the flash's duration.
    if Motion.level("tables") <= Motion.LOW then p = 0 end
    local fade = 1 - p
    Theme.setColor(Theme.sem.lost, 0.85 * fade)
    love.graphics.setLineWidth(math.max(1, math.floor(3 * fade)))
    local grow = 3 * p
    love.graphics.rectangle("line", x - grow, y - grow,
                            w + grow * 2, h + grow * 2, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

return Effects
