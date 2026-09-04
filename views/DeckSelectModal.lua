-- views/DeckSelectModal.lua
--
-- The roster: every deck on one screen, each tile telling its own story.
--
-- Two modes via :new(game, opts):
--   • Select (default) — post-shove. Clicking an unlocked tile puts that deck
--     in play for the next run (state:setActiveDeck, a guarded write).
--   • Read-only (opts.read_only) — mid-grind, from the top-bar cell. Same
--     screen; clicking a tile only shows it in the column. Swapping stays a
--     post-shove act on purpose: a fresh L0 deck at a new stake would max in
--     a hand if it could be swapped in mid-run.
--
-- A TILE carries: the art with its level pips (views/DeckArt), the name,
-- what fills its bar, and the bar itself — no numbers. A LOCKED tile fills
-- bottom-up with progress toward its unlock (the art saturates up to a fill
-- line) under a COMING SOON sticker (views/widgets/Sticker, the catalog's
-- own, seeded by services/Decal so it sits still) that names the condition
-- and counts it. The deck in play wears an IN PLAY tab on its panel and a
-- green frame; a maxed deck shows as five pips, foil art and a gold bar.
--
-- The COLUMN shows one deck in full — the deck in play until a tile is
-- clicked, then that one. Hover never changes it.
--
-- Pure presentation; the modal never mutates deck state directly.

local Anchors     = require("services.AnchorRegistry")
local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")
local Sticker     = require("views.widgets.Sticker")
local Decal       = require("services.Decal")
local Decks       = require("models.Decks")
local DeckArt     = require("views.DeckArt")
local IconText    = require("views.IconText")
local HoverSvc    = require("services.HoverService")
local Format      = require("utils.format")

local DeckSelectModal = {}
DeckSelectModal.__index = DeckSelectModal

-- Layout: 4 columns × 3 rows of tiles, a column of detail on the right.
local TILE_W_BASE      = 130
local TILE_H_BASE      = 160
local TILE_GAP_X_BASE  = 12
local TILE_GAP_Y_BASE  = 10
local TILES_PER_ROW    = 4
local DETAILS_W_BASE   = 250
local GAP_MIDDLE_BASE  = 24
local GRID_W_BASE      = TILE_W_BASE * TILES_PER_ROW + TILE_GAP_X_BASE * (TILES_PER_ROW - 1)
local MODAL_W_BASE     = GRID_W_BASE + GAP_MIDDLE_BASE + DETAILS_W_BASE + 48
local INFO_PANEL_FRAC  = 0.46   -- bottom of the tile: name, what levels it (2 lines), the bar
local INFO_PANEL_ALPHA = 0.88
local BTN_W_BASE       = 200
local BTN_H_BASE       = 40
local XP_BAR_H_BASE    = 6
local PREVIEW_W_BASE   = 70
local PREVIEW_H_BASE   = 95

-- The catalog's sticker palettes (views/CatalogModal), so a sticker here is
-- the same object the player peeled there. Cream promo stock, amber while
-- counting, green once earned; gold for a maxed deck.
local STICKER_STOCK = { 1.00, 1.00, 1.00 }
local STICKER_PANEL = { 1.00, 0.97, 0.88 }
local STICKER_INK   = { 0.15, 0.15, 0.12 }
local STICKER_EDGE  = { 0.15, 0.15, 0.12, 0.45 }
local FILL_COUNTING = { 0.88, 0.62, 0.10 }
local FILL_EARNED   = { 0.20, 0.58, 0.28 }

local STICKER_COMING = "COMING SOON!"

function DeckSelectModal:new(game, opts)
    opts = opts or {}
    local s = (game.ui_scale) or 1
    local title = opts.read_only and "YOUR DECKS" or "CHOOSE YOUR DECK"

    -- Any unlock met since the last sweep flips in before the roster shows.
    Decks.checkPendingUnlocks(game.state, game.unlock_rules)

    return setmetatable({
        game           = game,
        read_only      = opts.read_only or false,
        _resolved      = false,
        _continue_rect = nil,
        _tiles         = {},
        _detail_id     = game.state.active_deck_id,
        _modal         = Modal:new{ title = title, w = math.floor(MODAL_W_BASE * s), max_h_frac = 0.95 },
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

-- Continue resolves. A tile click shows that deck in the column; in select
-- mode an unlocked tile also goes into play. Read-only: a click outside the
-- frame dismisses.
function DeckSelectModal:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end

    local r = self._continue_rect
    if r and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
        self._resolved = true
        return true
    end

    for _, tile in ipairs(self._tiles) do
        if mx >= tile.x and mx < tile.x + tile.w and my >= tile.y and my < tile.y + tile.h then
            self._detail_id = tile.id
            if tile.unlocked and not self.read_only then
                self.game.state:setActiveDeck(tile.id)
            end
            return true
        end
    end

    if self.read_only and self._modal and self._modal:hitTest(mx, my) ~= "inside" then
        self._resolved = true
    end
    return true
end

-- ─── Text helpers ────────────────────────────────────────────────────

-- IconText, wrapped to `w` and centred line by line. Returns the y after.
local function iconWrapCentered(game, str, x, y, w, font, color, alpha)
    for _, line in ipairs(IconText.wrap(str, font, w)) do
        local tw = IconText.measure(line, font)
        IconText.draw(game, line, x + math.floor((w - tw) / 2), y, font, color, alpha or 1)
        y = y + font:getHeight()
    end
    return y
end

local function unlockCounter(spec, current, target)
    local kind = spec.unlock and spec.unlock.kind or ""
    if kind:find("money") then
        return Format.money(current) .. " / " .. Format.money(target)
    end
    return Format.formatBig(current) .. " / " .. Format.formatBig(target)
end

-- ─── Tile ────────────────────────────────────────────────────────────

-- Unlocked: art with pips; an info panel with the name, what fills the bar
-- (wrapped), and the bar. The deck in play wears a small tab on the panel's
-- edge; a maxed deck needs nothing extra (five pips, foil art, gold bar).
-- Locked: the art alone, filling bottom-up, under the COMING SOON sticker —
-- like a stickered catalog card, what it does is not on show yet.
local function drawTile(self, spec, x, y, w, h, fonts, s, unlocked, mx, my)
    local game  = self.game
    local state = game.state
    local fl    = math.floor
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local maxed = unlocked and level >= (spec.max_level or 5)
    local in_play = unlocked and (state.active_deck_id == spec.id)
    local hov = HoverSvc.rest("button", "deck_tile:" .. spec.id,
        mx >= x and mx < x + w and my >= y and my < y + h, 0)
    local gold = Theme.currency and Theme.currency.chip or Theme.fg.heading

    if not unlocked then
        local frac, cur, target = Decks.unlockProgress(state, spec, game.unlock_rules)
        frac = frac or 0
        DeckArt.draw(game, spec, x, y, w, h, { scale = s, locked_frac = frac, pips = false })

        local title   = STICKER_COMING
        local line    = (spec.unlock and spec.unlock.text) or ""
        local counter = unlockCounter(spec, cur or 0, target or 0)
        local sh = Sticker.heightFor(fonts, s, true)
        local sw = math.min(Sticker.widthFor(fonts, s, title, line, counter), w - fl(8 * s))
        local sx = Decal.lerp("deck_st_x:" .. spec.id, 1, x + fl(4 * s), x + w - sw - fl(4 * s))
        local sy = Decal.lerp("deck_st_y:" .. spec.id, 2, y + fl(6 * s), y + h - sh - fl(6 * s))
        local _, _, angle = Decal.place("deck_sticker:" .. spec.id, { angle = 0.10 })
        Sticker.draw{
            game = game, fonts = fonts, x = sx, y = sy, w = sw, h = sh,
            scale = s, rotation = angle,
            title = title, line = line, counter = counter, progress = frac,
            stock_token = STICKER_STOCK, panel_token = STICKER_PANEL,
            fill_token = frac >= 1 and FILL_EARNED or FILL_COUNTING,
            vinyl_token = STICKER_PANEL, ink_token = STICKER_INK, edge_token = STICKER_EDGE,
        }
    else
        DeckArt.draw(game, spec, x, y, w, h, { level = level, scale = s })

        local panel_h = fl(h * INFO_PANEL_FRAC)
        local panel_y = y + h - panel_h
        Theme.setColor(Theme.bg.window, INFO_PANEL_ALPHA)
        love.graphics.rectangle("fill", x, panel_y, w, panel_h, Theme.space.radius)
        Theme.setColor(Theme.border.soft, 0.7)
        love.graphics.rectangle("fill", x + 4, panel_y, w - 8, 1)

        local pad       = fl(8 * s)
        local content_x = x + pad
        local content_w = w - pad * 2
        local bar_h     = fl(XP_BAR_H_BASE * s)
        local bar_y     = y + h - bar_h - fl(6 * s)
        local cy        = panel_y + fl(6 * s)

        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.fg.heading)
        love.graphics.printf(spec.name or spec.id, content_x, cy, content_w, "center")
        cy = cy + fonts.sm:getHeight() + fl(2 * s)
        -- What fills the bar, wrapped; stops above the bar.
        for _, ln in ipairs(IconText.wrap(spec.levels_on or "", fonts.sm, content_w)) do
            if cy + fonts.sm:getHeight() > bar_y - fl(2 * s) then break end
            local tw = IconText.measure(ln, fonts.sm)
            IconText.draw(game, ln, content_x + fl((content_w - tw) / 2), cy, fonts.sm, Theme.fg.muted, 1)
            cy = cy + fonts.sm:getHeight()
        end

        -- The bar: progress into the current level, no numbers.
        local xp = (state.deck_xp and state.deck_xp[spec.id]) or 0
        local into, span = Decks.progressInLevel(spec, level, xp)
        local fill_frac = span and math.max(0, math.min(1, into / span)) or 1
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", content_x, bar_y, content_w, bar_h, 2)
        Theme.setColor(maxed and gold or Theme.fg.heading)
        love.graphics.rectangle("fill", content_x, bar_y, fl(content_w * fill_frac), bar_h, 2)
        if #self._tiles == 0 then
            Anchors.set("deck:xp", content_x, bar_y, content_w, bar_h)
        end

        -- IN PLAY: a plate across the art, below the pips.
        if in_play then
            love.graphics.setFont(fonts.md)
            local tab_text = "IN PLAY"
            local tab_w = fonts.md:getWidth(tab_text) + fl(16 * s)
            local tab_h = fonts.md:getHeight() + fl(8 * s)
            local tab_x = x + fl((w - tab_w) / 2)
            local art_top = y + DeckArt.pipRowHeight(s)
            local tab_y = art_top + fl((panel_y - art_top - tab_h) * 0.45)
            Theme.setColor(Theme.status.good)
            love.graphics.rectangle("fill", tab_x, tab_y, tab_w, tab_h, Theme.space.radius)
            Theme.setColor(Theme.bg.window)
            love.graphics.printf(tab_text, tab_x, tab_y + fl(4 * s), tab_w, "center")
        end
    end

    -- Frame: green for the deck in play, heading for the column's deck,
    -- brighter on hover.
    local shown = (self._detail_id == spec.id)
    local frame = in_play and Theme.status.good
               or (shown and Theme.fg.heading)
               or (hov and Theme.border.strong or Theme.border.soft)
    Theme.setColor(frame)
    love.graphics.setLineWidth((in_play or shown) and (Theme.space.line_strong or 2) or 1)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    self._tiles[#self._tiles + 1] = { id = spec.id, x = x, y = y, w = w, h = h, unlocked = unlocked }
    if #self._tiles == 1 then Anchors.set("deck:tile:1", x, y, w, h) end
end

-- ─── Column ──────────────────────────────────────────────────────────

local function drawColumn(self, spec, rx, ry, rw, rh, fonts, s, unlocked)
    local game  = self.game
    local state = game.state
    local fl    = math.floor
    local pad   = fl(12 * s)
    local cx, cw = rx + pad, rw - pad * 2
    local cy    = ry + pad
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local max_level = spec.max_level or 5
    local maxed = unlocked and level >= max_level

    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", rx, ry, rw, rh, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", rx, ry, rw, rh, Theme.space.radius)

    -- Preview.
    local pw, ph = fl(PREVIEW_W_BASE * s), fl(PREVIEW_H_BASE * s)
    local px = rx + fl((rw - pw) / 2)
    local frac, cur, target
    if not unlocked then
        frac, cur, target = Decks.unlockProgress(state, spec, game.unlock_rules)
    end
    DeckArt.draw(game, spec, px, cy, pw, ph, {
        level = level, scale = s, locked_frac = (not unlocked) and (frac or 0) or nil,
    })
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", px, cy, pw, ph, Theme.space.radius)
    cy = cy + ph + fl(10 * s)

    -- Name, level.
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.heading)
    love.graphics.printf(spec.name or spec.id, cx, cy, cw, "center")
    cy = cy + fonts.md:getHeight() + fl(2 * s)
    love.graphics.setFont(fonts.sm)
    if not unlocked then
        Theme.setColor(Theme.status.error)
        love.graphics.printf("locked", cx, cy, cw, "center")
    elseif maxed then
        Theme.setColor(Theme.currency and Theme.currency.chip or Theme.fg.heading)
        love.graphics.printf("maxed", cx, cy, cw, "center")
    else
        Theme.setColor(Theme.fg.muted)
        love.graphics.printf(("level %d of %d"):format(level, max_level), cx, cy, cw, "center")
    end
    cy = cy + fonts.sm:getHeight() + fl(10 * s)

    Theme.setColor(Theme.border.soft, 0.7)
    love.graphics.rectangle("fill", rx + 8, cy, rw - 16, 1)
    cy = cy + fl(10 * s)

    -- Unlock, when locked: the condition and the count.
    if not unlocked then
        cy = iconWrapCentered(game, (spec.unlock and spec.unlock.text) or "", cx, cy, cw,
                              fonts.sm, Theme.fg.primary)
        cy = iconWrapCentered(game, unlockCounter(spec, cur or 0, target or 0), cx, cy, cw,
                              fonts.sm, Theme.status.error)
        cy = cy + fl(10 * s)
    end

    -- The bonus: what it does now, and what each level adds.
    local lvl_now = unlocked and level or 0
    if lvl_now > 0 and spec.bonus and spec.bonus.per_level then
        cy = iconWrapCentered(game, Decks.bonusTextAt(spec, lvl_now), cx, cy, cw,
                              fonts.sm, Theme.fg.heading)
        cy = iconWrapCentered(game, "(" .. Decks.bonusTextPerLevel(spec) .. ")", cx, cy, cw,
                              fonts.sm, Theme.fg.muted)
    else
        cy = iconWrapCentered(game, Decks.bonusTextPerLevel(spec), cx, cy, cw,
                              fonts.sm, Theme.fg.primary)
    end
    cy = cy + fl(8 * s)

    -- The capstone: the sixth bonus, only at level 5, with whether it's earned.
    if spec.capstone and spec.capstone.text then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(maxed and (Theme.currency and Theme.currency.chip or Theme.fg.heading) or Theme.fg.muted)
        love.graphics.printf(maxed and "Capstone - earned" or "Capstone - at level 5",
                             cx, cy, cw, "center")
        cy = cy + fonts.sm:getHeight()
        cy = iconWrapCentered(game, spec.capstone.text, cx, cy, cw, fonts.sm,
                              maxed and Theme.fg.heading or Theme.fg.muted)
        cy = cy + fl(8 * s)
    end

    cy = iconWrapCentered(game, Decks.levelsOnText(spec), cx, cy, cw, fonts.sm, Theme.fg.muted)
    cy = cy + fl(10 * s)

    if spec.flavor_text then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf(spec.flavor_text, cx, cy, cw, "center")
    end
end

-- ─── Draw ────────────────────────────────────────────────────────────

function DeckSelectModal:draw()
    local fonts = self.game.fonts
    local W, H  = love.graphics.getDimensions()
    local s     = (self.game.ui_scale) or 1
    local fl    = math.floor
    self._modal.w = fl(MODAL_W_BASE * s)

    local tile_w, tile_h = fl(TILE_W_BASE * s), fl(TILE_H_BASE * s)
    local gap_x, gap_y   = fl(TILE_GAP_X_BASE * s), fl(TILE_GAP_Y_BASE * s)
    local btn_h          = fl(BTN_H_BASE * s)

    local all_specs = Decks.all()
    local n_rows    = math.ceil(#all_specs / TILES_PER_ROW)
    local grid_h    = n_rows * tile_h + (n_rows - 1) * gap_y
    local footer_h  = fonts.sm:getHeight() * 2 + fl(12 * s)
    local body_h    = grid_h + fl(12 * s) + footer_h + fl(12 * s) + btn_h + fl(20 * s)

    local body = self._modal:draw(fonts, body_h)
    Anchors.set("story:band", 0, H - fl(56 * s), W, fl(44 * s))

    local mx, my = love.mouse.getPosition()
    local state  = self.game.state
    local reg    = self.game.unlock_rules
    local grid_w = fl(GRID_W_BASE * s)

    self._tiles = {}
    for idx, spec in ipairs(all_specs) do
        local row = fl((idx - 1) / TILES_PER_ROW)
        local col = (idx - 1) % TILES_PER_ROW
        local tx  = body.x + col * (tile_w + gap_x)
        local ty  = body.y + row * (tile_h + gap_y)
        drawTile(self, spec, tx, ty, tile_w, tile_h, fonts, s,
                 Decks.isUnlocked(state, spec, reg), mx, my)
    end

    -- The column: the clicked deck, else the deck in play.
    local detail = Decks.specById(self._detail_id) or Decks.specById(state.active_deck_id) or all_specs[1]
    drawColumn(self, detail, body.x + grid_w + fl(GAP_MIDDLE_BASE * s), body.y,
               fl(DETAILS_W_BASE * s), grid_h, fonts, s, Decks.isUnlocked(state, detail, reg))

    -- Footer.
    local footer_y = body.y + grid_h + fl(12 * s)
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf("Only the deck in play levels. Every unlocked deck's bonus stays on.",
        body.x, footer_y, body.w, "center")
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("Each level adds the bonus again. The capstone is a sixth bonus a deck gives only at level 5.",
        body.x, footer_y + fonts.sm:getHeight() + fl(2 * s), body.w, "center")

    -- Continue.
    local btn_w = fl(BTN_W_BASE * s)
    local btn_x = body.x + fl((body.w - btn_w) / 2)
    local btn_y = body.y + body.h - btn_h - fl(4 * s)
    self._continue_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }
    Anchors.set("deck:continue", btn_x, btn_y, btn_w, btn_h)
    local hov = HoverSvc.rest("button", "deck_continue",
        mx >= btn_x and mx < btn_x + btn_w and my >= btn_y and my < btn_y + btn_h, 0)
    LabelButton.draw{
        x = btn_x, y = btn_y, w = btn_w, h = btn_h,
        text = "Continue", fonts = fonts, font = fonts.md, hovered = hov, depth = 3,
        fill_token   = hov and Theme.status.good or Theme.bg.widget,
        border_token = Theme.status.good,
        text_token   = hov and Theme.bg.window or Theme.status.good,
    }

    self._modal:endDraw()
end

return DeckSelectModal
