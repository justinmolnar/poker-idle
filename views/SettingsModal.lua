-- views/SettingsModal.lua
--
-- Top-bar SETTINGS button opens this overlay. Built from widgets:
--   • views.widgets.Modal         — frame + dim backdrop
--   • views.widgets.Row           — label-value rows
--   • views.widgets.Slider        — volume slider
--   • views.widgets.ConfirmDialog — new-game / quit prompts
--
-- Display mode (windowed / fullscreen) was removed from the prototype
-- build — the web canvas owns its own fit-to-iframe behavior, and
-- native builds default to the conf.lua window size.

local Theme         = require("views.Theme")
local SoundService  = require("services.SoundService")
local Modal         = require("views.widgets.Modal")
local Row           = require("views.widgets.Row")
local ConfirmDialog = require("views.widgets.ConfirmDialog")
local Slider        = require("views.widgets.Slider")
local Constants     = require("data.constants")
local TooltipSvc    = require("services.Tooltip")

local SettingsModal = {}
SettingsModal.__index = SettingsModal

-- Base sizes — scaled at draw-time against game.ui_scale.
local MODAL_W_BASE = 480
local ROW_GAP_BASE = 10

local MODAL_W = MODAL_W_BASE
local ROW_GAP = ROW_GAP_BASE
local ROW_H   = 44

function SettingsModal.configureFromFonts(fonts)
    if not (fonts and fonts.md) then return end
    ROW_H = fonts.md:getHeight() + 22
end

-- Volume-only persistence. Display state is session-local.
local function persistVolume(self)
    local g = self.game
    if not (g and g.save_service and g.save_service.saveSettings) then return end
    g.save_service:saveSettings({
        volume = SoundService.getMasterVolume(),
    })
end

function SettingsModal.applySaved(payload)
    -- Volume is applied directly in main.lua; nothing else here.
    if not payload then return end
end

-- ─── Construction ─────────────────────────────────────────────────────

function SettingsModal:new(game)
    local self_inst = setmetatable({
        game           = game,
        _modal         = Modal:new{ title = "Settings", w = MODAL_W },
        _row_rects     = {},
        _confirm       = nil,
        _confirm_kind  = nil,
        _vol_slider    = nil,
    }, SettingsModal)

    self_inst._vol_slider = Slider:new{
        value     = SoundService.getMasterVolume(),
        on_change = function(v)
            SoundService.setMasterVolume(v)
            persistVolume(self_inst)
        end,
    }

    return self_inst
end

-- Confirm-dialog factories per kind. Adding a new prompt = one entry here.
local CONFIRM_BUILDERS = {
    -- Mirrors the title-screen "Start" confirmation verbatim so the new-game
    -- prompt reads identically wherever it's triggered.
    new_game = function(self)
        return ConfirmDialog:new{
            prompt        = "Start a new game? Existing save will be erased.",
            danger        = true,
            confirm_label = "Start Over",
            on_confirm    = function() self:_performNewGame() end,
        }
    end,
    quit = function(self)
        return ConfirmDialog:new{
            prompt = "Quit the game?", danger = true,
            on_confirm = function() love.event.quit() end,
        }
    end,
}

function SettingsModal:_openConfirm(kind)
    self._confirm_kind = kind
    local builder = CONFIRM_BUILDERS[kind]
    if builder then self._confirm = builder(self) end
end

-- Wipe disk + in-memory state and drop into a fresh grind run — the in-game
-- equivalent of the title screen's "Start". Runs every state's fullReset
-- first so the live cursor swarm / in-flight chips don't dangle past the wipe.
function SettingsModal:_performNewGame()
    local g = self.game
    if g.save_service then g.save_service:clearAll() end
    if g.state then g.state:wipeAll() end
    if g.state_machine and g.state_machine.states then
        for _, st in pairs(g.state_machine.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then
                st:fullReset()
            end
        end
        g.state_machine:switch("grind")
    end
end

function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    g.state:wipeAll()
    local saved = g.save_service:loadAll() or {}
    g.state:applySaved(saved)
    g.state.effects_cache = nil
    if g.state_machine and g.state_machine.states then
        for _, st in pairs(g.state_machine.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then
                st:fullReset()
            end
        end
        g.state_machine:switch("grind")
    end
end

-- Row-action handlers per action key. Adding a new row = one entry here +
-- one action_row(...) call in :draw.
local ACTION_HANDLERS = {
    save = function(self)
        local g = self.game
        if g.save_service and g.state then
            g.save_service:saveAll(g.state:serializeMeta(), g.state:serializeRun())
        end
    end,
    load     = function(self) self:_performLoad() end,
    new_game = function(self) self:_openConfirm("new_game") end,
    quit     = function(self) self:_openConfirm("quit") end,
}

function SettingsModal:_runAction(action)
    local handler = ACTION_HANDLERS[action]
    if handler then handler(self) end
end

-- ─── Input ─────────────────────────────────────────────────────────────

function SettingsModal:consumeKey(key)
    if self._confirm then
        local consumed = self._confirm:consumeKey(key)
        if self._confirm:resolved() then self._confirm = nil; self._confirm_kind = nil end
        return consumed
    end
    if key == "escape" then return false end  -- top-level ESC: caller closes
    return true                                -- swallow other keys
end

function SettingsModal:consumeMouse(mx, my, button)
    if button ~= 1 then return false end

    if self._confirm then
        local consumed = self._confirm:consumeMouse(mx, my, button)
        if self._confirm:resolved() then self._confirm = nil; self._confirm_kind = nil end
        return consumed
    end

    -- Volume slider: clicking on the track jumps the knob and arms a
    -- drag; subsequent mousemoved events update the value continuously.
    if self._vol_slider and self._vol_slider:mousepressed(mx, my, button) then
        return true
    end

    for _, rec in ipairs(self._row_rects) do
        if rec.action and mx >= rec.x and mx < rec.x + rec.w
           and my >= rec.y and my < rec.y + rec.h then
            self:_runAction(rec.action)
            return true
        end
    end
    -- Consume any other click inside the modal frame (disabled rows, labels,
    -- dead space) so it doesn't fall through to the host's outside-click
    -- dismiss. Only genuine outside-clicks return false.
    if self._modal and self._modal:hitTest(mx, my) == "inside" then
        return true
    end
    return false
end

function SettingsModal:mousemoved(mx, my)
    if self._vol_slider then self._vol_slider:mousemoved(mx, my) end
end

function SettingsModal:mousereleased(mx, my, button)
    if self._vol_slider then self._vol_slider:mousereleased(mx, my, button) end
end

-- No wheelmoved — host (GrindState/ShoveState) checks for the method
-- before calling, so an absent method is a clean no-op.

-- ─── Drawing ───────────────────────────────────────────────────────────

function SettingsModal:draw()
    self._row_rects = {}
    self._quit_tip  = nil
    local fonts = self.game.fonts
    local mx, my = love.mouse.getPosition()

    -- Scale modal width + row gap by ui_scale so the dialog doesn't
    -- look like a postage stamp on big windows.
    local s = (self.game.ui_scale) or 1
    MODAL_W = math.floor(MODAL_W_BASE * s)
    ROW_GAP = math.floor(ROW_GAP_BASE * s)
    -- Rebuild the modal frame each draw so its width tracks scale.
    self._modal = Modal:new{ title = "Settings", w = MODAL_W }

    local rows = 5  -- volume, save, load, new game, quit
    local body_h = rows * ROW_H + (rows - 1) * ROW_GAP

    local body = self._modal:draw(fonts, body_h)

    local row_x = body.x
    local row_w = body.w
    local y     = body.y

    -- Volume — label on the left, slider track in the middle,
    -- live percentage on the right. Drag-anywhere on the track sets
    -- the knob; persistVolume runs on each on_change.
    local vol_pct = math.floor(SoundService.getMasterVolume() * 100 + 0.5)
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.md)
    love.graphics.print("Volume", row_x + 10, y + math.floor((ROW_H - fonts.md:getHeight()) / 2))

    local pct_text  = string.format("%d%%", vol_pct)
    local pct_w     = fonts.md:getWidth(pct_text) + 4
    local label_w   = fonts.md:getWidth("Volume") + 24
    local track_x   = row_x + label_w
    local track_end = row_x + row_w - pct_w - 10
    local track_w   = math.max(40, track_end - track_x)

    -- Sync slider value to live SoundService each frame so external
    -- changes (settings reload) reflect into the knob position.
    if self._vol_slider then
        self._vol_slider.value = SoundService.getMasterVolume()
        self._vol_slider:draw(track_x, y, track_w, ROW_H)
    end

    Theme.setColor(Theme.fg.heading)
    love.graphics.print(pct_text,
        row_x + row_w - pct_w - 4,
        y + math.floor((ROW_H - fonts.md:getHeight()) / 2))

    y = y + ROW_H + ROW_GAP

    local function action_row(label, action, opts)
        opts = opts or {}
        local hov = mx >= row_x and mx < row_x + row_w and my >= y and my < y + ROW_H
        Row.draw{ x = row_x, y = y, w = row_w, h = ROW_H,
                  label = label, fonts = fonts,
                  hovered = hov and not opts.disabled, disabled = opts.disabled }
        if opts.disabled then
            -- No hit-rect → unclickable; stash the hover tooltip to draw on top.
            if hov and opts.tip then self._quit_tip = { text = opts.tip, x = mx, y = my } end
        else
            self._row_rects[#self._row_rects + 1] = {
                x = row_x, y = y, w = row_w, h = ROW_H, action = action,
            }
        end
        y = y + ROW_H + ROW_GAP
    end
    action_row("Save now",       "save")
    action_row("Load save",      "load")
    action_row("Start new game", "new_game")
    local quit_off = Constants.FEATURES and Constants.FEATURES.QUIT_DISABLED
    action_row("Quit", "quit", quit_off
        and { disabled = true, tip = "Disabled for web build." } or nil)

    self._modal:endDraw()

    if self._confirm then
        self._confirm:draw(fonts)
        if self._confirm:resolved() then self._confirm = nil; self._confirm_kind = nil end
    end

    -- Disabled-Quit tooltip. GrindView's global tooltip pass already ran
    -- (before this modal drew), so render it here to land on top of the modal.
    if self._quit_tip then
        TooltipSvc.set(self._quit_tip.text, self._quit_tip.x, self._quit_tip.y)
        TooltipSvc.draw(fonts)
    end
end

return SettingsModal
