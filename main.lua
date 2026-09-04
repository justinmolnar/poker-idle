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

local EventBus      = require("services.EventBus")
local Time          = require("core.time")
local Camera        = require("core.camera")

local InputDispatcher = require("lib.input_dispatcher")

local SaveService     = require("services.SaveService")
local SoundService    = require("services.SoundService")
local SoundLoader     = require("services.SoundLoader")
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
local ItemGhosts      = require("views.ItemGhosts")
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
local ProcRegistry     = require("services.ProcRegistry")
local TableProcs       = require("models.table_procs")
local DeckXpRules      = require("models.deck_xp_rules")
local DeckUnlockRules  = require("models.deck_unlock_rules")
local CatalogUnlockRules = require("models.catalog_unlock_rules")
local CatalogLoader = require("models.catalog_loader")
-- The catalog is authored data; its prices are arithmetic. Derive them the
-- moment it is loaded, so nothing can ever read an authored cost by
-- accident. Module tables are cached, so every later require sees this.
CatalogLoader.deriveAll(Catalog)
local HintController  = require("controllers.HintController")
local HintView        = require("views.HintView")
local HintRules        = require("models.hint_rules")
local HintCtx          = require("controllers.hint_ctx")
local StoryDirector    = require("controllers.StoryDirector")
local StoryView        = require("views.StoryView")
local HintMarks        = require("views.HintMarks")
local RadioVoice       = require("services.RadioVoice")
local MusicDirector    = require("services.MusicDirector")
local AudioDevice      = require("services.AudioDevice")
local Story            = require("data.story")
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
    g.event_bus       = EventBus:new()
    g.time            = Time:new()
    g.camera          = Camera:new(0, 0, 1)
    g.sprite_loader   = SpriteLoader:new()

    -- Stateful or instance-backed services live on the DI container so
    -- consumers reach them via `self.game.foo`.
    g.sounds          = SoundService
    -- Sounds are discovered like sprites: a file under assets/audio pairs
    -- with whatever shares its name (sprite aliases followed).
    g.sound_loader    = SoundLoader:new()
    g.sound_loader:loadAll()
    SoundService.attachLoader(g.sound_loader, g.sprite_loader)
    -- An item doing its job is heard: its own sound (the file that shares
    -- its name), damaged if the item is corrupted.
    g.event_bus:subscribe("item_fired", function(e)
        local mix = require("data.sounds")._mix
        local rule = (mix and mix.item_fire) or {}
        local damaged = false
        for _, id in ipairs(g.state.corrupted_items or {}) do
            if id == e.item_id then damaged = true end
        end
        SoundService.playNamed(e.item_id, { volume_mult = rule.volume or 0.5,
                                            min_gap = rule.min_gap, damaged = damaged })
        -- ...and seen: the item's sprite pops over the table that fired it,
        -- because most of the foley reads alike.
        ItemGhosts.spawn(g, e.item_id, e.x, e.y, e.pw, e.ph)
    end)
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
    if type(prefs.sfx_volume) == "number" then
        SoundService.setSfxVolume(prefs.sfx_volume)
    end
    if type(prefs.music_volume) == "number" then
        SoundService.setMusicVolume(prefs.music_volume)
    end
    g.settings = {
        volume            = SoundService.getMasterVolume(),
        sfx_volume        = SoundService.getSfxVolume(),
        music_volume      = SoundService.getMusicVolume(),
        -- Tri-state on purpose: nil = never asked. Coercing nil to false
        -- here made GrindState's first-run consent ask unreachable, so the
        -- modal never showed and web analytics silently never sent.
        analytics_consent = prefs.analytics_consent,
    }

    g.effects = EffectsRegistry:new()
    PokerEffects.registerAll(g.effects)
    -- Fill-scaled upgrade prices are derived from the ladder + outcome
    -- model, once, before anything reads a cost.
    require("models.UpgradePricing").apply(RunUpgrades, g.effects)

    -- Proc dispatch: "when X happens, do Y to Z". Same split as above —
    -- engine-agnostic registry (services/ProcRegistry), poker-specific
    -- selectors and payloads from models/table_procs, descriptors in
    -- data/procs.lua.
    g.procs = ProcRegistry:new(love.math.random, g.event_bus)
    TableProcs.registerAll(g.procs)

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

    -- The House's story beats (data/story.lua): ordered, one at a time,
    -- spoken in each screen's story band. Same condition registry as the
    -- hints. A finished beat saves, so a heard line stays heard.
    g.story = StoryDirector:new{
        game  = g,
        rules = g.hint_rules,
        story = Story,
        save  = function()
            g.save_service:saveAll(g.state:serializeMeta(), g.state:serializeRun())
        end,
    }
    g.story_view = StoryView:new(g)

    -- Same-shape registry for poker-event applicators (post_blind,
    -- fold, call, raise, etc.). Used by both the script writer
    -- (models/HandScript.lua) at write-time and the cinematic walker
    -- (models/Table.lua) at play-time. Engine-agnostic; poker kinds
    -- register from models/poker_action_apply.
    g.poker_events = PokerEventRegistry:new()
    PokerActionApply.registerAll(g.poker_events)

    g.state_machine = StateMachine:new(g)

    -- The ctx every condition kind evaluates against (controllers/hint_ctx):
    -- state, pool, and the screen-level facts no controller owns. Built
    -- once per tick and shared by the story director and the hints.
    g.hint_ctx = function()
        return HintCtx.build{
            game         = g,
            anchor_fresh = function(name) return AnchorRegistry.age(name) <= 1 end,
        }
    end
    g.state_machine:register("grind",   GrindState:new(g))
    g.state_machine:register("shove",   ShoveState:new(g))
    g.state_machine:register("credits", CreditsState:new(g))
    g.state_machine:register("title",   TitleState:new(g))
    g.state_machine:register("room",    RoomState:new(g))

    g.startNewGame = function()
        HandAnalytics.deleteCurrent()
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
        g.story:reset()
        g.state_machine:switch("grind")
    end

    g.input_dispatcher = InputDispatcher:new()
    g.input_controller = InputController:new(g)

    -- STORY LINES ARE MODAL. While a line is visible the game keeps
    -- simulating, but the PLAYER is paused: every gameplay click and key
    -- is consumed here, ahead of the hint layer and both state branches.
    -- A click (or SPACE) anywhere completes the typewriter, then advances
    -- the hold — comms must be actively cleared before play resumes. The
    -- one passthrough is a FORCED line's own targets: a click inside a
    -- fresh mark reaches the state, because that click IS the lesson.
    -- No fresh target, no lock — a forced line never dead-locks a screen.
    -- ESC always falls through (settings stay reachable; opening a menu
    -- pauses the beat). Wheel and hover are never consumed: scrolling a
    -- forced target back on screen must stay possible, and the forced
    -- hover lesson needs the pointer.
    local function storyUnblocked()
        local cur = g.state_machine.current_state
        return not (cur and cur.hintsBlocked and cur:hintsBlocked())
    end
    -- The line the player is looking at right now, or nil. Paused covers
    -- wrong-screen, band-missing, and a target mid-grace.
    local function storyVisibleLine()
        if not storyUnblocked() or g.story:isPaused() then return nil end
        return g.story:currentLine()
    end
    -- A click (or SPACE) mid-typewriter completes the block instead of
    -- advancing past it; the next one advances. On a forced line neither
    -- applies — the wait owns the release — so the click just dies here.
    local function storyAdvance()
        if g.story_view:isTyping() then g.story_view:revealAll()
        elseif g.story:isHoldingClick() then g.story:advance() end
    end
    g.input_dispatcher:on("mousepressed",
        function(x, y)
            local line = storyVisibleLine()
            if not line then return false end
            local forced = g.story:forcedLine()
            if forced then
                local marks = HintMarks.fresh(forced.anchor)
                if #marks == 0 then return false end
                local pad = math.floor(10 * (g.ui_scale or 1))
                for _, m in ipairs(marks) do
                    if x >= m.x - pad and x < m.x + m.w + pad
                       and y >= m.y - pad and y < m.y + m.h + pad then
                        return false
                    end
                end
            end
            return true
        end,
        storyAdvance)
    g.input_dispatcher:on("keypressed",
        function(key)
            return key ~= "escape" and storyVisibleLine() ~= nil
        end,
        function(key)
            if key == "space" then storyAdvance() end
        end)

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
            if g.hint_view:mousepressed(x, y) == "bubble" then
                g.hints:dismissActive()
            end
        end)

    if not Constants.FEATURES.DEV_HOTKEYS then
        -- All DEV hotkeys (F2/F6/F7/backtick/-/=/[/]) are skipped — none
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
    -- Bake THE HOUSE's wall portrait (procedural, views/HouseArt) into
    -- the sprite pool so the room draws it like any other wall item.
    require("views.HouseArt").bake(Game.sprite_loader)

    -- Compile shaders at boot. ShaderRegistry caches by name; compile
    -- failures log a warning and degrade gracefully (no crash).
    ShaderRegistry.loadFromFile("radial_glow", "shaders/radial_glow.frag")
    ShaderRegistry.loadFromFile("dirty", "shaders/dirty.frag")
    ShaderRegistry.loadFromFile("foil", "shaders/foil.frag")
    ShaderRegistry.loadFromFile("pulse_glow", "shaders/pulse_glow.frag")
    ShaderRegistry.loadFromFile("hologram", "shaders/hologram.frag")
    ShaderRegistry.loadFromFile("rainbow_shift", "shaders/rainbow_shift.frag")
    ShaderRegistry.loadFromFile("pixel_glitch", "shaders/pixel_glitch.frag")
    ShaderRegistry.loadFromFile("corrupted", "shaders/corrupted.frag")
    ShaderRegistry.loadFromFile("flame", "shaders/flame.frag")
    ShaderRegistry.loadFromFile("desaturate", "shaders/desaturate.frag")

    if Constants.DEBUG.START_IN_SHOVE then
        Game.state_machine:switch("shove")
    else
        Game.state_machine:switch("title")
    end

    do local M, m, r = love.getVersion(); print(("[main] LÖVE %d.%d.%d, audio device switching %s"):format(M, m, r, (love.audio and love.audio.setPlaybackDevice) and "ON" or "OFF (needs LÖVE 12)")) end
    print("[main] Poker Idle booted. Active state: " .. tostring(Game.state_machine:current()))
end

function love.update(dt)
    -- Follow Windows' default audio output (LÖVE 12; inert on 11).
    AudioDevice.tick(dt)
    -- Reset per-frame hover + tooltip state before any hit-tests run. Things
    -- that own hoverable regions (Panel:updateHover, ComponentRenderer.hitTest,
    -- GrindView's hit_box walk) write to these during this update; draws
    -- read them after.
    HoverService.clear()
    Tooltip.clear()
    -- Per-frame budget for the notification spine, reset alongside the
    -- other per-frame state above.
    Game.event_bus:beginFrame()

    Game.time:update(dt)
    Game.state_machine:update(dt)
    -- Deliver everything the frame's gameplay announced. Lives here rather
    -- than inside a controller because any state can publish: an item can
    -- fire during the shove or from the catalog, and its ghost should not
    -- have to wait for the grind loop to come back around. Drained BEFORE
    -- the ghost/flight/floater updates below so anything spawned by a
    -- subscriber animates on this frame.
    Game.event_bus:drain()
    -- The House ticks after the state so it reads this frame's facts. A
    -- state may ask for quiet (a menu is up) through the duck-typed
    -- hintsBlocked — but the story ALWAYS ticks so its triggers keep
    -- arming behind the menu; `blocked` only stops beats starting and
    -- the running beat's clock. Story first: while a beat runs, the
    -- hints are paused.
    do
        local cur = Game.state_machine.current_state
        local blocked = (cur and cur.hintsBlocked and cur:hintsBlocked()) or false
        local ctx = Game.hint_ctx()
        Game.story:update(dt, ctx, blocked)
        if not blocked then
            Game.hints.paused = Game.story:isActive()
            Game.hints:update(dt, ctx)
        end
        -- The intercom's chopped voice runs exactly while a block is
        -- typing itself out (services/RadioVoice; the cold open fires
        -- from StoryView the frame a new block lands).
        RadioVoice.update(dt, Game.story:isActive()
            and not Game.story:isPaused()
            and Game.story_view:isTyping())
    end
    -- The music layer: jazz through the intercom until the player owns
    -- speakers; cut by the House's voice, the gauntlet, and the menus.
    MusicDirector.update(dt, Game)
    Game.floating_text.update(dt)
    FlightSystem.update(dt)
    ChipPile.update(dt)
    ClickFlash.update(dt)
    Ghosts.update(dt)
    ItemGhosts.update(dt)

    -- Periodic auto-save. Skip the menu-class states (title/credits) so
    -- we don't churn disk while the player sits at a static screen. Also
    -- skip while a "menu-class" modal is up over gameplay (catalog /
    -- prestige / prototype-end) — during a multi-minute post-bust catalog
    -- browse the autosave was firing every 10s and queueing JSON writes
    -- to Emscripten's IDBFS, then stalling the frame when the queue
    -- flushed on resume to grind. Counter resets on each save; love.quit
    -- flushes from the play states so anything not yet persisted lands on
    -- exit (the Room included — it has no autosave tick of its own).
    do
        local sm  = Game.state_machine
        local cur = sm:current()
        local s   = sm.current_state
        local idle_modal = s and (s.catalog_modal
                                  or s.demo_end_modal
                                  or s.deck_select_modal)
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
            -- Everything sounds broken once the bankroll has underflowed.
            SoundService.setDamage(Game.state.underflowed and 1 or 0)
            Game.hint_view:draw(Game.hints:activeHint(), Game.hints.paused)
            -- Every visible story line dims the screen — the player is in
            -- a conversation and play is input-blocked, so the frame says
            -- so. Two looks: a line pointing at something on screen gets
            -- the full spotlight dim with holes over its targets (forced
            -- or not); a line with nothing to point at (or whose target
            -- graced away) gets a quarter-strength wash. StoryView then
            -- draws the marks and the panel over it.
            do
                local line = (not Game.story:isPaused())
                             and Game.story:currentLine() or nil
                if line then
                    local holes = line.anchor
                                  and HintMarks.fresh(line.anchor) or {}
                    if #holes > 0 then
                        Game.hint_view:_drawDim(holes)
                    else
                        Game.hint_view:_drawDim({}, 0.25)
                    end
                end
            end
            -- The story band, last, so it is never under a hint's dim.
            Game.story_view:draw(Game.story:currentLine(), {
                holding = Game.story:isHoldingClick() and not Game.story:isPaused(),
                graced  = Game.story:anchorGraceElapsed(),
            })
        end
    end
    -- The hover tooltip, above the story dim and panel: the forced
    -- EV-hover lesson exists to make the player READ this. It consumes
    -- itself on draw, so when a modal (catalog, settings) already drew it
    -- inside the state, this is a no-op. Steered away from the dialog via
    -- the avoid rect.
    Tooltip.setAvoid(Game.story_view.band_rect)
    Tooltip.draw(Game.fonts)
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

-- One final flush, shared by the quit and crash paths. Saves only from
-- the play states (grind / shove / room) — from title or credits,
-- Game.state can be a freshly-constructed default, and writing it would
-- overwrite the real save with a blank one.
local function flushSave()
    if not Game then return false end
    HandAnalytics.flush(Game.state, Game.settings and Game.settings.analytics_consent)
    local current = Game.state_machine and Game.state_machine:current()
    if current == "grind" or current == "shove" or current == "room" then
        local state = Game.state
        Game.save_service:saveAll(state:serializeMeta(), state:serializeRun())
        return true
    end
    return false
end

-- Losing window focus (tab switch, minimise) flushes a save. On the web
-- build love.quit never fires when the tab closes, so this is the last
-- reliable Lua-side hook; on desktop it is harmless extra safety.
function love.focus(f)
    if not f then pcall(flushSave) end
end

-- A button released OUTSIDE the window never delivers love.mousereleased,
-- leaving drag latches (volume slider, panel scrollbars, room editor bars)
-- stuck down. Focus loss is that case — send a synthetic release so every
-- drag ends.
function love.mousefocus(f)
    if not f and Game and Game.input_dispatcher then
        Game.input_dispatcher:dispatch("mousereleased", -1, -1, 1)
    end
end

function love.quit()
    -- Anything between the last autosave tick and quit lands here.
    pcall(flushSave)
end

-- LÖVE 12 only (11 never fires it): the audio device went away — the
-- headphones died, the default output changed. Returning false lets the
-- default handler run, which reopens the default device in place; every
-- Source keeps its state, and MusicDirector's next update refills its
-- queue if the gap drained it. Logged so a silent room can be traced.
function love.audiodisconnected(sources)
    pcall(print, "[audio] device disconnected (" .. tostring(sources and #sources or 0) .. " sources)")
    -- Reopen ourselves (same call the default handler makes) so the
    -- poller's hold-off starts now, then let the default handler run too.
    AudioDevice.reopen("disconnected")
    return false
end

-- A crash must not cost the run. Flush the save, then show a minimal
-- error screen in place of LOVE's default blue screen (which saves
-- nothing). Every step is pcall-guarded: whatever just broke must not
-- also break the flush.
function love.errorhandler(msg)
    msg = tostring(msg)
    local trace = msg
    pcall(function() trace = debug.traceback(msg, 3) end)
    pcall(function() print("[crash] " .. trace) end)
    local saved = false
    pcall(function() saved = flushSave() end)

    pcall(function()
        love.graphics.reset()
        love.graphics.origin()
        love.graphics.setFont(love.graphics.newFont(15))
    end)
    if love.mouse then
        pcall(function() love.mouse.setVisible(true) end)
    end

    local lines = { "The game crashed.", "" }
    if saved then
        lines[#lines + 1] = "Your progress was saved."
        lines[#lines + 1] = ""
    end
    local n = 0
    for line in trace:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
        n = n + 1
        if n >= 10 then break end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Press ESC to close."
    local text = table.concat(lines, "\n")

    return function()
        love.event.pump()
        for e, a in love.event.poll() do
            if e == "quit" then return 1 end
            if e == "keypressed" and a == "escape" then return 1 end
        end
        pcall(function()
            love.graphics.clear(0.09, 0.08, 0.11)
            love.graphics.setColor(0.92, 0.90, 0.85)
            love.graphics.printf(text, 40, 40, love.graphics.getWidth() - 80)
            love.graphics.present()
        end)
        if love.timer then love.timer.sleep(0.05) end
    end
end
