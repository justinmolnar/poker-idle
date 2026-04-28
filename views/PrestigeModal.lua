-- views/PrestigeModal.lua
--
-- Overlay that appears on the shove view after the gauntlet busts. Reports
-- the run's peak bankroll, the PP awarded, and prompts the player to press
-- SPACE to continue (which the ShoveState consumes by calling resetRun()
-- and switching back to grind).
--
-- Pure presentation — no mutation. Logic lives in ShoveState.

local Theme = require("views.Theme")

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
    }, PrestigeModal)
end

-- Returns true if the modal consumed the key (caller should run prestige).
function PrestigeModal:consumeKey(key)
    return key == "space"
end

function PrestigeModal:draw()
    local W, H   = love.graphics.getDimensions()
    local fonts  = self.game.fonts

    -- Backdrop dim. Reuses the debug HUD's translucent black token so
    -- there's no literal color in this file.
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Card.
    local card_x = math.floor((W - CARD_W) / 2)
    local card_y = math.floor((H - CARD_H) / 2)

    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", card_x, card_y, CARD_W, CARD_H, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", card_x, card_y, CARD_W, CARD_H, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- Title.
    love.graphics.setFont(fonts.kpi)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf("RUN ENDED", card_x, card_y + 20, CARD_W, "center")

    -- Sub: which runout busted.
    love.graphics.setFont(fonts.ui)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("Busted on runout " .. tostring(self.busted_at),
        card_x, card_y + 64, CARD_W, "center")

    -- Peak bankroll.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("PEAK BANKROLL", card_x, card_y + 110, CARD_W, "center")
    love.graphics.setFont(fonts.kpi)
    Theme.setColor(Theme.fg.primary)
    love.graphics.printf(string.format("$%.2f", self.peak_bankroll),
        card_x, card_y + 130, CARD_W, "center")

    -- PP banked this run (accent color so the takeaway lands). The PP was
    -- earned per-stake-win during play; the modal celebrates the cumulative.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("PP BANKED THIS RUN", card_x, card_y + 180, CARD_W, "center")
    love.graphics.setFont(fonts.kpi)
    Theme.setColor(Theme.status.good)
    love.graphics.printf(tostring(self.pp_banked) .. " PP",
        card_x, card_y + 200, CARD_W, "center")

    -- Prompt.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("[ SPACE to continue ]",
        card_x, card_y + CARD_H - 30, CARD_W, "center")
end

return PrestigeModal
