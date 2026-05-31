-- views/AwardGlow.lua
--
-- The "chip acquired" gold pulse — one implementation so the bounty-bank
-- fanfare looks identical wherever it lands. Driven by a dedicated ClickFlash
-- namespace keyed by element id: GrindView fires it on the bank transition;
-- the renderers (ComponentRenderer add-table buttons, the game-type tab strip)
-- draw it over their rect. Fades like a press flash (~0.5 s).

local Theme      = require("views.Theme")
local ClickFlash = require("services.ClickFlash")

local AwardGlow = {}

local NS        = "chip_award"
local INTENSITY = 1.3   -- > 1 so the pulse holds briefly before fading

-- Fire the pulse on `id` (a button / tab id the renderers also draw under).
function AwardGlow.flash(id)
    if id then ClickFlash.flash(NS, id, INTENSITY) end
end

-- Draw the gold pulse over (x, y, w, h) if `id` is currently flashing.
function AwardGlow.draw(id, x, y, w, h)
    local a = id and ClickFlash.alpha(NS, id) or 0
    if a <= 0 then return end
    local gold = Theme.currency and Theme.currency.chip
    if not gold then return end
    Theme.setColor(gold, a * 0.18)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(gold, math.min(1, a))
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

return AwardGlow
