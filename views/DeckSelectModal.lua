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

local Anchors        = require("services.AnchorRegistry")
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
local TILE_W_BASE      = 130
local TILE_H_BASE      = 160
local TILE_GAP_X_BASE  = 12
local TILE_GAP_Y_BASE  = 10
local TILES_PER_ROW    = 4
local DETAILS_W_BASE   = 250
local GAP_MIDDLE_BASE  = 24
local MODAL_W_BASE     = (TILE_W_BASE * TILES_PER_ROW + TILE_GAP_X_BASE * (TILES_PER_ROW - 1)) + GAP_MIDDLE_BASE + DETAILS_W_BASE + 48  -- 878px total width
local INFO_PANEL_FRAC  = 0.40   -- bottom 40% of the tile is the info panel
local INFO_PANEL_ALPHA = 0.88   -- panel opacity (1.0 = card art hidden behind it)
local BTN_W_BASE       = 200
local BTN_H_BASE       = 40
local XP_BAR_H_BASE    = 6

function DeckSelectModal:new(game, opts)
    opts = opts or {}
    local s = (game.ui_scale) or 1
    local modal_w = math.floor(MODAL_W_BASE * s)
    local title = opts.read_only and "YOUR DECKS" or "CHOOSE YOUR DECK"

    -- Ensure any stats-based unlocks (such as the Master deck on loading a save)
    -- are fully synced before the modal is rendered or deck choices are made.
    Decks.checkPendingUnlocks(game.state, game.unlock_rules)

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

    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local sprite = self.game.sprite_loader:getSprite(spec.sprite)
    if sprite then
        local sw, sh = sprite:getWidth(), sprite:getHeight()
        local scale = math.max(w / sw, h / sh)
        local draw_w = sw * scale
        local draw_h = sh * scale
        local draw_x = x + math.floor((w - draw_w) / 2)
        local draw_y = y + math.floor((h - draw_h) / 2)
        love.graphics.setScissor(x, y, w, h)

        -- Dynamic shaders for level progression:
        -- L0 = sepia/dirty desaturated card back
        -- L5 = holographic foil shader
        local ShaderRegistry = require("services.ShaderRegistry")
        local active_shader = nil
        if level == 0 then
            active_shader = ShaderRegistry.get("dirty")
        elseif level == 5 then
            active_shader = ShaderRegistry.get("foil")
            if active_shader then
                active_shader:send("u_time", self.game.time.total_time)
            end
        end

        if active_shader then
            love.graphics.setShader(active_shader)
        end

        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, draw_x, draw_y, 0, scale, scale)

        if active_shader then
            love.graphics.setShader()
        end
        love.graphics.setScissor()
    end

    -- Unified Border drawing: L2-L4 use Bronze/Silver/Gold borders, L5 uses Epic Purple, L0-L1 use standard soft/active highlights.
    local border_color = Theme.border.soft
    local border_width = 1
    local border_inset = 0

    if active then
        border_color = Theme.fg.heading
        border_width = Theme.space.line_strong or 2
    end

    if level >= 2 and level <= 4 then
        local border_colors = {
            [2] = { 0.72, 0.45, 0.20, 1.0 }, -- Bronze
            [3] = { 0.80, 0.80, 0.85, 1.0 }, -- Silver
            [4] = { 0.98, 0.82, 0.12, 1.0 }, -- Gold
        }
        border_color = border_colors[level]
        if active then
            border_width = math.max(6, math.floor(10 * s))
        else
            border_width = math.max(4, math.floor(6 * s))
        end
        border_inset = math.floor(border_width / 2)
    end

    Theme.setColor(border_color)
    love.graphics.setLineWidth(border_width)
    love.graphics.rectangle("line", x + border_inset, y + border_inset, w - border_inset * 2, h - border_inset * 2, Theme.space.radius)
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

    -- Name (sm). Wrap-aware advance.
    local name_color = unlocked
        and (active and Theme.fg.heading or Theme.fg.primary)
        or  Theme.fg.faint
    Theme.setColor(name_color)
    love.graphics.setFont(fonts.sm)
    cursor_y = printCenteredWrapped(spec.name or spec.id,
                                    content_x, cursor_y, content_w, fonts.sm)
    cursor_y = cursor_y + math.floor(2 * s)

    if not unlocked then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.status.error)
        cursor_y = printCenteredWrapped("LOCKED",
                                        content_x, cursor_y, content_w, fonts.sm)

        self._tiles[#self._tiles + 1] = {
            id = spec.id, x = x, y = y, w = w, h = h, unlocked = false,
        }
        if #self._tiles == 1 then Anchors.set("deck:tile:1", x, y, w, h) end
        return
    end

    -- Unlocked path: level / XP progress bar.
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local xp    = (state.deck_xp     and state.deck_xp[spec.id])     or 0

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.sm)
    local lvl_text = "L" .. tostring(level) .. " / " .. tostring(spec.max_level)
    cursor_y = printCenteredWrapped(lvl_text,
                                    content_x, cursor_y, content_w, fonts.sm)

    -- Draw XP progress bar at a fixed bottom position
    local bar_h  = math.floor(XP_BAR_H_BASE * s)
    local bar_y  = y + h - bar_h - math.floor(6 * s)

    -- Draw the XP progress bar background
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", content_x, bar_y, content_w, bar_h, 2)

    -- Draw the XP progress bar fill
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
    love.graphics.rectangle("fill", content_x, bar_y,
        math.floor(content_w * fill_frac), bar_h, 2)

    self._tiles[#self._tiles + 1] = {
        id = spec.id, x = x, y = y, w = w, h = h, unlocked = true,
    }
    if #self._tiles == 1 then
        Anchors.set("deck:tile:1", x, y, w, h)
        Anchors.set("deck:xp", content_x, bar_y, content_w, bar_h)
    end
end

local function drawDetailsPanel(self, spec, rx, ry, rw, rh, fonts, s, unlocked)
    local state = self.game.state
    local pad = math.floor(12 * s)
    local cx = rx + pad
    local cw = rw - pad * 2
    local cy = ry + pad

    -- Title
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.heading)
    cy = printCenteredWrapped(spec.name or spec.id, cx, cy, cw, fonts.md)
    cy = cy + math.floor(4 * s)

    -- Status / Level
    love.graphics.setFont(fonts.sm)
    if not unlocked then
        Theme.setColor(Theme.status.error)
        cy = printCenteredWrapped("LOCKED", cx, cy, cw, fonts.sm)
    else
        local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
        Theme.setColor(Theme.fg.muted)
        cy = printCenteredWrapped("Level " .. level .. " / " .. spec.max_level, cx, cy, cw, fonts.sm)
    end
    cy = cy + math.floor(8 * s)

    -- Mini card back preview
    local preview_w = math.floor(70 * s)
    local preview_h = math.floor(95 * s)
    local preview_x = rx + math.floor((rw - preview_w) / 2)
    
    -- Draw sunken preview box
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", preview_x, cy, preview_w, preview_h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", preview_x, cy, preview_w, preview_h, Theme.space.radius)

    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local sprite = self.game.sprite_loader:getSprite(spec.sprite)
    if sprite then
        local sw, sh = sprite:getWidth(), sprite:getHeight()
        local scale = math.min(preview_w / sw, preview_h / sh)
        local draw_w = sw * scale
        local draw_h = sh * scale
        local draw_x = preview_x + math.floor((preview_w - draw_w) / 2)
        local draw_y = cy + math.floor((preview_h - draw_h) / 2)
        love.graphics.setScissor(preview_x, cy, preview_w, preview_h)

        -- Shaders for level progression
        local ShaderRegistry = require("services.ShaderRegistry")
        local active_shader = nil
        if level == 0 then
            active_shader = ShaderRegistry.get("dirty")
        elseif level == 5 then
            active_shader = ShaderRegistry.get("foil")
            if active_shader then
                active_shader:send("u_time", self.game.time.total_time)
            end
        end

        if active_shader then
            love.graphics.setShader(active_shader)
        end

        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, draw_x, draw_y, 0, scale, scale)

        if active_shader then
            love.graphics.setShader()
        end
        love.graphics.setScissor()

        -- Unified border drawing for details preview
        local active = (spec.id == state.active_deck_id)
        local border_color = Theme.border.soft
        local border_width = 1
        local border_inset = 0

        if active then
            border_color = Theme.fg.heading
            border_width = Theme.space.line_strong or 2
        end

        if level >= 2 and level <= 4 then
            local border_colors = {
                [2] = { 0.72, 0.45, 0.20, 1.0 }, -- Bronze
                [3] = { 0.80, 0.80, 0.85, 1.0 }, -- Silver
                [4] = { 0.98, 0.82, 0.12, 1.0 }, -- Gold
            }
            border_color = border_colors[level]
            if active then
                border_width = math.max(5, math.floor(8 * s))
            else
                border_width = math.max(3, math.floor(5 * s))
            end
            border_inset = math.floor(border_width / 2)
        end

        Theme.setColor(border_color)
        love.graphics.setLineWidth(border_width)
        love.graphics.rectangle("line", preview_x + border_inset, cy + border_inset, preview_w - border_inset * 2, preview_h - border_inset * 2, Theme.space.radius)
        love.graphics.setLineWidth(1)
    else
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.faint, 0.4)
        love.graphics.printf("?", preview_x, cy + math.floor((preview_h - fonts.md:getHeight()) / 2), preview_w, "center")
    end
    cy = cy + preview_h + math.floor(10 * s)

    -- Thin separator
    Theme.setColor(Theme.border.soft, 0.7)
    love.graphics.rectangle("fill", rx + 8, cy, rw - 16, 1)
    cy = cy + math.floor(8 * s)

    -- Info text area
    love.graphics.setFont(fonts.sm)
    if not unlocked then
        Theme.setColor(Theme.status.error)
        cy = printCenteredWrapped("Unlock Requirement:", cx, cy, cw, fonts.sm)
        cy = cy + math.floor(4 * s)
        Theme.setColor(Theme.fg.primary)
        cy = printCenteredWrapped((spec.unlock and spec.unlock.text) or "Locked.", cx, cy, cw, fonts.sm)
    else
        local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
        -- Passive
        Theme.setColor(Theme.fg.muted)
        cy = printCenteredWrapped("Passive Bonus:", cx, cy, cw, fonts.sm)
        cy = cy + math.floor(2 * s)
        Theme.setColor(Theme.fg.primary)
        cy = printCenteredWrapped(spec.bonus_text or "", cx, cy, cw, fonts.sm)
        cy = cy + math.floor(8 * s)

        -- Capstone
        if spec.capstone and spec.capstone.text then
            local active = level >= (spec.max_level or 5)
            Theme.setColor(active and Theme.fg.heading or Theme.fg.muted)
            local label = active and "Capstone (Active):" or "Capstone (Locked):"
            cy = printCenteredWrapped(label, cx, cy, cw, fonts.sm)
            cy = cy + math.floor(2 * s)
            Theme.setColor(active and Theme.fg.heading or Theme.fg.faint)
            cy = printCenteredWrapped(spec.capstone.text, cx, cy, cw, fonts.sm)
            cy = cy + math.floor(8 * s)
        end

        -- XP Rule
        Theme.setColor(Theme.fg.muted)
        cy = printCenteredWrapped("XP Action:", cx, cy, cw, fonts.sm)
        cy = cy + math.floor(2 * s)
        Theme.setColor(Theme.fg.primary)
        cy = printCenteredWrapped(spec.xp_action_text or "", cx, cy, cw, fonts.sm)
    end
end

function DeckSelectModal:draw()
    local fonts = self.game.fonts
    local W, H  = love.graphics.getDimensions()
    local s     = (self.game.ui_scale) or 1

    -- Clamp scale to ensure the modal never overflows the screen width or height.
    -- This prevents the modal box from getting capped and overlapping the button/text.
    local max_modal_w = W * 0.95
    local max_s_width = max_modal_w / MODAL_W_BASE

    local h_base = fonts.lg:getHeight() + fonts.sm:getHeight() * 2 + 76
    local h_scale = 596
    local max_modal_h = H * 0.90
    local max_s_height = (max_modal_h - h_base) / h_scale

    s = math.min(s, max_s_width, max_s_height)
    if s < 0.4 then s = 0.4 end

    -- Re-sync the frame width to the live scale so the modal resizes correctly
    -- if the window changes size while it's open (width was baked at :new).
    self._modal.w = math.floor(MODAL_W_BASE * s)

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
    local grid_panel_w = (TILE_W_BASE * TILES_PER_ROW + TILE_GAP_X_BASE * (TILES_PER_ROW - 1)) * s

    -- Left panel: Grid of 12 compact deck tiles (4 columns x 3 rows)
    for idx, spec in ipairs(all_specs) do
        local row    = math.floor((idx - 1) / TILES_PER_ROW)
        local col    = (idx - 1) % TILES_PER_ROW
        local tiles_in_row
        if row == n_rows - 1 then
            tiles_in_row = n - row * TILES_PER_ROW
        else
            tiles_in_row = TILES_PER_ROW
        end
        local row_w = tiles_in_row * tile_w + math.max(0, tiles_in_row - 1) * tile_gap_x
        local row_x = body.x + math.floor((grid_panel_w - row_w) / 2)
        local tx    = row_x + col * (tile_w + tile_gap_x)
        local ty    = body.y + row * (tile_h + tile_gap_y)
        local unlocked = Decks.isUnlocked(state, spec, unlock_registry)
        drawTile(self, spec, tx, ty, tile_w, tile_h, fonts, s, unlocked)
    end

    -- Right panel: Details panel showing the full rules/passive/capstone of the hovered/equipped deck
    local rx = body.x + grid_panel_w + math.floor(GAP_MIDDLE_BASE * s)
    local ry = body.y
    local rw = math.floor(DETAILS_W_BASE * s)
    local rh = grid_h

    -- Draw details panel container box
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", rx, ry, rw, rh, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", rx, ry, rw, rh, Theme.space.radius)

    -- Hover detection
    local mx, my = love.mouse.getPosition()
    local hovered_spec = nil
    for _, tile in ipairs(self._tiles) do
        if mx >= tile.x and mx < tile.x + tile.w
           and my >= tile.y and my < tile.y + tile.h then
            for _, spec in ipairs(all_specs) do
                if spec.id == tile.id then
                    hovered_spec = { spec = spec, unlocked = tile.unlocked }
                    break
                end
            end
            break
        end
    end

    local detail_spec, detail_unlocked
    if hovered_spec then
        detail_spec = hovered_spec.spec
        detail_unlocked = hovered_spec.unlocked
    else
        local active_id = state.active_deck_id or "standard"
        detail_spec = Decks.specById(active_id) or all_specs[1]
        detail_unlocked = Decks.isUnlocked(state, detail_spec, unlock_registry)
    end

    drawDetailsPanel(self, detail_spec, rx, ry, rw, rh, fonts, s, detail_unlocked)

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
    Anchors.set("deck:continue", btn_x, btn_y, btn_w, btn_h)

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
