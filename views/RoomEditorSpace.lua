-- views/RoomEditorSpace.lua
--
-- The room editor's sense of SPACE: what the thing in the hand would land
-- on, whether it fits, what it would overlap, and the home a drop writes.
-- Dev tooling: the build leaves this file out of shipped copies (a cut
-- module), and views/RoomView reaches it through a proxy that answers nil
-- without it. models/room_space does the geometry; this file knows the
-- editor (its active_* fields, the hand, the resolved room) and draws.
--
--   handFit(view, gx, gy)      the fit for the hand at a grid point, with
--                              the z it will be placed at and its layer
--   drawPreview / drawMarks    the overlay under the room's transform
--   applyDrop(view, entry, placement, fit)
--                              over a face: write a home (auto-parent);
--                              off a face it sat on: unhome; else nil and
--                              the caller writes as it always did
--   onGrab / nudgeZ            the height nudge above a parent's face
--   audit(view, why)           every clash in the room, printed and marked
--
-- The z the hand gets, in order: Shift+click or auto_surface off -> the
-- hand's own active_z; over a face -> restZ + active_z_nudge; else active_z.

local RoomSpace     = require("models.room_space")
local RoomPlacement = require("models.room_placement")
local RoomSurfaces  = require("services.RoomSurfaces")
local Theme         = require("views.Theme")

local ES = {}

ES.MARK_SECS = 6

-- ── The model's callbacks, over the editor's loader ────────────────────

function ES.ctx(view)
    if view._space_ctx then return view._space_ctx end
    local RoomView = require("views.RoomView")
    local loader = view.game and view.game.sprite_loader
    local ctx = {}
    ctx.entryFor = function(f, obj)
        local o = obj or f
        return (RoomSurfaces.entryFor(loader, { sprite = o.sprite or f.sprite, id = o.id or f.id, frame = o.frame or f.frame }))
    end
    ctx.geomFor = function(f, entry, obj)
        local o = obj or f
        local name = o.sprite or f.sprite or o.id or f.id
        local sprite = loader and loader.getSprite and loader:getSprite(name, false, nil, o.frame or f.frame) or nil
        local w = sprite and sprite.getWidth and sprite:getWidth() or nil
        local bottom = sprite and RoomView.getSpriteBottom and RoomView.getSpriteBottom(sprite, name) or nil
        return RoomSurfaces.geomFor(entry, w, bottom)
    end
    view._space_ctx = ctx
    return ctx
end

-- The room's placed things as the model wants them, from the last resolve:
-- shown ones only; minus the descendants of `exclude_id` (the hand's own
-- children ride with it and are never candidates under it).
function ES.items(view, exclude_id)
    local res = view._resolved
    if not res then return {} end
    local list = {}
    for _, obj in ipairs(view.placed) do
        local r = res[obj]
        if r and not obj.hidden and not (view.anchors_off and view.anchors_off[obj.id]) then
            local on = (r.home and r.home > 0 and obj.homes and obj.homes[r.home]) and obj.homes[r.home].on or nil
            list[#list + 1] = { obj = obj, f = r.fields, on = on }
        end
    end
    if exclude_id then
        local keep = {}
        for _, it in ipairs(list) do
            if it.obj.id ~= exclude_id and not RoomSpace.isDescendant(list, it.obj.id, exclude_id) then keep[#keep + 1] = it end
        end
        list = keep
    end
    return list
end

-- The hand as resolved fields at a grid point.
function ES.handFields(view, gx, gy)
    local spec = view.placeable[view.selected_idx]
    local pick = view.picked_item
    local align = view.active_align
    if align == "center" then align = nil end
    return {
        id = pick and pick.id or (spec and spec.id), sprite = pick and pick.sprite or (spec and (spec.sprite or spec.id)),
        frame = view.active_frame or (spec and spec.frame),
        gx = gx, gy = gy, w = view.active_w or 1, h = view.active_h or 1, align = align,
        flip_x = view.active_flip_x or false, scale = view.active_scale or 1,
        dx = view.active_dx or 0, z_offset = view.active_z or 0, layer = view.active_layer or 0,
    }
end

-- The placed list plus a synthetic entry for the hand, so a held parent's
-- children resolve against where it is going, not their base spot.
function ES.placedWithHand(view, gx, gy)
    if not view.picked_item then return nil end
    local hand = ES.handFields(view, gx, gy)
    local fit = view._hand_fit
    if fit and fit.z then hand.z_offset = fit.z end
    local list = {}
    for i, o in ipairs(view.placed) do list[i] = o end
    list[#list + 1] = hand
    return list
end

function ES.handFit(view, gx, gy)
    if not view.placeable or not view.placeable[view.selected_idx] then return nil end
    local hand = ES.handFields(view, gx, gy)
    local items = ES.items(view, hand.id)
    local auto = view.auto_surface ~= false
    local fit = RoomSpace.fit(hand, items, ES.ctx(view),
        { room_size = view.room_size, auto_z = auto, z_nudge = view.active_z_nudge or 0 })
    if not (fit.parent and auto) then fit.z = view.active_z or 0 end
    fit.layer = view.active_layer or 0
    if fit.parent and auto then
        fit.layer = math.max(fit.layer, (fit.parent.f.layer or 0) + 1)
    end
    view._hand_fit = fit
    return fit
end

-- ── Drawing (under the room's transform) ───────────────────────────────

local function toScreen(poly, elev, cx, cy, tw, th, s, g2s)
    local pts = {}
    for i = 1, #poly, 2 do
        local sx, sy = g2s(poly[i], poly[i + 1], cx, cy, tw, th)
        pts[#pts + 1] = sx; pts[#pts + 1] = sy - (elev or 0) * s
    end
    return pts
end

local wallToScreen, drawWall   -- defined with the SPACE mode below

local function drawPoly(poly, elev, token, fill_a, line_a, cx, cy, tw, th, s, g2s)
    local pts = toScreen(poly, elev, cx, cy, tw, th, s, g2s)
    if fill_a and fill_a > 0 then
        Theme.setColor(token, fill_a)
        love.graphics.polygon("fill", pts)
    end
    Theme.setColor(token, line_a or 0.9)
    love.graphics.polygon("line", pts)
end

function ES.drawPreview(view, fit, cx, cy, tw, th, s)
    local RoomView = require("views.RoomView")
    local g2s = RoomView.gridToScreen
    if not (fit and g2s) then return end
    local hand = ES.handFields(view, 0, 0)
    hand.z_offset = fit.z
    local E = RoomSpace.floorElev(hand)
    local bad = fit.status == "off_room" or fit.status == "overhang" or #fit.overlaps > 0 or fit.over_wall
    local token = bad and Theme.status.error or Theme.status.good
    if fit.wall then
        -- a wall thing: its rectangle on the wall, the ones it crosses
        drawWall(fit.wall, token, 0.25, 0.9, cx, cy, tw, th, s, g2s)
        for _, d in ipairs(fit.overlaps) do
            if d.wall then drawWall(d.wall, Theme.status.error, 0.15, 0.8, cx, cy, tw, th, s, g2s) end
        end
        return
    end
    -- the parent's top face, then the hand's foot on it
    if fit.face and fit.parent then
        drawPoly(fit.face, fit.parent.F, Theme.fg.heading, 0.10, 0.7, cx, cy, tw, th, s, g2s)
    end
    if fit.foot then drawPoly(fit.foot, E, token, 0.25, 0.9, cx, cy, tw, th, s, g2s) end
    for _, d in ipairs(fit.overlaps) do
        if d.foot then drawPoly(d.foot, d.E, Theme.status.error, 0.15, 0.8, cx, cy, tw, th, s, g2s) end
    end
end

function ES.drawMarks(view, cx, cy, tw, th, s)
    local marks = view._audit_marks
    if not marks or (view._audit_until or 0) < love.timer.getTime() then return end
    local RoomView = require("views.RoomView")
    local g2s = RoomView.gridToScreen
    for _, m in ipairs(marks) do
        drawPoly(m.poly, m.elev, Theme.status.error, 0.12, 0.8, cx, cy, tw, th, s, g2s)
    end
end

-- ── The drop ───────────────────────────────────────────────────────────

-- Over a face: the entry gets (or updates) a home on that parent, moved to
-- the front so it is the active one, and the base fields are left alone.
-- On the floor, when the entry was sitting on a face: the home goes and
-- the placement is written to the base. Anything else: nil, and the caller
-- writes the placement the way it always did.
function ES.applyDrop(view, entry, placement, fit)
    if not fit then return nil end
    local res_all = RoomPlacement.resolveAll(view.placed, view:_resolveSet({}))
    local r = res_all[entry]
    if not r then return nil end
    if fit.parent then
        local parent = fit.parent.item.obj
        if parent == entry or parent.id == entry.id then return nil end
        if RoomSpace.isDescendant(ES.items(view), parent.id, entry.id) then
            print(string.format("[room-editor] %s cannot sit on %s: that would sit on itself", entry.id, parent.id))
            return nil
        end
        local pres = res_all[parent]
        if not pres then return nil end
        local world = {}
        for k, v in pairs(r.fields) do world[k] = v end
        for k, v in pairs(placement) do world[k] = v end
        world.w, world.h = view.active_w or world.w, view.active_h or world.h
        RoomPlacement.setHome(entry, parent.id, world, pres.fields)
        local idx
        for i, h in ipairs(entry.homes) do if h.on == parent.id then idx = i end end
        while idx and idx > 1 do RoomPlacement.moveHome(entry, idx, -1); idx = idx - 1 end
        print(string.format("[room-editor] %s sits on %s (z %d, layer %d)", entry.id, parent.id,
            world.z_offset or 0, world.layer or 0))
        return true
    end
    if r.home and r.home > 0 and entry.homes and entry.homes[r.home] then
        local h = entry.homes[r.home]
        local pobj
        for _, o in ipairs(view.placed) do if o.id == h.on then pobj = o; break end end
        if pobj and res_all[pobj] then
            local ctx = ES.ctx(view)
            local pd = RoomSpace.describe({ obj = pobj, f = res_all[pobj].fields }, ctx)
            local cd = RoomSpace.describe({ obj = entry, f = r.fields }, ctx)
            if RoomSpace.sitsOn(cd, pd) then
                RoomPlacement.removeHome(entry, r.home)
                RoomPlacement.writePlacement(entry, nil, nil, placement)
                print(string.format("[room-editor] %s is off %s, on the floor", entry.id, pobj.id))
                return true
            end
        end
    end
    return nil
end

-- Picking a thing up that sits on a face: the hand remembers how far
-- above the rest height it was, so putting it back changes nothing.
function ES.onGrab(view, obj, r)
    view.active_z_nudge = 0
    if not (r and r.home and r.home > 0 and obj.homes and obj.homes[r.home]) then return end
    local h = obj.homes[r.home]
    local res_all = view._resolved
    local pobj
    for _, o in ipairs(view.placed) do if o.id == h.on then pobj = o; break end end
    if not (pobj and res_all and res_all[pobj]) then return end
    local ctx = ES.ctx(view)
    local pd = RoomSpace.describe({ obj = pobj, f = res_all[pobj].fields }, ctx)
    local cd = RoomSpace.describe({ obj = obj, f = r.fields }, ctx)
    if RoomSpace.sitsOn(cd, pd) then
        local rest = RoomSpace.restZ(pd.f, pd.entry, r.fields)
        if rest then view.active_z_nudge = (r.fields.z_offset or 0) - rest end
    end
end

-- The height keys while the hand is over a face: they move the nudge.
function ES.nudgeZ(view, delta)
    local fit = view._hand_fit
    if not (fit and fit.parent and view.auto_surface ~= false) then return false end
    view.active_z_nudge = (view.active_z_nudge or 0) + delta
    print(string.format("[room-editor] %d px above %s's top", view.active_z_nudge, fit.parent.item.obj.id))
    return true
end

-- Every clash in the room now, printed and marked for a few seconds.
function ES.clashWords(cl)
    local a, b = cl.a.item.obj.id, cl.b.item.obj.id
    if cl.kind == "overlap" then
        if cl.a.wall then return string.format("%s and %s overlap on the %s wall", a, b, cl.a.wall.plane) end
        return string.format("%s and %s overlap on the same level", a, b)
    elseif cl.kind == "wall" then
        return string.format("%s runs into %s on the wall", a, b)
    end
    return string.format("%s hangs off %s's top", a, b)
end

function ES.audit(view, why)
    local clashes = view._resolved and ES.frame(view).clashes or {}
    local marks = {}
    for _, cl in ipairs(clashes) do
        print("[room-editor] clash: " .. ES.clashWords(cl))
        if cl.a.foot then marks[#marks + 1] = { poly = cl.a.foot, elev = cl.a.E } end
    end
    if #clashes == 0 then print("[room-editor] no clashes (" .. tostring(why) .. ")") end
    view._audit_marks = marks
    view._audit_until = love.timer.getTime() + ES.MARK_SECS
    return #clashes
end

-- ── SPACE mode ──────────────────────────────────────────────────────────
--
-- The editor's second mode (view.space_mode, the SPACE toggle in the room
-- row): every face and footprint drawn at rest, placement by drag and
-- drop, the clashes a live panel tab. The old click-to-place path still
-- works on empty floor; Alt+click is no longer needed to pick a thing up.

-- The frame's view of the room: the resolved items, their descriptions
-- and the clashes, computed once per editor draw (the editor assigns a
-- fresh _resolved every draw, so its identity is the frame key).
function ES.frame(view)
    local res = view._resolved
    local fr = view._space_frame
    if fr and fr.res == res then return fr end
    local items = ES.items(view)
    local ctx = ES.ctx(view)
    local descs = RoomSpace.describeAll(items, ctx)
    local by_obj = {}
    for _, d in ipairs(descs) do by_obj[d.item.obj] = d end
    fr = { res = res, items = items, descs = descs, by_obj = by_obj,
           clashes = RoomSpace.clashes(items, ctx, descs) }
    view._space_frame = fr
    return fr
end

function ES.clashesNow(view)
    if not view._resolved then return {} end
    return ES.frame(view).clashes
end

-- A wall rectangle to screen points: (t, z) on its plane -> grid (t, 0)
-- or (0, t), projected, lifted by z.
wallToScreen = function(rect, cx, cy, tw, th, s, g2s)
    local pts = {}
    for _, c in ipairs({ { rect.t0, rect.z0 }, { rect.t1, rect.z0 }, { rect.t1, rect.z1 }, { rect.t0, rect.z1 } }) do
        local gx, gy
        if rect.plane == "back" then gx, gy = c[1], 0 else gx, gy = 0, c[1] end
        local sx, sy = g2s(gx, gy, cx, cy, tw, th)
        pts[#pts + 1] = sx; pts[#pts + 1] = sy - c[2] * s
    end
    return pts
end

drawWall = function(rect, token, fill_a, line_a, cx, cy, tw, th, s, g2s)
    local pts = wallToScreen(rect, cx, cy, tw, th, s, g2s)
    if fill_a and fill_a > 0 then
        Theme.setColor(token, fill_a)
        love.graphics.polygon("fill", pts)
    end
    Theme.setColor(token, line_a or 0.9)
    love.graphics.polygon("line", pts)
end

-- The room's space at rest: every top face (faint), every foot on its
-- plane, every wall rectangle, a tick from each child to its parent, the
-- members of a clash in red, and the clash the panel hovers lit.
function ES.drawSpace(view, cx, cy, tw, th, s)
    local RoomView = require("views.RoomView")
    local g2s = RoomView.gridToScreen
    if not (g2s and view._resolved) then return end
    local fr = ES.frame(view)
    local in_clash = {}
    for _, cl in ipairs(fr.clashes) do in_clash[cl.a] = true; in_clash[cl.b] = true end
    local hov = view._space_hover_clash
    for _, d in ipairs(fr.descs) do
        local hot = hov and (hov.a == d or hov.b == d)
        local bad = in_clash[d]
        if d.wall then
            local token = hot and Theme.status.warn or (bad and Theme.status.error or Theme.fg.heading)
            drawWall(d.wall, token, hot and 0.25 or (bad and 0.12 or 0.04), hot and 0.95 or 0.55, cx, cy, tw, th, s, g2s)
        else
            if d.foot then
                local token = hot and Theme.status.warn or (bad and Theme.status.error or Theme.status.good)
                drawPoly(d.foot, d.E, token, hot and 0.25 or (bad and 0.12 or 0.05), hot and 0.95 or 0.45, cx, cy, tw, th, s, g2s)
            end
            if d.face then
                drawPoly(d.face, d.F, hot and Theme.status.warn or Theme.fg.heading, hot and 0.15 or 0.03, hot and 0.9 or 0.35, cx, cy, tw, th, s, g2s)
            end
        end
        -- the tick to the parent it sits on
        local pid = d.item.on
        if pid and d.foot then
            for _, p in ipairs(fr.descs) do
                if p.item.obj.id == pid and p.face then
                    local ax, ay = RoomSpace.centroid(d.foot)
                    local bx, by = RoomSpace.centroid(p.face)
                    local sx1, sy1 = g2s(ax, ay, cx, cy, tw, th)
                    local sx2, sy2 = g2s(bx, by, cx, cy, tw, th)
                    sy1, sy2 = sy1 - d.E * s, sy2 - p.F * s
                    local dxp, dyp = sx2 - sx1, sy2 - sy1
                    local len = math.sqrt(dxp * dxp + dyp * dyp)
                    if len > 1 then
                        local k = math.min(1, (12 * s) / len)
                        Theme.setColor(Theme.fg.heading, 0.7)
                        love.graphics.setLineWidth(2)
                        love.graphics.line(sx1, sy1, sx1 + dxp * k, sy1 + dyp * k)
                        love.graphics.setLineWidth(1)
                    end
                    break
                end
            end
        end
    end
end

-- The status bar's words for the mode, and the right slot's nudge.
function ES.statusText(view)
    if not view.space_mode then return nil end
    local n = #ES.clashesNow(view)
    return string.format("SPACE | CLASHES %d (C)", n)
end

function ES.statusRight(view)
    local fit = view._hand_fit
    local d = view._space_drag
    if fit and fit.parent and (view.active_z_nudge or 0) ~= 0 and (view.picked_item or (d and d.started)) then
        return string.format("%s %+d px above %s", view.picked_item and view.picked_item.id or "hand",
            view.active_z_nudge, fit.parent.item.obj.id)
    end
    return nil
end

-- ── Drag and drop ──────────────────────────────────────────────────────
--
-- view._space_drag = { kind = "placed"|"browser", obj, idx, x0, y0, moved,
--                      started, orig_obj, orig_idx, locked }
-- A press arms it; past 4 px it is a drag (a placed thing goes into the
-- hand the way Alt+click did, its children riding); release drops where
-- the hand is, through the same placement the click uses, back at the
-- thing's old draw position; a release off the room, over the chrome,
-- at (-1,-1) (the window lost focus) or Esc puts it back untouched.

ES.DRAG_PX = 4

function ES.beginDrag(view, obj, x, y)
    if not view.space_mode or view.picked_item or view.parent_pick or not obj then return false end
    view._space_drag = { kind = "placed", obj = obj, x0 = x, y0 = y, moved = false, started = false, locked = obj.locked or false }
    return true
end

function ES.beginBrowserDrag(view, idx, x, y)
    if not view.space_mode or view.picked_item then return false end
    view._space_drag = { kind = "browser", idx = idx, x0 = x, y0 = y, moved = false, started = false }
    return true
end

function ES.dragMoved(view, x, y)
    local d = view._space_drag
    if not d then return false end
    if not d.moved and (math.abs(x - d.x0) > ES.DRAG_PX or math.abs(y - d.y0) > ES.DRAG_PX) then
        d.moved = true
    end
    if d.moved and not d.started then
        if d.kind == "placed" then
            if d.locked then return true end
            local idx
            for i, o in ipairs(view.placed) do if o == d.obj then idx = i; break end end
            if not idx then view._space_drag = nil; return false end
            d.orig_obj, d.orig_idx = d.obj, idx
            view:_grabPlaced(d.obj)
            d.started = view.picked_item ~= nil
        else
            local s = view.game and view.game.ui_scale or 1
            if x >= 280 * s then d.started = true end
        end
    end
    return true
end

-- Where a release counts as a drop: in the room, not on the chrome.
function ES.dropOk(view, x, y)
    local s = view.game and view.game.ui_scale or 1
    if x < 0 or y < 0 then return false end
    if x < 280 * s or y < 90 * s then return false end
    local R = view._panel_rect
    if R and not view.hide_editor_hud and x >= R.x and x < R.x + R.w and y >= R.y and y < R.y + R.h then return false end
    local fit = view._hand_fit
    if fit and fit.status == "off_room" then return false end
    return true
end

function ES.dragReleased(view, x, y, button)
    local d = view._space_drag
    if not d then return false end
    if button ~= 1 then return false end
    view._space_drag = nil
    if not d.moved then
        if d.kind == "placed" then view.sel_placed = d.obj end
        return true
    end
    if not d.started then return true end
    if not ES.dropOk(view, x, y) then
        ES.cancelDrag(view, d)
        return true
    end
    local gx, gy = view:_pointerGrid(x, y)
    view:_placeAt(gx, gy, d.orig_idx)
    return true
end

-- Put a dragged thing back exactly where it was: the original table at
-- its original index, nothing else touched.
function ES.cancelDrag(view, d)
    d = d or view._space_drag
    view._space_drag = nil
    if not (d and d.started and d.kind == "placed" and d.orig_obj) then return d ~= nil end
    if view.picked_item and view.picked_item.id == d.orig_obj.id then
        view.picked_item = nil
        local idx = math.min(d.orig_idx or (#view.placed + 1), #view.placed + 1)
        table.insert(view.placed, idx, d.orig_obj)
        view.sel_placed = d.orig_obj
        view:syncActiveParams()
        print("[room-editor] drag cancelled, " .. d.orig_obj.id .. " is back")
    end
    return true
end

function ES.dragging(view)
    local d = view._space_drag
    return d ~= nil and d.started
end

return ES
