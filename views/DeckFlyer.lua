-- views/DeckFlyer.lua
--
-- The deck PAMPHLET: a tri-fold the dealer throws onto the felt beside the
-- catalog once the deck system exists. Closed, it shows its cover — the
-- book's imprint, MAIL ORDER DECKS, the back of the deck in play. Clicking
-- it opens it out, leaf by leaf, into a three-leaf spread: the roster as
-- it always was — twelve tiles four wide, three deep, and a column on the
-- right with one deck in full — with a fold after the second column and
-- another before the column. Clicking off the spread folds it back where
-- it was. Leaving is the felt's job (CONTINUE), never the pamphlet's.
--
-- Two ways to hold one, exactly like the catalog (views/CatalogModal):
--   • on_felt (post-shove): thrown (services/Throw), lands at a Decal-hashed
--     spot clear of the book (opts.avoid), starts closed. Clicking an
--     unlocked tile puts that deck in play for the next run.
--   • read_only (mid-grind, from the top-bar cell): appears open and
--     centred over a scrim; tiles only pick what the column shows. Swapping
--     stays a post-shove act on purpose: a fresh L0 deck at a new stake
--     would max in a hand if it could be swapped in mid-run.
--
-- Palette: one fixed dark stock in the room's colours, hardcoded like the
-- book's cream so it is the same pamphlet on every screen. The stickers on
-- locked decks are the catalog's.
--
-- Pure presentation; state:setActiveDeck is the one guarded write.

local Anchors     = require("services.AnchorRegistry")
local Theme       = require("views.Theme")
local Sticker     = require("views.widgets.Sticker")
local Decal       = require("services.Decal")
local Throw       = require("services.Throw")
local Decks       = require("models.Decks")
local DeckArt     = require("views.DeckArt")
local CardSprites = require("views.CardSprites")
local IconText    = require("views.IconText")
local HoverSvc    = require("services.HoverService")
local Format      = require("utils.format")
local Motion      = require("services.Motion")

local DeckFlyer = {}
DeckFlyer.__index = DeckFlyer

-- Low motion: the pamphlet appears where it rests, faded in over
-- Motion.FADE_SECS. Every colour set in this file goes through `col`,
-- which multiplies by the fade.
local _alpha = 1
local function col(token, a)
    Theme.setColor(token, (a or token[4] or 1) * _alpha)
end

-- ─── Palette (the room's, fixed) ─────────────────────────────────────
local P = {
    stock   = { 0.145, 0.125, 0.110 },
    window  = { 0.118, 0.102, 0.090 },
    sunken  = { 0.085, 0.075, 0.065 },
    edge    = { 0.65, 0.55, 0.40 },
    rule    = { 0.40, 0.35, 0.28 },
    soft    = { 0.25, 0.22, 0.18 },
    heading = { 0.95, 0.88, 0.75 },
    primary = { 0.88, 0.82, 0.72 },
    muted   = { 0.62, 0.56, 0.46 },
    faint   = { 0.42, 0.38, 0.31 },
    good    = { 0.50, 0.78, 0.45 },
    warn    = { 0.92, 0.72, 0.32 },
    error   = { 0.82, 0.42, 0.38 },
}
local function gold() return Theme.currency and Theme.currency.chip or P.warn end

-- The catalog's sticker palette (views/CatalogModal), so a sticker here is
-- the same object the player peeled there.
local STICKER_STOCK = { 1.00, 1.00, 1.00 }
local STICKER_PANEL = { 1.00, 0.97, 0.88 }
local STICKER_INK   = { 0.15, 0.15, 0.12 }
local STICKER_EDGE  = { 0.15, 0.15, 0.12, 0.45 }
local FILL_COUNTING = { 0.88, 0.62, 0.10 }
local FILL_EARNED   = { 0.20, 0.58, 0.28 }
local STICKER_COMING = "COMING SOON!"

-- ─── Layout (design units, × ui_scale at draw) ──────────────────────
-- Leaf 1: tile columns 1-2. Leaf 2: columns 3-4. Leaf 3: the column.
local TILE_W_BASE      = 130
local TILE_H_BASE      = 160
local TILE_GAP_BASE    = 12
local TILE_GAP_Y_BASE  = 10
local ROWS             = 3
local LEAF_PAD_BASE    = 24
local LEAF_W_BASE      = LEAF_PAD_BASE * 2 + 2 * TILE_W_BASE + TILE_GAP_BASE     -- 320
local DETAILS_W_BASE   = 250
local LEAF3_W_BASE     = LEAF_PAD_BASE * 2 + DETAILS_W_BASE                       -- 298
local GRID_H_BASE      = ROWS * TILE_H_BASE + (ROWS - 1) * TILE_GAP_Y_BASE         -- 500
local INFO_PANEL_FRAC  = 0.46
local INFO_PANEL_ALPHA = 0.88
local XP_BAR_H_BASE    = 6
local PREVIEW_W_BASE   = 70
local PREVIEW_H_BASE   = 95
local FOLD_W_BASE      = 8

-- Closed on the felt: the cover leaf, scaled down like the book's cover.
local CLOSED = {
    scale        = 0.42,
    rest_x       = 0.50,
    rest_y       = 0.40,
    jitter_x     = 560,
    jitter_y     = 260,
    jitter_angle = 0.55,
    base_angle   = 0.08,
    throw_dx     = -260,     -- from the RIGHT; the book comes from the left
    throw_arc    = 60,
    throw_spin   = -1.6,
    flutter      = 6,        -- paper, not a book
    flutter_cycles = 3,
    impact_squash  = 0.05,
}
local THROW_SECS = 0.70
local OPEN_SECS  = 0.60     -- two leaves, one after the other
local AVOID_GAP  = 24

-- The print. The book's imprint, a title, a sell line. The terms are small
-- print at the foot of the column, the way the book keeps its own on the
-- back cover.
local IMPRINT   = "SEARS, ROEBUCK & CO."
local HEADLINE  = "MAIL ORDER DECKS"
local SELL      = "TWELVE DESIGNS. NO CHARGE."
local SELL_OPEN = "Twelve designs to choose from. Pick yours for the next run."
local TERMS     = "Only the deck in play levels. The rest keep their bonuses. Level 5 earns the capstone."

-- opts: on_felt, throw_key, read_only, scrim, avoid ({x,y,w,h} to land clear of)
function DeckFlyer:new(game, opts)
    opts = opts or {}
    Decks.checkPendingUnlocks(game.state, game.unlock_rules)
    local on_felt = opts.on_felt == true
    return setmetatable({
        game        = game,
        read_only   = opts.read_only == true,
        on_felt     = on_felt,
        scrim       = opts.scrim ~= false and not on_felt,
        avoid       = opts.avoid,
        _throw_key  = opts.throw_key or "flyer",
        _throw_t    = on_felt and 0 or 1,
        _open       = not on_felt,
        _open_t     = on_felt and 0 or 1,
        _resolved   = false,
        _tiles      = {},
        _felt_rect  = nil,
        _sheet_rect = nil,
        _detail_id  = game.state.active_deck_id,
    }, DeckFlyer)
end

function DeckFlyer:resolved() return self._resolved end
function DeckFlyer:isOpen()   return self._open end
-- Landed, closed, on the felt: the moment it can be pointed at.
function DeckFlyer:isLanded() return self.on_felt and not self._open and self._throw_t >= 1 end

function DeckFlyer:openFromFelt()
    if self._open then return end
    self._open   = true
    self._open_t = 0
    -- Looked at: the top-bar nudge for newly-opened decks stops.
    self.game.state.decks_unseen = {}
end

function DeckFlyer:closeToFelt()
    if not self.on_felt or not self._open then return end
    self._open = false
end

function DeckFlyer:consumeKey(key)
    if self.on_felt then
        if key == "escape" and self._open then self:closeToFelt(); return true end
        return false
    end
    if key == "escape" or key == "space" or key == "return" or key == "kpenter" then
        self._resolved = true
        return true
    end
    return false
end

-- Closed: a hit opens it (true), a miss is the felt's (false). Open: a tile
-- shows in the column (and, post-shove, goes into play); anywhere else
-- folds it back, or, read-only, closes it. Always consumed once open.
function DeckFlyer:consumeMouse(mx, my, button)
    if self.on_felt and not self._open then
        local r = self._felt_rect
        if r and button == 1 and Throw.hitsRotated(r, mx, my) then
            self:openFromFelt()
            return true
        end
        return false
    end
    if button ~= 1 or self._resolved then return true end
    if self._open_t < 1 then return true end

    for _, tile in ipairs(self._tiles) do
        if mx >= tile.x and mx < tile.x + tile.w and my >= tile.y and my < tile.y + tile.h then
            self._detail_id = tile.id
            if tile.unlocked and not self.read_only then
                self.game.state:setActiveDeck(tile.id)
            end
            return true
        end
    end

    local sr = self._sheet_rect
    local on_sheet = sr and mx >= sr.x and mx < sr.x + sr.w and my >= sr.y and my < sr.y + sr.h
    if not on_sheet then
        if self.on_felt then self:closeToFelt() else self._resolved = true end
    end
    return true
end

-- ─── Helpers ─────────────────────────────────────────────────────────

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

-- A leaf of stock: the book's double rule, in the pamphlet's own palette.
local function drawLeaf(x, y, w, h, s)
    local fl = math.floor
    col(P.stock)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    col(P.edge, 0.7)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
    col(P.rule, 0.5)
    love.graphics.rectangle("line", x + fl(5 * s), y + fl(5 * s), w - fl(10 * s), h - fl(10 * s), Theme.space.radius)
end

-- A fold at x: the valley in shadow on the left, the raised edge catching
-- light on the right — a crease, not a line.
local function drawFold(x, y, h, s)
    local fw = math.max(4, math.floor(FOLD_W_BASE * s))
    for i = 1, fw do
        local t = i / fw
        col(P.sunken, 0.6 * (1 - t))
        love.graphics.rectangle("fill", x - i, y, 1, h)
    end
    for i = 0, math.floor(fw / 2) do
        local t = i / math.max(1, math.floor(fw / 2))
        col(P.heading, 0.16 * (1 - t))
        love.graphics.rectangle("fill", x + i, y, 1, h)
    end
    col(P.sunken, 0.85)
    love.graphics.rectangle("fill", x - 1, y, 1, h)
end

-- Masthead height, from the fonts, so nothing below it can overlap.
local function mastHeight(fonts, s)
    return fonts.sm:getHeight() + fonts.lg:getHeight() + fonts.sm:getHeight() + math.floor(14 * s)
end

-- ─── Tile ────────────────────────────────────────────────────────────

-- Unlocked: art with pips; an info panel with the name, what fills the bar
-- (wrapped), and the bar. The deck in play wears an IN PLAY plate; a maxed
-- deck needs nothing extra (five pips, foil art, gold bar). Locked: the art
-- alone, filling bottom-up, under the COMING SOON sticker — like a
-- stickered catalog card, what it does is not on show yet.
local function drawTile(self, spec, x, y, w, h, fonts, s, unlocked, mx, my)
    local game  = self.game
    local state = game.state
    local fl    = math.floor
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local maxed = unlocked and level >= (spec.max_level or 5)
    local in_play = unlocked and (state.active_deck_id == spec.id)
    local hov = HoverSvc.rest("button", "deck_tile:" .. spec.id,
        mx >= x and mx < x + w and my >= y and my < y + h, 0)

    if not unlocked then
        local frac, cur, target = Decks.unlockProgress(state, spec, game.unlock_rules)
        frac = frac or 0
        DeckArt.draw(game, spec, x, y, w, h, { scale = s, locked_frac = frac, pips = false, alpha = _alpha })

        local title   = STICKER_COMING
        local line    = (spec.unlock and spec.unlock.text) or ""
        local counter = unlockCounter(spec, cur or 0, target or 0)
        -- Small headline and the count on its own row: the tile is too
        -- narrow for the big word or for a count beside the condition.
        local sh = Sticker.heightFor(fonts, s, true, true, "sm")
        local sw = math.min(Sticker.widthFor(fonts, s, title, line, nil, counter, "sm"), w - fl(8 * s))
        local sx = Decal.lerp("deck_st_x:" .. spec.id, 1, x + fl(4 * s), x + w - sw - fl(4 * s))
        local sy = Decal.lerp("deck_st_y:" .. spec.id, 2, y + fl(6 * s), y + h - sh - fl(6 * s))
        local _, _, angle = Decal.place("deck_sticker:" .. spec.id, { angle = 0.10 })
        Sticker.draw{
            game = game, fonts = fonts, x = sx, y = sy, w = sw, h = sh,
            scale = s, rotation = angle,
            title = title, line = line, line2 = counter, progress = frac, title_style = "sm",
            stock_token = STICKER_STOCK, panel_token = STICKER_PANEL,
            fill_token = frac >= 1 and FILL_EARNED or FILL_COUNTING,
            vinyl_token = STICKER_PANEL, ink_token = STICKER_INK, edge_token = STICKER_EDGE,
        }
    else
        DeckArt.draw(game, spec, x, y, w, h, { level = level, scale = s, alpha = _alpha })

        local panel_h = fl(h * INFO_PANEL_FRAC)
        local panel_y = y + h - panel_h
        col(P.window, INFO_PANEL_ALPHA)
        love.graphics.rectangle("fill", x, panel_y, w, panel_h, Theme.space.radius)
        col(P.soft, 0.7)
        love.graphics.rectangle("fill", x + 4, panel_y, w - 8, 1)

        local pad       = fl(8 * s)
        local content_x = x + pad
        local content_w = w - pad * 2
        local bar_h     = fl(XP_BAR_H_BASE * s)
        local bar_y     = y + h - bar_h - fl(6 * s)
        local cy        = panel_y + fl(6 * s)

        love.graphics.setFont(fonts.sm)
        col(P.heading)
        love.graphics.printf(spec.name or spec.id, content_x, cy, content_w, "center")
        cy = cy + fonts.sm:getHeight() + fl(2 * s)
        for _, ln in ipairs(IconText.wrap(spec.levels_on or "", fonts.sm, content_w)) do
            if cy + fonts.sm:getHeight() > bar_y - fl(2 * s) then break end
            local tw = IconText.measure(ln, fonts.sm)
            IconText.draw(game, ln, content_x + fl((content_w - tw) / 2), cy, fonts.sm, P.muted, 1)
            cy = cy + fonts.sm:getHeight()
        end

        local xp = (state.deck_xp and state.deck_xp[spec.id]) or 0
        local into, span = Decks.progressInLevel(spec, level, xp)
        local fill_frac = span and math.max(0, math.min(1, into / span)) or 1
        col(P.sunken)
        love.graphics.rectangle("fill", content_x, bar_y, content_w, bar_h, 2)
        col(maxed and gold() or P.heading)
        love.graphics.rectangle("fill", content_x, bar_y, fl(content_w * fill_frac), bar_h, 2)
        if #self._tiles == 0 then
            Anchors.set("deck:xp", content_x, bar_y, content_w, bar_h)
        end

        if in_play then
            love.graphics.setFont(fonts.md)
            local tab_text = "IN PLAY"
            local tab_w = fonts.md:getWidth(tab_text) + fl(16 * s)
            local tab_h = fonts.md:getHeight() + fl(8 * s)
            local tab_x = x + fl((w - tab_w) / 2)
            local art_top = y + DeckArt.pipRowHeight(s)
            local tab_y = art_top + fl((panel_y - art_top - tab_h) * 0.45)
            col(P.good)
            love.graphics.rectangle("fill", tab_x, tab_y, tab_w, tab_h, Theme.space.radius)
            col(P.window)
            love.graphics.printf(tab_text, tab_x, tab_y + fl(4 * s), tab_w, "center")
        end
    end

    local shown = (self._detail_id == spec.id)
    local frame = in_play and P.good or (shown and P.heading) or (hov and P.edge or P.soft)
    col(frame)
    love.graphics.setLineWidth((in_play or shown) and (Theme.space.line_strong or 2) or 1)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    self._tiles[#self._tiles + 1] = { id = spec.id, x = x, y = y, w = w, h = h, unlocked = unlocked }
    if #self._tiles == 1 then Anchors.set("deck:tile:1", x, y, w, h) end
end

-- ─── Column: one deck in full ─────────────────────────────────────────

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

    col(P.rule, 0.5)
    love.graphics.rectangle("line", rx, ry, rw, rh, Theme.space.radius)

    local pw, ph = fl(PREVIEW_W_BASE * s), fl(PREVIEW_H_BASE * s)
    local px = rx + fl((rw - pw) / 2)
    local frac, cur, target
    if not unlocked then
        frac, cur, target = Decks.unlockProgress(state, spec, game.unlock_rules)
    end
    DeckArt.draw(game, spec, px, cy, pw, ph, {
        level = level, scale = s, locked_frac = (not unlocked) and (frac or 0) or nil, alpha = _alpha,
    })
    col(P.rule)
    love.graphics.rectangle("line", px, cy, pw, ph, Theme.space.radius)
    cy = cy + ph + fl(10 * s)

    love.graphics.setFont(fonts.md)
    col(P.heading)
    love.graphics.printf(spec.name or spec.id, cx, cy, cw, "center")
    cy = cy + fonts.md:getHeight() + fl(2 * s)
    love.graphics.setFont(fonts.sm)
    if not unlocked then
        col(P.error)
        love.graphics.printf("locked", cx, cy, cw, "center")
    elseif maxed then
        col(gold())
        love.graphics.printf("maxed", cx, cy, cw, "center")
    else
        col(P.muted)
        love.graphics.printf(("level %d of %d"):format(level, max_level), cx, cy, cw, "center")
    end
    cy = cy + fonts.sm:getHeight() + fl(10 * s)

    col(P.rule, 0.5)
    love.graphics.rectangle("fill", rx + 8, cy, rw - 16, 1)
    cy = cy + fl(10 * s)

    if not unlocked then
        cy = iconWrapCentered(game, (spec.unlock and spec.unlock.text) or "", cx, cy, cw, fonts.sm, P.primary)
        cy = iconWrapCentered(game, unlockCounter(spec, cur or 0, target or 0), cx, cy, cw, fonts.sm, P.error)
        cy = cy + fl(10 * s)
    end

    local lvl_now = unlocked and level or 0
    if lvl_now > 0 and spec.bonus and spec.bonus.per_level then
        cy = iconWrapCentered(game, Decks.bonusTextAt(spec, lvl_now), cx, cy, cw, fonts.sm, P.heading)
        cy = iconWrapCentered(game, "(" .. Decks.bonusTextPerLevel(spec) .. ")", cx, cy, cw, fonts.sm, P.muted)
    else
        cy = iconWrapCentered(game, Decks.bonusTextPerLevel(spec), cx, cy, cw, fonts.sm, P.primary)
    end
    cy = cy + fl(8 * s)

    if spec.capstone and spec.capstone.text then
        love.graphics.setFont(fonts.sm)
        col(maxed and gold() or P.muted)
        love.graphics.printf(maxed and "Capstone - earned" or "Capstone - at level 5", cx, cy, cw, "center")
        cy = cy + fonts.sm:getHeight()
        cy = iconWrapCentered(game, spec.capstone.text, cx, cy, cw, fonts.sm, maxed and P.heading or P.muted)
        cy = cy + fl(8 * s)
    end

    cy = iconWrapCentered(game, Decks.levelsOnText(spec), cx, cy, cw, fonts.sm, P.muted)
    cy = cy + fl(10 * s)

    if spec.flavor_text then
        love.graphics.setFont(fonts.sm)
        col(P.faint)
        love.graphics.printf(spec.flavor_text, cx, cy, cw, "center")
    end

    -- The terms, small print at the foot.
    local _, tl = fonts.sm:getWrap(TERMS, cw)
    local terms_h = #tl * fonts.sm:getHeight()
    col(P.faint)
    love.graphics.setFont(fonts.sm)
    love.graphics.printf(TERMS, cx, ry + rh - pad - terms_h, cw, "center")
end

-- ─── The cover ───────────────────────────────────────────────────────

-- The outside of the first leaf, at design size (LEAF_W × leaf_h, × s).
-- The back of the deck in play is the picture: the felt's own card-back
-- draw, which clips nothing, so it survives the felt's rotation.
local function drawCover(self, w, h, fonts, s)
    local fl    = math.floor
    local game  = self.game
    local state = game.state
    drawLeaf(0, 0, w, h, s)

    col(P.muted)
    love.graphics.setFont(fonts.sm)
    love.graphics.printf(IMPRINT, 0, fl(26 * s), w, "center")
    col(P.heading)
    love.graphics.setFont(fonts.lg)
    local hy = fl(26 * s) + fonts.sm:getHeight() + fl(6 * s)
    love.graphics.printf(HEADLINE, fl(12 * s), hy, w - fl(24 * s), "center")

    local spec = Decks.specById(state.active_deck_id) or Decks.all()[1]
    local cw   = fl(w * 0.58)
    local ch   = fl(cw * 1.4)
    local cx   = fl((w - cw) / 2)
    local cy   = hy + fonts.lg:getHeight() + fl(24 * s)
    CardSprites.shadow(cx, cy, cw, ch, _alpha, fl(4 * s))
    CardSprites.back(game.sprite_loader, spec and spec.sprite, cx, cy, cw, ch, _alpha)
    col(P.edge)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", cx, cy, cw, ch, Theme.space.radius)
    love.graphics.setLineWidth(1)

    col(P.primary)
    love.graphics.setFont(fonts.md)
    love.graphics.printf(SELL, fl(12 * s), cy + ch + fl(22 * s), w - fl(24 * s), "center")
end

-- Where it rests: the hashed spot, moved clear of the book if they overlap.
function DeckFlyer:_feltSpot(W, H, fw, fh)
    local x, y, angle = Throw.spot(self._throw_key, CLOSED, W, H)
    x, y = Throw.avoid(x, y, fw, fh, self.avoid, self._throw_key, math.floor(AVOID_GAP), W)
    return x, y, angle
end

-- Leaf height: pad, masthead, the grid, pad — the same for every leaf.
local function leafHeight(fonts, s)
    local fl = math.floor
    return fl(LEAF_PAD_BASE * s) + mastHeight(fonts, s) + fl(GRID_H_BASE * s) + fl(LEAF_PAD_BASE * s)
end

function DeckFlyer:_drawClosedOnFelt(W, H, fonts, s)
    local fl = math.floor
    local dw, dh = fl(LEAF_W_BASE * s), leafHeight(fonts, s)
    local fw, fh = fl(dw * CLOSED.scale), fl(dh * CLOSED.scale)
    local rx, ry, angle = self:_feltSpot(W, H, fw, fh)

    local t = self._throw_t
    -- High and below: no tumble, no flutter on the way in.
    local cfg = CLOSED
    if not Motion.at("paper", Motion.FULL) then
        cfg = setmetatable({ flutter = 0, throw_spin = 0 }, { __index = CLOSED })
    end
    local x, y, spin_left, sq, height = Throw.pose(t, cfg, s, rx, ry, fh)
    local spin = angle + spin_left

    love.graphics.push()
    love.graphics.translate(x + fw * 0.5, y + fh * 0.5)
    love.graphics.rotate(spin)
    love.graphics.scale(sq, 1 / sq)
    if height > 0.02 then
        local sh_off = fl(12 * s * height)
        col(P.sunken, 0.40 * height)
        love.graphics.rectangle("fill", -fw * 0.5 + sh_off, -fh * 0.5 + sh_off, fw, fh, fl(4 * s))
    end
    -- The two leaves folded behind the cover, peeking out at the edge.
    for i = 2, 1, -1 do
        col(P.window)
        love.graphics.rectangle("fill", -fw * 0.5 + i * 2, -fh * 0.5 + i * 2, fw, fh, fl(3 * s))
        col(P.rule, 0.6)
        love.graphics.rectangle("line", -fw * 0.5 + i * 2, -fh * 0.5 + i * 2, fw, fh, fl(3 * s))
    end
    love.graphics.push()
    love.graphics.translate(-fw * 0.5, -fh * 0.5)
    love.graphics.scale(CLOSED.scale, CLOSED.scale)
    drawCover(self, dw, dh, fonts, s)
    love.graphics.pop()
    -- The invitation, at its real size: text never rests scaled.
    if t >= 1 then
        love.graphics.setFont(fonts.md)
        col(P.warn)
        love.graphics.printf("CLICK TO OPEN", -fw * 0.5, fh * 0.5 - fonts.md:getHeight() - fl(10 * s), fw, "center")
    end
    love.graphics.pop()

    if t >= 1 then
        self._felt_rect = { x = x, y = y, w = fw, h = fh, angle = angle }
        Anchors.set("deck:flyer", x, y, fw, fh)
    else
        self._felt_rect = nil
    end
end

-- ─── The spread ──────────────────────────────────────────────────────

-- Horizontal scale about a hinge (the catalog's page-turn trick).
local function hinged(hinge_x, sx, fn)
    if sx <= 0.02 then return end
    love.graphics.push()
    love.graphics.translate(hinge_x, 0)
    love.graphics.scale(sx, 1)
    love.graphics.translate(-hinge_x, 0)
    fn()
    love.graphics.pop()
end

-- A tile leaf (1 or 2): stock and its two columns of three. `register` =
-- the hit rects are live (only once the spread is fully open).
function DeckFlyer:_drawTileLeaf(k, lx, ly, lw, lh, fonts, s, register, mx, my)
    local fl     = math.floor
    local pad    = fl(LEAF_PAD_BASE * s)
    local tile_w, tile_h = fl(TILE_W_BASE * s), fl(TILE_H_BASE * s)
    local gap_x, gap_y   = fl(TILE_GAP_BASE * s), fl(TILE_GAP_Y_BASE * s)
    local state  = self.game.state
    local reg    = self.game.unlock_rules
    local specs  = Decks.all()
    drawLeaf(lx, ly, lw, lh, s)

    local ty0 = ly + pad + mastHeight(fonts, s)
    for row = 0, ROWS - 1 do
        for col = 0, 1 do
            local idx  = row * 4 + (k - 1) * 2 + col + 1     -- reading order across both leaves
            local spec = specs[idx]
            if spec then
                local tx = lx + pad + col * (tile_w + gap_x)
                local ty = ty0 + row * (tile_h + gap_y)
                if register then
                    drawTile(self, spec, tx, ty, tile_w, tile_h, fonts, s, Decks.isUnlocked(state, spec, reg), mx or -1, my or -1)
                else
                    local keep = self._tiles
                    self._tiles = {}
                    drawTile(self, spec, tx, ty, tile_w, tile_h, fonts, s, Decks.isUnlocked(state, spec, reg), -1, -1)
                    self._tiles = keep
                end
            end
        end
    end
end

-- The third leaf: the column.
function DeckFlyer:_drawColumnLeaf(lx, ly, lw, lh, fonts, s)
    local fl  = math.floor
    local pad = fl(LEAF_PAD_BASE * s)
    drawLeaf(lx, ly, lw, lh, s)
    local state  = self.game.state
    local detail = Decks.specById(self._detail_id) or Decks.specById(state.active_deck_id) or Decks.all()[1]
    drawColumn(self, detail, lx + pad, ly + pad + mastHeight(fonts, s), lw - pad * 2, fl(GRID_H_BASE * s),
               fonts, s, Decks.isUnlocked(state, detail, self.game.unlock_rules))
end

function DeckFlyer:draw()
    local fonts = self.game.fonts
    local W, H  = love.graphics.getDimensions()
    local s     = (self.game.ui_scale) or 1
    local fl    = math.floor
    local dt    = love.timer.getDelta()
    -- Motion: Medium shortens the throw and the opening; Low and below
    -- finish them on the next frame and fade the sheet in where it rests.
    local psc = math.max(Motion.scale("paper"), 0.003)
    if self._throw_t < 1 then self._throw_t = math.min(1, self._throw_t + dt / (THROW_SECS * psc)) end
    if self._open_t  < 1 then self._open_t  = math.min(1, self._open_t  + dt / (OPEN_SECS * psc)) end
    _alpha = Motion.fade("paper", "flyer:" .. tostring(self._throw_key) .. ":" .. (self._open and "open" or "closed"))

    if self.on_felt and not self._open then
        self:_drawClosedOnFelt(W, H, fonts, s)
        return
    end

    if self.scrim then
        col(Theme.debug.hud_bg)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end

    local lw, l3w = fl(LEAF_W_BASE * s), fl(LEAF3_W_BASE * s)
    local lh     = leafHeight(fonts, s)
    local pad    = fl(LEAF_PAD_BASE * s)
    local sw     = lw * 2 + l3w
    local sx, sy = fl((W - sw) / 2), fl((H - lh) / 2)
    local x1, x2, x3 = sx, sx + lw, sx + lw * 2
    self._sheet_rect = { x = sx, y = sy, w = sw, h = lh }
    Anchors.set("story:band", 0, H - fl(56 * s), W, fl(44 * s))
    local mx, my = love.mouse.getPosition()
    local done = self._open_t >= 1

    -- The opening: the middle leaf is on the table; the cover (the outside
    -- of leaf 1) turns over its left edge to lie on the left, then leaf 3
    -- swings out to the right. Two page-turns, one after the other.
    local q = self._open_t
    self._tiles = {}
    if done then
        self:_drawTileLeaf(1, x1, sy, lw, lh, fonts, s, true, mx, my)
        self:_drawTileLeaf(2, x2, sy, lw, lh, fonts, s, true, mx, my)
        self:_drawColumnLeaf(x3, sy, l3w, lh, fonts, s)
    else
        self:_drawTileLeaf(2, x2, sy, lw, lh, fonts, s, false)
        local a = math.min(1, q * 2)          -- leaf 1
        local b = math.max(0, q * 2 - 1)      -- leaf 3
        if a < 0.5 then
            hinged(x2, 1 - a * 2, function()
                love.graphics.push()
                love.graphics.translate(x2, sy)
                drawCover(self, lw, lh, fonts, s)
                love.graphics.pop()
            end)
        else
            hinged(x2, (a - 0.5) * 2, function()
                self:_drawTileLeaf(1, x1, sy, lw, lh, fonts, s, false)
            end)
        end
        if b > 0 then
            hinged(x3, b, function()
                self:_drawColumnLeaf(x3, sy, l3w, lh, fonts, s)
            end)
        end
    end

    if done then
        drawFold(x2, sy + 2, lh - 4, s)
        drawFold(x3, sy + 2, lh - 4, s)

        -- Masthead across the spread, in the band the leaves keep clear.
        local cy = sy + pad
        col(P.muted)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf(IMPRINT, sx, cy, sw, "center")
        cy = cy + fonts.sm:getHeight()
        col(P.heading)
        love.graphics.setFont(fonts.lg)
        love.graphics.printf(HEADLINE, sx, cy, sw, "center")
        cy = cy + fonts.lg:getHeight() + fl(2 * s)
        col(P.primary)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf(SELL_OPEN, sx, cy, sw, "center")
    end
    love.graphics.setColor(1, 1, 1, 1)
    _alpha = 1
end

return DeckFlyer
