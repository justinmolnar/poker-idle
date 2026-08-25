-- views/RoomView.lua
--
-- Isometric room renderer and visual layout designer.
-- Converts grid coords (gx, gy) to isometric screen coords and handles painter's algorithm
-- depth sorting to render items correctly from back to front.
-- Includes an in-game Editor mode to place, size, and layout furniture, which can then
-- be saved (printed to the console) for permanent inclusion in the room data.

local Theme          = require("views.Theme")
local LabelButton    = require("views.widgets.LabelButton")
local Catalog        = require("data.catalog")
local Layout         = require("data.room_layout")
local Tiles          = require("data.room_tiles")

-- The editor autosaves a draft next to the game's saves (DRAFT_FILE) so a
-- crash or a closed window loses seconds, not the session. The draft
-- loads over data/room_layout.lua; EXPORT writes the data file itself
-- (when running from source) and clears the draft; RESET goes back to
-- the data file.
local DRAFT_FILE = "room_layout_draft.lua"
local DRAFT_BAK  = "room_layout_draft.bak.lua"   -- the draft before the last write
local function countItems(layout)
    local n = 0
    for id in pairs(layout) do if id ~= "__meta" then n = n + 1 end end
    return n
end
local function backupDraft(new_str)
    if not love.filesystem.getInfo(DRAFT_FILE) then return end
    local prev = love.filesystem.read(DRAFT_FILE)
    if prev and prev ~= new_str then pcall(love.filesystem.write, DRAFT_BAK, prev) end
end
local function loadDraft()
    if not (love and love.filesystem and love.filesystem.getInfo(DRAFT_FILE)) then return nil end
    local ok, chunk = pcall(love.filesystem.load, DRAFT_FILE)
    if not ok or not chunk then return nil end
    local ok2, layout = pcall(chunk)
    if ok2 and type(layout) == "table" then
        local size = (layout.__meta or {}).room_size
        print(string.format("[room-editor] Loaded draft layout (%d items, size %s) from the save directory",
            countItems(layout), tostring(size)))
        return layout
    end
    return nil
end
local Anchors        = require("services.AnchorRegistry")
local ClickFlash     = require("services.ClickFlash")
local ShaderRegistry = require("services.ShaderRegistry")

local RoomView = {}
RoomView.__index = RoomView

-- Configuration
local GRID_SIZE = 10
local TILE_W    = 64
local TILE_H    = 32
local WALL_H    = 96

-- Cache for dynamic sprite bottom coordinate scanning
local sprite_bottom_cache = {}
local function getSpriteBottom(sprite, name)
    if not sprite then return 0 end
    if sprite_bottom_cache[name] then
        return sprite_bottom_cache[name]
    end
    
    local w, h = sprite:getDimensions()
    local resolved = name
    if game and game.sprite_loader and game.sprite_loader.aliases and game.sprite_loader.aliases[name] then
        resolved = game.sprite_loader.aliases[name]
    end
    local path = "assets/sprites/" .. resolved .. ".png"
    if not love.filesystem.getInfo(path) then
        path = "assets/sprites/" .. name .. ".png"
    end
    if not love.filesystem.getInfo(path) then
        path = "assets/" .. name .. ".png"
    end
    
    if love.filesystem.getInfo(path) then
        local ok, imgData = pcall(love.image.newImageData, path)
        if ok and imgData then
            -- The sprite can be one cell of a strip (see SpriteLoader
            -- _sliceStrip): scan only what both the sprite and the file
            -- have, or getPixel throws out of range.
            local iw, ih = imgData:getDimensions()
            local sw, sh = math.min(w, iw), math.min(h, ih)
            local max_y = sh - 1
            local found = false
            for y = sh - 1, 0, -1 do
                for x = 0, sw - 1 do
                    local r, g, b, a = imgData:getPixel(x, y)
                    if a > 0 then
                        max_y = y
                        found = true
                        break
                    end
                end
                if found then break end
            end
            local oy = max_y + 1
            sprite_bottom_cache[name] = oy
            return oy
        end
    end
    
    -- Fallback to full height if file not found or failed to load
    sprite_bottom_cache[name] = h
    return h
end

-- Integer tile metrics for the current ui scale. The HALF-steps (the
-- actual pixel deltas between neighboring tiles) are rounded to whole
-- pixels and everything else derives from them: tile positions land on
-- integers exactly one sprite-width apart, and the sprite draw scale
-- comes FROM the rounded step so the 64px tile art tessellates exactly.
-- The old approach (scale the art up 2% and round each tile's position
-- independently) is where the wall/floor seams came from: fractional
-- blits under linear filtering alpha-blend every tile edge over its
-- neighbor. Returns tw, th, sprite_scale.
local function tileMetrics(s)
    local hh = math.max(1, math.floor(TILE_H * 0.5 * s + 0.5))
    local tw = hh * 4                -- keeps the 2:1 diamond ratio exact
    return tw, hh * 2, tw / TILE_W
end

function RoomView:new(game)
    local catalog_by_id = {}
    for _, it in ipairs(Catalog) do
        catalog_by_id[it.id] = it
    end
    self.catalog_by_id = catalog_by_id

    -- Load all layout positions: the autosaved draft, else room_layout
    local Layout = loadDraft() or Layout
    local placed = {}
    for id, info in pairs(Layout) do
        if id ~= "__meta" then
            placed[#placed + 1] = {
                id        = id,
                sprite    = info.sprite or id:match("^(.-)_%d+$"),
                gx        = info.gx or 0,
                gy        = info.gy or 0,
                w         = info.w or 1,
                h         = info.h or 1,
                z_offset  = info.z_offset or 0,
                dx        = info.dx or 0,
                layer     = info.layer or 0,
                sh        = info.sh or 16,
                color     = info.color or { 0.5, 0.5, 0.5 },
                scale     = info.scale or 1.0,
                flip_x    = info.flip_x or false,
                align     = info.align or "center",
                anim_room = info.anim_room,
                fps       = info.fps,
                frame     = info.frame,
                shader    = info.shader,
            }
        end
    end

    -- Create list of placeable catalog item specs dynamically from
    -- SpriteLoader and Catalog. `placeable` stays FLAT (selected_idx
    -- indexes it everywhere); `groups` is the browser's presentation:
    -- one collapsible group per top-level folder under isometric/, plus
    -- a "Catalog" group up front for the actual game items.
    local placeable = {}
    local sprites_seen = {}
    local groups   = {}       -- ordered: { name, indices = {..}, collapsed, is_catalog }
    local group_of = {}       -- placeable idx -> group ref
    local by_name  = {}       -- group name -> group ref
    local function groupFor(name, default_collapsed)
        local g = by_name[name]
        if not g then
            g = { name = name, indices = {}, collapsed = default_collapsed, is_catalog = (name == "Catalog") }
            by_name[name] = g
            groups[#groups + 1] = g
        end
        return g
    end
    local function addTo(group, idx)
        group.indices[#group.indices + 1] = idx
        group_of[idx] = group
    end

    -- Game catalog items first — they're the ones that matter in play.
    groupFor("Catalog", false)
    for _, item in ipairs(Catalog) do
        if not item.hidden and item.id ~= "no_poster_handicap" then
            placeable[#placeable + 1] = item
            addTo(by_name["Catalog"], #placeable)
        end
    end

    local floor_list = {}
    local wall_list = {}
    local floors_seen = {}
    local walls_seen = {}

    if game.sprite_loader and game.sprite_loader.sprites then
        local sprite_names = {}
        for name, _ in pairs(game.sprite_loader.sprites) do
            if name:sub(1, 10) == "isometric/" or name:sub(1, 15) == "TinyHouse_0.17(" then
                sprite_names[#sprite_names + 1] = name
            end
        end
        table.sort(sprite_names)

        for _, name in ipairs(sprite_names) do
            if not sprites_seen[name] then
                sprites_seen[name] = true
                -- "TinyHouse_0.17(@Pixel_Salvaje)/Bathroom/Duck" → group "Bathroom", label "Duck"
                -- "isometric/Bathroom/Bath_Ani/Bath_1" → group "Bathroom", label "Bath_Ani/Bath_1"
                local clean = name:match("^[^/]+/(.+)$") or name
                local folder, label = clean:match("^([^/]+)/(.+)$")
                if not folder then folder, label = "Furniture", clean end
                placeable[#placeable + 1] = {
                    id = name,
                    name = label,
                    sprite = name,
                }
                addTo(groupFor(folder, true), #placeable)
            end

            -- Also extract available Floor and Wall theme names
            local f_theme = name:match("Floor_Wall_Tiles_%d+/Floor_%d+_(.+)$")
            if f_theme then
                if not floors_seen[f_theme] then
                    floors_seen[f_theme] = true
                    floor_list[#floor_list + 1] = f_theme
                end
            end

            local w_theme = name:match("Floor_Wall_Tiles_%d+/Wall_L_%d+_(.+)$")
            if w_theme then
                if not walls_seen[w_theme] then
                    walls_seen[w_theme] = true
                    wall_list[#wall_list + 1] = w_theme
                end
            end
        end
    end
    table.sort(floor_list)
    table.sort(wall_list)

    local meta = Layout.__meta or {}
    local room_size = meta.room_size or GRID_SIZE
    local floor_theme = meta.floor_theme or "Default"
    local wall_theme = meta.wall_theme or "Default"
    local tile_set = meta.tile_set or Tiles.default_set
    local floor_flip = meta.floor_flip or false
    local wall_flip = meta.wall_flip or false
    local wall_courses = meta.wall_courses or Tiles.default_courses

    local floor_idx = 0
    for i, t in ipairs(floor_list) do
        if t == floor_theme then floor_idx = i; break end
    end
    local wall_idx = 0
    for i, t in ipairs(wall_list) do
        if t == wall_theme then wall_idx = i; break end
    end

    return setmetatable({
        game             = game,
        placed           = placed,     -- active placed furniture objects list
        placeable        = placeable,  -- flat list; selected_idx indexes this
        groups           = groups,     -- collapsible browser groups (presentation)
        group_of         = group_of,   -- placeable idx -> group (auto-expand)
        browser_tab      = 1,          -- 1: Catalog Items, 2: Flavor Assets
        editor_mode      = false,      -- true = grid lines, placement selector, mouse controls
        selected_idx     = 1,          -- active item index in the placeable list
        active_w         = 1,          -- current placement footprint width
        active_h         = 1,          -- current placement footprint height
        active_sh        = 16,         -- current placement visual thickness/height
        active_z         = 0,          -- current placement vertical height offset
        active_scale     = 1.0,        -- current sprite scale factor
        active_flip_x    = false,      -- current sprite horizontal flip
        active_align     = "center",   -- current sprite alignment mode ("center", "left_wall", "right_wall")
        active_anim_room = nil,        -- nil (default), true (force anim), false (force static)
        zoom             = 1.0,        -- editor view zoom about the room centre (Ctrl+wheel)
        -- "place": a click adds the selected item (a new copy).
        -- "replace": a click moves the copy already in the room to the
        -- mouse (adds it if there is none). M toggles. Clicks never grab
        -- what is placed; Alt+click does.
        mode             = "place",
        active_fps       = nil,        -- nil (default), numeric FPS
        active_frame     = nil,        -- nil (default), numeric frame index
        active_shader    = nil,        -- nil (default), string shader name
        active_color     = { 1.0, 1.0, 1.0 }, -- current item tint color
        hide_editor_hud  = false,      -- true = hide grid and HUD for clean scene preview
        show_help_overlay= false,      -- true = show spacious controls help modal
        snap_options     = { 1.0, 0.5, 0.25, 0.125 },
        snap_idx         = 4,          -- current grid snap option (defaults to 0.125)
        picked_item      = nil,
        list_scroll      = 0,          -- item-browser scroll offset (px)
        _list_rows       = {},         -- built each draw; consumed by mousepressed
        _list_rect       = nil,        -- browser viewport rect (hit-test + wheel)
        _scroll_to_sel   = false,     -- draw() brings the selected row into view

        room_size        = room_size,
        floor_list       = floor_list,
        wall_list        = wall_list,
        floor_idx        = floor_idx,
        wall_idx         = wall_idx,
        tile_set         = tile_set,      -- 32 | 64 | 128: the kit's pixel density
        floor_flip       = floor_flip,    -- mirror the floor tile
        wall_flip        = wall_flip,     -- mirror the walls (each side wears the other's face)
        wall_courses     = wall_courses,  -- courses stacked for wall height
    }, RoomView)
end

-- Selection moved (keys / wheel / pick-up): make sure its group is open
-- and ask the next draw to scroll the row into view.
function RoomView:_onSelectionChanged()
    local g = self.group_of and self.group_of[self.selected_idx]
    if g then g.collapsed = false end
    self._scroll_to_sel = true
end

-- Cycle selection strictly within the active browser_tab items
function RoomView:_cycleSelection(delta)
    local visible_indices = {}
    for _, g in ipairs(self.groups) do
        if (self.browser_tab == 1 and g.is_catalog) or (self.browser_tab == 2 and not g.is_catalog) then
            -- Only what the list shows: cycling never opens a folder.
            if not g.collapsed or delta == 0 then
                for _, idx in ipairs(g.indices) do
                    visible_indices[#visible_indices + 1] = idx
                end
            end
        end
    end
    if #visible_indices == 0 then return end

    local current_pos = 1
    for pos, idx in ipairs(visible_indices) do
        if idx == self.selected_idx then current_pos = pos; break end
    end

    local new_pos = current_pos + delta
    if new_pos < 1 then new_pos = #visible_indices end
    if new_pos > #visible_indices then new_pos = 1 end

    self.selected_idx = visible_indices[new_pos]
    self:syncActiveParams()
    self:_onSelectionChanged()
end

-- ─── Projection Math ────────────────────────────────────────────────────────

local function getCenter(W, H, s, full_screen)
    local TOP_BAR_H   = math.floor(56 * s)
    if full_screen then
        local cx          = W * 0.5
        local cy          = TOP_BAR_H + (H - TOP_BAR_H) * 0.45
        return cx, cy
    end
    -- Locate the center of the center grid viewport
    local LEFT_W      = math.floor(280 * s)
    local RIGHT_W     = math.floor(280 * s)
    local cx          = LEFT_W + (W - LEFT_W - RIGHT_W) * 0.5
    local cy          = TOP_BAR_H + (H - TOP_BAR_H) * 0.45 -- shift slightly up for room bottom clearance
    return cx, cy
end

local function gridToScreen(gx, gy, cx, cy, tw, th)
    local sx = cx + (gx - gy) * (tw * 0.5)
    local sy = cy + (gx + gy) * (th * 0.5)
    return sx, sy
end

local function screenToGrid(sx, sy, cx, cy, tw, th)
    local dx = sx - cx
    local dy = sy - cy
    local gx = (dx / (tw * 0.5) + dy / (th * 0.5)) * 0.5
    local gy = (dy / (th * 0.5) - dx / (tw * 0.5)) * 0.5
    return gx, gy
end

-- ─── Drawing helpers ───

-- Helper: darken a color slightly
local function darken(c, f)
    return { c[1] * f, c[2] * f, c[3] * f, c[4] }
end

-- Helper: Draw a shaded isometric cube/slab
local function drawIsoBox(x, y, w, h, z, sh, color, tw, th, cx, cy, s, scale, flip_x)
    local fl = math.floor
    scale = scale or 1.0

    -- Scale dimensions and height
    w = w * scale
    h = h * scale
    sh = sh * scale

    -- Floor vertices (shifted up by z_offset)
    local v1_x, v1_y = gridToScreen(x, y, cx, cy, tw, th)
    local v2_x, v2_y = gridToScreen(x + w, y, cx, cy, tw, th)
    local v3_x, v3_y = gridToScreen(x + w, y + h, cx, cy, tw, th)
    local v4_x, v4_y = gridToScreen(x, y + h, cx, cy, tw, th)

    v1_y = v1_y - z * s
    v2_y = v2_y - z * s
    v3_y = v3_y - z * s
    v4_y = v4_y - z * s

    -- Top vertices (extruded vertically by sh)
    local t1_x, t1_y = v1_x, v1_y - sh * s
    local t2_x, t2_y = v2_x, v2_y - sh * s
    local t3_x, t3_y = v3_x, v3_y - sh * s
    local t4_x, t4_y = v4_x, v4_y - sh * s

    -- 1. Left visible face
    Theme.setColor(darken(color, 0.82))
    love.graphics.polygon("fill",
        v2_x, v2_y,
        t2_x, t2_y,
        t3_x, t3_y,
        v3_x, v3_y
    )

    -- 2. Right visible face
    Theme.setColor(darken(color, 0.68))
    love.graphics.polygon("fill",
        v3_x, v3_y,
        t3_x, t3_y,
        t4_x, t4_y,
        v4_x, v4_y
    )

    -- 3. Top face
    Theme.setColor(color)
    love.graphics.polygon("fill",
        t1_x, t1_y,
        t2_x, t2_y,
        t3_x, t3_y,
        t4_x, t4_y
    )

    -- 4. Edges/Outlines
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(fl(1 * s))
    love.graphics.polygon("line", t1_x, t1_y, t2_x, t2_y, t3_x, t3_y, t4_x, t4_y)
    love.graphics.line(t2_x, t2_y, v2_x, v2_y)
    love.graphics.line(t3_x, t3_y, v3_x, v3_y)
    love.graphics.line(t4_x, t4_y, v4_x, v4_y)
    love.graphics.setLineWidth(1)

    -- Draw direction indicator line on top face
    local tc_x = (t1_x + t3_x) * 0.5
    local tc_y = (t1_y + t3_y) * 0.5
    Theme.setColor(Theme.status.warn)
    love.graphics.setLineWidth(2)
    if flip_x then
        love.graphics.line(tc_x, tc_y, (tc_x + t4_x) * 0.5, (tc_y + t4_y) * 0.5)
    else
        love.graphics.line(tc_x, tc_y, (tc_x + t2_x) * 0.5, (tc_y + t2_y) * 0.5)
    end
    love.graphics.setLineWidth(1)
end

-- ─── Main Interface ───

-- opts (optional): zoom = scale the room about its centre (the shove intro
-- draws it big); item_tint = fn(obj) -> {r,g,b,a} or nil, the colour a
-- placed item is drawn with (nil = normal). The centre and zoom used are
-- left in self._view = { cx, cy, zoom } so an overlay can match them.
function RoomView:draw(full_screen, opts)
    opts = opts or {}
    self._anchored_item = nil   -- "first placed item" hint anchor is per draw
    self.full_screen = full_screen
    local W, H = love.graphics.getDimensions()
    local game = self.game
    local s    = game.ui_scale or 1
    local fl   = math.floor
    local TOP_BAR_H = fl(56 * s)
    local cx, cy = getCenter(W, H, s, full_screen)
    cx = fl(cx + 0.5)
    cy = fl(cy + 0.5)

    local state = game.state
    local owned_set = {}
    if state.owned_items then
        for _, id in ipairs(state.owned_items) do
            owned_set[id] = true
        end
    end

    local tw, th, tile_k = tileMetrics(s)
    local wh = WALL_H * s

    -- The room (walls, floor, items, preview) draws zoomed about its centre;
    -- the HUD does not. Mouse positions are unzoomed with _unzoom.
    local zoom = opts.zoom or (self.editor_mode and (self.zoom or 1) or 1)
    local oy = opts.dy or 0
    self._view = { cx = cx, cy = cy, zoom = zoom, dy = oy }
    love.graphics.push()
    love.graphics.translate(cx, cy + oy)
    love.graphics.scale(zoom, zoom)
    love.graphics.translate(-cx, -cy)

    -- 1. Draw background walls (corner walls of the room - fallback vector or sprite segments)
    local l_wall_sprite = nil
    local r_wall_sprite = nil
    -- The kit: which pixel density, and its anchors. A theme missing from
    -- the chosen set falls back to the 64 set so the room never goes bare.
    local set = self.tile_set or Tiles.default_set
    local function kitSprite(pattern, theme)
        local sp = game.sprite_loader:getSprite(string.format(Tiles.folder .. pattern, set, set, theme))
        if sp then return sp, set end
        local d = Tiles.default_set
        return game.sprite_loader:getSprite(string.format(Tiles.folder .. pattern, d, d, theme)), d
    end
    local wall_set, floor_set = set, set
    if self.wall_idx > 0 then
        local theme = self.wall_list[self.wall_idx]
        l_wall_sprite, wall_set = kitSprite(Tiles.wall_l_name, theme)
        r_wall_sprite = kitSprite(Tiles.wall_r_name, theme)
        -- Hard pixel edges: linear filtering (LÖVE's default — nothing
        -- sets a default filter) bleeds each tile's transparent border
        -- into its edge at any non-integer scale, which reads as seams.
        if l_wall_sprite then l_wall_sprite:setFilter("nearest", "nearest") end
        if r_wall_sprite then r_wall_sprite:setFilter("nearest", "nearest") end
    end

    if l_wall_sprite and r_wall_sprite then
        -- One wall tile is a single ~40px course — the kit expects walls
        -- to be STACKED for height. Measured from the art: the face
        -- repeats every 40 sprite px (edge columns are 41px tall, so a
        -- 40px offset gives a 1px overlap and no gap), and each face
        -- runs clean to its bottom edge, so an upper course drawn AFTER
        -- covers the course-below's top-cap trim; the cap shows only on
        -- the topmost course.
        local A            = Tiles.anchors[wall_set]
        local wk           = tile_k * 64 / wall_set   -- the set's px -> screen
        local WALL_COURSES = self.wall_courses or Tiles.default_courses
        local course_dy    = A.course_px * wk

        -- Flipped walls: each side wears the other's face, mirrored, so
        -- the art's lighting swaps sides. The anchor mirrors with it.
        local flip = self.wall_flip
        local back_sprite = flip and l_wall_sprite or r_wall_sprite   -- the wall along y=0 (down-right)
        local side_sprite = flip and r_wall_sprite or l_wall_sprite   -- the wall along x=0 (down-left)
        local back_a = flip and A.wall_l or A.wall_r
        local side_a = flip and A.wall_r or A.wall_l
        local wsx = flip and -wk or wk

        love.graphics.setColor(1, 1, 1, 1)
        for x = 0, self.room_size - 1 do
            local wx, wy = gridToScreen(x, 0, cx, cy, tw, th)
            for level = 0, WALL_COURSES - 1 do
                love.graphics.draw(back_sprite, wx, wy - level * course_dy,
                    0, wsx, wk, back_a.ox, back_a.oy)
            end
        end
        for y = 0, self.room_size - 1 do
            local wx, wy = gridToScreen(0, y, cx, cy, tw, th)
            for level = 0, WALL_COURSES - 1 do
                love.graphics.draw(side_sprite, wx, wy - level * course_dy,
                    0, wsx, wk, side_a.ox, side_a.oy)
            end
        end
    else
        -- Left-back wall fallback polygon
        local lx1, ly1 = gridToScreen(0, 0, cx, cy, tw, th)
        local lx2, ly2 = gridToScreen(self.room_size, 0, cx, cy, tw, th)
        Theme.setColor(Theme.bg.sunken)
        love.graphics.polygon("fill",
            lx1, ly1,
            lx2, ly2,
            lx2, ly2 - wh,
            lx1, ly1 - wh
        )
        Theme.setColor(Theme.border.soft)
        love.graphics.polygon("line",
            lx1, ly1,
            lx2, ly2,
            lx2, ly2 - wh,
            lx1, ly1 - wh
        )

        -- Right-back wall fallback polygon
        local rx1, ry1 = gridToScreen(0, 0, cx, cy, tw, th)
        local rx2, ry2 = gridToScreen(0, self.room_size, cx, cy, tw, th)
        Theme.setColor(darken(Theme.bg.sunken, 0.90))
        love.graphics.polygon("fill",
            rx1, ry1,
            rx2, ry2,
            rx2, ry2 - wh,
            rx1, ry1 - wh
        )
        Theme.setColor(Theme.border.soft)
        love.graphics.polygon("line",
            rx1, ry1,
            rx2, ry2,
            rx2, ry2 - wh,
            rx1, ry1 - wh
        )
    end

    -- 2. Draw floor tiles grid
    local floor_sprite = nil
    if self.floor_idx > 0 then
        local theme = self.floor_list[self.floor_idx]
        floor_sprite, floor_set = kitSprite(Tiles.floor_name, theme)
        if floor_sprite then floor_sprite:setFilter("nearest", "nearest") end
    end
    local FA  = Tiles.anchors[floor_set]
    local fk  = tile_k * 64 / floor_set
    local fsx = self.floor_flip and -fk or fk

    for x = 0, self.room_size - 1 do
        for y = 0, self.room_size - 1 do
            local tx1, ty1 = gridToScreen(x, y, cx, cy, tw, th)
            if floor_sprite then
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(floor_sprite, tx1, ty1, 0, fsx, fk, FA.floor.ox, FA.floor.oy)
            else
                -- Checkerboard floor pattern fallback
                if (x + y) % 2 == 0 then
                    Theme.setColor(Theme.bg.widget)
                else
                    Theme.setColor(darken(Theme.bg.widget, 0.92))
                end
                local tx2, ty2 = gridToScreen(x + 1, y, cx, cy, tw, th)
                local tx3, ty3 = gridToScreen(x + 1, y + 1, cx, cy, tw, th)
                local tx4, ty4 = gridToScreen(x, y + 1, cx, cy, tw, th)
                love.graphics.polygon("fill", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)
            end

            -- Wireframe grid lines (only in editor mode when HUD is visible)
            if self.editor_mode and not self.hide_editor_hud then
                Theme.setColor(Theme.border.soft, 0.18)
                local tx2, ty2 = gridToScreen(x + 1, y, cx, cy, tw, th)
                local tx3, ty3 = gridToScreen(x + 1, y + 1, cx, cy, tw, th)
                local tx4, ty4 = gridToScreen(x, y + 1, cx, cy, tw, th)
                love.graphics.polygon("line", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)
            end
        end
    end

    -- 3. Gather items to render (owned only, unless in editor mode)
    local render_list = {}
    for _, obj in ipairs(self.placed) do
        local owned = owned_set[obj.id]
        if owned or self.editor_mode then
            render_list[#render_list + 1] = obj
        end
    end

    -- 4. Depth sort (Painter's algorithm: sort back-to-front by center index)
    -- `layer` (Z / X on the thing in hand) overrides depth: higher draws
    -- over everything on a lower layer, whatever its position.
    table.sort(render_list, function(a, b)
        local la, lb = a.layer or 0, b.layer or 0
        if la ~= lb then return la < lb end
        local depth_a = (a.gx + a.w * 0.5) + (a.gy + a.h * 0.5)
        local depth_b = (b.gx + b.w * 0.5) + (b.gy + b.h * 0.5)
        if math.abs(depth_a - depth_b) < 0.001 then
            -- Tie-breaker: draw wall attachments (z_offset > 0) behind floor attachments
            return (a.z_offset or 0) < (b.z_offset or 0)
        end
        return depth_a < depth_b
    end)

    -- 5. Draw the items. Their on-screen rects are kept (room space, in
    -- draw order) so move mode can grab what the mouse is actually on.
    self._hit_rects = {}
    local zmx0, zmy0 = self:_unzoom(love.mouse.getX(), love.mouse.getY(), cx, cy)
    for _, obj in ipairs(render_list) do
        local color = obj.color
        local is_owned = owned_set[obj.id] or self.editor_mode
        if not is_owned then
            -- Unowned items drawn slightly transparent/desaturated in editor mode
            color = { color[1], color[2], color[3], 0.40 }
        end
        
        local cat_item = self.catalog_by_id and self.catalog_by_id[obj.id] or {}
        local cat_anim = cat_item.anim or {}
        local obj_anim = obj.anim or {}

        -- Room default: Animated by default!
        -- Disabled if obj or cat_item explicitly sets anim_room = false or anim.room_enabled = false or anim.enabled = false
        local is_room_anim = true
        if obj.anim_room ~= nil then
            is_room_anim = obj.anim_room
        elseif obj_anim.room_enabled ~= nil then
            is_room_anim = obj_anim.room_enabled
        elseif obj_anim.enabled ~= nil then
            is_room_anim = obj_anim.enabled
        elseif cat_item.anim_room ~= nil then
            is_room_anim = cat_item.anim_room
        elseif cat_anim.room_enabled ~= nil then
            is_room_anim = cat_anim.room_enabled
        elseif cat_anim.enabled ~= nil then
            is_room_anim = cat_anim.enabled
        end

        if obj.frame then is_room_anim = false end
        local time_arg  = is_room_anim and love.timer.getTime() or false
        local fps_arg   = obj.fps or obj_anim.fps or cat_item.fps or cat_anim.fps
        local frame_arg = obj.frame or obj.static_frame or obj_anim.frame or cat_item.frame or cat_item.static_frame or cat_anim.frame

        local shader_name   = obj.shader or obj_anim.shader or cat_item.shader or cat_anim.shader
        local shader_params = obj.shader_params or obj_anim.shader_params or cat_item.shader_params or cat_anim.shader_params

        local sprite = game.sprite_loader:getSprite(obj.sprite or obj.id, time_arg, fps_arg, frame_arg)
        if sprite then
            local draw_gx, draw_gy
            if obj.align == "left_wall" then
                draw_gx = obj.gx + obj.w * 0.5
                draw_gy = obj.gy
            elseif obj.align == "right_wall" then
                draw_gx = obj.gx
                draw_gy = obj.gy + obj.h * 0.5
            else
                draw_gx = obj.gx + obj.w * 0.5
                draw_gy = obj.gy + obj.h * 0.5
            end
            local sx, sy = gridToScreen(draw_gx, draw_gy, cx, cy, tw, th)
            local scale_factor = obj.scale or 1.0
            local draw_scale_x = s * scale_factor
            local draw_scale_y = s * scale_factor
            
            local ox = sprite:getWidth() * 0.5
            local diff_y
            if obj.align == "left_wall" then
                diff_y = obj.w * 8
            elseif obj.align == "right_wall" then
                diff_y = obj.h * 8
            else
                diff_y = (obj.w + obj.h) * 8
            end
            local oy = getSpriteBottom(sprite, obj.sprite or obj.id) - diff_y
            
            if obj.flip_x then
                draw_scale_x = -draw_scale_x
            end
            
            local px = sx + (obj.dx or 0) * s
            local py = sy - (obj.z_offset or 0) * s

            local asx = math.abs(draw_scale_x)
            local rect = { obj = obj, x = px - ox * asx, y = py - oy * draw_scale_y,
                           w = sprite:getWidth() * asx, h = sprite:getHeight() * draw_scale_y }
            self._hit_rects[#self._hit_rects + 1] = rect

            local tint = opts.item_tint and opts.item_tint(obj)
            if tint then
                love.graphics.setColor(tint[1], tint[2], tint[3], tint[4] or 1)
            elseif not is_owned then
                love.graphics.setColor(1, 1, 1, 0.40)
            else
                love.graphics.setColor(1, 1, 1, 1)
            end
            -- Replace mode: the copy the click will move lights up.
            if self.editor_mode and self.mode == "replace" and not self.picked_item then
                local spec = self.placeable[self.selected_idx]
                if spec and (obj.id == spec.id or obj.sprite == (spec.sprite or spec.id)) then
                    love.graphics.setColor(1, 0.85, 0.5, 1)
                end
            end

            if shader_name and ShaderRegistry and ShaderRegistry.apply then
                ShaderRegistry.apply(shader_name, shader_params)
            end
            
            love.graphics.draw(sprite, px, py, 0, draw_scale_x, draw_scale_y, ox, oy)
            -- The first placed item, for a "your things end up here" hint.
            -- The rect is the drawn sprite's footprint on screen.
            if not self._anchored_item then
                self._anchored_item = true
                local sw = sprite:getWidth()  * math.abs(draw_scale_x or 1)
                local sh = sprite:getHeight() * (draw_scale_y or 1)
                Anchors.set("room:item:first",
                            px - (ox or 0) * math.abs(draw_scale_x or 1),
                            py - (oy or 0) * (draw_scale_y or 1), sw, sh)
            end

            if shader_name and ShaderRegistry and ShaderRegistry.apply then
                ShaderRegistry.apply(nil)
            end
        else
            drawIsoBox(obj.gx, obj.gy, obj.w, obj.h, obj.z_offset, obj.sh, color, tw, th, cx, cy, s, obj.scale, obj.flip_x)
        end
    end

    love.graphics.pop()

    -- 6. Editor overlay: Selected active item preview + cursor grid position
    local mx, my = love.mouse.getPosition()
    local zmx, zmy = self:_unzoom(mx, my, cx, cy)
    local gx, gy = screenToGrid(zmx, zmy, cx, cy, tw, th)
    local step = self.snap_options[self.snap_idx] or 0.125
    gx = math.floor(gx / step + 0.5) * step
    gy = math.floor(gy / step + 0.5) * step

    local active_spec = self.placeable[self.selected_idx]

    if self.editor_mode and active_spec then
        love.graphics.push()
        love.graphics.translate(cx, cy)
        love.graphics.scale(zoom, zoom)
        love.graphics.translate(-cx, -cy)
        -- Hover preview tile highlighting
        if gx >= 0 and gx + self.active_w <= self.room_size and gy >= 0 and gy + self.active_h <= self.room_size then
            local tx1, ty1 = gridToScreen(gx, gy, cx, cy, tw, th)
            local tx2, ty2 = gridToScreen(gx + self.active_w, gy, cx, cy, tw, th)
            local tx3, ty3 = gridToScreen(gx + self.active_w, gy + self.active_h, cx, cy, tw, th)
            local tx4, ty4 = gridToScreen(gx, gy + self.active_h, cx, cy, tw, th)

            -- Fill footprint highlight green
            Theme.setColor(Theme.status.good, 0.25)
            love.graphics.polygon("fill", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)
            Theme.setColor(Theme.status.good, 0.8)
            love.graphics.polygon("line", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)

            -- Draw placement preview block (sprite or fallback box)
            local pv_anim = self.active_anim_room
            if pv_anim == nil then
                local ca = active_spec.anim or {}
                if active_spec.anim_room ~= nil then pv_anim = active_spec.anim_room
                elseif ca.room_enabled ~= nil then pv_anim = ca.room_enabled
                elseif ca.enabled ~= nil then pv_anim = ca.enabled
                else pv_anim = true end
            end
            if self.active_frame then pv_anim = false end
            local pv_time = pv_anim and love.timer.getTime() or false
            local sprite = game.sprite_loader:getSprite(active_spec.sprite or active_spec.id,
                pv_time, self.active_fps or active_spec.fps, self.active_frame or active_spec.frame)
            if sprite then
                local draw_gx, draw_gy
                if self.active_align == "left_wall" then
                    draw_gx = gx + self.active_w * 0.5
                    draw_gy = gy
                elseif self.active_align == "right_wall" then
                    draw_gx = gx
                    draw_gy = gy + self.active_h * 0.5
                else
                    draw_gx = gx + self.active_w * 0.5
                    draw_gy = gy + self.active_h * 0.5
                end
                local sx, sy = gridToScreen(draw_gx, draw_gy, cx, cy, tw, th)
                local scale_factor = self.active_scale or 1.0
                local draw_scale_x = s * scale_factor
                local draw_scale_y = s * scale_factor
                
                local ox = sprite:getWidth() * 0.5
                local diff_y
                if self.active_align == "left_wall" then
                    diff_y = self.active_w * 8
                elseif self.active_align == "right_wall" then
                    diff_y = self.active_h * 8
                else
                    diff_y = (self.active_w + self.active_h) * 8
                end
                local oy = getSpriteBottom(sprite, active_spec.sprite or active_spec.id) - diff_y
                
                if self.active_flip_x then
                    draw_scale_x = -draw_scale_x
                end
                
                local px = sx + (self.active_dx or 0) * s
                local py = sy - self.active_z * s
                
                love.graphics.setColor(1, 1, 1, 0.60)
                love.graphics.draw(sprite, px, py, 0, draw_scale_x, draw_scale_y, ox, oy)
            else
                local preview_c = { 0.92, 0.72, 0.32, 0.50 } -- translucent amber
                drawIsoBox(gx, gy, self.active_w, self.active_h, self.active_z, self.active_sh, preview_c, tw, th, cx, cy, s, self.active_scale, self.active_flip_x)
            end
        end
        love.graphics.pop()

        if not self.hide_editor_hud then
            -- ── Top Toolbar (Action buttons & Meta selectors in top bar)
            local bar_y = 0
            local bar_h = TOP_BAR_H
            local toolbar_x = math.max(fl(180 * s), fl(285 * s))
            local tb_y = fl(12 * s)
            local tb_h = fl(32 * s)
            local btn_w = fl(72 * s)

            -- EXPORT
            local exp_x = toolbar_x
            local exp_hov = mx >= exp_x and mx < exp_x + btn_w and my >= tb_y and my < tb_y + tb_h
            LabelButton.draw{
                x = exp_x, y = tb_y, w = btn_w, h = tb_h,
                text = "EXPORT", fonts = game.fonts, font = game.fonts.sm, hovered = exp_hov,
            }
            self._exp_btn_rect = { x = exp_x, y = tb_y, w = btn_w, h = tb_h }

            -- RESET
            local rst_x = exp_x + btn_w + fl(6 * s)
            local rst_hov = mx >= rst_x and mx < rst_x + btn_w and my >= tb_y and my < tb_y + tb_h
            LabelButton.draw{
                x = rst_x, y = tb_y, w = btn_w, h = tb_h,
                text = "RESET", fonts = game.fonts, font = game.fonts.sm, hovered = rst_hov,
            }
            self._rst_btn_rect = { x = rst_x, y = tb_y, w = btn_w, h = tb_h }

            -- CLEAR
            local clr_x = rst_x + btn_w + fl(6 * s)
            local clr_hov = mx >= clr_x and mx < clr_x + btn_w and my >= tb_y and my < tb_y + tb_h
            LabelButton.draw{
                x = clr_x, y = tb_y, w = btn_w, h = tb_h,
                text = "CLEAR", fonts = game.fonts, font = game.fonts.sm, hovered = clr_hov,
            }
            self._clr_btn_rect = { x = clr_x, y = tb_y, w = btn_w, h = tb_h }

            -- HELP [H]
            local help_x = clr_x + btn_w + fl(6 * s)
            local help_w = fl(76 * s)
            local help_hov = mx >= help_x and mx < help_x + help_w and my >= tb_y and my < tb_y + tb_h
            LabelButton.draw{
                x = help_x, y = tb_y, w = help_w, h = tb_h,
                text = "HELP [H]", fonts = game.fonts, font = game.fonts.sm, hovered = help_hov,
            }
            self._help_btn_rect = { x = help_x, y = tb_y, w = help_w, h = tb_h }

            -- Meta Config selectors (Size, Floor, Wall) in top bar
            local meta_x = help_x + help_w + fl(14 * s)
            local arrow_w = fl(16 * s)
            local arrow_h = fl(16 * s)

            -- 1. Room Size
            local size_val = tostring(self.room_size) .. "x" .. tostring(self.room_size)
            love.graphics.setFont(game.fonts.sm)
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("Size:", meta_x, tb_y + fl(6 * s))
            local val_x = meta_x + fl(32 * s)
            Theme.setColor(Theme.fg.heading)
            love.graphics.print(size_val, val_x, tb_y + fl(6 * s))

            local sp_hov = mx >= val_x + fl(28 * s) and mx < val_x + fl(28 * s) + arrow_w and my >= tb_y + fl(4 * s) and my < tb_y + fl(4 * s) + arrow_h
            local sn_hov = mx >= val_x + fl(46 * s) and mx < val_x + fl(46 * s) + arrow_w and my >= tb_y + fl(4 * s) and my < tb_y + fl(4 * s) + arrow_h

            LabelButton.draw{ x = val_x + fl(28 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h, text = "<", fonts = game.fonts, font = game.fonts.sm, hovered = sp_hov }
            LabelButton.draw{ x = val_x + fl(46 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h, text = ">", fonts = game.fonts, font = game.fonts.sm, hovered = sn_hov }
            self._size_prev_rect = { x = val_x + fl(28 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h }
            self._size_next_rect = { x = val_x + fl(46 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h }

            -- 2. Floor Theme
            local floor_x = meta_x + fl(115 * s)
            local floor_val = self.floor_idx == 0 and "Default" or self.floor_list[self.floor_idx]
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("Floor:", floor_x, tb_y + fl(6 * s))
            local fval_x = floor_x + fl(38 * s)
            Theme.setColor(Theme.fg.heading)
            love.graphics.print(floor_val, fval_x, tb_y + fl(6 * s))

            local fp_hov = mx >= fval_x + fl(55 * s) and mx < fval_x + fl(55 * s) + arrow_w and my >= tb_y + fl(4 * s) and my < tb_y + fl(4 * s) + arrow_h
            local fn_hov = mx >= fval_x + fl(73 * s) and mx < fval_x + fl(73 * s) + arrow_w and my >= tb_y + fl(4 * s) and my < tb_y + fl(4 * s) + arrow_h

            LabelButton.draw{ x = fval_x + fl(55 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h, text = "<", fonts = game.fonts, font = game.fonts.sm, hovered = fp_hov }
            LabelButton.draw{ x = fval_x + fl(73 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h, text = ">", fonts = game.fonts, font = game.fonts.sm, hovered = fn_hov }
            self._floor_prev_rect = { x = fval_x + fl(55 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h }
            self._floor_next_rect = { x = fval_x + fl(73 * s), y = tb_y + fl(4 * s), w = arrow_w, h = arrow_h }

            -- ── Room row: wall, kit size, courses, flips (second row, under the bar)
            -- Every control is { rect, fn }; mousepressed walks the list.
            self._room_ctls = {}
            local ry  = TOP_BAR_H + fl(6 * s)
            local rx  = fl(292 * s)
            local function selector(label, value, prev_fn, next_fn)
                Theme.setColor(Theme.fg.muted)
                love.graphics.print(label, rx, ry + fl(6 * s))
                rx = rx + game.fonts.sm:getWidth(label) + fl(6 * s)
                Theme.setColor(Theme.fg.heading)
                love.graphics.print(value, rx, ry + fl(6 * s))
                rx = rx + math.max(fl(48 * s), game.fonts.sm:getWidth(value) + fl(6 * s))
                for _, b in ipairs{ { "<", prev_fn }, { ">", next_fn } } do
                    local r = { x = rx, y = ry + fl(4 * s), w = arrow_w, h = arrow_h }
                    local hov = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
                    LabelButton.draw{ x = r.x, y = r.y, w = r.w, h = r.h, text = b[1], fonts = game.fonts, font = game.fonts.sm, hovered = hov }
                    self._room_ctls[#self._room_ctls + 1] = { rect = r, fn = b[2] }
                    rx = rx + arrow_w + fl(2 * s)
                end
                rx = rx + fl(14 * s)
            end
            local function toggle(label, on, fn)
                local r = { x = rx, y = ry + fl(4 * s), w = game.fonts.sm:getWidth(label) + fl(16 * s), h = arrow_h }
                local hov = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
                LabelButton.draw{ x = r.x, y = r.y, w = r.w, h = r.h, text = label, fonts = game.fonts, font = game.fonts.sm,
                    hovered = hov, fill_override = on and { 0.18, 0.42, 0.62 } or nil }
                self._room_ctls[#self._room_ctls + 1] = { rect = r, fn = fn }
                rx = rx + r.w + fl(8 * s)
            end
            Theme.setColor(Theme.bg.chrome, 0.92)
            love.graphics.rectangle("fill", fl(284 * s), TOP_BAR_H, W - fl(284 * s), fl(34 * s))
            local wall_val = self.wall_idx == 0 and "Default" or self.wall_list[self.wall_idx]
            selector("Wall:", wall_val,
                function() self.wall_idx = self.wall_idx - 1; if self.wall_idx < 0 then self.wall_idx = #self.wall_list end end,
                function() self.wall_idx = self.wall_idx + 1; if self.wall_idx > #self.wall_list then self.wall_idx = 0 end end)
            local function stepSet(d)
                local i = 1
                for k, v in ipairs(Tiles.sets) do if v == self.tile_set then i = k end end
                i = ((i - 1 + d) % #Tiles.sets) + 1
                self.tile_set = Tiles.sets[i]
            end
            selector("Tiles:", tostring(self.tile_set) .. "px", function() stepSet(-1) end, function() stepSet(1) end)
            selector("Courses:", tostring(self.wall_courses),
                function() self.wall_courses = math.max(1, self.wall_courses - 1) end,
                function() self.wall_courses = math.min(Tiles.max_courses, self.wall_courses + 1) end)
            toggle("FLIP FLOOR", self.floor_flip, function() self.floor_flip = not self.floor_flip end)
            toggle("FLIP WALLS", self.wall_flip, function() self.wall_flip = not self.wall_flip end)

            -- ── Left Sidebar Panel for Asset Browser (100% Dedicated Full Height)
            local sidebar_w = fl(280 * s)
            local sidebar_h = H - TOP_BAR_H
            local sidebar_x = 0
            local sidebar_y = TOP_BAR_H
            local text_margin = fl(12 * s)

            Theme.setColor(Theme.bg.chrome, 0.96)
            love.graphics.rectangle("fill", sidebar_x, sidebar_y, sidebar_w, sidebar_h)
            Theme.setColor(Theme.border.soft)
            love.graphics.line(sidebar_x + sidebar_w - 1, sidebar_y, sidebar_x + sidebar_w - 1, sidebar_y + sidebar_h)

            -- Count catalog & flavor items
            local cat_count = 0
            local flv_count = 0
            for _, g in ipairs(self.groups) do
                if g.is_catalog then cat_count = cat_count + #g.indices
                else flv_count = flv_count + #g.indices end
            end

            -- ── Category Tabs (PROMINENT, UNMISTAKABLE AT TOP OF SIDEBAR)
            local tab_y = sidebar_y + fl(8 * s)
            local tab_h = fl(28 * s)
            local tab_w = fl((sidebar_w - text_margin * 2 - fl(6 * s)) * 0.5)
            local tab1_x = sidebar_x + text_margin
            local tab2_x = tab1_x + tab_w + fl(6 * s)

            local tab1_hov = mx >= tab1_x and mx < tab1_x + tab_w and my >= tab_y and my < tab_y + tab_h
            local tab2_hov = mx >= tab2_x and mx < tab2_x + tab_w and my >= tab_y and my < tab_y + tab_h

            LabelButton.draw{
                x = tab1_x, y = tab_y, w = tab_w, h = tab_h,
                text          = "1. CATALOG (" .. cat_count .. ")",
                fonts         = game.fonts, font = game.fonts.sm,
                hovered       = tab1_hov,
                fill_override = self.browser_tab == 1 and { 0.18, 0.42, 0.62 } or { 0.12, 0.14, 0.18 },
            }
            LabelButton.draw{
                x = tab2_x, y = tab_y, w = tab_w, h = tab_h,
                text          = "2. FLAVOR (" .. flv_count .. ")",
                fonts         = game.fonts, font = game.fonts.sm,
                hovered       = tab2_hov,
                fill_override = self.browser_tab == 2 and { 0.18, 0.42, 0.62 } or { 0.12, 0.14, 0.18 },
            }

            -- Section Header
            local head_y = tab_y + tab_h + fl(8 * s)
            love.graphics.setFont(game.fonts.sm)
            Theme.setColor(Theme.fg.heading)
            local tab_title = self.browser_tab == 1 and "CATALOG ITEMS" or "FLAVOR ASSETS"
            local title_str = string.format("%s (%d):", tab_title, self.browser_tab == 1 and cat_count or flv_count)
            love.graphics.print(title_str, sidebar_x + text_margin, head_y)

            -- Scrolling Viewport starts cleanly 22px BELOW head_y with zero overlap!
            local sm     = game.fonts.sm
            local row_h  = sm:getHeight() + fl(4 * s)
            local view_y = head_y + sm:getHeight() + fl(8 * s)
            local view_h = (sidebar_y + sidebar_h) - view_y - fl(26 * s)
            self._list_rect = { x = sidebar_x, y = view_y, w = sidebar_w, h = view_h }

            -- Filter groups based on active browser tab
            local visible_groups = {}
            for _, g in ipairs(self.groups) do
                if (self.browser_tab == 1 and g.is_catalog) or (self.browser_tab == 2 and not g.is_catalog) then
                    visible_groups[#visible_groups + 1] = g
                end
            end

            local placed_map = {}
            for _, p in ipairs(self.placed) do placed_map[p.id] = true end

            -- Virtual layout pass
            local rows, vy, sel_vy = {}, 0, nil
            for _, g in ipairs(visible_groups) do
                rows[#rows + 1] = { kind = "group", group = g, vy = vy }
                vy = vy + row_h
                if not g.collapsed then
                    for _, idx in ipairs(g.indices) do
                        rows[#rows + 1] = { kind = "item", idx = idx, vy = vy }
                        if idx == self.selected_idx then sel_vy = vy end
                        vy = vy + row_h
                    end
                end
            end
            local total_h    = vy
            local max_scroll = math.max(0, total_h - view_h)

            -- Auto-scroll selection into view when selection changes
            if self._scroll_to_sel then
                self._scroll_to_sel = false
                if sel_vy then
                    if sel_vy < self.list_scroll then
                        self.list_scroll = sel_vy
                    elseif sel_vy + row_h > self.list_scroll + view_h then
                        self.list_scroll = sel_vy + row_h - view_h
                    end
                end
            end
            if self.list_scroll > max_scroll then self.list_scroll = max_scroll end
            if self.list_scroll < 0 then self.list_scroll = 0 end

            self._list_rows = rows
            for _, row in ipairs(rows) do
                row.y = view_y + row.vy - self.list_scroll
                row.h = row_h
            end

            local label_w = sidebar_w - text_margin * 2 - fl(14 * s)
            local function trimmed(item)
                if item._trim and item._trim_w == label_w then return item._trim end
                local txt = item.name or item.id
                if sm:getWidth(txt) > label_w then
                    repeat txt = txt:sub(1, -2)
                    until sm:getWidth(txt .. "…") <= label_w or #txt <= 1
                    txt = txt .. "…"
                end
                item._trim, item._trim_w = txt, label_w
                return txt
            end

            love.graphics.setScissor(sidebar_x, view_y, sidebar_w, view_h)
            love.graphics.setFont(sm)
            local text_pad = fl(2 * s)
            for _, row in ipairs(rows) do
                if row.y + row_h >= view_y and row.y <= view_y + view_h then
                    if row.kind == "group" then
                        local g   = row.group
                        local hov = mx >= sidebar_x and mx < sidebar_x + sidebar_w
                                and my >= row.y and my < row.y + row_h
                        if hov then
                            Theme.setColor(Theme.bg.widget_hover)
                            love.graphics.rectangle("fill", sidebar_x, row.y, sidebar_w, row_h)
                        end
                        Theme.setColor(Theme.fg.heading)
                        love.graphics.print(
                            (g.collapsed and "+ " or "- ") .. g.name
                            .. " (" .. #g.indices .. ")",
                            sidebar_x + text_margin, row.y + text_pad)
                    else
                        local item      = self.placeable[row.idx]
                        local active    = (row.idx == self.selected_idx)
                        local is_placed = placed_map[item.id]
                        local hov       = mx >= sidebar_x and mx < sidebar_x + sidebar_w
                                and my >= row.y and my < row.y + row_h
                        if active then
                            Theme.setColor(Theme.bg.widget_hover)
                            love.graphics.rectangle("fill", sidebar_x, row.y, sidebar_w, row_h)
                            if is_placed then
                                Theme.setColor(Theme.status.good)
                            else
                                Theme.setColor(Theme.status.warn)
                            end
                            local prefix = is_placed and "> [✓] " or "> "
                            love.graphics.print(prefix .. trimmed(item),
                                sidebar_x + text_margin, row.y + text_pad)
                        else
                            if hov then
                                Theme.setColor(Theme.bg.widget_hover, 0.5)
                                love.graphics.rectangle("fill", sidebar_x, row.y, sidebar_w, row_h)
                            end
                            if is_placed then
                                Theme.setColor(Theme.status.good)
                                love.graphics.print("  [✓] " .. trimmed(item),
                                    sidebar_x + text_margin, row.y + text_pad)
                            else
                                Theme.setColor(Theme.fg.primary)
                                love.graphics.print("      " .. trimmed(item),
                                    sidebar_x + text_margin, row.y + text_pad)
                            end
                        end
                    end
                end
            end
            love.graphics.setScissor()

            -- Scrollbar
            local thumb_h = math.max(fl(20 * s), view_h * (view_h / math.max(1, total_h)))
            self._list_bar = { x = sidebar_x + sidebar_w - fl(14 * s), w = fl(14 * s),
                               y = view_y, h = view_h, max_scroll = max_scroll, thumb_h = thumb_h }
            if max_scroll > 0 then
                local thumb_y = view_y + (view_h - thumb_h) * (self.list_scroll / max_scroll)
                Theme.setColor(Theme.bg.sunken, 0.6)
                love.graphics.rectangle("fill", sidebar_x + sidebar_w - 6, view_y, 4, view_h, 2)
                Theme.setColor(Theme.fg.muted)
                love.graphics.rectangle("fill", sidebar_x + sidebar_w - 6, thumb_y, 4, thumb_h, 2)
            end

            -- Bottom Status Bar
            local sb_h = fl(24 * s)
            local sb_y = H - sb_h
            Theme.setColor({ 0.08, 0.10, 0.14, 0.90 })
            love.graphics.rectangle("fill", 0, sb_y, W, sb_h)
            Theme.setColor(Theme.fg.muted)
            love.graphics.setFont(game.fonts.sm)
            local active_tab_str = self.browser_tab == 1 and "1. CATALOG" or "2. FLAVOR"
            local n_frames = self:_activeFrameCount()
            local anim_str
            if self.active_frame then
                anim_str = string.format("FRAME %d/%d (still)", self.active_frame, n_frames)
            elseif self.active_anim_room == false then
                anim_str = string.format("STILL frame 1/%d", n_frames)
            else
                anim_str = string.format("ANIM %d frames @ %s fps", n_frames, tostring(self.active_fps or "default"))
            end
            local mode_str = self.mode == "replace" and "REPLACE (M): click moves the existing copy" or "PLACE (M): click adds a copy"
            local sb_msg = string.format("%s | [%s] | LAYER %d (Z/X) | %s | Frame: , . | FPS: - = | Anim: V | [H] Controls | Enter: Export", mode_str, active_tab_str, self.active_layer or 0, anim_str)
            love.graphics.print(sb_msg, fl(12 * s), sb_y + fl(4 * s))
        else
            -- Clean preview mode: draw small bottom prompt
            local bw, bh = fl(340 * s), fl(24 * s)
            local bx = (W - bw) * 0.5
            local by = H - bh - fl(8 * s)
            Theme.setColor({ 0.1, 0.1, 0.12, 0.75 })
            love.graphics.rectangle("fill", bx, by, bw, bh, 4)
            Theme.setColor(Theme.fg.muted)
            love.graphics.setFont(game.fonts.sm)
            local msg = "CLEAN PREVIEW MODE | PRESS [H] FOR HUD"
            local tw = game.fonts.sm:getWidth(msg)
            love.graphics.print(msg, bx + (bw - tw) * 0.5, by + fl(4 * s))
        end
    end

    -- Render Top-Right Non-Modal Instructions Panel (Hidable with H)
    if self.editor_mode and self.show_help_overlay then
        local pw = fl(270 * s)
        local ph = fl(360 * s)
        local px = W - pw - fl(16 * s)
        local py = TOP_BAR_H + fl(12 * s)

        Theme.setColor(Theme.bg.chrome, 0.94)
        love.graphics.rectangle("fill", px, py, pw, ph, 6)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, py, pw, ph, 6)

        -- Panel Header
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(game.fonts.md)
        love.graphics.print("EDITOR KEYS [H]", px + fl(10 * s), py + fl(8 * s))

        love.graphics.setFont(game.fonts.sm)
        local iy = py + fl(30 * s)
        local ilh = fl(13 * s)

        Theme.setColor(Theme.status.warn)
        love.graphics.print("NAVIGATION & PLACEMENT", px + fl(10 * s), iy); iy = iy + ilh

        -- Every key RoomView:keypressed actually handles, and nothing else.
        Theme.setColor(Theme.fg.primary)
        love.graphics.print("• TAB : Catalog / Flavor tab", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• Q / E : Cycle item (open folders)   Ctrl+Wheel : Zoom", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• List: wheel, drag the bar, PgUp / PgDn / Home / End", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• M : PLACE (click adds a copy) / REPLACE (click moves it)", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• L-Click : Place   Alt+L-Click : Grab   Alt+R-Click : Delete", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• Shift+L-Click : Stack on surface", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• Ctrl+Arrows : Move the sprite in px (hold, Shift x8)", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• G : Grid step   D : Clone   Z / X : Layer down / up", px + fl(10 * s), iy); iy = iy + ilh + fl(4 * s)

        Theme.setColor(Theme.status.warn)
        love.graphics.print("TRANSFORMS & STYLING", px + fl(10 * s), iy); iy = iy + ilh

        Theme.setColor(Theme.fg.primary)
        love.graphics.print("• 1 / 2 : Width -/+   3 / 4 : Depth -/+", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• 5 / 6 : Thickness   7 / 8 : Height (Shift x8)", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• 9 / 0 : Scale   F / R / A : Flip / Rotate / Align", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• T : Tint   S : Shader   V : Anim on/off", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• Comma , and period . : previous / next frame (also [ and ])", px + fl(10 * s), iy); iy = iy + ilh
        love.graphics.print("• Minus - and equals = : slower / faster FPS", px + fl(10 * s), iy); iy = iy + ilh + fl(4 * s)

        Theme.setColor(Theme.status.warn)
        love.graphics.print("EXIT", px + fl(10 * s), iy); iy = iy + ilh
        Theme.setColor(Theme.fg.primary)
        love.graphics.print("• Enter : Export layout   F3 / Esc : Leave editor", px + fl(10 * s), iy)
    end

    -- Render Toast Notification Banner when layout exported
    if self.export_toast_time and self.export_toast_time > 0 then
        local dt = love.timer and love.timer.getDelta() or 0.016
        self.export_toast_time = self.export_toast_time - dt
        local banner_w = fl(440 * s)
        local banner_h = fl(36 * s)
        local banner_x = (W - banner_w) * 0.5
        local banner_y = fl(12 * s) + (top_bar_present and fl(56 * s) or 0)
        local alpha = math.min(1.0, self.export_toast_time * 2.0)

        Theme.setColor({ 0.15, 0.45, 0.25, 0.95 * alpha })
        love.graphics.rectangle("fill", banner_x, banner_y, banner_w, banner_h, 6)
        Theme.setColor({ 0.40, 0.85, 0.50, 1.0 * alpha })
        love.graphics.rectangle("line", banner_x, banner_y, banner_w, banner_h, 6)
        Theme.setColor({ 1.0, 1.0, 1.0, 1.0 * alpha })
        love.graphics.setFont(game.fonts.md)
        local msg = self.export_written and "SAVED TO data/room_layout.lua" or "LAYOUT EXPORTED TO CONSOLE & FILE"
        local tw = game.fonts.md:getWidth(msg)
        love.graphics.print(msg, banner_x + (banner_w - tw) * 0.5, banner_y + fl(8 * s))
    end
end

function RoomView:mousepressed(x, y, button)
    if not self.editor_mode then return false end
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1

    -- The room row under the top bar (wall / tiles / courses / flips)
    if button == 1 then
        for _, c in ipairs(self._room_ctls or {}) do
            local r = c.rect
            if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
                c.fn()
                ClickFlash.flash("room_btn", "room_btn")
                return true
            end
        end
    end

    -- Check Top Toolbar clicks (Export, Reset, Clear, Help, Meta Selectors)
    if y < math.floor(56 * s) then
        if button == 1 then
            if self._exp_btn_rect and x >= self._exp_btn_rect.x and x < self._exp_btn_rect.x + self._exp_btn_rect.w
               and y >= self._exp_btn_rect.y and y < self._exp_btn_rect.y + self._exp_btn_rect.h then
                ClickFlash.flash("room_btn", "room_btn")
                self:serializeLayout()
                return true
            elseif self._rst_btn_rect and x >= self._rst_btn_rect.x and x < self._rst_btn_rect.x + self._rst_btn_rect.w
               and y >= self._rst_btn_rect.y and y < self._rst_btn_rect.y + self._rst_btn_rect.h then
                ClickFlash.flash("room_btn", "room_btn")
                self.placed = {}
                backupDraft(nil)
                pcall(love.filesystem.remove, DRAFT_FILE)
                self._last_autosave = nil
                for id, info in pairs(Layout) do
                    if id ~= "__meta" then
                        self.placed[#self.placed + 1] = {
                            id       = id,
                            sprite    = info.sprite or id:match("^(.-)_%d+$"),
                            gx       = info.gx or 0,
                            gy       = info.gy or 0,
                            w        = info.w or 1,
                            h        = info.h or 1,
                            z_offset = info.z_offset or 0,
                            dx       = info.dx or 0,
                            layer     = info.layer or 0,
                            sh       = info.sh or 16,
                            color    = info.color or { 0.5, 0.5, 0.5 },
                            scale    = info.scale or 1.0,
                            flip_x   = info.flip_x or false,
                            align    = info.align or "center",
                        }
                    end
                end
                self.picked_item = nil
                print("[room-editor] Reset all layout changes to saved defaults")
                return true
            elseif self._clr_btn_rect and x >= self._clr_btn_rect.x and x < self._clr_btn_rect.x + self._clr_btn_rect.w
               and y >= self._clr_btn_rect.y and y < self._clr_btn_rect.y + self._clr_btn_rect.h then
                ClickFlash.flash("room_btn", "room_btn")
                self.placed = {}
                self.picked_item = nil
                print("[room-editor] Cleared all furniture items in room")
                return true
            elseif self._help_btn_rect and x >= self._help_btn_rect.x and x < self._help_btn_rect.x + self._help_btn_rect.w
               and y >= self._help_btn_rect.y and y < self._help_btn_rect.y + self._help_btn_rect.h then
                ClickFlash.flash("room_btn", "room_btn")
                self.hide_editor_hud = not self.hide_editor_hud
                return true
            end

            -- Hit test Room Size arrows
            if self._size_prev_rect and x >= self._size_prev_rect.x and x < self._size_prev_rect.x + self._size_prev_rect.w
               and y >= self._size_prev_rect.y and y < self._size_prev_rect.y + self._size_prev_rect.h then
                self.room_size = math.max(4, self.room_size - 1)
                ClickFlash.flash("room_btn", "room_btn")
                return true
            elseif self._size_next_rect and x >= self._size_next_rect.x and x < self._size_next_rect.x + self._size_next_rect.w
               and y >= self._size_next_rect.y and y < self._size_next_rect.y + self._size_next_rect.h then
                self.room_size = math.min(16, self.room_size + 1)
                ClickFlash.flash("room_btn", "room_btn")
                return true
            end

            -- Hit test Floor Theme arrows
            if self._floor_prev_rect and x >= self._floor_prev_rect.x and x < self._floor_prev_rect.x + self._floor_prev_rect.w
               and y >= self._floor_prev_rect.y and y < self._floor_prev_rect.y + self._floor_prev_rect.h then
                self.floor_idx = self.floor_idx - 1
                if self.floor_idx < 0 then self.floor_idx = #self.floor_list end
                ClickFlash.flash("room_btn", "room_btn")
                return true
            elseif self._floor_next_rect and x >= self._floor_next_rect.x and x < self._floor_next_rect.x + self._floor_next_rect.w
               and y >= self._floor_next_rect.y and y < self._floor_next_rect.y + self._floor_next_rect.h then
                self.floor_idx = self.floor_idx + 1
                if self.floor_idx > #self.floor_list then self.floor_idx = 0 end
                ClickFlash.flash("room_btn", "room_btn")
                return true
            end
        end
        return true
    end

    -- Check Left Sidebar Asset Browser clicks
    if x < math.floor(280 * s) then
        local sidebar_w = math.floor(280 * s)
        local sidebar_x = 0
        local sidebar_y = math.floor(56 * s)
        local text_margin = math.floor(12 * s)

        -- Hit test Category Tab Buttons
        local tab_y = sidebar_y + math.floor(8 * s)
        local tab_h = math.floor(28 * s)
        local tab_w = math.floor((sidebar_w - text_margin * 2 - math.floor(6 * s)) * 0.5)
        local tab1_x = sidebar_x + text_margin
        local tab2_x = tab1_x + tab_w + math.floor(6 * s)

        if button == 1 and y >= tab_y and y < tab_y + tab_h then
            local new_tab = nil
            if x >= tab1_x and x < tab1_x + tab_w then
                new_tab = 1
            elseif x >= tab2_x and x < tab2_x + tab_w then
                new_tab = 2
            end

            if new_tab then
                self.browser_tab = new_tab
                ClickFlash.flash("room_btn", "room_btn")
                self:_cycleSelection(0)
                return true
            end
        end

        -- Scrollbar: click jumps there and drags until release
        local b = self._list_bar
        if b and b.max_scroll > 0 and x >= b.x and y >= b.y and y < b.y + b.h then
            self._bar_drag = true
            self:_scrollTo(y)
            return true
        end

        -- Item-browser rows
        local lr = self._list_rect
        if lr and y >= lr.y and y < lr.y + lr.h then
            for _, row in ipairs(self._list_rows) do
                if y >= row.y and y < row.y + row.h then
                    if row.kind == "group" then
                        row.group.collapsed = not row.group.collapsed
                    elseif not self.picked_item then
                        self.selected_idx = row.idx
                        self:syncActiveParams()
                    end
                    return true
                end
            end
        end
        return true -- consume all clicks within left sidebar
    end

    local cx, cy = getCenter(W, H, s, self.full_screen)
    cx = math.floor(cx + 0.5)
    cy = math.floor(cy + 0.5)

    -- Same quantized metrics as draw() — click math must agree with
    -- where the tiles actually rendered.
    local tw, th = tileMetrics(s)

    local zx, zy = self:_unzoom(x, y, cx, cy)
    local gx, gy = screenToGrid(zx, zy, cx, cy, tw, th)
    local click_gx, click_gy = gx, gy

    local step = self.snap_options[self.snap_idx] or 0.125
    gx = math.floor(gx / step + 0.5) * step
    gy = math.floor(gy / step + 0.5) * step

    -- Left click
    if button == 1 then

        if gx >= 0 and gx + self.active_w <= self.room_size and gy >= 0 and gy + self.active_h <= self.room_size then
            -- 1. Check if hovering an existing object to PICK UP
            local clicked_obj = self:_hitItem(zx, zy, click_gx, click_gy)
            local clicked_idx = nil
            for i, o in ipairs(self.placed) do
                if o == clicked_obj then clicked_idx = i; break end
            end

            local is_shift = love.keyboard and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
            local is_alt   = love.keyboard and love.keyboard.isDown("lalt", "ralt")

            -- Placed items are scenery to the mouse: a click places what is
            -- in hand (PLACE adds a copy, REPLACE moves the existing one).
            -- Alt+click is the only grab.
            if clicked_obj and is_alt and not is_shift and not self.picked_item then
                -- Pick up the item! Save it in self.picked_item
                self.picked_item = {
                    id        = clicked_obj.id,
                    sprite    = clicked_obj.sprite,
                    gx        = clicked_obj.gx,
                    gy        = clicked_obj.gy,
                    w         = clicked_obj.w,
                    h         = clicked_obj.h,
                    z_offset  = clicked_obj.z_offset,
                    dx        = clicked_obj.dx or 0,
                    layer     = clicked_obj.layer or 0,
                    sh        = clicked_obj.sh,
                    color     = clicked_obj.color,
                    scale     = clicked_obj.scale or 1.0,
                    flip_x    = clicked_obj.flip_x or false,
                    align     = clicked_obj.align or "center",
                    anim_room = clicked_obj.anim_room,
                    fps       = clicked_obj.fps,
                    frame     = clicked_obj.frame,
                    shader    = clicked_obj.shader,
                }
                -- Load its specs to the active cursor parameters
                self.active_w         = clicked_obj.w
                self.active_h         = clicked_obj.h
                self.active_sh        = clicked_obj.sh
                self.active_z         = clicked_obj.z_offset
                self.active_dx        = clicked_obj.dx or 0
                self.active_layer     = clicked_obj.layer or 0
                self.active_scale     = clicked_obj.scale or 1.0
                self.active_flip_x    = clicked_obj.flip_x or false
                self.active_align     = clicked_obj.align or "center"
                self.active_anim_room = clicked_obj.anim_room
                self.active_fps       = clicked_obj.fps
                self.active_frame     = clicked_obj.frame
                self.active_shader    = clicked_obj.shader
                self.active_color     = clicked_obj.color or { 1.0, 1.0, 1.0 }
                
                -- Sync selected_idx to match this item (browser follows)
                for idx, item in ipairs(self.placeable) do
                    -- numbered copies (Door_2_Brown_2) match by sprite
                    if item.id == clicked_obj.id or item.id == clicked_obj.sprite then
                        self.selected_idx = idx
                        self:_onSelectionChanged()
                        break
                    end
                end

                -- Remove it from the grid so it's only attached to cursor
                table.remove(self.placed, clicked_idx)
                print("[room-editor] Picked up " .. clicked_obj.id .. " for editing")
            else
                -- Place active item (Shift+Click stacks on top of furniture!)
                local active_spec = self.placeable[self.selected_idx]
                if active_spec then
                    local auto_z = self.active_z
                    if is_shift and clicked_obj then
                        auto_z = clicked_obj.z_offset + (clicked_obj.sh or 16)
                    end

                    -- Catalog items are one per room (the id is what the
                    -- game owns), so placing again moves it. Flavor sprites
                    -- can repeat: a second copy gets a numbered id, and
                    -- keeps its sprite name so it still draws.
                    local place_id = self.picked_item and self.picked_item.id or active_spec.id
                    local is_catalog = self.catalog_by_id[active_spec.id] ~= nil
                    local sprite_name = active_spec.sprite or active_spec.id
                    if self.picked_item then
                        -- putting the same thing back: its id is its own
                    elseif is_catalog or self.mode == "replace" then
                        -- one copy: the existing one moves to the mouse
                        for i = #self.placed, 1, -1 do
                            local o = self.placed[i]
                            if o.id == active_spec.id or (not is_catalog and o.sprite == sprite_name) then
                                table.remove(self.placed, i)
                            end
                        end
                    else
                        local taken = {}
                        for _, o in ipairs(self.placed) do taken[o.id] = true end
                        local n = 2
                        while taken[place_id] do
                            place_id = active_spec.id .. "_" .. n
                            n = n + 1
                        end
                    end

                    -- Add to placed list
                    table.insert(self.placed, {
                        id        = place_id,
                        sprite    = self.picked_item and self.picked_item.sprite or active_spec.sprite or active_spec.id,
                        gx        = gx,
                        gy        = gy,
                        w         = self.active_w,
                        h         = self.active_h,
                        z_offset  = auto_z,
                        dx        = self.active_dx or 0,
                        layer     = self.active_layer or 0,
                        sh        = self.active_sh,
                        color     = { self.active_color[1], self.active_color[2], self.active_color[3] },
                        scale     = self.active_scale,
                        flip_x    = self.active_flip_x,
                        align     = self.active_align,
                        anim_room = self.active_anim_room,
                        fps       = self.active_fps,
                        frame     = self.active_frame,
                        shader    = self.active_shader,
                    })
                    print(string.format("[room-editor] Placed %s at (%.3f, %.3f, Z=%d)", place_id, gx, gy, auto_z))
                    self.picked_item = nil -- successfully placed, clear picked state
                end
            end
        end
        return true
    end

    -- Right click
    if button == 2 then
        if self.picked_item then
            -- Re-insert the picked item back at its original coordinates and specs
            table.insert(self.placed, self.picked_item)
            print("[room-editor] Cancelled edit, returned " .. self.picked_item.id .. " to grid")
            self.picked_item = nil
            self:syncActiveParams() -- restore current tool parameters
        elseif love.keyboard.isDown("lalt", "ralt") then
            -- Alt+right-click deletes what the mouse is on
            local o = self:_hitItem(zx, zy, click_gx, click_gy)
            for i = #self.placed, 1, -1 do
                if self.placed[i] == o then
                    print("[room-editor] Deleted object: " .. o.id)
                    table.remove(self.placed, i)
                    break
                end
            end
        end
        return true
    end

    return false
end

-- ─── Keyboard Input Routing ───

function RoomView:keypressed(key)
    if not self.editor_mode then
        -- F3 to enter editor mode
        if key == "f3" then
            self.editor_mode = true
            print("[room-editor] Entered Room Editor Mode. Press F3 to exit.")
            return true
        end
        return false
    end

    if key == "f3" or key == "escape" then
        if self.show_help_overlay then
            self.show_help_overlay = false
            return true
        end
        if self.picked_item then
            -- Restore the picked item before exiting
            table.insert(self.placed, self.picked_item)
            self.picked_item = nil
            return true
        end
        self.editor_mode = false
        print("[room-editor] Exited Room Editor Mode.")
        return true
    end

    -- Layer (draw order) of the thing in hand
    if key == "z" or key == "x" then
        self.active_layer = (self.active_layer or 0) + (key == "x" and 1 or -1)
        print("[room-editor] Layer " .. self.active_layer)
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Mode: place / move
    if key == "m" then
        self.mode = self.mode == "place" and "replace" or "place"
        print("[room-editor] Mode: " .. self.mode:upper())
        return true
    end

    -- List paging
    if key == "pageup" or key == "pagedown" or key == "home" or key == "end" then
        local b = self._list_bar
        if b then
            if key == "pageup" then self.list_scroll = self.list_scroll - b.h
            elseif key == "pagedown" then self.list_scroll = self.list_scroll + b.h
            elseif key == "home" then self.list_scroll = 0
            else self.list_scroll = b.max_scroll end
        end
        return true
    end

    -- Footprint adjustments
    if key == "1" then
        self.active_w = math.max(1, self.active_w - 1)
        return true
    elseif key == "2" then
        self.active_w = self.active_w + 1
        return true
    elseif key == "3" then
        self.active_h = math.max(1, self.active_h - 1)
        return true
    elseif key == "4" then
        self.active_h = self.active_h + 1
        return true
    end

    -- Height offset adjustments. Shift is the coarse step (x8), so a
    -- thing that belongs near the top of a wall gets there in a few taps;
    -- keys repeat while held in the editor (RoomState turns that on).
    local shift = love.keyboard and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
    local coarse = shift and 8 or 1
    if key == "7" then
        self.active_z = self.active_z - 4 * coarse   -- below 0 sinks into the floor
        return true
    elseif key == "8" then
        self.active_z = self.active_z + 4 * coarse
        return true
    end

    -- Thickness / visual height adjustments
    if key == "5" then
        self.active_sh = math.max(2, self.active_sh - 2)
        return true
    elseif key == "6" then
        self.active_sh = self.active_sh + 2
        return true
    end

    -- Rotate footprint
    if key == "r" then
        self.active_w, self.active_h = self.active_h, self.active_w
        return true
    end

    -- Scale adjustments
    if key == "9" then
        self.active_scale = math.max(0.1, self.active_scale - 0.1)
        return true
    elseif key == "0" then
        self.active_scale = self.active_scale + 0.1
        return true
    end

    -- Flip horizontal
    if key == "f" then
        self.active_flip_x = not self.active_flip_x
        return true
    end

    -- Grid snap cycling
    if key == "g" then
        self.snap_idx = self.snap_idx + 1
        if self.snap_idx > #self.snap_options then self.snap_idx = 1 end
        print("[room-editor] Grid snap step set to: " .. self.snap_options[self.snap_idx])
        return true
    end

    -- Alignment cycling
    if key == "a" then
        if self.active_align == "center" then
            self.active_align = "left_wall"
        elseif self.active_align == "left_wall" then
            self.active_align = "right_wall"
        else
            self.active_align = "center"
        end
        print("[room-editor] Alignment set to: " .. self.active_align)
        return true
    end

    -- Toggle Anim Room mode (V)
    if key == "v" then
        if self.active_anim_room == nil then
            self.active_anim_room = false
        elseif self.active_anim_room == false then
            self.active_anim_room = true
        else
            self.active_anim_room = nil
        end
        print("[room-editor] Anim mode set to: " .. tostring(self.active_anim_room))
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Frame adjustment ([ / ])
    if key == "[" or key == "]" or key == "," or key == "." then
        local n = self:_activeFrameCount()
        local f = self.active_frame or 0            -- 0 = AUTO (animating)
        f = f + ((key == "]" or key == ".") and 1 or -1)
        if f < 0 then f = n end
        if f > n then f = 0 end
        self.active_frame = f > 0 and f or nil
        -- A chosen frame is a still; AUTO animates again.
        self.active_anim_room = (f > 0) and false or nil
        print("[room-editor] Frame set to: " .. tostring(self.active_frame or "AUTO") .. " / " .. n)
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Speed / FPS adjustment (- / =)
    if key == "-" then
        local fps_steps = { 0, 1, 2, 3, 4, 6, 8, 12, 15, 20, 30 }   -- 0 = default
        local cur_idx = 1
        for i, f in ipairs(fps_steps) do
            if f == (self.active_fps or 0) then cur_idx = i; break end
        end
        cur_idx = math.max(1, cur_idx - 1)
        self.active_fps = fps_steps[cur_idx] ~= 0 and fps_steps[cur_idx] or nil
        print("[room-editor] FPS set to: " .. tostring(self.active_fps or "DEFAULT"))
        self:_updateActivePlacedItemAnim()
        return true
    elseif key == "=" then
        local fps_steps = { 0, 1, 2, 3, 4, 6, 8, 12, 15, 20, 30 }   -- 0 = default
        local cur_idx = 1
        for i, f in ipairs(fps_steps) do
            if f == (self.active_fps or 0) then cur_idx = i; break end
        end
        cur_idx = math.min(#fps_steps, cur_idx + 1)
        self.active_fps = fps_steps[cur_idx] ~= 0 and fps_steps[cur_idx] or nil
        print("[room-editor] FPS set to: " .. tostring(self.active_fps or "DEFAULT"))
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Shader cycle (S)
    if key == "s" then
        local shaders = { nil, "pulse_glow", "hologram", "rainbow_shift", "pixel_glitch", "foil", "dirty" }
        local cur_idx = 1
        for i, sh in ipairs(shaders) do
            if sh == self.active_shader then cur_idx = i; break end
        end
        cur_idx = (cur_idx % #shaders) + 1
        self.active_shader = shaders[cur_idx]
        print("[room-editor] Shader set to: " .. tostring(self.active_shader or "NONE"))
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Color Tint cycle (T)
    if key == "t" then
        local tints = {
            { 1.0, 1.0, 1.0 },     -- Default White
            { 0.85, 0.65, 0.45 },  -- Warm Wood
            { 0.35, 0.35, 0.40 },  -- Dark Slate
            { 0.95, 0.82, 0.35 },  -- Gold / Brass
            { 0.85, 0.35, 0.35 },  -- Crimson / Red
            { 0.35, 0.75, 0.85 },  -- Cyan / Neon
            { 0.45, 0.85, 0.45 },  -- Emerald Green
            { 0.75, 0.45, 0.85 },  -- Violet / Purple
        }
        local cur_idx = 1
        for i, c in ipairs(tints) do
            if self.active_color and math.abs(c[1] - self.active_color[1]) < 0.05 and math.abs(c[2] - self.active_color[2]) < 0.05 then
                cur_idx = i; break
            end
        end
        cur_idx = (cur_idx % #tints) + 1
        self.active_color = tints[cur_idx]
        print("[room-editor] Tint color set")
        self:_updateActivePlacedItemAnim()
        return true
    end

    -- Controls Help Overlay Toggle (H)
    if key == "h" then
        self.show_help_overlay = not self.show_help_overlay
        return true
    end

    -- Duplicate / Clone Item (D)
    if key == "d" then
        local active_spec = self.placeable[self.selected_idx]
        if active_spec then
            local clone_id = active_spec.id .. "_" .. tostring(math.random(100, 999))
            local clone_gx = 2.0
            local clone_gy = 2.0
            for _, o in ipairs(self.placed) do
                if o.id == active_spec.id then
                    clone_gx = math.min(self.room_size - o.w, o.gx + 0.25)
                    clone_gy = math.min(self.room_size - o.h, o.gy + 0.25)
                    break
                end
            end
            table.insert(self.placed, {
                id        = clone_id,
                sprite    = active_spec.sprite or active_spec.id,
                gx        = clone_gx,
                gy        = clone_gy,
                w         = self.active_w,
                h         = self.active_h,
                z_offset  = self.active_z,
                dx        = self.active_dx or 0,
                layer     = self.active_layer or 0,
                sh        = self.active_sh,
                color     = { self.active_color[1], self.active_color[2], self.active_color[3] },
                scale     = self.active_scale,
                flip_x    = self.active_flip_x,
                align     = self.active_align,
                anim_room = self.active_anim_room,
                fps       = self.active_fps,
                frame     = self.active_frame,
                shader    = self.active_shader,
            })
            print("[room-editor] Cloned item as " .. clone_id)
        end
        return true
    end

    -- Arrow key fine nudge (Left/Right/Up/Down when modifier key held or for precise alignment)
    local is_nudge = love.keyboard and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl") or love.keyboard.isDown("lalt") or love.keyboard.isDown("ralt"))
    if is_nudge and (key == "left" or key == "right" or key == "up" or key == "down") then
        -- One grid step per tap; Shift makes it eight. Held keys repeat.
        -- Screen-space, in pixels: up is UP (the sprite rises off its
        -- footprint: z_offset), left/right slide it sideways (dx). The
        -- footprint (the green) never moves; that is what the mouse is for.
        -- Applies to the thing in hand: the held item, or the preview
        -- that lands on the next placement.
        local px_step = 1 * coarse
        if key == "up"    then self.active_z  = self.active_z + px_step end
        if key == "down"  then self.active_z  = self.active_z - px_step end   -- may go below 0
        if key == "left"  then self.active_dx = (self.active_dx or 0) - px_step end
        if key == "right" then self.active_dx = (self.active_dx or 0) + px_step end
        print(string.format("[room-editor] height %d px, sideways %d px", self.active_z, self.active_dx or 0))
        return true
    end

    -- Browser Tab toggle (TAB)
    if key == "tab" then
        self.browser_tab = self.browser_tab == 1 and 2 or 1
        print("[room-editor] Browser tab set to: " .. (self.browser_tab == 1 and "CATALOG" or "FLAVOR ASSETS"))
        self:_cycleSelection(0)
        return true
    end

    -- Selection cycling (Q/E, or Up/Down).
    if key == "q" or key == "up" then
        if self.picked_item then return true end
        self:_cycleSelection(-1)
        return true
    elseif key == "e" or key == "down" then
        if self.picked_item then return true end
        self:_cycleSelection(1)
        return true
    end

    -- Serialize layout to console
    if key == "return" or key == "kpenter" then
        self:serializeLayout()
        return true
    end

    return false
end

-- Sync active block drawing dimensions to the selected item if already placed
function RoomView:syncActiveParams()
    local active_spec = self.placeable[self.selected_idx]
    if not active_spec then return end
    
    local found = false
    for _, o in ipairs(self.placed) do
        if o.id == active_spec.id then
            self.active_w         = o.w
            self.active_h         = o.h
            self.active_z         = o.z_offset
            self.active_dx        = o.dx or 0
            self.active_layer     = o.layer or 0
            self.active_sh        = o.sh
            self.active_scale     = o.scale or 1.0
            self.active_flip_x    = o.flip_x or false
            self.active_align     = o.align or "center"
            self.active_anim_room = o.anim_room
            self.active_fps       = o.fps
            self.active_frame     = o.frame
            self.active_shader    = o.shader
            self.active_color     = o.color or { 1.0, 1.0, 1.0 }
            found = true
            break
        end
    end
    
    if not found then
        self.active_w         = 1
        self.active_h         = 1
        self.active_sh        = 16
        self.active_z         = 0
        self.active_dx        = 0
        self.active_layer     = 0
        self.active_scale     = 1.0
        self.active_flip_x    = false
        self.active_align     = "center"
        self.active_anim_room = nil
        self.active_fps       = nil
        self.active_frame     = nil
        self.active_shader    = nil
        self.active_color     = { 1.0, 1.0, 1.0 }
    end
end

-- Frames in the active item's animation (1 for a still sprite).
function RoomView:_activeFrameCount()
    local spec = self.placeable[self.selected_idx]
    if not spec then return 1 end
    local loader = self.game.sprite_loader
    local name = spec.sprite or spec.id
    local anim = loader.animations and (loader.animations[name]
        or (loader.aliases and loader.aliases[name] and loader.animations[loader.aliases[name]]))
    return anim and #anim or 1
end

function RoomView:_updateActivePlacedItemAnim()
    if self.picked_item then
        self.picked_item.anim_room = self.active_anim_room
        self.picked_item.fps       = self.active_fps
        self.picked_item.layer     = self.active_layer or 0
        self.picked_item.frame     = self.active_frame
        self.picked_item.shader    = self.active_shader
        self.picked_item.color     = self.active_color
    end
    -- Placed items are never touched here: what is placed stays as it was
    -- placed until it is picked up. With nothing in hand, the params are
    -- the preview's, and land on the next placement.
end

-- Wheel: over the sidebar it scrolls the item browser; over the room it
-- cycles the selection (and the browser follows the selection).
-- The placed item under a room-space point: the topmost drawn sprite
-- whose pixels' box contains it, else the one whose footprint does.
function RoomView:_hitItem(x, y, gx, gy)
    local rects = self._hit_rects or {}
    for i = #rects, 1, -1 do
        local r = rects[i]
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            return r.obj
        end
    end
    if gx then
        for i = #self.placed, 1, -1 do
            local o = self.placed[i]
            if gx >= o.gx and gx < o.gx + o.w and gy >= o.gy and gy < o.gy + o.h then
                return o
            end
        end
    end
    return nil
end

-- Screen -> room space, undoing the zoom about the room centre.
function RoomView:_unzoom(x, y, cx, cy)
    local z = self.editor_mode and (self.zoom or 1) or 1
    return (x - cx) / z + cx, (y - cy) / z + cy
end

function RoomView:wheelmoved(dy)
    if not self.editor_mode then return false end
    if love.keyboard.isDown("lctrl", "rctrl") then
        local z = (self.zoom or 1) * (dy > 0 and 1.15 or 1 / 1.15)
        self.zoom = math.max(0.5, math.min(4, z))
        return true
    end
    local mx = love.mouse.getX()
    local s  = self.game.ui_scale or 1
    if mx < math.floor(270 * s) then
        self.list_scroll = self.list_scroll - dy * math.floor(40 * s)
        return true   -- clamped in draw against the live layout
    end
    -- Over the room the wheel does nothing (Ctrl+wheel zooms above). It
    -- used to cycle the selection, which opened folders by itself.
    return true
end

-- Scrollbar drag (the bar is a 14px column at the list's right edge).
function RoomView:_scrollTo(y)
    local b = self._list_bar
    if not b or b.max_scroll <= 0 then return end
    local track = b.h - b.thumb_h
    local t = track > 0 and (y - b.y - b.thumb_h * 0.5) / track or 0
    self.list_scroll = math.max(0, math.min(1, t)) * b.max_scroll
end

function RoomView:mousemoved(x, y)
    if self._bar_drag then self:_scrollTo(y); return true end
    return false
end

function RoomView:mousereleased(x, y, button)
    if self._bar_drag then self._bar_drag = false; return true end
    return false
end

-- Export function: Print the Lua return layout array directly to standard output
function RoomView:layoutString()
    local lines = {}
    lines[#lines + 1] = "return {"

    local floor_theme = self.floor_idx == 0 and "Default" or self.floor_list[self.floor_idx]
    local wall_theme = self.wall_idx == 0 and "Default" or self.wall_list[self.wall_idx]
    lines[#lines + 1] = "    __meta = {"
    lines[#lines + 1] = string.format("        room_size = %d,", self.room_size)
    lines[#lines + 1] = string.format("        floor_theme = %q,", floor_theme)
    lines[#lines + 1] = string.format("        wall_theme = %q,", wall_theme)
    lines[#lines + 1] = string.format("        tile_set = %d,", self.tile_set or Tiles.default_set)
    lines[#lines + 1] = string.format("        wall_courses = %d,", self.wall_courses or Tiles.default_courses)
    if self.floor_flip then lines[#lines + 1] = "        floor_flip = true," end
    if self.wall_flip then lines[#lines + 1] = "        wall_flip = true," end
    lines[#lines + 1] = "    },"

    -- Sort placed items alphabetically by id for neatness. What is in
    -- hand is part of the room too (at the spot it was picked from).
    local sorted = {}
    for _, o in ipairs(self.placed) do sorted[#sorted + 1] = o end
    if self.picked_item then sorted[#sorted + 1] = self.picked_item end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    for _, o in ipairs(sorted) do
        local scale_str  = o.scale and string.format(", scale = %.2f", o.scale) or ""
        local flip_str   = o.flip_x and ", flip_x = true" or ""
        local align_str  = o.align and o.align ~= "center" and string.format(", align = %q", o.align) or ""
        local anim_str   = o.anim_room == false and ", anim_room = false" or (o.anim_room == true and ", anim_room = true" or "")
        local fps_str    = o.fps and string.format(", fps = %d", o.fps) or ""
        local frame_str  = o.frame and string.format(", frame = %d", o.frame) or ""
        local shader_str = o.shader and string.format(", shader = %q", o.shader) or ""
        local dx_str     = (o.dx and o.dx ~= 0) and string.format(", dx = %d", o.dx) or ""
        local sprite_str = (o.sprite and o.sprite ~= o.id) and string.format(", sprite = %q", o.sprite) or ""
        local layer_str  = (o.layer and o.layer ~= 0) and string.format(", layer = %d", o.layer) or ""

        -- Flavor ids are sprite paths (slashes, dots, parens): not Lua
        -- names, so they go in ["..."].
        local key = o.id:match("^[%a_][%w_]*$") and o.id or string.format("[%q]", o.id)
        lines[#lines + 1] = string.format("    %-20s = { gx = %.3f, gy = %.3f, w = %d, h = %d, z_offset = %d, sh = %d, color = { %.2f, %.2f, %.2f }%s%s%s%s%s%s%s%s%s%s },",
            key, o.gx, o.gy, o.w, o.h, o.z_offset, o.sh, o.color[1], o.color[2], o.color[3], scale_str, flip_str, align_str, anim_str, fps_str, frame_str, shader_str, dx_str, sprite_str, layer_str)
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

-- Called every couple of seconds while the editor is open (RoomState).
-- Writes the draft only when the room changed.
function RoomView:autosave()
    if not (love and love.filesystem and love.filesystem.write) then return end
    local str = self:layoutString()
    if str == self._last_autosave then return end
    -- Keep the previous draft: an accidental CLEAR (or anything that
    -- empties the room) is then one file copy away from undone.
    local out = str .. "\n"
    backupDraft(out)
    local ok = pcall(love.filesystem.write, DRAFT_FILE, out)
    if ok then
        self._last_autosave = str
        print(string.format("[room-editor] Autosaved draft (%d items)", #self.placed + (self.picked_item and 1 or 0)))
    end
end

function RoomView:serializeLayout()
    local output_str = self:layoutString()

    print("---------------- COPY FROM LINE BELOW ----------------")
    print(output_str)
    print("------------------------------------------------------")

    self.export_toast_time = 3.5

    if love and love.filesystem and love.filesystem.write then
        local ok, err = pcall(love.filesystem.write, "room_layout_export.lua", output_str .. "\n")
        if ok then
            local save_dir = love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory() or ""
            print("[room-editor] Exported layout file: " .. save_dir .. "/room_layout_export.lua")
        end
    end

    -- Running from source: write data/room_layout.lua itself, so EXPORT
    -- is the whole job. (A fused build has no source dir to write into.)
    local src = love and love.filesystem and love.filesystem.getSource and love.filesystem.getSource()
    if src and love.filesystem.isFused and not love.filesystem.isFused() then
        local path = src .. "/data/room_layout.lua"
        local f = io.open(path, "w")
        if f then
            f:write(output_str .. "\n")
            f:close()
            print("[room-editor] Wrote " .. path)
            self._last_autosave = output_str
            pcall(love.filesystem.remove, DRAFT_FILE)
            self.export_written = true
        else
            print("[room-editor] Could not write " .. path .. " (export copy is in the save dir)")
        end
    end
end

return RoomView
