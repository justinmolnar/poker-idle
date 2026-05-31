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
local EffectsRegistry    = require("services.EffectsRegistry")
local XpRuleRegistry     = require("services.XpRuleRegistry")
local UnlockRegistry     = require("services.UnlockRegistry")
local PokerEventRegistry = require("services.PokerEventRegistry")
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

local GameState        = require("models.GameState")
local PokerEffects     = require("models.poker_effects")
local DeckXpRules      = require("models.deck_xp_rules")
local DeckUnlockRules  = require("models.deck_unlock_rules")
local PokerActionApply = require("models.poker_action_apply")
local GrindState   = require("states.GrindState")
local ShoveState   = require("states.ShoveState")
local CreditsState = require("states.CreditsState")
local TitleState   = require("states.TitleState")

local Game = nil

-- Periodic auto-save accumulator. Only ticks while we're inside the
-- gameplay states (not title/credits) and no menu-class modal is up.
-- Persisted in love.update; reset whenever a save fires.
local autosave_timer = 0
local AUTOSAVE_INTERVAL = 10  -- seconds

local function buildGame()
    local g = {
        C       = Constants,
        catalog = Catalog,
        run_upgrades = RunUpgrades,
    }

    g.theme           = Theme
    -- Fonts scale by an integer factor based on the current window
    -- (1× at 1280×720, 2× at 2560×1440, 3× at 3840×2160). main.lua's
    -- love.resize rebuilds the table in place on window changes.
    local _vw, _vh    = love.graphics.getDimensions()
    g.fonts           = FontService.build(ThemeData.font, _vw, _vh)
    -- Float layout scale exposed on the DI container so any view can
    -- multiply its hardcoded design-space constants by it. Updated on
    -- resize. Use this for card / chip / button sizes that should
    -- grow proportionally with the window.
    g.ui_scale        = FontService.layoutScale(_vw, _vh)
    -- Rescale procedural rendering against the live ui_scale.
    require("views.Chips").setScale(g.ui_scale)
    require("views.ComponentRenderer").setScale(g.ui_scale)
    require("views.widgets.ConfirmDialog").setScale(g.ui_scale)
    require("views.widgets.Slider").setScale(g.ui_scale)

    -- Pixel-font sizing affects layout. Configure layout-bearing
    -- modules (Panel header height, ComponentRenderer LINE_H,
    -- CatalogModal card heights) from the active fonts so they
    -- match whatever sizes data/theme.lua picked.
    require("views.Panel").configureFromFonts(g.fonts)
    require("views.ComponentRenderer").configureFromFonts(g.fonts)
    require("views.CatalogModal").configureFromFonts(g.fonts)
    require("views.SettingsModal").configureFromFonts(g.fonts)

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

    -- Apply persisted settings (volume only).
    local prefs = g.save_service:loadSettings()
    if prefs and type(prefs.volume) == "number" then
        SoundService.setMasterVolume(prefs.volume)
    end

    g.effects = EffectsRegistry:new()
    PokerEffects.registerAll(g.effects)

    -- Same-shape registry for deck XP rules. Engine-agnostic skeleton
    -- (services/XpRuleRegistry); poker-specific kinds register from
    -- models/deck_xp_rules. Mirrors the effects-registry pairing.
    g.xp_rules = XpRuleRegistry:new()
    DeckXpRules.registerAll(g.xp_rules)

    -- Same-shape registry for deck unlock conditions. Each registered
    -- kind compares a lifetime counter on state against a threshold on
    -- the spec's `unlock` block. Liftable into another idle game by
    -- swapping the kinds registered from models/deck_unlock_rules.
    g.unlock_rules = UnlockRegistry:new()
    DeckUnlockRules.registerAll(g.unlock_rules)

    -- Same-shape registry for poker-event applicators (post_blind,
    -- fold, call, raise, etc.). Used by both the script writer
    -- (models/HandScript.lua) at write-time and the cinematic walker
    -- (models/Table.lua) at play-time. Engine-agnostic; poker kinds
    -- register from models/poker_action_apply.
    g.poker_events = PokerEventRegistry:new()
    PokerActionApply.registerAll(g.poker_events)

    g.state_machine = StateMachine:new(g)
    g.state_machine:register("grind",   GrindState:new(g))
    g.state_machine:register("shove",   ShoveState:new(g))
    g.state_machine:register("credits", CreditsState:new(g))
    g.state_machine:register("title",   TitleState:new(g))

    g.input_dispatcher = InputDispatcher:new()
    g.input_controller = InputController:new(g)
    if not Constants.FEATURES.DEV_HOTKEYS then
        -- All DEV hotkeys (F2/F6/F7/backtick/-/=) are skipped — none
        -- of those dispatcher predicates run. But keypressed still
        -- forwards to the active state so modal-class keys like SPACE
        -- (continue), ENTER, and ESC keep working for normal UX.
        local sm = g.state_machine
        local d  = g.input_dispatcher
        d:on("keypressed",    nil, function(key)         sm:keypressed(key)         end)
        d:on("keyreleased",   nil, function(key)         sm:keyreleased(key)        end)
        d:on("mousepressed",  nil, function(x, y, b)     sm:mousepressed(x, y, b)   end)
        d:on("mousereleased", nil, function(x, y, b)     sm:mousereleased(x, y, b)  end)
        d:on("mousemoved",    nil, function(x, y, dx, dy) sm:mousemoved(x, y, dx, dy) end)
        d:on("textinput",     nil, function(text)        sm:textinput(text)         end)
        d:on("wheelmoved",    nil, function(x, y)        sm:wheelmoved(x, y)        end)
    else
        g.input_controller:wire()
    end

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
        Game.state_machine:switch("title")
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

    -- Periodic auto-save. Skip the menu-class states (title/credits) so
    -- we don't churn disk while the player sits at a static screen. Also
    -- skip while a "menu-class" modal is up over gameplay (catalog /
    -- prestige / prototype-end) — during a multi-minute post-bust catalog
    -- browse the autosave was firing every 10s and queueing JSON writes
    -- to Emscripten's IDBFS, then stalling the frame when the queue
    -- flushed on resume to grind. Counter resets on each save; love.quit
    -- flushes unconditionally so anything not yet persisted lands on exit.
    do
        local sm  = Game.state_machine
        local cur = sm:current()
        local s   = sm.current_state
        local idle_modal = s and (s.catalog_modal
                                  or s.prestige_modal
                                  or s.prototype_end_modal
                                  or s.deck_select_modal
                                  or s.onboarding_modal)
        if (cur == "grind" or cur == "shove") and not idle_modal then
            autosave_timer = autosave_timer + dt
            if autosave_timer >= AUTOSAVE_INTERVAL then
                autosave_timer = 0
                local state = Game.state
                Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
            end
        end
    end
end

function love.draw()
    Game.state_machine:draw()
end

function love.keypressed(key)    Game.input_dispatcher:dispatch("keypressed",   key)         end
function love.keyreleased(key)   Game.input_dispatcher:dispatch("keyreleased",  key)         end

function love.mousepressed(x, y, b)    Game.input_dispatcher:dispatch("mousepressed",  x, y, b)    end
function love.mousereleased(x, y, b)   Game.input_dispatcher:dispatch("mousereleased", x, y, b)    end
function love.mousemoved(x, y, dx, dy) Game.input_dispatcher:dispatch("mousemoved", x, y, dx, dy)  end
function love.textinput(text)    Game.input_dispatcher:dispatch("textinput",    text)        end
function love.wheelmoved(x, y)   Game.input_dispatcher:dispatch("wheelmoved",   x, y)        end

function love.resize(w, h)
    if not Game then return end
    if Game.viewport then
        Game.viewport.w, Game.viewport.h = w, h
    end

    -- Rebuild fonts at the new integer scale + re-run the
    -- configureFromFonts hooks so layout-bearing modules
    -- (Panel.TAB_BAR_H, ComponentRenderer LINE_H, modal sizes)
    -- recompute against the new font heights.
    local ThemeData = require("data.theme")
    FontService.rebuildInto(Game.fonts, ThemeData.font, w, h)
    Game.ui_scale = FontService.layoutScale(w, h)
    require("views.Chips").setScale(Game.ui_scale)
    require("views.ComponentRenderer").setScale(Game.ui_scale)
    require("views.widgets.ConfirmDialog").setScale(Game.ui_scale)
    require("views.widgets.Slider").setScale(Game.ui_scale)
    require("views.Panel").configureFromFonts(Game.fonts)
    require("views.ComponentRenderer").configureFromFonts(Game.fonts)
    require("views.CatalogModal").configureFromFonts(Game.fonts)
    require("views.SettingsModal").configureFromFonts(Game.fonts)

    if Game.state_machine then
        Game.state_machine:resize(w, h)
    end
end

function love.quit()
    -- Flush one final save so anything between the last autosave tick and
    -- quit doesn't get lost. Skip from the menu-class states (no useful
    -- run state to commit).
    if Game then
        local current = Game.state_machine and Game.state_machine:current()
        if current == "grind" or current == "shove" then
            local state = Game.state
            Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
        end
    end
end
