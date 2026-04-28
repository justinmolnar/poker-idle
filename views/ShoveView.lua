-- views/ShoveView.lua
--
-- Skeleton placeholder for the shove-mode UI. The MVP plan calls for the
-- shove sequence to be built first — this file is where the cinematic card
-- reveal, gauntlet runouts, and cheating-dealer reveal will live.
--
-- For the skeleton, just a black-ish background with a "SHOVE" label so the
-- state-machine swap is verifiable. The actual implementation is the next
-- task after the skeleton boots cleanly.

local Theme = require("views.Theme")

local ShoveView = {}
ShoveView.__index = ShoveView

function ShoveView:new(game)
    return setmetatable({ game = game }, ShoveView)
end

function ShoveView:update(_) end

function ShoveView:draw()
    local W, H = love.graphics.getWidth(), love.graphics.getHeight()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Eyebrow label.
    Theme.setColor(Theme.status.error)
    love.graphics.print("SHOVE", 16, 12)

    -- Centered hero text — sized via Theme.size.hero when fonts get wired.
    Theme.setColor(Theme.fg.heading)
    local label = "0%"
    local font = love.graphics.getFont()
    local tw = font:getWidth(label)
    love.graphics.print(label, math.floor((W - tw) / 2), math.floor(H * 0.4))

    Theme.setColor(Theme.fg.muted)
    local hint = "all-in"
    local hw = font:getWidth(hint)
    love.graphics.print(hint, math.floor((W - hw) / 2), math.floor(H * 0.4) + 24)
end

return ShoveView
