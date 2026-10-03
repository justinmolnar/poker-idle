-- views/OutcomeBar.lua
--
-- A table's odds as one bar: losses on the left (stack, large, medium,
-- small), wins on the right (small, medium, large, stack), each tier in its
-- own colour (Theme.tier), every segment as wide as its absolute chance.
-- Where the red ends and the green begins is the win rate; the gold at the
-- right edge is the stack win, the deep red at the left the stack loss.
--
-- Stats are the shape OutcomeMath and Table:estimateStats return:
-- { win_chance, win_dist = { small, medium, large, stack }, loss_dist = ... },
-- both dists conditional (each sums to 1 within its side).
--
-- A `ghost` (the next level of an upgrade) draws as a thin strip of the same
-- bar under it, on the same scale, so the segments that move show as an
-- offset between the two. Used by the table readout (views/TablePanelStats),
-- the add-table rows, the upgrade tooltips and the hover preview.

local Theme = require("views.Theme")

local OutcomeBar = {}

local TIERS = { "stack", "large", "medium", "small" }   -- loss side, left to right
local WINS  = { "small", "medium", "large", "stack" }   -- win side, left to right
OutcomeBar.LOSS_ORDER, OutcomeBar.WIN_ORDER = TIERS, WINS
local SIDES, DISTS = { "loss", "win" }, { "win_dist", "loss_dist" }

-- The eight segments' (x, w) for a bar at x of width w, written into `out`
-- as out[side][tier] = { x, w } (reused). A segment with any chance at all
-- gets at least a pixel; the rest share what is left.
local function segments(stats, x, w, out)
    out = out or { loss = {}, win = {} }
    local wc = math.max(0, math.min(1, stats.win_chance or 0))
    local wd, ld = stats.win_dist or {}, stats.loss_dist or {}
    local cx = x
    local function seg(side, tier, p)
        local px = math.floor(p * w + 0.5)
        if p > 0 and px < 1 then px = 1 end
        local s = out[side][tier]
        if not s then s = {}; out[side][tier] = s end
        s[1], s[2] = cx, px
        cx = cx + px
    end
    for _, t in ipairs(TIERS) do seg("loss", t, (1 - wc) * (ld[t] or 0)) end
    for _, t in ipairs(WINS)  do seg("win",  t, wc * (wd[t] or 0)) end
    -- Rounding drift lands on the last non-empty win segment.
    local over = (cx - x) - w
    if over ~= 0 then
        for i = #WINS, 1, -1 do
            local s = out.win[WINS[i]]
            if s[2] > 0 then s[2] = math.max(0, s[2] - over); break end
        end
    end
    return out
end
OutcomeBar.segments = segments

local _a, _b = { loss = {}, win = {} }, { loss = {}, win = {} }

local function paint(segs, y, h, alpha)
    for _, side in ipairs(SIDES) do
        local order = (side == "loss") and TIERS or WINS
        local pal = Theme.tier and Theme.tier[side] or nil
        for _, t in ipairs(order) do
            local s = segs[side][t]
            if s[2] > 0 then
                local c = (pal and pal[t]) or ((side == "win") and Theme.sem.won or Theme.sem.lost)
                Theme.setColor(c, alpha or 1)
                love.graphics.rectangle("fill", s[1], y, s[2], h)
            end
        end
    end
end

-- Draw at (x, y), w by h. opts: ghost (stats), alpha.
function OutcomeBar.draw(x, y, w, h, stats, opts)
    if not stats or w < 4 or h < 1 then return end
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local ghost = opts and opts.ghost
    local main_h = h
    if ghost then main_h = math.max(1, h - math.max(2, math.floor(h / 3)) - 1) end
    -- A faint track under it all, so a bar of tiny odds still reads as a bar.
    Theme.setColor(Theme.border.default, 0.35)
    love.graphics.rectangle("fill", x, y, w, main_h)
    paint(segments(stats, x, w, _a), y, main_h, opts and opts.alpha)
    if ghost then
        local gy = y + main_h + 1
        paint(segments(ghost, x, w, _b), gy, y + h - gy, 0.9)
    end
    -- The win/loss split, a hairline: where the bar crosses over.
    local split = _a.win.small[1]
    Theme.setColor(Theme.fg.heading, 0.55)
    love.graphics.rectangle("fill", split, y - 1, 1, main_h + 2)
end

-- Move display stats `d` toward `s` by fraction k (1 snaps): the bar
-- eases between odds instead of jumping. Allocation-free once d's dist
-- tables exist.
function OutcomeBar.ease(d, s, k)
    d.win_chance = (d.win_chance or 0) + ((s.win_chance or 0) - (d.win_chance or 0)) * k
    for _, side in ipairs(DISTS) do
        local dd, sd = d[side], s[side] or {}
        for _, t in ipairs(WINS) do
            dd[t] = (dd[t] or 0) + ((sd[t] or 0) - (dd[t] or 0)) * k
        end
    end
end

-- The rect of one segment of the bar drawn at (x, w): x, w (for an anchor on
-- the gold stack win, say).
function OutcomeBar.segmentRect(stats, x, w, side, tier)
    local segs = segments(stats, math.floor(x), math.floor(w), _a)
    local s = segs[side] and segs[side][tier]
    if not s then return x, 0 end
    return s[1], s[2]
end

-- A tooltip row (services/Tooltip custom row): a label line above the bar.
function OutcomeBar.row(stats, ghost, w, h)
    return {
        measure = function(_) return w, h end,
        render  = function(x, y, _) OutcomeBar.draw(x, y, w, h, stats, ghost and { ghost = ghost } or nil) end,
    }
end

return OutcomeBar
