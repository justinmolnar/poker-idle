-- views/CatalogModal.lua
--
-- Post-bust catalog. Replaces the old always-visible left-panel tab —
-- catalog purchases now happen here, after the PrestigeModal has been
-- dismissed but before the run is reset and we return to grind.
--
-- Layout: single backdrop card with a 2-column grid of item cards. Each
-- item card shows:
--   ┌─ Name ─────────────── Cost ─┐
--   │ Effect text                  │
--   │ Italic flavor blurb          │
--   └──────────────────────────────┘
--
-- Click an affordable item to buy. Owned items render dimmed with "OWNED"
-- in the cost slot. Locked items (requires=...) render greyed out with
-- "Requires X". SPACE dismisses the modal — ShoveState consumes that key
-- and runs the actual run-reset / state-switch.
--
-- Pure presentation. Buy clicks dispatch through GrindController:buyCatalogItem,
-- which handles effects-cache invalidation, the purchase sound, and the
-- guarded model mutation (the model still owns its own state — the
-- controller is the layer the view talks to).

local Theme       = require("views.Theme")
local Constants   = require("data.constants")
local Catalog     = require("data.catalog")
local LabelButton = require("views.widgets.LabelButton")
local Icons       = require("views.Icons")
local IconText    = require("views.IconText")
local TooltipSvc     = require("services.Tooltip")

local CatalogModal = {}
CatalogModal.__index = CatalogModal

-- ─── Layout constants ──────────────────────────────────────────────────

-- Base "design" sizes — scaled by ui_scale at draw time so the
-- modal grows with the window (a 4K screen shouldn't show a tiny
-- 980-wide card grid in the middle of empty void).
local MODAL_W_BASE      = 980
local MODAL_PAD_BASE    = 24
local GRID_GAP_X_BASE   = 16
local GRID_GAP_Y_BASE   = 12
local CARD_PAD_X_BASE   = 14
local CARD_PAD_Y_BASE   = 10

-- Live values populated each :draw from base × scale.
local MODAL_W           = MODAL_W_BASE
local MODAL_PAD         = MODAL_PAD_BASE
local HEADER_H          = 56
local FOOTER_H          = 44
local GRID_COLS         = 2
local GRID_GAP_X        = GRID_GAP_X_BASE
local GRID_GAP_Y        = GRID_GAP_Y_BASE
local CARD_PAD_X        = CARD_PAD_X_BASE
local CARD_PAD_Y        = CARD_PAD_Y_BASE
local CARD_H            = 84

-- Reconfigure layout from active fonts. Card layout is:
--   title  (md)  at PAD_Y
--   cost   (md)  on the same row, right-aligned
--   effect (sm)  at PAD_Y + md_h + 2
--   flavor (sm)  at PAD_Y + md_h + sm_h + 4
--
-- CARD_H is NOT cached here — it's recomputed in :draw against the live
-- ui-scaled CARD_PAD_Y so the bottom padding matches the top regardless
-- of when configureFromFonts last fired (boot vs resize).
function CatalogModal.configureFromFonts(fonts)
    if not (fonts and fonts.md) then return end
    local mh = fonts.md:getHeight()
    HEADER_H = fonts.lg:getHeight() + 16
    FOOTER_H = mh + 16
end

-- ─── Construction ──────────────────────────────────────────────────────

-- opts.read_only — when true, the modal renders the catalog but every
--                   item ignores buy clicks (no purchases mid-grind).
--                   Used by the top-bar CATALOG button so the player can
--                   inspect items without spending chips outside the
--                   post-bust ritual. Affordable items skip the green
--                   "buyable" border so the read-only state reads
--                   clearly. Default false → full post-bust behavior.
function CatalogModal:new(game, opts)
    opts = opts or {}
    return setmetatable({
        game      = game,
        read_only = opts.read_only == true,
        -- One-time tutorial lede (first post-shove visit only; the host
        -- decides via hints_seen["catalog_intro"] and marks it seen).
        intro_callout = opts.intro_callout == true,
        -- Cached cell rects (built each :draw, consumed by :consumeMouse)
        _cells   = {},
        -- Spread index (0 = pages 1-2, 1 = pages 3-4, etc.)
        spread_index   = 0,
        -- Continue-button rect (built each :draw); click sets _resolved.
        _continue_rect = nil,
        _resolved      = false,
    }, CatalogModal)
end

function CatalogModal:resolved() return self._resolved end

-- ─── Visibility filter ────────────────────────────────────────────────

-- Owned/locked-aware filter. Hides system phantoms (the no_poster
-- handicap) and items gated behind a not-yet-owned prerequisite that
-- asked to be hidden until unlocked. Phase tags exist on items for
-- future ordering / UI grouping but don't gate visibility — every
-- buyable item needs a path to be seen.
local function visibleItems(state)
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local out = {}
    for _, item in ipairs(Catalog) do
        local locked = item.requires and not owned[item.requires]
        local skip = item.hidden
                  or (locked and item.requires_hide)
                  or (item.requires_act3 and not state.shove_r2_won)
        if not skip then
            out[#out + 1] = item
        end
    end

    -- Sort by chip cost ascending so the player sees what's affordable
    -- next at the top. Owned items stay in their natural cost slot
    -- (no bubble-to-bottom on purchase) — moving them around as the
    -- player buys was disorienting and shifted everything else.
    table.sort(out, function(a, b)
        local ac, bc = a.cost_chip or 0, b.cost_chip or 0
        if ac ~= bc then return ac < bc end
        return false
    end)

    return out, owned
end

-- ─── Buy path ─────────────────────────────────────────────────────────

-- Dispatch the purchase intent through GrindController. The controller
-- handles effects-cache invalidation + sound + the guarded model mutation;
-- the view stays out of the model's internals.
local function tryBuy(game, item)
    if game.grind and game.grind.buyCatalogItem then
        return game.grind:buyCatalogItem(item.id)
    end
    -- Fallback: route through the model directly if the grind controller
    -- isn't registered yet (shouldn't happen in normal flow, but keeps the
    -- modal usable from contrived test setups).
    return game.state:tryBuyCatalogItem(item)
end

local function tryCorrupt(game, item)
    if game.grind and game.grind.corruptCatalogItem then
        return game.grind:corruptCatalogItem(item.id)
    end
    return game.state:tryCorruptItem(item)
end

-- ─── Input ────────────────────────────────────────────────────────────

function CatalogModal:consumeKey(key)
    if key == "space" or key == "return" or key == "kpenter" then
        -- Poster-forcing only exists in the scripted-intro build; under
        -- TUTORIAL the poster isn't in the catalog at all, so this gate
        -- would lock Continue forever.
        local _, owned = visibleItems(self.game.state)
        if (not Constants.FEATURES.TUTORIAL) and (not self.read_only)
           and (not owned["poker_poster"]) then
            return true -- Block resolution, but consume the key
        end
        self._resolved = true
        return true
    end
    return false
end

-- Forward mouse-wheel events from ShoveState. dy > 0 = wheel up = flip page back;
-- dy < 0 = wheel down = flip page forward.
function CatalogModal:wheelmoved(_, dy)
    if not dy or dy == 0 or self.flip_t then return end
    local step = (dy > 0) and -1 or 1
    local items = visibleItems(self.game.state)
    local max_spread = math.ceil(#items / 6) + 1
    local new_index = self.spread_index + step
    if new_index >= 0 and new_index <= max_spread then
        self.old_spread_index = self.spread_index
        self.spread_index = new_index
        self.flip_t = 0.35
        self.flip_dir = step > 0 and "next" or "prev"
        local SoundService = require("services.SoundService")
        SoundService.playNamed("hole_card_flip")
    end
end

-- Returns true if the click landed on a button or a buyable card.
function CatalogModal:consumeMouse(mx, my, button)
    if button ~= 1 then return false end

    -- 1. Continue/Close coupon button
    local r = self._continue_rect
    if r and mx >= r.x and mx < r.x + r.w
       and my >= r.y and my < r.y + r.h then
        local _, owned = visibleItems(self.game.state)
        if (not Constants.FEATURES.TUTORIAL) and (not self.read_only)
           and (not owned["poker_poster"]) then
            return true -- Block resolution
        end
        self._resolved = true
        return true
    end

    -- 2. Previous page dog-ear corner click
    local pr = self._prev_rect
    if pr and mx >= pr.x and mx < pr.x + pr.w
       and my >= pr.y and my < pr.y + pr.h then
        if self.spread_index > 0 and not self.flip_t then
            self.old_spread_index = self.spread_index
            self.spread_index = self.spread_index - 1
            self.flip_t = 0.35
            self.flip_dir = "prev"
            local SoundService = require("services.SoundService")
            SoundService.playNamed("hole_card_flip")
        end
        return true
    end

    -- 3. Next page dog-ear corner click
    local nr = self._next_rect
    if nr and mx >= nr.x and mx < nr.x + nr.w
       and my >= nr.y and my < nr.y + nr.h then
        local items = visibleItems(self.game.state)
        local max_spread = math.ceil(#items / 6) + 1
        if self.spread_index < max_spread and not self.flip_t then
            self.old_spread_index = self.spread_index
            self.spread_index = self.spread_index + 1
            self.flip_t = 0.35
            self.flip_dir = "next"
            local SoundService = require("services.SoundService")
            SoundService.playNamed("hole_card_flip")
        end
        return true
    end

    -- 4. Catalog item ads
    for _, cell in ipairs(self._cells) do
        if mx >= cell.x and mx < cell.x + cell.w
           and my >= cell.y and my < cell.y + cell.h then
            if cell.buyable and not self.read_only then
                if cell.corruptible then
                    return tryCorrupt(self.game, cell.item)
                else
                    return tryBuy(self.game, cell.item)
                end
            end
            return true   -- consumed even if not buyable (don't fall through)
        end
    end
    return false
end

-- ─── Render ───────────────────────────────────────────────────────────

local function moneyish(n) return string.format("%d", n or 0) end

local function drawItemCard(self, item, owned, state, x, y, w, h, fonts, forcing_tutorial, index)
    local is_owned   = owned[item.id]
    local locked     = item.requires and not owned[item.requires]
    local is_corrupted = false
    if state.corrupted_items then
        for _, cid in ipairs(state.corrupted_items) do
            if cid == item.id then is_corrupted = true; break end
        end
    end
    local is_corruptible = is_owned and item.corrupt and state.shove_r2_won and not is_corrupted

    local affordable = false
    local buyable    = false
    local corruptible = false

    if is_corruptible then
        affordable = state.anti_chips >= (item.corrupt.cost_achip or 0)
        buyable    = affordable and not self.read_only
        corruptible = true
    else
        affordable = (not is_owned) and (not locked) and state.chips >= (item.cost_chip or 0)
        buyable    = affordable and not self.read_only
    end

    local is_tutorial_target = forcing_tutorial and item.id == "poker_poster"

    local s = self.game.ui_scale or 1
    local fl = math.floor

    -- Vintage newsprint border for this ad
    Theme.setColor({ 0.15, 0.15, 0.12, 0.30 })
    love.graphics.rectangle("line", x, y, w, h)
    
    -- Picture frame for illustration on the left
    local img_w = fl(56 * s)
    local img_h = fl(56 * s)
    local img_x = x + fl(8 * s)
    local img_y = y + fl(14 * s)
    
    Theme.setColor({ 0.15, 0.15, 0.12, 0.08 })
    love.graphics.rectangle("fill", img_x, img_y, img_w, img_h)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
    love.graphics.rectangle("line", img_x, img_y, img_w, img_h)
    
    -- Draw sprite (if exists)
    local sprite = self.game.sprite_loader:getSprite(item.id)
    if sprite then
        local scale_x = img_w / sprite:getWidth()
        local scale_y = img_h / sprite:getHeight()
        local scale_factor = math.min(scale_x, scale_y)
        local px = img_x + (img_w - sprite:getWidth() * scale_factor) * 0.5
        local py = img_y + (img_h - sprite:getHeight() * scale_factor) * 0.5
        
        love.graphics.setColor(1, 1, 1, (is_owned and not is_corruptible and not is_corrupted) and 0.40 or 1.0)
        love.graphics.draw(sprite, px, py, 0, scale_factor, scale_factor)
    else
        -- Draw classic blueprint cross placeholder
        love.graphics.setColor(0.15, 0.15, 0.12, 0.15)
        love.graphics.line(img_x, img_y, img_x + img_w, img_y + img_h)
        love.graphics.line(img_x + img_w, img_y, img_x, img_y + img_h)
    end

    -- Stamp price tag in upper-right corner
    local price_color = { 0.15, 0.15, 0.12, 0.50 } -- black ink default
    if is_corruptible then
        price_color = { 0.55, 0.25, 0.85 } -- purple stamp for active corruption price
    elseif is_corrupted then
        price_color = { 0.40, 0.15, 0.60 } -- dark purple for corrupted
    elseif not is_owned and not locked then
        price_color = { 0.75, 0.20, 0.20 } -- red rubber stamp for active purchase price
    end
    
    local cx_stamp = x + w - fl(24 * s)
    local cy_stamp = y + fl(24 * s)
    local r_stamp = fl(16 * s)
    
    Theme.setColor(price_color)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", cx_stamp, cy_stamp, r_stamp)
    love.graphics.setLineWidth(1)
    love.graphics.circle("line", cx_stamp, cy_stamp, r_stamp - fl(2 * s))
    
    love.graphics.setFont(fonts.sm)
    local cost_text = string.format("%d", item.cost_chip or 0)
    if is_corruptible then
        cost_text = string.format("%d", item.corrupt.cost_achip or 0)
    elseif is_corrupted then
        cost_text = "OWN"
    elseif is_owned then
        cost_text = "OWN"
    elseif locked then
        cost_text = "LCK"
    elseif (item.cost_chip or 0) <= 0 then
        cost_text = "FREE"
    end
    local tw_c = fonts.sm:getWidth(cost_text)
    love.graphics.print(cost_text, cx_stamp - tw_c * 0.5, cy_stamp - fonts.sm:getHeight() * 0.5)

    -- Item Header info: Number code + Name
    local text_x = img_x + img_w + fl(12 * s)
    local title_y = y + fl(8 * s)
    
    local index_text = string.format("No. %03d", index or 0)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.60 })
    love.graphics.setFont(fonts.sm)
    love.graphics.print(index_text, text_x, title_y)
    
    local name_y = title_y + fonts.sm:getHeight() + 1
    local name_color = (is_owned and not is_corruptible and not is_corrupted) and { 0.15, 0.15, 0.12, 0.40 } or { 0.15, 0.15, 0.12 }
    Theme.setColor(name_color)
    love.graphics.setFont(fonts.md)
    love.graphics.print((item.name or "?"):upper(), text_x, name_y)

    -- Description / Effect
    local effect_y = name_y + fonts.md:getHeight() + 3
    local eff_text = is_corrupted and item.corrupt.effect_text or item.effect_text
    IconText.draw(self.game, eff_text or "", text_x, effect_y, fonts.sm,
        (is_owned and not is_corruptible and not is_corrupted) and { 0.15, 0.15, 0.12, 0.40 } or { 0.15, 0.15, 0.12 })
        
    local flavor_y = effect_y + fonts.sm:getHeight() + 2
    Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
    love.graphics.setFont(fonts.sm)
    
    local desc_w = w - (img_w + fl(20 * s)) - fl(44 * s)
    local desc_txt = item.description or ""
    if fonts.sm:getWidth(desc_txt) > desc_w then
        desc_txt = desc_txt:sub(1, 30) .. "..."
    end
    love.graphics.print(desc_txt, text_x, flavor_y)

    -- Stash cell bounds for hit-testing
    self._cells[#self._cells + 1] = {
        x = x, y = y, w = w, h = h, item = item, buyable = buyable, corruptible = corruptible,
    }

    -- Overlays: Rubber stamp "ORDERED", "CORRUPTED", or "SOLD OUT"
    if is_corrupted then
        love.graphics.push()
        love.graphics.translate(x + w * 0.55, y + h * 0.5)
        love.graphics.rotate(-0.15)
        
        Theme.setColor({ 0.45, 0.15, 0.70, 0.90 })
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", -fl(60 * s), -fl(14 * s), fl(120 * s), fl(28 * s), fl(4 * s))
        love.graphics.setLineWidth(1)
        
        love.graphics.setFont(fonts.md)
        local st_w = fonts.md:getWidth("CORRUPTED")
        love.graphics.print("CORRUPTED", -st_w * 0.5, -fonts.md:getHeight() * 0.5)
        
        love.graphics.pop()
    elseif is_corruptible then
        love.graphics.push()
        love.graphics.translate(x + w * 0.55, y + h * 0.5)
        love.graphics.rotate(0.05)
        
        Theme.setColor({ 0.55, 0.25, 0.85, 0.85 })
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", -fl(50 * s), -fl(12 * s), fl(100 * s), fl(24 * s), fl(3 * s))
        love.graphics.setLineWidth(1)
        
        love.graphics.setFont(fonts.sm)
        local st_w = fonts.sm:getWidth("CORRUPT?")
        love.graphics.print("CORRUPT?", -st_w * 0.5, -fonts.sm:getHeight() * 0.5)
        
        love.graphics.pop()
    elseif is_owned then
        love.graphics.push()
        love.graphics.translate(x + w * 0.55, y + h * 0.5)
        love.graphics.rotate(-0.15)
        
        Theme.setColor({ 0.75, 0.20, 0.20, 0.85 })
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", -fl(55 * s), -fl(14 * s), fl(110 * s), fl(28 * s), fl(4 * s))
        love.graphics.setLineWidth(1)
        
        love.graphics.setFont(fonts.md)
        local st_w = fonts.md:getWidth("ORDERED")
        love.graphics.print("ORDERED", -st_w * 0.5, -fonts.md:getHeight() * 0.5)
        
        love.graphics.pop()
    elseif locked then
        love.graphics.push()
        love.graphics.translate(x + w * 0.55, y + h * 0.5)
        love.graphics.rotate(-0.10)
        
        Theme.setColor({ 0.45, 0.45, 0.45, 0.70 })
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", -fl(60 * s), -fl(12 * s), fl(120 * s), fl(24 * s), fl(3 * s))
        love.graphics.setLineWidth(1)
        
        love.graphics.setFont(fonts.md)
        local st_w = fonts.md:getWidth("SOLD OUT")
        love.graphics.print("SOLD OUT", -st_w * 0.5, -fonts.md:getHeight() * 0.5)
        
        love.graphics.pop()
    elseif forcing_tutorial and item.id ~= "poker_poster" then
        love.graphics.push()
        love.graphics.translate(x + w * 0.55, y + h * 0.5)
        love.graphics.rotate(0.08)
        
        Theme.setColor({ 0.55, 0.55, 0.55, 0.60 })
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", -fl(55 * s), -fl(12 * s), fl(110 * s), fl(24 * s), fl(3 * s))
        love.graphics.setLineWidth(1)
        
        love.graphics.setFont(fonts.sm)
        local st_w = fonts.sm:getWidth("WAIT POSTER")
        love.graphics.print("WAIT POSTER", -st_w * 0.5, -fonts.sm:getHeight() * 0.5)
        
        love.graphics.pop()
    end
end

-- Maximum modal height as a fraction of the viewport. Anything taller
-- and the inner grid scrolls.
local MODAL_MAX_H_FRAC = 0.90

local function drawPageContents(self, is_left, spread_idx, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
    local fl = math.floor
    local px = is_left and left_x or right_x
    local pw = is_left and left_w or right_w
    local offset = is_left and 0 or 3
    
    -- Spread 1 starts items index at 1. Spread 0 is Front Cover.
    local page_start = (spread_idx - 1) * 6
    
    for slot = 1, 3 do
        local idx = page_start + offset + slot
        local item = items[idx]
        if item then
            local cx = px + fl(6 * s)
            local cy = viewport_y + (slot - 1) * (CARD_H + GRID_GAP_Y)
            drawItemCard(self, item, owned, state, cx, cy, pw - fl(12 * s), CARD_H, fonts, forcing_tutorial, idx)
        end
    end
end

function CatalogModal:draw()
    local fonts = self.game.fonts
    local state = self.game.state

    -- Update page flip animation timers self-contained via love.timer
    local dt = love.timer.getDelta()
    if self.flip_t then
        self.flip_t = self.flip_t - dt
        if self.flip_t <= 0 then
            self.flip_t = nil
            self.flip_dir = nil
            self.old_spread_index = nil
        end
    end

    -- Scale design-space constants by the live ui_scale so the modal
    -- and its card grid grow with the window.
    local s = (self.game.ui_scale) or 1
    local fl = math.floor
    MODAL_W      = fl(MODAL_W_BASE   * s)
    MODAL_PAD    = fl(MODAL_PAD_BASE * s)
    GRID_GAP_X   = fl(GRID_GAP_X_BASE * s)
    GRID_GAP_Y   = fl(GRID_GAP_Y_BASE * s)
    CARD_PAD_X   = fl(CARD_PAD_X_BASE * s)
    CARD_PAD_Y   = fl(CARD_PAD_Y_BASE * s)
    -- Tight card height: serial code (sm) + title (md) + effect (sm) + flavor (sm) +
    -- top/bottom pad + inter-line offsets.
    -- Recomputed per-draw so it always tracks the live scaled padding.
    CARD_H = fonts.md:getHeight() + 3 * fonts.sm:getHeight()
             + fl(16 * s) + 8

    -- First-visit tutorial callout: a recessed band between the header
    -- and the grid. Measured here so the frame allocates its height.
    local callout_pad = fl(10 * s)
    local callout_h   = self.intro_callout
                        and (fonts.sm:getHeight() + callout_pad * 2) or 0
    local head_extra  = self.intro_callout
                        and (callout_h + fl(8 * s)) or 0

    -- Height calculation locked to exactly 3 items vertically per page, plus bottom page-numbers margin
    local viewport_h = 3 * CARD_H + 2 * GRID_GAP_Y + fl(28 * s)
    local body_h   = HEADER_H + head_extra + viewport_h + FOOTER_H

    local items, owned = visibleItems(state)
    local max_spread = math.ceil(#items / 6) + 1

    -- Determine dynamic modal width based on cover (single page) vs open spread (double page)
    local old_w = (self.old_spread_index == 0 or self.old_spread_index == max_spread) and (MODAL_W * 0.5) or MODAL_W
    local new_w = (self.spread_index == 0 or self.spread_index == max_spread) and (MODAL_W * 0.5) or MODAL_W
    local current_w = new_w
    if self.flip_t and self.old_spread_index then
        local progress = self.flip_t / 0.35
        current_w = fl(new_w + (old_w - new_w) * progress)
    end

    -- Modal frame + dim backdrop come from the shared Modal widget so
    -- the chrome stays consistent with the other overlays. Rebuild it
    -- per-draw so width tracks the current scale.
    local Modal = require("views.widgets.Modal")
    self._modal = Modal:new{ w = current_w, max_h_frac = MODAL_MAX_H_FRAC,
                             pad = 0 }

    self._modal:draw(fonts, body_h)
    local box = self._modal:boxRect()

    -- Dim the outer book backdrop
    Theme.setColor({ 0, 0, 0, 0.40 })

    local forcing_tutorial = (not Constants.FEATURES.TUTORIAL)
                             and (not owned["poker_poster"]) and (not self.read_only)

    -- Geometry helpers for columns (always relative to screen center)
    local W, H = love.graphics.getDimensions()
    local center_x = W * 0.5
    local viewport_y = box.y + HEADER_H + head_extra + MODAL_PAD

    local left_w = fl(((MODAL_W_BASE * s) - 2 * MODAL_PAD) * 0.5 - 8 * s)
    local left_x = center_x - left_w - fl(4 * s)
    local right_w = left_w
    local right_x = center_x + fl(4 * s)

    -- Track screen hit-boxes
    self._cells = {}

    -- Render loop for spreads
    local current_draw_idx = self.spread_index

    if self.flip_t then
        -- During animation, background spread is the destination index
        current_draw_idx = self.spread_index
    end

    if current_draw_idx == 0 then
        -- ─── FRONT COVER VIEW (Single page wide, centered) ───
        Theme.setColor({ 0.94, 0.90, 0.83 })
        love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, Theme.space.radius)
        
        Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", box.x, box.y, box.w, box.h, Theme.space.radius)
        love.graphics.setLineWidth(1)
        
        Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
        love.graphics.rectangle("line", box.x + fl(4 * s), box.y + fl(4 * s), box.w - fl(8 * s), box.h - fl(8 * s), Theme.space.radius)

        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.lg)
        love.graphics.printf("SEARS, ROEBUCK & CO.", box.x, box.y + fl(36 * s), box.w, "center")

        -- Large decorative circular stamp in the center
        local draw_x = box.x + box.w * 0.5
        local draw_y = box.y + box.h * 0.46
        local draw_r = fl(56 * s)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.25 })
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", draw_x, draw_y, draw_r)
        love.graphics.circle("line", draw_x, draw_y, draw_r - fl(4 * s))
        love.graphics.setLineWidth(1)

        love.graphics.setFont(fonts.md)
        local ctxt1 = "1999"
        local ctxt2 = "EDITION"
        love.graphics.print(ctxt1, draw_x - fonts.md:getWidth(ctxt1)*0.5, draw_y - fonts.md:getHeight() - 2)
        love.graphics.print(ctxt2, draw_x - fonts.md:getWidth(ctxt2)*0.5, draw_y + 2)

        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.lg)
        local t_str = "CELL FURNISHINGS"
        love.graphics.printf(t_str, box.x, box.y + box.h * 0.68, box.w, "center")

        love.graphics.setFont(fonts.md)
        local t_sub = "CATALOG & ORDER BOOK"
        love.graphics.printf(t_sub, box.x, box.y + box.h * 0.75, box.w, "center")

        love.graphics.setFont(fonts.sm)
        local t_instr = "► GRAB CORNER TO OPEN CATALOG ◄"
        Theme.setColor({ 0.75, 0.20, 0.20 })
        love.graphics.printf(t_instr, box.x, box.y + box.h * 0.88, box.w, "center")

    elseif current_draw_idx == max_spread then
        -- ─── BACK COVER VIEW (Single page wide, centered) ───
        Theme.setColor({ 0.94, 0.90, 0.83 })
        love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, Theme.space.radius)
        
        Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", box.x, box.y, box.w, box.h, Theme.space.radius)
        love.graphics.setLineWidth(1)
        
        Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
        love.graphics.rectangle("line", box.x + fl(4 * s), box.y + fl(4 * s), box.w - fl(8 * s), box.h - fl(8 * s), Theme.space.radius)

        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.lg)
        love.graphics.printf("ORDER SUMMARY", box.x, box.y + fl(36 * s), box.w, "center")

        local owned_count = 0
        for _, id in ipairs(state.owned_items or {}) do
            if id ~= "no_poster_handicap" then
                owned_count = owned_count + 1
            end
        end

        love.graphics.setFont(fonts.md)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.70 })
        love.graphics.printf(string.format("Items active in room: %d", owned_count), box.x, box.y + box.h * 0.32, box.w, "center")
        
        love.graphics.setFont(fonts.sm)
        love.graphics.printf("All mail orders processed immediately.\nDecorations persist across presiges.", box.x, box.y + box.h * 0.40, box.w, "center")

        -- Continue coupon placement inside center of back cover
        local s_ui    = (self.game.ui_scale) or 1
        local btn_w   = math.max(160, fl(220 * s_ui))
        local btn_h   = math.max(32, fl(42 * s_ui))
        local btn_x   = box.x + fl((box.w - btn_w) / 2)
        local btn_y   = box.y + box.h * 0.58
        self._continue_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }

        local mx, my = love.mouse.getPosition()
        local hov = mx >= btn_x and mx < btn_x + btn_w
                    and my >= btn_y and my < btn_y + btn_h

        Theme.setColor({ 0.15, 0.15, 0.12, 0.50 })
        love.graphics.rectangle("line", btn_x, btn_y, btn_w, btn_h)

        LabelButton.draw{
            x = btn_x + 2, y = btn_y + 2, w = btn_w - 4, h = btn_h - 4,
            text         = forcing_tutorial and "ORDER COMPLETED" or "CLOSE CATALOG",
            fonts        = fonts,
            font         = fonts.md,
            hovered      = hov and (not forcing_tutorial),
            disabled     = forcing_tutorial,
            depth        = 3,
            fill_token   = (hov and not forcing_tutorial) and { 0.75, 0.20, 0.20 } or { 0.90, 0.86, 0.78 },
            border_token = forcing_tutorial and Theme.fg.disabled or { 0.15, 0.15, 0.12 },
            text_token   = (hov and not forcing_tutorial) and { 0.94, 0.90, 0.83 } or (forcing_tutorial and Theme.fg.disabled or { 0.15, 0.15, 0.12 }),
        }

        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.75, 0.20, 0.20 })
        love.graphics.printf("◄ GRAB CORNER TO BROWSE PAGES", box.x, box.y + box.h * 0.88, box.w, "center")

    else
        -- ─── TWO-PAGE INSIDE SPREADS VIEW ───
        -- Paint the modal box background with a gorgeous warm newsprint paper color
        Theme.setColor({ 0.94, 0.90, 0.83 })
        love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, Theme.space.radius)
        
        -- Ink border outline
        Theme.setColor({ 0.15, 0.15, 0.12, 0.40 })
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", box.x, box.y, box.w, box.h, Theme.space.radius)
        love.graphics.setLineWidth(1)

        -- Book-like double border layout around the entire sheet
        Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
        love.graphics.rectangle("line", box.x + fl(4 * s), box.y + fl(4 * s), box.w - fl(8 * s), box.h - fl(8 * s), Theme.space.radius)

        -- Draw vertical folding crease shadow down the center of the spread
        Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
        love.graphics.setLineWidth(fl(3 * s))
        love.graphics.line(center_x, box.y + fl(10 * s), center_x, box.y + box.h - fl(10 * s))
        Theme.setColor({ 0.15, 0.15, 0.12, 0.08 })
        love.graphics.setLineWidth(fl(1 * s))
        love.graphics.line(center_x - fl(2 * s), box.y + fl(10 * s), center_x - fl(2 * s), box.y + box.h - fl(10 * s))
        love.graphics.line(center_x + fl(2 * s), box.y + fl(10 * s), center_x + fl(2 * s), box.y + box.h - fl(10 * s))

        -- Header text: Sears styling in dark ink
        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.lg)
        love.graphics.print("SEARS, ROEBUCK & CO. ORDER BOOK", box.x + MODAL_PAD, box.y + 16)
        
        -- Chips balance as a vintage red rubber stamp ledger entry
        local bal   = string.format("%d", state.chips or 0)
        local bal_w = fonts.lg:getWidth(bal)
        local gsize = fonts.lg:getHeight()
        local gap   = fl(6 * s)
        local bx    = box.x + box.w - MODAL_PAD - (bal_w + gap + gsize)
        Theme.setColor({ 0.75, 0.20, 0.20 }) -- retro red ink stamp
        love.graphics.print(bal, bx, box.y + 16)
        Icons.drawChip(self.game, bx + bal_w + gap, box.y + 16, gsize)

        if self.intro_callout then
            local cx = box.x + MODAL_PAD
            local cy = box.y + HEADER_H + fl(4 * s)
            local cw = box.w - 2 * MODAL_PAD
            local r  = fl(3 * s)
            Theme.setColor({ 0.90, 0.86, 0.78 }) -- recessed sunken paper
            love.graphics.rectangle("fill", cx, cy, cw, callout_h, r)
            Theme.setColor({ 0.15, 0.15, 0.12, 0.30 })
            love.graphics.rectangle("line", cx, cy, cw, callout_h, r)
            Theme.setColor({ 0.75, 0.20, 0.20, 0.80 })
            love.graphics.rectangle("fill", cx, cy, fl(4 * s), callout_h)
            IconText.draw(self.game,
                "Make your cell a home. Everything here is permanent.",
                cx + fl(14 * s), cy + callout_pad, fonts.sm, { 0.15, 0.15, 0.12 })
        end

        if not self.flip_t then
            -- Draw active spread pages contents
            drawPageContents(self, true, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
            drawPageContents(self, false, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
        else
            -- Peeling page animated transition overlays
            local progress = self.flip_t / 0.35
            local scale_w = 1.0
            
            if self.flip_dir == "next" then
                drawPageContents(self, true, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                drawPageContents(self, false, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                
                if progress > 0.5 then
                    scale_w = (progress - 0.5) * 2
                    local flap_w = right_w * scale_w
                    local flap_x = center_x
                    
                    Theme.setColor({ 0.92, 0.88, 0.81 })
                    love.graphics.rectangle("fill", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
                    love.graphics.rectangle("line", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    
                    love.graphics.setScissor(flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    drawPageContents(self, false, self.old_spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                    love.graphics.setScissor()
                    
                    local shadow_x = center_x + flap_w
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 * math.sin(progress * math.pi) })
                    love.graphics.setLineWidth(fl(3 * s))
                    love.graphics.line(shadow_x, viewport_y, shadow_x, viewport_y + viewport_h)
                    love.graphics.setLineWidth(1)
                else
                    scale_w = (0.5 - progress) * 2
                    local flap_w = left_w * scale_w
                    local flap_x = center_x - flap_w
                    
                    Theme.setColor({ 0.92, 0.88, 0.81 })
                    love.graphics.rectangle("fill", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
                    love.graphics.rectangle("line", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    
                    love.graphics.setScissor(flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    drawPageContents(self, true, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                    love.graphics.setScissor()
                    
                    local shadow_x = flap_x
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 * math.sin(progress * math.pi) })
                    love.graphics.setLineWidth(fl(3 * s))
                    love.graphics.line(shadow_x, viewport_y, shadow_x, viewport_y + viewport_h)
                    love.graphics.setLineWidth(1)
                end
            else
                drawPageContents(self, true, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                drawPageContents(self, false, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                
                if progress > 0.5 then
                    scale_w = (progress - 0.5) * 2
                    local flap_w = left_w * scale_w
                    local flap_x = center_x - flap_w
                    
                    Theme.setColor({ 0.92, 0.88, 0.81 })
                    love.graphics.rectangle("fill", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
                    love.graphics.rectangle("line", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    
                    love.graphics.setScissor(flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    drawPageContents(self, true, self.old_spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                    love.graphics.setScissor()
                    
                    local shadow_x = flap_x
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 * math.sin(progress * math.pi) })
                    love.graphics.setLineWidth(fl(3 * s))
                    love.graphics.line(shadow_x, viewport_y, shadow_x, viewport_y + viewport_h)
                    love.graphics.setLineWidth(1)
                else
                    scale_w = (0.5 - progress) * 2
                    local flap_w = right_w * scale_w
                    local flap_x = center_x
                    
                    Theme.setColor({ 0.92, 0.88, 0.81 })
                    love.graphics.rectangle("fill", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 })
                    love.graphics.rectangle("line", flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    
                    love.graphics.setScissor(flap_x, viewport_y - fl(4 * s), flap_w, viewport_h + fl(8 * s))
                    drawPageContents(self, false, self.spread_index, items, owned, state, fonts, forcing_tutorial, viewport_y, left_x, left_w, right_x, right_w, CARD_H, GRID_GAP_Y, s)
                    love.graphics.setScissor()
                    
                    local shadow_x = center_x + flap_w
                    Theme.setColor({ 0.15, 0.15, 0.12, 0.15 * math.sin(progress * math.pi) })
                    love.graphics.setLineWidth(fl(3 * s))
                    love.graphics.line(shadow_x, viewport_y, shadow_x, viewport_y + viewport_h)
                    love.graphics.setLineWidth(1)
                end
            end
        end

        -- 3. Page numbers watermarks at the bottom of pages (Spread 1 starts pages 1 and 2)
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.40 })
        local left_num_str = tostring(self.spread_index * 2 - 1)
        local right_num_str = tostring(self.spread_index * 2)
        local l_num_w = fonts.sm:getWidth(left_num_str)
        local r_num_w = fonts.sm:getWidth(right_num_str)
        
        local text_y_offset = viewport_y + 3 * (CARD_H + GRID_GAP_Y) + fl(4 * s)
        love.graphics.print(left_num_str, left_x + left_w * 0.5 - l_num_w * 0.5, text_y_offset)
        love.graphics.print(right_num_str, right_x + right_w * 0.5 - r_num_w * 0.5, text_y_offset)
    end
    
    -- 4. Page navigation dog-ear corner curls
    local mx, my = love.mouse.getPosition()
    local max_spread = math.ceil(#items / 6) + 1

    -- Left corner fold (PREVIOUS PAGE)
    local left_corner_sz = fl(28 * s)
    local is_prev_hov = false
    if self.spread_index > 0 then
        -- Hover zone check
        if mx >= box.x and mx <= box.x + fl(48 * s)
           and my >= box.y + box.h - fl(48 * s) and my <= box.y + box.h then
            is_prev_hov = true
            left_corner_sz = fl(38 * s)
        end

        -- Cut space backdrop
        Theme.setColor(Theme.debug.hud_bg or {0, 0, 0, 0.7})
        love.graphics.polygon("fill",
            box.x, box.y + box.h,
            box.x + left_corner_sz, box.y + box.h,
            box.x, box.y + box.h - left_corner_sz
        )
        -- Folded flap
        Theme.setColor({ 0.88, 0.84, 0.77 })
        love.graphics.polygon("fill",
            box.x + left_corner_sz, box.y + box.h,
            box.x + left_corner_sz, box.y + box.h - left_corner_sz,
            box.x, box.y + box.h - left_corner_sz
        )
        Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
        love.graphics.line(box.x + left_corner_sz, box.y + box.h, box.x, box.y + box.h - left_corner_sz)
        love.graphics.line(box.x + left_corner_sz, box.y + box.h - left_corner_sz, box.x + left_corner_sz, box.y + box.h)
        
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, is_prev_hov and 0.85 or 0.35 })
        love.graphics.print("◄", box.x + left_corner_sz * 0.4, box.y + box.h - left_corner_sz * 0.8)
        
        self._prev_rect = { x = box.x, y = box.y + box.h - left_corner_sz, w = left_corner_sz, h = left_corner_sz }
    else
        self._prev_rect = nil
    end

    -- Right corner fold (NEXT PAGE)
    local right_corner_sz = fl(28 * s)
    local is_next_hov = false
    if self.spread_index < max_spread then
        -- Hover zone check
        if mx >= box.x + box.w - fl(48 * s) and mx <= box.x + box.w
           and my >= box.y + box.h - fl(48 * s) and my <= box.y + box.h then
            is_next_hov = true
            right_corner_sz = fl(38 * s)
        end

        -- Cut space backdrop
        Theme.setColor(Theme.debug.hud_bg or {0, 0, 0, 0.7})
        love.graphics.polygon("fill",
            box.x + box.w, box.y + box.h,
            box.x + box.w - right_corner_sz, box.y + box.h,
            box.x + box.w, box.y + box.h - right_corner_sz
        )
        -- Folded flap
        Theme.setColor({ 0.88, 0.84, 0.77 })
        love.graphics.polygon("fill",
            box.x + box.w - right_corner_sz, box.y + box.h,
            box.x + box.w - right_corner_sz, box.y + box.h - right_corner_sz,
            box.x + box.w, box.y + box.h - right_corner_sz
        )
        Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
        love.graphics.line(box.x + box.w - right_corner_sz, box.y + box.h, box.x + box.w, box.y + box.h - right_corner_sz)
        love.graphics.line(box.x + box.w - right_corner_sz, box.y + box.h - right_corner_sz, box.x + box.w - right_corner_sz, box.y + box.h)
        
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, is_next_hov and 0.85 or 0.35 })
        love.graphics.print("►", box.x + box.w - right_corner_sz * 0.7, box.y + box.h - right_corner_sz * 0.8)
        
        self._next_rect = { x = box.x + box.w - right_corner_sz, y = box.y + box.h - right_corner_sz, w = right_corner_sz, h = right_corner_sz }
    else
        self._next_rect = nil
    end

    -- Continue button at the bottom (coupon-style cutout button)
    local s_ui    = (self.game.ui_scale) or 1
    local btn_w   = math.max(160, fl(220 * s_ui))
    local btn_h   = math.max(32, fl(42 * s_ui))
    local btn_x   = box.x + fl((box.w - btn_w) / 2)
    local btn_y   = box.y + box.h - btn_h - 14
    self._continue_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }

    local hov = mx >= btn_x and mx < btn_x + btn_w
                and my >= btn_y and my < btn_y + btn_h

    -- Draw dashed border surrounding the order coupon button
    Theme.setColor({ 0.15, 0.15, 0.12, 0.50 })
    love.graphics.rectangle("line", btn_x, btn_y, btn_w, btn_h)

    LabelButton.draw{
        x = btn_x + 2, y = btn_y + 2, w = btn_w - 4, h = btn_h - 4,
        text         = forcing_tutorial and "ORDER COMPLETED" or "CLOSE CATALOG",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = hov and (not forcing_tutorial),
        disabled     = forcing_tutorial,
        depth        = 3,
        fill_token   = (hov and not forcing_tutorial) and { 0.75, 0.20, 0.20 } or { 0.90, 0.86, 0.78 },
        border_token = forcing_tutorial and Theme.fg.disabled or { 0.15, 0.15, 0.12 },
        text_token   = (hov and not forcing_tutorial) and { 0.94, 0.90, 0.83 } or (forcing_tutorial and Theme.fg.disabled or { 0.15, 0.15, 0.12 }),
    }

    -- Continue tooltip check
    if hov and forcing_tutorial then
        TooltipSvc.set("Get the Poker Poster to start your next run.", mx, my)
    end

    love.graphics.setFont(fonts.sm)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.50 })
    love.graphics.printf("scroll wheel or grab corners to turn pages",
        box.x, btn_y - fonts.sm:getHeight() - 4, box.w, "center")

    self._modal:endDraw()
    
    -- Tooltip draw at the very end to be on top.
    TooltipSvc.draw(fonts)
end

return CatalogModal
