-- views/TablePanelStats.lua
--
-- Per-panel stats UI extracted from views/TablePanel: the bottom-of-panel
-- "+N.N bb/h" EV readout, its hover-tooltip breakdown, and the backtick-
-- toggled debug overlay (game.debug.overlay). Lives in its own module so
-- TablePanel.lua stays focused on panel chrome / cards / chips while the
-- stats-and-debug rendering has a coherent home.
--
-- Public surface used by TablePanel:
--   • TablePanelStats.drawEvReadout(tbl, x, y, w, h_panel, controller, fonts, hit_boxes)
--   • TablePanelStats.stashDebugTooltipIfHover(tbl, panel_x, panel_y, panel_w, panel_h, game, controller)
-- Public surface used by GrindView (deferred-render top-of-stack):
--   • TablePanelStats.flushDebugOverlay(game)

local Theme       = require("views.Theme")
local Stakes      = require("data.stakes")
local MttPayouts  = require("data.mtt_payouts")
local Lookups     = require("utils.lookups")

-- Player-facing display letters for the four outcome tiers. The keys
-- are the same `small / medium / large / jackpot` strings every other
-- module uses — these letters are just the compact label the EV
-- tooltip + catalog item text print.
local TIER_LABELS = { small = "S", medium = "M", large = "L", jackpot = "J" }
local TIER_ORDER  = { "small", "medium", "large", "jackpot" }

local TablePanelStats = {}

-- Layout constants — exported so TablePanel can keep its stats-region
-- bottom-padding allocation in sync with what we render here.
TablePanelStats.EV_READOUT_PAD_BOTTOM = 4   -- gap between readout baseline and panel bottom
TablePanelStats.EV_READOUT_HIT_PAD    = 4   -- hit-rect padding around the text

local DEBUG_TIP_W      = 340
local DEBUG_TIP_PAD    = 8
local DEBUG_TIP_LINE_H = 14

-- ─── Pool-breakdown line list (shared by EV tooltip + debug overlay) ──

-- Binomial coefficient for small n. Used by the MTT expected-payout
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
    if math.abs(n) >= 100 then return string.format("$%.0f",  n) end
    if math.abs(n) >= 10  then return string.format("$%.1f",  n) end
    return string.format("$%.2f", n)
end

local function fmtPctClean(p)
    return string.format("%.0f%%", (p or 0) * 100)
end

-- Tooltip rows are structured ({ text, style, color_token }) so the
-- shared Tooltip widget can size the takeaway lines bigger than the
-- supporting context. style ∈ "sm" / "md" / "lg".
local function row(text, style, color)
    return { text = text, style = style or "sm", color_token = color }
end

-- Cash-table breakdown: how often you win, what the average win/loss
-- looks like, the expected per-hand $ value, and the focus penalty
-- when applicable. Rebuilt from the same pool stats the EV readout
-- below the panel uses.
local function buildCashLines(tbl, controller, stats)
    local bb = (stats.stake and stats.stake.bb) or 1
    if bb <= 0 then bb = 1 end
    local em = (controller and controller.ctx and controller.ctx.earnings_mult) or 1
    local lm = (controller and controller.ctx and controller.ctx.loss_mult)     or 1
    local win_avg_dollars  = stats.pool.win_avg_bb  * bb * em
    local loss_avg_dollars = stats.pool.loss_avg_bb * bb * lm
    local ev_bb = (stats.pool.ev_per_hand or 0) / bb

    -- One-line tier mix: "  S 40%  M 36%  L 22%  J 2%". Tiers with
    -- effectively zero probability are skipped so low stakes /
    -- heavily-shifted distributions read tight.
    local function tierMixLine(dist)
        local parts = {}
        for _, k in ipairs(TIER_ORDER) do
            local p = dist[k] or 0
            if p >= 0.0005 then
                parts[#parts + 1] = string.format("%s %s",
                    TIER_LABELS[k] or k, fmtPctClean(p))
            end
        end
        if #parts == 0 then return nil end
        return row("  " .. table.concat(parts, "  "), "sm")
    end

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        stats.gtype.short        or stats.gtype.id or "?")
    local lines = {
        row(header, "md"),
        row("Win rate: " .. fmtPctClean(stats.pool.win_chance)),
        row(string.format("Avg win:  %s",  fmtMoney(win_avg_dollars))),
    }
    local win_mix = tierMixLine(stats.pool.win_dist)
    if win_mix then lines[#lines + 1] = win_mix end
    lines[#lines + 1] = row(string.format("Avg loss: %s", fmtMoney(loss_avg_dollars)))
    local loss_mix = tierMixLine(stats.pool.loss_dist)
    if loss_mix then lines[#lines + 1] = loss_mix end

    -- Headline EV. Bigger font + status color so it lands as the
    -- takeaway line. Sign decides the color.
    local ev_color = (ev_bb > 0.05) and "good"
                  or (ev_bb < -0.05) and "error"
                  or "muted"
    lines[#lines + 1] = row(string.format("Expected: %s/hand  (%+.1f bb/h)",
        fmtMoney(stats.pool.ev_per_hand or 0), ev_bb), "md", ev_color)

    -- Focus only matters when the player's over capacity. Hide the
    -- line when fmult == 1 (no penalty) — saves a noisy row at low
    -- table counts.
    if controller and controller.currentFocusMult then
        local fmult = controller:currentFocusMult()
        if fmult < 0.999 then
            local fcap   = controller:currentFocusCapacity()
            local n_open = controller.pool and controller.pool:count() or 0
            local eff_ev = (stats.pool.ev_per_hand or 0) * fmult
            local eff_bb = eff_ev / bb
            lines[#lines + 1] = row(string.format(
                "Focus %d/%d ×%.2f → %s/hand  (%+.1f bb/h)",
                n_open, fcap, fmult, fmtMoney(eff_ev), eff_bb),
                "sm", "warn")
        end
    end

    return lines
end

-- MTT breakdown: per-hand win rate, expected wins out of N, the pay
-- ladder for the boost tier the player has unlocked, and the
-- expected $ per session computed via binomial CDF over wins.
local function buildMttLines(tbl, controller, stats)
    local p     = stats.pool.win_chance or 0
    local gtype = stats.gtype
    local n     = gtype.hand_count or 8

    local ctx   = controller and controller.ctx
    local boost = (ctx and ctx.mtt_payout_boost) or 0
    local payouts = MttPayouts[boost] or MttPayouts[0]
    local buy_in  = (stats.stake and stats.stake.buy_in) or 0

    -- Expected payout: sum over k of P(exactly k wins) × payout[k].
    -- Sessions where wins < 6 cash zero, which the payouts table
    -- represents by absent keys.
    local e_payout = 0
    for k = 0, n do
        local mult = payouts[k] or 0
        if mult > 0 then
            local prob = binomCoeff(n, k) * (p ^ k) * ((1 - p) ^ (n - k))
            e_payout = e_payout + prob * mult * buy_in
        end
    end
    local net = e_payout - buy_in
    local net_color = (net > 0) and "good" or (net < 0) and "error" or "muted"

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        gtype.short              or gtype.id       or "?")

    local lines = {
        row(header, "md"),
        row("Per-hand win rate: " .. fmtPctClean(p)),
        row(string.format("Expected wins: %.1f / %d", p * n, n)),
        row("Pay table:", "sm", "muted"),
    }
    -- Threshold rows in ascending order so the player reads
    -- "what do I need to clear" → "what does the top spot pay".
    local thresholds = {}
    for k in pairs(payouts) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds)
    for _, k in ipairs(thresholds) do
        local mult = payouts[k] or 0
        lines[#lines + 1] = row(string.format(
            "  %d wins  →  %d×  (%s)", k, mult, fmtMoney(mult * buy_in)))
    end
    lines[#lines + 1] = row(string.format("Expected: %s / run  (net %s)",
        fmtMoney(e_payout), fmtMoney(net)), "md", net_color)
    return lines
end

local function buildEvBreakdownLines(tbl, controller)
    local stats = tbl:debugStats(controller and controller.ctx)
    if not stats then return nil end
    local gtype = stats.gtype
    if gtype and gtype.binary_outcome then
        return buildMttLines(tbl, controller, stats)
    end
    return buildCashLines(tbl, controller, stats)
end

-- ─── EV readout (always visible) ─────────────────────────────────────

-- Bottom-of-panel "+1.9 bb/h" readout. Color-coded by sign (green positive
-- / red negative / muted near zero). Pushes a hit_box carrying the full
-- pool breakdown so the global Tooltip service surfaces it on hover.
function TablePanelStats.drawEvReadout(tbl, x, y, w, h_panel, controller, fonts, hit_boxes)
    if not tbl then return end
    local ctx = controller and controller.ctx
    local stats = tbl:estimateStats(ctx)
    if not stats then return end
    local stake = Lookups.findById(Stakes,tbl.stake_id)
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end

    local ev_bb = (stats.ev_per_hand or 0) / bb
    local label = string.format("%+0.1f bb/h", ev_bb)

    local font = fonts.sm
    love.graphics.setFont(font)
    local text_w = font:getWidth(label)
    local text_h = font:getHeight()
    local tx = x + math.floor((w - text_w) / 2)
    local ty = y + h_panel - text_h - TablePanelStats.EV_READOUT_PAD_BOTTOM

    local color
    if ev_bb > 0.05 then
        color = Theme.status.good
    elseif ev_bb < -0.05 then
        color = Theme.status.error
    else
        color = Theme.fg.muted
    end
    Theme.setColor(color)
    love.graphics.print(label, tx, ty)

    if hit_boxes then
        local lines = buildEvBreakdownLines(tbl, controller)
        if lines then
            hit_boxes[#hit_boxes + 1] = {
                x = tx - TablePanelStats.EV_READOUT_HIT_PAD,
                y = ty - TablePanelStats.EV_READOUT_HIT_PAD,
                w = text_w + TablePanelStats.EV_READOUT_HIT_PAD * 2,
                h = text_h + TablePanelStats.EV_READOUT_HIT_PAD * 2,
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
    -- Resolve each row to a concrete font + measure widest. Lines may
    -- be either plain strings (legacy) or { text, style } tables, so
    -- match the same shape Tooltip.draw uses.
    local rows = {}
    local max_w  = 0
    local total_h = 0
    for _, line in ipairs(lines) do
        local text  = (type(line) == "table") and (line.text or "") or tostring(line)
        local style = (type(line) == "table") and line.style or "sm"
        local font  = fonts[style] or fonts.sm
        local w     = font:getWidth(text)
        if w > max_w then max_w = w end
        total_h = total_h + font:getHeight() + 2
        rows[#rows + 1] = { text = text, font = font }
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

    Theme.setColor(Theme.fg.heading)
    local cy = tip_y + DEBUG_TIP_PAD
    for _, r in ipairs(rows) do
        love.graphics.setFont(r.font)
        love.graphics.print(r.text, tip_x + DEBUG_TIP_PAD, cy)
        cy = cy + r.font:getHeight() + 2
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

return TablePanelStats
