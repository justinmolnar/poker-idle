-- views/CreditsPanel.lua
--
-- The credits, from the title's menu: CREDITS.txt as the build wrote it
-- into the package (build-tools/credits.py — the head by hand, every
-- credited sound after it), scrolled in a modal. A dev run has no
-- CREDITS.txt and says so. Pure presentation.
--
-- Host contract, the shape of SettingsModal's: `host.credits_panel`,
-- `host:closeCredits()`, and CreditsPanel.route(host, event, ...) for the
-- input events.

local Modal    = require("views.widgets.Modal")
local Theme    = require("views.Theme")
local HintView = require("views.HintView")

local CreditsPanel = {}
CreditsPanel.__index = CreditsPanel

local W_BASE = 720
local NO_FILE = "The credits ship with the build: build-tools/credits.py writes CREDITS.txt into the package."

function CreditsPanel:new(game)
    local text
    if love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo("CREDITS.txt") then
        text = love.filesystem.read("CREDITS.txt")
    end
    return setmetatable({
        game     = game,
        text     = text or NO_FILE,
        _modal   = Modal:new{ title = "Credits", w = W_BASE },
        _lines   = nil,
        _lines_w = nil,
    }, CreditsPanel)
end

-- The text wrapped to the body, a blank line kept as a blank line.
function CreditsPanel:_wrap(font, w)
    if self._lines and self._lines_w == w then return self._lines end
    local lines = {}
    for para in (self.text .. "\n"):gmatch("(.-)\r?\n") do
        if para == "" then
            lines[#lines + 1] = ""
        else
            for _, l in ipairs(HintView.wrapLines(para, font, w)) do lines[#lines + 1] = l end
        end
    end
    self._lines, self._lines_w = lines, w
    return lines
end

function CreditsPanel:draw()
    local fonts = self.game.fonts
    local s     = self.game.ui_scale or 1
    local font  = fonts.sm
    self._modal.w = math.floor(W_BASE * s)
    local tw    = self._modal.w - self._modal.pad * 2
    local lines = self:_wrap(font, tw)
    local lh    = font:getHeight()
    local body  = self._modal:draw(fonts, #lines * lh)
    love.graphics.setFont(font)
    Theme.setColor(Theme.fg.primary)
    local y = body.y
    for _, line in ipairs(lines) do
        if line ~= "" then love.graphics.print(line, body.x, y) end
        y = y + lh
    end
    self._modal:endDraw()
end

-- A click on the frame (its scrollbar included) is the panel's; one off
-- it is the host's, which closes the panel.
function CreditsPanel:consumeMouse(mx, my, button)
    if self._modal:mousepressed(mx, my, button) then return true end
    return self._modal:hitTest(mx, my) == "inside"
end
function CreditsPanel:consumeKey() return false end
function CreditsPanel:wheelmoved(x, y) self._modal:wheelmoved(x, y) end
function CreditsPanel:mousemoved(x, y) self._modal:mousemoved(x, y) end
function CreditsPanel:mousereleased() self._modal:mousereleased() end

function CreditsPanel.route(host, event, a, b, c)
    local m = host.credits_panel
    if not m then return false end
    if event == "mousepressed" then
        if not m:consumeMouse(a, b, c) then host:closeCredits() end
    elseif event == "keypressed" then
        if not m:consumeKey(a) and a == "escape" then host:closeCredits() end
    elseif event == "mousemoved" then
        m:mousemoved(a, b)
    elseif event == "mousereleased" then
        m:mousereleased(a, b, c)
    elseif event == "wheelmoved" then
        m:wheelmoved(a, b)
    end
    return true
end

return CreditsPanel
