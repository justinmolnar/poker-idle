-- views/CatalogModal.lua
--
-- Post-bust catalog. Replaces the old always-visible left-panel tab —
-- catalog purchases now happen here, after the shove result has been read and
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

local Anchors        = require("services.AnchorRegistry")
local Theme        = require("views.Theme")
local Constants    = require("data.constants")
local Catalog      = require("data.catalog")
local CatalogPages = require("data.catalog_pages")
local LabelButton  = require("views.widgets.LabelButton")
local Sticker      = require("views.widgets.Sticker")
local Stamp        = require("views.widgets.Stamp")
local Pop          = require("services.Pop")
local Icons        = require("views.Icons")
local IconText     = require("views.IconText")
local Format       = require("utils.format")
local Decal        = require("services.Decal")
local TooltipSvc     = require("services.Tooltip")
local ShaderRegistry = require("services.ShaderRegistry")

-- Stable "No. NNN" code per item = its position in the master catalog, so the
-- serial on a card doesn't shuffle as pages filter items in and out.
local CATALOG_ORD = {}
for i, it in ipairs(Catalog) do CATALOG_ORD[it.id] = i end

local SLIDE_IN_SECS = 0.45

local CatalogModal = {}
CatalogModal.__index = CatalogModal

-- ─── Layout constants ──────────────────────────────────────────────────

-- Base "design" sizes — scaled by ui_scale at draw time so the book grows
-- with the window (a 4K screen shouldn't show a tiny card grid in a void).
local MODAL_W_BASE      = 980

-- Live value; CARD_H is recomputed each :draw against the ui-scaled fonts.
local CARD_H            = 84

-- Slot-units per leaf. An item costs 1 unless it declares `slots` (the
-- cursor hero is 3, filling a leaf on its own). Both the department packer
-- in :_pages and the card loop in drawLeaf budget against this.
local LEAF_SLOTS        = 3


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
        -- Post-shove arrival: the closed book rises from the bottom of the
        -- felt to its resting spot, beside the result it is the consequence
        -- of. Mid-grind (the top-bar button) it simply appears, as before.
        slide_in  = opts.slide_in == true,
        _enter_t  = (opts.slide_in == true) and 0 or 1,
        -- Full-screen dim behind the book. Off for the post-shove arrival so
        -- the felt result stays readable next to it; on by default so the
        -- mid-grind catalog is unchanged.
        scrim     = opts.scrim ~= false,
        -- Cached cell rects (built each :draw, consumed by :consumeMouse)
        _cells   = {},
        -- Peelable sticker rects (same lifecycle as _cells), and the drag in
        -- progress: { id, x0, w, amount }.
        _stickers = {},
        _peel     = nil,
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

-- Has the player pulled this item's sticker off? (models/GameState.peeled_items)
local function isPeeled(state, item_id)
    for _, id in ipairs(state.peeled_items or {}) do
        if id == item_id then return true end
    end
    return false
end

-- Counter formatters for the sticker, picked by the condition's `format`
-- field. Table lookup, never a branch on the unlock kind — a new format is
-- one entry here plus one field in data/catalog.lua.
local COUNTER_FORMAT = {
    count = function(n) return Format.formatBig(n) end,
    money = function(n) return Format.money(n) end,
}

-- Headlines on the locked-item sticker: still counting down, vs. earned and
-- waiting to be pulled off.
local STICKER_TITLE = "COMING SOON!"
local STICKER_READY = "PEEL TO OPEN"

-- How far right the sticker has to be dragged (as a fraction of its own
-- width) before letting go actually removes it. Under this it springs back.
local PEEL_COMMIT   = 0.55

-- Stamp slam. Long enough to read as a physical impact, short enough that it
-- is over before you look away.
local STAMP_IMPACT_SECS = 0.22

-- Trim a plain string (no icon markers) to a pixel width, measured with the
-- real font rather than an assumed character width — the card layout has to
-- hold at every ui_scale, and "Thin Sans" is not monospaced.
local function clampText(str, font, avail)
    str = str or ""
    if avail <= 0 or str == "" or font:getWidth(str) <= avail then return str end
    while #str > 1 and font:getWidth(str .. "...") > avail do
        str = str:sub(1, #str - 1)
    end
    return str .. "..."
end

-- "2 / 3" for a gated item, or nil when the condition is a flag (no ratio to
-- report — see services/UnlockRegistry:progress).
local function unlockCounter(cond, current, target)
    if not (current and target) then return nil end
    local fmt = COUNTER_FORMAT[cond and cond.format or "count"] or COUNTER_FORMAT.count
    return fmt(current) .. " / " .. fmt(target)
end

-- ─── Page model ───────────────────────────────────────────────────────

-- Build the ordered list of leaves (pages) from the authored DEPARTMENTS in
-- data/catalog_pages.lua, filtered by the same visibility rules as the flat
-- list: hidden/handicap phantoms, prerequisite-hidden items, and act-3-gated
-- items drop out.
--
-- A DEPARTMENT IS NOT A PAGE. It's a group of mechanically-related items of
-- any size, and this function is what turns departments into pages: each
-- one's visible items are packed into leaves of LEAF_SLOTS units, so a
-- nine-item department simply runs for three leaves under one heading. The
-- previous model forced one department per leaf, which is why the book ended
-- up with seventeen headings for forty-nine items.
--
-- Continuation leaves get " cont." appended so a repeated heading doesn't
-- read as a rendering bug. A department whose items are all invisible
-- produces no leaves. Any visible item not named in a department lands in a
-- trailing "&c." catch-all so nothing is ever unreachable.
-- Returns { {title=, items={item,...}}, ... }, owned.
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

    local pages = {}

    -- Spread a department's items over the fewest leaves that hold them,
    -- balanced rather than greedy. Greedy packing fills 3/3/3/1 and leaves a
    -- near-empty last page; targeting `remaining units / remaining leaves`
    -- gives 3/3/2/2, so no leaf looks like an afterthought.
    --
    -- Only the FIRST leaf of a department carries the heading. The rest pass
    -- title = nil and draw a bare header band, because a department running
    -- for three pages is what a catalog looks like — repeating the name on
    -- every page (or worse, "cont.") is noise.
    local function addLeaves(title, list)
        local units = 0
        for _, it in ipairs(list) do units = units + math.min(it.slots or 1, LEAF_SLOTS) end
        if units == 0 then return end
        local leaves_left = math.ceil(units / LEAF_SLOTS)

        local leaf, used, emitted = {}, 0, 0
        local target = math.ceil(units / leaves_left)
        local function flush()
            if #leaf == 0 then return end
            emitted = emitted + 1
            pages[#pages + 1] = { title = (emitted == 1) and title or nil, items = leaf }
            units       = units - used
            leaves_left = math.max(1, leaves_left - 1)
            target      = math.ceil(units / leaves_left)
            leaf, used  = {}, 0
        end
        for _, it in ipairs(list) do
            local sp = math.min(it.slots or 1, LEAF_SLOTS)
            -- Break when this item would exceed the leaf's fair share, but
            -- never break a leaf that can still physically fit the item and
            -- is still empty.
            if #leaf > 0 and (used + sp > LEAF_SLOTS or used + sp > target) then flush() end
            leaf[#leaf + 1] = it
            used = used + sp
        end
        flush()
    end

    local placed = {}
    for _, dept in ipairs(CatalogPages) do
        local list = {}
        for _, id in ipairs(dept.items) do
            local it = byId[id]
            placed[id] = true                       -- authored → never a leftover
            if it and visible(it) then list[#list + 1] = it end
        end
        addLeaves(dept.title, list)
    end

    -- Catch-all for any visible item the author forgot to place.
    local orphans = {}
    for _, it in ipairs(Catalog) do
        if not placed[it.id] and visible(it) then orphans[#orphans + 1] = it end
    end
    addLeaves("&c.", orphans)

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

-- Advance an in-progress peel from the live mouse position, and finish it when
-- the button comes up. Polled from :draw rather than driven by mousereleased
-- because ShoveState has no mousereleased handler and GrindState deliberately
-- swallows it while a modal is open; the modal already polls the mouse for
-- hover, so this keeps the input in one place instead of threading a new
-- callback through two states.
function CatalogModal:_updatePeel()
    local p = self._peel
    if not p then return end
    local mx = love.mouse.getPosition()

    if love.mouse.isDown(1) then
        -- Drag right to peel. Travel is measured against the sticker's own
        -- width so a small label peels in a short pull.
        local travel = (mx - p.x0) / math.max(1, p.w * 0.85)
        p.amount = math.max(0, math.min(1, travel))
        return
    end

    -- Released. Past the commit point it comes off for good; short of it the
    -- label falls back onto the paper.
    if (p.amount or 0) >= PEEL_COMMIT then
        if self.game.grind and self.game.grind.peelCatalogSticker then
            self.game.grind:peelCatalogSticker(p.id)
        end
    end
    self._peel = nil
end

-- Returns true if the click landed on a button or a buyable card.
function CatalogModal:consumeMouse(mx, my, button)
    -- Nothing is where it looks like it is until the book has landed.
    if self._enter_t < 1 then return false end
    if button ~= 1 then return false end

    -- A peelable sticker takes the click before the card underneath it does —
    -- it is physically on top, and the item is not buyable through it anyway.
    for _, st in ipairs(self._stickers) do
        if mx >= st.x and mx < st.x + st.w and my >= st.y and my < st.y + st.h then
            self._peel = { id = st.id, x0 = mx, w = st.w, amount = 0 }
            return true
        end
    end

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
    -- Three separate facts, deliberately not one:
    --   met        — the unlock condition is satisfied
    --   peeled     — the player has pulled the sticker off
    --   sticker_on — the sticker is still physically covering the ad
    -- Meeting the condition does NOT clear the sticker. It fills, and then it
    -- sits there being peelable until someone peels it, so the reveal is an
    -- act rather than something that quietly happened between sessions.
    local has_gate   = item.unlock ~= nil
    local met        = (not has_gate) or catalogUnlocked(self.game, item, state)
    local peeled     = (not has_gate) or isPeeled(state, item.id)
    local sticker_on = (not is_owned) and has_gate and ((not met) or (not peeled))
    local unlock_locked = sticker_on
    local locked     = (item.requires and not owned[item.requires]) or sticker_on
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

    -- A locked ad sits on darker paper than the rest of the page, the way a
    -- catalog greys out a line it can't sell you. Drawn under everything else
    -- so the whole card reads unavailable before you read a word of it.
    if unlock_locked then
        Theme.setColor({ 0.15, 0.15, 0.12, 0.10 })
        love.graphics.rectangle("fill", x, y, w, h)
    end

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
        -- Thumb grows with the card, so a 2-slot feature ad gets real art
        -- instead of a small thumb marooned in white space. A 1-slot card
        -- clamps to the same 56px it always was.
        local box = math.max(fl(56 * s), math.min(h - fl(28 * s), fl(150 * s)))
        img_w = box
        img_h = box
        img_x = x + fl(8 * s)
        img_y = y + fl(14 * s)
    end

    Theme.setColor({ 0.15, 0.15, 0.12, 0.08 })
    love.graphics.rectangle("fill", img_x, img_y, img_w, img_h)
    Theme.setColor({ 0.15, 0.15, 0.12, 0.35 })
    love.graphics.rectangle("line", img_x, img_y, img_w, img_h)

    -- Resolve item animation & shader settings (paper magazine catalog defaults to static unless overridden in item data)
    local anim_spec = item.anim or {}
    local catalog_animated = false
    if anim_spec.catalog_enabled ~= nil then
        catalog_animated = anim_spec.catalog_enabled
    elseif item.anim_catalog ~= nil then
        catalog_animated = item.anim_catalog
    end

    local time_arg  = catalog_animated and love.timer.getTime() or false
    local fps_arg   = anim_spec.fps or item.fps
    local frame_arg = anim_spec.frame or item.frame or item.static_frame

    local shader_name   = anim_spec.shader or item.shader
    local shader_params = anim_spec.shader_params or item.shader_params

    -- Draw sprite (if exists)
    local sprite = self.game.sprite_loader:getSprite(item.sprite or item.id, time_arg, fps_arg, frame_arg)
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

        if shader_name and ShaderRegistry and ShaderRegistry.apply then
            ShaderRegistry.apply(shader_name, shader_params)
        end

        love.graphics.draw(sprite, px, py, 0, scale_factor, scale_factor)

        if shader_name and ShaderRegistry and ShaderRegistry.apply then
            ShaderRegistry.apply(nil)
        end
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
        -- Show the real price rather than "LCK": you can't order it yet, but
        -- knowing what it costs is how you decide whether to save. The stamp
        -- stays black instead of the red orderable ink, and the red
        -- requirement line carries the "not yet" message.
        cost_text = ((item.cost_chip or 0) <= 0) and "FREE" or cost_text
    elseif (item.cost_chip or 0) <= 0 then
        cost_text = "FREE"
    end
    local tw_c = fonts.sm:getWidth(cost_text)
    love.graphics.print(cost_text, cx_stamp - tw_c * 0.5, cy_stamp - fonts.sm:getHeight() * 0.5)

    local dim = (is_owned and not is_corruptible and not is_corrupted)
    local ink = dim and { 0.15, 0.15, 0.12, 0.40 } or { 0.15, 0.15, 0.12 }
    -- An unlock-gated item is dimmed like an owned one — it is not orderable
    -- either way. The requirement itself lives on the sticker, not in the
    -- text column.
    local name_ink = unlock_locked and { 0.15, 0.15, 0.12, 0.45 } or ink

    -- Sticker rect is computed BEFORE any text is drawn, because the text
    -- column has to know where the sticker starts in order to stay out from
    -- under it. Guessing a reserve from a character-width estimate is how you
    -- get a name running beneath a sticker at one font scale and not another.
    local st_x, st_y, st_w, st_h, st_angle
    local st_line, st_counter, st_frac
    if unlock_locked then
        local reg = self.game.unlock_rules
        local cur, target
        st_frac = 0
        if reg then st_frac, cur, target = reg:progress(item.unlock, state) end
        st_line    = (item.unlock and item.unlock.text) or ""
        st_counter = unlockCounter(item.unlock, cur, target)

        st_h = Sticker.heightFor(fonts, s, true)
        -- Sized to its own text, then clamped to the band. A sticker stretched
        -- across the whole card is 80% blank paper and its fill stops meaning
        -- anything.
        local want_w = Sticker.widthFor(fonts, s, STICKER_TITLE, st_line, st_counter)
        if hero then
            st_w = math.min(w * 0.62, want_w)
            st_x = x + (w - st_w) * 0.5
            st_y = y + h - st_h - fl(18 * s)
        else
            -- BELOW the name, not beside it. Beside it, the sticker and the
            -- item name fight over the same 200px and the name loses
            -- ("CHROME TOAS..."). In the band under the name there is nothing
            -- to compete with, the price badge is well above it, and the
            -- sticker gets to be wide enough to read at a glance.
            -- Applied by hand: land anywhere in the free space rather than
            -- jittering a few pixels around one anchor, which just reads as
            -- "always the same place". Left bound clears the illustration,
            -- right bound is the card edge less the sticker's own width.
            st_w = math.min((x + w - fl(12 * s)) - (img_x + img_w + fl(12 * s)), want_w)
            st_x = Decal.lerp("cs_x:" .. item.id, 1,
                              img_x + img_w + fl(10 * s),
                              x + w - fl(10 * s) - st_w)
            st_y = Decal.lerp("cs_y:" .. item.id, 2,
                              y + fl(3 * s),
                              y + h - st_h - fl(3 * s))
        end
        -- Stickers get pressed on straighter than a stamp gets banged down,
        -- but still both ways.
        local _, _, angle = Decal.place("coming_soon:" .. item.id, { angle = 0.10 })
        st_angle = angle
    end

    -- Precompute the shove stat (registry-dispatched, no kind-string checks).
    local sctx = {}
    self.game.effects:applyAll(item, sctx)
    local shove = sctx.shove_rate or 0
    -- One decimal, not zero. Band A runs 0.005..0.018, which whole-percent
    -- rounding flattened into "+1%" for five different price tiers -- the
    -- stat was on screen and still could not be compared.
    local shove_txt = shove > 0 and string.format("+%.1f%% shove", shove * 100) or nil
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
        Theme.setColor(name_ink)
        local nm = (item.name or "?"):upper()
        love.graphics.print(nm, cxm - fonts.md:getWidth(nm) * 0.5, ty)
        ty = ty + fonts.md:getHeight() + 4

        -- Locked: no effect line and no shove stat. The requirement rides on
        -- the COMING SOON sticker instead (drawn last, below); the flavor
        -- blurb still prints, so a locked hero card says what the object is
        -- and how to earn it, never what it does.
        if not unlock_locked then
            local line = (is_corrupted and item.corrupt.effect_text or item.effect_text) or ""
            local lw = IconText.measure(line, fonts.sm)
            IconText.draw(self.game, line, cxm - lw * 0.5, ty, fonts.sm, ink)
            ty = ty + fonts.sm:getHeight() + 4
        end

        local desc_txt = item.description or ""
        if desc_txt ~= "" then
            love.graphics.setFont(fonts.sm)
            Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
            love.graphics.print(desc_txt, cxm - fonts.sm:getWidth(desc_txt) * 0.5, ty)
            ty = ty + fonts.sm:getHeight() + 4
        end

        if shove_txt and not unlock_locked then
            love.graphics.setFont(fonts.sm)
            Theme.setColor(shove_ink)
            love.graphics.print(shove_txt, cxm - fonts.sm:getWidth(shove_txt) * 0.5, ty)
        end
    else
        -- Item Header info: Number code + Name. On a multi-slot feature ad
        -- the text block centres against the taller art; a 1-slot card is
        -- shorter than the threshold so it stays top-aligned as before.
        local text_x = img_x + img_w + fl(12 * s)
        local block_h = fonts.md:getHeight() + 3 * fonts.sm:getHeight() + fl(6 * s)
        local title_y
        if unlock_locked then
            -- Locked copy hugs the top; the sticker takes the bottom and is
            -- allowed to run into this band if its text needs the room.
            title_y = y + fl(4 * s)
        elseif h > block_h + fl(24 * s) then
            title_y = y + fl((h - block_h) * 0.5)
        else
            title_y = y + fl(8 * s)
        end

        -- The sticker sits BELOW this column now, so the name gets the full
        -- width and only has to clear the price badge in the corner.
        local col_w = (x + w - fl(44 * s)) - text_x

        local index_text = string.format("No. %03d", index or 0)
        Theme.setColor({ 0.15, 0.15, 0.12, 0.60 })
        love.graphics.setFont(fonts.sm)
        love.graphics.print(index_text, text_x, title_y)

        local name_y = title_y + fonts.sm:getHeight() + 1
        Theme.setColor(name_ink)
        love.graphics.setFont(fonts.md)
        love.graphics.print(clampText((item.name or "?"):upper(), fonts.md, col_w),
                            text_x, name_y)

        -- Locked cards say what the object IS and how to earn it, never what it
        -- does: the effect line and the shove stat are withheld, and the
        -- requirement moves onto the COMING SOON sticker (drawn last, below).
        -- The flavor blurb slides up into the vacated effect slot so the text
        -- column has no hole in it.
        local effect_y = name_y + fonts.md:getHeight() + 3
        local flavor_y = effect_y
        if not unlock_locked then
            local line = (is_corrupted and item.corrupt.effect_text or item.effect_text) or ""
            IconText.draw(self.game, line, text_x, effect_y, fonts.sm, ink)
            flavor_y = effect_y + fonts.sm:getHeight() + 2
        end

        -- Flavor always prints, locked or not. It used to be suppressed when
        -- the sticker would have covered it, but the sticker now lands
        -- wherever it lands, so that test made the blurb blink in and out
        -- depending on where a hash put a label. A sticker covering some
        -- flavor text is exactly what a sticker on a catalog does.
        Theme.setColor({ 0.15, 0.15, 0.12, 0.45 })
        love.graphics.setFont(fonts.sm)
        love.graphics.print(clampText(item.description, fonts.sm, col_w), text_x, flavor_y)

        -- Shove contribution: its own right-aligned stat on the flavor line.
        -- Makes "buying builds your shove base" legible — every buyable
        -- item advertises how much % it adds. Withheld while locked.
        if shove_txt and not unlock_locked then
            Theme.setColor(shove_ink)
            love.graphics.setFont(fonts.sm)
            love.graphics.print(shove_txt, x + w - fl(12 * s) - fonts.sm:getWidth(shove_txt), flavor_y)
        end
    end

    -- COMING SOON sticker. Drawn after the card's own contents so it sits ON
    -- the ad the way a real sticker does, and it carries the whole "not yet"
    -- message: the requirement, the raw count, and a stock that fills as you
    -- close the gap. Everything before this is deliberately quiet about the
    -- lock (darker paper, dimmed name) — the sticker is the loud part.
    if sticker_on then
        -- A met-but-unpeeled sticker is the one you can grab. Record its rect
        -- so :consumeMouse can hit-test it, and read back how far the current
        -- drag has pulled it.
        local peel = 0
        if met then
            if not self.flip_t then
                self._stickers[#self._stickers + 1] = {
                    x = st_x, y = st_y, w = st_w, h = st_h, id = item.id,
                }
            end
            if self._peel and self._peel.id == item.id then
                peel = self._peel.amount or 0
            end
        end

        -- First sticker on the page is what a "stickers show progress" hint
        -- points at. Registered before the draw, off the rect the draw uses,
        -- and only when not mid-flip (same rule as the hit rects).
        if not self.flip_t and not self._anchored_sticker then
            self._anchored_sticker = true
            Anchors.set("catalog:sticker:first", st_x, st_y, st_w, st_h)
        end
        Sticker.draw{
            game     = self.game,
            fonts    = fonts,
            x = st_x, y = st_y, w = st_w, h = st_h,
            scale    = s,
            rotation = st_angle,
            peel     = peel,
            -- Once the condition is met the sticker stops counting down and
            -- starts asking to be removed.
            title    = met and STICKER_READY or STICKER_TITLE,
            line     = st_line,
            counter  = st_counter,
            progress = st_frac,
            -- Promo-sticker palette, passed in from the call site: the
            -- widget itself holds no literal colors. Cream base; the EARNED
            -- fraction is the saturated ink. Progress fills light → loud.
            -- Filler flips amber→green the moment it can be peeled, so the
            -- state change is visible from across the room.
            stock_token = { 1.00, 1.00, 1.00 },
            panel_token = { 1.00, 0.97, 0.88 },
            fill_token  = met and { 0.20, 0.58, 0.28 } or { 0.88, 0.62, 0.10 },
            vinyl_token = { 1.00, 0.97, 0.88 },
            ink_token   = { 0.15, 0.15, 0.12 },
            edge_token  = { 0.15, 0.15, 0.12, 0.45 },
        }
    end

    -- Stash cell bounds for hit-testing. Skipped mid-flip: leaves are drawn
    -- under a scale transform then, so the logical rect wouldn't match what's
    -- on screen — and clicks shouldn't land during a page turn anyway.
    if not self.flip_t then
        self._cells[#self._cells + 1] = {
            x = x, y = y, w = w, h = h, item = item, buyable = buyable, corruptible = corruptible,
        }
        -- Hint targets: the first card's price stamp, and the first
        -- corruptible card. "first" is per draw pass; the flags reset at
        -- the top of :draw.
        if not self._anchored_price then
            self._anchored_price = true
            Anchors.set("catalog:price:first",
                        cx_stamp - r_stamp, cy_stamp - r_stamp, r_stamp * 2, r_stamp * 2)
        end
        if corruptible and not self._anchored_corrupt then
            self._anchored_corrupt = true
            Anchors.set("catalog:corrupt:first", x, y, w, h)
        end
    end

    -- Rubber stamps. One stamp per card at most, so this is a chain of
    -- conditions picking WHICH, then a single shared draw — these were five
    -- copies of the same twelve lines with different labels.
    -- hw/hh/r are the ORIGINAL hand-tuned box dimensions per stamp, kept
    -- verbatim: sizing the box to its label instead changed how they look,
    -- which was never the ask.
    local stamp
    if is_corrupted then
        stamp = { label = "CORRUPTED", color = { 0.45, 0.15, 0.70, 0.90 },
                  font = fonts.md, lw = 3,
                  hw = 60, hh = 14, r = 4 }
    elseif is_corruptible then
        stamp = { label = "CORRUPT?", color = { 0.55, 0.25, 0.85, 0.85 },
                  font = fonts.sm, lw = 2,
                  hw = 50, hh = 12, r = 3 }
    elseif is_owned then
        stamp = { label = "ORDERED", color = { 0.75, 0.20, 0.20, 0.85 },
                  font = fonts.md, lw = 3,
                  hw = 55, hh = 14, r = 4 }
    elseif locked and not unlock_locked then
        -- SOLD OUT is only honest for a PREREQUISITE lock (you can't order
        -- the Engraved Plaque without the Plastic Trophy). An unlock-gated
        -- item gets no stamp; it wears the COMING SOON sticker instead, and
        -- "SOLD OUT" over an item that is merely not-yet-earned is a second,
        -- contradictory story about the same card.
        stamp = { label = "SOLD OUT", color = { 0.45, 0.45, 0.45, 0.70 },
                  font = fonts.md, lw = 2,
                  hw = 60, hh = 12, r = 3 }
    elseif forcing_tutorial and item.id ~= "poker_poster" then
        stamp = { label = "WAIT POSTER", color = { 0.55, 0.55, 0.55, 0.60 },
                  font = fonts.sm, lw = 1.5,
                  hw = 55, hh = 12, r = 3 }
    end

    -- Watched EVERY frame, stamped or not: Pop.onChange ignores first sight, so
    -- if this only ran while a stamp existed then a freshly-bought item's
    -- ORDERED would be its own first sighting and would never slam. Tracking
    -- "none" while unstamped makes the purchase a real transition.
    local impact = Pop.onChange("stamp:" .. item.id,
                                stamp and stamp.label or "none", STAMP_IMPACT_SECS)

    if stamp then
        -- Hand-stamped: anywhere across the middle of the card, not a fixed
        -- anchor with a few pixels of wobble. Keyed off the item id, so it is
        -- stable forever but no two cards on a page match.
        local hw, hh = fl(stamp.hw * s), fl(stamp.hh * s)
        local cx = Decal.lerp("stamp_x:" .. item.id, 1,
                              x + hw + fl(10 * s), x + w - hw - fl(10 * s))
        local cy = Decal.lerp("stamp_y:" .. item.id, 2,
                              y + hh + fl(6 * s), y + h - hh - fl(6 * s))
        -- Wide and centred on zero, so stamps lean BOTH ways. A narrow range
        -- around a per-stamp base angle made every ORDERED on the page tilt
        -- the same direction by the same amount, which reads as "all the
        -- same angle" no matter how random the number technically was.
        local _, _, angle = Decal.place("stamp:" .. item.id, { angle = 0.30 })

        Stamp.draw{
            x = cx, y = cy, hw = hw, hh = hh,
            label       = stamp.label,
            fonts       = fonts,
            font        = stamp.font,
            color_token = stamp.color,
            angle       = angle,
            radius      = fl(stamp.r * s),
            line_width  = stamp.lw,
            impact      = impact,
        }
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
    -- Department heading — turns WITH the leaf. Only the first leaf of a
    -- department has one (see :_pages); continuation leaves keep the header
    -- band for the ledger and the rule, but print no name.
    if page.title then
        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.md)
        love.graphics.print(page.title:upper(), x + pad, y + fl(10 * s))
    end
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

    -- Lay the cards out top-down, dividing the leaf's full card area between
    -- them in proportion to each item's slot cost. The leaf always fills:
    -- three 1-slot cards come out exactly card_h each (unchanged), while a
    -- leaf holding one 2-slot feature ad gives it the whole page instead of
    -- leaving a third of the paper blank.
    local cw    = w - 2 * pad
    local gapc  = fl(10 * s)
    local cy    = y + head_h + fl(8 * s)
    local avail = LEAF_SLOTS * card_h + (LEAF_SLOTS - 1) * gapc

    local units, shown = 0, {}
    for _, item in ipairs(page.items) do
        local sp = math.min(item.slots or 1, LEAF_SLOTS)
        if units + sp > LEAF_SLOTS then break end   -- guard; :_pages pre-fits
        units = units + sp
        shown[#shown + 1] = { item = item, sp = sp }
    end
    if units <= 0 then units = 1 end

    local card_area = avail - gapc * math.max(0, #shown - 1)
    for _, e in ipairs(shown) do
        local ch = fl(card_area * e.sp / units)
        drawItemCard(self, e.item, owned, state, x + pad, cy, cw, ch, fonts, forcing,
            CATALOG_ORD[e.item.id] or 0, e.sp >= 3)
        cy = cy + ch + gapc
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

    -- First-visit lede. The flag has been plumbed from ShoveState since the
    -- callout was specced and nothing ever read it, so the band never drew.
    -- It lives on the cover rather than over a page: this is the one moment
    -- the player has not opened the book yet, and it is what the book is for.
    if self.intro_callout then
        local band_h = fl(30 * s)
        -- Below CATALOG & ORDER BOOK (drawn at 0.74), above GRAB CORNER (0.88).
        local by     = y + h * 0.81
        Theme.setColor({ 0.15, 0.15, 0.12, 0.10 })
        love.graphics.rectangle("fill", x + fl(18 * s), by,
                                w - fl(36 * s), band_h, Theme.space.radius)
        Theme.setColor({ 0.15, 0.15, 0.12 })
        love.graphics.setFont(fonts.sm)
        love.graphics.printf("Make your cell a home. Everything here is permanent.",
                             x + fl(18 * s),
                             by + fl((band_h - fonts.sm:getHeight()) * 0.5),
                             w - fl(36 * s), "center")
    end
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
        Anchors.set("catalog:continue", btn_x, btn_y, btn_w, btn_h)
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
    -- "first sticker / price / corruptible" hint anchors are per draw pass.
    self._anchored_sticker, self._anchored_price, self._anchored_corrupt = nil, nil, nil
    local fonts = self.game.fonts
    local state = self.game.state
    local fl = math.floor

    -- Page-flip timer.
    local dt = love.timer.getDelta()
    if self._enter_t < 1 then
        self._enter_t = math.min(1, self._enter_t + dt / SLIDE_IN_SECS)
    end
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
    local page_h = fl(head_h + fl(8 * s) + LEAF_SLOTS * card_h
                      + (LEAF_SLOTS - 1) * fl(10 * s) + fonts.sm:getHeight() + fl(22 * s))
    local cx     = W * 0.5
    local top    = fl((H - page_h) * 0.5)
    -- The slide: ease-out cubic from below the screen to the resting `top`.
    -- Every hit rect below derives from `top` in this same pass, so they
    -- track the book as it moves with no extra bookkeeping.
    if self._enter_t < 1 then
        local e = 1 - (1 - self._enter_t) ^ 3
        top = top + fl((H - top) * (1 - e))
    end

    -- Dim backdrop only — no hard frame to morph.
    if self.scrim then
        Theme.setColor(Theme.debug.hud_bg)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end

    -- Advance any in-progress peel BEFORE the cards draw, using last frame's
    -- sticker rects, so the label renders at the pull the mouse is actually at.
    self:_updatePeel()

    self._cells = {}
    self._stickers = {}
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
    -- The book as one rect, for a "this is the catalog" hint.
    if not self.flip_t then
        Anchors.set("catalog:book", book_l, top, book_r - book_l, page_h)
    end
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
        Anchors.set("catalog:continue", cxr, cyr, cz, cz)
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
