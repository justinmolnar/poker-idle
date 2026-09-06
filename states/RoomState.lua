-- states/RoomState.lua
--
-- Dedicated state for viewing and designing the room.
-- Keeps the poker client grid, sidebars, and shove overlays completely hidden.

local AnchorRegistry = require("services.AnchorRegistry")
local Theme         = require("views.Theme")
local RoomView      = require("views.RoomView")
local Constants     = require("data.constants")
local LabelButton   = require("views.widgets.LabelButton")
local ClickFlash    = require("services.ClickFlash")
local ShoveDecor    = require("views.ShoveDecor")
local CatalogReceipt = require("views.CatalogReceipt")
local Tooltip       = require("services.Tooltip")
local Pop           = require("services.Pop")
local Motion        = require("services.Motion")
local SoundService  = require("services.SoundService")
local ItemFoley     = require("services.ItemFoley")
local Style         = require("data.shove_style")
local Catalog       = require("data.catalog")
local SettingsModal = require("views.SettingsModal")

local CARD_PIN_SECS = 3.0    -- a clicked item's card stays up this long
local POPIN_START   = 0.6    -- after enter, the first undelivered item pops in
local POPIN_STAGGER = 0.35   -- and the next, and the next
local BAND_CLEAR    = 76     -- × ui_scale: the story band's strip along the bottom
local EDGE          = 16     -- × ui_scale: the manifest's margin to the bar and the edge

local RoomState = {}
RoomState.__index = RoomState

function RoomState:new(game)
    return setmetatable({
        game      = game,
        room_view = nil,
        -- The manifest: the catalog's receipt, drawn flat on the right.
        manifest  = CatalogReceipt:new(game),
        _pinned   = nil,   -- { item, mx, my, until_t }: the card a click pinned
        _manifest_highlight = nil,   -- the room's hovered item: its row lights
        settings_modal = nil,
    }, RoomState)
end

-- The grind's view: its chrome (top bar and buttons) is drawn here too,
-- so the numbers never leave the screen. nil in a harness without one.
function RoomState:_grindView()
    local sm = self.game.state_machine
    local g  = sm and sm.states and sm.states.grind
    return g and g.view or nil
end

function RoomState:openSettings()
    if not self.settings_modal then
        self.settings_modal = SettingsModal:new(self.game)
    end
end

function RoomState:closeSettings()
    self.settings_modal = nil
end

-- The hint layer and the story stay quiet under the settings modal.
function RoomState:hintsBlocked()
    return self.settings_modal ~= nil
end

-- The one RoomView. The shove borrows it for its intro (the room counts
-- what you own), so it exists before the room screen is ever visited.
function RoomState:getRoomView()
    if not self.room_view then
        self.room_view = RoomView:new(self.game)
    end
    return self.room_view
end

function RoomState:enter()
    do  -- first-visit bookkeeping for the `screen_visits` hint kind
        local v = self.game.state and self.game.state.screen_visits
        if v then v["room"] = (v["room"] or 0) + 1 end
    end
    Theme.setActive("room")
    if not self.room_view then
        self.room_view = RoomView:new(self.game)
    end
    self._pinned = nil
    self.settings_modal = nil
    -- The chrome's numbers snap to the state: no tween across the cut.
    local gv = self:_grindView()
    if gv and gv.resetDisplays then gv:resetDisplays() end
    -- The lights stay how you left them.
    local settings = self.game.settings
    if settings and settings.room_lights_off ~= nil then
        self.room_view.fixture_off = settings.room_lights_off == true
    end
    self:_queuePopIn()
end

-- ── Delivery ─────────────────────────────────────────────────────────

-- Things bought since the last visit: those the layout has a place for
-- pop in one at a time (drawn at nothing until their turn); the rest are
-- seen by being on the manifest, and clear now.
function RoomState:_queuePopIn()
    local state = self.game.state
    local rv    = self.room_view
    local placed = {}
    for _, o in ipairs(rv.placed or {}) do
        local id = rv:catalogIdOf(o)
        if id then placed[id] = true end
    end
    local queue, pending = {}, {}
    for _, id in ipairs(state.room_unseen or {}) do
        if placed[id] and rv.catalog_by_id[id] and not pending[id] then
            queue[#queue + 1] = id
            pending[id] = true
        end
    end
    state.room_unseen = {}
    for _, id in ipairs(queue) do state.room_unseen[#state.room_unseen + 1] = id end
    self._popin = (#queue > 0) and { queue = queue, pending = pending, t = 0, next_at = POPIN_START } or nil
end

function RoomState:_updatePopIn(dt)
    local p = self._popin
    if not p then return end
    local state = self.game.state
    if Motion.scale("cinematics") <= 0 then
        -- No motion: everything is simply there.
        self._popin = nil
        state.room_unseen = {}
        return
    end
    p.t = p.t + dt
    while p.queue[1] and p.t >= p.next_at do
        local id = table.remove(p.queue, 1)
        p.pending[id] = nil
        local item = self.room_view.catalog_by_id[id]
        if item then self:_popItem(item) end
        for i = #state.room_unseen, 1, -1 do
            if state.room_unseen[i] == id then table.remove(state.room_unseen, i) end
        end
        p.next_at = p.next_at + POPIN_STAGGER
    end
    if not p.queue[1] then self._popin = nil end
end

-- The item's moment: its foley (the count's fallback tick when it has
-- none) and the count's own pop.
function RoomState:_popItem(item)
    local R = Style.room
    ItemFoley.play(self.game.state, item.id, { volume_mult = R.item_volume, fallback = R.fallback_tick })
    Pop.trigger("room_item:" .. item.id)
end

function RoomState:exit()
    self.settings_modal = nil
    self._pinned = nil
    if self.room_view then
        self.room_view.editor_mode = false
        self.room_view.hover_placed = nil   -- the shove and the title borrow the view
    end
    if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(false) end
    self._key_repeat = false
end

function RoomState:update(dt)
    -- Held keys repeat while the editor is up, so Ctrl+Up walks a piece
    -- across the room instead of needing a tap per grid step. Off again
    -- the moment the editor closes; nothing else in the game wants it.
    local want = (self.room_view and self.room_view.editor_mode) and true or false
    if want ~= (self._key_repeat or false) then
        if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(want) end
        self._key_repeat = want
    end

    -- Autosave the draft while the editor is up, and once more on the way
    -- out (want false, was true) so closing the editor loses nothing.
    if self.room_view then
        if want then
            self._autosave_t = (self._autosave_t or 0) + dt
            if self._autosave_t >= 2 then
                self._autosave_t = 0
                self.room_view:autosave()
            end
        elseif self._autosave_t then
            self._autosave_t = nil
            self.room_view:autosave()
        end
    end

    local gv = self:_grindView()
    if gv and gv.tweenChrome then gv:tweenChrome(dt) end

    if self.room_view and not want and not self.settings_modal then
        self:_updatePopIn(dt)
        self:_updateHover()
    end
end

-- ── The trophy case: hover, card, click ──────────────────────────────

-- What the pointer is on, in the room or on the manifest: the item
-- brightens in place, its row lights, and its card shows (a clicked
-- item's card stays pinned for a few seconds).
function RoomState:_updateHover()
    local rv = self.room_view
    local mx, my = love.mouse.getPosition()
    local hov_obj, hov_id
    local row = self.manifest:rowAt(mx, my)
    if row then
        hov_id  = row.item.id
        hov_obj = rv:placedById(hov_id)
    else
        hov_obj = rv:hitAt(mx, my)
        hov_id  = rv:catalogIdOf(hov_obj)
    end
    rv.hover_placed = hov_obj
    self._manifest_highlight = hov_id

    local pin = self._pinned
    if pin and love.timer.getTime() > pin.until_t then
        self._pinned = nil
        pin = nil
    end
    if pin then
        Tooltip.pin(self:_itemCard(pin.item), pin.mx, pin.my)
    elseif hov_id then
        local item = rv.catalog_by_id[hov_id]
        if item then Tooltip.set(self:_itemCard(item), mx, my) end
    end
end

-- The item's card: the receipt's (name, effect, corrupt line, description,
-- fire counts), read from the room too.
function RoomState:_itemCard(item)
    return CatalogReceipt.itemCard(self.game, item, self.game.state:isCorrupted(item.id))
end

-- A click on an item (in the room or on its row): its foley, a pop, the
-- card pinned, and, if it has one, the House's line about it.
function RoomState:_clickItem(item, mx, my)
    self:_popItem(item)
    self._pinned = { item = item, mx = mx, my = my, until_t = love.timer.getTime() + CARD_PIN_SECS }
    local story = self.game.story
    if item.house_line and story and story.sayOnce then story:sayOnce(item.house_line) end
end

-- The pop an item is mid-way through (a click, or the count's own pop),
-- as the scale RoomView draws it at.
function RoomState:_itemScale(obj)
    local id = self.room_view:catalogIdOf(obj)
    if not id then return 1 end
    -- Not delivered yet: its slot stands empty until its turn.
    if self._popin and self._popin.pending[id] then return 0 end
    local p = Pop.progress("room_item:" .. id, Style.room.flash_secs)
    if p <= 0 then return 1 end
    return Pop.scale(Motion.pop("cinematics", p), 1, 0.18)
end

function RoomState:draw()
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1
    local fl   = math.floor
    local fonts = self.game.fonts

    -- Draw background
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Draw Room View (centered full-screen). With the editor open the view
    -- is drawn LAST instead (see the end of this function): its toolbar
    -- lives inside the top bar, and drawing the bar after the view painted
    -- straight over Export / Reset / Clear / Help / Size / Floor.
    local view_last = self.room_view and self.room_view.editor_mode
    if self.room_view and not view_last then
        self:_drawRoom(W, H)
    end

    -- The top bar is the grind's: bankroll, tied up, total, chips, shove,
    -- tables, focus and the buttons, the ROOM button reading PLAY here.
    -- The chrome is the grind's rail along the bottom (its room button
    -- reads PLAY here and carries the room:play anchor).
    local gv = self:_grindView()
    local top_h = self:_topBarH()
    if gv then gv:drawChrome(W) end
    -- The House's story band: a strip along the bottom of the room, above the rail.
    AnchorRegistry.set("story:band", fl(16 * s), H - self:_railH() - fl(60 * s), W - fl(32 * s), fl(44 * s))
    local mx, my = love.mouse.getPosition()

    -- DESIGNER button + unlock-cheat status: dev tooling, not demo content.
    -- The editor's EXPORT writes into the source tree, which doesn't even
    -- exist on the web build. Under the bar, at the right.
    if Constants.FEATURES.DEV_HOTKEYS then
    local btn_h = fl(30 * s)
    local btn_y = top_h + fl(8 * s)
    local des_w = fl(140 * s)
    local des_x = W - des_w - fl(16 * s)
    self._designer_rect = { x = des_x, y = btn_y, w = des_w, h = btn_h }
    local is_editing = self.room_view and self.room_view.editor_mode

    local des_hov = mx >= des_x and mx < des_x + des_w and my >= btn_y and my < btn_y + btn_h

    LabelButton.draw{
        x = des_x, y = btn_y, w = des_w, h = btn_h,
        text        = is_editing and "DESIGNER: ON [F3]" or "DESIGNER [F3]",
        fonts       = fonts,
        hovered     = des_hov,
        fill_override = is_editing and { 0.20, 0.50, 0.30 } or nil,
    }

    -- Developer unlock cheat status (dev builds only, like the U key it
    -- serves). owned_items is an ARRAY of ids (see GameState) — build a
    -- set to test membership.
    if Constants.FEATURES.DEV_HOTKEYS then
        local Catalog = require("data.catalog")
        local owned_set = {}
        for _, id in ipairs(self.game.state.owned_items) do owned_set[id] = true end
        local is_unlocked = true
        for _, item in ipairs(Catalog) do
            if not item.granted_at_start and not owned_set[item.id] then
                is_unlocked = false
                break
            end
        end
        love.graphics.setFont(fonts.sm)
        if is_unlocked then
            Theme.setColor(Theme.fg.heading)
            love.graphics.print("ALL UNLOCKED [U]", des_x - fl(140 * s), btn_y + fl(10 * s))
        else
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("UNLOCK ALL [U]", des_x - fl(140 * s), btn_y + fl(10 * s))
        end
    end
    else
        self._designer_rect = nil
    end

    if view_last then
        self:_drawRoom(W, H)
    end
    if self.settings_modal then self.settings_modal:draw() end
end

-- Nothing sits along the top any more: the chrome is the rail (below).
function RoomState:_topBarH()
    return 0
end

-- The rail's height, from the grind view that draws it.
function RoomState:_railH()
    local gv = self:_grindView()
    return (gv and gv.railH) and gv:railH() or 0
end
-- The room: the same scene the shove's count and the title draw
-- (RoomView:drawScene), nothing moved; the manifest lies over its right
-- edge and the count sits where the shove's does. The editor keeps its
-- own zoom control and its unframed view.
function RoomState:_drawRoom(W, H)
    local rv = self.room_view
    local fixture = rv.fixture_off and 0 or 1
    if rv.editor_mode then
        rv:draw(true, { lighting = { fixture = fixture, emitters = true } })
        return
    end
    rv:drawScene(W, H, {
        fixture    = fixture,
        item_scale = function(obj) return self:_itemScale(obj) end,
    })
    -- The manifest: the same paper the catalog tucks behind its cover,
    -- laid flat. The card is the room's to show (hover or pinned).
    self.manifest:drawStandalone(self:_manifestRect(W, H), {
        placed_set   = rv:drawnIdSet(),
        highlight_id = self._manifest_highlight,
        tooltip      = false,
    })
    self:_drawCount(W, H)
end

-- Where the manifest lies: the paper's own width, down the right side,
-- under the bar and clear of the story band.
function RoomState:_manifestRect(W, H)
    local s, fl = self.game.ui_scale or 1, math.floor
    local pw, m = CatalogReceipt.paperWidth(s), fl(EDGE * s)
    local top_h = self:_topBarH()
    -- The rail stops left of this column, so the paper runs to the band.
    return { x = W - pw - m, y = top_h + m, w = pw, h = H - top_h - m - fl(BAND_CLEAR * s) }
end

-- The count: the number the shove's count reaches, where the shove puts
-- it (centred, at the room's counter line), the same word beside it.
function RoomState:_drawCount(W, H)
    local fonts = self.game.fonts
    local s     = self.game.ui_scale or 1
    local n     = #self.game.state:countedItems(Catalog)
    local c     = ShoveDecor.drawRoomCounter(fonts, s, W, H, n, "THINGS YOU OWN",
                                             { pop_id = "room_screen_count" })
    local lg_h  = fonts.lg:getHeight()
    local w     = fonts.lg:getWidth(tostring(n)) + math.floor(10 * s) + fonts.sm:getWidth("THINGS YOU OWN")
    AnchorRegistry.set("room:count", math.floor(c.x - fonts.lg:getWidth(tostring(n)) * 0.5),
                       c.y - lg_h * 0.5, w, lg_h)
end

-- The light switch: the fixture off and on, the tube's hum with it, and
-- the choice kept in settings so the room stays how you left it.
function RoomState:_toggleLights()
    local rv = self.room_view
    rv.fixture_off = not rv.fixture_off
    if rv.fixture_off then
        SoundService.stopNamed("lights_on")   -- the hum ends with the tube
        SoundService.playNamed("lights_off")
    else
        SoundService.playNamed("lights_on")
    end
    local g = self.game
    if g.settings then
        g.settings.room_lights_off = rv.fixture_off
        if g.save_service and g.save_service.saveSettings then g.save_service:saveSettings(g.settings) end
    end
end

-- The room editor's keys (F3 to enter/exit, -/= FPS, [ ] frame, ...)
-- collide with the global dev hotkeys; on this screen the room wins.
function RoomState:capturesDevKeys()
    return true
end

function RoomState:keypressed(key)
    if SettingsModal.route(self, "keypressed", key) then return end
    if self.room_view and self.room_view:keypressed(key) then
        return
    end

    -- Toggle unlock all cheat. owned_items is an ARRAY of ids everywhere
    -- (computeEffects iterates it, serializeMeta persists it) — the old
    -- version wrote set-style keys into it, which registered as nothing
    -- and polluted saves. Rebuild as a clean array both ways, and drop
    -- the effects cache so the rollup sees the change.
    -- Dev builds only: a shipped build must not carry a key that can
    -- wipe the whole catalog (all-owned + U empties owned_items, and the
    -- autosave makes it stick).
    if key == "u" and Constants.FEATURES.DEV_HOTKEYS then
        local Catalog = require("data.catalog")
        local state = self.game.state
        -- Sanitize: keep only the array part (repairs saves the old
        -- cheat polluted with hash keys).
        local owned = {}
        local owned_set = {}
        for _, id in ipairs(state.owned_items) do
            owned[#owned + 1] = id
            owned_set[id] = true
        end

        local any_unowned = false
        for _, item in ipairs(Catalog) do
            if not owned_set[item.id] then any_unowned = true; break end
        end

        if any_unowned then
            for _, item in ipairs(Catalog) do
                if not owned_set[item.id] then
                    owned[#owned + 1] = item.id
                end
            end
            state.owned_items = owned
            state.cleared = true
            print("[debug] Unlocked all catalog items and decks for room testing")
        else
            state.owned_items = {}
            state.cleared = false
            print("[debug] Reset owned catalog items and decks to none")
        end
        state.effects_cache = nil
        if self.game.grind and self.game.grind.invalidateEffects then
            self.game.grind:invalidateEffects()
        end
        return true
    end

    -- ESC or Tab exits the RoomState back to Grind
    if key == "escape" or key == "tab" then
        self.game.state_machine:switch("grind")
    end
end

function RoomState:mousepressed(x, y, button)
    if SettingsModal.route(self, "mousepressed", x, y, button) then return end
    if button ~= 1 then return end

    -- The rail: the grind's controls, read here. The room button is PLAY
    -- (back to the tables); the catalog and the deck roster are the
    -- grind's modals, so they open there; settings opens over the room;
    -- cash out, the quick reset and SHOVE act where they are.
    local gv = self:_grindView()
    local hit = gv and gv:chromeHit(x, y)
    if hit == "nav:room" then
        ClickFlash.flash("button", hit)
        self.game.state_machine:switch("grind")
        return
    elseif hit == "nav:settings" then
        ClickFlash.flash("button", hit)
        self:openSettings()
        return
    elseif hit == "nav:catalog" or hit == "deck" then
        ClickFlash.flash("button", hit)
        self.game.state_machine:switch("grind")
        if hit == "nav:catalog" then
            if self.game.openCatalog then self.game.openCatalog() end
        elseif self.game.openDeckRoster then
            self.game.openDeckRoster()
        end
        return
    elseif gv and gv:chromeMousepressed(x, y) then
        return
    end
    -- DESIGNER (dev builds only), under the bar at the right.
    local dr = self._designer_rect
    if dr and Constants.FEATURES.DEV_HOTKEYS
       and x >= dr.x and x < dr.x + dr.w and y >= dr.y and y < dr.y + dr.h then
        if self.room_view then
            self.room_view.editor_mode = not self.room_view.editor_mode
        end
        return
    end

    -- Otherwise forward to RoomView (the editor's own targets)...
    if self.room_view and self.room_view:mousepressed(x, y, button) then return end

    -- ...or, playing, a click on a thing you own: on its row or in the room.
    if self.room_view and not self.room_view.editor_mode and button == 1 then
        local rv  = self.room_view
        local row = self.manifest:rowAt(x, y)
        local item = row and row.item
        if not item then
            local hit = rv:hitAt(x, y)
            if hit and hit.id == "light_switch" then
                self:_toggleLights()
                return
            end
            local id = rv:catalogIdOf(hit)
            item = id and rv.catalog_by_id[id]
        end
        if item then self:_clickItem(item, x, y) end
    end
end

function RoomState:mousemoved(x, y, dx, dy)
    if SettingsModal.route(self, "mousemoved", x, y) then return end
    if self.room_view and self.room_view.mousemoved then
        self.room_view:mousemoved(x, y, dx, dy)
    end
end

function RoomState:mousereleased(x, y, button)
    if SettingsModal.route(self, "mousereleased", x, y, button) then return end
    if self.room_view and self.room_view.mousereleased then
        self.room_view:mousereleased(x, y, button)
    end
end

function RoomState:wheelmoved(x, y)
    if SettingsModal.route(self, "wheelmoved", x, y) then return end
    if self.room_view and not self.room_view.editor_mode then
        if self.manifest then self.manifest:wheelmoved(y) end
        return
    end
    if self.room_view then
        self.room_view:wheelmoved(y)
    end
end

return RoomState
