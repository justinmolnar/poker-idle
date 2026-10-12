-- sim/smoke_demo_end.lua
--
-- The demo's ending (FEATURES.DEMO_CUT): the shove's first R1 win plays
-- out as the standard cliffhanger (R2 forced lost, models/shove_rate),
-- records no act flag, and lands the flyer with the demo's inside.
--   loss      an R1 loss ends nothing and throws no flyer
--   ending    win R1 / lose R2 sets state.demo_ended; no act flag, no
--             milestone, decks still locked; the flyer lands, demo face
--   flyer     closed it lands; open it draws the page with the WISHLIST
--             sticker (store page set) and no tiles; the sticker opens
--             the store with the demo's utm; no store page, no sticker
--   again     the next shove throws it again (the full game's rule)
--   save      demo_ended rides the meta
--   full      outside the demo the same shove opens Act 2 and the flyer
--             is the roster
--
-- Standalone: `lua sim/smoke_demo_end.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Constants = require("data.constants")
local H = require("sim.harness")
local F = Stub.font(16)
local w = H.world({ act2 = false })   -- a demo save: nothing opened yet
local g = w.game
g.fonts = { lg = F, md = F, sm = F, xs = F, micro = F }
g.state_machine = { states = {}, switch = function() end,
                    current = function() return "shove" end }
local img = { getWidth = function() return 32 end, getHeight = function() return 32 end,
              getDimensions = function() return 32, 32 end,
              setFilter = function() end, release = function() end }
g.sprite_loader = {
    getSprite = function() return img end, getSpriteFor = function() return img end,
    hasSprite = function() return true end, backColor = function() return { 0.5, 0.5, 0.5 } end,
    setSprite = function() end, itemArt = function() return img end,
}
Stub.recorder()
love.graphics.newFont = function() return F end
love.graphics.getFont = function() return F end
love.timer.getDelta = love.timer.getDelta or function() return 1 / 60 end
local opened = {}
love.system.openURL = function(u) opened[#opened + 1] = u; return true end

local was = { cut = Constants.FEATURES.DEMO_CUT, decks = Constants.FEATURES.DECKS, url = Constants.STEAM_URL }
Constants.FEATURES.DEMO_CUT = true
Constants.FEATURES.DECKS    = false
Constants.STEAM_URL         = "https://store.steampowered.com/app/1"

local ShoveState = require("states.ShoveState")
local GameState  = require("models.GameState")
local Decks      = require("models.Decks")
local ss    = ShoveState:new(g)
local state = g.state

-- One shove, settled, its flyer thrown (the cinematic's settle beat and
-- the throw it schedules, without the timeline).
local function play(outcomes)
    local busted = (not outcomes[1]) and 1 or (not outcomes[2]) and 2 or (not outcomes[3]) and 3 or nil
    ss.gauntlet = { result = { outcomes = outcomes, won = outcomes[3] == true, busted_at = busted } }
    ss._settled = false
    ss.deck_flyer = nil
    state.shove_pending = { chips = 1, anti_chips = 0 }
    ss:settleRun()
    ss:throwFlyer()
end

-- loss
play({ false, false, false })
c.ok(state.demo_ended ~= true, "an R1 loss ends nothing")
c.ok(ss.deck_flyer == nil, "and throws no flyer")

-- ending
play({ true, false, false })
c.ok(state.demo_ended == true, "win R1, lose R2: the demo has ended")
c.ok(state.shove_r1_won ~= true and state.shove_r2_won ~= true, "no act flag is recorded in the demo")
c.ok(ss:_milestoneFor(ss.gauntlet.result) == nil, "no act-break milestone either")
c.ok(not Decks.systemUnlocked(state), "decks stay locked")
c.ok(ss.deck_flyer ~= nil and ss.deck_flyer.demo == true, "the flyer lands with the demo's inside")

-- flyer
local fl = ss.deck_flyer
if fl then
    local ok, err = pcall(function() fl:draw() end)
    c.ok(ok, "the flyer draws closed on the felt: " .. tostring(err))
    fl._throw_t = 1
    fl:draw()
    c.ok(fl:isLanded(), "it lands, folded")
    fl:openFromFelt()
    fl._open_t = 1
    ok, err = pcall(function() fl:draw() end)
    c.ok(ok, "the demo page draws: " .. tostring(err))
    c.ok(fl._demo_sticker ~= nil, "with the WISHLIST sticker (a store page is set)")
    c.eq(#fl._tiles, 0, "and no deck tiles")
    local st = fl._demo_sticker
    if st then
        fl:consumeMouse(st.x + 1, st.y + 1, 1)
        c.ok(#opened == 1 and opened[1]:find("utm_source=demo", 1, true) ~= nil,
             "the sticker opens the store page with the demo's utm (" .. tostring(opened[1]) .. ")")
        c.ok(fl:isOpen(), "and the flyer stays open")
    end
    fl:consumeMouse(-5, -5, 1)
    c.ok(not fl:isOpen(), "a click off the sheet folds it back")
    Constants.STEAM_URL = ""
    fl:openFromFelt(); fl._open_t = 1
    fl:draw()
    c.ok(fl._demo_sticker == nil, "no store page, no sticker")
    Constants.STEAM_URL = "https://store.steampowered.com/app/1"
end

-- again
play({ true, false, false })
c.ok(ss.deck_flyer ~= nil and ss.deck_flyer.demo == true, "the next shove throws the flyer again")

-- save
local in_meta = false
for _, k in ipairs(GameState.META_KEYS) do if k == "demo_ended" then in_meta = true end end
c.ok(in_meta, "demo_ended rides the meta")

-- full
Constants.FEATURES.DEMO_CUT = false
Constants.FEATURES.DECKS    = true
state.demo_ended = false
play({ true, false, false })
c.ok(state.shove_r1_won == true, "outside the demo the same shove opens Act 2")
c.ok(ss.deck_flyer ~= nil and not ss.deck_flyer.demo, "and the flyer is the roster")
c.ok(state.demo_ended ~= true, "and nothing ends")

Constants.FEATURES.DEMO_CUT = was.cut
Constants.FEATURES.DECKS    = was.decks
Constants.STEAM_URL         = was.url
local fails = c.report("smoke_demo_end")
if fails > 0 then os.exit(1) end
