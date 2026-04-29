-- views/TablePanel.lua
--
-- Renders one mini 6-max poker table inside a layout cell. Stateless module
-- (not a class) — call sites pass the Table model + cell rect + a hit_boxes
-- accumulator each frame.
--
-- Visual layout in a (w × h) cell, w ≈ 340, h ≈ 205:
--   • header strip (22 px) — stake display name + [x] remove button
--   • felt area  — green rounded rect filling the rest of the cell
--       └ top row: 5 opponent boxes (name / 2 mini face-down cards / stack)
--       └ middle:  pot label + 5 community card slots
--       └ bottom:  2 player hole cards centered + "YOU" + bankroll-style stack label
--   • DEAL button overlay (when state == idle) covering the felt center
--   • [STAKE↑ <next>] button overlay (when next stake is unlocked + affordable)
--
-- The community / hole card visibility tracks the per-hand state machine
-- in models/Table — flop shows 3, turn 4, river+ 5; opponent's hole flips
-- face-up only on showdown and settling.

local Theme       = require("views.Theme")
local Constants   = require("data.constants")
local Stakes      = require("data.stakes")
local OpTypes     = require("data.opponent_types")

local TablePanel = {}

-- Layout constants — relative to a panel's (x, y) origin.
local HEADER_H        = 24
local FELT_INSET      = 6
local REMOVE_BTN_SIZE = 18
local STAKE_UP_H      = 22
local STAKE_UP_PAD    = 6
local DEAL_BTN_W      = 140
local DEAL_BTN_H      = 40

-- EV gauge — thin colored strip at the bottom of every panel. Maps the
-- table's EV-per-hand (in bb units) to a 0..1 marker position on a
-- red→amber→green gradient. Replaces the old hover tooltip; always on,
-- one per table, at-a-glance "which of my tables is bleeding right now."
local GAUGE_H        = 6
local GAUGE_PAD      = 3   -- gap between gauge and panel bottom
local GAUGE_MARKER_W = 2
local GAUGE_LERP     = 6.0 -- lerp speed; ~1/3 sec to close most of the gap
local GAUGE_EV_SPAN  = 2.0 -- bb/hand mapped to gauge edges (±2 bb)

-- Card sizes for the cramped grid panel.
local OPP_CARD_W      = 14
local OPP_CARD_H      = 20
local COMM_CARD_W     = 28
local COMM_CARD_H     = 38
local PLAYER_CARD_W   = 36
local PLAYER_CARD_H   = 50

-- Opponent count comes from the table's game type now (`#tbl.opponents`).

-- ─── Helpers ──────────────────────────────────────────────────────────

local function findStake(id)
    for _, s in ipairs(Stakes) do
        if s.id == id then return s end
    end
end

-- Returns (next_stake, diff_cost, affordable). next_stake is nil if there
-- is no next tier. The only gate is the buy-in difference — having 100bb
-- of the new stake's bb is the entry. The button is rendered (greyed)
-- when not affordable so the player can see what's coming up next.
local function nextStakeInfo(current_id, bankroll)
    local current
    local found = false
    for _, s in ipairs(Stakes) do
        if found then
            local diff = (s.buy_in or 0) - ((current and current.buy_in) or 0)
            local affordable = bankroll >= diff
            return s, diff, affordable
        end
        if s.id == current_id then found = true; current = s end
    end
    return nil
end

local function communityCardCount(state)
    if state == "idle" or state == "dealing" then return 0 end
    if state == "flop"     then return 3 end
    if state == "turn"     then return 4 end
    return 5  -- river / showdown / settling
end

local function holeVisible(state) return state ~= "idle" end
local function opponentFaceUp(state)
    return state == "showdown" or state == "settling"
end

-- Lookup back sprite name once (avoids constants reach in render loop).
local CARD_BACK = Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE
                  or "cards/backs/03-fish"

local function moneyText(n)
    if math.abs(n or 0) < 1000 then
        return string.format("$%.2f", n or 0)
    end
    return string.format("$%.0f", n or 0)
end

-- ─── Card rendering ──────────────────────────────────────────────────

local function drawCardBack(sl, x, y, w, h, alpha)
    if sl and sl.drawSprite then
        sl:drawSprite(CARD_BACK, x, y, w, h, { 1, 1, 1, alpha or 1 })
    else
        Theme.setColor(Theme.bg.sunken, alpha or 1)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
        Theme.setColor(Theme.border.default, alpha or 1)
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    end
end

local function drawCardFront(sl, card, x, y, w, h, alpha)
    if not card then return end
    if sl and sl.drawSprite then
        sl:drawSprite(card:spriteName(), x, y, w, h, { 1, 1, 1, alpha or 1 })
    else
        Theme.setColor(Theme.bg.widget_hover, alpha or 1)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    end
end

-- Empty slot placeholder (for community cards not yet dealt).
local function drawCardSlot(x, y, w, h)
    Theme.setColor(Theme.bg.sunken, 0.5)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.soft, 0.6)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
end

-- ─── Sub-panels ──────────────────────────────────────────────────────

local function drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove, cursor_on)
    local stats = tbl:liveStats() or {}
    local header_text = stats.stake_display or "?"
    if stats.game_type_short and stats.game_type_short ~= "" then
        header_text = header_text .. " · " .. stats.game_type_short
    end
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", x, y, w, HEADER_H, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, HEADER_H, Theme.space.radius)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(header_text, x + 8, y + 5)

    -- [x] remove (right edge).
    local rb_x = x + w - REMOVE_BTN_SIZE - 4
    local rb_y = y + 3
    Theme.setColor(can_remove and Theme.bg.widget_hover or Theme.bg.sunken, 0.6)
    love.graphics.rectangle("fill", rb_x, rb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, Theme.space.radius)
    Theme.setColor(can_remove and Theme.border.strong or Theme.border.soft)
    love.graphics.rectangle("line", rb_x, rb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, Theme.space.radius)
    Theme.setColor(can_remove and Theme.fg.heading or Theme.fg.disabled)
    love.graphics.printf("x", rb_x, rb_y + 3, REMOVE_BTN_SIZE, "center")
    if can_remove then
        hit_boxes[#hit_boxes + 1] = {
            x = rb_x, y = rb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "remove_table", idx = idx,
        }
    end

    -- Cursor mute toggle "C" — only shown once the cursor system is unlocked.
    -- Filled when active (cursors target this table); dimmed when muted.
    local hands_right_offset = REMOVE_BTN_SIZE + 4 + 4
    if cursor_on then
        local cb_x = rb_x - REMOVE_BTN_SIZE - 4
        local cb_y = y + 3
        local muted = tbl.cursor_muted == true
        Theme.setColor(muted and Theme.bg.sunken or Theme.bg.widget_hover, 0.6)
        love.graphics.rectangle("fill", cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, Theme.space.radius)
        Theme.setColor(muted and Theme.border.soft or Theme.border.strong)
        love.graphics.rectangle("line", cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, Theme.space.radius)
        Theme.setColor(muted and Theme.fg.disabled or Theme.fg.heading)
        love.graphics.printf("C", cb_x, cb_y + 3, REMOVE_BTN_SIZE, "center")
        if muted then
            -- strike-through: a horizontal line across the badge
            love.graphics.setLineWidth(1)
            Theme.setColor(Theme.fg.disabled)
            love.graphics.line(cb_x + 3, cb_y + REMOVE_BTN_SIZE / 2,
                               cb_x + REMOVE_BTN_SIZE - 3, cb_y + REMOVE_BTN_SIZE / 2)
        end
        hit_boxes[#hit_boxes + 1] = {
            x = cb_x, y = cb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "toggle_cursor", idx = idx,
        }
        hands_right_offset = hands_right_offset + REMOVE_BTN_SIZE + 4
    end

    -- Hands played (right-aligned, shifted past [x] and the cursor badge).
    Theme.setColor(Theme.fg.muted)
    local hands = string.format("%d hands", tbl.hands_played or 0)
    local hw = fonts.ui_small:getWidth(hands)
    love.graphics.print(hands, x + w - hw - hands_right_offset, y + 5)
end

local function drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts)
    if not opp then return end

    -- Name (always shown).
    Theme.setColor(Theme.fg.primary, 0.85)
    love.graphics.setFont(fonts.ui_small)
    local name = opp.name or "?"
    if #name > 8 then name = name:sub(1, 7) .. "…" end
    love.graphics.printf(name, x, y, w, "center")

    -- Tag line — reveals accumulate at showdown. Each hand against an
    -- opponent has a 50% chance to flip ONE unrevealed attribute. Until
    -- revealed, the slot reads "?". The line is hidden entirely if
    -- nothing's revealed yet — keeps fresh seats clean.
    if opp.revealed_skill or opp.revealed_style then
        local skill_data = OpTypes.skills[opp.skill]     or {}
        local style_data = OpTypes.playstyles[opp.style] or {}
        local sk = opp.revealed_skill and (skill_data.short or "?") or "?"
        local st = opp.revealed_style and (style_data.name  or "?") or "?"
        Theme.setColor(Theme.fg.muted, 0.85)
        love.graphics.printf(sk .. " · " .. st, x, y + 11, w, "center")
    end

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
    -- Pushed down to make room for the tag line above.
    local cards_y  = y + 22
    local card_gap = 3
    local cards_w  = OPP_CARD_W * 2 + card_gap
    local cards_x  = x + math.floor((w - cards_w) / 2)
    local face_up  = opponentFaceUp(tbl.state) and tbl.opponent_idx == opp_idx
    if face_up and tbl.opponent_hole then
        drawCardFront(sl, tbl.opponent_hole[1], cards_x, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
        drawCardFront(sl, tbl.opponent_hole[2], cards_x + OPP_CARD_W + card_gap, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
    elseif holeVisible(tbl.state) then
        drawCardBack(sl, cards_x, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
        drawCardBack(sl, cards_x + OPP_CARD_W + card_gap, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
    end
    -- Opponent stacks were rendered here previously — dropped to make
    -- room for the reveal tag line above. Stacks weren't load-bearing
    -- info at multi-tabling scale; the felt's pot label is what matters.
end

local function drawCommunity(tbl, felt_x, row_y, felt_w, sl, card_w, card_h)
    card_w = card_w or COMM_CARD_W
    card_h = card_h or COMM_CARD_H
    local count = communityCardCount(tbl.state)
    local total_w = card_w * 5 + 4 * 4
    local row_x = felt_x + math.floor((felt_w - total_w) / 2)

    for i = 1, 5 do
        local cx = row_x + (i - 1) * (card_w + 4)
        if i <= count and tbl.community and tbl.community[i] then
            drawCardFront(sl, tbl.community[i], cx, row_y, card_w, card_h, 1)
        else
            drawCardSlot(cx, row_y, card_w, card_h)
        end
    end
end

local function drawPotLabel(tbl, felt_x, label_y, felt_w, fonts)
    if tbl.state == "idle" then return end
    -- Pot = total chips in the middle = your contribution + opponent's
    -- contribution. Outcome model is symmetric: win/lose magnitudes match,
    -- so 2 × |delta| is the right total-pot reading both ways.
    local pot = (tbl.outcome_delta and math.abs(tbl.outcome_delta) * 2) or 0
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf("Pot: " .. moneyText(pot), felt_x, label_y, felt_w, "center")
end

local function drawPlayerSeat(tbl, x, y, w, sl, fonts)
    -- Hole cards centered.
    local cards_w = PLAYER_CARD_W * 2 + 4
    local cards_x = x + math.floor((w - cards_w) / 2)
    local cards_y = y

    if holeVisible(tbl.state) and tbl.player_hole then
        drawCardFront(sl, tbl.player_hole[1], cards_x, cards_y, PLAYER_CARD_W, PLAYER_CARD_H, 1)
        drawCardFront(sl, tbl.player_hole[2], cards_x + PLAYER_CARD_W + 4, cards_y, PLAYER_CARD_W, PLAYER_CARD_H, 1)
    else
        drawCardSlot(cards_x, cards_y, PLAYER_CARD_W, PLAYER_CARD_H)
        drawCardSlot(cards_x + PLAYER_CARD_W + 4, cards_y, PLAYER_CARD_W, PLAYER_CARD_H, 1)
    end

    -- Label below cards: YOU + this table's stack (the chips at *this*
    -- felt). Wins/losses move the stack; cashing out refunds it. Bankroll
    -- is the off-table reading on the top bar.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf("YOU  " .. moneyText(tbl.stack or 0),
        x, cards_y + PLAYER_CARD_H + 2, w, "center")
end

-- Shared felt-overlay button (DEAL when stacked, REBUY $X when busted).
-- The variant is decided in :draw based on tbl.stack; this just renders.
local function drawFeltButton(x, y, w, h, fonts, hit_boxes, idx, label, action, fill_color, enabled)
    local btn_w = math.min(DEAL_BTN_W, w - 16)
    local btn_h = math.min(DEAL_BTN_H, h - 8)
    if btn_w < 40 then btn_w = math.max(20, w - 4) end
    if btn_h < 18 then btn_h = math.max(14, h - 4) end
    local bx = x + math.floor((w - btn_w) / 2)
    local by = y + math.floor((h - btn_h) / 2)
    Theme.setColor(enabled and fill_color or Theme.bg.sunken, enabled and 0.85 or 0.5)
    love.graphics.rectangle("fill", bx, by, btn_w, btn_h, Theme.space.radius)
    Theme.setColor(enabled and Theme.fg.heading or Theme.border.soft, 0.95)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", bx, by, btn_w, btn_h, Theme.space.radius)
    love.graphics.setLineWidth(1)
    Theme.setColor(enabled and Theme.bg.window or Theme.fg.disabled)
    local font = (btn_h >= 28) and fonts.heading or fonts.ui_small
    love.graphics.setFont(font)
    local text_y = by + math.floor((btn_h - font:getHeight()) / 2)
    love.graphics.printf(label, bx, text_y, btn_w, "center")
    if enabled then
        hit_boxes[#hit_boxes + 1] = {
            x = bx, y = by, w = btn_w, h = btn_h,
            action = action, idx = idx,
        }
    end
end

local function drawStakeUp(felt_x, felt_y, felt_w, felt_h, fonts, hit_boxes, idx, next_stake, diff, affordable)
    if not next_stake then return end
    local bw = felt_w - 2 * STAKE_UP_PAD
    local bx = felt_x + STAKE_UP_PAD
    local by = felt_y + felt_h - STAKE_UP_H - STAKE_UP_PAD
    Theme.setColor(affordable and Theme.bg.widget_hover or Theme.bg.sunken, 0.85)
    love.graphics.rectangle("fill", bx, by, bw, STAKE_UP_H, Theme.space.radius)
    Theme.setColor(affordable and Theme.border.strong or Theme.border.soft)
    love.graphics.rectangle("line", bx, by, bw, STAKE_UP_H, Theme.space.radius)
    Theme.setColor(affordable and Theme.fg.heading or Theme.fg.disabled)
    love.graphics.setFont(fonts.ui_small)
    local label = string.format("UP -> %s  (+$%.2f)", next_stake.display_name, diff or 0)
    love.graphics.printf(label, bx, by + 4, bw, "center")
    if affordable then
        hit_boxes[#hit_boxes + 1] = {
            x = bx, y = by, w = bw, h = STAKE_UP_H,
            action = "stake_up", idx = idx, next_stake_id = next_stake.id,
        }
    end
end

-- ─── EV gauge ─────────────────────────────────────────────────────────

-- Map ev_per_hand (in $) → 0..1 marker position. ev_bb = ev / stake.bb.
-- Linear, clamped: ev_bb ≤ -GAUGE_EV_SPAN → 0, +GAUGE_EV_SPAN → 1.
local function evToGaugePos(stake, ev_per_hand)
    local bb = (stake and stake.bb) or 1
    if bb <= 0 then bb = 1 end
    local ev_bb = (ev_per_hand or 0) / bb
    local pos = (ev_bb + GAUGE_EV_SPAN) / (2 * GAUGE_EV_SPAN)
    if pos < 0 then return 0 end
    if pos > 1 then return 1 end
    return pos
end

local function drawGauge(tbl, x, y, w, h_panel, ctx)
    if not tbl then return end
    local stats = tbl:estimateStats(ctx)
    if not stats then return end
    local stake = findStake(tbl.stake_id)
    local target = evToGaugePos(stake, stats.ev_per_hand)

    local dt = love.timer and love.timer.getDelta() or 0
    if tbl.gauge_pos == nil then
        tbl.gauge_pos = target
    else
        local k = math.min(1, dt * GAUGE_LERP)
        tbl.gauge_pos = tbl.gauge_pos + (target - tbl.gauge_pos) * k
    end

    local bx = x + FELT_INSET
    local bw = w - 2 * FELT_INSET
    if bw < 4 then return end
    local by = y + h_panel - GAUGE_H - GAUGE_PAD

    -- Vertex colors interpolate linearly across the mesh, so to land amber
    -- at the midpoint we need two halves: red→amber, then amber→green.
    local r = Theme.status.error
    local a = Theme.status.warn
    local g = Theme.status.good
    local mid_x  = bx + bw * 0.5
    local right_x = bx + bw
    local bot_y  = by + GAUGE_H

    local left_mesh = love.graphics.newMesh({
        { bx,    by,    0, 0, r[1], r[2], r[3], 1 },
        { mid_x, by,    0, 0, a[1], a[2], a[3], 1 },
        { mid_x, bot_y, 0, 0, a[1], a[2], a[3], 1 },
        { bx,    bot_y, 0, 0, r[1], r[2], r[3], 1 },
    }, "fan", "static")
    local right_mesh = love.graphics.newMesh({
        { mid_x,   by,    0, 0, a[1], a[2], a[3], 1 },
        { right_x, by,    0, 0, g[1], g[2], g[3], 1 },
        { right_x, bot_y, 0, 0, g[1], g[2], g[3], 1 },
        { mid_x,   bot_y, 0, 0, a[1], a[2], a[3], 1 },
    }, "fan", "static")

    Theme.assetTint(1)
    love.graphics.draw(left_mesh)
    love.graphics.draw(right_mesh)

    -- Marker — narrow vertical bar at gauge_pos. Drawn slightly taller than
    -- the strip so it visually breaks the gradient's top/bottom edges.
    local mxp = bx + tbl.gauge_pos * bw
    Theme.setColor(Theme.fg.heading)
    love.graphics.rectangle("fill",
        mxp - GAUGE_MARKER_W * 0.5, by - 1,
        GAUGE_MARKER_W, GAUGE_H + 2)
end

-- ─── Debug tooltip ────────────────────────────────────────────────────
-- Toggled by backtick (see controllers/InputController). When game.debug
-- .overlay is on AND mouse is inside the panel rect, render a tooltip
-- with the table's pool-avg outcome stats and per-seated-opponent
-- breakdown. Off by default — purely a math-tuning aid.

local DEBUG_TIP_W       = 340
local DEBUG_TIP_PAD     = 8
local DEBUG_TIP_LINE_H  = 14

local function fmtPct(p)   return string.format("%5.1f%%", (p or 0) * 100) end
local function fmtBB(b)    return string.format("%5.1f",   b or 0) end
local function fmtEV(n)
    n = n or 0
    if math.abs(n) < 100 then
        return string.format("%+0.3f", n)
    elseif math.abs(n) < 10000 then
        return string.format("%+0.2f", n)
    end
    return string.format("%+0.0f", n)
end

-- Stash the (tbl, ctx) for the panel currently under the mouse cursor.
-- TablePanel.flushDebugOverlay (called once per frame, after the panel loop)
-- consumes the stash and renders the tooltip on top of all panels — fixing
-- the z-order issue where panel N+1 would overdraw panel N's tooltip.
local function stashDebugTooltipIfHover(tbl, panel_x, panel_y, panel_w, panel_h, game, controller)
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
    local stats = tbl:debugStats(controller and controller.ctx)
    if not stats then return end

    local fonts = game.fonts
    local font  = fonts.ui_small
    love.graphics.setFont(font)

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
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Opponents (%d):", #stats.opponents)
    for i, o in ipairs(stats.opponents) do
        local name  = (o.name or "?")
        if #name > 10 then name = name:sub(1, 9) .. "…" end
        local skill = (OpTypes.skills[o.skill]     and OpTypes.skills[o.skill].short)     or "?"
        local style = (OpTypes.playstyles[o.style] and OpTypes.playstyles[o.style].name)  or "?"
        if #style > 4 then style = style:sub(1, 4) end
        lines[#lines + 1] = string.format(" %d. %-10s %3s/%-4s  WC %s  EV $%s",
            i, name, skill, style, fmtPct(o.win_chance), fmtEV(o.ev_per_hand))
    end

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

-- ─── Public API ──────────────────────────────────────────────────────

-- Draw one panel and append any clickable hit-zones to hit_boxes.
function TablePanel.draw(tbl, idx, x, y, w, h, game, controller, hit_boxes)
    if not tbl then
        TablePanel.drawEmpty(x, y, w, h, game.fonts)
        return
    end

    -- Update screen-space center for floating-text spawn.
    tbl.x = x + w / 2
    tbl.y = y + h / 2

    local fonts = game.fonts
    local sl    = game.sprite_loader
    local state = game.state

    -- Panel chrome.
    Theme.setColor(Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)

    -- Header. Removing always allowed now that buy-ins are refundable —
    -- the previous "keep at least one table" gate was a leftover from
    -- before cost-to-open and trapped the player's bankroll.
    -- The "C" cursor mute toggle only renders once the cursor system is
    -- catalog-unlocked.
    local cursor_on = (controller and controller.ctx and controller.ctx.cursor_unlocked) or false
    drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, true, cursor_on)

    -- Felt area.
    local felt_x = x + FELT_INSET
    local felt_y = y + HEADER_H + FELT_INSET
    local felt_w = w - 2 * FELT_INSET
    local felt_h = h - HEADER_H - 2 * FELT_INSET
    Theme.setColor(Theme.status.good, 0.18)   -- subdued green felt
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)

    -- Layout degradation thresholds. Small cells (high table count) drop
    -- elements progressively so the panel stays readable.
    local skip_opponents    = h < 170
    local skip_player_cards = h < 120
    local mini              = h < 90    -- only header + DEAL + pot label

    -- Resolve y offsets for each section based on which are present.
    local content_top   = skip_opponents and (felt_y + 4) or (felt_y + 56)
    local comm_card_w   = mini and 14 or COMM_CARD_W
    local comm_card_h   = mini and 20 or COMM_CARD_H
    local pot_y         = content_top - 14
    local comm_y        = content_top

    -- Opponents row across the top of the felt (full mode only). Count
    -- comes from the table's actual opponent list, which the model fills
    -- based on game_type.seats — 1 (HU), 5 (6-max / Zoom), 8 (9-max).
    if not skip_opponents then
        local opp_row_y = felt_y + 4
        local n_opps    = #tbl.opponents
        if n_opps > 0 then
            -- HU: single seat centered, capped width so it doesn't sprawl
            -- across the whole felt. Other game types: even-distribute.
            if n_opps == 1 then
                local seat_w = math.min(felt_w, 100)
                local ox     = felt_x + math.floor((felt_w - seat_w) / 2)
                drawOpponentSeat(tbl.opponents[1], 1, tbl, ox, opp_row_y, seat_w, 50, sl, fonts)
            else
                local opp_w = math.floor(felt_w / n_opps)
                for i = 1, n_opps do
                    local ox = felt_x + (i - 1) * opp_w
                    drawOpponentSeat(tbl.opponents[i], i, tbl, ox, opp_row_y, opp_w, 50, sl, fonts)
                end
            end
        end
    end

    -- Pot label + community cards.
    drawPotLabel(tbl, felt_x, pot_y, felt_w, fonts)
    drawCommunity(tbl, felt_x, comm_y, felt_w, sl, comm_card_w, comm_card_h)

    -- Player seat at bottom.
    if not skip_player_cards then
        local player_y = felt_y + felt_h - PLAYER_CARD_H - 18
        drawPlayerSeat(tbl, felt_x, player_y, felt_w, sl, fonts)
    elseif not mini then
        -- Compact mode: no hole-card sprites, just a YOU $X.XX text strip
        -- (stack on this table, not global bankroll).
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.ui_small)
        love.graphics.printf("YOU  " .. moneyText(tbl.stack or 0),
            felt_x, felt_y + felt_h - 16, felt_w, "center")
    end

    -- DEAL / REBUY overlay (only when idle). Stack > 0 → DEAL. Stack at
    -- 0 means the player busted out and must rebuy the buy-in to keep
    -- playing; the green DEAL button is replaced by a red REBUY $X.XX
    -- button gated on bankroll.
    if tbl.state == "idle" then
        local btn_area_h = felt_h - STAKE_UP_H - STAKE_UP_PAD
        if (tbl.stack or 0) <= 0 then
            local stake = findStake(tbl.stake_id)
            local cost  = (stake and stake.buy_in) or 0
            local can_rebuy = state.bankroll >= cost
            local label = string.format("REBUY %s", moneyText(cost))
            drawFeltButton(felt_x, felt_y, felt_w, btn_area_h,
                fonts, hit_boxes, idx, label, "rebuy",
                Theme.status.error, can_rebuy)
        else
            drawFeltButton(felt_x, felt_y, felt_w, btn_area_h,
                fonts, hit_boxes, idx, "DEAL", "deal",
                Theme.status.good, true)
            -- Tag the just-pushed DEAL hit_box so CursorPool can skip
            -- this table when the player has muted it. Mouse-click hit
            -- testing in GrindView ignores this field — muted tables
            -- stay hand-clickable.
            local last = hit_boxes[#hit_boxes]
            if last and last.action == "deal" then
                last.cursor_muted = tbl.cursor_muted == true
            end
        end
    end

    -- Stake-up button (only if next tier exists at all AND table is idle).
    -- Renders greyed when the player can't afford the diff so they can
    -- see what's coming next. Hidden when busted — rebuy is the only
    -- meaningful action at $0 stack.
    if tbl.state == "idle" and not mini and (tbl.stack or 0) > 0 then
        local next_s, diff, affordable = nextStakeInfo(tbl.stake_id, state.bankroll)
        drawStakeUp(felt_x, felt_y, felt_w, felt_h, fonts, hit_boxes, idx, next_s, diff, affordable)
    end

    -- EV gauge — drawn last so it sits above the felt's bottom edge.
    drawGauge(tbl, x, y, w, h, controller and controller.ctx)

    -- Backtick-toggled debug tooltip — only stashes the hovered panel's
    -- (tbl, ctx). Actual render happens in TablePanel.flushDebugOverlay
    -- AFTER the caller has drawn every panel, so the tooltip is never
    -- overdrawn by adjacent panels.
    stashDebugTooltipIfHover(tbl, x, y, w, h, game, controller)
end

-- Render the deferred debug tooltip, if any. Call once per frame after the
-- whole panel grid has been drawn.
function TablePanel.flushDebugOverlay(game)
    local dbg = game and game.debug
    if not dbg or not dbg.overlay then return end
    local p = dbg._tooltip_pending
    if not p then return end
    dbg._tooltip_pending = nil
    if p.tbl then
        renderDebugTooltip(p.tbl, p.mx, p.my, game, p.controller)
    end
end

-- Empty grid slot — placeholder when table_slots cap allows more tables
-- than are currently active.
function TablePanel.drawEmpty(x, y, w, h, fonts)
    Theme.setColor(Theme.bg.sunken, 0.4)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("empty slot", x, y + math.floor(h / 2) - 8, w, "center")
end

return TablePanel
