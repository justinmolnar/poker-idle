-- views/ItemGhosts.lua
--
-- "What just fired?" ghosts. When a catalog item does its job in play the
-- item_fired event plays its sound — but most foley reads alike, so the
-- item's own sprite pops in over the table that triggered it, floats up a
-- little, and fades, with the item's name beneath. Sound says SOMETHING
-- happened; this says what.
--
-- Module-singleton like services/Ghosts (list + update/draw/clear), but a
-- view: it knows sprites, fonts and Theme. Spawn from the item_fired
-- listener; drawn by GrindView above the table grid; cleared on hard
-- resets.

local Theme          = require("views.Theme")
local AnchorRegistry = require("services.AnchorRegistry")
local Easing         = require("utils.easing")

local Motion         = require("services.Motion")
local ItemGhosts = {}

local _ghosts = {}

local LIFETIME   = 1.5    -- seconds on screen
local RISE_PX    = 30     -- upward drift across the hold (exit adds more)
local MAX_H      = 460    -- sprite height ceiling (design px)
local PANEL_FRAC = 0.85   -- ...but aim for this fraction of the panel
local POP_T      = 0.22   -- entrance: small -> overshoot -> settle
local EXIT_FRAC  = 0.30   -- last fraction of life: shrink away + fade
local PEAK_ALPHA = 0.20   -- sprite opacity at full presence (a true ghost)
local GROW       = 0.08   -- slow breathing growth across the hold
local BOB_PX     = 3      -- gentle vertical bob while held
local STAGGER_X  = 46     -- offset when several items fire at one table
local DEDUP_SECS = 0.6    -- same item at ~the same moment ghosts once

-- Catalog id → display name, built lazily.
local _names
local function nameFor(id)
    if not _names then
        _names = {}
        for _, item in ipairs(require("data.catalog")) do
            _names[item.id] = item.name
        end
    end
    return _names[id]
end

-- Spawn a ghost for `item_id` at (x, y) — the firing table's centre —
-- sized to that panel (pw, ph), capped at MAX_H. A fire with no table (or
-- whose anchor was missing) still shows: it falls back to the centre of
-- the table section, then to a fixed mid-grid spot. Only a missing sprite
-- skips the ghost.
function ItemGhosts.spawn(game, item_id, x, y, pw, ph)
    if not (game and game.sprite_loader) then return end
    -- Motion: at None the ghost is not shown at all (the sound still says
    -- something fired).
    if Motion.level("text") <= Motion.NONE then return end
    local sprite = game.sprite_loader:getSprite(item_id)
    if not sprite then return end

    if not (x and y) then
        local grid = AnchorRegistry.get("grid:center")
        if grid then
            x, y, pw, ph = grid[1], grid[2], grid[3], (grid[4] or 0) * 0.55
        else
            -- Roughly the middle of the table section between the sidebars
            -- (the frame's width follows the window, so derive it).
            local W, H = love.graphics.getDimensions()
            x, y, pw, ph = math.floor(W * 0.5), math.floor(H * 0.49), 0, 320
        end
    end

    -- One ghost per item per moment: chip_award_mult fires on every bounty
    -- in a burst, and three overlapping copies of the same sprite read as
    -- a glitch, not information.
    local stagger = 0
    for _, g in ipairs(_ghosts) do
        if g.id == item_id and g.t < DEDUP_SECS then return end
        if math.abs(g.x - x) < 1 and g.t < DEDUP_SECS then
            stagger = stagger + 1
        end
    end

    local corrupted = false
    for _, id in ipairs((game.state and game.state.corrupted_items) or {}) do
        if id == item_id then corrupted = true; break end
    end

    -- Table-sized, to a ceiling: the ghost should read across the room,
    -- not be a postage stamp in the corner of the panel.
    local target_h = MAX_H
    if ph and ph > 0 then target_h = math.min(ph * PANEL_FRAC, MAX_H) end

    _ghosts[#_ghosts + 1] = {
        id        = item_id,
        name      = nameFor(item_id),
        sprite    = sprite,
        x         = x + stagger * ((pw and pw * 0.35) or STAGGER_X),
        y         = y,
        h         = target_h,
        t         = 0,
        corrupted = corrupted,
    }
end

function ItemGhosts.update(dt)
    if not dt or dt <= 0 then return end
    for i = #_ghosts, 1, -1 do
        local g = _ghosts[i]
        g.t = g.t + dt
        if g.t >= LIFETIME then table.remove(_ghosts, i) end
    end
end

function ItemGhosts.draw(game)
    if #_ghosts == 0 then return end
    local fonts = game and game.fonts
    for _, g in ipairs(_ghosts) do
        local p = g.t / LIFETIME

        -- ── Motion envelope ─────────────────────────────────────────
        -- Entrance: grows in from half-size with an overshoot pop while
        -- fading up. Hold: breathes slowly larger, bobs, drifts upward.
        -- Exit: shrinks away and accelerates upward while fading out.
        local sc, presence
        if g.t < POP_T then
            local k = g.t / POP_T
            sc       = 0.5 + 0.5 * Easing.outBack(k)
            presence = math.min(1, k / 0.6)
        else
            sc       = 1 + GROW * ((g.t - POP_T) / math.max(0.01, LIFETIME - POP_T))
            presence = 1
        end
        local rise = RISE_PX * p
        local bob  = math.sin(g.t * 5.2) * BOB_PX * presence
        if p > (1 - EXIT_FRAC) then
            local k = (p - (1 - EXIT_FRAC)) / EXIT_FRAC
            local ease = k * k
            presence = presence * (1 - ease)
            sc       = sc * (1 - 0.18 * ease)
            rise     = rise + 26 * ease
        end
        -- Motion: Medium doesn't bob or breathe; Low holds still entirely
        -- and only fades in and out.
        local lvl = Motion.level("text")
        if lvl <= Motion.MEDIUM then bob = 0 end
        if lvl <= Motion.LOW then sc, rise = 1, 0 end

        local sw, sh = g.sprite:getWidth(), g.sprite:getHeight()
        local scale  = (g.h / math.max(1, sh)) * sc
        local dx, dy = g.x, g.y - rise + bob

        -- Spawn burst: a faint expanding ring under the sprite sells the
        -- "something just happened HERE" beat without adding opacity.
        if g.t < 0.3 and lvl >= Motion.HIGH then
            local k = g.t / 0.3
            local rc
            if g.corrupted then
                rc = (Theme.currency and Theme.currency.achip) or { 0.65, 0.35, 0.95 }
            else
                rc = (Theme.currency and Theme.currency.chip) or { 0.98, 0.82, 0.12 }
            end
            love.graphics.setColor(rc[1], rc[2], rc[3], 0.18 * (1 - k))
            love.graphics.setLineWidth(3)
            love.graphics.circle("line", g.x, g.y, g.h * (0.25 + 0.45 * k))
            love.graphics.setLineWidth(1)
        end

        local ga = presence * PEAK_ALPHA
        if g.corrupted then
            local c = (Theme.currency and Theme.currency.achip) or { 0.65, 0.35, 0.95 }
            love.graphics.setColor(c[1], c[2], c[3], ga)
        else
            love.graphics.setColor(1, 1, 1, ga)
        end
        love.graphics.draw(g.sprite, dx, dy, 0, scale, scale, sw * 0.5, sh * 0.5)

        -- The label carries the information, so it stays near-full
        -- strength, slides up with the sprite, and skips the bob for
        -- readability.
        local font = fonts and (fonts.md or fonts.sm)
        if g.name and font then
            local la = presence * 0.95
            love.graphics.setFont(font)
            local tw = font:getWidth(g.name)
            local ty = (g.y - rise) + g.h * 0.5 + 4
            love.graphics.setColor(0, 0, 0, la * 0.85)
            for ox = -1, 1 do
                for oy = -1, 1 do
                    if ox ~= 0 or oy ~= 0 then
                        love.graphics.print(g.name, dx - tw * 0.5 + ox, ty + oy)
                    end
                end
            end
            Theme.setColor(Theme.fg.heading, la)
            love.graphics.print(g.name, dx - tw * 0.5, ty)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function ItemGhosts.clear()
    _ghosts = {}
end

return ItemGhosts
