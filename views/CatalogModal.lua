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
local Catalog     = require("data.catalog")
local LabelButton = require("views.widgets.LabelButton")

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
--                   inspect items without spending PP outside the
--                   post-bust ritual. Affordable items skip the green
--                   "buyable" border so the read-only state reads
--                   clearly. Default false → full post-bust behavior.
function CatalogModal:new(game, opts)
    opts = opts or {}
    return setmetatable({
        game      = game,
        read_only = opts.read_only == true,
        -- Cached cell rects (built each :draw, consumed by :consumeMouse)
        _cells   = {},
        -- Vertical scroll offset (px). Positive = scrolled down.
        _scroll_y    = 0,
        _scroll_max  = 0,    -- recomputed each :draw from content height
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
        if not skip then
            out[#out + 1] = item
        end
    end

    -- Sort by PP cost ascending so the player sees what's affordable
    -- next at the top. Owned items stay in their natural cost slot
    -- (no bubble-to-bottom on purchase) — moving them around as the
    -- player buys was disorienting and shifted everything else.
    table.sort(out, function(a, b)
        local ac, bc = a.cost_pp or 0, b.cost_pp or 0
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

-- ─── Input ────────────────────────────────────────────────────────────

function CatalogModal:consumeKey(key)
    if key == "space" or key == "return" or key == "kpenter" then
        self._resolved = true
        return true
    end
    return false
end

-- Forward mouse-wheel events from ShoveState. dy > 0 = wheel up = scroll
-- content up (toward earlier items); dy < 0 = wheel down. Clamped to
-- content bounds (computed in :draw).
local SCROLL_STEP_PX = 60
function CatalogModal:wheelmoved(_, dy)
    if not dy or dy == 0 then return end
    -- Sign-only step: love.js's SDL2 port forwards browser wheel deltas
    -- raw (often ±100+ pixels per notch on Chrome / Edge), so dy *
    -- SCROLL_STEP_PX would launch the modal straight to the bottom in a
    -- single tick. Local LÖVE reports dy = ±1, where this collapses to
    -- the same per-notch step it always was.
    local step = (dy > 0) and 1 or -1
    self._scroll_y = self._scroll_y - step * SCROLL_STEP_PX
    if self._scroll_y < 0 then self._scroll_y = 0 end
    if self._scroll_max and self._scroll_y > self._scroll_max then
        self._scroll_y = self._scroll_max
    end
end

-- Returns true if the click landed on a buyable card and the buy succeeded.
-- Used by ShoveState:mousepressed to drive purchases without the click
-- bleeding through to grind-state hit-boxes underneath.
function CatalogModal:consumeMouse(mx, my, button)
    if button ~= 1 then return false end

    -- Continue button at the bottom — click resolves the modal so the
    -- host (ShoveState) can advance out of the post-bust catalog flow.
    -- Checked before cells so a Continue rect that overlaps a card
    -- cell still wins.
    local r = self._continue_rect
    if r and mx >= r.x and mx < r.x + r.w
       and my >= r.y and my < r.y + r.h then
        self._resolved = true
        return true
    end

    for _, cell in ipairs(self._cells) do
        if mx >= cell.x and mx < cell.x + cell.w
           and my >= cell.y and my < cell.y + cell.h then
            if cell.buyable and not self.read_only then
                return tryBuy(self.game, cell.item)
            end
            return true   -- consumed even if not buyable (don't fall through)
        end
    end
    return false
end

-- ─── Render ───────────────────────────────────────────────────────────

local function moneyish(n) return string.format("%d PP", n or 0) end

local function drawItemCard(self, item, owned, state, x, y, w, h, fonts)
    local is_owned   = owned[item.id]
    local locked     = item.requires and not owned[item.requires]
    local affordable = (not is_owned) and (not locked) and state.pp >= (item.cost_pp or 0)
    -- Read-only catalog (mid-grind inspection) never marks a card buyable
    -- so the green "buyable" border doesn't lie about being clickable.
    local buyable    = affordable and not self.read_only

    -- Card background. Tinted by status: muted when locked/owned, normal
    -- when affordable, faint when can't afford yet.
    local bg = Theme.bg.window
    local border = Theme.border.soft
    if is_owned then
        bg = Theme.bg.sunken
        border = Theme.border.soft
    elseif locked then
        bg = Theme.bg.sunken
    elseif buyable then
        border = Theme.fg.heading
    end

    Theme.setColor(bg)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(border)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)

    -- Header: name (left) + cost (right).
    local name_color = is_owned and Theme.fg.muted
                       or locked and Theme.fg.faint
                       or Theme.fg.heading
    Theme.setColor(name_color)
    love.graphics.setFont(fonts.md)
    love.graphics.print(item.name or "?", x + CARD_PAD_X, y + CARD_PAD_Y)

    local cost_label
    local cost_color = Theme.fg.primary
    if is_owned then
        cost_label = "OWNED"
        cost_color = Theme.status.good
    elseif locked then
        cost_label = "LOCKED"
        cost_color = Theme.fg.faint
    elseif (item.cost_pp or 0) <= 0 then
        cost_label = "FREE"
        cost_color = Theme.status.good
    elseif affordable then
        cost_label = moneyish(item.cost_pp)
        cost_color = Theme.fg.heading
    else
        cost_label = moneyish(item.cost_pp)
        cost_color = Theme.status.error
    end
    love.graphics.setFont(fonts.md)
    Theme.setColor(cost_color)
    local cw = fonts.md:getWidth(cost_label)
    love.graphics.print(cost_label, x + w - CARD_PAD_X - cw, y + CARD_PAD_Y)

    -- Effect / flavor lines stack below the title row. Y offsets derive
    -- from md (title) + sm (body) heights so text doesn't collide
    -- regardless of font size.
    local title_h  = fonts.md:getHeight()
    local effect_y = y + CARD_PAD_Y + title_h + 2
    local flavor_y = effect_y + fonts.sm:getHeight() + 2

    love.graphics.setFont(fonts.sm)
    Theme.setColor(is_owned and Theme.fg.muted or Theme.fg.primary)
    love.graphics.print(item.effect_text or "", x + CARD_PAD_X, effect_y)

    Theme.setColor(Theme.fg.faint)
    love.graphics.print(item.description or "", x + CARD_PAD_X, flavor_y)

    -- Stash for hit-testing.
    self._cells[#self._cells + 1] = {
        x = x, y = y, w = w, h = h, item = item, buyable = buyable,
    }
end

-- Maximum modal height as a fraction of the viewport. Anything taller
-- and the inner grid scrolls.
local MODAL_MAX_H_FRAC = 0.90

function CatalogModal:draw()
    local fonts = self.game.fonts
    local state = self.game.state

    -- Scale design-space constants by the live ui_scale so the modal
    -- and its card grid grow with the window.
    local s = (self.game.ui_scale) or 1
    MODAL_W      = math.floor(MODAL_W_BASE   * s)
    MODAL_PAD    = math.floor(MODAL_PAD_BASE * s)
    GRID_GAP_X   = math.floor(GRID_GAP_X_BASE * s)
    GRID_GAP_Y   = math.floor(GRID_GAP_Y_BASE * s)
    CARD_PAD_X   = math.floor(CARD_PAD_X_BASE * s)
    CARD_PAD_Y   = math.floor(CARD_PAD_Y_BASE * s)
    -- Tight card height: title (md) + effect (sm) + flavor (sm) +
    -- top/bottom pad + the two 2-px inter-line gaps used in drawItemCard.
    -- Recomputed per-draw so it always tracks the live scaled padding.
    CARD_H = fonts.md:getHeight() + 2 * fonts.sm:getHeight()
             + 2 * CARD_PAD_Y + 4

    -- Modal frame + dim backdrop come from the shared Modal widget so
    -- the chrome stays consistent with the other overlays. Rebuild it
    -- per-draw so width tracks the current scale.
    local Modal = require("views.widgets.Modal")
    self._modal = Modal:new{ w = MODAL_W, max_h_frac = MODAL_MAX_H_FRAC,
                             pad = 0 }

    local items, owned = visibleItems(state)
    local n_rows   = math.ceil(#items / GRID_COLS)
    local card_w   = math.floor((MODAL_W - 2 * MODAL_PAD - GRID_GAP_X) / GRID_COLS)
    local content_h = n_rows * CARD_H + math.max(0, n_rows - 1) * GRID_GAP_Y
    local body_h   = HEADER_H + content_h + 2 * MODAL_PAD + FOOTER_H

    self._modal:draw(fonts, body_h)
    local box = self._modal:boxRect()

    -- Header: title (left) + PP (right).
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.lg)
    love.graphics.print("CATALOG", box.x + MODAL_PAD, box.y + 16)
    local pp_label = string.format("%d PP", state.pp or 0)
    Theme.setColor(Theme.status.good)
    local pp_w = fonts.lg:getWidth(pp_label)
    love.graphics.print(pp_label,
        box.x + box.w - MODAL_PAD - pp_w, box.y + 16)

    -- Scroll viewport for the grid.
    local viewport_x = box.x + MODAL_PAD
    local viewport_y = box.y + HEADER_H + MODAL_PAD
    local viewport_w = box.w - 2 * MODAL_PAD
    local viewport_h = box.h - HEADER_H - 2 * MODAL_PAD - FOOTER_H

    self._scroll_max = math.max(0, content_h - viewport_h)
    if self._scroll_y > self._scroll_max then self._scroll_y = self._scroll_max end
    if self._scroll_y < 0 then self._scroll_y = 0 end

    love.graphics.setScissor(viewport_x, viewport_y, viewport_w, viewport_h)

    self._cells = {}
    for i, item in ipairs(items) do
        local col = (i - 1) % GRID_COLS
        local row = math.floor((i - 1) / GRID_COLS)
        local cx = viewport_x + col * (card_w + GRID_GAP_X)
        local cy = viewport_y + row * (CARD_H + GRID_GAP_Y) - self._scroll_y
        if cy + CARD_H >= viewport_y and cy <= viewport_y + viewport_h then
            drawItemCard(self, item, owned, state, cx, cy, card_w, CARD_H, fonts)
        end
    end

    love.graphics.setScissor()

    if self._scroll_max > 0 then
        local track_x = box.x + box.w - 8
        local track_y = viewport_y
        local track_h = viewport_h
        Theme.setColor(Theme.bg.sunken, 0.6)
        love.graphics.rectangle("fill", track_x, track_y, 4, track_h, 2)
        local thumb_h = math.max(20, track_h * (viewport_h / content_h))
        local thumb_y = track_y + (track_h - thumb_h) * (self._scroll_y / self._scroll_max)
        Theme.setColor(Theme.fg.muted)
        love.graphics.rectangle("fill", track_x, thumb_y, 4, thumb_h, 2)
    end

    -- Continue button at the bottom. Replaces the old "[ SPACE to
    -- continue ]" text prompt so the modal works in prototype mode
    -- (where every key is dead) — click to dismiss.
    local s_ui    = (self.game.ui_scale) or 1
    local btn_w   = math.max(140, math.floor(200 * s_ui))
    local btn_h   = math.max(28, math.floor(40  * s_ui))
    local btn_x   = box.x + math.floor((box.w - btn_w) / 2)
    local btn_y   = box.y + box.h - btn_h - 14
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

    if self._scroll_max > 0 then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf("scroll wheel to browse",
            box.x, btn_y - fonts.sm:getHeight() - 4, box.w, "center")
    end

    self._modal:endDraw()
end

return CatalogModal
