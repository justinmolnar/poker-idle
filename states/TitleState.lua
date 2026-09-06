-- states/TitleState.lua
--
-- Boot screen, shown on every launch: the player's room in the dark
-- (views/TitleView draws it), the name dealt as cards, and the menu:
--   • Continue   — with a save: back to the grind (or the pending shove).
--                  Owns Enter.
--   • New Game   — confirms first if a save exists. Owns Enter without one.
--   • Settings   — the in-game SettingsModal in menu mode (no Save/Load),
--                  so the Motion page is reachable before anything moves.
--                  ESC opens it; ESC inside closes it.
--   • Exit       — desktop only (a browser tab can't quit itself).
--   • delete save — a small link in the corner; confirms.
--
-- Continue and New Game are the light switch: `lights_on` plays, the
-- fixture blooms on the room's own curve and the switch happens on the
-- settle, so a new game's "Morning, princess" lands seconds after the
-- tube comes on. At cinematics Low or None the switch is immediate.
--
-- Between clicks the intercom keys up now and then: static, no words
-- (services/RadioVoice with nothing typing plays the key-up alone) and
-- the wall speaker rattles. He's listening.

local Theme         = require("views.Theme")
local ConfirmDialog = require("views.widgets.ConfirmDialog")
local SettingsModal = require("views.SettingsModal")
local TitleView     = require("views.TitleView")
local Constants     = require("data.constants")
local SoundService  = require("services.SoundService")
local RadioVoice    = require("services.RadioVoice")
local Motion        = require("services.Motion")

local TitleState = {}
TitleState.__index = TitleState

local KEYUP_FIRST   = 9.0    -- seconds of quiet before the first key-up
local KEYUP_MIN     = 14.0   -- then every KEYUP_MIN..KEYUP_MAX
local KEYUP_MAX     = 28.0
local RATTLE_SECS   = 0.6    -- the speaker's rattle per key-up

function TitleState:new(game)
    return setmetatable({
        game           = game,
        view           = TitleView:new(game),
        t              = 0,
        skip           = false,
        leave          = nil,      -- { t, action } while the light comes on
        speaker        = 0,
        _next_keyup    = KEYUP_FIRST,
        _lands_played  = 0,
        _chip_played   = false,
        _confirm       = nil,
        settings_modal = nil,
    }, TitleState)
end

function TitleState:enter()
    Theme.setActive("room")
    self.t             = 0
    self.skip          = false
    self.leave         = nil
    self.speaker       = 0
    self._next_keyup   = KEYUP_FIRST
    self._lands_played = 0
    self._chip_played  = false
    self._confirm      = nil
    self.settings_modal = nil
    self.view:reset()
end

function TitleState:exit() end

local function hasSave()
    return love.filesystem.getInfo(Constants.SAVE.META_FILE) ~= nil
        or love.filesystem.getInfo(Constants.SAVE.RUN_FILE)  ~= nil
end

-- The player's room: RoomState owns the one RoomView (the shove intro
-- borrows it the same way). nil without a room state (a harness).
function TitleState:_roomView()
    local sm = self.game.state_machine
    local room = sm and sm.states and sm.states.room
    if room and room.getRoomView then return room:getRoomView() end
    return nil
end

-- ── The clock ─────────────────────────────────────────────────────────

function TitleState:update(dt)
    dt = dt or 0
    self.t = self.t + dt

    -- The deal's sounds, the frame each card (and the chip) lands.
    local sched = self.view:schedule()
    local t_eff = self.skip and math.huge or self.t
    if sched.scale > 0 then
        while self._lands_played < #sched.lands
              and t_eff >= sched.lands[self._lands_played + 1] do
            self._lands_played = self._lands_played + 1
            if not self.skip then SoundService.playNamed("card_dealt") end
        end
        if not self._chip_played and t_eff >= sched.chip_at then
            self._chip_played = true
            if not self.skip then SoundService.playNamed("chip_land_pot") end
        end
        -- The idle turns: one flip sound per turn, either direction.
        local t_now  = self.skip and math.max(self.t, sched.done_at) or self.t
        local t_prev = self.skip and math.max(self.t - dt, sched.done_at) or (self.t - dt)
        if self.view:idleFlips(t_prev, t_now) > 0 then
            SoundService.playNamed("hole_card_flip")
        end
    end

    -- The intercom, listening.
    if self.speaker > 0 then
        self.speaker = math.max(0, self.speaker - dt / RATTLE_SECS)
    end
    if not self.leave and self.t >= self._next_keyup then
        self._next_keyup = self.t + KEYUP_MIN + love.math.random() * (KEYUP_MAX - KEYUP_MIN)
        RadioVoice.lineStarted()
        if Motion.at("cinematics", Motion.HIGH) then self.speaker = 1 end
    end

    -- The light coming on.
    if self.leave then
        self.leave.t = self.leave.t + dt
        if self.leave.t >= TitleView.LEAVE_SECS then
            local action = self.leave.action
            self.leave = nil
            self:_go(action)
        end
    end
end

function TitleState:draw()
    self.view:draw{
        t         = self.t,
        skip      = self.skip,
        leave_t   = self.leave and self.leave.t or nil,
        speaker   = self.speaker,
        has_save  = hasSave(),
        room_view = self:_roomView(),
    }
    if self.settings_modal then self.settings_modal:draw() end
    if self._confirm then self._confirm:draw(self.game.fonts) end
end

-- ── Leaving ───────────────────────────────────────────────────────────

-- Throw the switch. The action runs when the fixture settles; at Low and
-- None (nothing travels) it runs now, after the sound.
function TitleState:_leave(action)
    if self.leave then return end
    SoundService.playNamed("lights_on")
    if Motion.scale("cinematics") <= 0 then
        self:_go(action)
        return
    end
    self.leave = { t = 0, action = action }
end

function TitleState:_go(action)
    -- The tube's hum is layered under lights_on and runs until stopped
    -- (the shove intro stops it at its switch-off); the cut to the game
    -- is where it ends here.
    SoundService.stopNamed("lights_on")
    if action == "new" then
        if self.game.startNewGame then self.game.startNewGame() end
    elseif action == "continue" then
        -- A save with shove_pending was written from the shove screen: the
        -- run is already spent (chips banked, outcomes rolled). Resume the
        -- shove itself — landing on grind handed back the un-reset run,
        -- an infinite chip re-bank and a free gauntlet retry.
        if self.game.state.shove_pending then
            self.game.state_machine:switch("shove")
        else
            self.game.state_machine:switch("grind")
        end
    end
end

function TitleState:_doDelete()
    self.game.save_service:clearAll()
    self.game.state:wipeAll()
    -- Stay on the title; the room redraws bare and Continue is gone.
end

-- ── The menu ──────────────────────────────────────────────────────────

local BUTTON_HANDLERS = {
    continue = function(self) self:_leave("continue") end,
    new = function(self)
        if hasSave() then
            self._confirm = ConfirmDialog:new{
                prompt        = "Start a new game? Existing save will be erased.",
                danger        = true,
                confirm_label = "Start Over",
                on_confirm    = function() self:_leave("new") end,
            }
        else
            self:_leave("new")
        end
    end,
    settings = function(self)
        self.settings_modal = SettingsModal:new(self.game, { menu = true })
    end,
    exit = function(self)
        self._confirm = ConfirmDialog:new{
            prompt        = "Quit the game?",
            danger        = true,
            confirm_label = "Quit",
            on_confirm    = function() love.event.quit() end,
        }
    end,
    delete = function(self)
        self._confirm = ConfirmDialog:new{
            prompt        = "Delete your save? This cannot be undone.",
            danger        = true,
            confirm_label = "Delete",
            on_confirm    = function() self:_doDelete() end,
        }
    end,
    wishlist = function()
        local url = Constants.STEAM_URL
        if url and url ~= "" and love.system and love.system.openURL then
            pcall(love.system.openURL, url)
        end
    end,
}

function TitleState:_handleButton(id)
    local handler = BUTTON_HANDLERS[id]
    if handler then handler(self) end
end

function TitleState:closeSettings()
    self.settings_modal = nil
end

-- ── Input ─────────────────────────────────────────────────────────────

function TitleState:mousepressed(x, y, button)
    if SettingsModal.route(self, "mousepressed", x, y, button) then return end
    if self._confirm then
        self._confirm:consumeMouse(x, y, button)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end
    if button ~= 1 or self.leave then return end

    local id = self.view:hit(x, y)
    if id then
        self:_handleButton(id)
        return
    end
    -- A click on nothing while the deal is still going completes it.
    if not self.skip and self.t < self.view:schedule().done_at then
        self.skip = true
    end
end

function TitleState:mousereleased(x, y, button)
    SettingsModal.route(self, "mousereleased", x, y, button)
end

function TitleState:mousemoved(x, y)
    SettingsModal.route(self, "mousemoved", x, y)
end

function TitleState:wheelmoved(x, y)
    SettingsModal.route(self, "wheelmoved", x, y)
end

function TitleState:keypressed(key)
    if SettingsModal.route(self, "keypressed", key) then return end
    if self._confirm then
        self._confirm:consumeKey(key)
        if self._confirm:resolved() then self._confirm = nil end
        return
    end
    if self.leave then return end
    if key == "return" or key == "kpenter" then
        self:_handleButton(hasSave() and "continue" or "new")
    elseif key == "escape" then
        self:_handleButton("settings")
    end
end

return TitleState
