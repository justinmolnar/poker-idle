-- states/RoomState.lua
--
-- Dedicated state for viewing and designing the room.
-- Keeps the poker client grid, sidebars, and shove overlays completely hidden.

local AnchorRegistry = require("services.AnchorRegistry")
local Theme         = require("views.Theme")
local RoomView      = require("views.RoomView")
local Constants     = require("data.constants")
local LabelButton   = require("views.widgets.LabelButton")
local ClickFlash    = require("services.ClickFlash")
local Format        = require("utils.format")

local function moneyText(n) return Format.money(n) end

local RoomState = {}
RoomState.__index = RoomState

function RoomState:new(game)
    return setmetatable({
        game      = game,
        room_view = nil,
    }, RoomState)
end

-- The one RoomView. The shove borrows it for its intro (the room counts
-- what you own), so it exists before the room screen is ever visited.
function RoomState:getRoomView()
    if not self.room_view then
        self.room_view = RoomView:new(self.game)
    end
    return self.room_view
end

function RoomState:enter()
    do  -- first-visit bookkeeping for the `screen_visits` hint kind
        local v = self.game.state and self.game.state.screen_visits
        if v then v["room"] = (v["room"] or 0) + 1 end
    end
    Theme.setActive("room")
    if not self.room_view then
        self.room_view = RoomView:new(self.game)
    end
end

function RoomState:exit()
    if self.room_view then
        self.room_view.editor_mode = false
    end
    if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(false) end
    self._key_repeat = false
end

function RoomState:update(dt)
    -- Held keys repeat while the editor is up, so Ctrl+Up walks a piece
    -- across the room instead of needing a tap per grid step. Off again
    -- the moment the editor closes; nothing else in the game wants it.
    local want = (self.room_view and self.room_view.editor_mode) and true or false
    if want ~= (self._key_repeat or false) then
        if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(want) end
        self._key_repeat = want
    end

    -- Autosave the draft while the editor is up, and once more on the way
    -- out (want false, was true) so closing the editor loses nothing.
    if self.room_view then
        if want then
            self._autosave_t = (self._autosave_t or 0) + dt
            if self._autosave_t >= 2 then
                self._autosave_t = 0
                self.room_view:autosave()
            end
        elseif self._autosave_t then
            self._autosave_t = nil
            self.room_view:autosave()
        end
    end
end

function RoomState:draw()
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1
    local fl   = math.floor
    local fonts = self.game.fonts

    -- Draw background
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Draw Room View (centered full-screen). With the editor open the view
    -- is drawn LAST instead (see the end of this function): its toolbar
    -- lives inside the top bar, and drawing the bar after the view painted
    -- straight over Export / Reset / Clear / Help / Size / Floor.
    local view_last = self.room_view and self.room_view.editor_mode
    if self.room_view and not view_last then
        self.room_view:draw(true, { lighting = { fixture = self.room_view.fixture_off and 0 or 1, emitters = true } })
    end

    -- Draw top bar
    local top_h = fl(56 * s)
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", 0, 0, W, top_h)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("fill", 0, top_h - 1, W, 1)

    -- Display bankroll in top bar
    local d_bank = self.game.state.bankroll or 0
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.lg)
    local bank_y = fl((top_h - fonts.lg:getHeight()) * 0.5)
    local bank_str = moneyText(d_bank)
    love.graphics.print(bank_str, fl(16 * s), bank_y)

    -- Draw back/PLAY button to return to grind
    local btn_w = fl(100 * s)
    local btn_h = fl(36 * s)
    local btn_x = W - btn_w - fl(16 * s)
    local btn_y = fl((top_h - btn_h) * 0.5)
    -- Hint target: the way back to the tables.
    AnchorRegistry.set("room:play", btn_x, btn_y, btn_w, btn_h)
    -- The House's story band: a strip along the bottom of the room.
    AnchorRegistry.set("story:band", fl(16 * s), H - fl(60 * s), W - fl(32 * s), fl(44 * s))

    local mx, my = love.mouse.getPosition()

    -- DESIGNER button + unlock-cheat status: dev tooling, not demo content.
    -- The editor's EXPORT writes into the source tree, which doesn't even
    -- exist on the web build.
    if Constants.FEATURES.DEV_HOTKEYS then
    -- Draw DESIGNER button
    local des_w = fl(140 * s)
    local des_x = btn_x - des_w - fl(12 * s)
    local is_editing = self.room_view and self.room_view.editor_mode

    local des_hov = mx >= des_x and mx < des_x + des_w and my >= btn_y and my < btn_y + btn_h

    LabelButton.draw{
        x = des_x, y = btn_y, w = des_w, h = btn_h,
        text        = is_editing and "DESIGNER: ON [F3]" or "DESIGNER [F3]",
        fonts       = fonts,
        hovered     = des_hov,
        fill_override = is_editing and { 0.20, 0.50, 0.30 } or nil,
    }

    -- Developer unlock cheat status (dev builds only, like the U key it
    -- serves). owned_items is an ARRAY of ids (see GameState) — build a
    -- set to test membership.
    if Constants.FEATURES.DEV_HOTKEYS then
        local Catalog = require("data.catalog")
        local owned_set = {}
        for _, id in ipairs(self.game.state.owned_items) do owned_set[id] = true end
        local is_unlocked = true
        for _, item in ipairs(Catalog) do
            if not item.granted_at_start and not owned_set[item.id] then
                is_unlocked = false
                break
            end
        end
        love.graphics.setFont(fonts.sm)
        if is_unlocked then
            Theme.setColor(Theme.status.warn)
            love.graphics.print("ALL UNLOCKED [U]", des_x - fl(140 * s), btn_y + fl(10 * s))
        else
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("UNLOCK ALL [U]", des_x - fl(140 * s), btn_y + fl(10 * s))
        end
    end
    end

    local btn_hov = mx >= btn_x and mx < btn_x + btn_w
                and my >= btn_y and my < btn_y + btn_h

    LabelButton.draw{
        x = btn_x, y = btn_y, w = btn_w, h = btn_h,
        text        = "PLAY",
        fonts       = fonts,
        hovered     = btn_hov,
        press_alpha = ClickFlash.alpha("room_back_btn", "room_back_btn"),
    }
    if view_last then
        self.room_view:draw(true, { lighting = { fixture = self.room_view.fixture_off and 0 or 1, emitters = true } })
    end
end

-- The room editor's keys (F3 to enter/exit, -/= FPS, [ ] frame, ...)
-- collide with the global dev hotkeys; on this screen the room wins.
function RoomState:capturesDevKeys()
    return true
end

function RoomState:keypressed(key)
    if self.room_view and self.room_view:keypressed(key) then
        return
    end

    -- Toggle unlock all cheat. owned_items is an ARRAY of ids everywhere
    -- (computeEffects iterates it, serializeMeta persists it) — the old
    -- version wrote set-style keys into it, which registered as nothing
    -- and polluted saves. Rebuild as a clean array both ways, and drop
    -- the effects cache so the rollup sees the change.
    -- Dev builds only: a shipped build must not carry a key that can
    -- wipe the whole catalog (all-owned + U empties owned_items, and the
    -- autosave makes it stick).
    if key == "u" and Constants.FEATURES.DEV_HOTKEYS then
        local Catalog = require("data.catalog")
        local state = self.game.state
        -- Sanitize: keep only the array part (repairs saves the old
        -- cheat polluted with hash keys).
        local owned = {}
        local owned_set = {}
        for _, id in ipairs(state.owned_items) do
            owned[#owned + 1] = id
            owned_set[id] = true
        end

        local any_unowned = false
        for _, item in ipairs(Catalog) do
            if not owned_set[item.id] then any_unowned = true; break end
        end

        if any_unowned then
            for _, item in ipairs(Catalog) do
                if not owned_set[item.id] then
                    owned[#owned + 1] = item.id
                end
            end
            state.owned_items = owned
            state.cleared = true
            print("[debug] Unlocked all catalog items and decks for room testing")
        else
            state.owned_items = {}
            state.cleared = false
            print("[debug] Reset owned catalog items and decks to none")
        end
        state.effects_cache = nil
        if self.game.grind and self.game.grind.invalidateEffects then
            self.game.grind:invalidateEffects()
        end
        return true
    end

    -- ESC or Tab exits the RoomState back to Grind
    if key == "escape" or key == "tab" then
        self.game.state_machine:switch("grind")
    end
end

function RoomState:mousepressed(x, y, button)
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1
    local fl   = math.floor

    -- Check top-bar PLAY button click
    local top_h = fl(56 * s)
    local btn_w = fl(100 * s)
    local btn_h = fl(36 * s)
    local btn_x = W - btn_w - fl(16 * s)
    local btn_y = fl((top_h - btn_h) * 0.5)

    if x >= btn_x and x < btn_x + btn_w and y >= btn_y and y < btn_y + btn_h then
        ClickFlash.flash("room_back_btn", "room_back_btn")
        self.game.state_machine:switch("grind")
        return
    end

    -- Check top-bar DESIGNER button click (dev builds only)
    if Constants.FEATURES.DEV_HOTKEYS then
        local des_w = fl(140 * s)
        local des_x = btn_x - des_w - fl(12 * s)
        if x >= des_x and x < des_x + des_w and y >= btn_y and y < btn_y + btn_h then
            if self.room_view then
                self.room_view.editor_mode = not self.room_view.editor_mode
            end
            return
        end
    end

    -- Otherwise forward to RoomView
    if self.room_view then
        self.room_view:mousepressed(x, y, button)
    end
end

function RoomState:mousemoved(x, y, dx, dy)
    if self.room_view and self.room_view.mousemoved then
        self.room_view:mousemoved(x, y, dx, dy)
    end
end

function RoomState:mousereleased(x, y, button)
    if self.room_view and self.room_view.mousereleased then
        self.room_view:mousereleased(x, y, button)
    end
end

function RoomState:wheelmoved(x, y)
    if self.room_view then
        self.room_view:wheelmoved(y)
    end
end

return RoomState
