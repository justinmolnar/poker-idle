-- views/HintMarks.lua
--
-- The pulsing highlight around whatever the House is pointing at. Shared
-- by the hint bubble (views/HintView) and the story band (views/StoryView):
-- a popup and a beat mark a widget the same way, because it is the same
-- finger.
--
-- Anchors are frame-stamped by services/AnchorRegistry; a mark exists only
-- while its widget drew this frame or the one before.

local Theme   = require("views.Theme")
local Anchors = require("services.AnchorRegistry")

local Motion  = require("services.Motion")
local HintMarks = {}

function HintMarks.freshAnchor(name)
    return name and Anchors.age(name) <= 1 and Anchors.get(name) or nil
end

-- A name or a list of names → list of marks {x, y, w, h, is_rect}; empty
-- when none of the targets are on screen.
function HintMarks.fresh(names)
    if type(names) ~= "table" then names = { names } end
    local marks = {}
    for _, name in ipairs(names) do
        local a = HintMarks.freshAnchor(name)
        if a then
            local m = { x = a[1], y = a[2], w = a[3], h = a[4],
                        is_rect = a[3] ~= nil and a[4] ~= nil }
            if not m.is_rect then m.w, m.h = 0, 0 end
            marks[#marks + 1] = m
        end
    end
    return marks
end

-- Pulsing double ring around each mark.
function HintMarks.draw(game, marks)
    local s  = game.ui_scale or 1
    local fl = math.floor
    -- Below High the mark holds still: a steady outline, no breathing.
    local t   = Motion.time("text", love.timer.getTime())
    local pad = fl(4 * s) + fl(2 * math.sin(t * 4) + 2)
    local pulse = Motion.at("text", Motion.HIGH) and (0.55 + 0.35 * math.sin(t * 4)) or 0.8
    Theme.setColor(Theme.status.warn, pulse)
    for _, m in ipairs(marks) do
        if m.is_rect then
            local r = fl(4 * s)
            love.graphics.rectangle("line", m.x - pad, m.y - pad,
                m.w + pad * 2, m.h + pad * 2, r)
            love.graphics.rectangle("line", m.x - pad - 1, m.y - pad - 1,
                m.w + pad * 2 + 2, m.h + pad * 2 + 2, r)
        else
            love.graphics.circle("line", m.x, m.y, fl(18 * s) + pad)
            love.graphics.circle("line", m.x, m.y, fl(18 * s) + pad + 1)
        end
    end
end

return HintMarks
