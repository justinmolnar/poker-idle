-- views/RoomBuildView.lua
--
-- BUILD: the room editor built around what the room knows about itself —
-- every placed thing's footprint, top face, height and, on a wall, its
-- rectangle (data/room_surfaces via models/room_space). Where the old
-- designer typed offsets, this one is a build mode:
--
--   • the pointer picks what it is OVER ON SCREEN: hover the top of a
--     tall thing and that top is the target, lit; the thing in hand is
--     drawn standing on it at the right height before you let go
--   • drag a thumbnail off the shelf, or any placed thing, by where you
--     grab it; children ride with their parent; release drops; a drop on
--     a top parents the thing there
--   • things refuse to go inside each other: pushed into a neighbour on
--     the same level they slide along it until they touch; a top's edge
--     snaps a foot inside it; the room's walls stop a floor thing
--   • wall things live on the walls: they slide along and up them
--   • click selects; a card shows what the thing is and sits on; the
--     keys nudge it; Delete, Ctrl+D, Ctrl+Z / Ctrl+Y, R flips, Z / X the
--     layer, [ ] the frame, the wheel over it the scale
--   • anything that clashes is tinted red, counted in the corner
--   • Enter exports the same data/room_layout.lua the old designer wrote
--
-- The room itself is drawn by views/RoomView (its render path only, in
-- build_mode); the hand's children resolve through opts.hand_entry.
-- Dev tooling: a cut module (build-tools/demo_cut.py), reached only from
-- states/RoomBuildState.

local Theme         = require("views.Theme")
local LabelButton   = require("views.widgets.LabelButton")
local RoomPlacement = require("models.room_placement")
local RoomSpace     = require("models.room_space")
local ES            = require("views.RoomEditorSpace")

local Build = {}
Build.__index = Build

local fl = math.floor
local DRAG_PX    = 4       -- a press that moves less is a click
local SNAP_IN    = 0.6     -- cells: a foot this close inside a top snaps in
local SLIDE_MAX  = 1.5     -- cells: how far a thing is pushed out of a neighbour
local SHELF_H    = 104     -- the shelf's height, art px
local CELL       = 72      -- a thumbnail cell
local WALL_NEAR  = 0.6     -- cells: a wall thing this close to a wall takes it

function Build.new(game, room_view)
    local self = setmetatable({}, Build)
    self.game, self.rv = game, room_view
    self.zoom = 2.0
    self.hand = nil            -- see beginGrab / beginNew
    self.press = nil           -- { x, y, obj, spec, moved }
    self.sel = nil             -- the selected placed entry
    self.hover = nil           -- the thing under the pointer, for the glow
    self.target = nil          -- the top / wall under the pointer this frame
    self.fit = nil
    self.grid_snap = false
    self.show_help = false
    self.shelf_tab = 1         -- 1 catalog, 2 flavour
    self.shelf_scroll = 0
    self.filter = ""
    self.undo, self.redo = {}, {}
    self._shelf_cells = {}
    self._card = nil
    self.help_lines = {
        "drag a thumbnail off the shelf, or anything in the room, by where you grab it",
        "hover the top of a thing: it lights, the hand stands on it; release parents it",
        "things slide along each other and stop at the walls; G snaps to the grid",
        "click selects: Delete, Ctrl+D copy, R flip, Z / X layer, [ ] frame, wheel scale, 7 / 8 height",
        "Ctrl+Z undo, Ctrl+Y redo, Tab the shelf's tab, type to filter, Esc clears / cancels",
        "Enter exports data/room_layout.lua, F3 leaves",
    }
    return self
end

-- ── Geometry: grid ↔ screen under the room's own transform ─────────────

function Build:metrics()
    local RoomView = require("views.RoomView")
    local v = self.rv._view
    local s = self.game.ui_scale or 1
    local tw, th = RoomView.tileMetrics(s)
    if not (v and v.cx) then
        local W, H = love.graphics.getDimensions()
        local cx, cy = RoomView.getCenter(W, H, s, true)
        return { cx = fl(cx + 0.5), cy = fl(cy + 0.5), zoom = self.zoom, dy = self:roomDy(), s = s, tw = tw, th = th, k = tw / RoomSpace.TW }
    end
    return { cx = v.cx, cy = v.cy, zoom = v.zoom or 1, dy = v.dy or 0, s = s, tw = tw, th = th, k = tw / RoomSpace.TW }
end

-- The room is lifted so the shelf covers none of it.
function Build:roomDy()
    return -fl(SHELF_H * (self.game.ui_scale or 1) * 0.5)
end

-- A grid point at elevation `elev` (art px) → screen.
function Build:toScreen(gx, gy, elev, m)
    m = m or self:metrics()
    local RoomView = require("views.RoomView")
    local x, y = RoomView.gridToScreen(gx, gy, m.cx, m.cy, m.tw, m.th)
    y = y - (elev or 0) * m.s
    return m.cx + (x - m.cx) * m.zoom, m.cy + m.dy + (y - m.cy) * m.zoom
end

-- Screen → the grid point on the plane at `elev`.
function Build:fromScreen(sx, sy, elev, m)
    m = m or self:metrics()
    local x = m.cx + (sx - m.cx) / m.zoom
    local y = m.cy + (sy - m.cy - m.dy) / m.zoom + (elev or 0) * m.s
    return RoomSpace.artToGrid((x - m.cx) / m.k, (y - m.cy) / m.k)
end

-- Screen → the wall plane: t along the wall (cells), z up it (art px).
function Build:fromScreenWall(sx, sy, plane, m)
    m = m or self:metrics()
    local x = m.cx + (sx - m.cx) / m.zoom
    local y = m.cy + (sy - m.cy - m.dy) / m.zoom
    local ax, ay = (x - m.cx) / m.k, (y - m.cy) / m.k
    if plane == "back" then return ax / (RoomSpace.TW / 2), ax / 2 - ay end
    return -ax / (RoomSpace.TW / 2), -ax / 2 - ay
end

function Build:polyToScreen(poly, elev, m)
    local pts = {}
    for i = 1, #poly, 2 do
        local x, y = self:toScreen(poly[i], poly[i + 1], elev, m)
        pts[#pts + 1] = x; pts[#pts + 1] = y
    end
    return pts
end

function Build:wallToScreen(rect, m)
    local pts = {}
    for _, c in ipairs({ { rect.t0, rect.z0 }, { rect.t1, rect.z0 }, { rect.t1, rect.z1 }, { rect.t0, rect.z1 } }) do
        local gx, gy
        if rect.plane == "back" then gx, gy = c[1], 0 else gx, gy = 0, c[1] end
        local x, y = self:toScreen(gx, gy, c[2], m)
        pts[#pts + 1] = x; pts[#pts + 1] = y
    end
    return pts
end

-- ── The frame: the room's things, described, with their screen polygons ─

function Build:frame()
    local rv = self.rv
    if not rv._resolved then return nil end
    local fr = ES.frame(rv)
    if fr._screen_m then return fr end
    local m = self:metrics()
    fr._screen_m = m
    for _, d in ipairs(fr.descs) do
        d.face_s = d.face and self:polyToScreen(d.face, d.F, m) or nil
        d.foot_s = d.foot and self:polyToScreen(d.foot, d.E, m) or nil
        d.wall_s = d.wall and self:wallToScreen(d.wall, m) or nil
    end
    return fr
end

local function excluded(self, d)
    local h = self.hand
    if not h then return false end
    if d.item.obj.id == h.id then return true end
    return RoomSpace.isDescendant(h.items or {}, d.item.obj.id, h.id)
end

-- What is under the pointer ON SCREEN: the highest top whose drawn face
-- holds the point, else a wall rectangle, else the sprite the old pixel
-- test finds (for selecting faceless things).
function Build:pick(sx, sy)
    local fr = self:frame()
    if not fr then return nil end
    local best
    for _, d in ipairs(fr.descs) do
        if d.face_s and not excluded(self, d) and RoomSpace.pointInPoly(d.face_s, sx, sy, 0) then
            if not best or d.F > best.F then best = d end
        end
    end
    if best then return { desc = best, kind = "top", elev = best.F } end
    for _, d in ipairs(fr.descs) do
        if d.wall_s and not excluded(self, d) and RoomSpace.pointInPoly(d.wall_s, sx, sy, 0) then
            return { desc = d, kind = "wall" }
        end
    end
    local m = self:metrics()
    local zx = m.cx + (sx - m.cx) / m.zoom
    local zy = m.cy + (sy - m.cy - m.dy) / m.zoom
    local obj = self.rv:_hitItem(zx, zy)
    if obj and not (self.hand and obj.id == self.hand.id) then
        return { obj = obj, desc = fr.by_obj[obj], kind = "body" }
    end
    return nil
end

-- ── The hand ───────────────────────────────────────────────────────────

local function fieldsOf(h)
    return { id = h.id, sprite = h.sprite, frame = h.frame, gx = h.gx, gy = h.gy, w = h.w, h = h.h,
             align = h.align, flip_x = h.flip_x, scale = h.scale, dx = h.dx, z_offset = h.z, layer = h.layer }
end

local function isWallThing(self, h)
    if h.align ~= "left_wall" and h.align ~= "right_wall" then return false end
    local e = ES.ctx(self.rv).entryFor(fieldsOf(h), { id = h.id, sprite = h.sprite, frame = h.frame })
    return not (e and e.v == "face")
end

-- Pick a placed thing up by where the mouse holds it.
function Build:beginGrab(obj, sx, sy)
    local rv = self.rv
    if obj.locked then return false end
    local r = rv._resolved and rv._resolved[obj]
    local f = r and r.fields or obj
    local idx
    for i, o in ipairs(rv.placed) do if o == obj then idx = i; break end end
    if not idx then return false end
    self:snapshot()
    local h = {
        kind = "placed", entry = obj, orig_idx = idx, id = obj.id, sprite = obj.sprite, frame = obj.frame,
        w = f.w or 1, h = f.h or 1, align = f.align, flip_x = f.flip_x or false, scale = f.scale or 1,
        dx = f.dx or 0, z = f.z_offset or 0, layer = f.layer or 0, gx = f.gx, gy = f.gy,
        anim_room = obj.anim_room, fps = obj.fps, shader = obj.shader, color = obj.color, sh = obj.sh,
        hidden_when = obj.hidden_when, homes = obj.homes,
    }
    h.sat_on = (r and r.home and r.home > 0 and obj.homes and obj.homes[r.home]) and obj.homes[r.home].on or nil
    h.items = ES.items(rv)
    h.wall = isWallThing(self, h)
    if h.wall then
        local plane = RoomSpace.wallPlaneOf(f) or ((h.align == "left_wall") and "back" or "side")
        local t, z = self:fromScreenWall(sx, sy, plane)
        local anchor_t = (plane == "back") and (f.gx + h.w / 2) or (f.gy + h.h / 2)
        h.plane, h.dt, h.dz = plane, t - anchor_t, z - h.z
    else
        -- the offset from the point under the cursor on the thing's own plane
        local E = RoomSpace.floorElev(f)
        local ux, uy = self:fromScreen(sx, sy, E)
        h.off = { gx = f.gx - ux, gy = f.gy - uy }
        -- the keys' nudge, and how far off its computed rest the thing sat
        -- on the parent it came from (kept only while it is back on it:
        -- a hand-tuned offset there says nothing about another top)
        h.nudge, h.nudge_home = 0, 0
        if h.sat_on then
            local pd = ES.frame(rv).by_obj[self:placedById(h.sat_on)]
            if pd and pd.face then
                local rest = RoomSpace.restZ(pd.f, pd.entry, f)
                if rest then h.nudge_home = (f.z_offset or 0) - rest end
            end
        end
    end
    table.remove(rv.placed, idx)
    rv.picked_item = nil
    self.hand = h
    self.sel = nil
    return true
end

-- A new thing from the shelf (a catalog item already in the room moves).
function Build:beginNew(spec, sx, sy)
    local rv = self.rv
    for _, o in ipairs(rv.placed) do
        if o.id == spec.id then return self:beginGrab(o, sx, sy) end
    end
    self:snapshot()
    local h = {
        kind = "new", spec = spec, id = spec.id, sprite = spec.sprite or spec.id, frame = spec.frame,
        w = 1, h = 1, align = nil, flip_x = false, scale = 1, dx = 0, z = 0, layer = 0,
        anim_room = nil, color = { 1, 1, 1 }, sh = 16,
    }
    h.items = ES.items(rv)
    h.wall = false
    h.off = { gx = -0.5, gy = -0.5 }
    h.nudge = 0
    self.hand = h
    self.sel = nil
    return true
end

function Build:placedById(id)
    for _, o in ipairs(self.rv.placed) do if o.id == id then return o end end
    return nil
end

-- Where the hand is for this pointer: the target under it, the thing's
-- origin on that target's plane, pushed out of its neighbours and into
-- the room; the fit that results. Called every frame while something
-- is in hand.
function Build:updateHand(sx, sy)
    local h = self.hand
    if not h then self.target, self.fit = nil, nil; return end
    local rv = self.rv
    local fr = self:frame()
    local ctx = ES.ctx(rv)
    local items = h.items
    local descs = fr and fr.descs or RoomSpace.describeAll(items, ctx)
    local room = rv.room_size or 5
    local step = self.grid_snap and 0.25 or 0.125
    local function snap(v) return fl(v / step + 0.5) * step end
    local target = self:pick(sx, sy)
    if target and target.kind == "body" then target = nil end
    self.target = target
    local opts = { room_size = room, auto_z = true, z_nudge = h.nudge or 0, descs = descs }
    if h.wall then
        -- which wall: the one the pointer is near, else the one it came from
        local rx, ry = self:fromScreen(sx, sy, 0)
        local plane = h.plane
        if ry <= WALL_NEAR and rx > WALL_NEAR then plane = "back" elseif rx <= WALL_NEAR and ry > WALL_NEAR then plane = "side" end
        if plane ~= h.plane then
            h.plane = plane
            h.align = (plane == "back") and "left_wall" or "right_wall"
            local t, z = self:fromScreenWall(sx, sy, plane)
            h.dt, h.dz = 0, z - h.z
        end
        local t, z = self:fromScreenWall(sx, sy, plane)
        local at = snap(t - h.dt)
        h.z = fl(z - h.dz + 0.5)
        if plane == "back" then h.gx, h.gy = at - h.w / 2, 0 else h.gx, h.gy = 0, at - h.h / 2 end
        local hf = fieldsOf(h)
        self.fit = RoomSpace.fit(hf, items, ctx, opts)
        -- slide along the wall out of a neighbour
        for _ = 1, 3 do
            local d = self.fit.overlaps[1]
            if not (d and d.wall and self.fit.wall) then break end
            local a, b = self.fit.wall, d.wall
            local left, right = a.t1 - b.t0, b.t1 - a.t0
            local push = (left < right) and -left or right
            if plane == "back" then h.gx = h.gx + push else h.gy = h.gy + push end
            self.fit = RoomSpace.fit(fieldsOf(h), items, ctx, opts)
        end
        self.fit.gx, self.fit.gy = h.gx, h.gy
        return
    end
    -- a floor thing: on the top under the pointer, else the floor
    local elev = (target and target.kind == "top") and target.elev or 0
    local ux, uy = self:fromScreen(sx, sy, elev)
    local gx, gy = ux + h.off.gx, uy + h.off.gy
    if self.grid_snap then gx, gy = snap(gx), snap(gy) end
    -- the walls stop it
    gx = math.max(0, math.min(room - h.w, gx))
    gy = math.max(0, math.min(room - h.h, gy))
    h.gx, h.gy = gx, gy
    local fit
    local function refit() fit = RoomSpace.fit(fieldsOf(h), items, ctx, opts) end
    local function clampTo(x, y)
        h.gx = math.max(0, math.min(room - h.w, x))
        h.gy = math.max(0, math.min(room - h.h, y))
    end
    refit()
    -- the top the pointer is on is where the thing goes: a foot that
    -- missed its edge snaps inside; one hanging off its parent likewise
    local want = (target and target.kind == "top") and target.desc or nil
    local function keepOn(face, reach)
        if not (face and fit.foot) then return end
        local dx, dy = RoomSpace.nudgeInside(fit.foot, face, reach, RoomSpace.INSIDE_TOL)
        if dx then clampTo(h.gx + dx, h.gy + dy); refit() end
    end
    if want and fit.parent ~= want then keepOn(want.face, SNAP_IN)
    elseif fit.status == "overhang" and fit.parent then keepOn(fit.parent.face, SNAP_IN) end
    -- refuse to go inside a neighbour: slide out of it along the way,
    -- up to a point, and never off the top it is aimed at (there it
    -- stays where it is, crossing, and shows red)
    local slid = 0
    for _ = 1, 4 do
        local d = fit.overlaps[1]
        if not (d and d.foot and fit.foot) then break end
        local dx, dy = RoomSpace.separate(fit.foot, d.foot)
        if not dx then break end
        local len = math.sqrt(dx * dx + dy * dy)
        if slid + len > SLIDE_MAX then break end
        local ogx, ogy = h.gx, h.gy
        clampTo(h.gx + dx, h.gy + dy)
        refit()
        if want and fit.parent ~= want then
            keepOn(want.face, SLIDE_MAX)
            if fit.parent ~= want then clampTo(ogx, ogy); refit() end
            break
        end
        slid = slid + len
    end
    fit.gx, fit.gy = h.gx, h.gy
    if fit.parent then
        if h.sat_on and fit.parent.item.obj.id == h.sat_on then fit.z = fit.z + (h.nudge_home or 0) end
        h.z = fit.z
        h.layer_out = math.max(h.layer or 0, (fit.parent.f.layer or 0) + 1)
    else
        h.z = (h.kind == "placed" and not h.sat_on) and h.z or 0
        if h.sat_on and not fit.parent then h.z = 0 end
        fit.z = h.z
        h.layer_out = h.layer or 0
    end
    self.fit = fit
end

-- Put the hand back where it came from.
function Build:cancel()
    local h = self.hand
    if not h then return false end
    if h.kind == "placed" then
        table.insert(self.rv.placed, math.min(h.orig_idx, #self.rv.placed + 1), h.entry)
        self.sel = h.entry
    end
    self.hand, self.fit, self.target = nil, nil, nil
    self.undo[#self.undo] = nil      -- the snapshot taken at the grab is moot
    return true
end

-- Drop the hand where it is: a home on the top it sits on, else the base.
function Build:drop()
    local h, fit = self.hand, self.fit
    if not h then return false end
    local rv = self.rv
    if not fit or fit.status == "off_room" then return self:cancel() end
    local placement = { gx = h.gx, gy = h.gy, z_offset = fl((h.z or 0) + 0.5), dx = h.dx or 0,
                        layer = h.layer_out or h.layer or 0, align = h.align or "center",
                        flip_x = h.flip_x or false, scale = h.scale or 1 }
    local entry = h.entry
    if h.kind == "new" then
        local taken = {}
        for _, o in ipairs(rv.placed) do taken[o.id] = true end
        local id, n = h.id, 2
        local is_catalog = rv.catalog_by_id and rv.catalog_by_id[h.id] ~= nil
        while taken[id] and not is_catalog do id = h.id .. "_" .. n; n = n + 1 end
        entry = { id = id, sprite = h.sprite ~= id and h.sprite or nil, w = h.w, h = h.h, sh = h.sh or 16,
                  color = { 1, 1, 1 }, anim_room = h.anim_room, frame = h.frame }
        h.orig_idx = #rv.placed + 1
    end
    table.insert(rv.placed, math.min(h.orig_idx or (#rv.placed + 1), #rv.placed + 1), entry)
    entry.w, entry.h = h.w, h.h
    local res_all = RoomPlacement.resolveAll(rv.placed, rv:_resolveSet({}))
    local r = res_all[entry]
    if fit.parent then
        local parent = fit.parent.item.obj
        local pres = res_all[parent]
        if pres then
            local world = {}
            for k, v in pairs(r and r.fields or entry) do world[k] = v end
            for k, v in pairs(placement) do world[k] = v end
            world.w, world.h = h.w, h.h
            RoomPlacement.setHome(entry, parent.id, world, pres.fields)
            local idx
            for i, hm in ipairs(entry.homes) do if hm.on == parent.id then idx = i end end
            while idx and idx > 1 do RoomPlacement.moveHome(entry, idx, -1); idx = idx - 1 end
            print(string.format("[build] %s sits on %s", entry.id, parent.id))
        end
    elseif h.sat_on and r and r.home and r.home > 0 and entry.homes and entry.homes[r.home]
           and entry.homes[r.home].on == h.sat_on then
        RoomPlacement.removeHome(entry, r.home)
        RoomPlacement.writePlacement(entry, nil, nil, placement)
        print(string.format("[build] %s is off %s", entry.id, h.sat_on))
    else
        rv:_writePlacement(entry, placement)
    end
    self.sel = entry
    self.hand, self.fit, self.target = nil, nil, nil
    rv.sel_placed = entry
    return true
end

-- ── Undo ───────────────────────────────────────────────────────────────

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

function Build:snapshot()
    local u = self.undo
    u[#u + 1] = deepcopy(self.rv.placed)
    if #u > 60 then table.remove(u, 1) end
    self.redo = {}
end

function Build:_restore(list)
    self.rv.placed = list
    self.rv._render_list, self.rv._render_rev = nil, nil
    self.sel, self.hand, self.fit = nil, nil, nil
end

function Build:undoStep()
    local u = self.undo
    if #u == 0 then return false end
    self.redo[#self.redo + 1] = deepcopy(self.rv.placed)
    self:_restore(table.remove(u))
    return true
end

function Build:redoStep()
    local r = self.redo
    if #r == 0 then return false end
    self.undo[#self.undo + 1] = deepcopy(self.rv.placed)
    self:_restore(table.remove(r))
    return true
end

-- ── Selection edits ────────────────────────────────────────────────────

function Build:edit(fn)
    local o = self.sel
    if not o then return false end
    self:snapshot()
    fn(o)
    self.rv._render_list, self.rv._render_rev = nil, nil
    return true
end

function Build:deleteSel()
    local o = self.sel
    if not o then return false end
    self:snapshot()
    for i, p in ipairs(self.rv.placed) do if p == o then table.remove(self.rv.placed, i); break end end
    self.sel = nil
    return true
end

function Build:duplicateSel()
    local o = self.sel
    if not o then return false end
    self:snapshot()
    local c = deepcopy(o)
    local taken = {}
    for _, p in ipairs(self.rv.placed) do taken[p.id] = true end
    local base = o.id:match("^(.-)_%d+$") or o.id
    local n = 2
    c.id = base .. "_" .. n
    while taken[c.id] do n = n + 1; c.id = base .. "_" .. n end
    c.sprite = c.sprite or (o.sprite or base)
    c.gx, c.gy = (c.gx or 0) + 0.5, (c.gy or 0) + 0.5
    c.homes = nil
    self.rv.placed[#self.rv.placed + 1] = c
    self.sel = c
    return true
end

-- ── The shelf ──────────────────────────────────────────────────────────

function Build:shelfItems()
    local rv = self.rv
    local out = {}
    local want_catalog = self.shelf_tab == 1
    local filter = self.filter:lower()
    for i, spec in ipairs(rv.placeable or {}) do
        local g = rv.group_of and rv.group_of[i]
        local is_catalog = g and g.is_catalog
        if (want_catalog and is_catalog) or (not want_catalog and not is_catalog) then
            local name = (spec.name or spec.id):lower()
            if filter == "" or name:find(filter, 1, true) or (spec.id or ""):lower():find(filter, 1, true) then
                out[#out + 1] = spec
            end
        end
    end
    return out
end

function Build:shelfRect(W, H)
    local s = self.game.ui_scale or 1
    return { x = 0, y = H - fl(SHELF_H * s), w = W, h = fl(SHELF_H * s) }
end

function Build:drawShelf(W, H)
    local s = self.game.ui_scale or 1
    local fonts = self.game.fonts
    local R = self:shelfRect(W, H)
    Theme.setColor(Theme.bg.chrome, 0.96)
    love.graphics.rectangle("fill", R.x, R.y, R.w, R.h)
    Theme.setColor(Theme.border.soft)
    love.graphics.line(R.x, R.y, R.x + R.w, R.y)
    -- tabs and the filter
    local mx, my = love.mouse.getPosition()
    local tx = R.x + fl(10 * s)
    self._shelf_tabs = {}
    for i, label in ipairs({ "CATALOG", "FLAVOUR" }) do
        local r = { x = tx, y = R.y + fl(6 * s), w = fl(84 * s), h = fl(22 * s) }
        LabelButton.draw{ x = r.x, y = r.y, w = r.w, h = r.h, text = label, fonts = fonts, font = fonts.sm,
            hovered = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h,
            fill_token = (self.shelf_tab == i) and Theme.bg.widget_hover or Theme.bg.sunken }
        self._shelf_tabs[i] = r
        tx = tx + r.w + fl(6 * s)
    end
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(self.filter ~= "" and ("filter: " .. self.filter .. "_") or "type to filter", tx + fl(8 * s), R.y + fl(10 * s))
    -- the thumbnails, in a row, scrolled
    local items = self:shelfItems()
    local cell = fl(CELL * s)
    local y0 = R.y + fl(32 * s)
    local x0 = R.x + fl(10 * s) - self.shelf_scroll
    self._shelf_cells = {}
    local loader = self.game.sprite_loader
    love.graphics.setScissor(R.x, y0, R.w, R.h - fl(32 * s))
    for i, spec in ipairs(items) do
        local cx_ = x0 + (i - 1) * (cell + fl(4 * s))
        if cx_ + cell >= 0 and cx_ <= W then
            local r = { x = cx_, y = y0, w = cell, h = cell - fl(4 * s), spec = spec }
            local hov = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
            Theme.setColor(hov and Theme.bg.widget_hover or Theme.bg.sunken)
            love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 3)
            local sprite = loader and loader.getSprite and loader:getSprite(spec.sprite or spec.id, false, nil, spec.frame)
            if sprite then
                local sw, sh = sprite:getWidth(), sprite:getHeight()
                local k = math.min((cell - fl(12 * s)) / sw, (cell - fl(24 * s)) / sh)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(sprite, r.x + r.w / 2, r.y + fl(4 * s) + (cell - fl(24 * s)) / 2, 0, k, k, sw / 2, sh / 2)
            end
            Theme.setColor(Theme.fg.primary)
            love.graphics.setFont(fonts.xs or fonts.sm)
            local label = spec.name or spec.id
            local f = fonts.xs or fonts.sm
            while f:getWidth(label) > r.w - 4 and #label > 3 do label = label:sub(1, -3) end
            love.graphics.print(label, r.x + 2, r.y + r.h - f:getHeight() - 2)
            self._shelf_cells[#self._shelf_cells + 1] = r
        end
    end
    love.graphics.setScissor()
    self._shelf_count = #items
end

function Build:shelfCellAt(x, y)
    for _, r in ipairs(self._shelf_cells or {}) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r end
    end
    return nil
end

-- ── Drawing ────────────────────────────────────────────────────────────

local function poly(pts, token, fill_a, line_a)
    if fill_a and fill_a > 0 then Theme.setColor(token, fill_a); love.graphics.polygon("fill", pts) end
    Theme.setColor(token, line_a or 1)
    love.graphics.polygon("line", pts)
end

function Build:draw(W, H)
    local rv = self.rv
    local s = self.game.ui_scale or 1
    local fonts = self.game.fonts
    local mx, my = love.mouse.getPosition()
    -- the room, with the hand's children riding
    local hand_entry
    if self.hand then
        self:updateHand(mx, my)
        local h = self.hand
        hand_entry = fieldsOf(h)
        hand_entry.z_offset = h.z
        hand_entry.homes = nil
    end
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)
    rv.zoom = self.zoom
    rv:draw(true, { lighting = { fixture = 1, emitters = true }, zoom = self.zoom, dy = self:roomDy(), hand_entry = hand_entry })
    if self.hand then self:updateHand(mx, my) end   -- against this frame's resolve
    local fr = self:frame()
    local m = self:metrics()
    love.graphics.setLineWidth(math.max(1, fl(2 * s)))
    if fr then
        local in_clash = {}
        for _, cl in ipairs(fr.clashes) do in_clash[cl.a] = true; in_clash[cl.b] = true end
        local t = self.target
        for _, d in ipairs(fr.descs) do
            local is_target = t and t.desc == d
            local is_sel = self.sel == d.item.obj
            if d.wall_s then
                poly(d.wall_s, in_clash[d] and Theme.status.error or (is_target and Theme.sem.chip or Theme.sem.tilt),
                     in_clash[d] and 0.25 or (is_target and 0.3 or 0.06), is_sel and 1 or 0.6)
            elseif d.foot_s and d.foot then
                local cxg, cyg = RoomSpace.centroid(d.foot)
                if cxg >= -0.5 and cyg >= -0.5 and cxg <= (rv.room_size or 5) + 0.5 and cyg <= (rv.room_size or 5) + 0.5 then
                    poly(d.foot_s, in_clash[d] and Theme.status.error or Theme.status.good, in_clash[d] and 0.25 or 0.05, is_sel and 1 or 0.45)
                    if d.face_s then
                        poly(d.face_s, is_target and Theme.sem.chip or Theme.fg.heading, is_target and 0.35 or 0.04, is_target and 1 or 0.4)
                    end
                end
            end
        end
    end
    -- the hand: its foot (a shadow, the front corner marked) and the sprite
    if self.hand and self.fit then
        local h, fit = self.hand, self.fit
        local bad = fit.status == "off_room" or fit.status == "overhang" or #fit.overlaps > 0 or fit.over_wall
        local token = bad and Theme.status.error or Theme.status.good
        if fit.wall then
            poly(self:wallToScreen(fit.wall, m), token, 0.3, 1)
        elseif fit.foot then
            local E = RoomSpace.floorElev(fieldsOf(h))
            local pts = self:polyToScreen(fit.foot, E, m)
            Theme.setColor({ 0, 0, 0 }, 0.5); love.graphics.polygon("fill", pts)
            poly(pts, token, 0.35, 1)
            love.graphics.circle("fill", pts[5], pts[6], math.max(2, 3 * s))
        end
        self:drawHandSprite(h, m)
    end
    love.graphics.setLineWidth(1)
    -- the hover glow for a body under the pointer (not while dragging)
    if not self.hand then
        local p = self:pick(mx, my)
        self.hover = p and (p.obj or (p.desc and p.desc.item.obj)) or nil
        rv.hover_placed = self.hover
        rv.sel_placed = self.sel
    end
    self:drawShelf(W, H)
    self:drawHud(W, H)
end

function Build:drawHandSprite(h, m)
    local rv = self.rv
    local loader = self.game.sprite_loader
    local sprite = loader and loader.getSprite and loader:getSprite(h.sprite or h.id, false, nil, h.frame)
    if not sprite then return end
    local RoomView = require("views.RoomView")
    local f = fieldsOf(h)
    local fr = RoomPlacement.frameOf(f)
    local sx, sy = self:toScreen(fr.ax, fr.ay, 0, m)
    local scale = (h.scale or 1) * m.s * m.zoom
    local ox = sprite:getWidth() * 0.5
    local oy = RoomView.getSpriteBottom(sprite, h.sprite or h.id) - RoomSpace.diffY(f)
    local px = sx + (h.dx or 0) * m.s * m.zoom
    local py = sy - (h.z or 0) * m.s * m.zoom
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(sprite, px, py, 0, h.flip_x and -scale or scale, scale, ox, oy)
end

function Build:drawHud(W, H)
    local s = self.game.ui_scale or 1
    local fonts = self.game.fonts
    local fr = self:frame()
    local n_clash = fr and #fr.clashes or 0
    love.graphics.setFont(fonts.sm)
    local line = string.format("BUILD  ·  %d things  ·  %d clash%s  ·  grid %s (G)  ·  zoom %.1f (Ctrl+wheel)  ·  [H] keys  ·  Enter export  ·  F3 leave",
        #self.rv.placed, n_clash, n_clash == 1 and "" or "es", self.grid_snap and "ON" or "off", self.zoom)
    Theme.setColor(Theme.bg.chrome, 0.9)
    love.graphics.rectangle("fill", 0, 0, W, fl(26 * s))
    Theme.setColor(n_clash > 0 and Theme.sem.chip or Theme.fg.primary)
    love.graphics.print(line, fl(10 * s), fl(6 * s))
    -- the selection card
    local o = self.sel
    if o and not self.hand then
        local rr = self.rv._resolved and self.rv._resolved[o]
        local f = rr and rr.fields or o
        local on = (rr and rr.home and rr.home > 0 and o.homes and o.homes[rr.home]) and o.homes[rr.home].on or "the floor"
        local rows = {
            o.id,
            string.format("on %s  ·  z %d  ·  layer %d", on, f.z_offset or 0, f.layer or 0),
            string.format("%s%.2f  ·  %s  ·  %s%s", "scale ", f.scale or 1, f.flip_x and "flipped" or "unflipped",
                f.align and f.align ~= "center" and f.align or "floor", o.frame and ("  ·  frame " .. o.frame) or ""),
            "Delete  Ctrl+D copy  R flip  Z/X layer  [ ] frame  wheel scale  7/8 height",
        }
        local cw = 0
        for _, r in ipairs(rows) do cw = math.max(cw, fonts.sm:getWidth(r)) end
        local cx_, cy_ = fl(10 * s), fl(34 * s)
        Theme.setColor(Theme.bg.chrome, 0.94)
        love.graphics.rectangle("fill", cx_, cy_, cw + fl(16 * s), #rows * (fonts.sm:getHeight() + 2) + fl(12 * s), 4)
        for i, r in ipairs(rows) do
            Theme.setColor(i == 1 and Theme.sem.chip or (i == #rows and Theme.fg.muted or Theme.fg.primary))
            love.graphics.print(r, cx_ + fl(8 * s), cy_ + fl(6 * s) + (i - 1) * (fonts.sm:getHeight() + 2))
        end
    end
    if self.show_help then
        local x, y = fl(10 * s), fl(140 * s)
        Theme.setColor(Theme.bg.chrome, 0.94)
        love.graphics.rectangle("fill", x, y, fl(620 * s), (#self.help_lines + 1) * (fonts.sm:getHeight() + 3) + fl(12 * s), 4)
        Theme.setColor(Theme.sem.chip)
        love.graphics.print("BUILD KEYS [H]", x + fl(8 * s), y + fl(6 * s))
        Theme.setColor(Theme.fg.primary)
        for i, l in ipairs(self.help_lines) do
            love.graphics.print("• " .. l, x + fl(8 * s), y + fl(6 * s) + i * (fonts.sm:getHeight() + 3))
        end
    end
end

-- ── Input ──────────────────────────────────────────────────────────────

function Build:mousepressed(x, y, button)
    local W, H = love.graphics.getDimensions()
    if button ~= 1 then
        if button == 2 and self.hand then self:cancel() end
        return true
    end
    -- the shelf
    local R = self:shelfRect(W, H)
    if y >= R.y then
        for i, r in ipairs(self._shelf_tabs or {}) do
            if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then self.shelf_tab = i; self.shelf_scroll = 0; return true end
        end
        local cell = self:shelfCellAt(x, y)
        if cell then self.press = { x = x, y = y, spec = cell.spec, moved = false } end
        return true
    end
    if y < fl(26 * (self.game.ui_scale or 1)) then return true end
    if self.hand then
        self:drop()
        return true
    end
    local p = self:pick(x, y)
    local obj = p and (p.obj or (p.desc and p.desc.item.obj)) or nil
    self.press = { x = x, y = y, obj = obj, moved = false }
    return true
end

function Build:mousemoved(x, y)
    local p = self.press
    if p and not p.moved and (math.abs(x - p.x) > DRAG_PX or math.abs(y - p.y) > DRAG_PX) then
        p.moved = true
        if p.spec then
            self:beginNew(p.spec, x, y)
        elseif p.obj then
            self:beginGrab(p.obj, p.x, p.y)
        end
    end
    return true
end

function Build:mousereleased(x, y, button)
    if button ~= 1 then return true end
    local p = self.press
    self.press = nil
    if self.hand then
        local W, H = love.graphics.getDimensions()
        if x < 0 or y < 0 or y >= self:shelfRect(W, H).y then self:cancel() else self:drop() end
        return true
    end
    if p and not p.moved then
        self.sel = p.obj
        self.rv.sel_placed = p.obj
    end
    return true
end

function Build:wheelmoved(dy, x, y)
    local W, H = love.graphics.getDimensions()
    if love.keyboard.isDown("lctrl", "rctrl") then
        self.zoom = math.max(0.75, math.min(4, self.zoom * (dy > 0 and 1.15 or 1 / 1.15)))
        return true
    end
    if y >= self:shelfRect(W, H).y then
        local s = self.game.ui_scale or 1
        local max = math.max(0, (self._shelf_count or 0) * fl((CELL + 4) * s) - W + fl(20 * s))
        self.shelf_scroll = math.max(0, math.min(max, self.shelf_scroll - dy * fl(60 * s)))
        return true
    end
    if self.sel and not self.hand then
        self:edit(function(o) o.scale = math.max(0.1, math.min(3, (o.scale or 1) + (dy > 0 and 0.05 or -0.05))) end)
        return true
    end
    return false
end

function Build:keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if key == "escape" then
        if self.hand then self:cancel() return true end
        if self.filter ~= "" then self.filter = ""; return true end
        if self.sel then self.sel = nil; self.rv.sel_placed = nil; return true end
        return false
    end
    if key == "h" and not ctrl then self.show_help = not self.show_help; return true end
    if key == "g" then self.grid_snap = not self.grid_snap; return true end
    if key == "tab" then self.shelf_tab = 3 - self.shelf_tab; self.shelf_scroll = 0; return true end
    if key == "return" or key == "kpenter" then self.rv:serializeLayout(); return true end
    if ctrl and key == "z" then self:undoStep(); return true end
    if ctrl and key == "y" then self:redoStep(); return true end
    if ctrl and key == "d" then self:duplicateSel(); return true end
    if key == "backspace" then self.filter = self.filter:sub(1, -2); return true end
    if key == "delete" then self:deleteSel(); return true end
    if self.hand then
        local h = self.hand
        if key == "7" or key == "8" then
            local d = (key == "8") and 4 or -4
            if h.wall then h.dz = h.dz - d else h.nudge = (h.nudge or 0) + d end
            return true
        end
        if key == "r" then h.flip_x = not h.flip_x; return true end
        return true
    end
    if self.sel then
        if key == "r" then return self:edit(function(o) o.flip_x = not o.flip_x end) end
        if key == "z" then return self:edit(function(o) self.rv:setLayer(o, self.rv:layerOf(o) + 1) end) end
        if key == "x" then return self:edit(function(o) self.rv:setLayer(o, self.rv:layerOf(o) - 1) end) end
        if key == "7" or key == "8" then
            local d = (key == "8") and 4 or -4
            return self:edit(function(o)
                local rr = self.rv._resolved and self.rv._resolved[o]
                local z = (rr and rr.fields.z_offset or o.z_offset or 0) + d
                self.rv:_writePlacement(o, { z_offset = z })
            end)
        end
        if key == "[" or key == "]" then
            return self:edit(function(o)
                local n = (o.frame or 1) + (key == "]" and 1 or -1)
                o.frame = n >= 1 and n or nil
            end)
        end
    end
    return false
end

function Build:textinput(text)
    if text:match("^[%w _%-]$") and not self.hand then
        self.filter = self.filter .. text
        self.shelf_scroll = 0
        return true
    end
    return false
end

return Build
