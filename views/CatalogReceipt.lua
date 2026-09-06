-- views/CatalogReceipt.lua
--
-- The MANIFEST: a thermal-receipt strip of everything the player has
-- bought, tucked behind the catalog book's left page. Its edge pokes out
-- on every view (cover, spreads, back cover); clicking the stub pulls it
-- out on top of the book, clicking anywhere else tucks it back. Rows are
-- the purchases in purchase order (state.owned_items is append-ordered):
-- sprite thumb, name, dotted leader, price. Hovering a row shows the
-- item's effect through the shared Tooltip. Corrupted purchases print a
-- purple annotation line. The footer totals the run of paper and the
-- bottom edge is torn.
--
-- When something is bought while the book is open, the printer feeds:
-- the stub thrusts out with a chatter (collapsed) or the newest row
-- slides in off the torn edge (expanded). Purchase detection is the same
-- Pop.onChange polling the ORDERED stamp uses — no events, no wiring.
--
-- Owned by CatalogModal: one instance per modal, drawn twice per pass
-- ("behind" before the leaves, "front" after the corner controls), input
-- routed through :consumeMouse / :wheelmoved ahead of the book's own
-- targets. Reads state, never mutates it.
--
-- The room screen owns one too and draws the same paper flat on its right
-- side (drawStandalone): one manifest, two places it is read.
--
-- Palette matches the book's hardcoded paper/ink, deliberately not Theme
-- tokens — this is the same printed matter the catalog is.

local Theme        = require("views.Theme")
local Catalog      = require("data.catalog")
local Icons        = require("views.Icons")
local IconText     = require("views.IconText")
local Pop          = require("services.Pop")
local RollingValue = require("services.RollingValue")
local Decal        = require("services.Decal")
local TooltipSvc   = require("services.Tooltip")

local Motion       = require("services.Motion")
local ShaderRegistry = require("services.ShaderRegistry")
local CatalogReceipt = {}
CatalogReceipt.__index = CatalogReceipt

local PAPER   = { 0.96, 0.93, 0.87 }   -- a shade whiter than the book page
local INK     = { 0.15, 0.15, 0.12 }
local RED     = { 0.75, 0.20, 0.20 }
local PURPLE  = { 0.45, 0.15, 0.70 }

local SLIDE_RATE  = 10     -- RollingValue rate for the pull-out
local PRINT_SECS  = 0.5    -- the feed impact, a touch longer than the stamp
local PEEK_BASE   = 44     -- visible stub width, pre-scale
local PAPER_W_BASE = 196

function CatalogReceipt:new(game)
    local by_id = {}
    for _, it in ipairs(Catalog) do by_id[it.id] = it end
    -- RollingValue keys are module-global; seed them closed so a receipt
    -- left open in a previous modal doesn't ease shut across this one,
    -- and let the tuck edge snap to wherever this book's cover is.
    RollingValue.set("catalog:receipt:slide", 0)
    RollingValue.reset("catalog:receipt:tuckx")
    return setmetatable({
        game   = game,
        by_id  = by_id,
        open   = false,
        scroll = 0,       -- px scrolled up from the bottom-pinned view
        _max_scroll = 0,
        _stub_rect  = nil,   -- collapsed hit target (built by "behind")
        _paper_rect = nil,   -- expanded hit target (built by "front")
    }, CatalogReceipt)
end

function CatalogReceipt:isOpen() return self.open end

-- The room's view, for each item's layout entry (RoomState owns it and
-- registers after this is built, so it is looked up when drawing; a
-- harness without one draws the catalog's own look).
function CatalogReceipt:_roomView()
    local sm   = self.game.state_machine
    local room = sm and sm.states and sm.states.room
    return room and room.getRoomView and room:getRoomView() or nil
end
function CatalogReceipt:close()  self.open = false end

-- Click routing, ahead of the book's own targets. Returns true when the
-- click was the receipt's: the stub (pull out), the open paper (inert —
-- rows are hover-only), or anywhere else while open (tuck back; consumed
-- so the host's close-on-unconsumed-click can't eat the whole catalog).
function CatalogReceipt:consumeMouse(mx, my)
    local function inside(r)
        return r and mx >= r.x and mx < r.x + r.w
                 and my >= r.y and my < r.y + r.h
    end
    if self.open then
        if inside(self._paper_rect) then return true end
        self.open = false
        return true
    end
    if inside(self._stub_rect) then
        self.open = true
        return true
    end
    return false
end

-- Wheel scrolls the paper only while it is out; the host keeps page
-- flipping otherwise. dy > 0 (wheel up) climbs into older purchases.
function CatalogReceipt:wheelmoved(dy)
    if not (dy and dy ~= 0) then return end
    local step = math.floor(24 * ((self.game.ui_scale or 1)))
    self.scroll = math.max(0, math.min(self._max_scroll or 0,
                                       self.scroll + dy * step))
end

-- ── Content ────────────────────────────────────────────────────────────

-- Purchases in purchase order. granted_at_start items were never bought,
-- so they never printed. Corruption is an annotation on the original
-- purchase, not a new line item.
-- Exported: the room screen's manifest prints the same rows.
function CatalogReceipt.rows(game, by_id)
    if not by_id then
        by_id = {}
        for _, it in ipairs(Catalog) do by_id[it.id] = it end
    end
    local state = game.state
    local corrupted = {}
    for _, id in ipairs(state.corrupted_items or {}) do corrupted[id] = true end
    local rows, total_chip, total_achip = {}, 0, 0
    for _, id in ipairs(state.owned_items or {}) do
        local it = by_id[id]
        if it and not it.granted_at_start then
            local corr = corrupted[id] == true
            rows[#rows + 1] = { item = it, cost = it.cost_chip or 0, corrupted = corr }
            total_chip = total_chip + (it.cost_chip or 0)
            if corr then
                total_achip = total_achip + ((it.corrupt and it.corrupt.cost_achip) or 0)
            end
        end
    end
    return rows, total_chip, total_achip
end

local function buildRows(self)
    return CatalogReceipt.rows(self.game, self.by_id)
end

-- A short-segment dashed rule (LÖVE has no dash API).
local function dashRule(x, y, w, alpha)
    Theme.setColor(INK, alpha or 0.35)
    local seg, gap = 5, 4
    local cx = x
    while cx < x + w do
        love.graphics.line(cx, y, math.min(cx + seg, x + w), y)
        cx = cx + seg + gap
    end
end

-- Tooltip custom row: icon-marked text ({chip}, tier glyphs) in a color.
-- Exported: the room's item card is the receipt's hover card.
function CatalogReceipt.iconRow(game, text, color)
    return {
        measure = function(fonts)
            return IconText.measure(text, fonts.sm), fonts.sm:getHeight()
        end,
        render = function(x, y, fonts)
            IconText.draw(game, text, x, y, fonts.sm, color)
        end,
    }
end
local iconRow = CatalogReceipt.iconRow

-- ── The card ───────────────────────────────────────────────────────────

-- Whether an item does something that FIRES (a proc), as opposed to a
-- flat effect that is simply on.
local function hasProc(item, corrupted)
    local effs = (corrupted and item.corrupt and item.corrupt.effects) or item.effects or {}
    for _, e in ipairs(effs) do
        if e.kind == "proc" then return true end
    end
    return false
end

-- An item's card, as Tooltip rows: name, effect (and the corrupt line),
-- description, and how often it has fired. The receipt's hover and the
-- room screen (hover and click) show this same card.
function CatalogReceipt.itemCard(game, item, corrupted)
    local tt = { { text = item.name or item.id, style = "md" } }
    if item.effect_text then
        tt[#tt + 1] = iconRow(game, item.effect_text, Theme.fg.primary)
    end
    if corrupted and item.corrupt and item.corrupt.effect_text then
        tt[#tt + 1] = iconRow(game, item.corrupt.effect_text, Theme.sem.corrupt)
    end
    if item.description then
        tt[#tt + 1] = { text = item.description, style = "sm" }
    end
    local state = game.state or {}
    if hasProc(item, corrupted) then
        local run  = (state.item_fires_run  or {})[item.id] or 0
        local life = (state.item_fires_life or {})[item.id] or 0
        local run_txt = (run == 0 and "Not fired yet this run")
                     or (run == 1 and "Fired once this run")
                     or ("Fired " .. run .. " times this run")
        tt[#tt + 1] = { text = run_txt .. ", " .. life .. " lifetime", style = "sm", color_token = "muted" }
    else
        tt[#tt + 1] = { text = "Always on", style = "sm", color_token = "muted" }
    end
    return tt
end

-- ── Render ─────────────────────────────────────────────────────────────

-- The paper's width at this scale (the room screen sizes its strip by it).
function CatalogReceipt.paperWidth(s)
    return math.floor(PAPER_W_BASE * s)
end

-- Row heights (written onto the rows) and the paper's natural height.
-- Returns ph_nat, head_h, foot_h, list_h.
function CatalogReceipt:_paperHeights(rows, total_achip, fonts, s)
    local fl    = math.floor
    local sm_h  = fonts.sm:getHeight()
    local row_h  = sm_h + fl(5 * s)
    local corr_h = sm_h                       -- the purple annotation line
    local list_h = 0
    for _, r in ipairs(rows) do
        r.h = row_h + (r.corrupted and corr_h or 0)
        list_h = list_h + r.h
    end
    if #rows == 0 then list_h = row_h end     -- the "nothing yet." line
    local head_h = fl(6 * s) + sm_h * 3 + fl(10 * s)          -- titles + rule
    local foot_h = fl(8 * s) + sm_h + (total_achip > 0 and sm_h or 0)
                   + sm_h + fl(12 * s)                        -- totals + NO REFUNDS
    return head_h + list_h + foot_h, head_h, foot_h, list_h
end

-- The paper itself at (x, y), pw wide, ph tall: torn edge, header, rows
-- (scissored, bottom-pinned so the latest purchase shows), scroll thumb,
-- footer. One body for the book's slip and the room screen's strip.
-- o = { fonts, s, p (the printer feed's progress), tucked, stub_hover,
-- can_hover, mx, my, placed_set (ids the room draws; the others read
-- "not placed"), highlight_id (a row lit from outside) }.
-- Leaves the row rects for rowAt; returns the hovered row or nil.
function CatalogReceipt:_drawPaper(x, y, pw, ph, rows, total_chip, total_achip, o)
    local game  = self.game
    local fonts = o.fonts
    local s     = o.s
    local fl    = math.floor
    local sm    = fonts.sm
    local sm_h  = sm:getHeight()
    local pad   = fl(10 * s)
    local p, tucked, mx, my = o.p or 0, o.tucked, o.mx, o.my
    local _, head_h, foot_h, list_h = self:_paperHeights(rows, total_achip, fonts, s)
    local teeth_h = fl(5 * s)

    -- ── Paper ──
    if not tucked then   -- a pulled-out slip floats; drop a shadow
        Theme.setColor({ 0, 0, 0, 0.35 })
        love.graphics.rectangle("fill", x + fl(4 * s), y + fl(5 * s), pw, ph + teeth_h)
    end
    Theme.setColor(PAPER)
    love.graphics.rectangle("fill", x, y, pw, ph)
    -- Torn bottom edge: paper-colored teeth past the bottom line.
    do
        local tw, yb = fl(8 * s), y + ph
        local tx = x
        while tx < x + pw do
            local t2 = math.min(tx + tw, x + pw)
            love.graphics.polygon("fill", tx, yb, (tx + t2) / 2, yb + teeth_h, t2, yb)
            tx = t2
        end
    end
    Theme.setColor(INK, 0.18)
    love.graphics.rectangle("line", x, y, pw, ph)

    -- ── Header ──
    love.graphics.setFont(sm)
    local hy = y + fl(6 * s)
    Theme.setColor(INK, 0.45)
    love.graphics.printf("THE HOUSE", x, hy, pw, "center")
    hy = hy + sm_h
    Theme.setColor(RED, 0.85)
    love.graphics.printf("MANIFEST OF PURCHASES", x, hy, pw, "center")
    hy = hy + sm_h
    Theme.setColor(INK, 0.40)
    love.graphics.printf("RUN " .. tostring((game.state.shove_count or 0) + 1),
        x, hy, pw, "center")
    hy = hy + sm_h + fl(4 * s)
    dashRule(x + pad, hy, pw - pad * 2)
    local list_y = hy + fl(6 * s)

    -- Vertical stub label while tucked, on the sliver that shows.
    if tucked then
        love.graphics.setFont(sm)
        Theme.setColor(RED, o.stub_hover and 1.0 or 0.75)
        love.graphics.print("MANIFEST", x + fl(4 * s), y + fl(46 * s), math.pi / 2)
    end

    -- ── Rows (scissored; bottom-pinned so the latest purchase shows) ──
    local list_vis = ph - head_h - foot_h
    self._max_scroll = math.max(0, list_h - list_vis)
    if self.scroll > self._max_scroll then self.scroll = self._max_scroll end
    self._list_clip = { x = x, y = list_y, w = pw, h = math.max(0, list_vis) }
    self._row_rects = {}
    local hover_row = nil

    love.graphics.setScissor(math.max(0, x - fl(20 * s)), list_y,
                             pw + fl(40 * s), math.max(0, list_vis))
    local ry = list_y - math.max(0, list_h - list_vis - self.scroll)
    if #rows == 0 then
        Theme.setColor(INK, 0.35)
        love.graphics.printf("nothing yet.", x, ry + fl(2 * s), pw, "center")
    end
    for i, r in ipairs(rows) do
        local newest = (i == #rows)
        local dy_in  = (newest and p > 0) and fl(r.h * 0.8 * p) or 0
        local alpha  = (newest and p > 0) and (1 - p * 0.6) or 1
        local yy     = ry + dy_in
        local it     = r.item
        local placed = o.placed_set == nil or o.placed_set[it.id] == true
        if not placed then alpha = alpha * 0.55 end
        self._row_rects[#self._row_rects + 1] = { y = yy, h = r.h, row = r }
        local hovered = o.can_hover and mx >= x and mx < x + pw
           and my >= math.max(yy, list_y) and my < math.min(yy + r.h, list_y + list_vis)
        if hovered then hover_row = r end
        if hovered or (o.highlight_id ~= nil and o.highlight_id == it.id) then
            Theme.setColor(INK, hovered and 0.07 or 0.05)
            love.graphics.rectangle("fill", x, yy, pw, r.h)
        end

        if yy + r.h >= list_y and yy <= list_y + list_vis then
            local ink = r.corrupted and PURPLE or INK
            -- Thumb, aspect-fit into a small square: the item exactly as the
            -- room draws it (its layout entry's frame and animation, the
            -- corruption shader), from the one resolver.
            local sq = fl(16 * s)
            local sprite, shader_name, shader_params
            if game.sprite_loader then
                local rv    = self:_roomView()
                local entry = rv and rv:layoutEntry(it.id) or nil
                sprite, shader_name, shader_params = game.sprite_loader:itemArt(it, "room", entry,
                    { corrupted = r.corrupted })
            end
            if sprite then
                local sw, sh = sprite:getWidth(), sprite:getHeight()
                local k = math.min(sq / sw, sq / sh)
                Theme.setColor({ 1, 1, 1, alpha })
                if shader_name and ShaderRegistry.apply then ShaderRegistry.apply(shader_name, shader_params) end
                love.graphics.draw(sprite,
                    fl(x + pad + (sq - sw * k) / 2),
                    fl(yy + (r.h - (r.corrupted and sm_h or 0) - sh * k) / 2), 0, k, k)
                if shader_name and ShaderRegistry.apply then ShaderRegistry.apply(nil) end
            end
            local row_h = r.h - (r.corrupted and sm_h or 0)
            -- Price, right-aligned: chip glyph + count.
            local cost_txt = tostring(r.cost)
            local cw       = sm:getWidth(cost_txt)
            local icon     = fl(10 * s)
            local cost_x   = x + pw - pad - cw
            local text_y   = yy + fl((row_h - sm_h) / 2)
            Theme.setColor(ink, 0.85 * alpha)
            love.graphics.print(cost_txt, cost_x, text_y)
            Icons.drawChip(game, cost_x - icon - fl(3 * s),
                fl(text_y + (sm_h - icon) / 2), icon, alpha)
            -- Name, clamped, then a dotted leader out to the price. An
            -- item the room has no place for says so in the leader's room.
            local name_x  = x + pad + sq + fl(6 * s)
            local lead_r  = cost_x - icon - fl(8 * s)
            local avail   = lead_r - name_x
            local name    = it.name or it.id
            while #name > 1 and sm:getWidth(name) > avail do
                name = name:sub(1, #name - 1)
            end
            Theme.setColor(ink, 0.85 * alpha)
            love.graphics.print(name, name_x, text_y)
            local lx = name_x + sm:getWidth(name) + fl(5 * s)
            if not placed then
                local mark = "not placed"
                local mw   = sm:getWidth(mark)
                if lx + mw <= lead_r then
                    Theme.setColor(INK, 0.35)
                    love.graphics.print(mark, lead_r - mw, text_y)
                    lead_r = lead_r - mw - fl(6 * s)
                end
            end
            Theme.setColor(ink, 0.25 * alpha)
            local ly = text_y + sm_h - fl(4 * s)
            while lx < lead_r do
                love.graphics.rectangle("fill", lx, ly, 1, 1)
                lx = lx + fl(4 * s)
            end
            if r.corrupted then
                Theme.setColor(PURPLE, 0.65 * alpha)
                love.graphics.print("corrupted", name_x, yy + row_h)
                local ac = (it.corrupt and it.corrupt.cost_achip) or 0
                local at = tostring(ac)
                local aw = sm:getWidth(at)
                love.graphics.print(at, x + pw - pad - aw, yy + row_h)
                Icons.drawAntiChip(game, x + pw - pad - aw - icon - fl(3 * s),
                    fl(yy + row_h + (sm_h - icon) / 2), icon, alpha)
            end
        end
        ry = ry + r.h
    end
    love.graphics.setScissor()

    -- Scroll thumb, only when there is history off-paper.
    if self._max_scroll > 0 and not tucked then
        local th = math.max(16, list_vis * (list_vis / list_h))
        local tt = 1 - (self.scroll / self._max_scroll)   -- 1 = pinned bottom
        local ty = list_y + (list_vis - th) * tt
        Theme.setColor(INK, 0.30)
        love.graphics.rectangle("fill", x + pw - fl(3 * s), ty, fl(2 * s), th, 1)
    end

    -- ── Footer ──
    local fy = y + ph - foot_h + fl(4 * s)
    dashRule(x + pad, fy, pw - pad * 2)
    fy = fy + fl(4 * s)
    love.graphics.setFont(sm)
    Theme.setColor(INK, 0.85)
    love.graphics.print(#rows .. (#rows == 1 and " ITEM" or " ITEMS"), x + pad, fy)
    do
        local tot = tostring(total_chip)
        local twd = sm:getWidth(tot)
        local icon = fl(10 * s)
        love.graphics.print(tot, x + pw - pad - twd, fy)
        Icons.drawChip(game, x + pw - pad - twd - icon - fl(3 * s),
            fl(fy + (sm_h - icon) / 2), icon)
        Theme.setColor(INK, 0.45)
        local lbl = "TOTAL"
        love.graphics.print(lbl, x + pw - pad - twd - icon - fl(8 * s)
            - sm:getWidth(lbl), fy)
    end
    fy = fy + sm_h
    if total_achip > 0 then
        Theme.setColor(PURPLE, 0.75)
        local tot = tostring(total_achip)
        local twd = sm:getWidth(tot)
        local icon = fl(10 * s)
        love.graphics.print(tot, x + pw - pad - twd, fy)
        Icons.drawAntiChip(game, x + pw - pad - twd - icon - fl(3 * s),
            fl(fy + (sm_h - icon) / 2), icon)
        fy = fy + sm_h
    end
    Theme.setColor(INK, 0.30)
    love.graphics.printf("NO REFUNDS.", x, fy, pw, "center")

    return hover_row
end

-- The row under a point, from the last draw (the paper's list area only).
function CatalogReceipt:rowAt(mx, my)
    local c = self._list_clip
    if not c then return nil end
    if not (mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h) then return nil end
    for _, rr in ipairs(self._row_rects or {}) do
        if my >= rr.y and my < rr.y + rr.h then return rr.row end
    end
    return nil
end

-- The same paper on its own: laid flat in `rect` at its natural width,
-- as tall as its content up to rect.h, no book, no stub, no tilt. The
-- room screen's manifest. o = { placed_set, highlight_id, tooltip }
-- (tooltip false: the host shows the card itself). Sets self.hover_row
-- and returns it.
function CatalogReceipt:drawStandalone(rect, o)
    o = o or {}
    local game  = self.game
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local rows, total_chip, total_achip = buildRows(self)
    -- The printer feed, as in the book: a purchase while the paper shows.
    local p = Motion.pop("paper", Pop.onChange("catalog:receipt:print", tostring(#rows), PRINT_SECS))
    local pw = CatalogReceipt.paperWidth(s)
    local ph_nat = self:_paperHeights(rows, total_achip, fonts, s)
    local ph = fl(math.min(ph_nat, rect.h - fl(5 * s)))
    local x  = fl(rect.x + (rect.w - pw) * 0.5)
    local y  = fl(rect.y)
    local mx, my = love.mouse.getPosition()
    local hover_row = self:_drawPaper(x, y, pw, ph, rows, total_chip, total_achip, {
        fonts = fonts, s = s, p = p, tucked = false, can_hover = true, mx = mx, my = my,
        placed_set = o.placed_set, highlight_id = o.highlight_id,
    })
    self._paper_rect = { x = x, y = y, w = pw, h = ph + fl(5 * s) }
    self.hover_row = hover_row
    if hover_row and o.tooltip ~= false then
        TooltipSvc.set(CatalogReceipt.itemCard(game, hover_row.item, hover_row.corrupted), mx, my)
    end
    return hover_row
end

-- Both layers funnel here. ctx = { book_l (the VISIBLE book's left edge —
-- the spine on the front cover, the spread edge otherwise), top, page_h,
-- W, H, s, fonts }. The layer split follows INTENT, not the animation:
-- pulling out draws on top from the first frame (grabbing it brings it
-- forward), tucking away drops it behind the page immediately so it
-- visibly slides INTO the book instead of finishing its travel on top
-- and then popping under.
function CatalogReceipt:draw(layer, ctx)
    local slide = RollingValue.get("catalog:receipt:slide",
                                   self.open and 1 or 0, SLIDE_RATE, "paper")
    local tucked = slide <= 0.01
    if layer == "behind" then
        if self.open then return end
        self._paper_rect = nil
    else
        if not self.open then
            if tucked then self._paper_rect = nil end
            return
        end
        self._stub_rect = nil
    end

    local game  = self.game
    local fonts = ctx.fonts
    local s     = ctx.s
    local fl    = math.floor

    local rows, total_chip, total_achip = buildRows(self)

    -- The printer feed: fires exactly on the ownership transition (first
    -- sighting is swallowed, same contract as the ORDERED stamp).
    local p = Motion.pop("paper", Pop.onChange("catalog:receipt:print", tostring(#rows), PRINT_SECS))

    -- ── Geometry ──
    local pw     = CatalogReceipt.paperWidth(s)
    local ph_nat = self:_paperHeights(rows, total_achip, fonts, s)
    local teeth_h = fl(5 * s)

    local max_h  = ctx.H - fl(20 * s) - fl(76 * s)   -- clear of the story band
    local ph_open   = math.min(ph_nat, max_h)
    -- Tucked, the paper must hide behind the book: never taller than the page.
    local ph_closed = math.min(ph_nat, ctx.page_h - fl(24 * s))

    local e = 1 - (1 - slide) ^ 3   -- ease-out cubic, same family as the book
    local ph = fl(ph_closed + (ph_open - ph_closed) * e)

    -- The tuck edge follows the VISIBLE book (the cover is only one leaf,
    -- so on the covers the paper hides behind that leaf, not behind the
    -- empty half of the spread). Eased, so opening the cover carries the
    -- tucked slip across with the page instead of teleporting it.
    local peek     = fl(PEEK_BASE * s)
    local tuck_l   = fl(RollingValue.get("catalog:receipt:tuckx", ctx.book_l, 10, "paper"))
    local x_closed = tuck_l - peek
    -- Pulled out, it lays down just left of the book (or as far as the
    -- screen allows on a full spread, overlapping the page edge a little).
    local x_open   = math.max(fl(10 * s), tuck_l - pw - fl(16 * s))
    local y_closed = ctx.top + fl(10 * s)
    local y_open   = fl(math.max(fl(16 * s), (ctx.H - fl(76 * s) - ph_open) / 2))
    local x = fl(x_closed + (x_open - x_closed) * e)
    local y = fl(y_closed + (y_open - y_closed) * e)

    -- Stub hover: the slip leans out to meet the hand, and says what it is.
    local mx, my = love.mouse.getPosition()
    local stub_hover = false
    if layer == "behind" and tucked then
        stub_hover = require("services.HoverService").rest("button",
            "manifest_stub",
            mx >= x - fl(6 * s) and mx < tuck_l
            and my >= y and my < y + ph_closed)
        if stub_hover then
            x = x - fl(7 * s)
            TooltipSvc.set("The manifest: everything you've bought", mx, my)
        end
    end

    -- Feed thrust + chatter while tucked: the stub jolts out of the book.
    if tucked and p > 0 then
        x = x - fl(16 * s * p)
        y = y + fl(math.sin(love.timer.getTime() * 50) * 2 * s * p)
    end

    -- Hand-tucked tilt, straightening as it is pulled out. Pivot at the
    -- top-right corner — the point still held by the book.
    local _, _, ang = Decal.place("catalog:manifest",
                                  { angle = 0.03, base_angle = -0.055 })
    ang = ang * (1 - e)
    local rotated = math.abs(ang) > 0.002
    if rotated then
        love.graphics.push()
        love.graphics.translate(x + pw, y)
        love.graphics.rotate(ang)
        love.graphics.translate(-(x + pw), -y)
    end

    local hover_row = self:_drawPaper(x, y, pw, ph, rows, total_chip, total_achip, {
        fonts = fonts, s = s, p = p, tucked = tucked, stub_hover = stub_hover,
        can_hover = not tucked and slide >= 0.99, mx = mx, my = my,
    })

    if rotated then love.graphics.pop() end

    -- ── Hit rects + hover tooltip ──
    if layer == "behind" then
        -- Generous AABB over the visible sliver (the tilt is small).
        self._stub_rect = { x = x - fl(6 * s), y = y - fl(6 * s),
                            w = (tuck_l - x) + fl(8 * s), h = ph + fl(12 * s) }
    else
        self._paper_rect = { x = x, y = y, w = pw, h = ph + teeth_h }
        if hover_row then
            TooltipSvc.set(CatalogReceipt.itemCard(game, hover_row.item, hover_row.corrupted), mx, my)
        end
    end
end

return CatalogReceipt
