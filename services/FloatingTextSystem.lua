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
        table       = opts.table,
        -- Size-clamp only: the renderer fits the text inside this table's
        -- panel, WITHOUT the `table` field's kill-on-next-deal lifecycle.
        -- For floats that should outlive the hand (tournament banners).
        fit_table   = opts.fit_table,
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
        local tbl = t.table   -- nil for non-resolution floaters

        -- Track whether the floater has ever seen its table reach idle.
        -- The floater spawns during "settling"; _finalizeHand sets the
        -- table to "idle" in the same frame or the next.  We only kill
        -- the floater once it has witnessed idle AND the table then
        -- leaves idle again (a new deal started).
        if tbl and tbl.state == "idle" then
            t.saw_idle = true
        end

        if tbl and t.saw_idle and tbl.state ~= "idle" then
            -- Table was idle (floater was resting), now a new hand
            -- started → remove immediately.
            table.remove(_texts, i)
        else
            t.timer = t.timer - dt
            local progress = 1 - (t.timer / t.lifetime)      -- 0 → 1

            if tbl then
            --     -- Table-attached: NO fade at all — stays fully opaque
            --     -- while it rises, then freezes at its final position.
            --     if tbl.state == "idle" and progress >= 1.0 then
            --         -- Freeze: clamp progress, hold timer alive.
            --         progress = 1.0
            --         t.timer = 0.001
            --         t.has_persisted = true
            --     end
            --     t.alpha = 1.0
            -- else
                -- Normal floater: hold-then-fade curve.
                if progress < ALPHA_HOLD then
                    t.alpha = 1
                else
                    t.alpha = (1 - progress) / (1 - ALPHA_HOLD)
                end
            end

            t.x = t.x0 + t.arc_x * math.min(1.0, progress)
            t.y = t.y0 + t.arc_y * math.min(1.0, progress)

            -- Non-persisted texts expire normally when timer hits 0.
            if t.timer <= 0 and not t.has_persisted then
                table.remove(_texts, i)
            end
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
