-- sim/felt_check.lua
--
-- The "is this just another version of teal" audit. Recomputes every
-- stake's felt from the live data files (chips, stakes, felt_style,
-- theme) and flags any pair of rooms a player couldn't tell apart at a
-- glance. Run it after touching felt_style color knobs, a felt_chip, or
-- a chip color:
--
--   lua sim/felt_check.lua
--
-- Exit code 1 when any pair is flagged, so it can gate a commit.
--
-- MIRRORS views/TablePanel.feltForStake (which can't be required here —
-- it pulls the whole view stack). Keep the math in step with it.

package.path = package.path .. ";./?.lua"

local ChipData  = require("data.chips")
local Stakes    = require("data.stakes")
local FeltStyle = require("data.felt_style")
local ThemeData = require("data.theme")

-- Both palettes' base felts: rooms must stay distinct under each.
local bases = {}
for pname, pal in pairs(ThemeData.palettes) do
    if pal.bg and pal.bg.felt then
        bases[#bases + 1] = { name = pname, felt = pal.bg.felt }
    end
end
table.sort(bases, function(a, b) return a.name < b.name end)

local function feltFor(stake, base)
    local bb = stake.bb or 0
    local best
    if stake.felt_chip then
        for _, d in ipairs(ChipData.denominations) do
            if d.value == stake.felt_chip then best = d; break end
        end
    end
    if not best then
        for _, d in ipairs(ChipData.denominations) do
            if d.value <= bb then best = d else break end
        end
    end
    best = best or ChipData.denominations[1]
    local col = best.color
    local cc  = FeltStyle.color or {}
    local base_luma = 0.30 * base[1] + 0.59 * base[2] + 0.11 * base[3]
    local target = base_luma * (cc.luma or 1.10)
    local C = cc.chroma or 0.10
    local cy = 0.30 * col[1] + 0.59 * col[2] + 0.11 * col[3]
    local cr, cb = col[1] - cy, col[3] - cy
    local n = math.sqrt(cr * cr + cb * cb)
    if n < (cc.min_chroma or 0.06) then
        cr, cb = base[1] - base_luma, base[3] - base_luma
        n = math.sqrt(cr * cr + cb * cb)
    end
    local r = target + C * cr / n
    local b = target + C * cb / n
    local g = (target - 0.30 * r - 0.11 * b) / 0.59
    r = math.max(0, math.min(1, r))
    g = math.max(0, math.min(1, g))
    b = math.max(0, math.min(1, b))
    return { r, g, b }, best.label, math.deg(math.atan2 and math.atan2(cb / n, cr / n)
                                             or math.atan(cb / n, cr / n))
end

-- Two rooms "read alike" when their hue angles are close. Chroma and
-- luma are identical by construction, so hue is the whole signal.
-- Under FAIL_DEG two dark muted felts are the same room, full stop
-- (exit 1). Under WARN_DEG they're siblings — legal, listed so the
-- closeness is a choice and not a surprise. Ten rooms on one wheel
-- average 36 degrees apart, so some sub-30 pairs are unavoidable; the
-- audit exists to keep them deliberate and far between.
local FAIL_DEG = 15
local WARN_DEG = 30

local function huesep(a, b)
    local d = math.abs(a - b) % 360
    return d > 180 and 360 - d or d
end

local failed = false
for _, bd in ipairs(bases) do
    print(("=== palette %q (base felt %.3f %.3f %.3f) ==="):format(
        bd.name, bd.felt[1], bd.felt[2], bd.felt[3]))
    local rooms = {}
    for _, stake in ipairs(Stakes) do
        local c, chip, hue = feltFor(stake, bd.felt)
        rooms[#rooms + 1] = { name = stake.display_name or stake.id,
                              c = c, chip = chip, hue = hue }
        print(("  %-8s chip %-4s hue %7.1f  ->  %3.0f %3.0f %3.0f"):format(
            rooms[#rooms].name, chip, hue,
            c[1] * 255, c[2] * 255, c[3] * 255))
    end
    for i = 1, #rooms do
        for j = i + 1, #rooms do
            local sep = huesep(rooms[i].hue, rooms[j].hue)
            if sep < FAIL_DEG then
                failed = true
                print(("  FAIL %s vs %s: %.0f deg apart — same room to a player")
                    :format(rooms[i].name, rooms[j].name, sep))
            elseif sep < WARN_DEG then
                print(("  warn %s vs %s: %.0f deg apart — siblings, check by eye")
                    :format(rooms[i].name, rooms[j].name, sep))
            end
        end
    end
end

if failed then
    print("FAIL: at least one pair of rooms reads alike")
    os.exit(1)
end
print("OK: no pair of rooms reads alike")
