-- views/TablePanelStats.lua
--
-- Per-panel stats UI extracted from views/TablePanel: the "+$N.NN/h" EV
-- readout (drawn into the felt layout's bottom-center slot), its hover-tooltip
-- breakdown, and the backtick-toggled debug overlay (game.debug.overlay).
-- Lives in its own module so TablePanel.lua stays focused on panel chrome /
-- cards / chips while the stats-and-debug rendering has a coherent home.
--
-- Public surface used by TablePanel:
--   • TablePanelStats.measureEvReadout(tbl, controller, fonts) -> full_w, money_w
--   • TablePanelStats.drawEvReadout(tbl, ev_slot, controller, fonts, hit_boxes, anchor_key?)
--   • TablePanelStats.stashDebugTooltipIfHover(tbl, panel_x, panel_y, panel_w, panel_h, game, controller)
-- Public surface used by GrindView (deferred-render top-of-stack):
--   • TablePanelStats.flushDebugOverlay(game)

local Theme       = require("views.Theme")
local Format = require("utils.format")
local Stakes      = require("data.stakes")
local KoPayouts  = require("data.ko_payouts")
local Lookups     = require("utils.lookups")
local TierGlyph   = require("views.TierGlyph")
local OutcomeMath = require("models.outcome_math")
local PayoutBreakdown = require("models.payout_breakdown")
local IconText    = require("views.IconText")
local Anchors     = require("services.AnchorRegistry")
local RollingValue = require("services.RollingValue")

-- Canonical tier order (internal keys). Rendered as glyphs via TierGlyph.
local TIER_ORDER  = { "small", "medium", "large", "stack" }

local TablePanelStats = {}

-- Padding around the readout's hover hit-rect.
TablePanelStats.EV_READOUT_HIT_PAD    = 4

local DEBUG_TIP_W      = 340
local DEBUG_TIP_PAD    = 8
local DEBUG_TIP_LINE_H = 14

-- ─── Pool-breakdown line list (shared by EV tooltip + debug overlay) ──

-- Binomial coefficient for small n. Used by the KO expected-payout
-- math (n = 8 hands per session).
local function binomCoeff(n, k)
    if k < 0 or k > n then return 0 end
    if k > n - k then k = n - k end
    local c = 1
    for i = 1, k do
        c = c * (n - i + 1) / i
    end
    return c
end

local function fmtMoney(n)
    n = n or 0
    if math.abs(n) >= 1000 then return Format.money(n) end
    if math.abs(n) >= 100 then return string.format("$%.0f",  n) end
    if math.abs(n) >= 10  then return string.format("$%.1f",  n) end
    return string.format("$%.2f", n)
end

-- Signed compact money: "+$0.07" / "-$1.2". Used by the $/h readouts,
-- where the sign IS the message (winning vs losing table).
local function fmtMoneySigned(n)
    n = n or 0
    return (n < 0 and "-" or "+") .. fmtMoney(math.abs(n))
end

-- Public: the headline per-hand EV label ("+$0.07/h"). Shared by the
-- per-table readout and the stake-add buttons so the two always format
-- identically. bb/h lives in the hover tooltips only.
function TablePanelStats.evLabel(ev_dollars)
    return fmtMoneySigned(ev_dollars) .. "/h"
end

local function fmtPctClean(p)
    local pct = (p or 0) * 100
    -- Sub-1% values keep a decimal so a small-but-real chance (e.g. a 0.3% stack
    -- tier at low upgrade levels) doesn't collapse to a misleading "0%".
    if pct > 0 and pct < 1 then return string.format("%.1f%%", pct) end
    return string.format("%.0f%%", pct)
end

-- Tooltip rows are structured ({ text, style, color_token }) so the
-- shared Tooltip widget can size the takeaway lines bigger than the
-- supporting context. style ∈ "sm" / "md" / "lg".
local function row(text, style, color)
    return { text = text, style = style or "sm", color_token = color }
end

-- Exported (TablePanelStats.iconRow) so other tooltips — the top-bar deck
-- cell's — render {chip} / {w:stack} markers the same way.
local function iconRow(game, str, style, color)
    local fstyle = style or "sm"
    return {
        measure = function(fonts)
            local f = fonts[fstyle] or fonts.sm
            return IconText.measure(str, f), f:getHeight()
        end,
        render  = function(x, y, fonts)
            local f = fonts[fstyle] or fonts.sm
            local c = color and (Theme.semColor(color)
                       or (Theme.status and Theme.status[color])
                       or (Theme.fg and Theme.fg[color])) or Theme.fg.heading
            IconText.draw(game, str, x, y, f, c, 1)
        end,
    }
end

-- Cash-table breakdown: how often you win, what the average win/loss
-- looks like, the expected per-hand $ value, and the focus penalty
-- when applicable. Rebuilt from the same pool stats the EV readout
-- below the panel uses.
local function buildCashOverviewRenderRow(header, bb, ev_dollars, ev_bb, win_chance, win_avg_dollars, win_dist, loss_avg_dollars, loss_dist)
    local present_win = {}
    for _, k in ipairs(TIER_ORDER) do
        local p = (win_dist and win_dist[k]) or 0
        if p >= 0.0005 then present_win[#present_win + 1] = { tier = k, pct = fmtPctClean(p) } end
    end
    local present_loss = {}
    for _, k in ipairs(TIER_ORDER) do
        local p = (loss_dist and loss_dist[k]) or 0
        if p >= 0.0005 then present_loss[#present_loss + 1] = { tier = k, pct = fmtPctClean(p) } end
    end

    local loss_chance = 1.0 - (win_chance or 0)
    local TIER_COUNT = { small = 1, medium = 2, large = 3, stack = 4 }

    local function mixWidth(present, fonts)
        local f_sm = fonts.sm
        local r = TierGlyph.radius(f_sm:getHeight())
        local SEG_GAP = 12
        local w = 0
        for _, seg in ipairs(present) do
            w = w + r * 2 + 3 + f_sm:getWidth(seg.pct) + SEG_GAP
        end
        return w
    end

    local function drawMixRow(x, y, present, outcome, fonts)
        local f_sm = fonts.sm
        local fh = f_sm:getHeight()
        local r = TierGlyph.radius(fh)
        local SEG_GAP = 12
        local step = math.max(1, math.floor(r * 0.55))
        local text_y = y
        local text_center_y = y + math.floor(fh * 0.5)
        local cx = x + r
        love.graphics.setFont(f_sm)
        for _, seg in ipairs(present) do
            local count = TIER_COUNT[seg.tier] or 1
            local baseline = text_center_y + math.floor((count - 1) * step * 0.5)
            TierGlyph.draw(cx, baseline, seg.tier, r, outcome)
            Theme.setColor(TierGlyph.color(seg.tier, outcome))
            love.graphics.print(seg.pct, cx + r + 3, text_y)
            cx = cx + r * 2 + 3 + f_sm:getWidth(seg.pct) + SEG_GAP
        end
    end

    local function calcWidth(fonts)
        local f_md = fonts.md or fonts.sm
        local f_sm = fonts.sm
        local title_w = f_md:getWidth(header) + f_sm:getWidth(string.format("  (1 bb = %s)", fmtMoney(bb)))
        local ev1 = string.format("Expected: %s/hand", fmtMoneySigned(ev_dollars))
        local ev2 = string.format("(%+.1f bb/h)", ev_bb)
        local ev_w = f_md:getWidth(ev1) + f_md:getWidth(ev2) + 8

        local win_hdr = string.format("Win Rate: %s · Avg Win: %s", fmtPctClean(win_chance), fmtMoney(win_avg_dollars))
        local win_w = math.max(f_sm:getWidth(win_hdr), mixWidth(present_win, fonts))

        local loss_hdr = string.format("Loss Rate: %s · Avg Loss: %s", fmtPctClean(loss_chance), fmtMoney(loss_avg_dollars))
        local loss_w = math.max(f_sm:getWidth(loss_hdr), mixWidth(present_loss, fonts))

        return math.max(260, title_w, ev_w, win_w, loss_w)
    end

    local function measure(fonts)
        local f_md = fonts.md or fonts.sm
        local f_sm = fonts.sm
        local fh_md = f_md:getHeight()
        local fh_sm = f_sm:getHeight()

        local win_h = fh_sm + (#present_win > 0 and (fh_sm + 2) or 0)
        local loss_h = fh_sm + (#present_loss > 0 and (fh_sm + 2) or 0)

        local total_h = fh_md + fh_md + 6 + win_h + 8 + loss_h
        local w = calcWidth(fonts)
        return w, total_h
    end

    local function render(x, y, fonts)
        local f_md = fonts.md or fonts.sm
        local f_sm = fonts.sm
        local fh_md = f_md:getHeight()
        local fh_sm = f_sm:getHeight()

        local cy = y

        -- 1. TITLE & BLIND RATE ON SAME LINE (PERFECT BASELINE ALIGNMENT)
        love.graphics.setFont(f_md)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print(header, x, cy)
        local hw = f_md:getWidth(header)

        love.graphics.setFont(f_sm)
        Theme.setColor(Theme.fg.muted)
        local offset_y = math.max(0, math.floor((fh_md - fh_sm) * 0.35))
        love.graphics.print(string.format("  (1 bb = %s)", fmtMoney(bb)), x + hw, cy + offset_y)
        cy = cy + fh_md + 2

        -- 2. EXPECTED EV (HEADLINE RIGHT BELOW TITLE)
        local ev_color_token = (ev_bb > 0.05) and "good"
                            or (ev_bb < -0.05) and "error"
                            or "muted"
        local ev_c = (ev_color_token == "good" and Theme.sem.won)
                  or (ev_color_token == "error" and Theme.sem.lost)
                  or Theme.fg.muted

        love.graphics.setFont(f_md)
        Theme.setColor(ev_c)
        local ev1 = string.format("Expected: %s/hand", fmtMoneySigned(ev_dollars))
        local ev2 = string.format("(%+.1f bb/h)", ev_bb)
        love.graphics.print(ev1, x, cy)
        local ev1_w = f_md:getWidth(ev1)
        Theme.setColor(ev_c, 0.8)
        love.graphics.print(ev2, x + ev1_w + 6, cy)
        cy = cy + fh_md + 6

        -- 3. WIN SECTION (Header on line 1, Chip icons on line 2)
        love.graphics.setFont(f_sm)
        Theme.setColor(Theme.sem.won)
        local win_hdr_str = string.format("Win Rate: %s · Avg Win: %s", fmtPctClean(win_chance), fmtMoney(win_avg_dollars))
        love.graphics.print(win_hdr_str, x, cy)
        cy = cy + fh_sm + 2

        if #present_win > 0 then
            drawMixRow(x, cy, present_win, "win", fonts)
            cy = cy + fh_sm + 2
        end

        cy = cy + 8 -- DISTINCT GAP BETWEEN WIN GROUP AND LOSS GROUP

        -- 4. LOSS SECTION (Header on line 1, Chip icons on line 2)
        love.graphics.setFont(f_sm)
        Theme.setColor(Theme.sem.lost)
        local loss_hdr_str = string.format("Loss Rate: %s · Avg Loss: %s", fmtPctClean(loss_chance), fmtMoney(loss_avg_dollars))
        love.graphics.print(loss_hdr_str, x, cy)
        cy = cy + fh_sm + 2

        if #present_loss > 0 then
            drawMixRow(x, cy, present_loss, "loss", fonts)
            cy = cy + fh_sm + 2
        end
    end

    return { measure = measure, render = render }
end

local function buildCashLines(tbl, controller, stats)
    local bb = (stats.stake and stats.stake.bb) or 1
    if bb <= 0 then bb = 1 end
    local em = (controller and controller.ctx and controller.ctx.earnings_mult) or 1
    local lm = (controller and controller.ctx and controller.ctx.loss_mult)     or 1
    local win_avg_dollars  = stats.pool.win_avg_bb  * bb * em
    local loss_avg_dollars = stats.pool.loss_avg_bb * bb * lm
    local ev_bb = (stats.pool.ev_per_hand or 0) / bb

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        stats.gtype.short        or stats.gtype.id or "?")

    local lines = {
        buildCashOverviewRenderRow(header, bb, stats.pool.ev_per_hand or 0, ev_bb, stats.pool.win_chance or 0, win_avg_dollars, stats.pool.win_dist, loss_avg_dollars, stats.pool.loss_dist)
    }

    if controller and controller.currentFocusMult then
        local fmult = controller:currentFocusMult()
        if fmult < 0.999 then
            local fcap   = controller:currentFocusCapacity()
            local n_open = controller.pool and controller.pool:count() or 0
            local eff_ev = (stats.pool.ev_per_hand or 0) * fmult
            local eff_bb = eff_ev / bb
            lines[#lines + 1] = row("", "xs")
            lines[#lines + 1] = row(string.format(
                "Focus %d/%d ×%.2f → %s/hand  (%+.1f bb/h)",
                n_open, fcap, fmult, fmtMoneySigned(eff_ev), eff_bb),
                "sm", "warn")
        end
    end

    return lines
end

-- Chip-stack tournament breakdown (8-max KO): per-hand win rate, buy-in,
-- expected cash return per run, ROI %, per-hand EV, and finish-position odds.
local function buildKoLines(tbl, controller, stats)
    local p       = stats.pool.win_chance or 0
    local gtype   = stats.gtype
    local stake   = stats.stake
    local n_seats = (gtype.seats or 0) + 1   -- 7 opps + player = 8

    local ctx   = controller and controller.ctx
    local game  = controller and controller.game
    local boost = (ctx and ctx.ko_payout_boost) or 0
    local payouts = KoPayouts[boost] or KoPayouts[0]
    local buy_in  = (stake and stake.buy_in) or 0
    local bb      = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end

    local net_ev    = stats.pool.net_ev_run or 0
    local roi       = stats.pool.roi_pct or 0
    local ev_hand   = stats.pool.ev_per_hand or 0
    local exp_hands = stats.pool.exp_hands or 10
    local pos_probs = stats.pool.pos_probs or {}

    local ev_bb    = ev_hand / bb
    local ev_sign  = (net_ev >= 0 and "+" or "-")
    local ev_color = (net_ev > 0.05 and "good") or (net_ev < -0.05 and "error") or "muted"

    local function iconRow(str, color)
        return {
            measure = function(fonts) local f = fonts.sm; return IconText.measure(str, f), f:getHeight() end,
            render  = function(x, y, fonts)
                IconText.draw(game, str, x, y, fonts.sm, color or Theme.fg.heading, 1)
            end,
        }
    end

    local header = string.format("%s · %s",
        stake.display_name or stake.id or "?",
        gtype.short        or gtype.id or "?")

    local stack_pct = ((stats.pool.win_chance or 0) * ((stats.pool.win_dist and stats.pool.win_dist.stack) or 0)) * 100

    local lines = {
        row(header, "md"),
        row(string.format("Buy-in: %s (%d bb starting stack)", fmtMoney(buy_in), gtype.starting_stack_bb or 10), "sm", "muted"),
        row(string.format("Expected: %s$%.2f / run (%+.1f%% ROI)", ev_sign, math.abs(net_ev), roi), "md", ev_color),
        row(string.format("EV/hand: %s/h (%+.1f bb/h) · Avg Run: %.1f hands", fmtMoneySigned(ev_hand), ev_bb, exp_hands), "sm", "muted"),
        row("", "xs"),
        row(string.format("Per-hand win rate: %s · Stack-win: %.1f%%", fmtPctClean(p), stack_pct)),
        row("Finish position odds & payouts:", "sm", "muted"),
    }

    local function positionName(pos)
        if pos == 1 then return "1st"
        elseif pos == 2 then return "2nd"
        elseif pos == 3 then return "3rd"
        else return string.format("%dth", pos) end
    end

    local bust_prob = 0
    for pos = 1, n_seats do
        local key  = n_seats - pos + 1
        local mult = payouts[key]
        local prob = pos_probs[pos] or 0
        if mult and mult > 0 then
            lines[#lines + 1] = row(string.format("  %s place:  %s  →  %d×  (%s)",
                positionName(pos), fmtPctClean(prob), mult, fmtMoney(mult * buy_in)),
                "sm", pos == 1 and "amber" or nil)
        else
            bust_prob = bust_prob + prob
        end
    end
    if bust_prob > 0 then
        lines[#lines + 1] = row(string.format("  4th–%dth:   %s  →  0×  (Bust)", n_seats, fmtPctClean(bust_prob)), "sm", "muted")
    end

    lines[#lines + 1] = row("", "xs")
    lines[#lines + 1] = iconRow("Winning 1st place also awards the {chip} bounty.", Theme.fg.muted)

    return lines
end

-- Legacy binary tournament breakdown: per-hand win rate + the consecutive-win
-- payout ladder (6/7/8 → 3×/6×/20× × buy-in). The cash breakdown (avg win/loss,
-- bb/h) is meaningless here -- the binary outcome forces delta=0 and the payout
-- is keyed by win streak, not per-hand $ -- so this is its own shape.
local function buildLegacyKoLines(tbl, controller, stats)
    local p       = stats.pool.win_chance or 0
    local gtype   = stats.gtype
    local ctx     = controller and controller.ctx
    local game    = controller and controller.game
    local boost   = (ctx and ctx.ko_payout_boost) or 0
    local payouts = KoPayouts[boost] or KoPayouts[0]
    local buy_in  = (stats.stake and stats.stake.buy_in) or 0
    local cap     = gtype.hand_count or 8

    local thresholds = {}
    for k in pairs(payouts) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds)               -- ascending: 6, 7, 8

    -- Win-streak math: the first loss ends the run, so finishing with exactly K
    -- wins = K in a row then a loss (p^K·(1-p)); a full sweep = p^cap. {chip} is
    -- awarded ONLY on the sweep (the win condition is hands_won>=cap). Net EV is
    -- the probability-weighted cash return minus the buy-in.
    local function finishOdds(k) return (k >= cap) and (p ^ k) or (p ^ k) * (1 - p) end
    local exp_mult = 0
    for _, k in ipairs(thresholds) do exp_mult = exp_mult + finishOdds(k) * (payouts[k] or 0) end
    local net_ev = buy_in * (exp_mult - 1)

    local ev_sign  = (net_ev >= 0 and "+" or "-")
    local ev_color = (net_ev > 0.05 and "good") or (net_ev < -0.05 and "error") or "muted"

    -- IconText render row so {chip} renders as the glyph (icon rule: never the
    -- word). `color` is a concrete RGB (not a token) since it draws directly.
    local function iconRow(str, color)
        return {
            measure = function(fonts) local f = fonts.sm; return IconText.measure(str, f), f:getHeight() end,
            render  = function(x, y, fonts)
                IconText.draw(game, str, x, y, fonts.sm, color or Theme.fg.heading, 1)
            end,
        }
    end

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        gtype.short              or gtype.id       or "?")

    local lines = {
        row(header, "md"),
        row("1 bb = " .. fmtMoney((stats.stake and stats.stake.bb) or 0), "sm", "muted"),
        row(string.format("Expected cash: %s$%.2f per run", ev_sign, math.abs(net_ev)), "md", ev_color),
        row("", "xs"),
        row("Win hands in a row — one loss ends the run.", "sm", "muted"),
        row("Win rate: " .. fmtPctClean(p) .. " per hand"),
        row("Payout · chance to finish there:", "sm", "muted"),
    }
    -- One row per win level: cash payout + the odds of finishing there. The top
    -- rung is amber; the {chip} note below carries the chip detail.
    for _, k in ipairs(thresholds) do
        lines[#lines + 1] = row(
            string.format("%d wins  $%.2f   %s", k, (payouts[k] or 0) * buy_in, fmtPctClean(finishOdds(k))),
            "sm", (k >= cap) and "amber" or nil)
    end
    lines[#lines + 1] = iconRow(string.format(
        "Winning all %d also pays {chip}.", cap), Theme.fg.muted)
    return lines
end

-- ─── "Where does my payout come from" ────────────────────────────────
--
-- Three shapes of the same data (models/payout_breakdown), cycled with
-- the F3 hotkey so they can be compared in place and two of them deleted.
-- game.debug.payout_shape indexes SHAPES; 0 is off.
--
--   grid    — every source × every tier at once. Complete, dense.
--   focused — one tier, chosen by which is worth the most right now,
--             with a marker on any source that behaves differently
--             elsewhere.
--   totals  — per-tier totals only, itemised for a single tier.
--
-- Ratios read as multipliers on EXPECTED DOLLARS FROM THAT TIER, which
-- folds in both the multiplier and the odds of landing there — so a perk
-- that shifts Small wins into Medium shows up, which is the whole point.
local SHAPES = { "grid", "focused", "totals" }
TablePanelStats.PAYOUT_SHAPES = SHAPES

-- Two decimals under 10x, none above: "x212" is more legible than
-- "x212.00" and the precision is meaningless at that size.
-- When ratio is nil (unlocked from 0 baseline), formats the net dollar addition (e.g. +$0.25).
local function fmtRatio(r, dollar_val)
    if r == nil then
        if dollar_val and math.abs(dollar_val) >= 1e-6 then
            local abs_v = math.abs(dollar_val)
            if abs_v >= 1000 then
                return Format.moneySigned(dollar_val)
            elseif abs_v >= 10 then
                return string.format("+$%.0f", dollar_val)
            elseif abs_v >= 1 then
                return string.format("+$%.1f", dollar_val)
            else
                return string.format("+$%.2f", dollar_val)
            end
        end
        return "-"
    end
    if math.abs(r - 1) < 5e-4 then return "-" end
    if r >= 10 or r <= 0.1 then return string.format("x%.0f", r) end
    return string.format("x%.2f", r)
end

local function ratioColor(r)
    if r == nil then return "good" end
    if r > 1.0005 then return "good" end
    if r < 0.9995 then return "error" end
    return "muted"
end

-- Rows that change nothing are noise; a player scanning for "what is
-- making this number big" does not want twenty "-" lines.
local function activeRows(bd)
    local out = {}
    for _, r in ipairs(bd.rows) do
        if r.matters then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.ev_delta > b.ev_delta end)
    return out
end

-- Which tier is currently worth the most expected dollars — the one a
-- single-tier shape should default to.
local function richestTier(bd)
    local best, best_v = bd.tiers[1], -math.huge
    for _, t in ipairs(bd.tiers) do
        local v = (bd.full.win[t] or 0) + (bd.full.loss[t] or 0)
        if v > best_v then best, best_v = t, v end
    end
    return best
end

local function hasWinEffects(r, tiers)
    for _, t in ipairs(tiers) do
        local v = r.win[t]
        if v == nil or math.abs(v - 1) > 5e-4 then return true end
    end
    return false
end

local function hasLossEffects(r, tiers)
    for _, t in ipairs(tiers) do
        local v = r.loss[t]
        if v == nil or math.abs(v - 1) > 5e-4 then return true end
    end
    return false
end

local function buildGridRenderRow(game, bd)
    local win_active = {}
    local loss_active = {}
    for _, r in ipairs(activeRows(bd)) do
        if hasWinEffects(r, bd.tiers) then win_active[#win_active + 1] = r end
        if hasLossEffects(r, bd.tiers) then loss_active[#loss_active + 1] = r end
    end

    local function measure(fonts)
        local f = fonts.sm or fonts.md
        local max_name_w = 90
        for _, r in ipairs(bd.rows) do
            if r.matters then
                local w = f:getWidth(r.name or "")
                if w > max_name_w then max_name_w = w end
            end
        end
        local name_col_w = max_name_w + 14
        local col_w = 46
        local grid_w = name_col_w + #bd.tiers * col_w
        local line_h = f:getHeight() + 4

        local win_count = math.max(1, #win_active)
        local loss_count = math.max(1, #loss_active)
        local total_h = (1 + 1 + win_count + 1) * line_h + 8 + (1 + 1 + loss_count + 1) * line_h + 4
        return grid_w, total_h
    end

    local function render(x, y, fonts)
        local f = fonts.sm or fonts.md
        local fh = f:getHeight()
        local line_h = fh + 4

        local max_name_w = 90
        for _, r in ipairs(bd.rows) do
            if r.matters then
                local w = f:getWidth(r.name or "")
                if w > max_name_w then max_name_w = w end
            end
        end
        local name_col_w = max_name_w + 14
        local col_w = 46
        local grid_w = name_col_w + #bd.tiers * col_w
        local r_glyph = TierGlyph.radius(fh)

        local cy = y

        local function drawSubgrid(title, outcome, rows_list, total_map, title_color)
            love.graphics.setFont(fonts.xs or f)
            Theme.setColor(title_color or Theme.fg.muted)
            love.graphics.print(title, x, cy)
            cy = cy + fh + 2

            local hdr_y = cy
            Theme.setColor(Theme.bg.card or Theme.bg.window, 0.6)
            love.graphics.rectangle("fill", x, hdr_y, grid_w, line_h, 2)

            love.graphics.setFont(f)
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("Source", x + 6, hdr_y + 2)

            for i, tier in ipairs(bd.tiers) do
                local col_right = x + name_col_w + i * col_w - 6
                local cx = col_right - r_glyph
                local baseline_y = hdr_y + line_h - 3
                TierGlyph.draw(cx, baseline_y, tier, r_glyph, outcome)
            end
            cy = cy + line_h

            if #rows_list == 0 then
                Theme.setColor(Theme.fg.muted)
                love.graphics.setFont(f)
                love.graphics.print("  (no active items)", x + 6, cy + 2)
                cy = cy + line_h
            else
                for idx, r in ipairs(rows_list) do
                    if idx % 2 == 1 then
                        Theme.setColor({1, 1, 1}, 0.03)
                        love.graphics.rectangle("fill", x, cy, grid_w, line_h)
                    end

                    love.graphics.setFont(f)
                    local name_color = Theme.fg.heading
                    if r.ev_delta > 0.001 then name_color = Theme.sem.won
                    elseif r.ev_delta < -0.001 then name_color = Theme.sem.lost end
                    Theme.setColor(name_color)
                    love.graphics.print(r.name, x + 6, cy + 2)

                    local val_map   = (outcome == "win") and r.win or r.loss
                    local delta_map = (outcome == "win") and r.win_delta or r.loss_delta
                    for i, tier in ipairs(bd.tiers) do
                        local val  = val_map[tier]
                        local dval = delta_map and delta_map[tier]
                        local str  = fmtRatio(val, dval)
                        local col_right = x + name_col_w + i * col_w - 6
                        local sw   = f:getWidth(str)
                        local c_token = ratioColor(val)
                        local c    = (c_token == "good" and Theme.sem.won)
                                  or (c_token == "error" and Theme.sem.lost)
                                  or Theme.fg.muted
                        Theme.setColor(c)
                        love.graphics.print(str, col_right - sw, cy + 2)
                    end
                    cy = cy + line_h
                end
            end

            Theme.setColor(Theme.border.strong or Theme.fg.muted, 0.5)
            love.graphics.line(x, cy, x + grid_w, cy)

            Theme.setColor(Theme.bg.card or Theme.bg.window, 0.4)
            love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)

            love.graphics.setFont(f)
            Theme.setColor(Theme.fg.heading)
            love.graphics.print("TOTAL", x + 6, cy + 2)

            local total_val = (outcome == "win") and bd.total.win_val or bd.total.loss_val
            for i, tier in ipairs(bd.tiers) do
                local val  = total_map[tier]
                local dval = total_val and total_val[tier]
                local str  = fmtRatio(val, dval)
                local col_right = x + name_col_w + i * col_w - 6
                local sw   = f:getWidth(str)
                Theme.setColor(Theme.fg.heading)
                love.graphics.print(str, col_right - sw, cy + 2)
            end
            cy = cy + line_h + 4
        end

        drawSubgrid("WINS MULTIPLIERS", "win", win_active, bd.total.win, Theme.sem.won)
        cy = cy + 4
        drawSubgrid("LOSSES MULTIPLIERS", "loss", loss_active, bd.total.loss, Theme.sem.lost)
    end

    return { measure = measure, render = render }
end

local function buildFocusedRenderRow(game, bd)
    local tier = richestTier(bd)

    local active_list = {}
    for _, r in ipairs(activeRows(bd)) do
        local win_val = r.win[tier]
        local loss_val = r.loss[tier]
        local win_matters = (win_val == nil or math.abs(win_val - 1) > 5e-4)
        local loss_matters = (loss_val == nil or math.abs(loss_val - 1) > 5e-4)
        if win_matters or loss_matters then
            local win_varies, loss_varies = false, false
            for _, t in ipairs(bd.tiers) do
                local v = r.win[t]
                if (v == nil) ~= (win_val == nil) or (v and win_val and math.abs(v - win_val) > 1e-4) then win_varies = true end
                local lv = r.loss[t]
                if (lv == nil) ~= (loss_val == nil) or (lv and loss_val and math.abs(lv - loss_val) > 1e-4) then loss_varies = true end
            end
            active_list[#active_list + 1] = {
                r = r, win_val = win_val, loss_val = loss_val,
                varies = win_varies or loss_varies
            }
        end
    end

    local function measure(fonts)
        local f = fonts.sm or fonts.md
        local max_name_w = 90
        for _, item in ipairs(active_list) do
            local w = f:getWidth(item.r.name or "")
            if w > max_name_w then max_name_w = w end
        end
        local name_col_w = max_name_w + 14
        local col_w = 54
        local grid_w = name_col_w + 2 * col_w
        local line_h = f:getHeight() + 4

        local total_h = line_h + line_h + math.max(1, #active_list) * line_h + line_h + line_h
        return grid_w, total_h
    end

    local function render(x, y, fonts)
        local f = fonts.sm or fonts.md
        local fh = f:getHeight()
        local line_h = fh + 4

        local max_name_w = 90
        for _, item in ipairs(active_list) do
            local w = f:getWidth(item.r.name or "")
            if w > max_name_w then max_name_w = w end
        end
        local name_col_w = max_name_w + 14
        local col_w = 54
        local grid_w = name_col_w + 2 * col_w
        local r_glyph = TierGlyph.radius(fh)

        local cy = y

        love.graphics.setFont(fonts.xs or f)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("FOCUSED TIER:", x, cy)
        local tw = f:getWidth("FOCUSED TIER: ")
        TierGlyph.draw(x + tw + r_glyph, cy + fh - 2, tier, r_glyph, "win")
        cy = cy + fh + 4

        Theme.setColor(Theme.bg.card or Theme.bg.window, 0.6)
        love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)
        love.graphics.setFont(f)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("Source", x + 6, cy + 2)

        local win_cx = x + name_col_w + 0.5 * col_w
        TierGlyph.draw(win_cx, cy + line_h - 3, tier, r_glyph, "win")

        local loss_cx = x + name_col_w + 1.5 * col_w
        TierGlyph.draw(loss_cx, cy + line_h - 3, tier, r_glyph, "loss")
        cy = cy + line_h

        if #active_list == 0 then
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("  (no active items)", x + 6, cy + 2)
            cy = cy + line_h
        else
            for idx, item in ipairs(active_list) do
                if idx % 2 == 1 then
                    Theme.setColor({1, 1, 1}, 0.03)
                    love.graphics.rectangle("fill", x, cy, grid_w, line_h)
                end

                local name_color = Theme.fg.heading
                if item.r.ev_delta > 0.001 then name_color = Theme.sem.won
                elseif item.r.ev_delta < -0.001 then name_color = Theme.sem.lost end
                Theme.setColor(name_color)
                local name_text = item.r.name .. (item.varies and " *" or "")
                love.graphics.print(name_text, x + 6, cy + 2)

                local str_w = fmtRatio(item.win_val, item.r.win_delta and item.r.win_delta[tier])
                local col1_right = x + name_col_w + col_w - 6
                Theme.setColor(ratioColor(item.win_val) == "good" and Theme.sem.won or Theme.fg.muted)
                love.graphics.print(str_w, col1_right - f:getWidth(str_w), cy + 2)

                local str_l = fmtRatio(item.loss_val, item.r.loss_delta and item.r.loss_delta[tier])
                local col2_right = x + name_col_w + 2 * col_w - 6
                Theme.setColor(ratioColor(item.loss_val) == "error" and Theme.sem.lost)
                love.graphics.print(str_l, col2_right - f:getWidth(str_l), cy + 2)

                cy = cy + line_h
            end
        end

        Theme.setColor(Theme.border.strong or Theme.fg.muted, 0.5)
        love.graphics.line(x, cy, x + grid_w, cy)

        Theme.setColor(Theme.bg.card or Theme.bg.window, 0.4)
        love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print("TOTAL", x + 6, cy + 2)

        local tot_w = fmtRatio(bd.total.win[tier], bd.total.win_val and bd.total.win_val[tier])
        local tot_l = fmtRatio(bd.total.loss[tier], bd.total.loss_val and bd.total.loss_val[tier])
        love.graphics.print(tot_w, x + name_col_w + col_w - 6 - f:getWidth(tot_w), cy + 2)
        love.graphics.print(tot_l, x + name_col_w + 2 * col_w - 6 - f:getWidth(tot_l), cy + 2)
        cy = cy + line_h + 2

        love.graphics.setFont(fonts.xs or f)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("* varies by tier", x + 6, cy)
    end

    return { measure = measure, render = render }
end

local function buildTotalsRenderRow(game, bd)
    local tier = richestTier(bd)
    local active_list = {}
    for _, r in ipairs(activeRows(bd)) do
        local win_val = r.win[tier]
        local loss_val = r.loss[tier]
        if (win_val and math.abs(win_val - 1) > 5e-4) or (loss_val and math.abs(loss_val - 1) > 5e-4) then
            active_list[#active_list + 1] = { r = r, win_val = win_val, loss_val = loss_val }
        end
    end

    local function measure(fonts)
        local f = fonts.sm or fonts.md
        local name_col_w = 110
        local col_w = 46
        local grid_w = name_col_w + #bd.tiers * col_w
        local line_h = f:getHeight() + 4
        local total_h = (1 + 1) * line_h + 8 + line_h + line_h + math.max(1, #active_list) * line_h
        return grid_w, total_h
    end

    local function render(x, y, fonts)
        local f = fonts.sm or fonts.md
        local fh = f:getHeight()
        local line_h = fh + 4
        local name_col_w = 110
        local col_w = 46
        local grid_w = name_col_w + #bd.tiers * col_w
        local r_glyph = TierGlyph.radius(fh)

        local cy = y

        Theme.setColor(Theme.bg.card or Theme.bg.window, 0.5)
        love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)
        Theme.setColor(Theme.sem.won)
        love.graphics.print("WIN TOTALS", x + 6, cy + 2)
        for i, t in ipairs(bd.tiers) do
            local str = fmtRatio(bd.total.win[t], bd.total.win_val and bd.total.win_val[t])
            local rx = x + name_col_w + i * col_w - 6
            love.graphics.print(str, rx - f:getWidth(str), cy + 2)
        end
        cy = cy + line_h + 2

        Theme.setColor(Theme.bg.card or Theme.bg.window, 0.5)
        love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)
        Theme.setColor(Theme.sem.lost)
        love.graphics.print("LOSS TOTALS", x + 6, cy + 2)
        for i, t in ipairs(bd.tiers) do
            local str = fmtRatio(bd.total.loss[t], bd.total.loss_val and bd.total.loss_val[t])
            local rx = x + name_col_w + i * col_w - 6
            love.graphics.print(str, rx - f:getWidth(str), cy + 2)
        end
        cy = cy + line_h + 6

        love.graphics.setFont(fonts.xs or f)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("ITEMISED AT RICHEST TIER:", x, cy)
        local tw = f:getWidth("ITEMISED AT RICHEST TIER: ")
        TierGlyph.draw(x + tw + r_glyph, cy + fh - 2, tier, r_glyph, "win")
        cy = cy + fh + 4

        Theme.setColor(Theme.bg.card or Theme.bg.window, 0.6)
        love.graphics.rectangle("fill", x, cy, grid_w, line_h, 2)
        love.graphics.setFont(f)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print("Source", x + 6, cy + 2)

        local win_col_right = x + name_col_w + col_w - 6
        local win_cx = win_col_right - r_glyph
        TierGlyph.draw(win_cx, cy + line_h - 3, tier, r_glyph, "win")

        local loss_col_right = x + name_col_w + 2 * col_w - 6
        local loss_cx = loss_col_right - r_glyph
        TierGlyph.draw(loss_cx, cy + line_h - 3, tier, r_glyph, "loss")
        cy = cy + line_h

        if #active_list == 0 then
            Theme.setColor(Theme.fg.muted)
            love.graphics.print("  (no active items)", x + 6, cy + 2)
        else
            for idx, item in ipairs(active_list) do
                if idx % 2 == 1 then
                    Theme.setColor({1, 1, 1}, 0.03)
                    love.graphics.rectangle("fill", x, cy, grid_w, line_h)
                end
                Theme.setColor(Theme.fg.heading)
                love.graphics.print(item.r.name, x + 6, cy + 2)

                local str_w = fmtRatio(item.win_val, item.r.win_delta and item.r.win_delta[tier])
                local col1_right = x + name_col_w + col_w - 6
                Theme.setColor(ratioColor(item.win_val) == "good" and Theme.sem.won or Theme.fg.muted)
                love.graphics.print(str_w, col1_right - f:getWidth(str_w), cy + 2)

                local str_l = fmtRatio(item.loss_val, item.r.loss_delta and item.r.loss_delta[tier])
                local col2_right = x + name_col_w + 2 * col_w - 6
                Theme.setColor(ratioColor(item.loss_val) == "error" and Theme.sem.lost)
                love.graphics.print(str_l, col2_right - f:getWidth(str_l), cy + 2)

                cy = cy + line_h
            end
        end
    end

    return { measure = measure, render = render }
end

-- Append the payout breakdown to an existing tooltip line list.
function TablePanelStats.appendPayoutLines(lines, game, controller, stake, gtype)
    local dbg = game and game.debug
    local idx = dbg and dbg.payout_shape
    if not idx or idx < 1 then return lines end
    local shape = SHAPES[idx]
    if not shape then return lines end

    local bd = PayoutBreakdown.cached(game, gtype, stake, {
        focus_mult = controller and controller.currentFocusMult
                     and controller:currentFocusMult() or nil,
        bankroll   = game.state and game.state.bankroll or nil,
    })
    if not bd then return lines end

    lines[#lines + 1] = row("", "xs")
    lines[#lines + 1] = row("MULTIPLIER BREAKDOWN", "sm", "heading")
    if shape == "grid" then
        lines[#lines + 1] = buildGridRenderRow(game, bd)
    elseif shape == "focused" then
        lines[#lines + 1] = buildFocusedRenderRow(game, bd)
    elseif shape == "totals" then
        lines[#lines + 1] = buildTotalsRenderRow(game, bd)
    end
    return lines
end

-- Dispatch stats → tooltip rows (cash vs tournament). The single breakdown
-- path; both the per-table readout and the stake-add buttons go through it.
local function breakdownFromStats(controller, stats)
    if not stats then return nil end
    local gt = stats.gtype
    local lines
    if gt and gt.chip_stack_table then
        lines = buildKoLines(nil, controller, stats)        -- 8-max KO
    elseif gt and gt.hand_count then
        lines = buildLegacyKoLines(nil, controller, stats)  -- legacy binary KO
    else
        lines = buildCashLines(nil, controller, stats)
    end
    -- Every tooltip that explains a table's EV gets the payout breakdown
    -- appended, so the "why" sits with the number it explains. No-ops
    -- unless the F3 shape toggle is on.
    local game = controller and controller.game
    if game and lines then
        TablePanelStats.appendPayoutLines(lines, game, controller, stats.stake, gt)
    end
    return lines
end

local function buildEvBreakdownLines(tbl, controller)
    return breakdownFromStats(controller, tbl:debugStats(controller and controller.ctx))
end

-- Public: EV breakdown rows for a hypothetical (stake, gtype) — lets the
-- stake-add buttons show the exact tooltip you get hovering a live table.
function TablePanelStats.breakdownLinesFor(controller, stake, gtype)
    return breakdownFromStats(controller,
        OutcomeMath.evStats(controller and controller.ctx, gtype, stake))
end

-- Public: the per-hand EV for a (stake, gtype), matching the readout below
-- each table panel. Returns dollars (the headline figure) plus the
-- bb-normalized value, which stays the sign/color threshold so the
-- good/bad cutoff doesn't shift with stake size.
function TablePanelStats.evPerHand(controller, stake, gtype)
    local s = OutcomeMath.evStats(controller and controller.ctx, gtype, stake)
    if not s then return nil end
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end
    local ev = s.pool.ev_per_hand or 0
    return ev, ev / bb
end

-- ─── EV readout ──────────────────────────────────────────────────────
-- "+$0.07/h  {stack-glyph} N%" — EV sign-colored (green / red / muted) with
-- the gold stack glyph marking the stack-win %. bb/h moved to the hover
-- tooltip. Position comes from the felt layout's bottom-center slot
-- (views/FeltLayout → L.bottom.ev); this module no longer measures from
-- the panel border.

-- Shared metric + measurement, so the width FeltLayout reserves and the width
-- drawn here are the same number. Returns a metrics table, or nil when there
-- are no stats yet.
local function evMetrics(tbl, controller, font)
    if not (tbl and tbl.estimateStats) then return nil end
    local stats = tbl:estimateStats(controller and controller.ctx)
    if not stats then return nil end
    local stake = Lookups.findById(Stakes, tbl.stake_id)
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end

    -- Displayed values roll toward their targets (same feel as the
    -- top-bar money) so an upgrade purchase sweeps the readout instead
    -- of snapping it. Color derives from the ROLLED value so the tint
    -- never disagrees with the number on screen.
    local id        = tbl._id or 0
    local ev        = RollingValue.get("table_ev:" .. id,
                                       stats.ev_per_hand or 0)
    local stack_pct = RollingValue.get("table_stackpct:" .. id,
                          ((stats.win_chance or 0)
                           * ((stats.win_dist and stats.win_dist.stack) or 0))
                           * 100)
    local ev_bb       = ev / bb
    local label       = TablePanelStats.evLabel(ev)
    local stack_label = string.format("%.1f%%", stack_pct)

    local state = controller and controller.game and controller.game.state
    local show_loss = state and state.shove_r2_won
    local loss_pct = 0
    local loss_label = ""
    
    local text_h    = font:getHeight()
    local r         = TierGlyph.radius(text_h)
    local gap       = math.floor(text_h * 0.6)
    local glyph_pad = math.floor(text_h * 0.25)
    local bb_w      = font:getWidth(label)
    -- Two widths, because the bottom row sheds the Stack% before it drops the
    -- readout entirely (views/FeltLayout picks; this just measures both).
    local money_w   = bb_w
    local total_w   = bb_w + gap + r * 2 + glyph_pad + font:getWidth(stack_label)

    if show_loss then
        loss_pct = RollingValue.get("table_losspct:" .. id,
                      ((1.0 - (stats.win_chance or 0))
                       * ((stats.loss_dist and stats.loss_dist.stack) or 0))
                       * 100)
        loss_label = string.format("%.1f%%", loss_pct)
        total_w = total_w + gap + r * 2 + glyph_pad + font:getWidth(loss_label)
    end

    local color     = (ev_bb > 0.05 and Theme.sem.won)
                   or (ev_bb < -0.05 and Theme.sem.lost)
                   or Theme.fg.muted

    return {
        label = label, stack_label = stack_label, color = color,
        total_w = total_w, money_w = money_w, text_h = text_h, r = r, gap = gap,
        glyph_pad = glyph_pad, bb_w = bb_w,
        show_loss = show_loss, loss_label = loss_label,
    }
end

-- Pixel widths the readout can occupy: the full form, and the money-only form
-- it sheds to when the bottom row is too narrow to hold both it and the
-- tied-up line. views/FeltLayout picks between them. 0, 0 when there's none.
function TablePanelStats.measureEvReadout(tbl, controller, fonts)
    local m = evMetrics(tbl, controller, fonts.sm)
    if not m then return 0, 0 end
    return m.total_w, m.money_w
end

-- Draw the readout left-anchored at the layout slot `ev = { x, y, w, show }`
-- (TablePanel only calls this when ev.show is true). Pushes the breakdown
-- hover hit_box. `anchor_key` (optional, e.g. "ev:1") registers the drawn
-- rect as a hint-anchor.
function TablePanelStats.drawEvReadout(tbl, ev, controller, fonts, hit_boxes, anchor_key)
    if not ev then return end
    local font = fonts.sm
    local m = evMetrics(tbl, controller, font)
    if not m then return end

    -- `ev.parts` is the layout's shed decision: "money" means the row was too
    -- narrow to hold the Stack% glyph beside the tied-up line, so only the
    -- $/hand survives.
    local money_only = (ev.parts == "money")
    local drawn_w    = money_only and m.money_w or m.total_w

    love.graphics.setFont(font)
    local tx, ty = ev.x, ev.y
    if anchor_key then
        Anchors.set(anchor_key, tx, ty, drawn_w, m.text_h)
    end
    Theme.setColor(m.color)
    love.graphics.print(m.label, tx, ty)

    -- Stack-win chance: gold tier glyph + pct, sharing the EV color. Its
    -- own anchor ("ev:<idx>" -> "stack_pct:<idx>") for the beats about the
    -- gold number alone.
    local sx = tx + m.bb_w + m.gap
    if not money_only then
        TierGlyph.draw(sx + m.r, ty + m.text_h - m.r, "stack", m.r, "win")
        Theme.setColor(m.color)
        love.graphics.print(m.stack_label, sx + m.r * 2 + m.glyph_pad, ty)
        if anchor_key then
            Anchors.set((anchor_key:gsub("^ev:", "stack_pct:")), sx, ty,
                m.r * 2 + m.glyph_pad + font:getWidth(m.stack_label), m.text_h)
        end
    end

    -- Stack-loss chance: purple tier glyph + pct
    if m.show_loss and not money_only then
        local lx = sx + m.r * 2 + m.glyph_pad + font:getWidth(m.stack_label) + m.gap
        -- Corruption's purple on the Stack glyph (the anti-chip is what a Stack
        -- loss pays in Act 3), without patching the tier ramp in place.
        TierGlyph.drawColored(lx + m.r, ty + m.text_h - m.r, "stack", m.r, Theme.sem.corrupt)

        Theme.setColor(Theme.sem.corrupt)
        love.graphics.print(m.loss_label, lx + m.r * 2 + m.glyph_pad, ty)
    end

    if hit_boxes then
        local lines = buildEvBreakdownLines(tbl, controller)
        if lines then
            local pad = TablePanelStats.EV_READOUT_HIT_PAD
            hit_boxes[#hit_boxes + 1] = {
                x = tx - pad, y = ty - pad,
                w = drawn_w + pad * 2, h = m.text_h + pad * 2,
                tooltip = lines,
            }
        end
    end
end

-- ─── Debug tooltip (toggled by `) ────────────────────────────────────
-- Two-step rendering: stash the hovered panel during the panel-render
-- loop, then flush AFTER the whole grid has drawn so the tooltip overlays
-- every panel correctly (no z-order races).

function TablePanelStats.stashDebugTooltipIfHover(tbl, panel_x, panel_y, panel_w, panel_h, game, controller)
    if not tbl then return end
    local dbg = game and game.debug
    if not dbg or not dbg.overlay then return end

    local mx, my = love.mouse.getPosition()
    if mx < panel_x or mx > panel_x + panel_w
        or my < panel_y or my > panel_y + panel_h then
        return
    end
    dbg._tooltip_pending = { tbl = tbl, controller = controller, mx = mx, my = my }
end

local function renderDebugTooltip(tbl, mx, my, game, controller)
    local lines = buildEvBreakdownLines(tbl, controller)
    if not lines then return end

    local fonts = game.fonts
    local default_font = fonts.sm or fonts.md
    local rows = {}
    local max_w  = 0
    local total_h = 0
    for _, line in ipairs(lines) do
        if type(line) == "table" and line.render then
            local w, h = 0, default_font:getHeight()
            if line.measure and fonts then w, h = line.measure(fonts) end
            if w > max_w then max_w = w end
            total_h = total_h + h + 2
            rows[#rows + 1] = { render = line.render, _h = h }
        else
            local text  = (type(line) == "table") and (line.text or "") or tostring(line)
            local style = (type(line) == "table") and line.style or "sm"
            local font  = fonts[style] or default_font
            local w     = font:getWidth(text)
            if w > max_w then max_w = w end
            local h     = font:getHeight()
            total_h = total_h + h + 2
            rows[#rows + 1] = { text = text, font = font, color = (type(line) == "table") and line.color_token or nil, _h = h }
        end
    end

    local screen_w, screen_h = love.graphics.getDimensions()
    local tip_w = max_w + DEBUG_TIP_PAD * 2
    local tip_h = total_h + DEBUG_TIP_PAD * 2
    local tip_x = mx + 16
    local tip_y = my + 8
    if tip_x + tip_w > screen_w then tip_x = mx - tip_w - 16 end
    if tip_x < 0 then tip_x = 4 end
    if tip_y + tip_h > screen_h then tip_y = screen_h - tip_h - 4 end
    if tip_y < 0 then tip_y = 4 end

    Theme.setColor(Theme.bg.window, 0.95)
    love.graphics.rectangle("fill", tip_x, tip_y, tip_w, tip_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", tip_x, tip_y, tip_w, tip_h, Theme.space.radius)

    local cy = tip_y + DEBUG_TIP_PAD
    for _, r in ipairs(rows) do
        if r.render then
            r.render(tip_x + DEBUG_TIP_PAD, cy, fonts)
        else
            love.graphics.setFont(r.font)
            local c = r.color and (Theme.semColor(r.color)
                       or (Theme.status and Theme.status[r.color])
                       or (Theme.fg and Theme.fg[r.color])) or Theme.fg.heading
            Theme.setColor(c)
            love.graphics.print(r.text, tip_x + DEBUG_TIP_PAD, cy)
        end
        cy = cy + (r._h or 0) + 2
    end
end

-- Render the deferred debug tooltip, if any. Call once per frame after
-- the whole panel grid has been drawn.
function TablePanelStats.flushDebugOverlay(game)
    local dbg = game and game.debug
    if not dbg or not dbg.overlay then return end
    local p = dbg._tooltip_pending
    if not p then return end
    dbg._tooltip_pending = nil
    if p.tbl then
        renderDebugTooltip(p.tbl, p.mx, p.my, game, p.controller)
    end
end

TablePanelStats.iconRow = iconRow

return TablePanelStats
