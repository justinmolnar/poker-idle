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

local Theme  = require("views.Theme")
local Stakes = require("data.stakes")

local TablePanelStats = {}

-- Layout constants — exported so TablePanel can keep its stats-region
-- bottom-padding allocation in sync with what we render here.
TablePanelStats.EV_READOUT_PAD_BOTTOM = 4   -- gap between readout baseline and panel bottom
TablePanelStats.EV_READOUT_HIT_PAD    = 4   -- hit-rect padding around the text

local DEBUG_TIP_W      = 340
local DEBUG_TIP_PAD    = 8
local DEBUG_TIP_LINE_H = 14

-- ─── Format helpers ──────────────────────────────────────────────────

local function fmtPct(p) return string.format("%5.1f%%", (p or 0) * 100) end
local function fmtBB(b)  return string.format("%5.1f",   b or 0) end
local function fmtEV(n)
    n = n or 0
    if math.abs(n) < 100 then
        return string.format("%+0.3f", n)
    elseif math.abs(n) < 10000 then
        return string.format("%+0.2f", n)
    end
    return string.format("%+0.0f", n)
end

local function findStake(id)
    for _, s in ipairs(Stakes) do
        if s.id == id then return s end
    end
end

-- ─── Pool-breakdown line list (shared by EV tooltip + debug overlay) ──

local function buildEvBreakdownLines(tbl, controller)
    local stats = tbl:debugStats(controller and controller.ctx)
    if not stats then return nil end

    local bb = (stats.stake and stats.stake.bb) or 1
    if bb <= 0 then bb = 1 end

    local lines = {}
    lines[#lines + 1] = string.format("%s · %s   (pool avg)",
        stats.stake.display_name or stats.stake.id or "?",
        stats.gtype.short or stats.gtype.id or "?")
    lines[#lines + 1] = string.format("WC %s   EV $%s  (%s bb/h)",
        fmtPct(stats.pool.win_chance),
        fmtEV(stats.pool.ev_per_hand),
        fmtEV((stats.pool.ev_per_hand or 0) / bb))

    -- Focus penalty — applied multiplicatively to all $ deltas in the
    -- resolution loop. The base EV above is pre-focus; the line below
    -- shows the effective EV the player actually realizes.
    if controller and controller.currentFocusMult then
        local fmult   = controller:currentFocusMult()
        local fcap    = controller:currentFocusCapacity()
        local n_open  = controller.pool and controller.pool:count() or 0
        local eff_ev  = (stats.pool.ev_per_hand or 0) * fmult
        lines[#lines + 1] = string.format(
            "Focus %d / %d cap   x%.2f  ->  eff EV $%s  (%s bb/h)",
            n_open, fcap, fmult, fmtEV(eff_ev), fmtEV(eff_ev / bb))
    end
    lines[#lines + 1] = string.format("WIN  T %s S %s M %s J %s   avg %s bb",
        fmtPct(stats.pool.win_dist.tiny),
        fmtPct(stats.pool.win_dist.small),
        fmtPct(stats.pool.win_dist.medium),
        fmtPct(stats.pool.win_dist.jackpot),
        fmtBB(stats.pool.win_avg_bb))
    lines[#lines + 1] = string.format("LOSS T %s S %s M %s J %s   avg %s bb",
        fmtPct(stats.pool.loss_dist.tiny),
        fmtPct(stats.pool.loss_dist.small),
        fmtPct(stats.pool.loss_dist.medium),
        fmtPct(stats.pool.loss_dist.jackpot),
        fmtBB(stats.pool.loss_avg_bb))

    return lines
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
    local stake = findStake(tbl.stake_id)
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end

    local ev_bb = (stats.ev_per_hand or 0) / bb
    local label = string.format("%+0.1f bb/h", ev_bb)

    local font = fonts.ui_small
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
    local font  = fonts.ui_small
    love.graphics.setFont(font)

    local screen_w, screen_h = love.graphics.getDimensions()
    local tip_h = DEBUG_TIP_PAD * 2 + DEBUG_TIP_LINE_H * #lines
    local tip_x = mx + 16
    local tip_y = my + 8
    if tip_x + DEBUG_TIP_W > screen_w then
        tip_x = mx - DEBUG_TIP_W - 16
    end
    if tip_x < 0 then tip_x = 4 end
    if tip_y + tip_h > screen_h then tip_y = screen_h - tip_h - 4 end
    if tip_y < 0 then tip_y = 4 end

    Theme.setColor(Theme.bg.window, 0.95)
    love.graphics.rectangle("fill", tip_x, tip_y, DEBUG_TIP_W, tip_h, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", tip_x, tip_y, DEBUG_TIP_W, tip_h, Theme.space.radius)

    Theme.setColor(Theme.fg.heading)
    for i, line in ipairs(lines) do
        love.graphics.print(line,
            tip_x + DEBUG_TIP_PAD,
            tip_y + DEBUG_TIP_PAD + (i - 1) * DEBUG_TIP_LINE_H)
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
