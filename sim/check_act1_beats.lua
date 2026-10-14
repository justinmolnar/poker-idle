-- sim/check_act1_beats.lua
--
-- Does every Act 1 item arrive in the catalog it was designed for? The Act 1
-- catalog is laid out by beat (data/catalog.lua, 2026-10-05): the catalog
-- after shove 1, after 2, after 3, after 4. This runs sim/act1.lua, records
-- the lifetime counters at every shove, takes the median per shove, and
-- reports for each Act 1 item the first shove whose median opens it, next
-- to the beat it is meant for. Exit 1 when an item lands elsewhere.
--
--   lua sim/check_act1_beats.lua [seeds]
--
-- docs/act1-sim.md (which sim/act1.lua writes) is put back as it was.

package.path = "./?.lua;" .. package.path

-- The beats, by design. Anything not listed is not an Act 1 item.
local BEAT = {
    energy_drink = 1, yellow_sticky_note = 1, fight_night_poster = 1, starter_gift_box = 1, mirror = 1, box_of_mice = 1,
    compact_fridge = 1,
    corkboard = 2, stack_of_books = 2, bottle_of_wine = 2, handheld = 2, lava_lamp = 2, house_cat = 2,
    desk = 2, chrome_toaster = 2, rebuy_sticky_note = 2, ring_binder = 2,
    dogs_playing_poker = 3, trophy_shelf = 3, dusty_console = 3, washing_machine = 3,
    hybrid_console = 3, candle = 3, pencil_holder = 3, gaming_chair = 3,
    wall_clock = 4,
}

local seeds = tonumber(arg and arg[1]) or 20

local doc_path = "docs/act1-sim.md"
local fh = io.open(doc_path, "rb")
local doc_before = fh and fh:read("*a")
if fh then fh:close() end

-- Record the counters at each shove (resetRun runs once per shove).
local GS = require("models.GameState")
local records = {}   -- [shove] = { state copies }
local real = GS.resetRun
GS.resetRun = function(self, ...)
    local n = (self.shove_count or 0) + 1
    local snap = {}
    for k, v in pairs(self) do
        if type(k) == "string" and (k:match("^total_") or k == "has_shoved") then
            snap[k] = (type(v) == "table") and { table.unpack and table.unpack({}) } or v
            if type(v) == "table" then
                local cp = {}
                for kk, vv in pairs(v) do cp[kk] = vv end
                snap[k] = cp
            end
        end
    end
    snap.shove_count = n
    snap.has_shoved = true
    records[n] = records[n] or {}
    table.insert(records[n], snap)
    return real(self, ...)
end

arg = { "--seeds=" .. seeds }
local quiet = io.write
io.write = function() end
local real_print = print
print = function() end
dofile("sim/act1.lua")
print, io.write = real_print, quiet

if doc_before then
    local out = io.open(doc_path, "wb"); out:write(doc_before); out:close()
end

-- The median state at each shove.
local function median(list)
    table.sort(list)
    return list[math.floor((#list + 1) / 2)] or 0
end
local medians = {}
for n, snaps in pairs(records) do
    local m = { shove_count = n, has_shoved = true, total_hands_by_gtype = {} }
    local keys = {}
    for _, s in ipairs(snaps) do for k, v in pairs(s) do if type(v) == "number" then keys[k] = true end end end
    for k in pairs(keys) do
        local vals = {}
        for _, s in ipairs(snaps) do vals[#vals + 1] = s[k] or 0 end
        m[k] = median(vals)
    end
    for _, g in ipairs({ "zoom", "hu" }) do
        local vals = {}
        for _, s in ipairs(snaps) do vals[#vals + 1] = (s.total_hands_by_gtype or {})[g] or 0 end
        m.total_hands_by_gtype[g] = median(vals)
    end
    medians[n] = m
end

-- The unlock predicates, as the game registers them.
local preds = {}
local reg = { register = function(_, name, pred) preds[name] = pred end }
require("models.catalog_unlock_rules").registerAll(reg)

local CL = require("models.catalog_loader")
local Catalog = CL.deriveAll(require("data.catalog"))
local byId = {}
for _, it in ipairs(Catalog) do byId[it.id] = it end

local function opensAt(item, depth)
    depth = depth or 0
    for n = 1, 12 do
        local st = medians[n]
        if not st then return nil end
        local ok = true
        if item.unlock then
            local p = preds[item.unlock.kind]
            ok = p and p(item.unlock, st) or false
        end
        if ok and item.requires and depth < 4 then
            local req = byId[item.requires]
            local at = req and opensAt(req, depth + 1)
            ok = at ~= nil and at <= n
        end
        if ok then return n end
    end
    return nil
end

-- The median counters at each shove (what the thresholds are set from).
real_print("median counters at each shove:")
for n = 1, 6 do
    local m = medians[n]
    if m then
        real_print(("  shove %d: chips %d, won %d, played %d, stacks %d, stack losses %d, busts %d, rebuys %d, upgrade levels %d, zoom %d, hu %d"):format(
            n, m.total_chips_banked or 0, m.total_hands_won or 0, m.total_hands_played or 0, m.total_stacks or 0,
            m.total_stack_losses or 0, m.total_busts or 0, m.total_rebuys or 0, m.total_upgrade_levels or 0,
            m.total_hands_by_gtype.zoom or 0, m.total_hands_by_gtype.hu or 0))
    end
end
real_print("")

local bad = 0
local ids = {}
for id in pairs(BEAT) do ids[#ids + 1] = id end
table.sort(ids, function(a, b) if BEAT[a] ~= BEAT[b] then return BEAT[a] < BEAT[b] end return a < b end)
real_print(("%-20s %5s %8s %s"):format("item", "beat", "opens", ""))
for _, id in ipairs(ids) do
    local it = byId[id]
    local at = it and opensAt(it)
    local ok = at == BEAT[id]
    if not ok then bad = bad + 1 end
    real_print(("%-20s %5d %8s %s"):format(id, BEAT[id], at and ("after " .. at) or "later", ok and "" or "<- off beat"))
end
-- Any Act 1 item the beat table does not place.
for _, it in ipairs(Catalog) do
    if CL.isOwnable(it) and not it.retired and not it.hidden and it.act ~= 2 and not BEAT[it.id]
       and it.id ~= "prize_vase" then
        bad = bad + 1
        real_print(("%-20s  not placed on a beat"):format(it.id))
    end
end
real_print(("\ncheck_act1_beats: %d off beat"):format(bad))
if bad > 0 then os.exit(1) end
