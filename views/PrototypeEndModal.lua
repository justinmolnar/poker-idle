-- views/PrototypeEndModal.lua
--
-- End-of-prototype overlay. Shown when FEATURES.DEMO_CUT is on and the
-- player wins runout 1 then loses runout 2 — the natural cliffhanger
-- in the prototype build, before the gauntlet's full three-runout arc
-- becomes its own thing.
--
-- Two buttons: Continue Playing (loops the player back into the grind
-- with a fresh run) and Exit to Title (drops back to TitleState). The
-- host (ShoveState) reads :resolved() to decide which path to take.
--
-- Pure presentation — no mutation. Modal frame comes from
-- views/widgets/Modal.lua so the chrome stays consistent with
-- PrestigeModal / ConfirmDialog.

local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")

local PrototypeEndModal = {}
PrototypeEndModal.__index = PrototypeEndModal

local CARD_W_BASE = 520
local CARD_H_BASE = 320
local BTN_W_BASE  = 200
local BTN_H_BASE  = 44
local BTN_GAP     = 18

function PrototypeEndModal:new(game)
    local s = (game.ui_scale) or 1
    local card_w = math.floor(CARD_W_BASE * s)
    local card_h = math.floor(CARD_H_BASE * s)
    return setmetatable({
        game          = game,
        _resolved     = nil,    -- "continue" | "exit" | nil
        _continue_rect = nil,
        _exit_rect     = nil,
        _modal         = Modal:new{ title = "PROTOTYPE COMPLETE", w = card_w, h = card_h },
    }, PrototypeEndModal)
end

function PrototypeEndModal:resolved() return self._resolved end

function PrototypeEndModal:consumeKey(key)
    if self._resolved then return true end
    if key == "return" or key == "kpenter" or key == "space" then
        self._resolved = "continue"; return true
    end
    if key == "escape" then
        self._resolved = "exit"; return true
    end
    return true  -- swallow other keys while modal is up
end

function PrototypeEndModal:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end
    local function inside(rect)
        return rect and mx >= rect.x and mx < rect.x + rect.w
                    and my >= rect.y and my < rect.y + rect.h
    end
    if inside(self._continue_rect) then self._resolved = "continue"; return true end
    if inside(self._exit_rect)     then self._resolved = "exit";     return true end
    return true
end

function PrototypeEndModal:draw()
    local fonts = self.game.fonts
    local body  = self._modal:draw(fonts)
    local s     = (self.game.ui_scale) or 1

    -- Headline takeaway.
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf(
        "That's the end of the prototype.",
        body.x, body.y, body.w, "center")

    -- Body copy — neutral, doesn't mention runouts / gauntlet structure
    -- so first-time players don't get spoiled on what's still ahead.
    local copy_y = body.y + fonts.md:getHeight() + 18
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(
        "Thanks for playing!"
        .. "\n\nYou can keep grinding from here — the run resets and"
        .. " more is coming in future builds.",
        body.x, copy_y, body.w, "center")

    -- Buttons row.
    local btn_w = math.floor(BTN_W_BASE * s)
    local btn_h = math.floor(BTN_H_BASE * s)
    local btn_y = body.y + body.h - btn_h - 12
    local total_w = 2 * btn_w + BTN_GAP
    local btn_x = body.x + math.floor((body.w - total_w) / 2)

    self._continue_rect = { x = btn_x,                y = btn_y, w = btn_w, h = btn_h }
    self._exit_rect     = { x = btn_x + btn_w + BTN_GAP, y = btn_y, w = btn_w, h = btn_h }

    local mx, my = love.mouse.getPosition()
    local cont_hov = mx >= self._continue_rect.x and mx < self._continue_rect.x + btn_w
                     and my >= btn_y and my < btn_y + btn_h
    local exit_hov = mx >= self._exit_rect.x and mx < self._exit_rect.x + btn_w
                     and my >= btn_y and my < btn_y + btn_h

    LabelButton.draw{
        x = self._continue_rect.x, y = btn_y, w = btn_w, h = btn_h,
        text         = "Continue Playing",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = cont_hov,
        depth        = 3,
        fill_token   = cont_hov and Theme.status.good or Theme.bg.widget,
        border_token = Theme.status.good,
        text_token   = cont_hov and Theme.bg.window or Theme.status.good,
    }
    LabelButton.draw{
        x = self._exit_rect.x, y = btn_y, w = btn_w, h = btn_h,
        text         = "Exit to Title",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = exit_hov,
        depth        = 3,
    }

    self._modal:endDraw()
end

return PrototypeEndModal
