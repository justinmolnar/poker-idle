-- views/PrestigeModal.lua
--
-- Overlay that appears on the shove view after the gauntlet busts. Reports
-- the run's peak bankroll, the PP awarded, and prompts the player to press
-- SPACE to continue (which the ShoveState consumes by calling resetRun()
-- and switching back to grind).
--
-- Pure presentation — no mutation. Logic lives in ShoveState. Modal frame
-- comes from views/widgets/Modal.lua so the chrome / dim backdrop stay
-- consistent with the other modal-class overlays.

local Theme = require("views.Theme")
local Modal = require("views.widgets.Modal")

local PrestigeModal = {}
PrestigeModal.__index = PrestigeModal

local CARD_W = 480
local CARD_H = 300

function PrestigeModal:new(game, peak_bankroll, pp_banked, busted_at)
    return setmetatable({
        game          = game,
        peak_bankroll = peak_bankroll or 0,
        pp_banked     = pp_banked or 0,   -- PP earned this run (already in state.pp)
        busted_at     = busted_at or 0,
        _modal        = Modal:new{ title = "RUN ENDED", w = CARD_W, h = CARD_H },
    }, PrestigeModal)
end

-- Returns true if the modal consumed the key (caller should run prestige).
function PrestigeModal:consumeKey(key)
    return key == "space"
end

function PrestigeModal:draw()
    local fonts = self.game.fonts
    local body  = self._modal:draw(fonts)

    -- Sub: which runout busted.
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("Busted on runout " .. tostring(self.busted_at),
        body.x, body.y, body.w, "center")

    -- Peak bankroll.
    local row1_y = body.y + fonts.md:getHeight() + 16
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("PEAK BANKROLL", body.x, row1_y, body.w, "center")
    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.primary)
    love.graphics.printf(string.format("$%.2f", self.peak_bankroll),
        body.x, row1_y + fonts.sm:getHeight() + 4, body.w, "center")

    -- PP banked this run (accent color so the takeaway lands).
    local row2_y = row1_y + fonts.sm:getHeight() + fonts.lg:getHeight() + 16
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("PP BANKED THIS RUN", body.x, row2_y, body.w, "center")
    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.status.good)
    love.graphics.printf(tostring(self.pp_banked) .. " PP",
        body.x, row2_y + fonts.sm:getHeight() + 4, body.w, "center")

    -- Prompt at the bottom of the body.
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("[ SPACE to continue ]",
        body.x, body.y + body.h - fonts.sm:getHeight() - 6, body.w, "center")

    self._modal:endDraw()
end

return PrestigeModal
