-- views/CatalogModal.lua
--
-- Post-bust catalog. Replaces the old always-visible left-panel tab —
-- catalog purchases now happen here, after the PrestigeModal has been
-- dismissed but before the run is reset and we return to grind.
--
-- Presented as a physical order-book on a dim backdrop. There is NO hard
-- modal frame that resizes: a resizing frame made the whole UI (border,
-- dog-ears, header) morph and jump when the book opened. Instead every PAGE
-- is a self-contained leaf — its own running title, chip ledger (right page),
-- three item cards, page number — and the WHOLE leaf turns, top to bottom.
-- The closed cover is one narrow page; opening genuinely widens the book to
-- a two-page spread by animating the leaves themselves.
--
-- Click an affordable item to buy. Owned items render dimmed with "ORDERED";
-- unlock-gated items render as silhouettes with their requirement text. SPACE
-- dismisses the modal — ShoveState consumes that key and runs the actual
-- run-reset / state-switch.
--
-- Pure presentation. Buy clicks dispatch through GrindController:buyCatalogItem,
-- which handles effects-cache invalidation, the purchase sound, and the
-- guarded model mutation (the model still owns its own state — the
-- controller is the layer the view talks to).

local Theme        = require("views.Theme")
local Constants    = require("data.constants")
local Catalog      = require("data.catalog")
local CatalogPages = require("data.catalog_pages")
local LabelButton  = require("views.widgets.LabelButton")
local Icons        = require("views.Icons")
local IconText     = require("views.IconText")
local TooltipSvc     = require("services.Tooltip")

-- Stable "No. NNN" code per item = its position in the master catalog, so the
-- serial on a card doesn't shuffle as pages filter items in and out.
local CATALOG_ORD = {}
for i, it in ipairs(Catalog) do CATALOG_ORD[it.id] = i end

local CatalogModal = {}
CatalogModal.__index = CatalogModal

-- ─── Layout constants ──────────────────────────────────────────────────

-- Base "design" sizes — scaled by ui_scale at draw time so the book grows
-- with the window (a 4K screen shouldn't show a tiny card grid in a void).
local MODAL_W_BASE      = 980

-- Live value; CARD_H is recomputed each :draw against the ui-scaled fonts.
local CARD_H            = 84

-- Kept for external callers (host measures header height off this).
local HEADER_H          = 56
local FOOTER_H          = 44

function CatalogModal.configureFromFonts(fonts)
    if not (fonts and fonts.md) then return end
    HEADER_H = fonts.lg:getHeight() + 16
    FOOTER_H = fonts.md:getHeight() + 16
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
        -- Spread index (0 = front cover, 1 = pages 1-2, ..., max = back cover)
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

-- An item with an `unlock` condition stays a silhouette (visible, showing
-- its requirement text) until the condition is met — the Vampire-Survivors
-- "you can see how to get it" pattern. No unlock → always available. Reuses
-- the same UnlockRegistry the decks use (see models/catalog_unlock_rules).
-- Live-checked; the conditions are monotonic counters so once met they stay.
local function catalogUnlocked(game, item, state)
    if not item.unlock then return true end
    if not (game and game.unlock_rules) then return true end
    return game.unlock_rules:check(item.unlock, state)
end

-- ─── Page model ───────────────────────────────────────────────────────

-- Build the ordered list of leaves (pages) from the authored layout in
-- data/catalog_pages.lua, filtered by the same visibility rules as the flat
-- list: hidden/handicap phantoms, prerequisite-hidden items, and act-3-gated
-- items drop out. A leaf whose items all drop out is omitted. Any visible
-- item not named on a page lands in a trailing "&c." catch-all so nothing is
-- ever unreachable. Returns { {title=, items={item,...}}, ... }, owned.
--
-- Visibility is a plain field test — no cost sort here; order is authored.
function CatalogModal:_pages()
    local state = self.game.state
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local function visible(item)
        local locked = item.requires and not owned[item.requires]
        if item.hidden then return false end
        if locked and item.requires_hide then return false end
        if item.requires_act3 and not state.shove_r2_won then return false end
        return true
    end

    local byId = {}
    for _, it in ipairs(Catalog) do byId[it.id] = it end

    local placed, pages = {}, {}
    for _, pdef in ipairs(CatalogPages) do
        local leaf = {}
        for _, id in ipairs(pdef.items) do
            local it = byId[id]
            placed[id] = true                       -- authored → never a leftover
            if it and visible(it) then leaf[#leaf + 1] = it end
        end
        if #leaf > 0 then pages[#pages + 1] = { title = pdef.title, items = leaf } end
    end

    -- Catch-all for any visible item the author forgot to place, 3 per leaf.
    local orphans = {}
    for _, it in ipairs(Catalog) do
        if not placed[it.id] and visible(it) then orphans[#orphans + 1] = it end
    end
    for i = 1, #orphans, 3 do
        local leaf = {}
        for j = i, math.min(i + 2, #orphans) do leaf[#leaf + 1] = orphans[j] end
        pages[#pages + 1] = { title = "&c.", items = leaf }
    end

    return pages, owned
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
    local pages = self:_pages()
    local max_spread = math.ceil(#pages / 2) + 1
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
        local pages = self:_pages()
        local max_spread = math.ceil(#pages / 2) + 1
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

-- hero = true renders a full-leaf feature card: big centered art with the
-- name/effect/shove centered beneath, instead of the left-thumb row layout.
-- All the buy/lock/stamp logic is identical either way — only the art + text
-- placement branches, so there's one source of truth for state and hit-cells.
local function drawItemCard(self, item, owned, state, x, y, w, h, fonts, forcing_tutorial, index, hero)
    local is_owned   = owned[item.id]
    local unlock_locked = (not is_owned) and not catalogUnlocked(self.game, item, state)
    local locked     = (item.requires and not owned[item.requires]) or unlock_locked
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

    -- Picture frame for the illustration. Hero: a large square centered in the
    -- card's upper half. Normal: a small thumb on the left.
    local img_w, img_h, img_x, img_y
    if hero then
        img_w = math.min(fl(140 * s), fl(h * 0.5))
        img_h = img_w
        img_x = x + (w - img_w) * 0.5
        img_y = y + fl(24 * s)
    else
        img_w = fl(56 * s)
        img_h = fl(56 * s)
        img_x = x + fl(8 * s)
        img_y = y + fl(14 * s)
    end

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

        if unlock_locked then
            -- Silhouette: draw the art as a dark ink shape, no detail.
            love.graphics.setColor(0.15, 0.15, 0.12, 0.55)
        else
            love.graphics.setColor(1, 1, 1, (is_owned and not is_corruptible and not is_corrupted) and 0.40 or 1.0)
        end
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

    local dim = (is_owned and not is_corruptible and not is_corrupted)
    local ink = dim and { 0.15, 0.15, 0.12, 0.40 } or { 0.15, 0.15, 0.12 }

    -- Precompute the shove stat (registry-dispatched, no kind-string checks).
    local sctx = {}
    self.game.effects:applyAll(item, sctx)
    local shove = sctx.shove_rate or 0
    local shove_txt = shove > 0 and string.format("+%d%% shove", math.floor(shove * 100 + 0.5)) or nil
    local shove_ink = dim and { 0.20, 0.35, 0.55, 0.45 } or { 0.20, 0.35, 0.55 }

    if hero then
        -- Centered feature layout beneath the big art.
        local cxm = x + w * 0.5
        local ty  = img_y + img_h + fl(10 * s)

        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.60 })
        local code = string.format("No. %03d", index or 0)
        love.graphics.print(code, cxm - fonts.sm:getWidth(code) * 0.5, ty)
        ty = ty + fonts.sm:getHeight() + 2

        love.graphics.setFont(fonts.md)
        Theme.setColor(ink)
        local nm = (item.name or "?"):upper()
        love.graphics.print(nm, cxm - fonts.md:getWidth(nm) * 0.5, ty)
        ty = ty + fonts.md:getHeight() + 4

        if unlock_locked then
            love.graphics.setFont(fonts.sm)
            Theme.setColor({ 0.15, 0.15, 0.12, 0.55 })
            local ut = (item.unlock and item.unlock.text) or "Locked"
            love.graphics.print(ut, cxm - fonts.sm:getWidth(ut) * 0.5, ty)
        else
            local eff_text = (is_corrupted and item.corrupt.effect_text or item.effect_text) or ""
            local ew = IconText.measure(eff_text, fonts.sm)
            IconText.draw(self.game, eff_text, cxm - ew * 0.5, ty, fonts.sm, ink)
            ty = ty + fonts.sm:getHeight() + 4
            if shove_txt then
                love.graphics.setFont(fonts.sm)
                Theme.setColor(shove_ink)
                love.graphics.print(shove_txt, cxm - fonts.sm:getWidth(shove_txt) * 0.5, ty)
            end
        end
    else
        -- Item Header info: Number code + Name
        local text_x = img_x + img_w + fl(12 * s)
        local title_y = y + fl(8 * s)

        local index_text = string.format("No. %03d", index or 0)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.60 })
        love.graphics.setFont(fonts.sm)
        love.graphics.print(index_text, text_x, title_y)

        local name_y = title_y + fonts.sm:getHeight() + 1
        Theme.setColor(ink)
        love.graphics.setFont(fonts.md)
        love.graphics.print((item.name or "?"):upper(), text_x, name_y)

        -- Description / Effect — or, when locked behind an unlock, the
        -- requirement text in place of what it does (you learn how to get it,
        -- the effect stays a surprise).
        local effect_y = name_y + fonts.md:getHeight() + 3
        if unlock_locked then
            Theme.setColor({ 0.15, 0.15, 0.12, 0.55 })
            love.graphics.setFont(fonts.sm)
            love.graphics.print((item.unlock and item.unlock.text) or "Locked", text_x, effect_y)
        else
            local eff_text = is_corrupted and item.corrupt.effect_text or item.effect_text
            IconText.draw(self.game, eff_text or "", text_x, effect_y, fonts.sm, ink)

            local flavor_y = effect_y + fonts.sm:getHeight() + 2
            Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
            love.graphics.setFont(fonts.sm)

            local desc_w = w - (img_w + fl(20 * s)) - fl(44 * s)
            local desc_txt = item.description or ""
            if fonts.sm:getWidth(desc_txt) > desc_w then
                desc_txt = desc_txt:sub(1, 30) .. "..."
            end
            love.graphics.print(desc_txt, text_x, flavor_y)

            -- Shove contribution: its own right-aligned stat on the flavor line.
            -- Makes "buying builds your shove base" legible — every buyable
            -- item advertises how much % it adds.
            if shove_txt then
                Theme.setColor(shove_ink)
                love.graphics.setFont(fonts.sm)
                love.graphics.print(shove_txt, x + w - fl(12 * s) - fonts.sm:getWidth(shove_txt), flavor_y)
            end
        end
    end

    -- Stash cell bounds for hit-testing. Skipped mid-flip: leaves are drawn
    -- under a scale transform then, so the logical rect wouldn't match what's
    -- on screen — and clicks shouldn't land during a page turn anyway.
    if not self.flip_t then
        self._cells[#self._cells + 1] = {
            x = x, y = y, w = w, h = h, item = item, buyable = buyable, corruptible = corruptible,
        }
    end

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

-- ─── Book rendering ────────────────────────────────────────────────────

-- Horizontal-scale flip around a vertical hinge: draws `fn` squished toward
-- hinge_x by factor sx (1 = flat/full, 0 = edge-on). Turns a whole leaf.
local function drawFlipped(hinge_x, sx, fn)
    if sx <= 0.02 then return end
    love.graphics.push()
    love.graphics.translate(hinge_x, 0)
    love.graphics.scale(sx, 1)
    love.graphics.translate(-hinge_x, 0)
    fn()
    love.graphics.pop()
end

-- One complete page leaf: paper, its authored title, chip ledger (right page
-- only), its item cards packed into 3 vertical slot-units by each item's
-- `slots` (1 default; 3 = a full-leaf hero card), and the page number. `page`
-- is { title, items } or nil (a blank verso — draw bare paper only).
local function drawLeaf(self, page, page_num, owned, state, fonts, forcing, x, y, w, h, is_right, s, card_h)
    local fl = math.floor
    Theme.setColor({ 0.94, 0.90, 0.83 })
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.40 })
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.12 })
    love.graphics.rectangle("line", x + fl(4 * s), y + fl(4 * s), w - fl(8 * s), h - fl(8 * s), Theme.space.radius)

    if not page then return end   -- blank verso

    local pad = fl(12 * s)
    -- Authored page title — turns WITH the leaf.
    Theme.setColor({ 0.15, 0.15, 0.12 })
    love.graphics.setFont(fonts.md)
    love.graphics.print((page.title or ""):upper(), x + pad, y + fl(10 * s))
    -- Chip ledger, right page only.
    if is_right then
        local bal   = string.format("%d", state.chips or 0)
        local bal_w = fonts.md:getWidth(bal)
        local gsize = fonts.md:getHeight()
        local gap   = fl(5 * s)
        local bx    = x + w - pad - (bal_w + gap + gsize)
        Theme.setColor({ 0.75, 0.20, 0.20 })
        love.graphics.print(bal, bx, y + fl(10 * s))
        Icons.drawChip(self.game, bx + bal_w + gap, y + fl(10 * s), gsize)
    end
    local head_h = fonts.md:getHeight() + fl(16 * s)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.20 })
    love.graphics.line(x + pad, y + head_h, x + w - pad, y + head_h)

    -- Pack item cards top-down. A slots=N item is N units tall; stop once the
    -- 3-unit budget is spent (authored pages should sum to ≤ 3).
    local cw    = w - 2 * pad
    local gapc  = fl(10 * s)
    local cy    = y + head_h + fl(8 * s)
    local used  = 0
    for _, item in ipairs(page.items) do
        local sp = item.slots or 1
        if used + sp > 3 then break end
        local ch = sp * card_h + (sp - 1) * gapc
        drawItemCard(self, item, owned, state, x + pad, cy, cw, ch, fonts, forcing,
            CATALOG_ORD[item.id] or 0, sp >= 3)
        cy   = cy + ch + gapc
        used = used + sp
    end

    -- Page number, bottom-center.
    love.graphics.setFont(fonts.sm)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
    local ns = tostring(page_num)
    love.graphics.print(ns, x + w * 0.5 - fonts.sm:getWidth(ns) * 0.5, y + h - fonts.sm:getHeight() - fl(8 * s))
end

-- Front cover face (single narrow page).
local function drawFrontCover(self, x, y, w, h, fonts, s)
    local fl = math.floor
    Theme.setColor({ 0.90, 0.85, 0.76 })
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.55 })
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.20 })
    love.graphics.rectangle("line", x + fl(5 * s), y + fl(5 * s), w - fl(10 * s), h - fl(10 * s), Theme.space.radius)

    Theme.setColor({ 0.15, 0.15, 0.12 })
    love.graphics.setFont(fonts.lg)
    love.graphics.printf("SEARS, ROEBUCK & CO.", x, y + fl(40 * s), w, "center")

    local dx, dy, dr = x + w * 0.5, y + h * 0.46, fl(48 * s)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.30 })
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", dx, dy, dr)
    love.graphics.circle("line", dx, dy, dr - fl(4 * s))
    love.graphics.setLineWidth(1)
    love.graphics.setFont(fonts.md)
    love.graphics.print("1999", dx - fonts.md:getWidth("1999") * 0.5, dy - fonts.md:getHeight() - 2)
    love.graphics.print("EDITION", dx - fonts.md:getWidth("EDITION") * 0.5, dy + 2)

    Theme.setColor({ 0.15, 0.15, 0.12 })
    love.graphics.setFont(fonts.lg)
    love.graphics.printf("CELL FURNISHINGS", x, y + h * 0.66, w, "center")
    love.graphics.setFont(fonts.md)
    love.graphics.printf("CATALOG & ORDER BOOK", x, y + h * 0.74, w, "center")

    love.graphics.setFont(fonts.sm)
    Theme.setColor({ 0.75, 0.20, 0.20 })
    love.graphics.printf("GRAB CORNER TO OPEN", x, y + h * 0.88, w, "center")
end

-- Back cover face. When interactive, mounts the prominent CLOSE button and
-- sets self._continue_rect; mid-flip it's just the visual (no hit rect).
local function drawBackCover(self, x, y, w, h, fonts, state, forcing, s, interactive)
    local fl = math.floor
    Theme.setColor({ 0.90, 0.85, 0.76 })
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.55 })
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.20 })
    love.graphics.rectangle("line", x + fl(5 * s), y + fl(5 * s), w - fl(10 * s), h - fl(10 * s), Theme.space.radius)

    Theme.setColor({ 0.15, 0.15, 0.12 })
    love.graphics.setFont(fonts.lg)
    love.graphics.printf("ORDER SUMMARY", x, y + fl(40 * s), w, "center")

    local owned_count = 0
    for _, id in ipairs(state.owned_items or {}) do
        if id ~= "no_poster_handicap" then owned_count = owned_count + 1 end
    end
    love.graphics.setFont(fonts.md)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.70 })
    love.graphics.printf(string.format("Items active in room: %d", owned_count), x, y + h * 0.34, w, "center")
    love.graphics.setFont(fonts.sm)
    love.graphics.printf("All mail orders processed immediately.\nDecorations persist across prestiges.", x, y + h * 0.42, w, "center")

    local btn_w = math.max(160, fl(200 * s))
    local btn_h = math.max(32, fl(42 * s))
    local btn_x = x + fl((w - btn_w) / 2)
    local btn_y = fl(y + h * 0.60)
    local mx, my = love.mouse.getPosition()
    local hov = interactive and mx >= btn_x and mx < btn_x + btn_w and my >= btn_y and my < btn_y + btn_h
    if interactive then
        self._continue_rect = { x = btn_x, y = btn_y, w = btn_w, h = btn_h }
    end
    Theme.setColor({ 0.15, 0.15, 0.12, 0.50 })
    love.graphics.rectangle("line", btn_x, btn_y, btn_w, btn_h)
    LabelButton.draw{
        x = btn_x + 2, y = btn_y + 2, w = btn_w - 4, h = btn_h - 4,
        text         = forcing and "ORDER COMPLETED" or "CLOSE CATALOG",
        fonts        = fonts,
        font         = fonts.md,
        hovered      = hov and (not forcing),
        disabled     = forcing,
        depth        = 3,
        fill_token   = (hov and not forcing) and { 0.75, 0.20, 0.20 } or { 0.90, 0.86, 0.78 },
        border_token = forcing and Theme.fg.disabled or { 0.15, 0.15, 0.12 },
        text_token   = (hov and not forcing) and { 0.94, 0.90, 0.83 } or (forcing and Theme.fg.disabled or { 0.15, 0.15, 0.12 }),
    }
    if hov and forcing then TooltipSvc.set("Get the Poker Poster to start your next run.", mx, my) end

    love.graphics.setFont(fonts.sm)
    Theme.setColor({ 0.75, 0.20, 0.20 })
    love.graphics.printf("GRAB CORNER TO BROWSE", x, y + h * 0.88, w, "center")
end

function CatalogModal:draw()
    local fonts = self.game.fonts
    local state = self.game.state
    local fl = math.floor

    -- Page-flip timer.
    local dt = love.timer.getDelta()
    if self.flip_t then
        self.flip_t = self.flip_t - dt
        if self.flip_t <= 0 then
            self.flip_t = nil
            self.flip_dir = nil
            self.old_spread_index = nil
        end
    end

    local s = self.game.ui_scale or 1
    local W, H = love.graphics.getDimensions()

    local pages, owned = self:_pages()
    local max_spread = math.ceil(#pages / 2) + 1
    local forcing = (not Constants.FEATURES.TUTORIAL)
                    and (not owned["poker_poster"]) and (not self.read_only)

    -- Page + book geometry. One page = half the base modal width; an open
    -- spread is two of them, centered on the spine at screen center.
    CARD_H = fonts.md:getHeight() + 3 * fonts.sm:getHeight() + fl(16 * s) + 8
    local card_h = CARD_H
    local page_w = fl(MODAL_W_BASE * s * 0.5)
    local head_h = fonts.md:getHeight() + fl(16 * s)
    local page_h = fl(head_h + fl(8 * s) + 3 * card_h + 2 * fl(10 * s) + fonts.sm:getHeight() + fl(22 * s))
    local cx     = W * 0.5
    local top    = fl((H - page_h) * 0.5)

    -- Dim backdrop only — no hard frame to morph.
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", 0, 0, W, H)

    self._cells = {}
    self._continue_rect = nil

    local idx      = self.spread_index
    local old      = self.old_spread_index
    local flipping = self.flip_t ~= nil
    local progress = flipping and (self.flip_t / 0.35) or 0   -- 1 -> 0

    -- leaf_idx indexes the pages list (1-based). Spread k shows leaves
    -- 2k-1 (left) and 2k (right); an out-of-range index draws a blank verso.
    local function leaf(leaf_idx, x, is_right)
        drawLeaf(self, pages[leaf_idx], leaf_idx, owned, state, fonts, forcing, x, top, page_w, page_h, is_right, s, card_h)
    end

    if not flipping then
        -- ── Static views ──
        if idx == 0 then
            -- Front cover = the right leaf (spine at centre); grab its outer
            -- right corner to open. Fixed slot, so the corner never moves.
            drawFrontCover(self, cx, top, page_w, page_h, fonts, s)
        elseif idx == max_spread then
            -- Back cover = the left leaf; grab its outer left corner to browse.
            drawBackCover(self, cx - page_w, top, page_w, page_h, fonts, state, forcing, s, true)
        else
            leaf(idx * 2 - 1, cx - page_w, false)
            leaf(idx * 2, cx, true)
        end

    elseif old == 0 or idx == 0 then
        -- ── Front cover open/close. ONE leaf turns on the spine: it starts as
        -- the cover in the right slot, flips to edge-on, then lands flat in the
        -- left slot as page 1 (its inside face). Page 2 sits static in the right
        -- slot, revealed as the cover lifts. Only a single leaf is ever in
        -- motion — no double slide. q: 0 = closed, 1 = open. ──
        local opening = (idx == 1)
        local q = opening and (1 - progress) or progress
        leaf(2, cx, true)                                  -- page 2, static right slot
        if q < 0.5 then
            drawFlipped(cx, 1 - q * 2, function()          -- cover flips to edge-on (right slot)
                drawFrontCover(self, cx, top, page_w, page_h, fonts, s)
            end)
        else
            drawFlipped(cx, (q - 0.5) * 2, function()      -- page 1 opens flat (left slot)
                leaf(1, cx - page_w, false)
            end)
        end

    elseif old == max_spread or idx == max_spread then
        -- ── Back cover open/close. Mirror of the front, one leaf on the spine:
        -- it starts as the back cover in the left slot, flips to edge-on, then
        -- lands flat in the right slot as the spread's right page. The left
        -- page sits static, revealed as the cover lifts. ──
        local cs      = max_spread - 1
        local opening = (idx == cs)
        local q = opening and (1 - progress) or progress
        leaf(cs * 2 - 1, cx - page_w, false)               -- left page, static left slot
        if q < 0.5 then
            drawFlipped(cx, 1 - q * 2, function()          -- back cover flips to edge-on (left slot)
                drawBackCover(self, cx - page_w, top, page_w, page_h, fonts, state, forcing, s, false)
            end)
        else
            drawFlipped(cx, (q - 0.5) * 2, function()      -- right page opens flat (right slot)
                leaf(cs * 2, cx, true)
            end)
        end

    else
        -- ── Inner spread ⇄ inner spread: whole-leaf spine flip ──
        local spine = cx
        local a     = progress   -- 1 -> 0
        if idx > old then
            -- forward: old right leaf flips left across the spine
            if a > 0.5 then
                leaf(old * 2 - 1, cx - page_w, false)   -- old left stays
                leaf(idx * 2, cx, true)                 -- new right revealed
                drawFlipped(spine, (a - 0.5) * 2, function() leaf(old * 2, cx, true) end)
            else
                leaf(idx * 2, cx, true)                 -- new right
                leaf(old * 2 - 1, cx - page_w, false)   -- old left (about to be covered)
                drawFlipped(spine, (0.5 - a) * 2, function() leaf(idx * 2 - 1, cx - page_w, false) end)
            end
        else
            -- backward: old left leaf flips right across the spine
            if a > 0.5 then
                leaf(old * 2, cx, true)                 -- old right stays
                leaf(idx * 2 - 1, cx - page_w, false)   -- new left revealed
                drawFlipped(spine, (a - 0.5) * 2, function() leaf(old * 2 - 1, cx - page_w, false) end)
            else
                leaf(idx * 2 - 1, cx - page_w, false)   -- new left
                leaf(old * 2, cx, true)                 -- old right (about to be covered)
                drawFlipped(spine, (0.5 - a) * 2, function() leaf(idx * 2, cx, true) end)
            end
        end
    end

    -- ── Corner controls. Book bounds are ALWAYS the full open-spread extent,
    -- cover or spread, so the dog-ear corners and the close ✕ never move
    -- between views — that motion is what made the buttons annoying to hit.
    -- Non-interactive during a flip. ──
    local book_l = fl(cx - page_w)
    local book_r = fl(cx + page_w)
    local book_b = top + page_h
    local mx, my = love.mouse.getPosition()

    -- Previous-page dog-ear (bottom-left).
    self._prev_rect = nil
    if idx > 0 then
        local sz  = fl(28 * s)
        local hov = mx >= book_l and mx <= book_l + fl(48 * s) and my >= book_b - fl(48 * s) and my <= book_b
        if hov then sz = fl(38 * s) end
        Theme.setColor({ 0.88, 0.84, 0.77 })
        love.graphics.polygon("fill", book_l + sz, book_b, book_l + sz, book_b - sz, book_l, book_b - sz)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
        love.graphics.line(book_l + sz, book_b, book_l, book_b - sz)
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, hov and 0.85 or 0.40 })
        love.graphics.print("<", book_l + sz * 0.35, book_b - sz * 0.8)
        if not flipping then self._prev_rect = { x = book_l, y = book_b - sz, w = sz, h = sz } end
    end

    -- Next-page dog-ear (bottom-right).
    self._next_rect = nil
    if idx < max_spread then
        local sz  = fl(28 * s)
        local hov = mx >= book_r - fl(48 * s) and mx <= book_r and my >= book_b - fl(48 * s) and my <= book_b
        if hov then sz = fl(38 * s) end
        Theme.setColor({ 0.88, 0.84, 0.77 })
        love.graphics.polygon("fill", book_r - sz, book_b, book_r - sz, book_b - sz, book_r, book_b - sz)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
        love.graphics.line(book_r - sz, book_b, book_r, book_b - sz)
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, hov and 0.85 or 0.40 })
        love.graphics.print(">", book_r - sz * 0.65, book_b - sz * 0.8)
        if not flipping then self._next_rect = { x = book_r - sz, y = book_b - sz, w = sz, h = sz } end
    end

    -- Subtle close: a small muted ✕ in the margin just ABOVE the book's
    -- top-right corner (on the dim backdrop) on every view except the back
    -- cover (which owns the prominent CLOSE). Sits clear of the right page's
    -- {chip} ledger, which lives inside that same corner. Suppressed while the
    -- intro forces a poster purchase, and during a flip.
    if idx ~= max_spread and not flipping and not forcing then
        local cz   = fl(20 * s)
        local cxr  = book_r - cz
        local cyr  = math.max(fl(6 * s), top - cz - fl(6 * s))
        local hovx = mx >= cxr and mx < cxr + cz and my >= cyr and my < cyr + cz
        Theme.setColor({ 0.15, 0.15, 0.12, hovx and 0.85 or 0.40 })
        love.graphics.setLineWidth(fl(2 * s))
        local xp = fl(5 * s)
        love.graphics.line(cxr + xp, cyr + xp, cxr + cz - xp, cyr + cz - xp)
        love.graphics.line(cxr + cz - xp, cyr + xp, cxr + xp, cyr + cz - xp)
        love.graphics.setLineWidth(1)
        self._continue_rect = { x = cxr, y = cyr, w = cz, h = cz }
        if hovx then TooltipSvc.set("Close catalog", mx, my) end
    end

    -- Page-turn hint under an open spread.
    if idx ~= 0 and idx ~= max_spread then
        love.graphics.setFont(fonts.sm)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
        love.graphics.printf("scroll wheel or grab a corner to turn pages",
            book_l, book_b + fl(6 * s), book_r - book_l, "center")
    end

    TooltipSvc.draw(fonts)
end

return CatalogModal
