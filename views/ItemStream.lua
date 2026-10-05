-- views/ItemStream.lua
--
-- "What is firing, where, and what did it do?" Every catalog item that does
-- its job in play (the item_fired event) shows its own small sprite ON the
-- table it affected, with a word for what it did ("heater", "dealt", "next
-- win up"; data/item_fx.lua), and drifts up a little as it fades. When it
-- landed on another table than the one that set it off (a heater on a
-- neighbour, a redirected tilt), it flies from the one to the other first,
-- so a chain across the board reads as one. The same item on the same table
-- again within a moment merges into one icon with a count (xN), so a busy
-- Zoom board is a row of counters, not a blizzard.
--
-- A fire with no table (a bounty doubled at the shove) floats up from the
-- bottom of the table area, as the whole stream used to.
--
-- Module-singleton like services/Ghosts (list + update/draw/clear), but a
-- view: it knows sprites, fonts and Theme. Spawn from the item_fired
-- listener (main.lua); drawn by GrindView above the table grid; cleared
-- on hard resets. Replaced views/ItemGhosts (the per-table 20% ghosts,
-- 2026-09-07): those were invisible and spread over the whole screen.

local Theme          = require("views.Theme")
local AnchorRegistry = require("services.AnchorRegistry")
local Easing         = require("utils.easing")
local Motion         = require("services.Motion")
local Catalog        = require("data.catalog")
local Lookups        = require("utils.lookups")
local Fx             = require("data.item_fx")

local ItemStream = {}

local _icons = {}

local ICON_H      = 46      -- sprite height, px (the stream's heart size)
local MAX_LIVE    = 140     -- icons on screen at once; the oldest goes first
local RISE_FRAC   = 0.55    -- how far up the area an icon travels before it is gone
local SPEED_MIN   = 95      -- px/s
local SPEED_MAX   = 150
local WOBBLE_MIN  = 9       -- px, side-to-side amplitude
local WOBBLE_MAX  = 24
local WOBBLE_RATE = 2.4     -- rad/s, ± a little per icon
local POP_T       = 0.18    -- entrance: small -> overshoot -> settle
local FADE_FROM   = 0.62    -- fraction of the climb where the fade starts
local SPREAD      = 0.5     -- spawn x spread as a fraction of the firing panel's width
local LABEL_T     = 1.0     -- the name reads for this long after spawn, then goes
local EDGE_PAD    = 14

-- Catalog id → display name, built lazily.
local _names
local function nameFor(id)
    if not _names then
        _names = {}
        for _, item in ipairs(Catalog) do _names[item.id] = item.name end
    end
    return _names[id]
end

-- The item's room layout entry, the way views/CatalogReceipt finds it:
-- through the room state's live view (drafts from the save dir included).
local function roomEntry(game, item_id)
    local sm   = game.state_machine
    local room = sm and sm.states and sm.states.room
    local rv   = room and room.getRoomView and room:getRoomView() or nil
    return rv and rv:layoutEntry(item_id) or nil
end

-- The table area: centre point + dims from the grid anchor, else a guess
-- from the window.
local function area()
    local grid = AnchorRegistry.get("grid:center")
    if grid then
        local cx, cy, w, h = grid[1], grid[2], grid[3] or 0, grid[4] or 0
        return cx - w * 0.5, cy - h * 0.5, w, h
    end
    local W, H = love.graphics.getDimensions()
    return W * 0.2, H * 0.05, W * 0.6, H * 0.75
end

local function artFor(game, item_id)
    local item = Lookups.findById(Catalog, item_id)
    local corrupted = game.state and game.state.isCorrupted and game.state:isCorrupted(item_id) or false
    -- The SAME art the manifest and the catalog show: a placed item is drawn
    -- exactly as the room draws it (its layout entry's frame, animated only
    -- if the room animates it), and an unplaced one exactly as its catalog
    -- card does (a still, unless the card opts in). Never the resolver's
    -- default of "animate everything".
    local entry = roomEntry(game, item_id)
    local place = entry and "room" or "catalog"
    local sprite, _, _, animated = game.sprite_loader:itemArt(item, place, entry, { corrupted = corrupted })
    return sprite, item, entry, place, animated or false, corrupted
end

local function trim()
    local cap = Fx.max_live or MAX_LIVE
    while #_icons > cap do table.remove(_icons, 1) end
end

local function iconHeight(h)
    local ih = Fx.icon_h or ICON_H
    if h and h > 0 then ih = math.min(ih, h * (Fx.icon_of_table or 0.34)) end
    return math.max(14, ih)
end

-- A pop on a table: merges into a live one of the same item on the same
-- table (it gains a count), else a new icon. `delay` holds it back (the
-- flight there is still in the air).
local function pop(game, item_id, x, y, w, h, what, delay)
    local key = item_id .. "@" .. math.floor(x / 8) .. ":" .. math.floor(y / 8)
    for i = #_icons, 1, -1 do
        local ic = _icons[i]
        if ic.kind == "pop" and ic.key == key and ic.t < (Fx.merge_window or 1.0) then
            ic.count = ic.count + 1
            if ic.t > POP_T then ic.t = POP_T end   -- hold it up
            return
        end
    end
    local sprite, item, entry, place, animated, corrupted = artFor(game, item_id)
    if not sprite then return end
    local ih = iconHeight(h)
    _icons[#_icons + 1] = {
        kind = "pop", key = key, id = item_id, name = nameFor(item_id),
        sprite = sprite, item = item, entry = entry, place = place,
        animated = animated, corrupted = corrupted,
        x0 = x, y0 = y + ih * 0.5, icon_h = ih,
        life = Fx.pop_life or 1.2, t = -(delay or 0), count = 1,
        what = what,
    }
    trim()
end

-- Spawn for one fire. (x, y, pw, ph) is the table that set it off (its
-- centre and size), nil for a fire with no table. opts: what = { text,
-- color } (data/item_fx.lua), targets = { { x, y, w, h }, ... } where it
-- landed.
function ItemStream.spawn(game, item_id, x, y, pw, ph, opts)
    if not (game and game.sprite_loader) then return end
    if Motion.level("text") <= Motion.NONE then return end
    local what = opts and opts.what
    local targets = opts and opts.targets
    if x and y then
        local away = false
        if targets then
            for _, t in ipairs(targets) do
                if math.abs(t.x - x) > 4 or math.abs(t.y - y) > 4 then away = true end
            end
        end
        if not away then
            pop(game, item_id, x, y, pw, ph, what, 0)
            return
        end
        -- From the table that set it off to each table it landed on: the
        -- icon flies, then pops there with its word.
        local sprite, item, entry, place, animated, corrupted = artFor(game, item_id)
        if not sprite then return end
        local ih = iconHeight(ph)
        local fly = Fx.fly_time or 0.45
        for _, t in ipairs(targets) do
            _icons[#_icons + 1] = {
                kind = "fly", id = item_id, sprite = sprite, item = item, entry = entry, place = place,
                animated = animated, corrupted = corrupted, icon_h = ih,
                x0 = x, y0 = y, x1 = t.x, y1 = t.y,
                life = fly, t = 0, what = what,
            }
            pop(game, item_id, t.x, t.y, t.w, t.h, what, fly)
        end
        trim()
        return
    end
    -- No table: float up from the bottom of the table area.
    local sprite, item, entry, place, animated, corrupted = artFor(game, item_id)
    if not sprite then return end
    local ax, ay, aw, ah = area()
    local sx = ax + love.math.random() * aw
    sx = math.max(ax + EDGE_PAD, math.min(ax + aw - EDGE_PAD, sx))
    local speed = SPEED_MIN + love.math.random() * (SPEED_MAX - SPEED_MIN)
    local climb = ah * RISE_FRAC
    _icons[#_icons + 1] = {
        kind = "float", id = item_id, name = nameFor(item_id), sprite = sprite,
        item = item, entry = entry, place = place, animated = animated, corrupted = corrupted,
        x0 = sx, y0 = ay + ah, speed = speed, climb = climb, life = climb / speed, t = 0,
        amp = WOBBLE_MIN + love.math.random() * (WOBBLE_MAX - WOBBLE_MIN),
        rate = WOBBLE_RATE * (0.8 + love.math.random() * 0.5),
        phase = love.math.random() * math.pi * 2,
        dir = (love.math.random() < 0.5) and -1 or 1,
        icon_h = ICON_H, what = what,
    }
    trim()
end

-- Tests: what is live.
function ItemStream.debugIcons() return _icons end

function ItemStream.update(dt)
    if not dt or dt <= 0 then return end
    for i = #_icons, 1, -1 do
        local ic = _icons[i]
        ic.t = ic.t + dt
        if ic.t >= ic.life then table.remove(_icons, i) end
    end
end

local function wordColor(what)
    local c = what and what.color and Theme.semColor and Theme.semColor(what.color)
    return c or Theme.fg.heading
end

local function drawSprite(game, ic, dx, dy, scale_k, alpha, achip)
    local sprite = ic.sprite
    if ic.animated and game and game.sprite_loader then
        sprite = game.sprite_loader:itemArt(ic.item, ic.place, ic.entry, { corrupted = ic.corrupted }) or sprite
    end
    local sw, sh = sprite:getWidth(), sprite:getHeight()
    local scale  = ((ic.icon_h or ICON_H) / math.max(1, sh)) * scale_k
    if ic.corrupted then
        love.graphics.setColor(achip[1], achip[2], achip[3], alpha)
    else
        love.graphics.setColor(1, 1, 1, alpha)
    end
    love.graphics.draw(sprite, dx, dy, 0, scale, scale, sw * 0.5, sh)
end

function ItemStream.draw(game)
    if #_icons == 0 then return end
    local fonts = game and game.fonts
    local font  = fonts and (fonts.sm or fonts.xs)
    local lvl   = Motion.level("text")
    local achip = (Theme.currency and Theme.currency.achip) or { 0.65, 0.35, 0.95 }
    for _, ic in ipairs(_icons) do
        if ic.t >= 0 then
            local p = ic.t / ic.life
            if ic.kind == "fly" then
                -- along a bowed path to the table it landed on
                local k = 1 - (1 - p) * (1 - p)
                local dx = ic.x0 + (ic.x1 - ic.x0) * k
                local dy = ic.y0 + (ic.y1 - ic.y0) * k - (Fx.fly_arc or 40) * math.sin(math.pi * k)
                drawSprite(game, ic, dx, dy + (ic.icon_h or 0) * 0.5, 0.9, 1, achip)
            elseif ic.kind == "pop" then
                local sc = 1
                if ic.t < POP_T and lvl >= Motion.MEDIUM then
                    sc = 0.4 + 0.6 * Easing.outBack(ic.t / POP_T)
                end
                local alpha = 1
                if p > 0.6 then
                    local k = (p - 0.6) / 0.4
                    alpha = 1 - k * k
                end
                local rise = (lvl > Motion.LOW) and (Fx.pop_rise or 26) * p or 0
                local dx, dy = ic.x0, ic.y0 - rise
                drawSprite(game, ic, dx, dy, sc, alpha, achip)
                local word = (ic.what and ic.what.text) or ic.name
                if word and font then
                    if ic.count > 1 then word = word .. "  x" .. ic.count end
                    love.graphics.setFont(font)
                    local tw = font:getWidth(word)
                    Theme.setColor(wordColor(ic.what), alpha)
                    love.graphics.print(word, math.floor(dx - tw * 0.5), math.floor(dy + 2))
                end
            else
                -- float: the climb, and the wobble on top of it
                local rise = ic.speed * ic.t
                local wob  = ic.dir * ic.amp * math.sin(ic.t * ic.rate + ic.phase)
                if lvl <= Motion.MEDIUM then wob = wob * 0.5 end
                if lvl <= Motion.LOW then wob, rise = 0, ic.climb * 0.25 end
                local sc = 1
                if ic.t < POP_T and lvl >= Motion.MEDIUM then
                    sc = 0.4 + 0.6 * Easing.outBack(ic.t / POP_T)
                end
                local alpha = 1
                if p > FADE_FROM then
                    local k = (p - FADE_FROM) / (1 - FADE_FROM)
                    alpha = 1 - k * k
                    sc    = sc * (1 - 0.25 * k)
                end
                local dx, dy = ic.x0 + wob, ic.y0 - rise
                drawSprite(game, ic, dx, dy, sc, alpha, achip)
                local word = (ic.what and ic.what.text) or ic.name
                if word and font and ic.t < LABEL_T then
                    local la = alpha * (1 - (ic.t / LABEL_T)) ^ 1.5
                    love.graphics.setFont(font)
                    local tw = font:getWidth(word)
                    Theme.setColor(wordColor(ic.what), la)
                    love.graphics.print(word, dx - tw * 0.5, dy + 2)
                end
            end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function ItemStream.clear()
    _icons = {}
end

return ItemStream
