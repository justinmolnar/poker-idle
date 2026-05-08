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

local Effects = {}

-- ── Tunables ─────────────────────────────────────────────────────────
local SHAKE_MAX_PX        = 8     -- amplitude at trauma=1; trauma² scaling
local VIGNETTE_MAX_ALPHA  = 0.65
local LIFT_MAX_PX         = 18    -- panel hovers up this many px during a hand
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
local GLOW_RECT_PAD       = 80              -- draw the glow rect this many
                                            -- px outside the panel on every
                                            -- side so the halo bleeds beyond
                                            -- panel edges instead of cutting
                                            -- off at the border.

-- ── Transforms ───────────────────────────────────────────────────────

function Effects.shakeOffset(tbl)
    local trauma = tbl.shake_trauma or 0
    if trauma <= 0 then return 0, 0 end
    local amp = SHAKE_MAX_PX * trauma * trauma
    return (love.math.random() * 2 - 1) * amp,
           (love.math.random() * 2 - 1) * amp
end

-- Vertical offset for the hover-lift. Returns Y delta in px — negative =
-- up, 0 = rest. The lift_t value lerps both directions in Table:update,
-- so a fresh hand smoothly raises the panel and a settled hand smoothly
-- lowers it. No separate slam impulse — the slam mechanic was creating
-- an overshoot that looked like a teleport on quick re-deals.
function Effects.liftSlamOffset(tbl)
    return (tbl.lift_t or 0) * -LIFT_MAX_PX
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
function Effects.drawHoverShadow(tbl, x, y, w, h)
    local lift = tbl.lift_t or 0
    local r = Theme.space.radius

    -- Three layers. Outermost is biggest + most transparent for a soft
    -- edge feel; innermost is densest. Stacked behind the panel.
    local layers = {
        { spread = 8 + lift * 6,  alpha = 0.10 + lift * 0.05 },
        { spread = 4 + lift * 4,  alpha = 0.18 + lift * 0.08 },
        { spread = 0,             alpha = 0.45 + lift * 0.10 },
    }

    for _, L in ipairs(layers) do
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

-- Border-pulse colored frame on top of the panel chrome. Drawn AFTER
-- the panel chrome (so it overlays the regular border) but BEFORE felt
-- content (so cards/chips render on top of the colored ring).
function Effects.drawBorderPulse(tbl, x, y, w, h)
    local t = tbl.border_pulse_t or 0
    if t <= 0.001 or not tbl.border_pulse_color then return end
    local color = (tbl.border_pulse_color == "good") and Theme.status.good
                                                       or Theme.status.error
    local line_w = math.max(1, math.floor(BORDER_PULSE_MAX_W * t + 0.5))
    Theme.setColor(color, t * BORDER_PULSE_ALPHA)
    love.graphics.setLineWidth(line_w)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

-- Radial-glow halo via shader. Rendered additively over the panel rect
-- after all other content. Falls back to plain rendering if the shader
-- failed to compile (graceful degradation — see ShaderRegistry).
function Effects.drawGlow(tbl, x, y, w, h)
    local t = tbl.glow_t or 0
    if t <= 0.001 then return end
    local sh = ShaderRegistry.get("radial_glow")
    if not sh then return end
    local gx = x - GLOW_RECT_PAD
    local gy = y - GLOW_RECT_PAD
    local gw = w + GLOW_RECT_PAD * 2
    local gh = h + GLOW_RECT_PAD * 2
    Theme.setColor(SHADER_PASS_COLOR, 1)
    love.graphics.setShader(sh)
    sh:send("u_color",     GLOW_COLOR)
    sh:send("u_intensity", t)
    love.graphics.setBlendMode("add", "alphamultiply")
    love.graphics.rectangle("fill", gx, gy, gw, gh)
    love.graphics.setBlendMode("alpha")
    love.graphics.setShader()
end

function Effects.drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)
    local a = tbl.vignette_alpha or 0
    if a <= 0.001 or not tbl.vignette_kind then return end
    local color = (tbl.vignette_kind == "good") and Theme.status.good
                                                  or Theme.status.error
    Theme.setColor(color, a * VIGNETTE_MAX_ALPHA)
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h,
                            Theme.space.radius)
end

return Effects
