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
-- Locked decks render as dim silhouettes with their unlock requirement
-- text in place of the bonus / XP-bar block. Clicks on locked tiles are
-- inert in select mode.
--
-- Pure presentation. Tile clicks (in select mode only, on unlocked tiles)
-- dispatch through state:setActiveDeck (a model-side guarded write); the
-- modal never mutates state.active_deck_id directly.

local Theme       = require("views.Theme")
local Modal       = require("views.widgets.Modal")
local LabelButton = require("views.widgets.LabelButton")
local Decks       = require("models.Decks")

local DeckSelectModal = {}
DeckSelectModal.__index = DeckSelectModal

-- Layout: 4 columns × up-to-2 rows. Modal width is sized for 4 tiles +
-- their gaps plus modal padding. Roster of 7 fills row-major: 4 on top,
-- 3 centered on the bottom.
--
-- Each tile is a card: the card-back sprite scales to FILL the tile area
-- (cover semantics, cropped to tile bounds via scissor), and a
-- semi-transparent dark info panel overlays the bottom portion of the
-- tile to carry the name / level / bonus / xp action / xp bar text. The
-- card art reads behind the panel for atmosphere; the text reads on top
-- against the dark fill for legibility.
local MODAL_W_BASE     = 920
local TILE_W_BASE      = 200
local TILE_H_BASE      = 240
local TILE_GAP_X_BASE  = 16
local TILE_GAP_Y_BASE  = 12
local INFO_PANEL_FRAC  = 0.70   -- bottom 70% of the tile is the info panel
local INFO_PANEL_ALPHA = 0.88   -- panel opacity (1.0 = card art hidden behind it)
local BTN_W_BASE       = 200
local BTN_H_BASE       = 40
local XP_BAR_H_BASE    = 6
local TILES_PER_ROW    = 4

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
        _modal         = Modal:new{ title = title, w = modal_w, max_h_frac = 0.95 },
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

-- Click handler. Continue button always resolves. Read-only mode: any
-- click dismisses. Select mode: clicks on UNLOCKED tiles set the active
-- deck; clicks on locked tiles are inert (the unlock requirement text
-- is the answer the modal already gives).
function DeckSelectModal:consumeMouse(mx, my, button)
    if button ~= 1 or self._resolved then return true end

    local r = self._continue_rect
    if r and mx >= r.x and mx < r.x + r.w
       and my >= r.y and my < r.y + r.h then
        self._resolved = true
        return true
    end

    if self.read_only then
        self._resolved = true
        return true
    end

    for _, tile in ipairs(self._tiles) do
        if tile.unlocked
           and mx >= tile.x and mx < tile.x + tile.w
           and my >= tile.y and my < tile.y + tile.h then
            self.game.state:setActiveDeck(tile.id)
            return true
        end
    end
    return true
end

-- Print centered, wrap-aware. Returns the y-cursor advanced by the actual
-- rendered height (one line tall when the text fits, N lines tall when
-- printf wraps it). Without this the cursor_y advances by one line and
-- subsequent draws overlap any wrapped text.
local function printCenteredWrapped(text, x, y, w, font)
    love.graphics.printf(text or "", x, y, w, "center")
    local _, lines = font:getWrap(text or "", w)
    local n = #lines
    if n < 1 then n = 1 end
    return y + n * font:getHeight()
end

-- Draw a single deck tile. Card art fills the tile (scaled to cover,
-- cropped via scissor); a semi-transparent dark info panel overlays
-- the bottom portion to carry the text. Locked tiles render as
-- silhouettes (sprite skipped, dark fill + "?" placeholder) and replace
-- the level/bonus/xp content with the LOCKED + unlock-text block.
-- Returns nothing; stashes hit rect on self._tiles with `unlocked` flag
-- for the click handler.
local function drawTile(self, spec, x, y, w, h, fonts, s, unlocked)
    local state = self.game.state
    local active = unlocked and (state.active_deck_id == spec.id)

    -- Background fill in case the sprite is missing or doesn't fully
    -- cover the rounded corners' edge pixels.
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)

    -- Card-back sprite as the entire tile background — only when the
    -- deck is unlocked. Locked decks keep the dark sunken fill so they
    -- read as silhouettes (card shape only, no art revealed). Scale
    -- to FILL (cover) — pick the larger of the two ratios so neither
    -- dimension shows background; clip via scissor so the overflow is
    -- cropped at the tile bounds.
    local sprite = self.game.sprite_loader:getSprite(spec.sprite)
    if sprite and unlocked then
        local sw, sh = sprite:getWidth(), sprite:getHeight()
        local scale = math.max(w / sw, h / sh)
        local draw_w = sw * scale
        local draw_h = sh * scale
        local draw_x = x + math.floor((w - draw_w) / 2)
        local draw_y = y + math.floor((h - draw_h) / 2)
        love.graphics.setScissor(x, y, w, h)
        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, draw_x, draw_y, 0, scale, scale)
        love.graphics.setScissor()
    elseif not unlocked then
        -- Silhouette treatment: the dark sunken background already
        -- covers the tile. Drop a faint "?" glyph centered in the card-
        -- art band as a visual placeholder for the hidden deck.
        local panel_h_preview = math.floor(h * INFO_PANEL_FRAC)
        local art_band_h      = h - panel_h_preview
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.faint, 0.5)
        love.graphics.printf("?", x,
            y + math.floor((art_band_h - fonts.md:getHeight()) / 2),
            w, "center")
    end

    -- Border. Active gets the heading-color stronger line for the
    -- "currently equipped" read.
    local border_color = active and Theme.fg.heading or Theme.border.soft
    Theme.setColor(border_color)
    love.graphics.setLineWidth(active and Theme.space.line_strong or 1)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- ACTIVE badge top-right (drawn over the card art).
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

    -- Info panel: bottom INFO_PANEL_FRAC of the tile, semi-transparent
    -- dark fill so the card art is faintly visible behind the text.
    local panel_h = math.floor(h * INFO_PANEL_FRAC)
    local panel_y = y + h - panel_h
    Theme.setColor(Theme.bg.window, INFO_PANEL_ALPHA)
    love.graphics.rectangle("fill", x, panel_y, w, panel_h, Theme.space.radius)
    -- Thin separator line at the panel's top edge so it visually divides
    -- the card-art band above from the info band below.
    Theme.setColor(Theme.border.soft, 0.7)
    love.graphics.rectangle("fill", x + 4, panel_y, w - 8, 1)

    local cx_pad     = math.floor(10 * s)
    local cursor_y   = panel_y + math.floor(8 * s)
    local content_x  = x + cx_pad
    local content_w  = w - cx_pad * 2

    -- Name (md). Wrap-aware advance.
    local name_color = unlocked
        and (active and Theme.fg.heading or Theme.fg.primary)
        or  Theme.fg.faint
    Theme.setColor(name_color)
    love.graphics.setFont(fonts.md)
    cursor_y = printCenteredWrapped(spec.name or spec.id,
                                    content_x, cursor_y, content_w, fonts.md)
    cursor_y = cursor_y + math.floor(4 * s)

    if not unlocked then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.status.error)
        cursor_y = printCenteredWrapped("LOCKED",
                                        content_x, cursor_y, content_w, fonts.sm)
        cursor_y = cursor_y + math.floor(8 * s)

        Theme.setColor(Theme.fg.muted)
        local unlock_text = (spec.unlock and spec.unlock.text) or "Locked."
        cursor_y = printCenteredWrapped(unlock_text,
                                        content_x, cursor_y, content_w, fonts.sm)

        self._tiles[#self._tiles + 1] = {
            id = spec.id, x = x, y = y, w = w, h = h, unlocked = false,
        }
        return
    end

    -- Unlocked path: level / bonus / xp-action / bar.
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 1
    local xp    = (state.deck_xp     and state.deck_xp[spec.id])     or 0

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.sm)
    local lvl_text = "L" .. tostring(level) .. " / " .. tostring(spec.max_level)
    cursor_y = printCenteredWrapped(lvl_text,
                                    content_x, cursor_y, content_w, fonts.sm)
    cursor_y = cursor_y + math.floor(4 * s)

    Theme.setColor(Theme.fg.primary)
    cursor_y = printCenteredWrapped(spec.bonus_text or "",
                                    content_x, cursor_y, content_w, fonts.sm)
    cursor_y = cursor_y + math.floor(2 * s)

    Theme.setColor(Theme.fg.muted)
    cursor_y = printCenteredWrapped(spec.xp_action_text or "",
                                    content_x, cursor_y, content_w, fonts.sm)
    cursor_y = cursor_y + math.floor(6 * s)

    local bar_h = math.floor(XP_BAR_H_BASE * s)
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", content_x, cursor_y, content_w, bar_h, 2)

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
    love.graphics.rectangle("fill", content_x, cursor_y,
        math.floor(content_w * fill_frac), bar_h, 2)

    -- Explicit XP numbers were removed from the tile — the bar carries
    -- the progress read here. The full "X / Y XP to L_n" breakdown lives
    -- in the top-bar deck-chip tooltip for the active deck.

    self._tiles[#self._tiles + 1] = {
        id = spec.id, x = x, y = y, w = w, h = h, unlocked = true,
    }
end

function DeckSelectModal:draw()
    local fonts = self.game.fonts
    local s     = (self.game.ui_scale) or 1

    local tile_w     = math.floor(TILE_W_BASE * s)
    local tile_h     = math.floor(TILE_H_BASE * s)
    local tile_gap_x = math.floor(TILE_GAP_X_BASE * s)
    local tile_gap_y = math.floor(TILE_GAP_Y_BASE * s)
    local btn_h      = math.floor(BTN_H_BASE * s)

    local all_specs = Decks.all()
    local n = #all_specs
    local n_rows = math.ceil(n / TILES_PER_ROW)
    local grid_h = n_rows * tile_h + math.max(0, n_rows - 1) * tile_gap_y
    local footer_h = fonts.sm:getHeight() * 2 + math.floor(12 * s)
    local body_h = grid_h + math.floor(12 * s) + footer_h
                   + math.floor(12 * s) + btn_h + math.floor(20 * s)

    local body = self._modal:draw(fonts, body_h)

    self._tiles = {}
    local state = self.game.state
    local unlock_registry = self.game.unlock_rules

    for idx, spec in ipairs(all_specs) do
        local row    = math.floor((idx - 1) / TILES_PER_ROW)
        local col    = (idx - 1) % TILES_PER_ROW
        -- Last row may have fewer than TILES_PER_ROW tiles; centre it.
        local tiles_in_row
        if row == n_rows - 1 then
            tiles_in_row = n - row * TILES_PER_ROW
        else
            tiles_in_row = TILES_PER_ROW
        end
        local row_w = tiles_in_row * tile_w + math.max(0, tiles_in_row - 1) * tile_gap_x
        local row_x = body.x + math.floor((body.w - row_w) / 2)
        local tx    = row_x + col * (tile_w + tile_gap_x)
        local ty    = body.y + row * (tile_h + tile_gap_y)
        local unlocked = Decks.isUnlocked(state, spec, unlock_registry)
        drawTile(self, spec, tx, ty, tile_w, tile_h, fonts, s, unlocked)
    end

    -- Footer: active-only-XP rule + stacking rule + mode hint.
    local footer_y = body.y + grid_h + math.floor(12 * s)
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.printf(
        "Only the active deck earns XP. All unlocked decks' bonuses still apply.",
        body.x, footer_y, body.w, "center")
    Theme.setColor(Theme.fg.faint)
    if self.read_only then
        love.graphics.printf("Swap at the post-shove screen to train a different deck.",
            body.x, footer_y + fonts.sm:getHeight() + math.floor(2 * s),
            body.w, "center")
    else
        love.graphics.printf("Click an unlocked deck to train it on your next run.",
            body.x, footer_y + fonts.sm:getHeight() + math.floor(2 * s),
            body.w, "center")
    end

    -- Continue button. Click resolves the modal so the host (ShoveState
    -- or GrindState) can dismiss.
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
