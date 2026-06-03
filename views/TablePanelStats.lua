-- views/TablePanelStats.lua
--
-- Per-panel stats UI extracted from views/TablePanel: the "+N.N bb/h" EV
-- readout (drawn into the felt layout's bottom-center slot), its hover-tooltip
-- breakdown, and the backtick-toggled debug overlay (game.debug.overlay).
-- Lives in its own module so TablePanel.lua stays focused on panel chrome /
-- cards / chips while the stats-and-debug rendering has a coherent home.
--
-- Public surface used by TablePanel:
--   • TablePanelStats.measureEvReadout(tbl, controller, fonts) -> width
--   • TablePanelStats.drawEvReadout(tbl, ev_slot, controller, fonts, hit_boxes)
--   • TablePanelStats.stashDebugTooltipIfHover(tbl, panel_x, panel_y, panel_w, panel_h, game, controller)
-- Public surface used by GrindView (deferred-render top-of-stack):
--   • TablePanelStats.flushDebugOverlay(game)

local Theme       = require("views.Theme")
local Stakes      = require("data.stakes")
local MttPayouts  = require("data.mtt_payouts")
local Lookups     = require("utils.lookups")
local TierGlyph   = require("views.TierGlyph")
local OutcomeMath = require("models.outcome_math")

-- Canonical tier order (internal keys). Rendered as glyphs via TierGlyph.
local TIER_ORDER  = { "small", "medium", "large", "jackpot" }

local TablePanelStats = {}

-- Padding around the readout's hover hit-rect.
TablePanelStats.EV_READOUT_HIT_PAD    = 4

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

    -- Tier mix as shared TierGlyph chip-stacks + percentages, skipping tiers
    -- with ~zero probability so heavily-shifted distributions read tight.
    -- Returns a custom render row the Tooltip widget draws via its
    -- draw-callback support.
    local SEG_GAP = 12
    local function tierMixLine(dist, outcome)
        local present = {}
        for _, k in ipairs(TIER_ORDER) do
            local p = dist[k] or 0
            if p >= 0.0005 then
                present[#present + 1] = { tier = k, pct = fmtPctClean(p) }
            end
        end
        if #present == 0 then return nil end

        local function metrics(fonts)
            local f = fonts.sm
            local r = TierGlyph.radius(f:getHeight())
            return f, r, f:getHeight() + r * 3
        end

        local function measure(fonts)
            local f, r, row_h = metrics(fonts)
            local w = 4
            for _, seg in ipairs(present) do
                w = w + r * 2 + 3 + f:getWidth(seg.pct) + SEG_GAP
            end
            return w, row_h
        end

        local function render(x, y, fonts)
            local f, r, row_h = metrics(fonts)
            local baseline = y + row_h - r
            local text_y   = y + row_h - f:getHeight()
            local cx = x + 4 + r
            love.graphics.setFont(f)
            for _, seg in ipairs(present) do
                TierGlyph.draw(cx, baseline, seg.tier, r, outcome)
                Theme.setColor(TierGlyph.color(seg.tier, outcome))
                love.graphics.print(seg.pct, cx + r + 3, text_y)
                cx = cx + r * 2 + 3 + f:getWidth(seg.pct) + SEG_GAP
            end
        end

        return { render = render, measure = measure }
    end

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        stats.gtype.short        or stats.gtype.id or "?")
    local lines = {
        row(header, "md"),
        row("Win rate: " .. fmtPctClean(stats.pool.win_chance)),
        row(string.format("Avg win:  %s",  fmtMoney(win_avg_dollars))),
    }
    local win_mix = tierMixLine(stats.pool.win_dist, "win")
    if win_mix then lines[#lines + 1] = win_mix end
    lines[#lines + 1] = row(string.format("Avg loss: %s", fmtMoney(loss_avg_dollars)))
    local loss_mix = tierMixLine(stats.pool.loss_dist, "loss")
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

-- Chip-stack tournament breakdown: per-hand win rate, buy-in, and the
-- finish-position pay table keyed by `n_seats - finish_position + 1`
-- (so 1st = 8, 2nd = 7, 3rd = 6). No expected-$ estimate — the
-- per-hand model doesn't translate cleanly to tournament finish-
-- position probability without modeling stack dynamics, which is
-- out of scope for the readout.
local function buildMttLines(tbl, controller, stats)
    local p       = stats.pool.win_chance or 0
    local gtype   = stats.gtype
    local n_seats = (gtype.seats or 0) + 1   -- 7 opps + player = 8

    local ctx   = controller and controller.ctx
    local boost = (ctx and ctx.mtt_payout_boost) or 0
    local payouts = MttPayouts[boost] or MttPayouts[0]
    local buy_in  = (stats.stake and stats.stake.buy_in) or 0

    local header = string.format("%s · %s",
        stats.stake.display_name or stats.stake.id or "?",
        gtype.short              or gtype.id       or "?")

    local lines = {
        row(header, "md"),
        row("Per-hand win rate: " .. fmtPctClean(p)),
        row(string.format("Buy-in: %s (%d bb stack)",
            fmtMoney(buy_in), gtype.starting_stack_bb or 100)),
        row("Pay by finish position:", "sm", "muted"),
    }
    -- Thresholds descending so 1st place reads first. Each key maps to
    -- finish_position = n_seats - key + 1.
    local function positionName(pos)
        if pos == 1 then return "1st"
        elseif pos == 2 then return "2nd"
        elseif pos == 3 then return "3rd"
        else return string.format("%dth", pos) end
    end
    local thresholds = {}
    for k in pairs(payouts) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds, function(a, b) return a > b end)
    for _, k in ipairs(thresholds) do
        local mult = payouts[k] or 0
        local pos  = n_seats - k + 1
        lines[#lines + 1] = row(string.format(
            "  %s  →  %d×  (%s)", positionName(pos), mult, fmtMoney(mult * buy_in)))
    end
    return lines
end

-- Dispatch stats → tooltip rows (cash vs tournament). The single breakdown
-- path; both the per-table readout and the stake-add buttons go through it.
local function breakdownFromStats(controller, stats)
    if not stats then return nil end
    if stats.gtype and stats.gtype.chip_stack_table then
        return buildMttLines(nil, controller, stats)
    end
    return buildCashLines(nil, controller, stats)
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

-- Public: the bb/h figure for a (stake, gtype), matching the readout below
-- each table panel.
function TablePanelStats.evBbPerHand(controller, stake, gtype)
    local s = OutcomeMath.evStats(controller and controller.ctx, gtype, stake)
    if not s then return nil end
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end
    return (s.pool.ev_per_hand or 0) / bb
end

-- ─── EV readout ──────────────────────────────────────────────────────
-- "+1.9 bb/h  {stack-glyph} N%" — EV sign-colored (green / red / muted) with
-- the gold stack glyph marking the stack-win %. Position comes from the felt
-- layout's bottom-center slot (views/FeltLayout → L.bottom.ev); this module
-- no longer measures from the panel border.

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

    local ev_bb       = (stats.ev_per_hand or 0) / bb
    local stack_p     = (stats.win_chance or 0)
                        * ((stats.win_dist and stats.win_dist.jackpot) or 0)
    local label       = string.format("%+0.1f bb/h", ev_bb)
    local stack_label = string.format("%.1f%%", stack_p * 100)

    local text_h    = font:getHeight()
    local r         = TierGlyph.radius(text_h)
    local gap       = math.floor(text_h * 0.6)
    local glyph_pad = math.floor(text_h * 0.25)
    local bb_w      = font:getWidth(label)
    local total_w   = bb_w + gap + r * 2 + glyph_pad + font:getWidth(stack_label)
    local color     = (ev_bb > 0.05 and Theme.status.good)
                   or (ev_bb < -0.05 and Theme.status.error)
                   or Theme.fg.muted

    return {
        label = label, stack_label = stack_label, color = color,
        total_w = total_w, text_h = text_h, r = r, gap = gap,
        glyph_pad = glyph_pad, bb_w = bb_w,
    }
end

-- Pixel width the readout will occupy — so FeltLayout can decide whether it
-- fits the gap between the chip pile and the YOU label. 0 when there's none.
function TablePanelStats.measureEvReadout(tbl, controller, fonts)
    local m = evMetrics(tbl, controller, fonts.sm)
    return m and m.total_w or 0
end

-- Draw the readout left-anchored at the layout slot `ev = { x, y, w, show }`
-- (TablePanel only calls this when ev.show is true). Pushes the breakdown
-- hover hit_box.
function TablePanelStats.drawEvReadout(tbl, ev, controller, fonts, hit_boxes)
    if not ev then return end
    local font = fonts.sm
    local m = evMetrics(tbl, controller, font)
    if not m then return end

    love.graphics.setFont(font)
    local tx, ty = ev.x, ev.y
    Theme.setColor(m.color)
    love.graphics.print(m.label, tx, ty)

    -- Stack-win chance: gold tier glyph + pct, sharing the EV color.
    local sx = tx + m.bb_w + m.gap
    TierGlyph.draw(sx + m.r, ty + m.text_h - m.r, "jackpot", m.r, "win")
    Theme.setColor(m.color)
    love.graphics.print(m.stack_label, sx + m.r * 2 + m.glyph_pad, ty)

    if hit_boxes then
        local lines = buildEvBreakdownLines(tbl, controller)
        if lines then
            local pad = TablePanelStats.EV_READOUT_HIT_PAD
            hit_boxes[#hit_boxes + 1] = {
                x = tx - pad, y = ty - pad,
                w = m.total_w + pad * 2, h = m.text_h + pad * 2,
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
