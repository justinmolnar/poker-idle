-- states/TitleState.lua
--
-- Boot-screen state shown unconditionally on launch. Four buttons
-- stacked in the center of the window:
--   • Start       — fresh game (confirms first if a save exists)
--   • Load Save   — switches to grind with whatever was loaded at boot
--   • Delete Save — confirms, then clears the meta + run save slots
--   • Exit        — confirms, then love.event.quit()
--
-- Reuses ConfirmDialog for the destructive flows so the chrome stays
-- consistent with the in-game settings modal. State holds nothing
-- beyond the active confirm dialog (if any) and stores the menu
-- button rects for hit-testing.

local Theme         = require("views.Theme")
local LabelButton   = require("views.widgets.LabelButton")
local ConfirmDialog = require("views.widgets.ConfirmDialog")
local Constants     = require("data.constants")

local TitleState = {}
TitleState.__index = TitleState

local BTN_W_BASE   = 280
local BTN_H_BASE   = 56
local BTN_GAP_BASE = 14

function TitleState:new(game)
    return setmetatable({
        game     = game,
        _confirm = nil,
        _btn_rects = {},
    }, TitleState)
end

function TitleState:enter()
    Theme.setActive("room")
end

function TitleState:exit() end

function TitleState:update(_) end

local function hasSave()
    return love.filesystem.getInfo(Constants.SAVE.META_FILE) ~= nil
        or love.filesystem.getInfo(Constants.SAVE.RUN_FILE)  ~= nil
end

function TitleState:_buttons()
    -- Order matters: drawn top-to-bottom, hit-tested same.
    local has = hasSave()
    return {
        { id = "start",   label = "Start",       enabled = true },
        { id = "load",    label = "Load Save",   enabled = has  },
        { id = "delete",  label = "Delete Save", enabled = has  },
        { id = "exit",    label = "Exit",        enabled = true },
    }
end

function TitleState:_buttonRects()
    local s = (self.game and self.game.ui_scale) or 1
    local btn_w = math.floor(BTN_W_BASE   * s)
    local btn_h = math.floor(BTN_H_BASE   * s)
    local gap   = math.floor(BTN_GAP_BASE * s)

    local W, H  = love.graphics.getDimensions()
    local btns  = self:_buttons()
    local n     = #btns
    local total = n * btn_h + (n - 1) * gap
    local start_y = math.floor((H - total) / 2 + total * 0.05)
    local x = math.floor((W - btn_w) / 2)

    local rects = {}
    for i, b in ipairs(btns) do
        rects[i] = {
            id      = b.id,
            label   = b.label,
            enabled = b.enabled,
            x = x, y = start_y + (i - 1) * (btn_h + gap),
            w = btn_w, h = btn_h,
        }
    end
    return rects
end

function TitleState:draw()
    local W, H  = love.graphics.getDimensions()
    local fonts = self.game.fonts

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title.
    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf("POKER IDLE", 0, math.floor(H * 0.18), W, "center")

    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("prototype build", 0,
        math.floor(H * 0.18) + fonts.lg:getHeight() + 8, W, "center")

    -- Buttons.
    self._btn_rects = self:_buttonRects()
    local mx, my = love.mouse.getPosition()
    for _, r in ipairs(self._btn_rects) do
        local hov = r.enabled
                    and mx >= r.x and mx < r.x + r.w
                    and my >= r.y and my < r.y + r.h
        LabelButton.draw{
            x = r.x, y = r.y, w = r.w, h = r.h,
            text     = r.label,
            fonts    = fonts,
            font     = fonts.md,
            hovered  = hov,
            disabled = not r.enabled,
            depth    = 4,
        }
    end

    if self._confirm then
        self._confirm:draw(fonts)
    end
end

-- Title-screen button handlers. Adding a new menu button = one entry
-- here + one entry in the button list rendered in :draw.
local BUTTON_HANDLERS = {
    start = function(self)
        if hasSave() then
            self._confirm = ConfirmDialog:new{
                prompt        = "Start a new game? Existing save will be erased.",
                danger        = true,
                confirm_label = "Start Over",
                on_confirm    = function() self:_doStart() end,
            }
        else
            self:_doStart()
        end
    end,
    load = function(self) self.game.state_machine:switch("grind") end,
    delete = function(self)
        self._confirm = ConfirmDialog:new{
            prompt        = "Delete your save? This cannot be undone.",
            danger        = true,
            confirm_label = "Delete",
            on_confirm    = function() self:_doDelete() end,
        }
    end,
    exit = function(self)
        self._confirm = ConfirmDialog:new{
            prompt        = "Quit the game?",
            danger        = true,
            confirm_label = "Quit",
            on_confirm    = function() love.event.quit() end,
        }
    end,
}

function TitleState:_handleButton(id)
    local handler = BUTTON_HANDLERS[id]
    if handler then handler(self) end
end

function TitleState:_doStart()
    -- Fresh game: wipe disk + in-memory state, then drop into grind.
    self.game.save_service:clearAll()
    self.game.state:wipeAll()
    self.game.state_machine:switch("grind")
end

function TitleState:_doDelete()
    self.game.save_service:clearAll()
    self.game.state:wipeAll()
    -- Stay on title; Load Save / Delete Save will now be greyed.
end

function TitleState:mousepressed(x, y, button)
    if button ~= 1 then return end

    if self._confirm then
        self._confirm:consumeMouse(x, y, button)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end

    for _, r in ipairs(self._btn_rects or {}) do
        if r.enabled
           and x >= r.x and x < r.x + r.w
           and y >= r.y and y < r.y + r.h then
            self:_handleButton(r.id)
            return
        end
    end
end

function TitleState:keypressed(key)
    if self._confirm then
        self._confirm:consumeKey(key)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end
    -- ENTER from title with no confirm = Start (fastest path for keyboard).
    if key == "return" or key == "kpenter" then
        self:_handleButton("start")
    elseif key == "escape" then
        self:_handleButton("exit")
    end
end

return TitleState
