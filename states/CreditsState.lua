-- states/CreditsState.lua
--
-- Reached when the player clears the gauntlet (3-of-3 runouts). Shows a
-- minimal "you walked out" screen with the option to keep playing on the
-- same save (the clear unlocks the deck system as post-win progression)
-- or wipe both saves and start over. The win itself is the achievement;
-- this state is the period at the end of the sentence.
--
-- For the vertical slice this is intentionally sparse — a polish pass can
-- replace it with a proper credit roll, audio sting, etc. The mechanic to
-- prove is that the win path EXISTS, persists in `state.cleared`, and the
-- player has a way to start over.

local AnchorRegistry = require("services.AnchorRegistry")
local Theme = require("views.Theme")

local CreditsState = {}
CreditsState.__index = CreditsState

function CreditsState:new(game)
    return setmetatable({ game = game }, CreditsState)
end

function CreditsState:enter()
    do  -- first-visit bookkeeping for the `screen_visits` hint kind
        local v = self.game.state and self.game.state.screen_visits
        if v then v["credits"] = (v["credits"] or 0) + 1 end
    end
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

    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf("you walked out.", 0, math.floor(H * 0.30), W, "center")
    -- The House's last word lands under it (story beat "credits").
    AnchorRegistry.set("story:band", 0,
        math.floor(H * 0.30) + fonts.lg:getHeight() + math.floor(12 * (self.game.ui_scale or 1)),
        W, fonts.md:getHeight())

    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(
        "the gauntlet cleared. the room is empty behind you.",
        0, math.floor(H * 0.46), W, "center")

    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("[ SPACE to keep playing ]",
        0, H - 90, W, "center")
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("[ R to wipe save and start over ]",
        0, H - 60, W, "center")
end

function CreditsState:keypressed(key)
    -- Continue on the same save: the clear persists (state.cleared), which
    -- is what unlocks the deck system as post-win progression. Mirrors the
    -- post-bust return: fresh run, catalog perks re-applied, back to grind
    -- (GrindState:enter rebuilds the pool).
    if key == "space" or key == "return" or key == "kpenter" then
        local state = self.game.state
        state:resetRun()
        local meta_ctx = state:computeEffects(
            self.game.effects, self.game.catalog, self.game.run_upgrades)
        state:applyStartingPerks(meta_ctx)
        self.game.save_service:saveAll(
            state:serializeMeta(), state:serializeRun())
        self.game.state_machine:switch("grind")
        return
    end
    if key == "r" then
        -- In-memory reset only. Use F7 (delete) to wipe the disk slots too.
        local state = self.game.state
        state:wipeAll()
        self.game.state_machine:switch("grind")
    end
end

return CreditsState
