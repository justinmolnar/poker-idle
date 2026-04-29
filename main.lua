-- main.lua
--
-- Bootstrap. Builds the DI container, wires services, registers states with
-- the StateMachine, hooks LÖVE callbacks through the InputDispatcher.
--
-- No globals. The DI table is a file-local upvalue here; LÖVE callbacks close
-- over it. Every other module receives it through its constructor — never
-- reach into this file's `Game` from elsewhere.

local Constants     = require("data.constants")
local Catalog       = require("data.catalog")
local RunUpgrades   = require("data.run_upgrades")

local EventBus      = require("core.event_bus")
local Time          = require("core.time")
local Camera        = require("core.camera")

local InputDispatcher = require("lib.input_dispatcher")

local SaveService     = require("services.SaveService")
local SoundService    = require("services.SoundService")
local SpriteLoader    = require("services.SpriteLoader")
local AnimationSystem = require("services.AnimationSystem")
local FloatingText    = require("services.FloatingTextSystem")
local EffectsRegistry = require("services.EffectsRegistry")
local FontService     = require("services.FontService")
local HoverService    = require("services.HoverService")
local CursorPool      = require("services.CursorPool")

local Theme         = require("views.Theme")
local ThemeData     = require("data.theme")

local StateMachine    = require("controllers.StateMachine")
local InputController = require("controllers.InputController")

local GameState    = require("models.GameState")
local PokerEffects = require("models.poker_effects")
local GrindState   = require("states.GrindState")
local ShoveState   = require("states.ShoveState")
local CreditsState = require("states.CreditsState")

local Game = nil
-- Auto-save was here. Disabled by request — manual F5/F6/F7 only so debug
-- experiments don't get committed to disk between intentional saves.

local function buildGame()
    local g = {
        C       = Constants,
        catalog = Catalog,
        run_upgrades = RunUpgrades,
    }

    g.theme           = Theme
    g.fonts           = FontService.build(ThemeData.font)

    -- Transient debug toggles (not persisted). Backtick (`) toggles
    -- the per-table tooltip overlay; see InputController and TablePanel.
    g.debug = { overlay = false }
    g.event_bus       = EventBus
    g.time            = Time:new()
    g.camera          = Camera:new(0, 0, 1)
    g.sprite_loader   = SpriteLoader:new()
    g.sounds          = SoundService
    g.animations      = AnimationSystem
    g.floating_text   = FloatingText
    g.hover           = HoverService
    g.cursor_pool     = CursorPool

    g.save_service    = SaveService:new()
    local saved       = g.save_service:loadAll()
    g.state           = GameState:new(saved)

    g.effects = EffectsRegistry:new()
    PokerEffects.registerAll(g.effects)

    g.state_machine = StateMachine:new(g)
    g.state_machine:register("grind",   GrindState:new(g))
    g.state_machine:register("shove",   ShoveState:new(g))
    g.state_machine:register("credits", CreditsState:new(g))

    g.input_dispatcher = InputDispatcher:new()
    g.input_controller = InputController:new(g)
    g.input_controller:wire()

    return g
end

function love.load()
    Game = buildGame()
    Game.sprite_loader:loadAll()

    if Constants.DEBUG.START_IN_SHOVE then
        Game.state_machine:switch("shove")
    else
        Game.state_machine:switch("grind")
    end

    print("[main] Poker Idle booted. Active state: " .. tostring(Game.state_machine:current()))
end

function love.update(dt)
    -- Reset per-frame hover state before any hit-tests run. Things that own
    -- hoverable regions (Panel:updateHover, ComponentRenderer.hitTest) write
    -- to it during this update; draws read it after.
    HoverService.clear()

    Game.time:update(dt)
    Game.state_machine:update(dt)
    Game.floating_text.update(dt)
    -- No auto-save. Use F5 to save manually, F6 to reload, F7 to wipe.
end

function love.draw()
    Game.state_machine:draw()
end

function love.keypressed(key)    Game.input_dispatcher:dispatch("keypressed",   key)         end
function love.keyreleased(key)   Game.input_dispatcher:dispatch("keyreleased",  key)         end
function love.mousepressed(x,y,b) Game.input_dispatcher:dispatch("mousepressed",  x, y, b)   end
function love.mousereleased(x,y,b) Game.input_dispatcher:dispatch("mousereleased", x, y, b)  end
function love.mousemoved(x,y,dx,dy) Game.input_dispatcher:dispatch("mousemoved", x, y, dx, dy) end
function love.textinput(text)    Game.input_dispatcher:dispatch("textinput",    text)        end
function love.wheelmoved(x, y)   Game.input_dispatcher:dispatch("wheelmoved",   x, y)        end

function love.resize(w, h)
    -- Forwards to the active state. States that own anchored layout (sidebar
    -- Panels) implement :resize(w, h) to rebuild internal rects; states that
    -- read getDimensions() per-frame ignore.
    if Game and Game.state_machine then
        Game.state_machine:resize(w, h)
    end
end

function love.quit()
    -- No save on quit. Disk only changes through explicit F5 / F7 actions.
end
