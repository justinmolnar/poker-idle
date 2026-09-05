-- views/SettingsModal.lua
--
-- Top-bar SETTINGS button opens this overlay. Built from widgets:
--   • views.widgets.Modal         — frame + dim backdrop
--   • views.widgets.Row           — label-value rows
--   • views.widgets.Slider        — volume slider
--   • views.widgets.ConfirmDialog — new-game / quit prompts
--   • views.widgets.Dropdown      — resolution picker
--
-- Display (windowed / borderless / fullscreen) and Resolution rows show on
-- desktop only: the web canvas is the iframe and owns its own fit. Both go
-- through services/Display, which applies and persists them.

local Theme         = require("views.Theme")
local SoundService  = require("services.SoundService")
local Display       = require("services.Display")
local Motion        = require("services.Motion")
local Modal         = require("views.widgets.Modal")
local Row           = require("views.widgets.Row")
local ConfirmDialog = require("views.widgets.ConfirmDialog")
local Slider        = require("views.widgets.Slider")
local Dropdown      = require("views.widgets.Dropdown")
local TooltipSvc    = require("services.Tooltip")
local HoverSvc      = require("services.HoverService")

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

-- Merge-write the full settings table so analytics_consent is never wiped.
local function persistSettings(self)
    local g = self.game
    if not (g and g.save_service and g.settings) then return end
    g.settings.volume       = SoundService.getMasterVolume()
    g.settings.sfx_volume   = SoundService.getSfxVolume()
    g.settings.music_volume = SoundService.getMusicVolume()
    Motion.save(g.settings)
    g.save_service:saveSettings(g.settings)
end

-- ─── Construction ─────────────────────────────────────────────────────

-- opts.menu: opened from the title. Hides Save / Load: there is nothing
-- live to save (Save would write a file where none may exist) and Load is
-- the title's own Continue.
function SettingsModal:new(game, opts)
    local self_inst = setmetatable({
        game           = game,
        _menu          = opts and opts.menu or false,
        _modal         = Modal:new{ title = "Settings", w = MODAL_W },
        _row_rects     = {},
        _confirm       = nil,
        _confirm_kind  = nil,
        _sliders       = {},
        _res_dd        = nil,   -- resolution picker (desktop only)
        _res_popup     = nil,   -- where the open popup anchors, set in :draw
        _page          = "main", -- "main" | "motion"
    }, SettingsModal)

    -- Resolution picker: the primary display's modes (services/Display).
    -- Picking one applies and persists it through the same path as the
    -- Display row. Refreshed from the engine whenever the popup opens.
    if Display.isDesktop() and game.settings then
        Display.defaults(game.settings)
        self_inst._res_dd = Dropdown:new{
            items          = Display.modes(game.settings),
            selected_value = Display.sizeKey(game.settings.display_w, game.settings.display_h),
            on_pick        = function(value)
                local w, h = Display.parseSize(value)
                if not w then return end
                Display.commit(game.settings, game.save_service,
                    { display_w = w, display_h = h })
            end,
        }
    end

    -- The three audio channels: Master scales everything; SFX carries
    -- every effect and the intercom voice; Music is the music layer.
    local channels = {
        { label = "Master", get = SoundService.getMasterVolume,
                            set = SoundService.setMasterVolume },
        { label = "SFX",    get = SoundService.getSfxVolume,
                            set = SoundService.setSfxVolume },
        { label = "Music",  get = SoundService.getMusicVolume,
                            set = SoundService.setMusicVolume },
    }
    for _, ch in ipairs(channels) do
        local entry = { label = ch.label, get = ch.get }
        entry.slider = Slider:new{
            value     = ch.get(),
            on_change = function(v)
                ch.set(v)
                persistSettings(self_inst)
            end,
        }
        self_inst._sliders[#self_inst._sliders + 1] = entry
    end

    return self_inst
end

local function toggleAnalytics(self)
    local g = self.game
    if not (g and g.settings) then return end
    g.settings.analytics_consent = not g.settings.analytics_consent
    persistSettings(self)
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
    if self.game.startNewGame then self.game.startNewGame() end
end

function SettingsModal:_performLoad()
    local g = self.game
    if not (g.save_service and g.state) then return end
    -- Read FIRST: loadAll always returns a table, so wiping before the
    -- check meant a missing or unreadable save wiped the live game.
    local saved = g.save_service:loadAll()
    if not (saved.meta or saved.run) then
        print("SettingsModal: no readable save to load")
        return
    end
    g.state:wipeAll()
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
    load      = function(self) self:_performLoad() end,
    new_game  = function(self) self:_openConfirm("new_game") end,
    quit      = function(self) self:_openConfirm("quit") end,
    analytics = function(self) toggleAnalytics(self) end,
    -- The Motion page (services/Motion levels).
    motion_page = function(self) self._page = "motion" end,
    motion_back = function(self) self._page = "main" end,
    motion_all  = function(self)
        local m = Motion.master()
        Motion.setAll(Motion.nextLevel(m or Motion.FULL))
        persistSettings(self)
    end,
    -- Cycles windowed -> borderless -> fullscreen; applied + persisted.
    display   = function(self)
        local g = self.game
        if not (g and g.settings) then return end
        Display.commit(g.settings, g.save_service,
            { display_mode = Display.nextMode(g.settings.display_mode) })
    end,
}

function SettingsModal:_runAction(action)
    if type(action) == "string" and action:sub(1, 7) == "motion:" then
        local id = action:sub(8)
        Motion.set(id, Motion.nextLevel(Motion.level(id)))
        persistSettings(self)
        return
    end
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
    -- An open resolution popup owns the keyboard (ESC closes it, not the modal).
    if self._res_dd and self._res_dd:wasOpen() then
        self._res_dd:consumeKey(key)
        return true
    end
    -- ESC on the Motion page goes back to the main page, not out.
    if key == "escape" and self._page == "motion" then self._page = "main"; return true end
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

    -- The frame's own scrollbar, when the body scrolls.
    if self._modal and self._modal:mousepressed(mx, my, button) then return true end

    -- Resolution popup first: it draws over everything else in the modal,
    -- and a click that closes it must not also fire whatever it covered.
    if self._res_dd then
        local was_open = self._res_dd:wasOpen()
        local hit = self._res_dd:consumeMouse(mx, my, button)
        if hit == "header" and self._res_dd:wasOpen() then
            self._res_dd:setItems(Display.modes(self.game.settings),
                self._res_dd.selected_value)
        end
        if hit ~= "outside" or was_open then return true end
    end

    -- Rows and sliders are laid out through the frame's scroll; a hit
    -- outside the visible body is on something that isn't on screen.
    if self._modal and not self._modal:inBody(mx, my) then
        if self._modal:hitTest(mx, my) == "inside" then return true end
        return false
    end

    -- Volume sliders: clicking on a track jumps that knob and arms a
    -- drag; subsequent mousemoved events update the value continuously.
    for _, entry in ipairs(self._sliders) do
        if entry.slider:mousepressed(mx, my, button) then
            return true
        end
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
    if self._modal and self._modal:mousemoved(mx, my) then return end
    for _, entry in ipairs(self._sliders) do
        entry.slider:mousemoved(mx, my)
    end
end

function SettingsModal:mousereleased(mx, my, button)
    if self._modal then self._modal:mousereleased() end
    for _, entry in ipairs(self._sliders) do
        entry.slider:mousereleased(mx, my, button)
    end
end

-- Wheel scrolls the resolution popup while it's open; nothing else here
-- scrolls. Hosts (GrindState/ShoveState) forward when the method exists.
function SettingsModal:wheelmoved(x, y)
    if self._res_dd and self._res_dd:wasOpen() then
        self._res_dd:wheelmoved(x, y)
        return true
    end
    -- Else the frame scrolls its body, when there is more than fits.
    if self._modal and self._modal:wheelmoved(x, y) then return true end
    return false
end

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
    -- One frame, kept across draws (its scroll lives on it); width and
    -- title follow the page and the scale.
    self._modal.w = MODAL_W
    self._modal:setTitle((self._page == "motion") and "Motion" or "Settings")

    -- master, sfx, music, [display, resolution], motion, analytics, save,
    -- load, new game, quit — the bracketed two are desktop only. The
    -- Motion page: all-motion, one per group, back.
    local show_display = self._res_dd ~= nil and self.game.settings ~= nil
    local rows = show_display and 11 or 9
    if self._menu then rows = rows - 2 end
    if self._page == "motion" then rows = 2 + #Motion.GROUPS end
    local body_h = rows * ROW_H + (rows - 1) * ROW_GAP

    local body = self._modal:draw(fonts, body_h)

    local row_x = body.x
    local row_w = body.w
    local y     = body.y

    local function action_row(label, action, opts)
        opts = opts or {}
        local hov = HoverSvc.rest("button", "settings_row:" .. label,
            mx >= row_x and mx < row_x + row_w and my >= y and my < y + ROW_H, 0)
        Row.draw{ x = row_x, y = y, w = row_w, h = ROW_H,
                  label = label, value = opts.value, fonts = fonts,
                  hovered = hov and not opts.disabled, disabled = opts.disabled }
        -- A hover tip, drawn on top after endDraw.
        if hov and opts.tip then self._quit_tip = { text = opts.tip, x = mx, y = my } end
        if not opts.disabled then
            self._row_rects[#self._row_rects + 1] = {
                x = row_x, y = y, w = row_w, h = ROW_H, action = action,
            }
        end
        y = y + ROW_H + ROW_GAP
    end

    -- The Motion page: the master level, one row per group, Back. A click
    -- on a row steps its level down and wraps (Full → High → … → None).
    if self._page == "motion" then
        action_row("All motion", "motion_all", {
            value = Motion.masterLabel(),
            tip   = "Sets every group below. Full is the game as authored; None is instant.",
        })
        for _, g in ipairs(Motion.GROUPS) do
            action_row(g.label, "motion:" .. g.id, { value = Motion.label(g.id), tip = g.desc })
        end
        action_row("Back", "motion_back")
        self._modal:endDraw()
        if self._quit_tip then
            TooltipSvc.set(self._quit_tip.text, self._quit_tip.x, self._quit_tip.y)
            TooltipSvc.draw(fonts)
        end
        return
    end

    -- Volume rows — label on the left (column sized to the widest of the
    -- three), slider track in the middle, live percentage on the right.
    -- Drag-anywhere on a track sets its knob; persistSettings runs on
    -- each on_change. Slider values re-sync from SoundService each frame
    -- so external changes reflect into the knobs.
    local label_w = 0
    for _, entry in ipairs(self._sliders) do
        label_w = math.max(label_w, fonts.md:getWidth(entry.label))
    end
    label_w = label_w + 24
    for _, entry in ipairs(self._sliders) do
        local vol_pct = math.floor(entry.get() * 100 + 0.5)
        Theme.setColor(Theme.fg.muted)
        love.graphics.setFont(fonts.md)
        love.graphics.print(entry.label, row_x + 10,
            y + math.floor((ROW_H - fonts.md:getHeight()) / 2))

        local pct_text  = string.format("%d%%", vol_pct)
        local pct_w     = fonts.md:getWidth("100%") + 4
        local track_x   = row_x + label_w
        local track_end = row_x + row_w - pct_w - 10
        local track_w   = math.max(40, track_end - track_x)

        entry.slider.value = entry.get()
        entry.slider:draw(track_x, y, track_w, ROW_H)

        Theme.setColor(Theme.fg.heading)
        love.graphics.print(pct_text,
            row_x + row_w - pct_w - 4,
            y + math.floor((ROW_H - fonts.md:getHeight()) / 2))

        y = y + ROW_H + ROW_GAP
    end


    -- Display mode + resolution (desktop only). The mode row cycles on
    -- click and shows the current mode as its value; the resolution row is
    -- the dropdown's header, greyed while Borderless (that mode is always
    -- the desktop size). The popup itself draws after endDraw, on top.
    self._res_popup = nil
    if show_display then
        local st   = self.game.settings
        local mode = st.display_mode or "windowed"
        action_row("Display", "display", { value = Display.MODE_LABELS[mode] or mode })
        if mode == "borderless" then
            self._res_dd:reset()
            action_row("Resolution", nil, {
                disabled = true,
                value    = string.format("%d x %d", st.display_w, st.display_h),
                tip      = "Borderless uses the desktop size.",
            })
        else
            self._res_dd.selected_value = Display.sizeKey(st.display_w, st.display_h)
            if self._res_dd:selectedLabel() == "" then
                self._res_dd:setItems(Display.modes(st), self._res_dd.selected_value)
            end
            self._res_dd:drawHeader(row_x, y, row_w, ROW_H, "Resolution", fonts)
            self._res_popup = { x = row_x, y = y + ROW_H + math.floor(2 * s), w = row_w }
            y = y + ROW_H + ROW_GAP
        end
    end

    -- Motion levels live on their own page (they are nine rows).
    action_row("Motion", "motion_page", {
        value = Motion.masterLabel(),
        tip   = "How much the game moves: chips, cards, tables, and the rest, each with its own level.",
    })

    -- Analytics consent — same checkbox style as the onboarding modal.
    do
        -- Strict true: consent is tri-state and nil means "never asked" —
        -- displaying that as ON contradicted the send gate, which treats
        -- anything but true as off.
        local ana_on  = (self.game.settings and self.game.settings.analytics_consent) == true
        local ana_hov = HoverSvc.rest("button", "settings_analytics",
            mx >= row_x and mx < row_x + row_w and my >= y and my < y + ROW_H, 0)
        local box_sz  = math.floor(12 * s)
        local lh      = fonts.md:getHeight()
        local label   = "Send Anonymous Gameplay Analytics"
        local box_x   = row_x + math.floor(10 * s)
        local box_y   = y + math.floor((ROW_H - box_sz) / 2)
        local text_y  = y + math.floor((ROW_H - lh) / 2)
        local label_x = box_x + box_sz + math.floor(8 * s)
        if ana_hov then
            Theme.setColor(Theme.bg.widget)
            love.graphics.rectangle("fill", row_x, y, row_w, ROW_H, math.floor(3 * s))
        end
        Theme.setColor(ana_on and Theme.status.good or Theme.bg.widget)
        love.graphics.rectangle("fill", box_x, box_y, box_sz, box_sz, math.floor(2*s))
        Theme.setColor(ana_on and Theme.status.good or Theme.border.default)
        love.graphics.rectangle("line", box_x, box_y, box_sz, box_sz, math.floor(2*s))
        if ana_on then
            love.graphics.setFont(fonts.sm)
            Theme.setColor(Theme.bg.window)
            love.graphics.print("\xE2\x9C\x93", box_x + math.floor(1*s), box_y - math.floor(1*s))
        end
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(label, label_x, text_y)
        self._row_rects[#self._row_rects + 1] = {
            x = row_x, y = y, w = row_w, h = ROW_H, action = "analytics",
        }
        y = y + ROW_H + ROW_GAP
    end

    if not self._menu then
        action_row("Save now",       "save")
        action_row("Load save",      "load")
    end
    action_row("Start new game", "new_game")
    -- The web/love.js build can't quit a browser tab — love.event.quit()
    -- hard-errors the canvas — so Quit greys out on that platform.
    -- getOS() returns "Web" there (verified against the shipped
    -- love.js compat wasm); "Emscripten" belts any variant that passes
    -- SDL's platform name through instead.
    local os_name  = love.system and love.system.getOS and love.system.getOS() or ""
    local quit_off = os_name == "Web" or os_name == "Emscripten"
    action_row("Quit", "quit", quit_off
        and { disabled = true, tip = "Disabled for web build." } or nil)

    self._modal:endDraw()

    -- The resolution list, over the rows beneath it.
    if self._res_dd and self._res_popup and self._res_dd:wasOpen() then
        local p = self._res_popup
        self._res_dd:drawPopup(p.x, p.y, p.w, fonts)
    end

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
