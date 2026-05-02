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

local Theme   = require("views.Theme")
local Catalog = require("data.catalog")

local CatalogModal = {}
CatalogModal.__index = CatalogModal

-- ─── Layout constants ──────────────────────────────────────────────────

local MODAL_W           = 980
local MODAL_PAD         = 24

local HEADER_H          = 56
local FOOTER_H          = 44

local GRID_COLS         = 2
local GRID_GAP_X        = 16
local GRID_GAP_Y        = 12
local CARD_PAD_X        = 14
local CARD_PAD_Y        = 10
local CARD_H            = 84

-- ─── Construction ──────────────────────────────────────────────────────

function CatalogModal:new(game)
    return setmetatable({
        game     = game,
        -- Cached cell rects (built each :draw, consumed by :consumeMouse)
        _cells   = {},
    }, CatalogModal)
end

-- ─── Visibility filter ────────────────────────────────────────────────

-- Owned/locked-aware filter mirroring the old in-grind catalog tab. Hides
-- system phantoms (handicap), locked items behind requires_hide, and any
-- non-demo phase items so the modal stays focused on the 11-item demo
-- catalog. Future phases would ship via a phase=mid|late filter relaxation
-- (or a phase-progression flag on state).
local function visibleItems(state)
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local out = {}
    for _, item in ipairs(Catalog) do
        local locked = item.requires and not owned[item.requires]
        local skip = item.hidden
                  or item.phase ~= "demo"
                  or (locked and item.requires_hide)
        if not skip then
            out[#out + 1] = item
        end
    end
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
    return key == "space" or key == "return"
end

-- Returns true if the click landed on a buyable card and the buy succeeded.
-- Used by ShoveState:mousepressed to drive purchases without the click
-- bleeding through to grind-state hit-boxes underneath.
function CatalogModal:consumeMouse(mx, my, button)
    if button ~= 1 then return false end
    for _, cell in ipairs(self._cells) do
        if mx >= cell.x and mx < cell.x + cell.w
           and my >= cell.y and my < cell.y + cell.h then
            if cell.buyable then
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
    local buyable    = affordable

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
    love.graphics.setFont(fonts.heading)
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
    love.graphics.setFont(fonts.ui)
    Theme.setColor(cost_color)
    local cw = fonts.ui:getWidth(cost_label)
    love.graphics.print(cost_label, x + w - CARD_PAD_X - cw, y + CARD_PAD_Y + 4)

    -- Effect line.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(is_owned and Theme.fg.muted or Theme.fg.primary)
    love.graphics.print(item.effect_text or "",
        x + CARD_PAD_X, y + CARD_PAD_Y + 28)

    -- Flavor (italic-feel via muted color).
    Theme.setColor(Theme.fg.faint)
    love.graphics.print(item.description or "",
        x + CARD_PAD_X, y + CARD_PAD_Y + 48)

    -- Stash for hit-testing.
    self._cells[#self._cells + 1] = {
        x = x, y = y, w = w, h = h, item = item, buyable = buyable,
    }
end

function CatalogModal:draw()
    local W, H  = love.graphics.getDimensions()
    local fonts = self.game.fonts
    local state = self.game.state

    -- Backdrop dim.
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local items, owned = visibleItems(state)
    local n_rows = math.ceil(#items / GRID_COLS)
    local card_w = math.floor((MODAL_W - 2 * MODAL_PAD - GRID_GAP_X) / GRID_COLS)
    local grid_h = n_rows * CARD_H + (n_rows - 1) * GRID_GAP_Y
    local modal_h = HEADER_H + grid_h + 2 * MODAL_PAD + FOOTER_H

    local mx_modal = math.floor((W - MODAL_W) / 2)
    local my_modal = math.floor((H - modal_h) / 2)

    -- Modal card.
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", mx_modal, my_modal, MODAL_W, modal_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", mx_modal, my_modal, MODAL_W, modal_h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- Header: title (left) + PP (right).
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.kpi)
    love.graphics.print("CATALOG", mx_modal + MODAL_PAD, my_modal + 16)
    local pp_label = string.format("%d PP", state.pp or 0)
    love.graphics.setFont(fonts.kpi)
    Theme.setColor(Theme.status.good)
    local pp_w = fonts.kpi:getWidth(pp_label)
    love.graphics.print(pp_label,
        mx_modal + MODAL_W - MODAL_PAD - pp_w, my_modal + 16)

    -- Grid.
    self._cells = {}
    local grid_x = mx_modal + MODAL_PAD
    local grid_y = my_modal + HEADER_H + MODAL_PAD
    for i, item in ipairs(items) do
        local col = (i - 1) % GRID_COLS
        local row = math.floor((i - 1) / GRID_COLS)
        local cx = grid_x + col * (card_w + GRID_GAP_X)
        local cy = grid_y + row * (CARD_H + GRID_GAP_Y)
        drawItemCard(self, item, owned, state, cx, cy, card_w, CARD_H, fonts)
    end

    -- Footer prompt.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("[ SPACE to continue ]",
        mx_modal, my_modal + modal_h - 28, MODAL_W, "center")
end

return CatalogModal
