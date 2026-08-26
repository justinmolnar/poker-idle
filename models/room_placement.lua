-- models/room_placement.lua
--
-- Where a placed room item sits depends on what the player owns. Each
-- entry in data/room_layout.lua has its own base placement (gx, gy,
-- z_offset, dx, layer...) and may carry, in order of preference:
--
--   homes = {
--       { on = "desk", u = 0.5, v = 1.2, z_offset = 34, dx = 3, f = 2, ... },
--   }
--   hidden_when = { "gaming_chair" },   -- not drawn once any is owned
--
-- The first home whose parent is owned (and itself shown) wins; the
-- entry's own spot is the fallback when none does (everything has a
-- place on the floor).
--
-- A HOME IS STORED IN THE PARENT'S LOCAL FRAME, not as a grid delta.
-- The frame's origin is the parent's anchor (the point its sprite hangs
-- from) and its handedness H is +1 or -1: flipping the parent, or
-- putting it on the other wall, mirrors the frame across the screen's
-- x axis. Children are DEFINED in that frame, so a parent that flips or
-- changes wall carries and mirrors its children exactly, with no stored
-- history and no case analysis:
--
--   u          screen-x offset of the child's anchor, grid units, at H=+1
--   v          screen-depth offset (the axis a mirror never touches)
--   z_offset   height above the parent (never mirrored)
--   dx         pixel nudge relative to the parent's, mirrored with H
--   align / w / h stored canonically (their values when H=+1)
--   flip_x     relative to the PARENT'S OWN flip, not to H: wall side
--              moves anchors but never mirrors pixels, so a child's
--              pixels mirror exactly when the parent's pixels do
--   layer / scale          the home's own, untouched by mirrors
--
-- Writing under any H normalises into the canonical frame; reading
-- multiplies H back in. H*H = 1, so write and read are exact inverses:
-- edit a child under a flipped parent, unflip the parent, and nothing
-- drifts. Frame homes carry f = 3; f = 2 homes (an earlier frame format
-- whose flip tracked H) and pre-frame homes (plain grid offsets, dx
-- sometimes relative) are migrated in place by migrateRelativeDx.
--
-- Grid <-> screen: +1 gx draws right-and-down, +1 gy left-and-down, so
-- a grid offset (ex, ey) has screen-x component ex - ey and depth
-- component ex + ey. Pure functions; the caller says what is owned.

local RoomPlacement = {}

RoomPlacement.HOME_FIELDS = { "gx", "gy", "z_offset" }
RoomPlacement.HOME_OWN_FIELDS = { "dx", "layer", "flip_x", "align", "scale" }

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- ── The frame ───────────────────────────────────────────────────────────

local function anchorOffset(align, w, h)
    w, h = w or 1, h or 1
    if align == "left_wall"  then return w * 0.5, 0 end
    if align == "right_wall" then return 0, h * 0.5 end
    return w * 0.5, h * 0.5
end

local function otherWall(a)
    if a == "left_wall" then return "right_wall" end
    if a == "right_wall" then return "left_wall" end
    return a
end

-- The parent's frame, from its RESOLVED world fields.
function RoomPlacement.frameOf(f)
    local ox, oy = anchorOffset(f.align, f.w, f.h)
    local H = 1
    if f.flip_x then H = -H end
    if f.align == "right_wall" then H = -H end
    return {
        ax = f.gx + ox, ay = f.gy + oy,          -- anchor, grid
        z  = f.z_offset or 0,
        dx = f.dx or 0,
        H  = H,
        flip = f.flip_x or false,                -- pixel mirror, alone
    }
end

-- World fields -> a home in `frame` (canonical: H folded out).
function RoomPlacement.toLocal(frame, f)
    local ox, oy = anchorOffset(f.align, f.w, f.h)
    local ex = (f.gx + ox) - frame.ax
    local ey = (f.gy + oy) - frame.ay
    local h = {
        u        = (ex - ey) * frame.H,
        v        = ex + ey,
        z_offset = (f.z_offset or 0) - frame.z,
        dx       = ((f.dx or 0) - frame.dx) * frame.H,
        layer    = f.layer or 0,
        scale    = f.scale or 1.0,
        f        = 3,
    }
    if frame.H < 0 then
        h.align  = otherWall(f.align or "center")
        h.w, h.h = f.h or 1, f.w or 1
    else
        h.align  = f.align or "center"
        h.w, h.h = f.w or 1, f.h or 1
    end
    h.flip_x = ((f.flip_x or false) ~= frame.flip) or nil
    if h.align == "center" then h.align = nil end
    return h
end

-- A home + the parent's CURRENT frame -> world fields, written onto `out`.
function RoomPlacement.toWorld(frame, h, out)
    local align, w, hh
    if frame.H < 0 then
        align = otherWall(h.align or "center")
        w, hh = h.h or 1, h.w or 1
    else
        align = h.align or "center"
        w, hh = h.w or 1, h.h or 1
    end
    local flip = (h.flip_x or false) ~= frame.flip
    local a  = (h.u or 0) * frame.H
    local b  = h.v or 0
    local ex = (a + b) * 0.5
    local ey = (b - a) * 0.5
    local ox, oy = anchorOffset(align ~= "center" and align or nil, w, hh)
    out.gx       = frame.ax + ex - ox
    out.gy       = frame.ay + ey - oy
    out.z_offset = frame.z + (h.z_offset or 0)
    out.dx       = frame.dx + (h.dx or 0) * frame.H
    out.flip_x   = flip
    out.align    = align ~= "center" and align or nil
    out.w, out.h = w, hh
    if h.layer ~= nil then out.layer = h.layer end
    if h.scale ~= nil then out.scale = h.scale end
    return out
end

-- ── Resolution ──────────────────────────────────────────────────────────

-- f = 2 frame homes: as toWorld, except flip tracked H instead of the
-- parent's own flip. Kept only to read old drafts for migration.
local function f2ToWorld(frame, h, out)
    RoomPlacement.toWorld(frame, h, out)
    if frame.H < 0 then out.flip_x = not h.flip_x else out.flip_x = h.flip_x or false end
    return out
end

-- Pre-frame homes: plain origin offsets, own-fields, dx maybe relative.
local function legacyToWorld(pf, h, out)
    out.gx       = pf.gx + (h.gx or 0)
    out.gy       = pf.gy + (h.gy or 0)
    out.z_offset = (pf.z_offset or 0) + (h.z_offset or 0)
    for _, f in ipairs(RoomPlacement.HOME_OWN_FIELDS) do
        if h[f] ~= nil then out[f] = h[f] end
    end
    if h.dx_rel then
        out.dx = (pf.dx or 0) + (h.dx or 0)
    end
    return out
end

-- Resolve every entry of `placed` against `owned_set` (id -> true).
-- Returns a table keyed by entry: { fields = <resolved copy>, shown =
-- bool, home = <index into homes, 0 for its own spot> }. `shown` is
-- false only when hidden_when fires.
function RoomPlacement.resolveAll(placed, owned_set)
    owned_set = owned_set or {}
    local by_id = {}
    for _, o in ipairs(placed) do by_id[o.id] = by_id[o.id] or o end
    local out, visiting = {}, {}

    local function resolve(o)
        if out[o] then return out[o] end
        if visiting[o] then                    -- a cycle: fall back to the base
            return { fields = copy(o), shown = true, home = 0 }
        end
        visiting[o] = true
        local r = { fields = copy(o), shown = true, home = 0 }
        for _, id in ipairs(o.hidden_when or {}) do
            if owned_set[id] then r.shown = false end
        end
        for i, h in ipairs(o.homes or {}) do
            local parent = h.on and by_id[h.on]
            if parent and owned_set[parent.id] then
                local pr = resolve(parent)
                if pr.shown then
                    if h.f == 3 then
                        RoomPlacement.toWorld(RoomPlacement.frameOf(pr.fields), h, r.fields)
                    elseif h.f == 2 then
                        f2ToWorld(RoomPlacement.frameOf(pr.fields), h, r.fields)
                    else
                        legacyToWorld(pr.fields, h, r.fields)
                    end
                    r.home = i
                    break
                end
            end
        end
        visiting[o] = nil
        out[o] = r
        return r
    end
    for _, o in ipairs(placed) do resolve(o) end
    return out
end

function RoomPlacement.resolve(obj, placed, owned_set)
    return RoomPlacement.resolveAll(placed, owned_set)[obj]
end

-- ── Editing ─────────────────────────────────────────────────────────────

function RoomPlacement.homeOn(obj, parent_id)
    for i, h in ipairs(obj.homes or {}) do
        if h.on == parent_id then return h, i end
    end
    return nil
end

-- Make (or replace) the home of `obj` on `parent_id`, from both entries'
-- RESOLVED world fields right now: the child stays exactly where it sits.
function RoomPlacement.setHome(obj, parent_id, obj_res, parent_res)
    local _, i = RoomPlacement.homeOn(obj, parent_id)
    local new = RoomPlacement.toLocal(RoomPlacement.frameOf(parent_res), obj_res)
    new.on = parent_id
    if i then
        obj.homes[i] = new
    else
        obj.homes = obj.homes or {}
        obj.homes[#obj.homes + 1] = new
    end
    return new
end

function RoomPlacement.removeHome(obj, index)
    if not obj.homes or not obj.homes[index] then return false end
    table.remove(obj.homes, index)
    if #obj.homes == 0 then obj.homes = nil end
    return true
end

function RoomPlacement.moveHome(obj, index, dir)
    local hs = obj.homes
    if not hs then return false end
    local j = index + dir
    if not hs[index] or not hs[j] then return false end
    hs[index], hs[j] = hs[j], hs[index]
    return true
end

-- Write a placement into the home active under `res` (through the
-- parent's current frame), or onto the base when none is. `fields` are
-- world values; unspecified ones keep what the entry resolves to now.
function RoomPlacement.writePlacement(obj, res, parent_res, fields)
    local h = res and res.home > 0 and obj.homes and obj.homes[res.home]
    if h and parent_res then
        local world = copy(res.fields)
        for k, v in pairs(fields) do world[k] = v end
        local new = RoomPlacement.toLocal(RoomPlacement.frameOf(parent_res), world)
        new.on = h.on
        obj.homes[res.home] = new
    else
        for _, f in ipairs(RoomPlacement.HOME_FIELDS) do
            if fields[f] ~= nil then obj[f] = fields[f] end
        end
        for _, f in ipairs(RoomPlacement.HOME_OWN_FIELDS) do
            if fields[f] ~= nil then obj[f] = fields[f] end
        end
    end
end

-- ── Conditions, copies, anchors ─────────────────────────────────────────

function RoomPlacement.isHiddenWhen(obj, id)
    for _, h in ipairs(obj.hidden_when or {}) do
        if h == id then return true end
    end
    return false
end

function RoomPlacement.toggleHiddenWhen(obj, id)
    obj.hidden_when = obj.hidden_when or {}
    for i, h in ipairs(obj.hidden_when) do
        if h == id then
            table.remove(obj.hidden_when, i)
            if #obj.hidden_when == 0 then obj.hidden_when = nil end
            return false
        end
    end
    obj.hidden_when[#obj.hidden_when + 1] = id
    return true
end

function RoomPlacement.copyConditions(obj)
    local hw, hs = nil, nil
    if obj.hidden_when then
        hw = {}
        for i, h in ipairs(obj.hidden_when) do hw[i] = h end
    end
    if obj.homes then
        hs = {}
        for i, h in ipairs(obj.homes) do hs[i] = copy(h) end
    end
    return hw, hs
end

function RoomPlacement.anchorIds(placed)
    local seen, ids = {}, {}
    for _, o in ipairs(placed) do
        for _, h in ipairs(o.homes or {}) do
            if h.on and not seen[h.on] then seen[h.on] = true; ids[#ids + 1] = h.on end
        end
    end
    table.sort(ids)
    return ids
end

-- ── Migration ───────────────────────────────────────────────────────────

-- Convert every pre-frame home to a frame home, preserving exactly what
-- it resolves to TODAY: resolve the room with everything present, then
-- re-express each child in its parent's current frame. One home per pass
-- so chains (a homed parent of a homed child) settle parents-first. Name
-- kept from the earlier dx migration; RoomView calls it at load/RESET.
function RoomPlacement.migrateRelativeDx(placed)
    local all, by_id = {}, {}
    for _, o in ipairs(placed) do
        all[o.id] = true
        by_id[o.id] = by_id[o.id] or o
    end
    local n = 0
    for _ = 1, 64 do
        local res = RoomPlacement.resolveAll(placed, all)
        local done = true
        for _, o in ipairs(placed) do
            for i, h in ipairs(o.homes or {}) do
                if h.f ~= 3 then
                    local parent = h.on and by_id[h.on]
                    if parent and res[parent] then
                        local world = copy(o)
                        local pf = res[parent].fields
                        if h.f == 2 then
                            f2ToWorld(RoomPlacement.frameOf(pf), h, world)
                        else
                            legacyToWorld(pf, h, world)
                        end
                        local new = RoomPlacement.toLocal(RoomPlacement.frameOf(pf), world)
                        new.on = h.on
                        o.homes[i] = new
                    else
                        h.f = 3   -- orphan home: freeze; it never resolves anyway
                    end
                    n = n + 1
                    done = false
                end
            end
        end
        if done then break end
    end
    return n
end

return RoomPlacement
