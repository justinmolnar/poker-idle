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
local ChipPile        = require("views.ChipPile")
local ClickFlash      = require("services.ClickFlash")
local Tooltip         = require("services.Tooltip")
local Ghosts          = require("services.Ghosts")
local AnchorRegistry  = require("services.AnchorRegistry")
local ShaderRegistry  = require("services.ShaderRegistry")
local HandAnalytics   = require("services.HandAnalytics")

local Theme         = require("views.Theme")
local ThemeData     = require("data.theme")

local StateMachine    = require("controllers.StateMachine")
local InputController = require("controllers.InputController")

local GameState        = require("models.GameState")
local Decks            = require("models.Decks")
local PokerEffects     = require("models.poker_effects")
local DeckXpRules      = require("models.deck_xp_rules")
local DeckUnlockRules  = require("models.deck_unlock_rules")
local CatalogUnlockRules = require("models.catalog_unlock_rules")
local HintController  = require("controllers.HintController")
local HintView        = require("views.HintView")
local HintRules        = require("models.hint_rules")
local PokerActionApply = require("models.poker_action_apply")
local GrindState   = require("states.GrindState")
local ShoveState   = require("states.ShoveState")
local CreditsState = require("states.CreditsState")
local TitleState   = require("states.TitleState")
local RoomState    = require("states.RoomState")

local Game = nil

-- ── Fixed-resolution rendering + sharp-bilinear scaling ─────────────────────
-- A pixel font can't be rasterized at fractional sizes without artifacts
-- (nearest → uneven strokes, antialias → gridlines). So the game renders ONCE
-- at a fixed base resolution with the crisp 1-bit pixel font into a canvas, and
-- that finished IMAGE is scaled to the window through a sharp-bilinear shader:
-- each source pixel stays hard with only a ~1px antialiased seam at its edge.
-- Crisp at ANY window size — no gridlines (we scale an image, not glyphs) and
-- no uneven strokes (the whole frame scales uniformly). Standard pixel-art tech.
--
-- getDimensions/getWidth/getHeight report the base size so layout stays in base
-- space; mouse coords map back through the fit. Scissor needs no override — the
-- game draws into the base-sized canvas, so clip rects are already base coords.
local BASE_W, BASE_H = 1600, 900
local _realDimensions = love.graphics.getDimensions
local _realGetPos     = love.mouse.getPosition
local _frameCanvas, _scaleShader

-- Uniform fit scale + centering offset that maps the base frame onto the window.
local function fitTransform()
    local ww, wh = _realDimensions()
    if ww == 0 or wh == 0 then return 1, 0, 0 end
    local s = math.min(ww / BASE_W, wh / BASE_H)
    return s, (ww - BASE_W * s) / 2, (wh - BASE_H * s) / 2
end

love.graphics.getDimensions = function() return BASE_W, BASE_H end
love.graphics.getWidth      = function() return BASE_W end
love.graphics.getHeight     = function() return BASE_H end
love.mouse.getPosition = function()
    local x, y = _realGetPos()
    local s, ox, oy = fitTransform()
    return (x - ox) / s, (y - oy) / s
end

-- Sharp-bilinear: bilinear sampling confined to a 1-output-pixel band at each
-- source-texel boundary, flat (hard) everywhere else. The canvas must use a
-- linear filter so Texture() interpolates. u_scale = output px per source px.
local SHARP_BILINEAR = [[
extern vec2 u_sourceSize;
extern vec2 u_scale;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 px) {
    vec2 texel        = uv * u_sourceSize;
    vec2 texelFloored = floor(texel);
    vec2 s            = fract(texel);
    vec2 regionRange  = vec2(0.5) - vec2(0.5) / u_scale;
    vec2 centerDist   = s - vec2(0.5);
    vec2 f = (centerDist - clamp(centerDist, -regionRange, regionRange)) * u_scale + vec2(0.5);
    return Texel(tex, (texelFloored + f) / u_sourceSize) * color;
}
]]

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
    -- Fonts scale as a smooth float with the window (antialiased TTF, so any
    -- size rasterizes cleanly). love.resize rebuilds the table in place at the
    -- new window size so the atlas is always rasterized at its display size.
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
    -- Chip faces print in the game font like every other string. They used
    -- to build their own default-typeface font, which is why they were the
    -- one bit of text in the game that didn't match anything around it.
    require("views.Chips").configureFont(g.fonts)
    -- Same reason: a card too small for its sprite falls back to a plate with
    -- its rank as one glyph, and that glyph is the game font.
    require("views.CardSprites").configure(g.fonts)
    require("views.FeltDecor").configure(g.fonts)
    require("views.ShoveDecor").configure(g.fonts)

    -- Transient debug toggles (not persisted). Backtick (`) toggles
    -- the per-table tooltip overlay; see InputController and TablePanel.
    -- payout_shape: 0 = off, else an index into
    -- TablePanelStats.PAYOUT_SHAPES. Cycled with F3.
    g.debug = { overlay = false, payout_shape = 0, perf = false }
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

    -- Apply persisted settings.
    local prefs = g.save_service:loadSettings() or {}
    if type(prefs.volume) == "number" then
        SoundService.setMasterVolume(prefs.volume)
    end
    g.settings = {
        volume            = SoundService.getMasterVolume(),
        analytics_consent = prefs.analytics_consent == true,  -- nil → false
    }

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
    -- Catalog items reuse the same registry — adds total_*/chips-banked kinds
    -- on top of the deck-registered lifetime_* kinds (see catalog_unlock_rules).
    CatalogUnlockRules.registerAll(g.unlock_rules)

    -- Check and sync deck unlocks immediately at boot time using the loaded save data.
    Decks.checkPendingUnlocks(g.state, g.unlock_rules)

    -- Same-shape registry for tutorial-hint trigger/done conditions.
    -- Separate instance from g.unlock_rules — hint kinds check against
    -- a { state, pool } ctx, not the bare GameState.
    g.hint_rules = UnlockRegistry:new()
    HintRules.registerAll(g.hint_rules)

    -- The tutorial layer, owned here so it exists on every screen and draws
    -- above every modal. It used to belong to GrindState and render inside
    -- GrindView's draw, which put it under the catalog and deck select and
    -- off the shove felt entirely: the three surfaces that most needed
    -- explaining were the three it could not reach.
    g.hints     = HintController:new(g)
    g.hint_view = HintView:new(g)

    -- Same-shape registry for poker-event applicators (post_blind,
    -- fold, call, raise, etc.). Used by both the script writer
    -- (models/HandScript.lua) at write-time and the cinematic walker
    -- (models/Table.lua) at play-time. Engine-agnostic; poker kinds
    -- register from models/poker_action_apply.
    g.poker_events = PokerEventRegistry:new()
    PokerActionApply.registerAll(g.poker_events)

    g.state_machine = StateMachine:new(g)

    -- Screen-level facts for hint conditions that no controller owns: which
    -- screen is up, where the shove's beat machine is, whether a modal that
    -- doubles as a teaching surface is open. Read fresh each tick.
    g.hints.ctx_extra = function()
        local sm  = g.state_machine
        local cur = sm and sm.current_state
        local sv  = cur and cur.view
        local is_shove = sm and sm:current() == "shove"
        return {
            screen           = sm and sm:current() or nil,
            shove_phase      = is_shove and sv and sv.phase or nil,
            shove_hold       = is_shove and sv and sv.hold_id or nil,
            shove_cheats     = is_shove and sv and sv.cheatsDealt and sv:cheatsDealt() or 0,
            catalog_open     = cur and (cur.catalog_modal ~= nil) or false,
            deck_select_open = cur and ((cur.deck_select_modal or cur.deck_roster_modal) ~= nil) or false,
        }
    end
    g.state_machine:register("grind",   GrindState:new(g))
    g.state_machine:register("shove",   ShoveState:new(g))
    g.state_machine:register("credits", CreditsState:new(g))
    g.state_machine:register("title",   TitleState:new(g))
    g.state_machine:register("room",    RoomState:new(g))

    g.startNewGame = function()
        g.save_service:clearAll()
        g.state:wipeAll()
        if g.settings then
            g.settings.analytics_consent = false
            g.save_service:saveSettings(g.settings)
        end
        for _, st in pairs(g.state_machine.states) do
            if type(st) == "table" and type(st.fullReset) == "function" then
                st:fullReset()
            end
        end
        g.state_machine:switch("grind")
    end

    g.input_dispatcher = InputDispatcher:new()
    g.input_controller = InputController:new(g)

    -- Hint-layer clicks are claimed here, ahead of both dispatcher branches
    -- below, so no state has to know the layer exists. The dispatcher fires
    -- the first handler whose predicate passes and stops: an [i] icon click
    -- dismisses that hint, the sticky bubble dismisses itself, and anything
    -- else falls through to the state exactly as before.
    g.input_dispatcher:on("mousepressed",
        function(x, y)
            local cur = g.state_machine.current_state
            if cur and cur.hintsBlocked and cur:hintsBlocked() then return false end
            return g.hint_view:mousepressed(x, y) ~= nil
        end,
        function(x, y)
            local hit = g.hint_view:mousepressed(x, y)
            if hit == "bubble" then g.hints:dismissActive()
            elseif hit then g.hints:dismissQueued(hit.id) end
        end)

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
    ShaderRegistry.loadFromFile("dirty", "shaders/dirty.frag")
    ShaderRegistry.loadFromFile("foil", "shaders/foil.frag")
    ShaderRegistry.loadFromFile("pulse_glow", "shaders/pulse_glow.frag")
    ShaderRegistry.loadFromFile("hologram", "shaders/hologram.frag")
    ShaderRegistry.loadFromFile("rainbow_shift", "shaders/rainbow_shift.frag")
    ShaderRegistry.loadFromFile("pixel_glitch", "shaders/pixel_glitch.frag")

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
    -- Hints tick after the state so they read this frame's facts. A state
    -- may ask for quiet (a menu is up) through the duck-typed hintsBlocked.
    do
        local cur = Game.state_machine.current_state
        if not (cur and cur.hintsBlocked and cur:hintsBlocked()) then
            Game.hints:update(dt)
        end
    end
    Game.floating_text.update(dt)
    FlightSystem.update(dt)
    ChipPile.update(dt)
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
                                  or s.prototype_end_modal
                                  or s.deck_select_modal
                                  or s.onboarding_modal)
        if (cur == "grind" or cur == "shove") and not idle_modal then
            autosave_timer = autosave_timer + dt
            if autosave_timer >= AUTOSAVE_INTERVAL then
                autosave_timer = 0
                local state = Game.state
                Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
                HandAnalytics.flush(state, Game.settings and Game.settings.analytics_consent)
            end
        end
    end
end

-- Dev perf HUD (F4). Read the stats BEFORE drawing anything here, so the
-- numbers describe the game's frame and not this overlay.
--
-- drawcallsbatched is the one worth watching: it is how many of those calls
-- LOVE managed to merge, and a chip-rendering change that quietly breaks
-- batching shows up here and nowhere else.
local function drawPerfHud()
    local st = love.graphics.getStats()
    local Chips = require("views.Chips")
    local n_chips, s_min, s_max = Chips.frameStats()

    local font = Game.fonts and Game.fonts.sm
    local prev = love.graphics.getFont()
    if font then love.graphics.setFont(font) end

    local lines = {
        string.format("fps           %d", love.timer.getFPS()),
        string.format("draw calls    %d", st.drawcalls or 0),
        string.format("batched       %d", st.drawcallsbatched or 0),
        string.format("chips         %d", n_chips),
        string.format("chip scale    %.2f - %.2f", s_min, s_max),
        string.format("texture mem   %.1f MB", (st.texturememory or 0) / 1048576),
    }

    local lh = font and font:getHeight() or 10
    local w, h = 190, lh * #lines + 12
    local x, y = 8, 8
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle("fill", x, y, w, h, 3)
    love.graphics.setColor(0.55, 0.85, 1.00, 1)
    for i, line in ipairs(lines) do
        love.graphics.print(line, x + 6, y + 6 + (i - 1) * lh)
    end
    if prev then love.graphics.setFont(prev) end
end

function love.draw()
    if not _frameCanvas then
        _frameCanvas = love.graphics.newCanvas(BASE_W, BASE_H)
        _frameCanvas:setFilter("linear", "linear")   -- shader needs bilinear sampling
        _scaleShader = love.graphics.newShader(SHARP_BILINEAR)
    end

    -- Render the game into the fixed base-resolution canvas (crisp, 1:1).
    -- Anchor frame-stamp advances first so anchors registered during this
    -- draw read age 0 and stale ones (widget no longer drawn) age up.
    AnchorRegistry.tick()
    love.graphics.setCanvas(_frameCanvas)
    love.graphics.clear(love.graphics.getBackgroundColor())
    Game.state_machine:draw()
    -- The hint layer, above whatever the state drew including its modals.
    -- Still inside the base canvas so it scales with the frame.
    do
        local cur = Game.state_machine.current_state
        if not (cur and cur.hintsBlocked and cur:hintsBlocked()) then
            Game.hint_view:draw(Game.hints:activeHint(), Game.hints:queuedHints())
        end
    end
    if Game.debug and Game.debug.perf then drawPerfHud() end
    love.graphics.setCanvas()

    -- Scale the finished frame to the window via the sharp-bilinear shader.
    local s, ox, oy = fitTransform()
    _scaleShader:send("u_sourceSize", { BASE_W, BASE_H })
    _scaleShader:send("u_scale",      { s, s })
    love.graphics.setShader(_scaleShader)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(_frameCanvas, ox, oy, 0, s, s)
    love.graphics.setShader()
end

function love.keypressed(key)    Game.input_dispatcher:dispatch("keypressed",   key)         end
function love.keyreleased(key)   Game.input_dispatcher:dispatch("keyreleased",  key)         end

function love.mousepressed(x, y, b)    local s, ox, oy = fitTransform(); Game.input_dispatcher:dispatch("mousepressed",  (x-ox)/s, (y-oy)/s, b)          end
function love.mousereleased(x, y, b)   local s, ox, oy = fitTransform(); Game.input_dispatcher:dispatch("mousereleased", (x-ox)/s, (y-oy)/s, b)          end
function love.mousemoved(x, y, dx, dy) local s, ox, oy = fitTransform(); Game.input_dispatcher:dispatch("mousemoved", (x-ox)/s, (y-oy)/s, dx/s, dy/s)    end
function love.textinput(text)    Game.input_dispatcher:dispatch("textinput",    text)        end
function love.wheelmoved(x, y)   Game.input_dispatcher:dispatch("wheelmoved",   x, y)        end

function love.resize(w, h)
    if not Game then return end
    -- The game always lays out at the base resolution; the canvas+shader handle
    -- fitting to the window. Use the (fixed) base dims, ignore the window size.
    w, h = love.graphics.getDimensions()
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
    require("views.Chips").configureFont(Game.fonts)
    require("views.CardSprites").configure(Game.fonts)
    require("views.FeltDecor").configure(Game.fonts)
    require("views.ShoveDecor").configure(Game.fonts)

    if Game.state_machine then
        Game.state_machine:resize(w, h)
    end
end

function love.quit()
    -- Flush one final save so anything between the last autosave tick and
    -- quit doesn't get lost. Skip from the menu-class states (no useful
    -- run state to commit).
    if Game then
        HandAnalytics.flush(Game.state, Game.settings and Game.settings.analytics_consent)
        local current = Game.state_machine and Game.state_machine:current()
        if current == "grind" or current == "shove" then
            local state = Game.state
            Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
        end
    end
end
