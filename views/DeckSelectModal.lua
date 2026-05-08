-- views/DeckSelectModal.lua
--
-- Two modes via :new(game, opts):
--
--   • Default (opts.read_only = false / nil) — Post-shove swap overlay.
--     Slots between the catalog modal and grind switch in the post-bust
--     ritual: shove → gauntlet → prestige → catalog → DECK SELECT → grind.
--     Player picks which deck is active for the next run.
--
--   • Read-only (opts.read_only = true) — Mid-grind roster popup. Same
--     visuals; clicking a tile does NOT swap the active deck (swap is
--     restricted to post-shove). Any click dismisses.
--
-- All unlocked decks contribute their banked passive regardless of which
-- is active — the active selection only decides who accrues XP next run.
--
-- Pure presentation. Tile clicks (in select mode only) dispatch through
-- state:setActiveDeck (a model-side guarded write); the modal never
-- mutates state.active_deck_id directly.

local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")
local Decks       = require("models.Decks")

local DeckSelectModal = {}
DeckSelectModal.__index = DeckSelectModal

local MODAL_W_BASE     = 760
local TILE_W_BASE      = 200
-- Tile height fits: sprite (~196) + gap + name + level + bonus + xp-action
-- + bar + xp-numbers, with breathing room. Each text row uses fonts.sm
-- (~14) or fonts.md (~18). 360 leaves enough slack for a slightly taller
-- pixel font without the XP bar / numbers overflowing the bottom border.
local TILE_H_BASE      = 360
local TILE_GAP_BASE    = 24
local SPRITE_W_BASE    = 140
local SPRITE_H_BASE    = 196
local BTN_W_BASE       = 200
local BTN_H_BASE       = 44
local XP_BAR_H_BASE    = 8

function DeckSelectModal:new(game, opts)
    opts = opts or {}
    local s = (game.ui_scale) or 1
    local modal_w = math.floor(MODAL_W_BASE * s)
    local title = opts.read_only and "YOUR DECKS" or "CHOOSE YOUR DECK"
    return setmetatable({
        game           = game,
        read_only      = opts.read_only or false,
        _resolved      = false,
        _continue_rect = nil,
        _tiles         = {},
        _modal         = Modal:new{ title = title, w = modal_w },
    }, DeckSelectModal)
end

function DeckSelectModal:resolved() return self._resolved end

function DeckSelectModal:consumeKey(key)
    if key == "space" or key == "return" or key == "kpenter" or key == "escape" then
        self._resolved = true
        return true
    end
    return false
end

-- Handle a click on either a deck tile (swap active in select mode) or
-- the Continue button (resolve). Read-only mode dismisses on any click.
-- Returns true so the host doesn't fall through to underlying view
-- hit-tests.
function DeckSelectModal:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end

    local r = self._continue_rect
    if r and mx >= r.x and mx < r.x + r.w
       and my >= r.y and my < r.y + r.h then
        self._resolved = true
        return true
    end

    if self.read_only then
        -- Click anywhere else dismisses the read-only roster popup.
        self._resolved = true
        return true
    end

    for _, tile in ipairs(self._tiles) do
        if mx >= tile.x and mx < tile.x + tile.w
           and my >= tile.y and my < tile.y + tile.h then
            self.game.state:setActiveDeck(tile.id)
            return true
        end
    end
    return true
end

-- Draw a single deck tile. Returns nothing; stashes hit rect in self._tiles.
local function drawTile(self, spec, x, y, w, h, fonts, s)
    local state = self.game.state
    local active = (state.active_deck_id == spec.id)
    local level  = (state.deck_levels and state.deck_levels[spec.id]) or 1
    local xp     = (state.deck_xp and state.deck_xp[spec.id]) or 0

    -- Tile chrome. Active deck gets the heading-color border so the
    -- "currently equipped" reads at a glance against the muted tiles.
    local border = active and Theme.fg.heading or Theme.border.soft
    Theme.setColor(active and Theme.bg.widget_hover or Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(border)
    love.graphics.setLineWidth(active and Theme.space.line_strong or 1)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- Card-back sprite, scaled to fit. Centered horizontally; top-aligned
    -- inside the tile with a small inset.
    local sprite = self.game.sprite_loader:getSprite(spec.sprite)
    local sprite_w = math.floor(SPRITE_W_BASE * s)
    local sprite_h = math.floor(SPRITE_H_BASE * s)
    local sprite_x = x + math.floor((w - sprite_w) / 2)
    local sprite_y = y + math.floor(14 * s)
    if sprite then
        local sx = sprite_w / sprite:getWidth()
        local sy = sprite_h / sprite:getHeight()
        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, sprite_x, sprite_y, 0, sx, sy)
    else
        -- Fallback chrome rect with the deck name centered, in case the
        -- sprite asset is missing. Keeps the tile tappable + visible.
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", sprite_x, sprite_y, sprite_w, sprite_h,
                                Theme.space.radius)
        Theme.setColor(Theme.fg.faint)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf("(no sprite)", sprite_x,
            sprite_y + math.floor(sprite_h / 2 - fonts.sm:getHeight() / 2),
            sprite_w, "center")
    end

    -- Active badge in the top-right corner of the sprite area when this
    -- deck is the equipped one.
    if active then
        local badge_w = math.floor(60 * s)
        local badge_h = math.floor(18 * s)
        Theme.setColor(Theme.status.good)
        love.graphics.rectangle("fill", x + w - badge_w - 6, y + 6,
                                badge_w, badge_h, Theme.space.radius)
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.bg.window)
        love.graphics.printf("ACTIVE", x + w - badge_w - 6, y + 8,
                             badge_w, "center")
    end

    -- Stack below the sprite: name (md), level (sm muted), bonus text
    -- (sm primary), XP bar.
    local cx_pad   = math.floor(12 * s)
    local cursor_y = sprite_y + sprite_h + math.floor(12 * s)

    Theme.setColor(active and Theme.fg.heading or Theme.fg.primary)
    love.graphics.setFont(fonts.md)
    love.graphics.printf(spec.name or spec.id, x + cx_pad, cursor_y,
                         w - cx_pad * 2, "center")
    cursor_y = cursor_y + fonts.md:getHeight() + math.floor(2 * s)

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.sm)
    local lvl_text = "L" .. tostring(level) .. "  /  " .. tostring(spec.max_level)
    love.graphics.printf(lvl_text, x + cx_pad, cursor_y, w - cx_pad * 2, "center")
    cursor_y = cursor_y + fonts.sm:getHeight() + math.floor(6 * s)

    Theme.setColor(Theme.fg.primary)
    love.graphics.printf(spec.bonus_text or "", x + cx_pad, cursor_y,
                         w - cx_pad * 2, "center")
    cursor_y = cursor_y + fonts.sm:getHeight() + math.floor(2 * s)

    -- XP action — what actually grants XP to this deck. Muted color so
    -- it reads as supplementary detail rather than headline.
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(spec.xp_action_text or "", x + cx_pad, cursor_y,
                         w - cx_pad * 2, "center")
    cursor_y = cursor_y + fonts.sm:getHeight() + math.floor(8 * s)

    -- XP bar — track + fill. Maxed deck shows a full track in the good
    -- color so the player gets the "completed" read at a glance.
    local bar_x = x + cx_pad
    local bar_w = w - cx_pad * 2
    local bar_h = math.floor(XP_BAR_H_BASE * s)
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", bar_x, cursor_y, bar_w, bar_h, 2)

    local into, span = Decks.progressInLevel(spec, level, xp)
    local fill_frac
    local bar_color = Theme.status.good
    if span then
        fill_frac = math.max(0, math.min(1, into / span))
        bar_color = Theme.fg.heading
    else
        fill_frac = 1
    end
    Theme.setColor(bar_color)
    love.graphics.rectangle("fill", bar_x, cursor_y,
        math.floor(bar_w * fill_frac), bar_h, 2)
    cursor_y = cursor_y + bar_h + math.floor(4 * s)

    -- XP numbers under the bar.
    Theme.setColor(Theme.fg.faint)
    love.graphics.setFont(fonts.sm)
    local xp_text
    if span then
        xp_text = string.format("%d / %d XP", math.floor(into), math.floor(span))
    else
        xp_text = "MAX"
    end
    love.graphics.printf(xp_text, x + cx_pad, cursor_y, w - cx_pad * 2, "center")

    -- Stash hit rect.
    self._tiles[#self._tiles + 1] = { id = spec.id, x = x, y = y, w = w, h = h }
end

function DeckSelectModal:draw()
    local fonts = self.game.fonts
    local s     = (self.game.ui_scale) or 1

    local tile_w = math.floor(TILE_W_BASE * s)
    local tile_h = math.floor(TILE_H_BASE * s)
    local tile_gap = math.floor(TILE_GAP_BASE * s)
    local btn_h = math.floor(BTN_H_BASE * s)
    local footer_h = fonts.sm:getHeight() * 2 + math.floor(12 * s)
    local body_h = tile_h + math.floor(8 * s) + footer_h
                   + math.floor(12 * s) + btn_h + math.floor(20 * s)

    local body = self._modal:draw(fonts, body_h)

    -- Tile row, centered in the body. Iterate the deck roster from the
    -- model layer (only unlocked decks; current build seeds all-unlocked
    -- but the system supports a partial roster).
    self._tiles = {}
    local state = self.game.state
    local unlocked = state.unlocked_decks or {}
    local n = #unlocked
    local row_w = n * tile_w + math.max(0, n - 1) * tile_gap
    local row_x = body.x + math.floor((body.w - row_w) / 2)
    local row_y = body.y

    for i, id in ipairs(unlocked) do
        local spec = Decks.specById(id)
        if spec then
            local tx = row_x + (i - 1) * (tile_w + tile_gap)
            drawTile(self, spec, tx, row_y, tile_w, tile_h, fonts, s)
        end
    end

    -- Footer: explain that all unlocked decks contribute their banked
    -- passive simultaneously — the swap only decides who gets XP. Read-
    -- only mode adds a "click anywhere to dismiss" hint instead of the
    -- swap-context line.
    local footer_y = row_y + tile_h + math.floor(10 * s)
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(
        "All unlocked decks contribute their bonus at all times — even when not active.",
        body.x, footer_y, body.w, "center")
    if self.read_only then
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf("Swap decks at the post-shove screen.",
            body.x, footer_y + fonts.sm:getHeight() + math.floor(2 * s),
            body.w, "center")
    else
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf("Click a deck to set it active for your next run.",
            body.x, footer_y + fonts.sm:getHeight() + math.floor(2 * s),
            body.w, "center")
    end

    -- Continue button at the bottom of the body. Click resolves the
    -- modal so the host (ShoveState or GrindState) can dismiss.
    local btn_w = math.floor(BTN_W_BASE * s)
    local btn_x = body.x + math.floor((body.w - btn_w) / 2)
    local btn_y = body.y + body.h - btn_h - math.floor(4 * s)
    self._continue_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }

    local mx, my = love.mouse.getPosition()
    local hov = mx >= btn_x and mx < btn_x + btn_w
                and my >= btn_y and my < btn_y + btn_h
    LabelButton.draw{
        x = btn_x, y = btn_y, w = btn_w, h = btn_h,
        text         = "Continue",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = hov,
        depth        = 3,
        fill_token   = hov and Theme.status.good or Theme.bg.widget,
        border_token = Theme.status.good,
        text_token   = hov and Theme.bg.window or Theme.status.good,
    }

    self._modal:endDraw()
end

return DeckSelectModal
