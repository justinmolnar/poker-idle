-- models/room_space.lua
--
-- The room as SPACE: where each placed thing's footprint lies on the floor
-- (or on the thing under it), where its top face is, and how high. Built
-- from the per-sprite surfaces (data/room_surfaces.lua, read through
-- services/RoomSurfaces) and the way views/RoomView draws a sprite, so a
-- polygon here lands exactly where the pixels do.
--
-- Everything is a pure function over RESOLVED placement fields
-- (gx, gy, w, h, align, flip_x, scale, dx, z_offset — what
-- models/room_placement resolves) plus two callbacks the caller supplies:
--   ctx.entryFor(f)        -> the surfaces entry for the object, or nil
--   ctx.geomFor(f, entry)  -> { cell_w, bottom } of its drawn sprite
-- so the model never sees a loader or an Image; the tests pass tables.
--
-- UNITS. Grid: one tile is TW x TH art pixels (64 x 32 at ui scale 1):
--   gridToArt(gx, gy) = ((gx - gy) * 32, (gx + gy) * 16)
-- A sprite is drawn with its centre column on the item's anchor and its
-- lowest opaque row `diffY` sprite pixels below the anchor at scale 1
-- (RoomView draws oy = bottom - diffY, diffY = (w + h) * 8 or w * 8 /
-- h * 8 on a wall), lifted by z_offset art px. z_offset and dx are art
-- px at scale 1 and are NOT scaled by the item; the sprite is. So the
-- plane the sprite's bottom row sits on is
--   E(f) = z_offset + diffY * (1 - scale)        -- the floor elevation
-- (at scale 1 just z_offset; at scale 0.7 the bottom floats a little
-- above the front vertex — a renderer quirk this model absorbs rather
-- than moving every placed item), and the top face's plane is
--   F(f, entry) = E(f) + entry.height * scale
-- A sprite pixel (u, v) at elevation `elev` lands on the grid at
--   anchor + artToGrid(dx + (u - cell_w/2) * scale * Hflip,
--                     -z_offset + (v - (bottom - diffY)) * scale + elev)
-- and z_offset cancels for a polygon drawn at its own plane: the plan-view
-- polygons depend only on where the thing sits, elevation is a scalar.
-- Fit is therefore a 2-D polygon test plus a 1-D level compare.

local RoomPlacement = require("models.room_placement")

local RoomSpace = {}

RoomSpace.TW, RoomSpace.TH = 64, 32
RoomSpace.LEVEL_EPS  = 8      -- art px: two planes this close are "the same level"
RoomSpace.INSIDE_TOL = 0.03   -- grid units: pixel-derived corners are noisy
RoomSpace.WALL_TOL   = 0.125  -- grid: an anchor this close to a wall line is on the wall
RoomSpace.WALL_TOUCH = 0.15   -- grid: a floor foot this close to the line touches the wall

-- ── Projection ──────────────────────────────────────────────────────────

function RoomSpace.gridToArt(gx, gy)
    return (gx - gy) * (RoomSpace.TW / 2), (gx + gy) * (RoomSpace.TH / 2)
end

function RoomSpace.artToGrid(x, y)
    local a, b = x / (RoomSpace.TW / 2), y / (RoomSpace.TH / 2)
    return (a + b) / 2, (b - a) / 2
end

function RoomSpace.diffY(f)
    local w, h = f.w or 1, f.h or 1
    if f.align == "left_wall"  then return w * 8 end
    if f.align == "right_wall" then return h * 8 end
    return (w + h) * 8
end

-- ── Walls ───────────────────────────────────────────────────────────────
--
-- A wall-mounted thing lives on a WALL PLANE, not the floor. "left_wall"
-- is the gy = 0 wall (it runs down-right on screen, the screen's right;
-- the kit's Wall_R tile), "right_wall" the gx = 0 wall (down-left, the
-- screen's left). The align alone does not say a thing is on a wall (a
-- pillow can be left_wall-aligned on a bed), and a child's resolved align
-- can name the other wall after its parent's mirror, so the plane is
-- read from the RESOLVED ANCHOR: on the gy = 0 line → back, on gx = 0 →
-- side. Along the wall the coordinate is t (gx on the back wall, gy on
-- the side wall), up it z in art px. The kit shears wall art at the wall's
-- own slope (1/2), so a sprite's silhouette box maps to an axis-aligned
-- rectangle [t0, t1] x [z0, z1] on the plane.

-- `entry` (the surfaces entry, optional): a thing with a top FACE is a
-- floor thing however it is aligned — a box pushed against the wall has
-- its anchor on the line too.
function RoomSpace.wallPlaneOf(f, entry)
    if f.align ~= "left_wall" and f.align ~= "right_wall" then return nil end
    if entry and entry.v == "face" then return nil end
    local fr = RoomPlacement.frameOf(f)
    if math.abs(fr.ay) <= RoomSpace.WALL_TOL then return "back" end
    if math.abs(fr.ax) <= RoomSpace.WALL_TOL then return "side" end
    return nil
end

-- The sprite's silhouette box (entry.bbox = { l, t, r, b }, inclusive px;
-- the whole cell without it) on its wall plane. The pixel → art offsets
-- are the ones spriteToGrid uses; on the plane a point (t, z) sits at
--   back: X = (t − ax)·32, Y = (t − ax)·16 − z     → t = ax + X/32, z = X/2 − Y
--   side: X = −(t − ay)·32, Y = (t − ay)·16 − z    → t = ay − X/32, z = −X/2 − Y
function RoomSpace.wallRect(f, entry, geom)
    local plane = RoomSpace.wallPlaneOf(f, entry)
    if not (plane and geom) then return nil end
    local bb = (entry and entry.bbox) or { 0, 0, geom.cell_w - 1, geom.bottom - 1 }
    local fr = RoomPlacement.frameOf(f)
    local sc, hf = f.scale or 1, (f.flip_x and -1 or 1)
    local HW = RoomSpace.TW / 2
    local oy = geom.bottom - RoomSpace.diffY(f)
    local xa = (f.dx or 0) + (bb[1]     - geom.cell_w / 2) * sc * hf
    local xb = (f.dx or 0) + (bb[3] + 1 - geom.cell_w / 2) * sc * hf
    if xa > xb then xa, xb = xb, xa end
    local ya = -(f.z_offset or 0) + (bb[2]     - oy) * sc
    local yb = -(f.z_offset or 0) + (bb[4] + 1 - oy) * sc
    local r = { plane = plane }
    if plane == "back" then
        r.t0, r.t1 = fr.ax + xa / HW, fr.ax + xb / HW
        r.z1, r.z0 = xa / 2 - ya, xb / 2 - yb
    else
        r.t0, r.t1 = fr.ay - xb / HW, fr.ay - xa / HW
        r.z1, r.z0 = -xb / 2 - ya, -xa / 2 - yb
    end
    if r.z0 > r.z1 then r.z0, r.z1 = r.z1, r.z0 end
    return r
end

local function rectsOverlap(a, b, eps)
    eps = eps or 1e-6
    return a.t0 < b.t1 - eps and b.t0 < a.t1 - eps and a.z0 < b.z1 - eps and b.z0 < a.z1 - eps
end
RoomSpace.rectsOverlap = rectsOverlap

function RoomSpace.floorElev(f)
    return (f.z_offset or 0) + RoomSpace.diffY(f) * (1 - (f.scale or 1))
end

function RoomSpace.faceElev(f, entry)
    if not (entry and entry.v == "face" and entry.height) then return nil end
    return RoomSpace.floorElev(f) + entry.height * (f.scale or 1)
end

-- A sprite pixel to a grid point, at elevation `elev`.
function RoomSpace.spriteToGrid(f, geom, u, v, elev)
    local frame = RoomPlacement.frameOf(f)
    local scale = f.scale or 1
    local hf = f.flip_x and -1 or 1
    local x = (f.dx or 0) + (u - geom.cell_w / 2) * scale * hf
    local y = -(f.z_offset or 0) + (v - (geom.bottom - RoomSpace.diffY(f))) * scale + elev
    local ex, ey = RoomSpace.artToGrid(x, y)
    return frame.ax + ex, frame.ay + ey
end

local function cornersToPoly(f, geom, list, elev)
    -- list: { Tx,Ty, Lx,Ly, Bx,By, Rx,Ry } -> T, R, B, L (clockwise on screen)
    local order = { 1, 7, 5, 3 }
    local poly = {}
    for _, i in ipairs(order) do
        local gx, gy = RoomSpace.spriteToGrid(f, geom, list[i] + 0.5, list[i + 1] + 0.5, elev)
        poly[#poly + 1] = gx; poly[#poly + 1] = gy
    end
    return poly
end

-- The footprint on its plane: the surfaces' foot, else the w x h rectangle.
function RoomSpace.footPoly(f, entry, geom)
    if RoomSpace.wallPlaneOf(f, entry) then return nil end     -- a wall thing has no floor foot
    if entry and entry.foot and geom then
        return cornersToPoly(f, geom, entry.foot, RoomSpace.floorElev(f))
    end
    local w, h = f.w or 1, f.h or 1
    return { f.gx, f.gy, f.gx + w, f.gy, f.gx + w, f.gy + h, f.gx, f.gy + h }
end

function RoomSpace.facePoly(f, entry, geom)
    local F = RoomSpace.faceElev(f, entry)
    if not (F and entry.face and geom) then return nil end
    return cornersToPoly(f, geom, entry.face, F)
end

-- ── Polygons (convex quads) ─────────────────────────────────────────────

function RoomSpace.centroid(poly)
    local n = #poly / 2
    local sx, sy = 0, 0
    for i = 1, #poly, 2 do sx = sx + poly[i]; sy = sy + poly[i + 1] end
    return sx / n, sy / n
end

local function cross(ax, ay, bx, by, px, py)
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
end

-- Inside (or within `tol` of an edge) for either winding.
function RoomSpace.pointInPoly(poly, px, py, tol)
    tol = tol or 0
    local n = #poly / 2
    local sign = 0
    for i = 1, n do
        local ax, ay = poly[i * 2 - 1], poly[i * 2]
        local j = (i % n) + 1
        local bx, by = poly[j * 2 - 1], poly[j * 2]
        local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        local c = cross(ax, ay, bx, by, px, py) / (len > 0 and len or 1)   -- signed distance
        if c < -tol then
            if sign > 0 then return false end
            sign = -1
        elseif c > tol then
            if sign < 0 then return false end
            sign = 1
        end
    end
    return true
end

function RoomSpace.polyInside(inner, outer, tol)
    for i = 1, #inner, 2 do
        if not RoomSpace.pointInPoly(outer, inner[i], inner[i + 1], tol) then return false end
    end
    return true
end

-- The smallest shift (dx, dy) that moves `inner` inside `outer` (both
-- convex quads), or nil when it is already inside or would take more
-- than `max_shift`: for every edge of the outer quad, how far the inner
-- quad sticks out past it, pushed back along the edge's inward normal.
function RoomSpace.nudgeInside(inner, outer, max_shift, tol)
    tol = tol or 0
    local n = #outer / 2
    -- the outer quad's winding, so the normals point inward
    local area = 0
    for i = 1, n do
        local j = (i % n) + 1
        area = area + outer[i * 2 - 1] * outer[j * 2] - outer[j * 2 - 1] * outer[i * 2]
    end
    local sgn = area >= 0 and 1 or -1
    local sx, sy = 0, 0
    for i = 1, n do
        local j = (i % n) + 1
        local ax, ay = outer[i * 2 - 1], outer[i * 2]
        local bx, by = outer[j * 2 - 1], outer[j * 2]
        local ex, ey = bx - ax, by - ay
        local len = math.sqrt(ex * ex + ey * ey)
        if len > 0 then
            -- inward normal
            local nx, ny = -ey / len * sgn, ex / len * sgn
            local worst = 0
            for k = 1, #inner, 2 do
                local depth = (inner[k] - ax) * nx + (inner[k + 1] - ay) * ny   -- > 0 inside
                if depth < -tol and -depth > worst then worst = -depth end
            end
            if worst > 0 then sx, sy = sx + nx * worst, sy + ny * worst end
        end
    end
    if sx == 0 and sy == 0 then return nil end
    if math.sqrt(sx * sx + sy * sy) > (max_shift or math.huge) then return nil end
    return sx, sy
end

-- The smallest shift that moves `a` OUT of `b` (both convex quads): the
-- least-overlap axis of the separating axis test, pointed away from b.
-- Nil when they do not overlap.
function RoomSpace.separate(a, b)
    local best_d, bnx, bny = math.huge, 0, 0
    local ax, ay = RoomSpace.centroid(a)
    local bx, by = RoomSpace.centroid(b)
    for _, poly in ipairs({ a, b }) do
        local n = #poly / 2
        for i = 1, n do
            local j = (i % n) + 1
            local ex, ey = poly[j * 2 - 1] - poly[i * 2 - 1], poly[j * 2] - poly[i * 2]
            local len = math.sqrt(ex * ex + ey * ey)
            if len > 0 then
                local nx, ny = -ey / len, ex / len
                local alo, ahi, blo, bhi = math.huge, -math.huge, math.huge, -math.huge
                for k = 1, #a, 2 do local d = a[k] * nx + a[k + 1] * ny; if d < alo then alo = d end; if d > ahi then ahi = d end end
                for k = 1, #b, 2 do local d = b[k] * nx + b[k + 1] * ny; if d < blo then blo = d end; if d > bhi then bhi = d end end
                local overlap = math.min(ahi - blo, bhi - alo)
                if overlap <= 0 then return nil end
                if overlap < best_d then
                    best_d = overlap
                    -- away from b's centre
                    if (ax - bx) * nx + (ay - by) * ny < 0 then nx, ny = -nx, -ny end
                    bnx, bny = nx, ny
                end
            end
        end
    end
    if best_d == math.huge then return nil end
    return bnx * (best_d + 1e-4), bny * (best_d + 1e-4)
end

-- Separating axis test; touching edges do not count as overlap.
local function project(poly, nx, ny)
    local lo, hi = math.huge, -math.huge
    for i = 1, #poly, 2 do
        local d = poly[i] * nx + poly[i + 1] * ny
        if d < lo then lo = d end
        if d > hi then hi = d end
    end
    return lo, hi
end

function RoomSpace.polysOverlap(a, b, eps)
    eps = eps or 1e-6
    for _, poly in ipairs({ a, b }) do
        local n = #poly / 2
        for i = 1, n do
            local j = (i % n) + 1
            local ex, ey = poly[j * 2 - 1] - poly[i * 2 - 1], poly[j * 2] - poly[i * 2]
            local nx, ny = -ey, ex
            local alo, ahi = project(a, nx, ny)
            local blo, bhi = project(b, nx, ny)
            if ahi <= blo + eps or bhi <= alo + eps then return false end
        end
    end
    return true
end

-- ── Descriptions ────────────────────────────────────────────────────────

-- Everything the fit and the clash tests need of one placed thing.
-- `item` is { obj = <entry>, f = <resolved fields>, on = <parent id|nil> }.
function RoomSpace.describe(item, ctx)
    local f = item.f
    local entry = ctx.entryFor and ctx.entryFor(f, item.obj) or nil
    local geom  = entry and ctx.geomFor and ctx.geomFor(f, entry, item.obj) or nil
    local d = { item = item, f = f, entry = entry, geom = geom }
    d.E    = RoomSpace.floorElev(f)
    d.F    = RoomSpace.faceElev(f, entry)
    d.foot = RoomSpace.footPoly(f, entry, geom)
    d.face = RoomSpace.facePoly(f, entry, geom)
    d.wall = RoomSpace.wallRect(f, entry, geom)
    return d
end

function RoomSpace.describeAll(items, ctx)
    local out = {}
    for i, item in ipairs(items) do out[i] = RoomSpace.describe(item, ctx) end
    return out
end

-- The z_offset that puts `child` (its fields) with its bottom row on
-- `parent`'s top face. Rounded: the layout writes whole pixels.
function RoomSpace.restZ(parent_f, parent_entry, child_f)
    local F = RoomSpace.faceElev(parent_f, parent_entry)
    if not F then return nil end
    local z = F - RoomSpace.diffY(child_f) * (1 - (child_f.scale or 1))
    return math.floor(z + 0.5)
end

local function sameLevel(a, b)
    return math.abs(a - b) < RoomSpace.LEVEL_EPS
end

-- Does `child` (a description) sit on `parent`'s face: its plane is the
-- face's plane and its foot's centroid lies inside the face.
function RoomSpace.sitsOn(child_d, parent_d)
    if not (parent_d.face and child_d.foot) then return false end
    if not sameLevel(child_d.E, parent_d.F) then return false end
    local cx, cy = RoomSpace.centroid(child_d.foot)
    return RoomSpace.pointInPoly(parent_d.face, cx, cy, RoomSpace.INSIDE_TOL)
end

-- Is `obj_id` homed (through any chain of active homes) on `ancestor_id`?
-- `items` carry `on` = the parent of the ACTIVE home.
function RoomSpace.isDescendant(items, obj_id, ancestor_id)
    local on = {}
    for _, it in ipairs(items) do on[it.obj.id] = it.on end
    local cur, guard = on[obj_id], 0
    while cur and guard < 64 do
        if cur == ancestor_id then return true end
        cur = on[cur]; guard = guard + 1
    end
    return false
end

-- The highest face under a grid point, among `descs`.
function RoomSpace.parentAt(descs, gx, gy)
    local best
    for _, d in ipairs(descs) do
        if d.face and not d.wall and RoomSpace.pointInPoly(d.face, gx, gy, RoomSpace.INSIDE_TOL) then
            if not best or d.F > best.F then best = d end
        end
    end
    return best
end

-- Where a thing in the hand would land. `hand_f` carries the hand's fields
-- (gx, gy, w, h, align, flip_x, scale, dx, z_offset, id, sprite, frame);
-- `items` the room's placed things (the hand's own descendants excluded by
-- the caller); `opts.room_size` the floor's side in cells; `opts.auto_z`
-- false keeps the hand's own z_offset over a face.
-- Returns { status = "off_room"|"floor"|"on"|"overhang", parent = desc|nil,
--           z = the z_offset to place at, foot = poly, face = parent face,
--           overlaps = { desc, ... } }.
function RoomSpace.fit(hand_f, items, ctx, opts)
    opts = opts or {}
    local descs = opts.descs or RoomSpace.describeAll(items, ctx)
    local w, h = hand_f.w or 1, hand_f.h or 1
    local fit = { overlaps = {}, z = hand_f.z_offset or 0 }
    if opts.room_size and (hand_f.gx < 0 or hand_f.gy < 0
       or hand_f.gx + w > opts.room_size or hand_f.gy + h > opts.room_size) then
        fit.status = "off_room"
    end
    -- A wall thing: it slides along its wall. The drop snaps to the wall
    -- line, its rectangle is checked against the others on that plane,
    -- and nothing parents (z stays the hand's own).
    local plane, fr
    local hand_entry = ctx.entryFor and ctx.entryFor(hand_f, { id = hand_f.id, sprite = hand_f.sprite, frame = hand_f.frame }) or nil
    if (hand_f.align == "left_wall" or hand_f.align == "right_wall") and not (hand_entry and hand_entry.v == "face") then
        -- within reach of a wall line it snaps there (opts.wall_snap cells)
        fr = RoomPlacement.frameOf(hand_f)
        local snap = opts.wall_snap or 0.5
        local prefer_back = hand_f.align == "left_wall"
        if prefer_back and math.abs(fr.ay) <= snap then plane = "back"
        elseif (not prefer_back) and math.abs(fr.ax) <= snap then plane = "side"
        elseif math.abs(fr.ay) <= snap then plane = "back"
        elseif math.abs(fr.ax) <= snap then plane = "side" end
    end
    if plane then
        local snapped = {}
        for k, v in pairs(hand_f) do snapped[k] = v end
        if plane == "back" then snapped.gy = hand_f.gy - fr.ay else snapped.gx = hand_f.gx - fr.ax end
        local hd = RoomSpace.describe({ obj = { id = hand_f.id, sprite = hand_f.sprite, frame = hand_f.frame }, f = snapped }, ctx)
        fit.status = fit.status or "wall"
        fit.plane, fit.wall, fit.gx, fit.gy = plane, hd.wall, snapped.gx, snapped.gy
        if opts.wall_height and hd.wall and hd.wall.z1 > opts.wall_height then fit.over_wall = true end
        for _, d in ipairs(descs) do
            if hd.wall and d.wall and d.wall.plane == plane and d.item.obj.id ~= hand_f.id
               and rectsOverlap(d.wall, hd.wall) then
                fit.overlaps[#fit.overlaps + 1] = d
            end
        end
        return fit
    end
    -- the hand's own geometry, first at its own z (the plan view does not
    -- depend on z), then re-levelled onto the parent
    local hand_item = { obj = { id = hand_f.id, sprite = hand_f.sprite, frame = hand_f.frame }, f = hand_f }
    local hd = RoomSpace.describe(hand_item, ctx)
    fit.foot = hd.foot
    local cx, cy = RoomSpace.centroid(hd.foot)
    local parent = RoomSpace.parentAt(descs, cx, cy)
    if parent then
        fit.parent, fit.face = parent, parent.face
        if opts.auto_z ~= false then
            fit.z = RoomSpace.restZ(parent.f, parent.entry, hand_f) + (opts.z_nudge or 0)
        end
        fit.status = fit.status or (RoomSpace.polyInside(hd.foot, parent.face, RoomSpace.INSIDE_TOL) and "on" or "overhang")
    else
        fit.status = fit.status or "floor"
    end
    -- overlaps: things on the hand's level whose feet cross the hand's
    local lifted = {}
    for k, v in pairs(hand_f) do lifted[k] = v end
    lifted.z_offset = fit.z
    local E = RoomSpace.floorElev(lifted)
    for _, d in ipairs(descs) do
        if d ~= parent and d.foot and d.item.obj.id ~= hand_f.id and sameLevel(d.E, E)
           and RoomSpace.polysOverlap(d.foot, hd.foot) then
            fit.overlaps[#fit.overlaps + 1] = d
        end
    end
    return fit
end

-- A wall thing against a faced floor thing: the foot touches the wall
-- line, they share a stretch along it, and the floor thing's body (E to
-- F) reaches into the wall thing's height.
function RoomSpace.wallHits(wd, fd)
    local wall = wd.wall
    if not (wall and fd.foot and fd.F) then return false end
    local lo, hi, near = math.huge, -math.huge, math.huge
    for i = 1, #fd.foot, 2 do
        local along = (wall.plane == "back") and fd.foot[i] or fd.foot[i + 1]
        local off   = (wall.plane == "back") and fd.foot[i + 1] or fd.foot[i]
        if along < lo then lo = along end
        if along > hi then hi = along end
        if off < near then near = off end
    end
    if near > RoomSpace.WALL_TOUCH then return false end
    if not (lo < wall.t1 - 1e-6 and wall.t0 < hi - 1e-6) then return false end
    return fd.E < wall.z1 and fd.F > wall.z0
end

-- Every clash in the room: two feet on one level that cross (neither
-- homed on the other), and a child on a face that hangs off it.
-- Returns { { a = desc, b = desc, kind = "overlap"|"overhang" }, ... }.
-- Kinds: "overlap" (two feet on one level, or two wall rectangles on one
-- plane), "overhang" (a child on a face that hangs off it), "wall" (a wall
-- thing a floor thing's body runs into). Things homed on each other are
-- exempt from overlap (a note on a corkboard covers it by design).
function RoomSpace.clashes(items, ctx, descs)
    descs = descs or RoomSpace.describeAll(items, ctx)
    local by_id = {}
    for _, d in ipairs(descs) do by_id[d.item.obj.id] = d end
    local out = {}
    for i = 1, #descs do
        local a = descs[i]
        for j = i + 1, #descs do
            local b = descs[j]
            local related = a.item.on == b.item.obj.id or b.item.on == a.item.obj.id
            if not related then
                if a.foot and b.foot then
                    if sameLevel(a.E, b.E) and RoomSpace.polysOverlap(a.foot, b.foot) then
                        out[#out + 1] = { a = a, b = b, kind = "overlap" }
                    end
                elseif a.wall and b.wall then
                    if a.wall.plane == b.wall.plane and rectsOverlap(a.wall, b.wall) then
                        out[#out + 1] = { a = a, b = b, kind = "overlap" }
                    end
                elseif a.wall and b.foot then
                    if RoomSpace.wallHits(a, b) then out[#out + 1] = { a = b, b = a, kind = "wall" } end
                elseif b.wall and a.foot then
                    if RoomSpace.wallHits(b, a) then out[#out + 1] = { a = a, b = b, kind = "wall" } end
                end
            end
        end
        local p = a.item.on and by_id[a.item.on]
        if p and p.face and a.foot and sameLevel(a.E, p.F)
           and not RoomSpace.polyInside(a.foot, p.face, RoomSpace.INSIDE_TOL) then
            out[#out + 1] = { a = a, b = p, kind = "overhang" }
        end
    end
    return out
end

return RoomSpace
