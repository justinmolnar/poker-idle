-- views/RoomView.lua
--
-- Skeleton placeholder for the grind-mode UI. Renders the empty room — the
-- visual centerpiece that fills with catalog items over time. For now, just
-- a window-fill background with a "GRIND" label so the state-machine swap is
-- verifiable.
--
-- When the catalog UI is built, this is where the room background, item
-- placement, and per-item draw calls live.

local Theme = require("views.Theme")

local RoomView = {}
RoomView.__index = RoomView

function RoomView:new(game)
    return setmetatable({ game = game }, RoomView)
end

function RoomView:update(_) end

function RoomView:draw()
    local W, H = love.graphics.getWidth(), love.graphics.getHeight()

    -- Fill the room with chrome bg.
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Floor / wall split: a soft horizontal band so the room reads as a room.
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", 0, H * 0.65, W, H * 0.35)

    -- Borderline floor edge.
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("fill", 0, H * 0.65 - 1, W, 1)

    -- Eyebrow label so we can confirm we're in grind state.
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("GRIND", 16, 12)

    -- Centered placeholder text.
    Theme.setColor(Theme.fg.heading)
    local label = "the room"
    local font = love.graphics.getFont()
    local tw = font:getWidth(label)
    love.graphics.print(label, math.floor((W - tw) / 2), math.floor(H * 0.4))
end

return RoomView
