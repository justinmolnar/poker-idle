-- states/RoomState.lua
--
-- Dedicated state for viewing and designing the room.
-- Keeps the poker client grid, sidebars, and shove overlays completely hidden.

local Theme         = require("views.Theme")
local RoomView      = require("views.RoomView")
local Constants     = require("data.constants")
local LabelButton   = require("views.widgets.LabelButton")
local ClickFlash    = require("services.ClickFlash")
local Format        = require("utils.format")

local function moneyText(n)
    if math.abs(n or 0) < 1000 then return Format.moneyExact(n) end
    return Format.money(n)
end

local RoomState = {}
RoomState.__index = RoomState

function RoomState:new(game)
    return setmetatable({
        game      = game,
        room_view = nil,
    }, RoomState)
end

function RoomState:enter()
    Theme.setActive("room")
    if not self.room_view then
        self.room_view = RoomView:new(self.game)
    end
end

function RoomState:exit()
    if self.room_view then
        self.room_view.editor_mode = false
    end
end

function RoomState:update(dt)
    -- Room visual elements update if needed
end

function RoomState:draw()
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1
    local fl   = math.floor
    local fonts = self.game.fonts

    -- Draw background
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Draw Room View (centered full-screen)
    if self.room_view then
        self.room_view:draw(true)
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
    local btn_w = fl(120 * s)
    local btn_h = fl(36 * s)
    local btn_x = W - btn_w - fl(16 * s)
    local btn_y = fl((top_h - btn_h) * 0.5)

    -- Render developer unlock cheat status. owned_items is an ARRAY of
    -- ids (see GameState) — build a set to test membership.
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
        love.graphics.print("ALL ITEMS UNLOCKED [U]", btn_x - fl(170 * s), btn_y + fl(10 * s))
    else
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("PRESS [U] TO UNLOCK ALL", btn_x - fl(170 * s), btn_y + fl(10 * s))
    end

    local mx, my = love.mouse.getPosition()
    local btn_hov = mx >= btn_x and mx < btn_x + btn_w
                and my >= btn_y and my < btn_y + btn_h

    LabelButton.draw{
        x = btn_x, y = btn_y, w = btn_w, h = btn_h,
        text        = "PLAY",
        fonts       = fonts,
        hovered     = btn_hov,
        press_alpha = ClickFlash.alpha("room_back_btn", "room_back_btn"),
    }
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
    if key == "u" then
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
    local btn_w = fl(120 * s)
    local btn_h = fl(36 * s)
    local btn_x = W - btn_w - fl(16 * s)
    local btn_y = fl((top_h - btn_h) * 0.5)

    if x >= btn_x and x < btn_x + btn_w and y >= btn_y and y < btn_y + btn_h then
        ClickFlash.flash("room_back_btn", "room_back_btn")
        self.game.state_machine:switch("grind")
        return
    end

    -- Otherwise forward to RoomView
    if self.room_view then
        self.room_view:mousepressed(x, y, button)
    end
end

function RoomState:wheelmoved(x, y)
    if self.room_view then
        self.room_view:wheelmoved(y)
    end
end

return RoomState
