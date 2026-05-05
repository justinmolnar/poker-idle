-- views/PrestigeModal.lua
--
-- Overlay that appears on the shove view after the gauntlet busts.
-- Tells the player they lost the all-in and reports the PP they
-- banked this run. A Continue button advances the post-bust flow
-- (host calls _advanceToCatalog or _resolvePrototypeEnd as needed).
--
-- Deliberately neutral about the gauntlet's runout structure — does
-- NOT say "busted on runout 1 of 3" or similar. First-time players
-- shouldn't be spoiled on R2/R3 mechanics from the bust screen.
--
-- Pure presentation — no mutation. Logic lives in ShoveState. Modal
-- frame comes from views/widgets/Modal.lua.

local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")

local PrestigeModal = {}
PrestigeModal.__index = PrestigeModal

local CARD_W_BASE = 480
local CARD_H_BASE = 320
local BTN_W_BASE  = 200
local BTN_H_BASE  = 44

function PrestigeModal:new(game, pp_banked, _busted_at)
    local s = (game.ui_scale) or 1
    local card_w = math.floor(CARD_W_BASE * s)
    local card_h = math.floor(CARD_H_BASE * s)
    return setmetatable({
        game          = game,
        pp_banked     = pp_banked or 0,   -- PP earned this run (already in state.pp)
        _resolved     = false,
        _btn_rect     = nil,
        _modal        = Modal:new{ title = "BUSTED", w = card_w, h = card_h },
    }, PrestigeModal)
end

function PrestigeModal:resolved() return self._resolved end

-- Back-compat for non-prototype mode where SPACE still advances.
function PrestigeModal:consumeKey(key)
    if key == "space" or key == "return" or key == "kpenter" then
        self._resolved = true
        return true
    end
    return false
end

function PrestigeModal:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end
    local r = self._btn_rect
    if r and mx >= r.x and mx < r.x + r.w
       and my >= r.y and my < r.y + r.h then
        self._resolved = true
    end
    return true
end

function PrestigeModal:draw()
    local fonts = self.game.fonts
    local body  = self._modal:draw(fonts)
    local s     = (self.game.ui_scale) or 1

    -- Bust copy — acknowledges the all-in loss but doesn't expose the
    -- runout structure (no "R1 of 3", no mention of the dealer cheats
    -- coming on subsequent runouts).
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("You busted on the all-in.",
        body.x, body.y, body.w, "center")

    -- PP banked this run (accent color so the takeaway lands).
    local row_y = body.y + fonts.md:getHeight() + 24
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("PP BANKED THIS RUN", body.x, row_y, body.w, "center")
    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.status.good)
    love.graphics.printf(tostring(self.pp_banked) .. " PP",
        body.x, row_y + fonts.sm:getHeight() + 4, body.w, "center")

    -- Continue button at the bottom.
    local btn_w = math.floor(BTN_W_BASE * s)
    local btn_h = math.floor(BTN_H_BASE * s)
    local btn_x = body.x + math.floor((body.w - btn_w) / 2)
    local btn_y = body.y + body.h - btn_h - 12
    self._btn_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }

    local mx, my = love.mouse.getPosition()
    local hov = mx >= btn_x and mx < btn_x + btn_w
                and my >= btn_y and my < btn_y + btn_h
    LabelButton.draw{
        x = btn_x, y = btn_y, w = btn_w, h = btn_h,
        text         = "Continue",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = hov,
        depth        = 3,
        fill_token   = hov and Theme.status.good or Theme.bg.widget,
        border_token = Theme.status.good,
        text_token   = hov and Theme.bg.window or Theme.status.good,
    }

    self._modal:endDraw()
end

return PrestigeModal
