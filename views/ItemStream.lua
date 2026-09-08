-- views/ItemStream.lua
--
-- "What is firing?" as a live-stream feed. Every catalog item that does its
-- job in play (the item_fired event) puts its own small sprite at the
-- bottom of the table area, and it floats up like a heart on a phone
-- stream: a little pop, a lazy side-to-side wobble, fading out before the
-- top. One icon per fire, always. Nothing merges, nothing counts, nothing
-- is sized by strength: a billion Zoom fires is a billion Handhelds, and
-- that swarm IS the information. An item that never fires never appears,
-- which is also information.
--
-- Where along the bottom: under the table that fired, with a spread, so a
-- hot corner of the board swarms from that corner; a fire with no table
-- spawns anywhere across the width.
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

-- Spawn one icon for `item_id`. (x, pw) is the firing table's centre and
-- width, when there is one; y and ph are accepted for the old call shape
-- and ignored (every icon starts at the bottom of the area).
function ItemStream.spawn(game, item_id, x, _y, pw, _ph)
    if not (game and game.sprite_loader) then return end
    if Motion.level("text") <= Motion.NONE then return end
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
    if not sprite then return end

    local ax, ay, aw, ah = area()
    local sx
    if x then
        local spread = (pw and pw > 0) and (pw * SPREAD) or 60
        sx = x + (love.math.random() * 2 - 1) * spread
    else
        sx = ax + love.math.random() * aw
    end
    sx = math.max(ax + EDGE_PAD, math.min(ax + aw - EDGE_PAD, sx))

    local speed = SPEED_MIN + love.math.random() * (SPEED_MAX - SPEED_MIN)
    local climb = ah * RISE_FRAC
    _icons[#_icons + 1] = {
        id        = item_id,
        name      = nameFor(item_id),
        sprite    = sprite,
        -- an item the room animates keeps animating on the way up: the
        -- frame is re-resolved each draw (a still is resolved once)
        item      = item,
        entry     = entry,
        place     = place,
        animated  = animated or false,
        corrupted = corrupted,
        x0        = sx,
        y0        = ay + ah,                 -- the bottom edge of the area
        speed     = speed,
        climb     = climb,
        life      = climb / speed,
        t         = 0,
        amp       = WOBBLE_MIN + love.math.random() * (WOBBLE_MAX - WOBBLE_MIN),
        rate      = WOBBLE_RATE * (0.8 + love.math.random() * 0.5),
        phase     = love.math.random() * math.pi * 2,
        dir       = (love.math.random() < 0.5) and -1 or 1,
    }
    -- The cap: a full board at Zoom speed must not fill the screen or the
    -- frame budget. Density under the cap is the signal.
    while #_icons > MAX_LIVE do table.remove(_icons, 1) end
end

function ItemStream.update(dt)
    if not dt or dt <= 0 then return end
    for i = #_icons, 1, -1 do
        local ic = _icons[i]
        ic.t = ic.t + dt
        if ic.t >= ic.life then table.remove(_icons, i) end
    end
end

function ItemStream.draw(game)
    if #_icons == 0 then return end
    local fonts = game and game.fonts
    local font  = fonts and (fonts.sm or fonts.xs)
    local lvl   = Motion.level("text")
    local achip = (Theme.currency and Theme.currency.achip) or { 0.65, 0.35, 0.95 }
    for _, ic in ipairs(_icons) do
        local p = ic.t / ic.life

        -- the climb, and the wobble on top of it
        local rise = ic.speed * ic.t
        local wob  = ic.dir * ic.amp * math.sin(ic.t * ic.rate + ic.phase)
        if lvl <= Motion.MEDIUM then wob = wob * 0.5 end
        if lvl <= Motion.LOW then wob, rise = 0, ic.climb * 0.25 end

        -- the pop in
        local sc = 1
        if ic.t < POP_T and lvl >= Motion.MEDIUM then
            sc = 0.4 + 0.6 * Easing.outBack(ic.t / POP_T)
        end
        -- the fade out over the last stretch, shrinking a little with it
        local alpha = 1
        if p > FADE_FROM then
            local k = (p - FADE_FROM) / (1 - FADE_FROM)
            alpha = 1 - k * k
            sc    = sc * (1 - 0.25 * k)
        end

        local sprite = ic.sprite
        if ic.animated and game and game.sprite_loader then
            sprite = game.sprite_loader:itemArt(ic.item, ic.place, ic.entry, { corrupted = ic.corrupted }) or sprite
        end
        local sw, sh = sprite:getWidth(), sprite:getHeight()
        local scale  = (ICON_H / math.max(1, sh)) * sc
        local dx, dy = ic.x0 + wob, ic.y0 - rise

        if ic.corrupted then
            love.graphics.setColor(achip[1], achip[2], achip[3], alpha)
        else
            love.graphics.setColor(1, 1, 1, alpha)
        end
        love.graphics.draw(sprite, dx, dy, 0, scale, scale, sw * 0.5, sh)

        -- The name, for the first beat only: the swarm is the picture, the
        -- word is the caption you read once.
        if ic.name and font and ic.t < LABEL_T then
            local la = alpha * (1 - (ic.t / LABEL_T)) ^ 1.5
            love.graphics.setFont(font)
            local tw = font:getWidth(ic.name)
            local tx, ty = dx - tw * 0.5, dy + 2
            love.graphics.setColor(0, 0, 0, la * 0.8)
            love.graphics.print(ic.name, tx + 1, ty + 1)
            Theme.setColor(Theme.fg.heading, la)
            love.graphics.print(ic.name, tx, ty)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function ItemStream.clear()
    _icons = {}
end

return ItemStream
