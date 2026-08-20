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
local Anchors        = require("services.AnchorRegistry")
local ClickFlash     = require("services.ClickFlash")

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
            local max_y = h - 1
            local found = false
            for y = h - 1, 0, -1 do
                for x = 0, w - 1 do
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
    -- Load all layout positions from room_layout
    local placed = {}
    for id, info in pairs(Layout) do
        if id ~= "__meta" then
            placed[#placed + 1] = {
                id       = id,
                gx       = info.gx or 0,
                gy       = info.gy or 0,
                w        = info.w or 1,
                h        = info.h or 1,
                z_offset = info.z_offset or 0,
                sh       = info.sh or 16,
                color    = info.color or { 0.5, 0.5, 0.5 },
                scale    = info.scale or 1.0,
                flip_x   = info.flip_x or false,
                align    = info.align or "center",
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
    local groups   = {}       -- ordered: { name, indices = {..}, collapsed }
    local group_of = {}       -- placeable idx -> group ref
    local by_name  = {}       -- group name -> group ref
    local function groupFor(name, default_collapsed)
        local g = by_name[name]
        if not g then
            g = { name = name, indices = {}, collapsed = default_collapsed }
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
            local f_theme = name:match("Floor_Wall_Tiles_64/Floor_64_(.+)$")
            if f_theme then
                if not floors_seen[f_theme] then
                    floors_seen[f_theme] = true
                    floor_list[#floor_list + 1] = f_theme
                end
            end

            local w_theme = name:match("Floor_Wall_Tiles_64/Wall_L_64_(.+)$")
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

    local floor_idx = 0
    for i, t in ipairs(floor_list) do
        if t == floor_theme then floor_idx = i; break end
    end
    local wall_idx = 0
    for i, t in ipairs(wall_list) do
        if t == wall_theme then wall_idx = i; break end
    end

    return setmetatable({
        game          = game,
        placed        = placed,     -- active placed furniture objects list
        placeable     = placeable,  -- flat list; selected_idx indexes this
        groups        = groups,     -- collapsible browser groups (presentation)
        group_of      = group_of,   -- placeable idx -> group (auto-expand)
        editor_mode   = false,      -- true = grid lines, placement selector, mouse controls
        selected_idx  = 1,          -- active item index in the placeable list
        active_w      = 1,          -- current placement footprint width
        active_h      = 1,          -- current placement footprint height
        active_sh     = 16,         -- current placement visual thickness/height
        active_z      = 0,          -- current placement vertical height offset
        active_scale  = 1.0,        -- current sprite scale factor
        active_flip_x = false,      -- current sprite horizontal flip
        active_align  = "center",   -- current sprite alignment mode ("center", "left_wall", "right_wall")
        snap_options  = { 1.0, 0.5, 0.25, 0.125 },
        snap_idx      = 4,          -- current grid snap option (defaults to 0.125)
        picked_item   = nil,
        list_scroll   = 0,          -- item-browser scroll offset (px)
        _list_rows    = {},         -- built each draw; consumed by mousepressed
        _list_rect    = nil,        -- browser viewport rect (hit-test + wheel)
        _scroll_to_sel = false,     -- draw() brings the selected row into view

        room_size     = room_size,
        floor_list    = floor_list,
        wall_list     = wall_list,
        floor_idx     = floor_idx,
        wall_idx      = wall_idx,
    }, RoomView)
end

-- Selection moved (keys / wheel / pick-up): make sure its group is open
-- and ask the next draw to scroll the row into view.
function RoomView:_onSelectionChanged()
    local g = self.group_of and self.group_of[self.selected_idx]
    if g then g.collapsed = false end
    self._scroll_to_sel = true
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

function RoomView:draw(full_screen)
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

    -- 1. Draw background walls (corner walls of the room - fallback vector or sprite segments)
    local l_wall_sprite = nil
    local r_wall_sprite = nil
    if self.wall_idx > 0 then
        local theme = self.wall_list[self.wall_idx]
        local l_name = "isometric/Floor_Wall_Tiles_64/Wall_L_64_" .. theme
        local r_name = "isometric/Floor_Wall_Tiles_64/Wall_R_64_" .. theme
        l_wall_sprite = game.sprite_loader:getSprite(l_name)
        r_wall_sprite = game.sprite_loader:getSprite(r_name)
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
        local COURSE_PX    = 40
        local WALL_COURSES = 2   -- courses to stack; 3 for a taller room
        local course_dy    = COURSE_PX * tile_k

        -- Draw Left-back wall segments (right side of the room, sloping down-right) using Wall_R
        local r_ox = 16
        local r_oy = 47
        love.graphics.setColor(1, 1, 1, 1)
        for x = 0, self.room_size - 1 do
            local wx, wy = gridToScreen(x, 0, cx, cy, tw, th)
            for level = 0, WALL_COURSES - 1 do
                love.graphics.draw(r_wall_sprite, wx, wy - level * course_dy,
                    0, tile_k, tile_k, r_ox, r_oy)
            end
        end

        -- Draw Right-back wall segments (left side of the room, sloping down-left) using Wall_L
        local l_ox = 47
        local l_oy = 47
        for y = 0, self.room_size - 1 do
            local wx, wy = gridToScreen(0, y, cx, cy, tw, th)
            for level = 0, WALL_COURSES - 1 do
                love.graphics.draw(l_wall_sprite, wx, wy - level * course_dy,
                    0, tile_k, tile_k, l_ox, l_oy)
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
        local sprite_name = "isometric/Floor_Wall_Tiles_64/Floor_64_" .. theme
        floor_sprite = game.sprite_loader:getSprite(sprite_name)
        if floor_sprite then floor_sprite:setFilter("nearest", "nearest") end
    end

    for x = 0, self.room_size - 1 do
        for y = 0, self.room_size - 1 do
            local tx1, ty1 = gridToScreen(x, y, cx, cy, tw, th)
            if floor_sprite then
                local ox = 32
                local oy = 16
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(floor_sprite, tx1, ty1, 0, tile_k, tile_k, ox, oy)
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

            -- Wireframe grid lines (only in editor mode)
            if self.editor_mode then
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
    table.sort(render_list, function(a, b)
        local depth_a = (a.gx + a.w * 0.5) + (a.gy + a.h * 0.5)
        local depth_b = (b.gx + b.w * 0.5) + (b.gy + b.h * 0.5)
        if math.abs(depth_a - depth_b) < 0.001 then
            -- Tie-breaker: draw wall attachments (z_offset > 0) behind floor attachments
            return (a.z_offset or 0) < (b.z_offset or 0)
        end
        return depth_a < depth_b
    end)

    -- 5. Draw the items
    for _, obj in ipairs(render_list) do
        local color = obj.color
        local is_owned = owned_set[obj.id] or self.editor_mode
        if not is_owned then
            -- Unowned items drawn slightly transparent/desaturated in editor mode
            color = { color[1], color[2], color[3], 0.40 }
        end
        
        local sprite = game.sprite_loader:getSprite(obj.sprite or obj.id)
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
            
            local px = sx
            local py = sy - (obj.z_offset or 0) * s
            
            if not is_owned then
                love.graphics.setColor(1, 1, 1, 0.40)
            else
                love.graphics.setColor(1, 1, 1, 1)
            end
            
            love.graphics.draw(sprite, px, py, 0, draw_scale_x, draw_scale_y, ox, oy)
        else
            drawIsoBox(obj.gx, obj.gy, obj.w, obj.h, obj.z_offset, obj.sh, color, tw, th, cx, cy, s, obj.scale, obj.flip_x)
        end
    end

    -- 6. Editor overlay: Selected active item preview + cursor grid position
    local mx, my = love.mouse.getPosition()
    local gx, gy = screenToGrid(mx, my, cx, cy, tw, th)
    local step = self.snap_options[self.snap_idx] or 0.125
    gx = math.floor(gx / step + 0.5) * step
    gy = math.floor(gy / step + 0.5) * step

    local active_spec = self.placeable[self.selected_idx]

    if self.editor_mode and active_spec then
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
            local sprite = game.sprite_loader:getSprite(active_spec.sprite or active_spec.id)
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
                
                local px = sx
                local py = sy - self.active_z * s
                
                love.graphics.setColor(1, 1, 1, 0.60)
                love.graphics.draw(sprite, px, py, 0, draw_scale_x, draw_scale_y, ox, oy)
            else
                local preview_c = { 0.92, 0.72, 0.32, 0.50 } -- translucent amber
                drawIsoBox(gx, gy, self.active_w, self.active_h, self.active_z, self.active_sh, preview_c, tw, th, cx, cy, s, self.active_scale, self.active_flip_x)
            end
        end

        -- Draw UI Sidebar Panel for Editor Controls (Left Side overlay)
        local sidebar_w = fl(270 * s)
        local sidebar_h = H - TOP_BAR_H
        local sidebar_x = 0
        local sidebar_y = TOP_BAR_H

        Theme.setColor(Theme.bg.chrome, 0.95)
        love.graphics.rectangle("fill", sidebar_x, sidebar_y, sidebar_w, sidebar_h)
        Theme.setColor(Theme.border.soft)
        love.graphics.line(sidebar_x + sidebar_w - 1, sidebar_y, sidebar_x + sidebar_w - 1, sidebar_y + sidebar_h)

        -- Title
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(game.fonts.md)
        local text_margin = fl(12 * s)
        love.graphics.print("ROOM DESIGNER", sidebar_x + text_margin, sidebar_y + text_margin)

        -- Current Placed Items count
        love.graphics.setFont(game.fonts.sm)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(string.format("Items Placed: %d", #self.placed), sidebar_x + text_margin, sidebar_y + text_margin + fl(22 * s))

        local ins_y = sidebar_y + fl(45 * s)
        local ins_lh = fl(12 * s)
        local instructions = {
            "L-Click Empty: Place Item",
            "L-Click Item: Pick Up / Edit",
            "R-Click Grid: Delete Item",
            "R-Click Picked: Cancel Edit",
            "Q / E: Cycle Selected Item",
            "1 / 2: Width: " .. self.active_w,
            "3 / 4: Length: " .. self.active_h,
            "5 / 6: Thickness: " .. self.active_sh,
            "7 / 8: Elevation (Z): " .. self.active_z,
            "9 / 0: Scale: " .. string.format("%.1f", self.active_scale),
            "F-Key: Flip Horiz: " .. (self.active_flip_x and "ON" or "OFF"),
            "R-Key: Rotate Footprint",
            "G-Key: Snap Grid: " .. tostring(self.snap_options[self.snap_idx]),
            "A-Key: Alignment: " .. self.active_align,
            "Enter-Key: Export positions",
            "F3-Key: Exit Room Editor",
        }
        for _, ins in ipairs(instructions) do
            love.graphics.print(ins, sidebar_x + text_margin, ins_y)
            ins_y = ins_y + ins_lh
        end

        -- Draw EXPORT and RESET buttons in the sidebar
        local btn_w = sidebar_w - text_margin * 2
        local btn_h = fl(26 * s)
        local btn_gap = fl(6 * s)
        local btn_x = sidebar_x + text_margin
        
        -- EXPORT button
        local exp_y = sidebar_y + fl(250 * s)
        local exp_hov = mx >= btn_x and mx < btn_x + btn_w and my >= exp_y and my < exp_y + btn_h
        LabelButton.draw{
            x = btn_x, y = exp_y, w = btn_w, h = btn_h,
            text        = "EXPORT LAYOUT",
            fonts       = game.fonts,
            hovered     = exp_hov,
        }

        -- RESET button
        local rst_y = exp_y + btn_h + btn_gap
        local rst_hov = mx >= btn_x and mx < btn_x + btn_w and my >= rst_y and my < rst_y + btn_h
        LabelButton.draw{
            x = btn_x, y = rst_y, w = btn_w, h = btn_h,
            text        = "RESET CHANGES",
            fonts       = game.fonts,
            hovered     = rst_hov,
        }

        -- CLEAR button
        local clr_y = rst_y + btn_h + btn_gap
        local clr_hov = mx >= btn_x and mx < btn_x + btn_w and my >= clr_y and my < clr_y + btn_h
        LabelButton.draw{
            x = btn_x, y = clr_y, w = btn_w, h = btn_h,
            text        = "CLEAR ROOM",
            fonts       = game.fonts,
            hovered     = clr_hov,
        }

        -- ── Room Meta Config selectors (Size, Floor, Wall)
        local meta_y = clr_y + btn_h + fl(10 * s)
        local arrow_w = fl(18 * s)
        local arrow_h = fl(18 * s)
        local prev_x = sidebar_x + sidebar_w - text_margin - arrow_w * 2 - fl(4 * s)
        local next_x = sidebar_x + sidebar_w - text_margin - arrow_w

        local function checkHov(row_y)
            local p_hov = mx >= prev_x and mx < prev_x + arrow_w and my >= row_y and my < row_y + arrow_h
            local n_hov = mx >= next_x and mx < next_x + arrow_w and my >= row_y and my < row_y + arrow_h
            return p_hov, n_hov
        end

        local function drawSelectorRow(label, value, row_y, p_hov, n_hov)
            love.graphics.setFont(game.fonts.sm)
            Theme.setColor(Theme.fg.muted)
            love.graphics.print(label .. ":", sidebar_x + text_margin, row_y + fl(3 * s))
            
            local val_x = sidebar_x + text_margin + fl(80 * s)
            Theme.setColor(Theme.fg.heading)
            love.graphics.print(value, val_x, row_y + fl(3 * s))
            
            LabelButton.draw{
                x = prev_x, y = row_y, w = arrow_w, h = arrow_h,
                text = "<", fonts = game.fonts, font = game.fonts.sm, hovered = p_hov
            }
            LabelButton.draw{
                x = next_x, y = row_y, w = arrow_w, h = arrow_h,
                text = ">", fonts = game.fonts, font = game.fonts.sm, hovered = n_hov
            }
            
            return {
                prev = { x = prev_x, y = row_y, w = arrow_w, h = arrow_h },
                next = { x = next_x, y = row_y, w = arrow_w, h = arrow_h }
            }
        end

        -- 1. Room Size Row
        local size_val = tostring(self.room_size) .. "x" .. tostring(self.room_size)
        local sp_hov, sn_hov = checkHov(meta_y)
        local size_rects = drawSelectorRow("Room Size", size_val, meta_y, sp_hov, sn_hov)
        self._size_prev_rect = size_rects.prev
        self._size_next_rect = size_rects.next

        -- 2. Floor Theme Row
        local floor_val = self.floor_idx == 0 and "Default" or self.floor_list[self.floor_idx]
        local fp_hov, fn_hov = checkHov(meta_y + fl(24 * s))
        local floor_rects = drawSelectorRow("Floor Tile", floor_val, meta_y + fl(24 * s), fp_hov, fn_hov)
        self._floor_prev_rect = floor_rects.prev
        self._floor_next_rect = floor_rects.next

        -- 3. Wall Theme Row
        local wall_val = self.wall_idx == 0 and "Default" or self.wall_list[self.wall_idx]
        local wp_hov, wn_hov = checkHov(meta_y + fl(48 * s))
        local wall_rects = drawSelectorRow("Wall Tile", wall_val, meta_y + fl(48 * s), wp_hov, wn_hov)
        self._wall_prev_rect = wall_rects.prev
        self._wall_next_rect = wall_rects.next

        -- ── Item browser: collapsible folder groups in a scrolling
        -- viewport with a scrollbar. Click a folder to fold/unfold,
        -- click an item to select it; draw() auto-scrolls to keep the
        -- selection visible after keyboard/wheel cycling.
        local cat_y = meta_y + fl(76 * s)
        love.graphics.setFont(game.fonts.md)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print(string.format("ITEMS (%d):", #self.placeable),
            sidebar_x + text_margin, cat_y)
        cat_y = cat_y + fl(22 * s)

        local sm    = game.fonts.sm
        local row_h = sm:getHeight() + fl(4 * s)
        local view_y = cat_y
        local view_h = (sidebar_y + sidebar_h) - view_y - fl(8 * s)
        self._list_rect = { x = sidebar_x, y = view_y, w = sidebar_w, h = view_h }

        -- Virtual layout pass: every visible row's y offset from list top.
        local rows, vy, sel_vy = {}, 0, nil
        for _, g in ipairs(self.groups) do
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

        -- Bring the selection into view when it just moved.
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

        -- Stamp absolute y on the rows for click hit-testing.
        self._list_rows = rows
        for _, row in ipairs(rows) do
            row.y = view_y + row.vy - self.list_scroll
            row.h = row_h
        end

        -- Truncate a label to the row width (cached per item + width).
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
                    local item   = self.placeable[row.idx]
                    local active = (row.idx == self.selected_idx)
                    local hov = mx >= sidebar_x and mx < sidebar_x + sidebar_w
                            and my >= row.y and my < row.y + row_h
                    if active then
                        Theme.setColor(Theme.bg.widget_hover)
                        love.graphics.rectangle("fill", sidebar_x, row.y, sidebar_w, row_h)
                        Theme.setColor(Theme.status.warn)
                        love.graphics.print("> " .. trimmed(item),
                            sidebar_x + text_margin, row.y + text_pad)
                    else
                        if hov then
                            Theme.setColor(Theme.bg.widget_hover, 0.5)
                            love.graphics.rectangle("fill", sidebar_x, row.y, sidebar_w, row_h)
                        end
                        Theme.setColor(owned_set[item.id] and Theme.fg.primary
                                       or Theme.fg.disabled)
                        love.graphics.print("  " .. trimmed(item),
                            sidebar_x + text_margin, row.y + text_pad)
                    end
                end
            end
        end
        love.graphics.setScissor()

        -- Scrollbar.
        if max_scroll > 0 then
            local thumb_h = math.max(fl(20 * s), view_h * (view_h / total_h))
            local thumb_y = view_y + (view_h - thumb_h)
                            * (self.list_scroll / max_scroll)
            Theme.setColor(Theme.bg.sunken, 0.6)
            love.graphics.rectangle("fill", sidebar_x + sidebar_w - 6, view_y, 4, view_h, 2)
            Theme.setColor(Theme.fg.muted)
            love.graphics.rectangle("fill", sidebar_x + sidebar_w - 6, thumb_y, 4, thumb_h, 2)
        end
    end
end

-- ─── Mouse Input routing ───

function RoomView:mousepressed(x, y, button)
    if not self.editor_mode then return false end
    local W, H = love.graphics.getDimensions()
    local s    = self.game.ui_scale or 1

    -- Check sidebar button clicks if in editor mode
    if x < math.floor(270 * s) then
        local sidebar_w = math.floor(270 * s)
        local sidebar_x = 0
        local sidebar_y = math.floor(56 * s)
        local text_margin = math.floor(12 * s)
        
        local btn_w = sidebar_w - text_margin * 2
        local btn_h = math.floor(26 * s)
        local btn_gap = math.floor(6 * s)
        local btn_x = sidebar_x + text_margin
        
        local exp_y = sidebar_y + math.floor(250 * s)
        local rst_y = exp_y + btn_h + btn_gap
        local clr_y = rst_y + btn_h + btn_gap

        if button == 1 then
            if x >= btn_x and x < btn_x + btn_w then
                if y >= exp_y and y < exp_y + btn_h then
                    ClickFlash.flash("room_btn", "room_btn")
                    self:serializeLayout()
                    return true
                elseif y >= rst_y and y < rst_y + btn_h then
                    ClickFlash.flash("room_btn", "room_btn")
                    -- Re-load initial layout to discard changes
                    self.placed = {}
                    for id, info in pairs(Layout) do
                        if id ~= "__meta" then
                            self.placed[#self.placed + 1] = {
                                id       = id,
                                gx       = info.gx or 0,
                                gy       = info.gy or 0,
                                w        = info.w or 1,
                                h        = info.h or 1,
                                z_offset = info.z_offset or 0,
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
                elseif y >= clr_y and y < clr_y + btn_h then
                    ClickFlash.flash("room_btn", "room_btn")
                    self.placed = {}
                    self.picked_item = nil
                    print("[room-editor] Cleared all furniture items in room")
                    return true
                end
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

            -- Hit test Wall Theme arrows
            if self._wall_prev_rect and x >= self._wall_prev_rect.x and x < self._wall_prev_rect.x + self._wall_prev_rect.w
               and y >= self._wall_prev_rect.y and y < self._wall_prev_rect.y + self._wall_prev_rect.h then
                self.wall_idx = self.wall_idx - 1
                if self.wall_idx < 0 then self.wall_idx = #self.wall_list end
                ClickFlash.flash("room_btn", "room_btn")
                return true
            elseif self._wall_next_rect and x >= self._wall_next_rect.x and x < self._wall_next_rect.x + self._wall_next_rect.w
               and y >= self._wall_next_rect.y and y < self._wall_next_rect.y + self._wall_next_rect.h then
                self.wall_idx = self.wall_idx + 1
                if self.wall_idx > #self.wall_list then self.wall_idx = 0 end
                ClickFlash.flash("room_btn", "room_btn")
                return true
            end

            -- Item-browser rows: click a folder header to fold/unfold,
            -- click an item to select it (locked while holding a picked
            -- item, same as Q/E).
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
        end
        return true -- consume all other clicks in sidebar
    end

    local cx, cy = getCenter(W, H, s, self.full_screen)
    cx = math.floor(cx + 0.5)
    cy = math.floor(cy + 0.5)

    -- Same quantized metrics as draw() — click math must agree with
    -- where the tiles actually rendered.
    local tw, th = tileMetrics(s)

    local gx, gy = screenToGrid(x, y, cx, cy, tw, th)
    local click_gx, click_gy = gx, gy

    local step = self.snap_options[self.snap_idx] or 0.125
    gx = math.floor(gx / step + 0.5) * step
    gy = math.floor(gy / step + 0.5) * step

    -- Left click
    if button == 1 then

        if gx >= 0 and gx + self.active_w <= self.room_size and gy >= 0 and gy + self.active_h <= self.room_size then
            -- 1. Check if hovering an existing object to PICK UP
            local clicked_obj = nil
            local clicked_idx = nil
            for i, o in ipairs(self.placed) do
                if click_gx >= o.gx and click_gx < o.gx + o.w and click_gy >= o.gy and click_gy < o.gy + o.h then
                    clicked_obj = o
                    clicked_idx = i
                    break
                end
            end

            if clicked_obj then
                -- Pick up the item! Save it in self.picked_item
                self.picked_item = {
                    id       = clicked_obj.id,
                    gx       = clicked_obj.gx,
                    gy       = clicked_obj.gy,
                    w        = clicked_obj.w,
                    h        = clicked_obj.h,
                    z_offset = clicked_obj.z_offset,
                    sh       = clicked_obj.sh,
                    color    = clicked_obj.color,
                    scale    = clicked_obj.scale or 1.0,
                    flip_x   = clicked_obj.flip_x or false,
                    align    = clicked_obj.align or "center",
                }
                -- Load its specs to the active cursor parameters
                self.active_w  = clicked_obj.w
                self.active_h  = clicked_obj.h
                self.active_sh = clicked_obj.sh
                self.active_z  = clicked_obj.z_offset
                self.active_scale = clicked_obj.scale or 1.0
                self.active_flip_x = clicked_obj.flip_x or false
                self.active_align = clicked_obj.align or "center"
                
                -- Sync selected_idx to match this item (browser follows)
                for idx, item in ipairs(self.placeable) do
                    if item.id == clicked_obj.id then
                        self.selected_idx = idx
                        self:_onSelectionChanged()
                        break
                    end
                end

                -- Remove it from the grid so it's only attached to cursor
                table.remove(self.placed, clicked_idx)
                print("[room-editor] Picked up " .. clicked_obj.id .. " for editing")
            else
                -- 2. Empty space: PLACE the active item
                local active_spec = self.placeable[self.selected_idx]
                if active_spec then
                    -- Delete any existing block with this ID to overwrite (since catalog items are unique)
                    for i = #self.placed, 1, -1 do
                        if self.placed[i].id == active_spec.id then
                            table.remove(self.placed, i)
                        end
                    end

                    -- Add to placed list
                    table.insert(self.placed, {
                        id       = active_spec.id,
                        gx       = gx,
                        gy       = gy,
                        w        = self.active_w,
                        h        = self.active_h,
                        z_offset = self.active_z,
                        sh       = self.active_sh,
                        color    = active_spec.id == "poker_poster" and { 0.82, 0.42, 0.38 } or { 0.40, 0.55, 0.75 },
                        scale    = self.active_scale,
                        flip_x   = self.active_flip_x,
                        align    = self.active_align,
                    })
                    print(string.format("[room-editor] Placed %s at (%.3f, %.3f)", active_spec.id, gx, gy))
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
        else
            -- Delete hovered item
            if click_gx >= 0 and click_gx < self.room_size and click_gy >= 0 and click_gy < self.room_size then
                for i = #self.placed, 1, -1 do
                    local o = self.placed[i]
                    if click_gx >= o.gx and click_gx < o.gx + o.w and click_gy >= o.gy and click_gy < o.gy + o.h then
                        print("[room-editor] Deleted object: " .. o.id)
                        table.remove(self.placed, i)
                        break
                    end
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
        if self.picked_item then
            -- Restore the picked item before exiting
            table.insert(self.placed, self.picked_item)
            self.picked_item = nil
        end
        self.editor_mode = false
        print("[room-editor] Exited Room Editor Mode.")
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

    -- Height offset adjustments
    if key == "7" then
        self.active_z = math.max(0, self.active_z - 4)
        return true
    elseif key == "8" then
        self.active_z = self.active_z + 4
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

    -- Selection cycling (Q/E, or Up/Down). The browser follows: the
    -- selection's folder unfolds and the list scrolls it into view.
    if key == "q" or key == "up" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx - 1
        if self.selected_idx < 1 then self.selected_idx = #self.placeable end
        self:syncActiveParams()
        self:_onSelectionChanged()
        return true
    elseif key == "e" or key == "down" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx + 1
        if self.selected_idx > #self.placeable then self.selected_idx = 1 end
        self:syncActiveParams()
        self:_onSelectionChanged()
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
            self.active_w  = o.w
            self.active_h  = o.h
            self.active_z  = o.z_offset
            self.active_sh = o.sh
            self.active_scale = o.scale or 1.0
            self.active_flip_x = o.flip_x or false
            self.active_align = o.align or "center"
            found = true
            break
        end
    end
    
    if not found then
        self.active_w  = 1
        self.active_h  = 1
        self.active_sh = 16
        self.active_z  = 0
        self.active_scale = 1.0
        self.active_flip_x = false
        self.active_align = "center"
    end
end

-- Wheel: over the sidebar it scrolls the item browser; over the room it
-- cycles the selection (and the browser follows the selection).
function RoomView:wheelmoved(dy)
    if not self.editor_mode then return false end
    local mx = love.mouse.getX()
    local s  = self.game.ui_scale or 1
    if mx < math.floor(270 * s) then
        self.list_scroll = self.list_scroll - dy * math.floor(40 * s)
        return true   -- clamped in draw against the live layout
    end
    if self.picked_item then return true end
    if dy > 0 then
        self.selected_idx = self.selected_idx - 1
        if self.selected_idx < 1 then self.selected_idx = #self.placeable end
    else
        self.selected_idx = self.selected_idx + 1
        if self.selected_idx > #self.placeable then self.selected_idx = 1 end
    end
    self:syncActiveParams()
    self:_onSelectionChanged()
    return true
end

-- Export function: Print the Lua return layout array directly to standard output
function RoomView:serializeLayout()
    print("---------------- COPY FROM LINE BELOW ----------------")
    print("return {")
    
    local floor_theme = self.floor_idx == 0 and "Default" or self.floor_list[self.floor_idx]
    local wall_theme = self.wall_idx == 0 and "Default" or self.wall_list[self.wall_idx]
    print("    __meta = {")
    print(string.format("        room_size = %d,", self.room_size))
    print(string.format("        floor_theme = %q,", floor_theme))
    print(string.format("        wall_theme = %q,", wall_theme))
    print("    },")

    -- Sort placed items alphabetically by id for neatness
    local sorted = {}
    for _, o in ipairs(self.placed) do sorted[#sorted + 1] = o end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    for _, o in ipairs(sorted) do
        local scale_str = o.scale and string.format(", scale = %.2f", o.scale) or ""
        local flip_str = o.flip_x and ", flip_x = true" or ""
        local align_str = o.align and o.align ~= "center" and string.format(", align = %q", o.align) or ""
        print(string.format("    %-20s = { gx = %.3f, gy = %.3f, w = %d, h = %d, z_offset = %d, sh = %d, color = { %.2f, %.2f, %.2f }%s%s%s },",
            o.id, o.gx, o.gy, o.w, o.h, o.z_offset, o.sh, o.color[1], o.color[2], o.color[3], scale_str, flip_str, align_str))
    end
    print("}")
    print("------------------------------------------------------")
end

return RoomView
