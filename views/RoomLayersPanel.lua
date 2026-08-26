-- views/RoomLayersPanel.lua
--
-- The room editor's right-hand panel. Two tabs:
--   LAYERS  every placed item in draw order, front-most first: eye (hide
--           while working; editor only), lock, name, layer, marks (^ sits
--           on something, ! not shown under the anchors). Hover lights the
--           item in the room; click selects it (fields, homes, buttons
--           below); click again grabs it; drag reorders; ANCHORS at the
--           bottom tick things off to see the room without them.
--   LIGHT   the fixture and the selected item's emitter, stepped live over
--           data/room_lights.lua (RoomLighting reads the same table).
-- State lives on the RoomView (view.panel_tab, view.sel_placed,
-- view.hover_placed, view.layer_scroll, view.anchors_off, view.parent_pick);
-- this module only
-- draws and routes clicks. Everything it needs from the room is left by
-- RoomView:draw (view._draw_order, view._hit_rects).

local Theme          = require("views.Theme")
local LabelButton    = require("views.widgets.LabelButton")
local Lights         = require("data.room_lights")
local RoomPlacement  = require("models.room_placement")
local Scrollbar      = require("views.Scrollbar")

local Panel = {}

local PANEL_W = 300
local fl = math.floor

function Panel.rect(W, H, s)
    local top = fl(56 * s) + fl(40 * s)
    return { x = W - fl((PANEL_W + 20) * s), y = top, w = fl(PANEL_W * s), h = H - top - fl(30 * s) }
end

local function inRect(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function trim(font, text, max_w)
    if font:getWidth(text) <= max_w then return text end
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    while #chars > 1 and font:getWidth(table.concat(chars) .. "..") > max_w do chars[#chars] = nil end
    return table.concat(chars) .. ".."
end

-- ── drawing ─────────────────────────────────────────────────────────────

function Panel.draw(view, W, H)
    local game  = view.game
    local s     = game.ui_scale or 1
    local fonts = game.fonts
    local sm    = fonts.sm
    local mx, my = love.mouse.getPosition()
    local R = Panel.rect(W, H, s)
    view._panel_rect = R
    view._panel_ctls = {}
    view._layer_rows = {}
    view.hover_placed = nil
    local ctls = view._panel_ctls
    local function ctl(rect, fn) ctls[#ctls + 1] = { rect = rect, fn = fn } end

    Theme.setColor(Theme.bg.chrome, 0.96)
    love.graphics.rectangle("fill", R.x, R.y, R.w, R.h)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", R.x, R.y, R.w, R.h)

    -- tabs
    local pad = fl(8 * s)
    local tab_h = fl(24 * s)
    local tab_w = fl((R.w - pad * 3) * 0.5)
    for i, tab in ipairs{ { "layers", "LAYERS" }, { "light", "LIGHT" } } do
        local tx = R.x + pad + (i - 1) * (tab_w + pad)
        local rect = { x = tx, y = R.y + pad, w = tab_w, h = tab_h }
        local on = (view.panel_tab or "layers") == tab[1]
        LabelButton.draw{ x = rect.x, y = rect.y, w = rect.w, h = rect.h, text = tab[2], fonts = fonts, font = sm,
            hovered = inRect(rect, mx, my), fill_token = on and Theme.bg.widget_hover or Theme.bg.sunken }
        ctl(rect, function() view.panel_tab = tab[1] end)
    end
    local cy = R.y + pad + tab_h + pad

    if (view.panel_tab or "layers") == "layers" then
        Panel._drawLayers(view, R, cy, mx, my)
    else
        Panel._drawLight(view, R, cy, mx, my)
    end
end

-- A stepper row: label, value, < >. Shift steps x5.
local function stepper(view, ctl, x, y, w, label, value_str, dec, inc)
    local game  = view.game
    local s     = game.ui_scale or 1
    local sm    = game.fonts.sm
    local mx, my = love.mouse.getPosition()
    local bw = fl(18 * s)
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(sm)
    love.graphics.print(label, x, y + fl(3 * s))
    Theme.setColor(Theme.fg.heading)
    local vx = x + w - bw * 2 - fl(6 * s) - sm:getWidth(value_str) - fl(8 * s)
    love.graphics.print(value_str, vx, y + fl(3 * s))
    local r1 = { x = x + w - bw * 2 - fl(4 * s), y = y, w = bw, h = fl(18 * s) }
    local r2 = { x = x + w - bw, y = y, w = bw, h = fl(18 * s) }
    LabelButton.draw{ x = r1.x, y = r1.y, w = r1.w, h = r1.h, text = "<", fonts = game.fonts, font = sm, hovered = inRect(r1, mx, my) }
    LabelButton.draw{ x = r2.x, y = r2.y, w = r2.w, h = r2.h, text = ">", fonts = game.fonts, font = sm, hovered = inRect(r2, mx, my) }
    local function mult() return love.keyboard.isDown("lshift", "rshift") and 5 or 1 end
    ctl(r1, function() dec(mult()) end)
    ctl(r2, function() inc(mult()) end)
    return y + fl(22 * s)
end

-- ── LAYERS ──────────────────────────────────────────────────────────────

function Panel._drawLayers(view, R, y0, mx, my)
    local game  = view.game
    local s     = game.ui_scale or 1
    local sm    = game.fonts.sm
    local pad   = fl(8 * s)
    local ctls  = view._panel_ctls
    local function ctl(rect, fn) ctls[#ctls + 1] = { rect = rect, fn = fn } end
    love.graphics.setFont(sm)

    -- front-most first
    local order = view._draw_order or {}
    local items = {}
    for i = #order, 1, -1 do items[#items + 1] = order[i] end
    -- hidden items are not drawn, so they are not in the order: list them last
    for _, o in ipairs(view.placed) do
        if o.hidden then items[#items + 1] = o end
    end

    local row_h  = sm:getHeight() + fl(6 * s)
    local fields_h = fl(250 * s)
    local list_y = y0
    local list_h = R.h - (y0 - R.y) - fields_h - pad
    local total_h = #items * row_h
    local max_scroll = math.max(0, total_h - list_h)
    view.layer_scroll = math.max(0, math.min(max_scroll, view.layer_scroll or 0))
    view._layer_list = { x = R.x, y = list_y, w = R.w, h = list_h, max_scroll = max_scroll, content_h = total_h }

    Theme.setColor(Theme.fg.muted)
    love.graphics.print(string.format("IN FRONT  (%d)", #items), R.x + pad, list_y - fl(2 * s))
    list_y = list_y + sm:getHeight() + fl(4 * s)
    list_h = list_h - sm:getHeight() - fl(4 * s)
    view._layer_list.y, view._layer_list.h = list_y, list_h

    love.graphics.setScissor(R.x, list_y, R.w, list_h)
    local eye_w = fl(18 * s)
    local arrow_w = fl(16 * s)
    local name_w = R.w - pad * 2 - eye_w * 2 - arrow_w * 2 - fl(52 * s)
    local drag = view._layer_drag
    for i, o in ipairs(items) do
        local ry = list_y + (i - 1) * row_h - view.layer_scroll
        if ry + row_h >= list_y and ry <= list_y + list_h then
            local row = { x = R.x, y = ry, w = R.w, h = row_h }
            local hov = inRect(row, mx, my) and inRect(view._layer_list, mx, my)
            local sel = view.sel_placed == o
            if hov then view.hover_placed = o end
            if sel then
                Theme.setColor(Theme.bg.widget_hover)
                love.graphics.rectangle("fill", row.x, row.y, row.w, row.h)
            elseif hov then
                Theme.setColor(Theme.bg.widget_hover, 0.5)
                love.graphics.rectangle("fill", row.x, row.y, row.w, row.h)
            end
            -- eye, lock
            local eye = { x = R.x + pad, y = ry + fl(2 * s), w = eye_w, h = row_h - fl(4 * s) }
            Theme.setColor(o.hidden and Theme.fg.faint or Theme.fg.heading)
            love.graphics.print(o.hidden and "-" or "o", eye.x + fl(5 * s), ry + fl(3 * s))
            ctl(eye, function() o.hidden = not o.hidden end)
            local lock = { x = eye.x + eye_w, y = eye.y, w = eye_w, h = eye.h }
            Theme.setColor(o.locked and Theme.status.warn or Theme.fg.faint)
            love.graphics.print(o.locked and "L" or ".", lock.x + fl(5 * s), ry + fl(3 * s))
            ctl(lock, function() o.locked = not o.locked end)
            -- the drop line while dragging another row
            if drag and drag.obj ~= o and inRect(row, mx, my) then
                local above = my < ry + row_h * 0.5
                Theme.setColor(Theme.status.warn)
                local ly = above and ry or ry + row_h
                love.graphics.rectangle("fill", R.x + pad, ly - 1, R.w - pad * 2, 2)
                drag.target, drag.above = o, above
            end
            -- name, layer, marks
            local name = o.id:match("([^/]+)$") or o.id
            local marks = ""
            local rr = view._resolved and view._resolved[o]
            if rr and rr.home > 0 then marks = marks .. "^" end      -- sitting on something
            if rr and not rr.shown then marks = marks .. "!" end      -- hidden_when fired
            Theme.setColor(o.hidden and Theme.fg.faint or (sel and Theme.status.warn or Theme.fg.primary))
            love.graphics.print(trim(sm, name, name_w), eye.x + eye_w * 2 + fl(4 * s), ry + fl(3 * s))
            Theme.setColor(Theme.fg.muted)
            love.graphics.print(string.format("L%d %s", view:layerOf(o), marks), R.x + R.w - pad - arrow_w * 2 - fl(46 * s), ry + fl(3 * s))
            -- layer arrows
            local up = { x = R.x + R.w - pad - arrow_w * 2, y = ry + fl(2 * s), w = arrow_w, h = row_h - fl(4 * s) }
            local dn = { x = R.x + R.w - pad - arrow_w, y = ry + fl(2 * s), w = arrow_w, h = row_h - fl(4 * s) }
            LabelButton.draw{ x = up.x, y = up.y, w = up.w, h = up.h, text = "^", fonts = game.fonts, font = sm, hovered = inRect(up, mx, my) }
            LabelButton.draw{ x = dn.x, y = dn.y, w = dn.w, h = dn.h, text = "v", fonts = game.fonts, font = sm, hovered = inRect(dn, mx, my) }
            ctl(up, function() view:setLayer(o, view:layerOf(o) + 1) end)
            ctl(dn, function() view:setLayer(o, view:layerOf(o) - 1) end)
            view._layer_rows[#view._layer_rows + 1] = { rect = { x = eye.x + eye_w * 2, y = ry, w = up.x - eye.x - eye_w * 2, h = row_h }, obj = o }
        end
    end
    if drag and drag.moved then
        Theme.setColor(Theme.fg.heading, 0.8)
        love.graphics.print((drag.obj.id:match("([^/]+)$") or drag.obj.id), mx + fl(12 * s), my - fl(8 * s))
    end
    love.graphics.setScissor()
    local bx = R.x + R.w - Scrollbar.width() - 2
    view._layer_list.bar_x = bx
    view._layer_list.content_h = total_h
    Scrollbar.draw(bx, list_y, list_h, view.layer_scroll, total_h,
        Scrollbar.containsPoint(bx, list_y, list_h, mx, my))

    -- the selected item's fields
    -- Everything below the list scrolls as one region (the fields, the
    -- homes, ANCHORS): controls in it are clipped to it for clicks too.
    local region = { x = R.x, y = list_y + list_h + pad - fl(4 * s), w = R.w, h = R.y + R.h - (list_y + list_h + pad - fl(4 * s)) }
    view._fields_region = region
    local function ctl(rect, fn) ctls[#ctls + 1] = { rect = rect, fn = fn, clip = region } end
    local fy = region.y + fl(4 * s) - (view.fields_scroll or 0)
    love.graphics.setScissor(region.x, region.y, region.w, region.h)
    local o = view.sel_placed
    Theme.setColor(Theme.border.soft)
    love.graphics.line(R.x, fy - fl(4 * s), R.x + R.w, fy - fl(4 * s))
    local function closeRegion(end_y)
        love.graphics.setScissor()
        local content_h = (end_y + (view.fields_scroll or 0)) - region.y + fl(8 * s)
        view.fields_scroll = Scrollbar.clamp(view.fields_scroll or 0, region.h, content_h)
        region.content_h = content_h
        Scrollbar.draw(R.x + R.w - Scrollbar.width() - 2, region.y, region.h, view.fields_scroll, content_h,
            Scrollbar.containsPoint(R.x + R.w - Scrollbar.width() - 2, region.y, region.h, mx, my))
    end
    if not o then
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("Click a row to select. Click again to grab.", R.x + pad, fy)
        fy = fy + sm:getHeight() + fl(8 * s)
    end
    local x = R.x + pad
    local w = R.w - pad * 2
    if o then
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(trim(sm, o.id, w), x, fy); fy = fy + sm:getHeight() + fl(2 * s)
    local rr  = view._resolved and view._resolved[o]
    local res = rr and rr.fields or o
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(string.format("at %.2f, %.2f  z %d  dx %d  layer %d  %s%s%s", res.gx, res.gy, res.z_offset or 0, res.dx or 0, res.layer or 0,
        res.align or "center", res.flip_x and "  flipped" or "", (rr and not rr.shown) and "  (not shown)" or ""), x, fy); fy = fy + sm:getHeight() + fl(4 * s)
    local bh = fl(20 * s)
    local bx = x
    local function button(text, width, fn, on)
        local r = { x = bx, y = fy, w = fl(width * s), h = bh }
        LabelButton.draw{ x = r.x, y = r.y, w = r.w, h = r.h, text = text, fonts = game.fonts, font = sm, hovered = inRect(r, mx, my),
            fill_token = on and Theme.bg.widget_hover or nil }
        ctl(r, fn)
        bx = bx + r.w + fl(4 * s)
    end
    button("GRAB", 46, function() view:_grabPlaced(o) end)
    button("COPY", 46, function() view:duplicatePlaced(o) end)
    button("DELETE", 56, function() view:deletePlaced(o) end)
    button("FRONT", 50, function() view:sendToFront(o) end)
    button("BACK", 46, function() view:sendToBack(o) end)
    fy = fy + bh + fl(4 * s)
    bx = x
    button(view.parent_pick == o and "PARENT: click it.." or "PARENT", 110, function()
        view.parent_pick = (view.parent_pick == o) and nil or o
    end, view.parent_pick == o)
    button(view.anchors_off[o.id] and "ANCHOR: OFF" or "ANCHOR: ON", 90, function()
        if view.anchors_off[o.id] then view.anchors_off[o.id] = nil else view.anchors_off[o.id] = true end
    end, view.anchors_off[o.id])
    fy = fy + bh + fl(6 * s)
    -- the homes, in order; the active one marked
    Theme.setColor(Theme.fg.muted)
    if o.homes and #o.homes > 0 then
        love.graphics.print("sits on (first that exists wins; else its own floor spot):", x, fy); fy = fy + sm:getHeight()
        for i, h in ipairs(o.homes) do
            local active = rr and rr.home == i
            Theme.setColor(active and Theme.status.good or Theme.fg.muted)
            love.graphics.print(trim(sm, string.format("%s%d. %s  (x%+.2f, d%+.2f, z%+d)", active and "> " or "  ", i, h.on, h.u or h.gx or 0, h.v or h.gy or 0, h.z_offset or 0), w - fl(70 * s)), x, fy)
            local hb = fl(16 * s)
            local r_up = { x = x + w - hb * 3 - fl(4 * s), y = fy, w = hb, h = hb }
            local r_dn = { x = x + w - hb * 2 - fl(2 * s), y = fy, w = hb, h = hb }
            local r_x  = { x = x + w - hb, y = fy, w = hb, h = hb }
            LabelButton.draw{ x = r_up.x, y = r_up.y, w = hb, h = hb, text = "^", fonts = game.fonts, font = sm, hovered = inRect(r_up, mx, my) }
            LabelButton.draw{ x = r_dn.x, y = r_dn.y, w = hb, h = hb, text = "v", fonts = game.fonts, font = sm, hovered = inRect(r_dn, mx, my) }
            LabelButton.draw{ x = r_x.x,  y = r_x.y,  w = hb, h = hb, text = "x", fonts = game.fonts, font = sm, hovered = inRect(r_x, mx, my) }
            ctl(r_up, function() RoomPlacement.moveHome(o, i, -1) end)
            ctl(r_dn, function() RoomPlacement.moveHome(o, i, 1) end)
            ctl(r_x,  function() RoomPlacement.removeHome(o, i) end)
            fy = fy + hb + fl(2 * s)
        end
    else
        love.graphics.print("its own floor spot", x, fy); fy = fy + sm:getHeight()
    end
    if o.hidden_when and #o.hidden_when > 0 then
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(trim(sm, "hidden when owned: " .. table.concat(o.hidden_when, ", "), w), x, fy); fy = fy + sm:getHeight()
    end

    end   -- if o

    -- anchors: everything something sits on, tick off to see the room without it
    fy = fy + fl(4 * s)
    Theme.setColor(Theme.border.soft)
    love.graphics.line(R.x, fy, R.x + R.w, fy); fy = fy + fl(4 * s)
    local anchors = RoomPlacement.anchorIds(view.placed)
    local seen = {}
    for _, id in ipairs(anchors) do seen[id] = true end
    for id in pairs(view.anchors_off) do if not seen[id] then anchors[#anchors + 1] = id end end
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("ANCHORS (tick off = the room without it)", x, fy); fy = fy + sm:getHeight() + fl(2 * s)
    local col = 0
    for _, id in ipairs(anchors) do
        local off = view.anchors_off[id] and true or false
        local r = { x = x + col * fl(140 * s), y = fy, w = fl(136 * s), h = fl(18 * s) }
        LabelButton.draw{ x = r.x, y = r.y, w = r.w, h = r.h, text = (off and "[ ] " or "[x] ") .. (id:match("([^/]+)$") or id), fonts = game.fonts, font = sm,
            hovered = inRect(r, mx, my), fill_token = off and Theme.bg.sunken or Theme.bg.widget_hover }
        ctl(r, function() if view.anchors_off[id] then view.anchors_off[id] = nil else view.anchors_off[id] = true end end)
        col = col + 1
        if col == 2 then col = 0; fy = fy + r.h + fl(3 * s) end
    end
    if col == 1 then fy = fy + fl(18 * s) + fl(3 * s) end
    closeRegion(fy)
end

-- ── LIGHT ───────────────────────────────────────────────────────────────

local function fmt2(v) return string.format("%.2f", v) end

function Panel._drawLight(view, R, y0, mx, my)
    local game = view.game
    local s    = game.ui_scale or 1
    local sm   = game.fonts.sm
    local pad  = fl(8 * s)
    local ctls = view._panel_ctls
    local function ctl(rect, fn) ctls[#ctls + 1] = { rect = rect, fn = fn } end
    local x, w, y = R.x + pad, R.w - pad * 2, y0
    local function num(label, tbl, key, step, lo, hi)
        y = stepper(view, ctl, x, y, w, label, fmt2(tbl[key]),
            function(m) tbl[key] = math.max(lo, tbl[key] - step * m) end,
            function(m) tbl[key] = math.min(hi, tbl[key] + step * m) end)
    end
    local function rgb(label, col)
        for i, ch in ipairs{ "r", "g", "b" } do
            y = stepper(view, ctl, x, y, w, label .. " " .. ch, fmt2(col[i]),
                function(m) col[i] = math.max(0, col[i] - 0.05 * m) end,
                function(m) col[i] = math.min(1, col[i] + 0.05 * m) end)
        end
    end
    love.graphics.setFont(sm)

    -- ── The selected item's light ──────────────────────────────────
    local o = view.sel_placed
    Theme.setColor(Theme.fg.heading)
    if not o then
        love.graphics.print("Select an item (LAYERS tab, or a row below)", x, y)
        y = y + sm:getHeight() + fl(6 * s)
    else
        local id = o.id
        love.graphics.print(trim(sm, id, w), x, y); y = y + sm:getHeight() + fl(4 * s)
        local e = Lights.emitters[id]
        local tog = { x = x, y = y, w = fl(110 * s), h = fl(20 * s) }
        LabelButton.draw{ x = tog.x, y = tog.y, w = tog.w, h = tog.h, text = e and "MAKES LIGHT" or "NO LIGHT", fonts = game.fonts, font = sm,
            hovered = inRect(tog, mx, my), fill_token = e and Theme.bg.widget_hover or nil }
        ctl(tog, function()
            if Lights.emitters[id] then Lights.emitters[id] = nil
            else Lights.emitters[id] = { color = { 1.0, 0.95, 0.8 }, radius = 1.2, alpha = 0.4 } end
        end)
        y = y + tog.h + fl(6 * s)
        if e then
            rgb("color", e.color)
            num("size", e, "radius", 0.1, 0.1, 5)
            num("brightness", e, "alpha", 0.05, 0, 1)
            local pt = { x = x, y = y, w = fl(110 * s), h = fl(20 * s) }
            LabelButton.draw{ x = pt.x, y = pt.y, w = pt.w, h = pt.h, text = e.pulse and "PULSE: ON" or "PULSE: OFF", fonts = game.fonts, font = sm,
                hovered = inRect(pt, mx, my), fill_token = e.pulse and Theme.bg.widget_hover or nil }
            ctl(pt, function() if e.pulse then e.pulse = nil else e.pulse = { secs = 2.0, amount = 0.15 } end end)
            y = y + pt.h + fl(6 * s)
            if e.pulse then
                num("pulse secs", e.pulse, "secs", 0.1, 0.2, 10)
                num("pulse amount", e.pulse, "amount", 0.05, 0, 1)
            end
        end
    end

    -- ── Everything that makes light: click to edit it ──────────────
    y = y + fl(4 * s)
    Theme.setColor(Theme.border.soft)
    love.graphics.line(R.x, y, R.x + R.w, y); y = y + fl(6 * s)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("MAKES LIGHT", x, y); y = y + sm:getHeight() + fl(2 * s)
    local ids = {}
    for id in pairs(Lights.emitters) do ids[#ids + 1] = id end
    table.sort(ids)
    local by_id = {}
    for _, po in ipairs(view.placed) do by_id[po.id] = by_id[po.id] or po end
    for _, id in ipairs(ids) do
        local row = { x = R.x, y = y, w = R.w, h = sm:getHeight() + fl(4 * s) }
        local sel = o and o.id == id
        if inRect(row, mx, my) then
            Theme.setColor(Theme.bg.widget_hover, 0.5)
            love.graphics.rectangle("fill", row.x, row.y, row.w, row.h)
            if by_id[id] then view.hover_placed = by_id[id] end
        end
        Theme.setColor(sel and Theme.status.warn or (by_id[id] and Theme.fg.primary or Theme.fg.faint))
        love.graphics.print(trim(sm, id .. (by_id[id] and "" or "  (not in room)"), w), x, y + fl(2 * s))
        if by_id[id] then ctl(row, function() view.sel_placed = by_id[id] end) end
        y = y + row.h
    end

    -- ── The room's own light, folded away ──────────────────────────
    y = y + fl(6 * s)
    Theme.setColor(Theme.border.soft)
    love.graphics.line(R.x, y, R.x + R.w, y); y = y + fl(6 * s)
    local fx = { x = x, y = y, w = fl(130 * s), h = fl(20 * s) }
    LabelButton.draw{ x = fx.x, y = fx.y, w = fx.w, h = fx.h, text = view.show_fixture and "ROOM LIGHT  v" or "ROOM LIGHT  >", fonts = game.fonts, font = sm,
        hovered = inRect(fx, mx, my) }
    ctl(fx, function() view.show_fixture = not view.show_fixture end)
    -- Off while working: see the glows on their own (the shove intro's dark)
    local sw = { x = fx.x + fx.w + pad, y = y, w = fl(70 * s), h = fl(20 * s) }
    LabelButton.draw{ x = sw.x, y = sw.y, w = sw.w, h = sw.h, text = view.fixture_off and "OFF" or "ON", fonts = game.fonts, font = sm,
        hovered = inRect(sw, mx, my), fill_token = (not view.fixture_off) and Theme.bg.widget_hover or nil }
    ctl(sw, function() view.fixture_off = not view.fixture_off end)
    y = y + fx.h + fl(6 * s)
    if view.show_fixture then
        local F = Lights.fixture
        y = stepper(view, ctl, x, y, w, "kind", F.kind,
            function() F.kind = F.kind == "fluorescent" and "cone" or "fluorescent" end,
            function() F.kind = F.kind == "fluorescent" and "cone" or "fluorescent" end)
        rgb("color", F.color)
        rgb("ambient", F.ambient)
        num("base", F, "base", 0.05, 0, 1.5)
        num("pool w", F.pool, "w", 0.1, 0.2, 4)
        num("pool h", F.pool, "h", 0.1, 0.2, 4)
        num("pool alpha", F.pool, "alpha", 0.05, 0, 1)
        num("bloom peak", F.bloom, "peak", 0.05, 1, 2)
        num("bloom peak_at", F.bloom, "peak_at", 0.02, 0.02, 1)
        num("bloom settle_at", F.bloom, "settle_at", 0.05, 0.1, 3)
        local KIND_ROWS = {
            cone = { { "cone w", "w", 0.1, 0.2, 4 }, { "cone h", "h", 0.1, 0.2, 4 },
                     { "cone alpha", "alpha", 0.05, 0, 1 }, { "cone base", "base", 0.05, 0, 1 } },
        }
        for _, row in ipairs(KIND_ROWS[F.kind] or {}) do
            num(row[1], F[F.kind], row[2], row[3], row[4], row[5])
        end
    end
end

-- ── input ───────────────────────────────────────────────────────────────

function Panel.mousepressed(view, x, y, button)
    local R = view._panel_rect
    if not R or not inRect(R, x, y) then return false end
    if button ~= 1 then return true end
    for _, c in ipairs(view._panel_ctls or {}) do
        if inRect(c.rect, x, y) and (not c.clip or inRect(c.clip, x, y)) then c.fn(); return true end
    end
    local F = view._fields_region
    if F and F.content_h and Scrollbar.containsPoint(R.x + R.w - Scrollbar.width() - 2, F.y, F.h, x, y) then
        local bx = R.x + R.w - Scrollbar.width() - 2
        if Scrollbar.containsThumb(bx, F.y, F.h, view.fields_scroll or 0, F.content_h, x, y) then
            view._fields_bar_drag = { y0 = y, scroll0 = view.fields_scroll or 0 }
        else
            view.fields_scroll = Scrollbar.scrollFromTrackClick(F.y, F.h, y, F.content_h)
        end
        return true
    end
    local L = view._layer_list
    if L and L.bar_x and Scrollbar.containsPoint(L.bar_x, L.y, L.h, x, y) then
        if Scrollbar.containsThumb(L.bar_x, L.y, L.h, view.layer_scroll, L.content_h, x, y) then
            view._layer_bar_drag = { y0 = y, scroll0 = view.layer_scroll }
        else
            view.layer_scroll = Scrollbar.scrollFromTrackClick(L.y, L.h, y, L.content_h)
        end
        return true
    end
    if L and inRect(L, x, y) then
        for _, row in ipairs(view._layer_rows or {}) do
            if inRect(row.rect, x, y) then
                -- a press starts a possible drag; the click resolves on release
                view._layer_drag = { obj = row.obj, x0 = x, y0 = y, moved = false }
                return true
            end
        end
    end
    return true
end

function Panel.mousemoved(view, x, y)
    local fd = view._fields_bar_drag
    if fd then
        local F = view._fields_region
        if F then view.fields_scroll = Scrollbar.scrollFromDrag(F.h, y - fd.y0, fd.scroll0, F.content_h or 0) end
        return true
    end
    local bd = view._layer_bar_drag
    if bd then
        local L = view._layer_list
        if L then view.layer_scroll = Scrollbar.scrollFromDrag(L.h, y - bd.y0, bd.scroll0, L.content_h) end
        return true
    end
    local d = view._layer_drag
    if not d then return false end
    if not d.moved and (math.abs(x - d.x0) > 4 or math.abs(y - d.y0) > 4) then d.moved = true end
    return true
end

function Panel.mousereleased(view, x, y, button)
    if view._fields_bar_drag then view._fields_bar_drag = nil; return true end
    if view._layer_bar_drag then view._layer_bar_drag = nil; return true end
    local d = view._layer_drag
    if not d then return false end
    view._layer_drag = nil
    if not d.moved then
        if view.parent_pick and view.parent_pick ~= d.obj then
            view:parentTo(view.parent_pick, d.obj)
            view.parent_pick = nil
            return true
        end
        -- a click: select, or grab when already selected
        if view.sel_placed == d.obj then view:_grabPlaced(d.obj) else view.sel_placed = d.obj end
        return true
    end
    if d.target and d.target ~= d.obj then
        if d.above then view:placeInFrontOf(d.obj, d.target) else view:placeBehind(d.obj, d.target) end
        view.sel_placed = d.obj
    end
    return true
end

function Panel.wheelmoved(view, dy, mx, my)
    local L = view._layer_list
    local R = view._panel_rect
    if R and inRect(R, mx, my) then
        local F = view._fields_region
        if F and inRect(F, mx, my) then
            view.fields_scroll = Scrollbar.clamp((view.fields_scroll or 0) - dy * Scrollbar.WHEEL_NOTCH_PX * 1.5, F.h, F.content_h or 0)
        elseif L and (view.panel_tab or "layers") == "layers" then
            view.layer_scroll = Scrollbar.clamp((view.layer_scroll or 0) - dy * Scrollbar.WHEEL_NOTCH_PX * 1.5, L.h, L.content_h or 0)
        end
        return true
    end
    return false
end

return Panel
