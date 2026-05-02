-- services/FloatingTextSystem.lua
--
-- Floating text popups ("+$2.40", "-$0.15", "WIN STREAK x3"). Owns the
-- list, update logic, and exposes it for rendering.
--
-- emit(text, x, y, opts) — opts is optional, all fields default to the
-- legacy behavior so old call sites work unchanged. New fields:
--
--   scale    — text size multiplier (1.0 default; jackpots use ~1.8)
--   color    — RGB override; nil → auto-detect from text prefix
--   color_token — string key (e.g. "amber", "violet") resolved through
--                 Theme tokens by the renderer; lower priority than `color`
--   font     — font key in game.fonts ("heading" default; "kpi" for big)
--   arc_x    — horizontal drift over lifetime in px (0 = straight up)
--   arc_y    — vertical drift over lifetime in px (negative = up;
--              defaults to Constants.FLOATING_TEXT.DRIFT_Y)
--   lifetime — seconds; defaults to Constants.FLOATING_TEXT.DURATION

local FloatingTextSystem = {}

local Constants = require("data.constants")

local _texts = {}

function FloatingTextSystem.emit(text, x, y, opts)
    opts = opts or {}
    if #_texts >= Constants.FLOATING_TEXT.MAX_ITEMS then
        table.remove(_texts, 1)
    end
    local lifetime = opts.lifetime or Constants.FLOATING_TEXT.DURATION
    table.insert(_texts, {
        text     = text,
        x        = x,
        y        = y,
        x0       = x,                                       -- spawn position for arc
        y0       = y,
        timer    = lifetime,
        lifetime = lifetime,
        alpha    = 1,
        scale       = opts.scale or 1.0,
        color       = opts.color,                           -- nil → auto / token
        color_token = opts.color_token,                     -- resolved at draw time
        font        = opts.font or "heading",
        arc_x       = opts.arc_x or 0,
        arc_y       = opts.arc_y or Constants.FLOATING_TEXT.DRIFT_Y,
    })
end

-- Hold-then-fade alpha curve: stay fully opaque for the first chunk of
-- the lifetime, fade only over the tail. So the player has time to
-- actually READ the text before it starts dissolving. With HOLD = 0.6:
-- 60% of lifetime is full alpha, 40% is the linear fade.
local ALPHA_HOLD = 0.6

function FloatingTextSystem.update(dt)
    for i = #_texts, 1, -1 do
        local t = _texts[i]
        t.timer = t.timer - dt
        local progress = 1 - (t.timer / t.lifetime)         -- 0 → 1 over lifetime
        t.x     = t.x0 + t.arc_x * progress
        t.y     = t.y0 + t.arc_y * progress
        if progress < ALPHA_HOLD then
            t.alpha = 1
        else
            t.alpha = (1 - progress) / (1 - ALPHA_HOLD)
        end
        if t.timer <= 0 then
            table.remove(_texts, i)
        end
    end
end

function FloatingTextSystem.getTexts()
    return _texts
end

function FloatingTextSystem.clear()
    _texts = {}
end

return FloatingTextSystem
