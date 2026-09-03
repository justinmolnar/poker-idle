-- views/widgets/ConfirmDialog.lua
--
-- Small centered prompt + Cancel/Confirm buttons. Owns its own input
-- (mouse + key) so callers just instantiate, draw, and forward. ESC
-- = cancel, ENTER/SPACE = confirm.
--
-- on_confirm and on_cancel are optional callbacks; the host is also
-- expected to inspect :resolved() to decide when to drop the dialog.
--
-- Engine-agnostic — knows about Theme tokens, fonts, and LabelButton.

local Theme       = require("views.Theme")
local LabelButton = require("views.widgets.LabelButton")

local ConfirmDialog = {}
ConfirmDialog.__index = ConfirmDialog

-- Base sizes are 1× design-space; setScale(s) multiplies them in
-- place so the dialog grows with the window. main.lua wires the
-- call on boot and on resize from game.ui_scale.
local BOX_W_BASE      = 360
local BOX_H_BASE      = 160
local BTN_W_BASE      = 140
local BTN_H_BASE      = 38
local SIDE_PAD_BASE   = 24
local BTN_BOTTOM_BASE = 16
local TITLE_TOP_BASE  = 28

local BOX_W       = BOX_W_BASE
local BOX_H       = BOX_H_BASE
local BTN_W       = BTN_W_BASE
local BTN_H       = BTN_H_BASE
local SIDE_PAD    = SIDE_PAD_BASE
local BTN_BOTTOM  = BTN_BOTTOM_BASE
local TITLE_TOP   = TITLE_TOP_BASE

function ConfirmDialog.setScale(s)
    s = s or 1
    BOX_W      = math.floor(BOX_W_BASE      * s)
    BOX_H      = math.floor(BOX_H_BASE      * s)
    BTN_W      = math.floor(BTN_W_BASE      * s)
    BTN_H      = math.floor(BTN_H_BASE      * s)
    SIDE_PAD   = math.floor(SIDE_PAD_BASE   * s)
    BTN_BOTTOM = math.floor(BTN_BOTTOM_BASE * s)
    TITLE_TOP  = math.floor(TITLE_TOP_BASE  * s)
end

-- opts:
--   prompt          (string, required)
--   on_confirm      (function, optional)
--   on_cancel       (function, optional)
--   danger          (bool, default false) — if true, Confirm is red
--   confirm_label   (default "Confirm")
--   cancel_label    (default "Cancel")
function ConfirmDialog:new(opts)
    return setmetatable({
        prompt        = opts.prompt or "",
        on_confirm    = opts.on_confirm,
        on_cancel     = opts.on_cancel,
        danger        = opts.danger == true,
        confirm_label = opts.confirm_label or "Confirm",
        cancel_label  = opts.cancel_label  or "Cancel",
        _resolved     = nil,    -- "confirm" | "cancel" | nil
        _cancel_rect  = nil,
        _confirm_rect = nil,
    }, ConfirmDialog)
end

function ConfirmDialog:resolved() return self._resolved end

local function fire(self, kind)
    self._resolved = kind
    if kind == "confirm" and self.on_confirm then self.on_confirm() end
    if kind == "cancel"  and self.on_cancel  then self.on_cancel()  end
end

function ConfirmDialog:consumeKey(key)
    if self._resolved then return true end
    if key == "escape" then fire(self, "cancel"); return true end
    if key == "return" or key == "kpenter" or key == "space" then
        fire(self, "confirm"); return true
    end
    -- Swallow any other key while the dialog is up so it doesn't fall
    -- through to the host state.
    return true
end

function ConfirmDialog:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end
    local function inside(rect)
        return rect and mx >= rect.x and mx < rect.x + rect.w
                    and my >= rect.y and my < rect.y + rect.h
    end
    if inside(self._cancel_rect)  then fire(self, "cancel");  return true end
    if inside(self._confirm_rect) then fire(self, "confirm"); return true end
    return true  -- click outside the buttons swallowed; user must pick one
end

function ConfirmDialog:draw(fonts)
    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window, 0.85)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local bx = math.floor((W - BOX_W) / 2)
    local by = math.floor((H - BOX_H) / 2)

    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", bx, by, BOX_W, BOX_H, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", bx, by, BOX_W, BOX_H, Theme.space.radius)

    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.md)
    love.graphics.printf(self.prompt, bx, by + TITLE_TOP, BOX_W, "center")

    local btn_y     = by + BOX_H - BTN_H - BTN_BOTTOM
    local cancel_x  = bx + SIDE_PAD
    local confirm_x = bx + BOX_W - BTN_W - SIDE_PAD

    local mx, my = love.mouse.getPosition()
    local HoverSvc = require("services.HoverService")
    local cancel_hov = HoverSvc.rest("button", "confirm_dialog:cancel",
                           mx >= cancel_x and mx < cancel_x + BTN_W
                           and my >= btn_y and my < btn_y + BTN_H, 0)
    local confirm_hov = HoverSvc.rest("button", "confirm_dialog:confirm",
                            mx >= confirm_x and mx < confirm_x + BTN_W
                            and my >= btn_y and my < btn_y + BTN_H, 0)

    LabelButton.draw{
        x = cancel_x, y = btn_y, w = BTN_W, h = BTN_H,
        text         = self.cancel_label,
        fonts        = fonts,
        font         = fonts.md,
        hovered      = cancel_hov,
        depth        = 3,
    }

    if self.danger then
        LabelButton.draw{
            x = confirm_x, y = btn_y, w = BTN_W, h = BTN_H,
            text         = self.confirm_label,
            fonts        = fonts,
            font         = fonts.md,
            hovered      = confirm_hov,
            depth        = 3,
            fill_token   = confirm_hov and Theme.status.error or Theme.bg.widget,
            border_token = Theme.status.error,
            text_token   = confirm_hov and Theme.bg.window or Theme.status.error,
        }
    else
        LabelButton.draw{
            x = confirm_x, y = btn_y, w = BTN_W, h = BTN_H,
            text         = self.confirm_label,
            fonts        = fonts,
            font         = fonts.md,
            hovered      = confirm_hov,
            depth        = 3,
            fill_token   = confirm_hov and Theme.status.good or Theme.bg.widget,
            border_token = Theme.status.good,
            text_token   = confirm_hov and Theme.bg.window or Theme.status.good,
        }
    end

    self._cancel_rect  = { x = cancel_x,  y = btn_y, w = BTN_W, h = BTN_H }
    self._confirm_rect = { x = confirm_x, y = btn_y, w = BTN_W, h = BTN_H }
end

return ConfirmDialog
