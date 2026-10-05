-- models/board_preview.lua
--
-- "What would this move do?" for a table being dragged: the board as it
-- would be with the held table in `target` (swapping with whatever sits
-- there), and for every table what changes in the bonuses that read where
-- a table sits. The same rules as GrindController's per-frame stamp
-- (empty sides inside the board's bounds, nothing on any side, Zoom
-- neighbours; a 6-Max counts as empty with the Comfort Bed), applied to a
-- virtual layout so nothing is moved until the drop.
--
-- Pure: tables in, a result out. GrindView memoises it on the drop cell.

local TableGrid = require("models.table_grid")

local BoardPreview = {}

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function pct(v) return string.format("%+d%%", math.floor(v * 100 + 0.5)) end

-- The virtual layout: { [tbl] = { slot, ea, lonely, zn, near_tilt } },
-- plus the board's cols, rows and the slot → table map.
function BoardPreview.layout(tables, moved, target, ctx)
    local slot_of = {}
    local from = moved.slot or 0
    for _, t in ipairs(tables) do slot_of[t] = t.slot or 0 end
    for _, t in ipairs(tables) do
        if t ~= moved and slot_of[t] == target then slot_of[t] = from end
    end
    slot_of[moved] = target
    local occupied, slots = {}, {}
    for _, t in ipairs(tables) do
        occupied[slot_of[t]] = t
        slots[#slots + 1] = slot_of[t]
    end
    local cols, rows = TableGrid.bounds(slots)
    local six_empty = ctx and ctx.six_max_counts_empty
    local out = {}
    for _, t in ipairs(tables) do
        local r, c = TableGrid.unpack(slot_of[t])
        local ea, nb, zn, near_tilt = 0, 0, 0, false
        for _, d in ipairs(DIRS) do
            local rr, cc = r + d[1], c + d[2]
            local o = occupied[TableGrid.pack(rr, cc)]
            local counts_empty = (o == nil) or (six_empty and o.game_type_id == "six_max")
            if not counts_empty then nb = nb + 1 end
            local inside = rr >= 0 and rr < rows and cc >= 0 and cc < cols
            if inside and counts_empty then ea = ea + 1 end
            if o and t.game_type_id == "zoom" and o.game_type_id == "zoom" then zn = zn + 1 end
            -- A 6-Max's stack loss and a tournament's bust tilt the tables
            -- beside them (data/procs.lua tilt_cooler, tilt_miss).
            if o and (o.game_type_id == "six_max" or o.game_type_id == "ko") then near_tilt = true end
        end
        out[t] = { slot = slot_of[t], ea = ea, lonely = (nb == 0), zn = zn, near_tilt = near_tilt }
    end
    return out, cols, rows, occupied
end

-- For each table whose bonuses would change, the changes as short lines
-- { text, good } ("+10% odds", "x1.5 lost", "+20% pace", "beside a 6-Max:
-- tilt"). `now` is a function(tbl) giving the current { ea, lonely, zn,
-- near_tilt } (the controller's stamps, or a layout of the board as it is).
function BoardPreview.deltas(tables, virtual, now, ctx)
    ctx = ctx or {}
    local res = {}
    for _, t in ipairs(tables) do
        local v, c = virtual[t], now(t)
        local lines = {}
        if v and c then
            local per = ctx.odds_per_empty_adjacent or 0
            if per > 0 and v.ea ~= c.ea then
                local d = (v.ea - c.ea) * per
                lines[#lines + 1] = { text = pct(d) .. " odds", good = d > 0 }
            end
            local mult = ctx.lonely_winnings_mult
            if mult and v.lonely ~= c.lonely then
                lines[#lines + 1] = v.lonely and { text = string.format("x%.1f alone", mult), good = true }
                                              or { text = string.format("x%.1f lost", mult), good = false }
            end
            local zp = ctx.zoom_block_pace or 0
            if zp > 0 and t.game_type_id == "zoom" and v.zn ~= c.zn then
                local d = (v.zn - c.zn) * zp
                lines[#lines + 1] = { text = pct(d) .. " pace", good = d > 0 }
            end
            if v.near_tilt and not c.near_tilt then
                lines[#lines + 1] = { text = "tilt risk", good = false }
            elseif c.near_tilt and not v.near_tilt then
                lines[#lines + 1] = { text = "out of tilt range", good = true }
            end
        end
        if #lines > 0 then res[t] = lines end
    end
    return res
end

return BoardPreview
