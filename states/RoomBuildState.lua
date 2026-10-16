-- states/RoomBuildState.lua
--
-- BUILD: the room's build-mode editor (views/RoomBuildView), as its own
-- state over the room's view. F3 from the room enters it (dev builds);
-- F3 leaves. It edits the same room_view the room state owns, so the
-- layout, the draft and the export are the ones the game uses. Dev
-- tooling: a cut module (build-tools/demo_cut.py).

local Theme = require("views.Theme")

local RoomBuildState = {}
RoomBuildState.__index = RoomBuildState

function RoomBuildState:new(game)
    return setmetatable({ game = game, view = nil, _autosave_t = 0 }, RoomBuildState)
end

local function roomView(game)
    local rs = game.state_machine.states.room
    if not rs then return nil end
    if not rs.room_view then
        local RoomView = require("views.RoomView")
        rs.room_view = RoomView:new(game)
    end
    return rs.room_view
end

function RoomBuildState:enter()
    Theme.setActive("room")
    local rv = roomView(self.game)
    if not rv then self.game.state_machine:switch("room"); return end
    rv.editor_mode = false
    rv.build_mode  = true
    rv.hide_editor_hud = false
    local Build = require("views.RoomBuildView")
    if not self.view or self.view.rv ~= rv then self.view = Build.new(self.game, rv) end
    if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(true) end
    if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(true) end
    print("[build] entered. Drag from the shelf; F3 leaves.")
end

function RoomBuildState:exit()
    local rv = roomView(self.game)
    if rv then
        if self.view and self.view.hand then self.view:cancel() end
        rv.build_mode = false
        rv.sel_placed, rv.hover_placed = nil, nil
        if rv.autosave then rv:autosave() end
    end
    if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(false) end
end

function RoomBuildState:update(dt)
    self._autosave_t = (self._autosave_t or 0) + dt
    if self._autosave_t > 2 then
        self._autosave_t = 0
        local rv = roomView(self.game)
        if rv and rv.autosave and not (self.view and self.view.hand) then rv:autosave() end
    end
end

function RoomBuildState:draw()
    if not self.view then return end
    local W, H = love.graphics.getDimensions()
    self.view:draw(W, H)
end

function RoomBuildState:keypressed(key)
    if key == "f3" then self.game.state_machine:switch("room"); return end
    if self.view then self.view:keypressed(key) end
end

function RoomBuildState:textinput(text)
    if self.view then self.view:textinput(text) end
end

function RoomBuildState:mousepressed(x, y, button)
    if self.view then self.view:mousepressed(x, y, button) end
end

function RoomBuildState:mousemoved(x, y, dx, dy)
    if self.view then self.view:mousemoved(x, y) end
end

function RoomBuildState:mousereleased(x, y, button)
    if self.view then self.view:mousereleased(x, y, button) end
end

function RoomBuildState:wheelmoved(x, y)
    if self.view then
        local mx, my = love.mouse.getPosition()
        self.view:wheelmoved(y, mx, my)
    end
end

return RoomBuildState
