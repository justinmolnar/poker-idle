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
local FlightSystem    = require("services.FlightSystem")
local ClickFlash      = require("services.ClickFlash")
local Tooltip         = require("services.Tooltip")
local Ghosts          = require("services.Ghosts")
local AnchorRegistry  = require("services.AnchorRegistry")
local ShaderRegistry  = require("services.ShaderRegistry")

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

    -- Stateful or instance-backed services live on the DI container so
    -- consumers reach them via `self.game.foo`.
    g.sounds          = SoundService
    g.animations      = AnimationSystem
    g.floating_text   = FloatingText
    g.hover           = HoverService

    -- Stateless module-singleton services (CursorPool, FlightSystem,
    -- ClickFlash, Tooltip, Ghosts, AnchorRegistry) are NOT registered on
    -- the DI container. They're file-local-state singletons; consumers
    -- require them directly. Putting them on `g` would create two parallel
    -- access paths (DI + require) for the same shared state — a subtle
    -- form of fake DI. main.lua references them through the locals at
    -- the top of the file for the per-frame update/draw plumbing below.

    -- Viewport dimensions, refreshed in love.resize. Non-view layers
    -- (controllers, services) read from here instead of querying
    -- love.graphics directly so the rendering subsystem isn't a
    -- silent global dependency for non-rendering code.
    local vw, vh      = love.graphics.getDimensions()
    g.viewport        = { w = vw, h = vh }

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

    -- Compile shaders at boot. ShaderRegistry caches by name; compile
    -- failures log a warning and degrade gracefully (no crash).
    ShaderRegistry.loadFromFile("radial_glow", "shaders/radial_glow.frag")

    if Constants.DEBUG.START_IN_SHOVE then
        Game.state_machine:switch("shove")
    else
        Game.state_machine:switch("grind")
    end

    print("[main] Poker Idle booted. Active state: " .. tostring(Game.state_machine:current()))
end

function love.update(dt)
    -- Reset per-frame hover + tooltip state before any hit-tests run. Things
    -- that own hoverable regions (Panel:updateHover, ComponentRenderer.hitTest,
    -- GrindView's hit_box walk) write to these during this update; draws
    -- read them after.
    HoverService.clear()
    Tooltip.clear()

    Game.time:update(dt)
    Game.state_machine:update(dt)
    Game.floating_text.update(dt)
    FlightSystem.update(dt)
    ClickFlash.update(dt)
    Ghosts.update(dt)
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
    if Game then
        if Game.viewport then
            Game.viewport.w, Game.viewport.h = w, h
        end
        if Game.state_machine then
            Game.state_machine:resize(w, h)
        end
    end
end

function love.quit()
    -- No save on quit. Disk only changes through explicit F5 / F7 actions.
end
