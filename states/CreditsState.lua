-- states/CreditsState.lua
--
-- Reached when the player clears the gauntlet (3-of-3 runouts). Shows a
-- minimal "you walked out" screen with the option to wipe both saves and
-- start over. The win itself is the achievement; this state is the period
-- at the end of the sentence.
--
-- For the vertical slice this is intentionally sparse — a polish pass can
-- replace it with a proper credit roll, audio sting, etc. The mechanic to
-- prove is that the win path EXISTS, persists in `state.cleared`, and the
-- player has a way to start over.

local Theme = require("views.Theme")

local CreditsState = {}
CreditsState.__index = CreditsState

function CreditsState:new(game)
    return setmetatable({ game = game }, CreditsState)
end

function CreditsState:enter()
    -- The shove palette is the right backdrop here — sparse, dramatic,
    -- already what the player just won out of.
    Theme.setActive("shove")
end

function CreditsState:exit() end

function CreditsState:update(_) end

function CreditsState:draw()
    local W, H  = love.graphics.getDimensions()
    local fonts = self.game.fonts

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    love.graphics.setFont(fonts.hero)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf("you walked out.", 0, math.floor(H * 0.30), W, "center")

    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(
        "the gauntlet cleared. the room is empty behind you.",
        0, math.floor(H * 0.46), W, "center")

    love.graphics.setFont(fonts.ui)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("[ R to wipe save and start over ]",
        0, H - 60, W, "center")
end

function CreditsState:keypressed(key)
    if key == "r" then
        -- In-memory reset only. Use F7 (delete) to wipe the disk slots too.
        local state = self.game.state
        state:wipeAll()
        self.game.state_machine:switch("grind")
    end
end

return CreditsState
