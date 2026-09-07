-- sim/deck_curve_check.lua
--
-- How fast Standard levels. Gross $ won per hour per table at every stake
-- and cash game type, naked / mid / capped fill, from the engine's own
-- outcome pipeline (models/outcome_math.buildOutcome + the tier bands),
-- then hours to each Standard level on 1, 4 and 9 tables.
--
--   lua sim/deck_curve_check.lua                    Standard's live curve
--   lua sim/deck_curve_check.lua 2e3,2e4,1e5,5e5,2e6  a curve to try
--
-- "Gross $ won" is what the money_won XP rule counts: the delta of every
-- won hand, so P(win) x E[win bb] x $/bb x hands/hr. Seconds per hand are
-- the sweep's constants (tools/balance_sweep.js SEC_PER_HAND, from
-- sim/gtype_ev.lua). No focus penalty, no cursor overhead: the ceiling.

io.stdout:setvbuf("no")
love = { math = { random = math.random }, timer = { getTime = os.clock } }
package.path = package.path .. ";./?.lua"

local OutcomeMath = require("models.outcome_math")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local Decks       = require("data.decks")

local SEC_PER_HAND = { six_max = 17, hu = 6.2, zoom = 2.2 }
local STACK_BB     = 100

local curve
if arg and arg[1] then
    curve = {}
    for n in arg[1]:gmatch("[^,]+") do curve[#curve + 1] = tonumber(n) end
else
    for _, d in ipairs(Decks) do if d.id == "standard" then curve = d.xp_curve end end
end
assert(curve and #curve == 5, "need five thresholds")

local function fullCtx(levels)
    local fill = { { strength = levels } }
    return { win_chance_fills = fill, win_dist_fills = fill, loss_dist_fills = fill }
end

local function grossPerHour(gt, st, ctx)
    local wc, wd = OutcomeMath.buildOutcome(ctx, gt, st)
    local cap = OutcomeMath.maxWinBB(gt, STACK_BB)
    local ebb = 0
    for _, tier in ipairs(OutcomeMath.TIER_KEYS) do
        ebb = ebb + (wd[tier] or 0) * OutcomeMath.tierAvgBB(tier, gt, true, cap)
    end
    local bb_usd = (st.buy_in or 0) / STACK_BB
    local hands_hr = 3600 / (SEC_PER_HAND[gt.id] or 17)
    return wc * ebb * bb_usd * hands_hr
end

local function money(v)
    if v >= 1e9 then return ("$%.1fB"):format(v / 1e9) end
    if v >= 1e6 then return ("$%.1fM"):format(v / 1e6) end
    if v >= 1e3 then return ("$%.0fk"):format(v / 1e3) end
    return ("$%.0f"):format(v)
end
local function hours(h)
    if h < 1/60 then return "<1m" end
    if h < 1 then return ("%.0fm"):format(h * 60) end
    if h < 100 then return ("%.1fh"):format(h) end
    return ("%.0fh"):format(h)
end

print(("Standard curve: %s"):format(table.concat((function()
    local t = {} for i, v in ipairs(curve) do t[i] = money(v) end return t end)(), " / ")))
print("hours to reach L1..L5 from zero, gross $ won; columns = tables at that one stake")
print()
for _, gt in ipairs(GameTypes) do
    if gt.id ~= "ko" then
        print(("== %s (%.1fs a hand) =="):format(gt.id, SEC_PER_HAND[gt.id] or 0))
        print(("%-5s %-6s %10s | %-28s | %-28s | %-28s"):format("stake", "fill", "$/hr/tbl", "1 table  L1 L2 L3 L4 L5", "4 tables L1 L2 L3 L4 L5", "9 tables L1 L2 L3 L4 L5"))
        for _, st in ipairs(Stakes) do
            if st.id ~= "s010" and st.fill_window then
                local w = st.fill_window
                for _, fill in ipairs{ { "naked", nil }, { "mid", (w.start + w.complete) / 2 }, { "capped", w.complete } } do
                    local ctx = fill[2] and fullCtx(fill[2]) or nil
                    local per = grossPerHour(gt, st, ctx)
                    local cols = {}
                    for _, n in ipairs{ 1, 4, 9 } do
                        local cells = {}
                        for L = 1, 5 do
                            cells[#cells + 1] = per > 0 and hours(curve[L] / (per * n)) or "never"
                        end
                        cols[#cols + 1] = ("%-28s"):format(table.concat(cells, " "))
                    end
                    print(("%-5s %-6s %10s | %s | %s | %s"):format(st.id, fill[1], money(per), cols[1], cols[2], cols[3]))
                end
            end
        end
        print()
    end
end
