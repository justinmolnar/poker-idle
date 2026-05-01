-- services/FloatingTextSystem.lua
-- Self-contained system for floating text popups (e.g. "+$500", "-3").
-- Owns the list, update logic, and exposes it for rendering.

local FloatingTextSystem = {}

local Constants = require("data.constants")

local _texts = {}

function FloatingTextSystem.emit(text, x, y)
    if #_texts >= Constants.FLOATING_TEXT.MAX_ITEMS then
        table.remove(_texts, 1)
    end
    table.insert(_texts, {
        text  = text,
        x     = x,
        y     = y,
        timer = Constants.FLOATING_TEXT.DURATION,
        alpha = 1,
    })
end

function FloatingTextSystem.update(dt)
    local lifespan = Constants.FLOATING_TEXT.DURATION
    local drift_per_sec = Constants.FLOATING_TEXT.DRIFT_Y / lifespan
    for i = #_texts, 1, -1 do
        local t = _texts[i]
        t.y     = t.y + drift_per_sec * dt
        t.timer = t.timer - dt
        t.alpha = t.timer / lifespan
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
