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

-- `opts.backdrop` (optional): a canvas of the shove's last frame. The
-- credits fade in over it; without one (loading a cleared save straight
-- into credits) the screen draws as it always did.
local FADE_SECS   = 2.5    -- the pile darkens over this
local TEXT_DELAY  = 1.2    -- the words start after this
local TEXT_SECS   = 1.5
local FADE_ALPHA  = 0.88

function CreditsState:enter(opts)
    self.backdrop = opts and opts.backdrop or nil
    self.t = 0
    do  -- first-visit bookkeeping for the `screen_visits` hint kind
        local v = self.game.state and self.game.state.screen_visits
        if v then v["credits"] = (v["credits"] or 0) + 1 end
    end
    -- The shove palette is the right backdrop here — sparse, dramatic,
    -- already what the player just won out of.
    Theme.setActive("shove")
end

function CreditsState:exit() end

function CreditsState:update(dt)
    self.t = (self.t or 0) + (dt or 0)
end

-- Alpha of the text, 0 until TEXT_DELAY then up to 1; 1 with no backdrop.
function CreditsState:_textAlpha()
    if not self.backdrop then return 1 end
    local a = ((self.t or 0) - TEXT_DELAY) / TEXT_SECS
    if a < 0 then return 0 elseif a > 1 then return 1 end
    return a
end

function CreditsState:draw()
    local W, H  = love.graphics.getDimensions()
    local fonts = self.game.fonts

    if self.backdrop then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(self.backdrop, 0, 0)
        local p = math.min(1, (self.t or 0) / FADE_SECS)
        Theme.setColor(Theme.bg.window, p * FADE_ALPHA)
        love.graphics.rectangle("fill", 0, 0, W, H)
    else
        Theme.setColor(Theme.bg.window)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end
    local ta = self:_textAlpha()

    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.heading, ta)
    love.graphics.printf("you walked out.", 0, math.floor(H * 0.30), W, "center")
    -- The House's last word lands under it (story beat "credits").
    AnchorRegistry.set("story:band", 0,
        math.floor(H * 0.30) + fonts.lg:getHeight() + math.floor(12 * (self.game.ui_scale or 1)),
        W, fonts.md:getHeight())

    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.muted, ta)
    love.graphics.printf(
        "the gauntlet cleared. the room is empty behind you.",
        0, math.floor(H * 0.46), W, "center")

    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.muted, ta)
    love.graphics.printf("[ SPACE to keep playing ]",
        0, H - 90, W, "center")
    Theme.setColor(Theme.fg.faint, ta)
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
