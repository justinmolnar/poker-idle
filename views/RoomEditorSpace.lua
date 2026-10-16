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
    local bad = fit.status == "off_room" or fit.status == "overhang" or #fit.overlaps > 0
    local token = bad and Theme.status.error or Theme.status.good
    -- the parent's top face, then the hand's foot on it
    if fit.face and fit.parent then
        drawPoly(fit.face, fit.parent.F, Theme.fg.heading, 0.10, 0.7, cx, cy, tw, th, s, g2s)
    end
    drawPoly(fit.foot, E, token, 0.25, 0.9, cx, cy, tw, th, s, g2s)
    for _, d in ipairs(fit.overlaps) do
        drawPoly(d.foot, d.E, Theme.status.error, 0.15, 0.8, cx, cy, tw, th, s, g2s)
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
function ES.audit(view, why)
    local items = ES.items(view)
    local clashes = RoomSpace.clashes(items, ES.ctx(view))
    local marks = {}
    for _, cl in ipairs(clashes) do
        local a, b = cl.a.item.obj.id, cl.b.item.obj.id
        if cl.kind == "overlap" then
            print(string.format("[room-editor] clash: %s and %s overlap on the same level", a, b))
        else
            print(string.format("[room-editor] clash: %s hangs off %s's top", a, b))
        end
        marks[#marks + 1] = { poly = cl.a.foot, elev = cl.a.E }
    end
    if #clashes == 0 then print("[room-editor] no clashes (" .. tostring(why) .. ")") end
    view._audit_marks = marks
    view._audit_until = love.timer.getTime() + ES.MARK_SECS
    return #clashes
end

return ES
