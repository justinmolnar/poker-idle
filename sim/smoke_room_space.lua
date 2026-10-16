-- sim/smoke_room_space.lua
-- The room's space model (models/room_space) and the surfaces reader
-- (services/RoomSurfaces), headless: projections round-trip, a synthetic
-- sprite's foot and face land where the draw puts its pixels, restZ puts a
-- child's bottom on a parent's face, fit says on / overhang / floor /
-- overlap, clashes finds the overlaps and overhangs of a small room, and
-- the reader resolves aliases, animation frames, strips and a nil loader.
--
--   lua sim/smoke_room_space.lua
package.path = package.path .. ";./?.lua"
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local RS = require("models.room_space")
local RP = require("models.room_placement")
local RoomSurfaces = require("services.RoomSurfaces")

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- 1. projections round-trip, eighth steps included
do
    local good = true
    for gx = -2, 6, 0.125 do
        for gy = -1, 5, 0.375 do
            local x, y = RS.gridToArt(gx, gy)
            local bx, by = RS.artToGrid(x, y)
            if not (near(bx, gx) and near(by, gy)) then good = false end
        end
    end
    c.ok(good, "gridToArt / artToGrid round-trip on a lattice")
end

-- A synthetic 64x64 sprite whose foot is the 1x1 cell diamond and whose
-- top is 20 px up: T (32,32) L (0,48) B (32,64) R (64,48) for the foot.
local ENTRY = { v = "face", height = 20, bottom = 64, cell = { 64, 64 },
                face = { 32, 12, 0, 28, 32, 44, 64, 28 },
                foot = { 32, 32, 0, 48, 32, 64, 64, 48 } }
local ctx = {
    entryFor = function(f, obj) return (obj and obj.entry) or f.entry end,
    geomFor  = function(f, entry) return { cell_w = entry.cell[1], bottom = entry.bottom } end,
}

-- 2. fallback rectangle: two adjacent cells do not overlap, shifted ones do
do
    local none = { entryFor = function() return nil end, geomFor = function() return nil end }
    local a = RS.describe({ obj = { id = "a" }, f = { gx = 2, gy = 3, w = 1, h = 1 } }, none)
    local b = RS.describe({ obj = { id = "b" }, f = { gx = 3, gy = 3, w = 1, h = 1 } }, none)
    local b2 = RS.describe({ obj = { id = "b2" }, f = { gx = 2.875, gy = 3, w = 1, h = 1 } }, none)
    c.ok(#a.foot == 8 and a.foot[1] == 2 and a.foot[2] == 3, "no entry: the foot is the w x h rectangle")
    c.ok(not RS.polysOverlap(a.foot, b.foot), "adjacent cells do not overlap")
    c.ok(RS.polysOverlap(a.foot, b2.foot), "a cell shifted by an eighth overlaps")
end

-- 3. the synthetic sprite's foot lands on the cell it is placed in
do
    local f = { gx = 2, gy = 3, w = 1, h = 1, scale = 1, z_offset = 0, dx = 0, entry = ENTRY }
    local d = RS.describe({ obj = { id = "s" }, f = f }, ctx)
    -- foot corners T, R, B, L in grid: (2,3) (3,3) (3,4) (2,4) up to the half-pixel the corners sit on
    local want = { 2, 3, 3, 3, 3, 4, 2, 4 }
    local maxerr = 0
    for i = 1, 8 do maxerr = math.max(maxerr, math.abs(d.foot[i] - want[i])) end
    c.ok(maxerr <= 0.03, ("a 1x1 sprite's foot is its cell (max corner error %.3f)"):format(maxerr))
    -- the face's B lands on the same grid point as the foot's B
    c.ok(near(d.face[5], d.foot[5], 0.03) and near(d.face[6], d.foot[6], 0.03),
         "the face's front corner projects onto the foot's front corner")
    c.ok(near(d.E, 0) and near(d.F, 20), ("E %.1f F %.1f"):format(d.E, d.F))
    -- flipped: the same set of corners
    local ff = {}; for k, v in pairs(f) do ff[k] = v end; ff.flip_x = true
    local df = RS.describe({ obj = { id = "s" }, f = ff }, ctx)
    -- (to the half pixel the corners sit on: a mirror swaps which side carries it)
    local function sameSet(p, q)
        for i = 1, 8, 2 do
            local found = false
            for j = 1, 8, 2 do if near(p[i], q[j], 0.05) and near(p[i + 1], q[j + 1], 0.05) then found = true end end
            if not found then return false end
        end
        return true
    end
    c.ok(sameSet(df.foot, d.foot), "flipping the sprite keeps its foot's corners")
    -- scale 0.5: B stays on the front vertex, T comes in
    local fs = {}; for k, v in pairs(f) do fs[k] = v end; fs.scale = 0.5
    local ds = RS.describe({ obj = { id = "s" }, f = fs }, ctx)
    c.ok(near(ds.foot[5], 3, 0.03) and near(ds.foot[6], 4, 0.03), "at scale 0.5 the foot's front corner stays on the front vertex")
    c.ok(near(ds.foot[1], 2.5, 0.03) and near(ds.foot[2], 3.5, 0.03), "at scale 0.5 the foot's back corner is halfway in")
    c.ok(near(ds.E, 8), ("at scale 0.5 the floor plane is lifted by diffY/2: E %.1f"):format(ds.E))
end

-- 4. restZ puts the child's bottom on the parent's face
do
    local parent = { gx = 0, gy = 0, w = 1, h = 2, scale = 1, z_offset = -16, dx = 0, entry = { v = "face", height = 52 } }
    local child  = { gx = 0, gy = 0, w = 1, h = 1, scale = 0.7, z_offset = 0 }
    local z = RS.restZ(parent, parent.entry, child)
    local lifted = {}; for k, v in pairs(child) do lifted[k] = v end; lifted.z_offset = z
    c.ok(math.abs(RS.floorElev(lifted) - RS.faceElev(parent, parent.entry)) <= 0.5,
         ("restZ %d puts the child's plane on the parent's face"):format(z))
    c.ok(RS.restZ(child, nil, child) == nil, "no face, no restZ")
end

-- 5. fit: on, overhang, floor, overlap, stacked faces, descendants
do
    local desk = { obj = { id = "desk", entry = { v = "face", height = 40, bottom = 128, cell = { 128, 128 },
                                                   face = { 64, 40, 0, 72, 64, 104, 128, 72 },
                                                   foot = { 64, 80, 0, 112, 64, 144, 128, 112 } } },
                   f = { gx = 1, gy = 1, w = 2, h = 2, scale = 1, z_offset = 0, dx = 0 } }
    -- (a 2x2 sprite whose foot is the 2x2 diamond: bottom 144 > cell is fine for the maths)
    local plant = { obj = { id = "plant" }, f = { gx = 4, gy = 4, w = 1, h = 1, scale = 1, z_offset = 0 } }
    local items = { desk, plant }
    local hand = { id = "cup", gx = 1.5, gy = 1.5, w = 1, h = 1, scale = 1, z_offset = 0, dx = 0, entry = ENTRY }
    local fit = RS.fit(hand, items, ctx, { room_size = 6 })
    c.ok(fit.status == "on" and fit.parent == nil or fit.parent and fit.parent.item == desk,
         "a cup over the desk's top: parent is the desk (" .. tostring(fit.status) .. ")")
    c.ok(fit.status == "on", "and it is on (" .. tostring(fit.status) .. ")")
    c.ok(fit.z == RS.restZ(desk.f, desk.obj.entry, hand), ("auto z = restZ (%s)"):format(tostring(fit.z)))
    local edge = {}; for k, v in pairs(hand) do edge[k] = v end; edge.gx, edge.gy = 2.6, 2.6
    local fe = RS.fit(edge, items, ctx, { room_size = 6 })
    c.ok(fe.status == "overhang" and fe.parent and fe.parent.item == desk, "straddling the desk's edge: overhang (" .. tostring(fe.status) .. ")")
    local floor = {}; for k, v in pairs(hand) do floor[k] = v end; floor.gx, floor.gy = 4.5, 0.5
    local ff = RS.fit(floor, items, ctx, { room_size = 6 })
    c.ok(ff.status == "floor" and #ff.overlaps == 0, "free floor: floor, no overlaps (" .. tostring(ff.status) .. ")")
    local onplant = {}; for k, v in pairs(hand) do onplant[k] = v end; onplant.gx, onplant.gy = 4.25, 4.25
    local fo = RS.fit(onplant, items, ctx, { room_size = 6 })
    c.ok(fo.status == "floor" and #fo.overlaps == 1 and fo.overlaps[1].item == plant, "over the plant: it overlaps (" .. #fo.overlaps .. ")")
    local off = {}; for k, v in pairs(hand) do off[k] = v end; off.gx, off.gy = 5.5, 5.5
    c.ok(RS.fit(off, items, ctx, { room_size = 6 }).status == "off_room", "past the room: off_room")
    -- a faceless thing already on the desk at the same spot (a plant in a
    -- pot: a foot, no top): parent desk, the plant in overlaps
    local FOOT_ONLY = { v = "none", bottom = 64, cell = { 64, 64 }, foot = ENTRY.foot }
    local cup2 = { obj = { id = "cup2", entry = FOOT_ONLY }, on = "desk",
                   f = { gx = 1.5, gy = 1.5, w = 1, h = 1, scale = 1, dx = 0,
                         z_offset = RS.restZ(desk.f, desk.obj.entry, { w = 1, h = 1, scale = 1 }) } }
    local f2 = RS.fit(hand, { desk, plant, cup2 }, ctx, { room_size = 6 })
    c.ok(f2.parent and f2.parent.item == desk and #f2.overlaps == 1 and f2.overlaps[1].item == cup2,
         "dropping on a potted plant already on the desk: parent desk, the plant overlaps")
    -- stacked faces: the higher one wins
    local box = { obj = { id = "box", entry = ENTRY }, on = "desk",
                  f = { gx = 1.5, gy = 1.5, w = 1, h = 1, scale = 1, dx = 0,
                        z_offset = RS.restZ(desk.f, desk.obj.entry, { w = 1, h = 1, scale = 1 }) } }
    local f3 = RS.fit(hand, { desk, box }, ctx, { room_size = 6 })
    c.ok(f3.parent and f3.parent.item == box, "two faces under the hand: the higher (the box on the desk) wins")
    -- descendants
    c.ok(RS.isDescendant({ desk, box }, "box", "desk") and not RS.isDescendant({ desk, box }, "desk", "box"),
         "isDescendant follows the home chain one way")
end

-- 6. clashes on a small room
do
    local none = { entryFor = function(f, obj) return obj and obj.entry end,
                   geomFor = function(f, e) return { cell_w = e.cell[1], bottom = e.bottom } end }
    local a = { obj = { id = "a" }, f = { gx = 0, gy = 0, w = 1, h = 1, z_offset = 0 } }
    local b = { obj = { id = "b" }, f = { gx = 0.5, gy = 0, w = 1, h = 1, z_offset = 0 } }
    local cl = RS.clashes({ a, b }, none)
    c.ok(#cl == 1 and cl[1].kind == "overlap", "two feet crossing on the floor: one overlap")
    local desk = { obj = { id = "desk", entry = { v = "face", height = 40, bottom = 128, cell = { 128, 128 },
                                                   face = { 64, 40, 0, 72, 64, 104, 128, 72 },
                                                   foot = { 64, 80, 0, 112, 64, 144, 128, 112 } } },
                   f = { gx = 2, gy = 2, w = 2, h = 2, scale = 1, z_offset = 0, dx = 0 } }
    local zc = RS.restZ(desk.f, desk.obj.entry, { w = 1, h = 1, scale = 1 })
    local inside = { obj = { id = "cup", entry = ENTRY }, on = "desk", f = { gx = 2.5, gy = 2.5, w = 1, h = 1, scale = 1, dx = 0, z_offset = zc } }
    c.ok(#RS.clashes({ desk, inside }, none) == 0, "a child inside its face: no clash")
    local half = { obj = { id = "cup", entry = ENTRY }, on = "desk", f = { gx = 3.6, gy = 3.6, w = 1, h = 1, scale = 1, dx = 0, z_offset = zc } }
    local ch = RS.clashes({ desk, half }, none)
    c.ok(#ch == 1 and ch[1].kind == "overhang", "a child half off its face: one overhang")
    local clock = { obj = { id = "clock" }, f = { gx = 2.5, gy = 2.5, w = 1, h = 1, z_offset = 44 } }
    c.ok(#RS.clashes({ desk, clock }, none) == 0, "a wall clock 44 px up over the desk: no clash")
    local cup2 = { obj = { id = "cup2", entry = ENTRY }, on = "desk", f = { gx = 2.75, gy = 2.5, w = 1, h = 1, scale = 1, dx = 0, z_offset = zc } }
    local two = RS.clashes({ desk, inside, cup2 }, none)
    local overlaps = 0
    for _, x in ipairs(two) do if x.kind == "overlap" then overlaps = overlaps + 1 end end
    c.ok(overlaps == 1, "two children crossing on one face: one overlap (" .. overlaps .. ")")
end

-- 7. the frame model round-trips a restZ home
do
    local parent = { id = "desk", gx = 1, gy = 1, w = 2, h = 2, z_offset = -8, dx = 3 }
    local child_f = { gx = 1.5, gy = 1.5, w = 1, h = 1, scale = 0.7, z_offset = 0, dx = 0 }
    local z = RS.restZ(parent, { v = "face", height = 40 }, child_f)
    child_f.z_offset = z
    local child = { id = "cup", homes = {} }
    RP.setHome(child, "desk", child_f, parent)
    local out = RP.toWorld(RP.frameOf(parent), child.homes[1], {})
    c.ok(out.z_offset == z, ("setHome then toWorld returns the rest z (%s vs %s)"):format(tostring(out.z_offset), tostring(z)))
end

-- 8. the reader
do
    local data = {
        __meta = { format = "room-surfaces/1" },
        ["K/Desks/Desk_1_Tile"] = { v = "face", height = 34 },
        ["K/Clock_Ani/Clock_1"] = { v = "none" },
        ["K/Clock_Ani/Clock_2"] = { v = "face", height = 3 },
        ["K/Doors/Door_2"] = { v = "none", cells = { { v = "none" }, { v = "face", height = 9 }, { v = "none" } } },
    }
    RoomSurfaces.load(data)
    local loader = { aliases = { desk = "K/Desks/Desk_1_Tile", clock = "K/Clock_Ani/Clock_1", door = "K/Doors/Door_2" },
                     animation_paths = { ["K/Clock_Ani/Clock_1"] = { "K/Clock_Ani/Clock_1", "K/Clock_Ani/Clock_2" },
                                         ["K/Clock_Ani/Clock_2"] = { "K/Clock_Ani/Clock_1", "K/Clock_Ani/Clock_2" } } }
    local e = RoomSurfaces.entryFor(loader, { id = "desk" })
    c.ok(e and e.height == 34, "an alias resolves to its entry")
    c.ok(RoomSurfaces.entryFor(loader, { id = "clock" }).v == "none", "an animating sprite reads frame 1")
    c.ok(RoomSurfaces.entryFor(loader, { id = "clock", frame = 2 }).height == 3, "a pinned frame reads its own")
    c.ok(RoomSurfaces.entryFor(loader, { id = "clock", frame = 9 }).height == 3, "a frame past the end clamps")
    c.ok(RoomSurfaces.entryFor(loader, { id = "door", frame = 2 }).height == 9, "a strip cell by frame")
    c.ok(RoomSurfaces.entryFor(nil, { sprite = "K/Desks/Desk_1_Tile" }).height == 34, "no loader: the sprite name is the key")
    c.ok(RoomSurfaces.entryFor({}, { id = "nothing" }) == nil, "unknown: nil, no error")
    RoomSurfaces.load({})
    c.ok(RoomSurfaces.entryFor(loader, { id = "desk" }) == nil, "empty data: nil")
end

-- 9. the real data, when it is there: every face sprite names a file
do
    local good, real = pcall(require, "data.room_surfaces")
    if good and type(real) == "table" then
        local missing, n = 0, 0
        for key, e in pairs(real) do
            if key ~= "__meta" then
                n = n + 1
                local fh = io.open("assets/sprites/" .. key .. ".png", "rb")
                if fh then fh:close() else missing = missing + 1 end
            end
        end
        c.ok(missing == 0, ("%d of %d surfaces entries name a sprite file that is not on disk"):format(missing, n))
    else
        print("[smoke] data/room_surfaces.lua absent; skipping the file check")
    end
end

if c.report("smoke_room_space") > 0 then os.exit(1) end
