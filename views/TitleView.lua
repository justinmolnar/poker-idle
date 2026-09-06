-- views/TitleView.lua
--
-- The title screen: the room before you wake up. The fixture is off, the
-- emitters and the House's print are the only light, and the name is
-- dealt onto the dark as letter cards, one card per letter, the
-- apostrophe a gold chip. The menu sits low; Continue is the light
-- switch (states/TitleState blooms the fixture and cuts on the settle).
--
-- Drawing only. states/TitleState owns the clock and the flow and hands
-- this a plain table each frame:
--   t             seconds since enter
--   skip          true once a click completed the deal in place
--   leave_t       seconds since the light switch was thrown, or nil
--   speaker       0..1, the wall intercom's rattle (the idle key-ups)
--   has_save      whether Continue is on the menu
--   room_view     the player's room (views/RoomView), or nil
-- and reads back `view.rects` (menu buttons, the delete link, the
-- sticker) for hit tests.
--
-- Everything moves under Motion's `cinematics` group: at Medium the
-- timings shorten, at Low nothing travels (things appear by Motion.fade
-- at their final place), at None they are simply there.

local Theme        = require("views.Theme")
local Constants    = require("data.constants")
local Motion       = require("services.Motion")
local Throw        = require("services.Throw")
local Decal        = require("services.Decal")
local CardSprites  = require("views.CardSprites")
local Chips        = require("views.Chips")
local ShoveDecor   = require("views.ShoveDecor")
local RoomLighting = require("views.RoomLighting")
local RoomLights   = require("data.room_lights")
local LabelButton  = require("views.widgets.LabelButton")
local Sticker      = require("views.widgets.Sticker")
local IconText     = require("views.IconText")
local Format       = require("utils.format")
local Stakes       = require("data.stakes")
local Decks        = require("models.Decks")
local Anim         = require("data.animations")

local TitleView = {}
TitleView.__index = TitleView

-- ── The timeline (seconds at Full; Motion.scale shortens them) ─────────
-- The deal itself (flight, stagger, the flip) is the grind's deal,
-- data/animations grind_deal, so the title deals the way a table does.
local GD = Anim.grind_deal or {}
local T = {
    room_fade  = 0.40,   -- black → the room
    setup_at   = 0.30,   -- "POKER?" starts fading in
    setup_fade = 0.25,
    deal_at    = 0.70,   -- the first card leaves the dealer's hand
    card       = GD.card or 0.30,      -- one card's flight, face up
    stagger    = GD.stagger or 0.06,
    flip       = GD.flip or 0.22,      -- an idle turn
    chip_drop  = 0.25,   -- the apostrophe, after the last card lands
    menu_at    = 1.20,   -- the menu fades in (never gated on the deal)
    menu_fade  = 0.30,
    leave      = 0.60,   -- the fixture's settle (data/room_lights bloom)
    -- At rest (cinematics High and up): the row breathes, and now and
    -- then one card turns over, sits on its back, and turns back.
    idle_from  = 2.50,   -- after the deal is done
    idle_every = 7.00,
    idle_hold  = 1.60,   -- seconds face down
    bob_px     = 2.5,
    bob_rad    = 0.012,
}

-- The card's flight: from the left and above, an arc, a settling spin.
local DEAL = { throw_dx = 420, throw_arc = 60, throw_spin = 0.35, impact_squash = 0.06 }

-- ── Layout (base px, × ui_scale) ───────────────────────────────────────
local L = {
    row_y      = 0.20,   -- of H: the wordmark's top
    card_w     = 60,
    card_h     = 84,
    card_gap   = 6,
    word_gap   = 34,
    chip_r     = 15,
    tilt       = 0.035,  -- rest tilt spread, radians (Decal-hashed)
    menu_y     = 0.56,   -- of H
    btn_w      = 260,
    btn_h      = 48,
    btn_gap    = 10,
    corner_pad = 18,
}

function TitleView:new(game)
    return setmetatable({
        game   = game,
        rects  = {},
        _ui    = nil,   -- canvas the menu fades in through
        _sched = nil,
        _sched_scale = nil,
    }, TitleView)
end

-- Forget the fade keys so a return to the title fades again.
function TitleView:reset()
    for _, k in ipairs{ "title:room", "title:setup", "title:cards", "title:menu" } do
        Motion.forget(k)
    end
    self._sched = nil
end

-- ── The name as tokens ────────────────────────────────────────────────
-- Letters become cards, spaces become gaps, the apostrophe a chip.
local function tokens()
    local out = {}
    local name = (Constants.TITLE or ""):upper()
    for i = 1, #name do
        local ch = name:sub(i, i)
        if ch == " " then out[#out + 1] = { kind = "gap" }
        elseif ch == "'" then out[#out + 1] = { kind = "chip" }
        else out[#out + 1] = { kind = "card", glyph = ch } end
    end
    return out
end

-- When each thing lands, at the current Motion scale. Cached per scale so
-- the state can play a sound the frame a card lands. At scale 0 (Low and
-- None) everything is at rest from t = 0.
function TitleView:schedule()
    local sc = Motion.scale("cinematics")
    if self._sched and self._sched_scale == sc then return self._sched end
    local s = {
        scale    = sc,
        setup_at = T.setup_at * sc,
        deal_at  = T.deal_at * sc,
        menu_at  = T.menu_at * sc,
        lands    = {},
        chip_at  = 0,
        done_at  = 0,
    }
    local n = 0
    for _, tk in ipairs(tokens()) do
        if tk.kind == "card" then
            local start = (T.deal_at + n * T.stagger) * sc
            s.lands[#s.lands + 1] = start + T.card * sc
            n = n + 1
        end
    end
    local last = s.lands[#s.lands] or s.deal_at
    s.chip_at = last + T.chip_drop * sc
    s.done_at = math.max(s.chip_at, s.menu_at + T.menu_fade * sc)
    s.cards   = #s.lands
    s.idle_at = s.done_at + T.idle_from
    self._sched, self._sched_scale = s, sc
    return s
end

-- The idle flips: cycle k (0, 1, 2 ...) turns one hashed card over at
-- `start`, holds it face down, turns it back. Returns start, card index.
local function idleCycle(sched, k)
    local start = sched.idle_at + k * T.idle_every + Decal.unit("title:idle:" .. k, 1) * 2.5
    local card  = 1 + math.floor(Decal.unit("title:idle:" .. k, 2) * sched.cards)
    return start, card
end

-- Whether the row is at rest and allowed to move on its own.
local function idling(sched)
    return sched.scale > 0 and Motion.at("cinematics", Motion.HIGH)
end

-- How many card turns start in (t0, t1]: the state plays the flip sound.
function TitleView:idleFlips(t0, t1)
    local sched = self:schedule()
    if not idling(sched) or t1 < sched.idle_at then return 0 end
    local n = 0
    local k0 = math.max(0, math.floor((t0 - sched.idle_at) / T.idle_every) - 1)
    local k1 = math.floor((t1 - sched.idle_at) / T.idle_every) + 1
    for k = k0, k1 do
        local start = idleCycle(sched, k)
        local back  = start + T.flip + T.idle_hold
        if start > t0 and start <= t1 then n = n + 1 end
        if back  > t0 and back  <= t1 then n = n + 1 end
    end
    return n
end

-- A card's face at time t: `face` (true = the letter, false = the back)
-- and `sx`, its width mid-turn (1 flat, 0 edge-on). Cards deal face up;
-- at rest an idle cycle turns one over to the player's deck back and back.
local function cardFace(sched, i, t)
    if idling(sched) and t >= sched.idle_at then
        local k = math.floor((t - sched.idle_at) / T.idle_every)
        for kk = math.max(0, k - 1), k do
            local start, card = idleCycle(sched, kk)
            if card == i then
                local u = t - start
                if u >= 0 and u < T.flip then
                    return u / T.flip < 0.5, math.abs(math.cos(math.pi * u / T.flip))
                elseif u >= T.flip and u < T.flip + T.idle_hold then
                    return false, 1
                elseif u >= T.flip + T.idle_hold and u < 2 * T.flip + T.idle_hold then
                    local v = (u - T.flip - T.idle_hold) / T.flip
                    return v >= 0.5, math.abs(math.cos(math.pi * v))
                end
            end
        end
    end
    return true, 1
end

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

-- Progress of a beat that starts at `at` and runs `dur` (already scaled).
local function prog(t, at, dur)
    if dur <= 0 then return 1 end
    return clamp01((t - at) / dur)
end

-- ── The wordmark ──────────────────────────────────────────────────────
-- Lays the row out centred at row_y; returns the slots.
local function layoutRow(W, H, s)
    local cw, ch = math.floor(L.card_w * s), math.floor(L.card_h * s)
    local gap, wgap = math.floor(L.card_gap * s), math.floor(L.word_gap * s)
    local chip_r = math.floor(L.chip_r * s)
    local chip_w = chip_r * 2 + gap
    local toks = tokens()
    local total = 0
    for i, tk in ipairs(toks) do
        if tk.kind == "card" then total = total + cw
        elseif tk.kind == "chip" then total = total + chip_w
        else total = total + wgap end
        if i < #toks and tk.kind ~= "gap" and toks[i + 1].kind ~= "gap" then
            total = total + gap
        end
    end
    local x = math.floor((W - total) * 0.5)
    local y = math.floor(H * L.row_y)
    local slots = {}
    local n = 0
    for i, tk in ipairs(toks) do
        if tk.kind == "card" then
            n = n + 1
            slots[#slots + 1] = { kind = "card", glyph = tk.glyph, idx = n, x = x, y = y, w = cw, h = ch }
            x = x + cw
        elseif tk.kind == "chip" then
            slots[#slots + 1] = { kind = "chip", x = x, y = y, w = chip_w, h = ch, r = chip_r }
            x = x + chip_w
        else
            x = x + wgap
        end
        if i < #toks and tk.kind ~= "gap" and toks[i + 1].kind ~= "gap" then
            x = x + gap
        end
    end
    return slots, y, ch
end

function TitleView:_drawWordmark(W, H, s, t, sched, alpha)
    local fonts = self.game.fonts
    local slots, row_y, row_h = layoutRow(W, H, s)
    local sc = sched.scale

    -- The setup line above the row.
    local setup = Constants.TITLE_SETUP
    if setup and setup ~= "" then
        local a
        if sc > 0 then a = prog(t, sched.setup_at, T.setup_fade * sc)
        else a = Motion.fade("cinematics", "title:setup") end
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.muted, a * alpha)
        love.graphics.printf(setup:upper(), 0, row_y - fonts.md:getHeight() - math.floor(10 * s), W, "center")
    end

    local rest_a = (sc > 0) and 1 or Motion.fade("cinematics", "title:cards")
    local shadow_off = math.floor(3 * s)
    local breathe = idling(sched)
    local atlas = self.game.sprite_loader
    local state = self.game.state
    local back  = (Constants.FEATURES.DECKS and Decks.systemUnlocked(state)
                   and Decks.activeSprite(state))
                  or (Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE)
    for _, sl in ipairs(slots) do
        local _, _, tilt = Decal.place("title:slot:" .. tostring(sl.x), { dx = 0, dy = 0, angle = L.tilt })
        -- At rest the row breathes: each piece on its own slow phase.
        local ph = Decal.unit("title:bob:" .. tostring(sl.x), 1) * math.pi * 2
        local bob_y, bob_r = 0, 0
        if breathe then
            bob_y = math.sin(t * 1.3 + ph) * T.bob_px * s
            bob_r = math.sin(t * 0.8 + ph * 1.7) * T.bob_rad
        end
        if sl.kind == "card" then
            local p
            if sc > 0 then
                local start = (T.deal_at + (sl.idx - 1) * T.stagger) * sc
                p = prog(t, start, T.card * sc)
            else
                p = 1
            end
            if p > 0 then
                local x, y, spin, squash, height = Throw.pose(p, DEAL, s, sl.x, sl.y, sl.h)
                if p >= 1 then y = y + bob_y end
                local a = math.min(1, p * 3) * rest_a * alpha
                local lift = height * 14 * s
                CardSprites.shadow(x, y, sl.w, sl.h, a, shadow_off + lift)
                local h   = sl.h * squash
                local rot = tilt + spin + ((p >= 1) and bob_r or 0)
                local face, sx = cardFace(sched, sl.idx, t)
                if face then
                    CardSprites.letter(x, y + (sl.h - h) * 0.5, sl.w, h, sl.glyph, fonts.xl, a, rot, sx)
                elseif atlas and back then
                    CardSprites.sprite(atlas, back, x, y + (sl.h - h) * 0.5, sl.w, h, sx, a, rot)
                else
                    CardSprites.letter(x, y + (sl.h - h) * 0.5, sl.w, h, nil, nil, a, rot, sx)
                end
            end
        else
            -- The apostrophe: a gold chip that drops in after the last card.
            local p = (sc > 0) and prog(t, sched.chip_at - T.chip_drop * sc, T.chip_drop * sc) or 1
            if p > 0 then
                local e  = 1 - (1 - p) ^ 3
                local cx = sl.x + sl.w * 0.5
                local cy = sl.y + sl.r + math.floor(6 * s) + ((p >= 1) and bob_y or 0)
                local drop = (1 - e) * 60 * s
                local a = math.min(1, p * 3) * rest_a * alpha
                Chips.drawShadow(cx, cy + math.floor(3 * s), 0.35 * a, sl.r / Chips.radius())
                Chips.drawGlyph(cx, cy - drop, sl.r, a)
            end
        end
    end
end

-- ── The menu ──────────────────────────────────────────────────────────
local function isDesktop()
    local os_name = (love.system and love.system.getOS and love.system.getOS()) or ""
    return os_name ~= "Web" and os_name ~= "Emscripten"
end

-- One line under Continue: the save at a glance.
local function saveSummary(game)
    local st = game.state
    if not st then return nil end
    local parts = { Format.money(st.bankroll or 0) }
    parts[#parts + 1] = tostring(math.floor(st.chips or 0)) .. " {chip}"
    for _, sk in ipairs(Stakes) do
        if sk.id == st.current_stake_id then parts[#parts + 1] = sk.display_name break end
    end
    local hands = st.total_hands_played or 0
    if hands > 0 then parts[#parts + 1] = Format.formatBig(hands) .. " hands" end
    if Constants.FEATURES.DECKS and Decks.systemUnlocked(st) and st.active_deck_id then
        local spec = Decks.specById(st.active_deck_id)
        if spec and spec.name then parts[#parts + 1] = spec.name end
    end
    return table.concat(parts, "  \xC2\xB7  ")
end

function TitleView:_menuItems(has_save)
    local items = {}
    if has_save then items[#items + 1] = { id = "continue", label = "Continue" } end
    items[#items + 1] = { id = "new",      label = "New Game" }
    items[#items + 1] = { id = "settings", label = "Settings" }
    if isDesktop() then items[#items + 1] = { id = "exit", label = "Exit" } end
    return items
end

function TitleView:_drawMenu(W, H, s, st)
    local fonts = self.game.fonts
    local mx, my = love.mouse.getPosition()
    local rects = {}
    local btn_w, btn_h, gap = math.floor(L.btn_w * s), math.floor(L.btn_h * s), math.floor(L.btn_gap * s)
    local x = math.floor((W - btn_w) * 0.5)
    local y = math.floor(H * L.menu_y)
    local summary = st.has_save and saveSummary(self.game) or nil
    local interactive = not st.leave_t

    for _, it in ipairs(self:_menuItems(st.has_save)) do
        local hov = interactive and mx >= x and mx < x + btn_w and my >= y and my < y + btn_h
        LabelButton.draw{
            x = x, y = y, w = btn_w, h = btn_h,
            text = it.label, fonts = fonts, font = fonts.md,
            hovered = hov, depth = 4,
        }
        rects[#rects + 1] = { id = it.id, x = x, y = y, w = btn_w, h = btn_h }
        y = y + btn_h + gap
        if it.id == "continue" and summary then
            local sw = IconText.measure(summary, fonts.sm)
            IconText.draw(self.game, summary, math.floor((W - sw) * 0.5), y, fonts.sm, Theme.fg.muted, 1)
            y = y + fonts.sm:getHeight() + math.floor(6 * s)
        end
    end

    -- Corners: the delete link, the build string, the demo's sticker.
    local pad = math.floor(L.corner_pad * s)
    love.graphics.setFont(fonts.sm)
    local sh = fonts.sm:getHeight()
    if st.has_save then
        local txt = "delete save"
        local tw  = fonts.sm:getWidth(txt)
        local lx, ly = pad, H - pad - sh
        local hov = interactive and mx >= lx and mx < lx + tw and my >= ly and my < ly + sh
        Theme.setColor(hov and Theme.status.error or Theme.fg.faint)
        love.graphics.print(txt, lx, ly)
        rects[#rects + 1] = { id = "delete", x = lx, y = ly, w = tw, h = sh }
    end
    do
        local txt = "build " .. tostring(Constants.BUILD or "")
        if Constants.DEMO then txt = txt .. "  \xC2\xB7  demo" end
        local tw = fonts.sm:getWidth(txt)
        Theme.setColor(Theme.fg.faint)
        love.graphics.print(txt, W - pad - tw, H - pad - sh)
    end
    if Constants.DEMO and Constants.STEAM_URL and Constants.STEAM_URL ~= "" then
        local title, line = "WISHLIST", "on Steam"
        local sw = Sticker.widthFor(fonts, s, title, line)
        local sth = Sticker.heightFor(fonts, s, true)
        local sx = W - pad - sw
        local sy = H - pad - sh - math.floor(12 * s) - sth
        local _, _, rot = Decal.place("title:wishlist", { dx = 0, dy = 0, angle = 0.08, base_angle = -0.06 })
        Sticker.draw{
            game = self.game, fonts = fonts, x = sx, y = sy, w = sw, h = sth,
            title = title, line = line, scale = s, rotation = rot,
        }
        rects[#rects + 1] = { id = "wishlist", x = sx, y = sy, w = sw, h = sth }
    end
    self.rects = rects
end

-- ── The frame ─────────────────────────────────────────────────────────
function TitleView:draw(st)
    local W, H  = love.graphics.getDimensions()
    local s     = self.game.ui_scale or 1
    local sched = self:schedule()
    local sc    = sched.scale
    local t     = st.skip and math.max(st.t, sched.done_at) or st.t

    -- Leaving: the fixture blooms on the room's own curve, the title
    -- fades over the same window.
    local fixture = 0
    local title_a = 1
    if st.leave_t then
        fixture = RoomLighting.fixtureLevel(RoomLights.fixture, st.leave_t)
        title_a = 1 - clamp01(st.leave_t / T.leave)
    end

    -- The room, in the dark: the same scene the shove and the room screen
    -- draw, under the wordmark.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", 0, 0, W, H)
    if st.room_view then
        st.room_view:drawScene(W, H, { fixture = fixture, speaker = st.speaker or 0 })
    end
    -- Fade up from black.
    local room_a = (sc > 0) and prog(t, 0, T.room_fade * sc) or Motion.fade("cinematics", "title:room")
    if room_a < 1 then
        Theme.setColor(Theme.bg.sunken, 1 - room_a)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end

    self:_drawWordmark(W, H, s, t, sched, title_a)

    -- The menu fades in through a canvas (the widgets paint in their own
    -- colours; a canvas is the one way to fade them as a group).
    local menu_a = ((sc > 0) and prog(t, sched.menu_at, T.menu_fade * sc)
                    or Motion.fade("cinematics", "title:menu")) * title_a
    if menu_a <= 0 then self.rects = {} return end
    if self._ui and (self._ui:getWidth() ~= W or self._ui:getHeight() ~= H) then self._ui = nil end
    if not self._ui and love.graphics.newCanvas then
        local ok, c = pcall(love.graphics.newCanvas, W, H, { dpiscale = 1 })
        if ok then self._ui = c end
    end
    if self._ui and menu_a < 1 then
        local prev = love.graphics.getCanvas()
        love.graphics.setCanvas(self._ui)
        love.graphics.clear(0, 0, 0, 0)
        self:_drawMenu(W, H, s, st)
        love.graphics.setCanvas(prev)
        love.graphics.setColor(1, 1, 1, menu_a)
        love.graphics.setBlendMode("alpha", "premultiplied")
        love.graphics.draw(self._ui, 0, 0)
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(1, 1, 1, 1)
    else
        self:_drawMenu(W, H, s, st)
    end
end

-- Is (x, y) on a menu rect? Returns its id.
function TitleView:hit(x, y)
    for _, r in ipairs(self.rects or {}) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r.id end
    end
    return nil
end

TitleView.LEAVE_SECS = T.leave

return TitleView
