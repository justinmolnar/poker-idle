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

function RoomView:new(game)
    -- Load all layout positions from room_layout
    local placed = {}
    for id, info in pairs(Layout) do
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
        }
    end

    -- Create list of placeable catalog item specs dynamically from SpriteLoader and Catalog
    local placeable = {}
    local sprites_seen = {}
    if game.sprite_loader and game.sprite_loader.sprites then
        local sprite_names = {}
        for name, _ in pairs(game.sprite_loader.sprites) do
            if name:sub(1, 10) == "isometric/" then
                sprite_names[#sprite_names + 1] = name
            end
        end
        table.sort(sprite_names)
        
        for _, name in ipairs(sprite_names) do
            placeable[#placeable + 1] = {
                id = name,
                name = name:match("([^/]+)$") or name,
                sprite = name,
            }
            sprites_seen[name] = true
        end
    end
    for _, item in ipairs(Catalog) do
        if not item.hidden and item.id ~= "no_poster_handicap" then
            if not sprites_seen[item.id] then
                placeable[#placeable + 1] = item
            end
        end
    end

    return setmetatable({
        game          = game,
        placed        = placed,     -- active placed furniture objects list
        placeable     = placeable,  -- list of all placeable items from catalog.lua
        editor_mode   = false,      -- true = grid lines, placement selector, mouse controls
        selected_idx  = 1,          -- active item index in the placeable list
        active_w      = 1,          -- current placement footprint width
        active_h      = 1,          -- current placement footprint height
        active_sh     = 16,         -- current placement visual thickness/height
        active_z      = 0,          -- current placement vertical height offset
        active_scale  = 1.0,        -- current sprite scale factor
        active_flip_x = false,      -- current sprite horizontal flip
        picked_item   = nil,
    }, RoomView)
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

    local state = game.state
    local owned_set = {}
    if state.owned_items then
        for _, id in ipairs(state.owned_items) do
            owned_set[id] = true
        end
    end

    local tw = TILE_W * s
    local th = TILE_H * s
    local wh = WALL_H * s

    -- 1. Draw background walls (corner walls of the room)
    -- Left-back wall
    local lx1, ly1 = gridToScreen(0, 0, cx, cy, tw, th)
    local lx2, ly2 = gridToScreen(GRID_SIZE, 0, cx, cy, tw, th)
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

    -- Right-back wall
    local rx1, ry1 = gridToScreen(0, 0, cx, cy, tw, th)
    local rx2, ry2 = gridToScreen(0, GRID_SIZE, cx, cy, tw, th)
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

    -- 2. Draw floor tiles grid
    for x = 0, GRID_SIZE - 1 do
        for y = 0, GRID_SIZE - 1 do
            local fx, fy = gridToScreen(x + 0.5, y + 0.5, cx, cy, tw, th)
            -- Checkerboard floor pattern
            if (x + y) % 2 == 0 then
                Theme.setColor(Theme.bg.widget)
            else
                Theme.setColor(darken(Theme.bg.widget, 0.92))
            end
            -- Draw single floor tile polygon
            local tx1, ty1 = gridToScreen(x, y, cx, cy, tw, th)
            local tx2, ty2 = gridToScreen(x + 1, y, cx, cy, tw, th)
            local tx3, ty3 = gridToScreen(x + 1, y + 1, cx, cy, tw, th)
            local tx4, ty4 = gridToScreen(x, y + 1, cx, cy, tw, th)
            love.graphics.polygon("fill", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)

            -- Wireframe grid lines (only in editor mode)
            if self.editor_mode then
                Theme.setColor(Theme.border.soft, 0.18)
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
        
        local sprite = game.sprite_loader:getSprite(obj.id)
        if sprite then
            local sx, sy = gridToScreen(obj.gx + obj.w*0.5, obj.gy + obj.h*0.5, cx, cy, tw, th)
            local scale_factor = obj.scale or 1.0
            local draw_scale_x = s * scale_factor
            local draw_scale_y = s * scale_factor
            
            local ox = sprite:getWidth() * 0.5
            local oy = sprite:getHeight()
            
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
    gx = math.floor(gx)
    gy = math.floor(gy)

    local active_spec = self.placeable[self.selected_idx]

    if self.editor_mode and active_spec then
        -- Hover preview tile highlighting
        if gx >= 0 and gx < GRID_SIZE and gy >= 0 and gy < GRID_SIZE then
            local tx1, ty1 = gridToScreen(gx, gy, cx, cy, tw, th)
            local tx2, ty2 = gridToScreen(gx + self.active_w, gy, cx, cy, tw, th)
            local tx3, ty3 = gridToScreen(gx + self.active_w, gy + self.active_h, cx, cy, tw, th)
            local tx4, ty4 = gridToScreen(gx, gy + self.active_h, cx, cy, tw, th)

            -- Fill footprint highlight green
            Theme.setColor(Theme.status.good, 0.25)
            love.graphics.polygon("fill", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)
            Theme.setColor(Theme.status.good, 0.8)
            love.graphics.polygon("line", tx1, ty1, tx2, ty2, tx3, ty3, tx4, ty4)

            -- Draw placement preview block
            -- Draw placement preview block (sprite or fallback box)
            local sprite = game.sprite_loader:getSprite(active_spec.id)
            if sprite then
                local sx, sy = gridToScreen(gx + self.active_w*0.5, gy + self.active_h*0.5, cx, cy, tw, th)
                local scale_factor = self.active_scale or 1.0
                local draw_scale_x = s * scale_factor
                local draw_scale_y = s * scale_factor
                
                local ox = sprite:getWidth() * 0.5
                local oy = sprite:getHeight()
                
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
        local exp_y = sidebar_y + fl(225 * s)
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

        -- Catalog items selection list
        local cat_y = rst_y + btn_h + fl(12 * s)
        love.graphics.setFont(game.fonts.md)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print("CATALOG ITEMS:", sidebar_x + text_margin, cat_y)
        cat_y = cat_y + fl(22 * s)

        love.graphics.setFont(game.fonts.sm)
        for idx, item in ipairs(self.placeable) do
            local active = (idx == self.selected_idx)
            if active then
                Theme.setColor(Theme.status.warn)
                love.graphics.print("> " .. item.name, sidebar_x + text_margin, cat_y)
            else
                Theme.setColor(owned_set[item.id] and Theme.fg.primary or Theme.fg.disabled)
                love.graphics.print("  " .. item.name, sidebar_x + text_margin, cat_y)
            end
            cat_y = cat_y + fl(16 * s)
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
        
        local exp_y = sidebar_y + math.floor(225 * s)
        local rst_y = exp_y + btn_h + btn_gap

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
                        }
                    end
                    self.picked_item = nil
                    print("[room-editor] Reset all layout changes to saved defaults")
                    return true
                end
            end
        end
        return true -- consume all other clicks in sidebar
    end

    local cx, cy = getCenter(W, H, s, self.full_screen)

    local tw = TILE_W * s
    local th = TILE_H * s

    local gx, gy = screenToGrid(x, y, cx, cy, tw, th)
    gx = math.floor(gx)
    gy = math.floor(gy)

    -- Left click
    if button == 1 then

        if gx >= 0 and gx < GRID_SIZE and gy >= 0 and gy < GRID_SIZE then
            -- 1. Check if hovering an existing object to PICK UP
            local clicked_obj = nil
            local clicked_idx = nil
            for i, o in ipairs(self.placed) do
                if gx >= o.gx and gx < o.gx + o.w and gy >= o.gy and gy < o.gy + o.h then
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
                }
                -- Load its specs to the active cursor parameters
                self.active_w  = clicked_obj.w
                self.active_h  = clicked_obj.h
                self.active_sh = clicked_obj.sh
                self.active_z  = clicked_obj.z_offset
                self.active_scale = clicked_obj.scale or 1.0
                self.active_flip_x = clicked_obj.flip_x or false
                
                -- Sync selected_idx to match this item
                for idx, item in ipairs(self.placeable) do
                    if item.id == clicked_obj.id then
                        self.selected_idx = idx
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
                    })
                    print(string.format("[room-editor] Placed %s at (%d, %d)", active_spec.id, gx, gy))
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
            if gx >= 0 and gx < GRID_SIZE and gy >= 0 and gy < GRID_SIZE then
                for i = #self.placed, 1, -1 do
                    local o = self.placed[i]
                    if gx >= o.gx and gx < o.gx + o.w and gy >= o.gy and gy < o.gy + o.h then
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

    -- Selection cycling (Q / E)
    if key == "q" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx - 1
        if self.selected_idx < 1 then self.selected_idx = #self.placeable end
        self:syncActiveParams()
        return true
    elseif key == "e" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx + 1
        if self.selected_idx > #self.placeable then self.selected_idx = 1 end
        self:syncActiveParams()
        return true
    end

    -- Selection cycling backup (Up / Down)
    if key == "up" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx - 1
        if self.selected_idx < 1 then self.selected_idx = #self.placeable end
        self:syncActiveParams()
        return true
    elseif key == "down" then
        if self.picked_item then return true end
        self.selected_idx = self.selected_idx + 1
        if self.selected_idx > #self.placeable then self.selected_idx = 1 end
        self:syncActiveParams()
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
    end
end

-- Cycle through selector via scroll wheel
function RoomView:wheelmoved(dy)
    if not self.editor_mode then return false end
    if self.picked_item then return true end
    if dy > 0 then
        self.selected_idx = self.selected_idx - 1
        if self.selected_idx < 1 then self.selected_idx = #self.placeable end
    else
        self.selected_idx = self.selected_idx + 1
        if self.selected_idx > #self.placeable then self.selected_idx = 1 end
    end
    self:syncActiveParams()
    return true
end

-- Export function: Print the Lua return layout array directly to standard output
function RoomView:serializeLayout()
    print("---------------- COPY FROM LINE BELOW ----------------")
    print("return {")
    -- Sort placed items alphabetically by id for neatness
    local sorted = {}
    for _, o in ipairs(self.placed) do sorted[#sorted + 1] = o end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    for _, o in ipairs(sorted) do
        local scale_str = o.scale and string.format(", scale = %.2f", o.scale) or ""
        local flip_str = o.flip_x and ", flip_x = true" or ""
        print(string.format("    %-20s = { gx = %d, gy = %d, w = %d, h = %d, z_offset = %d, sh = %d, color = { %.2f, %.2f, %.2f }%s%s },",
            o.id, o.gx, o.gy, o.w, o.h, o.z_offset, o.sh, o.color[1], o.color[2], o.color[3], scale_str, flip_str))
    end
    print("}")
    print("------------------------------------------------------")
end

return RoomView
