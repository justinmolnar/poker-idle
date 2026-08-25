-- data/room_tiles.lua
--
-- The floor and wall tile kits under
-- assets/sprites/isometric/Floor_Wall_Tiles_<size>/. The three sizes are
-- the same designs at three pixel densities (roughly 2x steps), but not
-- exact scales of each other, so each set carries its own anchors,
-- measured from the art (opaque bounds of the WoodHard tiles).
--
-- Every value is in the set's own sprite pixels. RoomView draws a set at
-- scale tile_k * 64 / size so a floor diamond always spans one grid tile;
-- the offsets below are the point of the sprite that lands on the grid
-- vertex.
--
--   floor.ox/oy   top vertex of the floor diamond
--   wall_l.ox/oy  Wall_L: its right edge (x1 - 3), 16*ts above the bottom
--   wall_r.ox/oy  Wall_R: its left edge (x0 + 2), same height
--   course_px     the face repeats every this many px when stacked
--
-- Bath and Japanese tiles live elsewhere with other names and are not
-- part of the kits here.

return {
    sets = { 32, 64, 128 },
    default_set = 64,
    default_courses = 2,
    max_courses = 4,
    folder = "isometric/Floor_Wall_Tiles_%d/",
    floor_name = "Floor_%d_%s",
    wall_l_name = "Wall_L_%d_%s",
    wall_r_name = "Wall_R_%d_%s",
    anchors = {
        [32]  = { floor = { ox = 16, oy = 5 },  wall_l = { ox = 27, oy = 24 }, wall_r = { ox = 4,  oy = 24 }, course_px = 20 },
        [64]  = { floor = { ox = 32, oy = 16 }, wall_l = { ox = 47, oy = 47 }, wall_r = { ox = 16, oy = 47 }, course_px = 40 },
        [128] = { floor = { ox = 64, oy = 36 }, wall_l = { ox = 95, oy = 83 }, wall_r = { ox = 32, oy = 83 }, course_px = 78 },
    },
}
