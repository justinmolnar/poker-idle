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
local Chips       = require("views.Chips")
local ChipData    = require("data.chips")
local ClickFlash  = require("services.ClickFlash")
local Hover       = require("services.HoverService")
local Button      = require("views.Button")
local Ghosts      = require("services.Ghosts")

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

    -- [x] remove (right edge). Chunky button via views/Button. Warn-
    -- tinted while pending_close so the player can see a click on a busy
    -- table was queued and will fire when the hand finishes.
    local rb_x = x + w - REMOVE_BTN_SIZE - 4
    local rb_y = y + 3
    local pending_close = tbl.pending_close == true
    local rb_fill       = pending_close and Theme.status.warn
                          or (can_remove and Theme.bg.widget_hover or Theme.bg.sunken)
    do
        local rid     = "remove_table:" .. idx
        local hovered = can_remove and Hover.is("hit", rid)
        local press   = can_remove and ClickFlash.alpha("hit", rid) or 0
        Button.draw(rb_x, rb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, {
            fill_color   = rb_fill,
            border_color = (can_remove or pending_close) and Theme.border.strong or Theme.border.soft,
            hovered      = hovered,
            press_alpha  = press,
            disabled     = not can_remove,
            depth        = 2,
        }, function(fx, fy, fw, fh)
            Theme.setColor((can_remove or pending_close) and Theme.fg.heading or Theme.fg.disabled)
            love.graphics.setFont(fonts.ui_small)
            love.graphics.printf("x", fx, fy + (fh - fonts.ui_small:getHeight()) * 0.5,
                                 fw, "center")
        end)
    end
    if can_remove then
        hit_boxes[#hit_boxes + 1] = {
            x = rb_x, y = rb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "remove_table", idx = idx,
            label = "x",
            fill_color = rb_fill,
            tooltip = pending_close
                  and "Closing after this hand finishes."
                   or "Close this table — refunds the current stack.",
        }
    end

    -- Cursor mute toggle "C" — only shown once the cursor system is unlocked.
    -- Filled when active (cursors target this table); dimmed when muted.
    local hands_right_offset = REMOVE_BTN_SIZE + 4 + 4
    if cursor_on then
        local cb_x = rb_x - REMOVE_BTN_SIZE - 4
        local cb_y = y + 3
        local muted = tbl.cursor_muted == true
        local cid     = "toggle_cursor:" .. idx
        local hovered = Hover.is("hit", cid)
        local press   = ClickFlash.alpha("hit", cid)
        Button.draw(cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, {
            fill_color   = muted and Theme.bg.sunken or Theme.bg.widget_hover,
            border_color = muted and Theme.border.soft or Theme.border.strong,
            hovered      = hovered,
            press_alpha  = press,
            depth        = 2,
        }, function(fx, fy, fw, fh)
            Theme.setColor(muted and Theme.fg.disabled or Theme.fg.heading)
            love.graphics.setFont(fonts.ui_small)
            love.graphics.printf("C", fx, fy + (fh - fonts.ui_small:getHeight()) * 0.5,
                                 fw, "center")
            if muted then
                love.graphics.setLineWidth(1)
                Theme.setColor(Theme.fg.disabled)
                love.graphics.line(fx + 3, fy + fh / 2,
                                   fx + fw - 3, fy + fh / 2)
            end
        end)
        hit_boxes[#hit_boxes + 1] = {
            x = cb_x, y = cb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "toggle_cursor", idx = idx,
            tooltip = muted and "Unmute: allow cursors to deal at this table."
                            or  "Mute: stop the cursor swarm from dealing at this table.",
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

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
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

local function drawPotLabel(tbl, felt_x, felt_y, felt_w, felt_h, fonts, allow_chips)
    if tbl.state == "idle" then return end
    -- Pot = total chips in the middle = your contribution + opponent's
    -- contribution. Outcome model is symmetric: win/lose magnitudes match,
    -- so 2 × |delta| is the right total-pot reading both ways.
    local pot = (tbl.outcome_delta and math.abs(tbl.outcome_delta) * 2) or 0
    if pot <= 0 then return end

    local center_x = felt_x + felt_w * 0.5
    local center_y = felt_y + felt_h * 0.5    -- visual middle of the felt

    -- Chip pile when room permits — uses outcome_tier so jackpot pots
    -- visibly dwarf tiny ones. Falls back to text-only on mini panels.
    if allow_chips then
        local palette = ChipData.stake_palettes[tbl.stake_id]
                        or ChipData.full_palette
        local tier    = tbl.outcome_tier or "small"
        local chips   = Chips.breakdown(pot, palette, tier)
        -- Stack base anchored at felt center; chips grow upward via the
        -- stack-offset, label below the pile.
        Chips.drawStack(center_x, center_y + 6, chips, { align = "center" })
        tbl.pot_x = center_x
        tbl.pot_y = center_y + 6
    end

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.ui_small)
    -- Text sits below the chip pile (or, in mini-panel fallback, at the
    -- felt center).
    local text_y = allow_chips and (center_y + 12) or (center_y - 6)
    love.graphics.printf("Pot: " .. moneyText(pot), felt_x, text_y, felt_w, "center")
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

    -- Stack chip pile to the LEFT of the cards (small, ~8-12 chips), and
    -- "YOU $X.XX" label to the RIGHT for the precise read. Caches the
    -- chip-pile center on tbl so chip-flight emission can anchor here.
    local stack = tbl.stack or 0
    local label_y = cards_y + PLAYER_CARD_H + 2

    if stack > 0 then
        local palette = ChipData.stake_palettes[tbl.stake_id]
                        or ChipData.full_palette
        -- Always render player stack at "small" target (~10 chips) so the
        -- pile stays compact regardless of stake — pot/bankroll are where
        -- magnitude flexes via tier hints.
        local chips = Chips.breakdown(stack, palette, "small")
        local pile_anchor_x = cards_x - 8   -- right edge of pile
        local pile_y        = cards_y + PLAYER_CARD_H - 4
        Chips.drawStack(pile_anchor_x, pile_y, chips, { align = "right" })
        tbl.you_x = pile_anchor_x - 18
        tbl.you_y = pile_y
    else
        tbl.you_x = cards_x - 26
        tbl.you_y = cards_y + PLAYER_CARD_H - 4
    end

    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.print("YOU  " .. moneyText(stack),
        cards_x + cards_w + 8, label_y - 12)
end

-- Shared felt-overlay button (DEAL when stacked, REBUY $X when busted).
-- The variant is decided in :draw based on tbl.stack; this just renders.
local DEAL_BTN_DEPTH = 4

-- Render the chunky DEAL/REBUY button at (bx, by, btn_w, btn_h). Used both
-- by the live render path and by the press-then-vanish ghost path, so the
-- ghost matches the live button pixel-for-pixel.
local function _renderFeltButton(bx, by, btn_w, btn_h, fonts, label, fill_color,
                                  enabled, hovered, press)
    Button.draw(bx, by, btn_w, btn_h, {
        fill_color   = fill_color,
        border_color = enabled and Theme.fg.heading or Theme.border.soft,
        line_width   = Theme.space.line_strong,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = not enabled,
        depth        = DEAL_BTN_DEPTH,
    }, function(fx, fy, fw, fh)
        local font = (fh >= 28) and fonts.heading or fonts.ui_small
        love.graphics.setFont(font)
        Theme.setColor(enabled and Theme.bg.window or Theme.fg.disabled)
        local text_y = fy + math.floor((fh - font:getHeight()) * 0.5)
        love.graphics.printf(label, fx, text_y, fw, "center")
    end)
end

local function drawFeltButton(x, y, w, h, fonts, hit_boxes, idx, label, action, fill_color, enabled)
    local btn_w = math.min(DEAL_BTN_W, w - 16)
    local btn_h = math.min(DEAL_BTN_H, h - 8)
    if btn_w < 40 then btn_w = math.max(20, w - 4) end
    if btn_h < 18 then btn_h = math.max(14, h - 4) end
    local bx = x + math.floor((w - btn_w) / 2)
    local by = y + math.floor((h - btn_h) / 2)
    local fid     = action .. ":" .. idx
    local hovered = enabled and Hover.is("hit", fid)
    local press   = enabled and ClickFlash.alpha("hit", fid) or 0

    _renderFeltButton(bx, by, btn_w, btn_h, fonts, label, fill_color,
                      enabled, hovered, press)

    if enabled then
        hit_boxes[#hit_boxes + 1] = {
            x = bx, y = by, w = btn_w, h = btn_h,
            action = action, idx = idx,
            label = label,
            fill_color = fill_color,
            tooltip = (action == "deal")
                  and "Deal a hand at this table."
                  or  "Refill the stack to 100bb to keep playing.",
        }
    end
end

-- Drop the unused inline ghost factory; TablePanel.makeGhostFor below is
-- the public entry point for ephemeral-button ghost-rendering.

local STAKE_UP_DEPTH = 2

local function drawStakeUp(felt_x, felt_y, felt_w, felt_h, fonts, hit_boxes, idx, next_stake, diff, affordable)
    if not next_stake then return end
    local bw = felt_w - 2 * STAKE_UP_PAD
    local bx = felt_x + STAKE_UP_PAD
    local by = felt_y + felt_h - STAKE_UP_H - STAKE_UP_PAD
    local sid     = "stake_up:" .. idx
    local hovered = affordable and Hover.is("hit", sid)
    local press   = affordable and ClickFlash.alpha("hit", sid) or 0
    local label   = string.format("UP -> %s  (+$%.2f)", next_stake.display_name, diff or 0)

    Button.draw(bx, by, bw, STAKE_UP_H, {
        fill_color   = affordable and Theme.bg.widget_hover or Theme.bg.sunken,
        border_color = affordable and Theme.border.strong   or Theme.border.soft,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = not affordable,
        depth        = STAKE_UP_DEPTH,
    }, function(fx, fy, fw, fh)
        Theme.setColor(affordable and Theme.fg.heading or Theme.fg.disabled)
        love.graphics.setFont(fonts.ui_small)
        local text_y = fy + math.floor((fh - fonts.ui_small:getHeight()) * 0.5)
        love.graphics.printf(label, fx, text_y, fw, "center")
    end)

    if affordable then
        hit_boxes[#hit_boxes + 1] = {
            x = bx, y = by, w = bw, h = STAKE_UP_H,
            action = "stake_up", idx = idx, next_stake_id = next_stake.id,
            tooltip = string.format("Move this table up to %s.", next_stake.display_name),
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

-- ─── Jackpot FX (shake + vignette) ───────────────────────────────────
-- Per-table screen shake and colored vignette on jackpot resolutions.
-- Both are bounded so adjacent panels in the grid don't get encroached on.

local SHAKE_MAX_PX        = 4   -- amplitude at trauma=1; trauma² scaling
                                -- means typical max ≈ 2-3 px. Stays inside
                                -- panel margins.
local VIGNETTE_MAX_ALPHA  = 0.55  -- final alpha = vignette_alpha * this

local function shakeOffset(tbl)
    local trauma = tbl.shake_trauma or 0
    if trauma <= 0 then return 0, 0 end
    local amp = SHAKE_MAX_PX * trauma * trauma
    return (love.math.random() * 2 - 1) * amp,
           (love.math.random() * 2 - 1) * amp
end

local function drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)
    local a = tbl.vignette_alpha or 0
    if a <= 0.001 or not tbl.vignette_kind then return end
    local color = (tbl.vignette_kind == "good") and Theme.status.good
                                                  or Theme.status.error
    Theme.setColor(color, a * VIGNETTE_MAX_ALPHA)
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h,
                            Theme.space.radius)
end

-- ─── Ghost factory (press-then-vanish for ephemeral buttons) ─────────
-- Builds a Ghosts.add render closure for a hit_box that's about to vanish
-- (DEAL→dealing state, REBUY→stack refilled, [×]→table removed). The
-- closure captures the rect + label + fill so the ghost matches the live
-- button exactly, and replays the press rise-out animation while the
-- underlying render path is gone.
--
-- Returns nil for actions that don't need ghost-fade (stake-up, [C], etc.
-- — those persist after click and animate via the live ClickFlash path).
function TablePanel.makeGhostFor(hb, fonts)
    if not (hb and hb.action and hb.label) then return nil end

    local depth, label_color
    if hb.action == "deal" or hb.action == "rebuy" then
        depth       = 4
        label_color = Theme.bg.window
    elseif hb.action == "remove_table" then
        depth       = 2
        label_color = Theme.fg.heading
    else
        return nil
    end

    local rx, ry, rw, rh = hb.x, hb.y, hb.w, hb.h
    local label, fill   = hb.label, hb.fill_color or Theme.bg.widget_hover
    local border_color  = Theme.fg.heading

    return function(alpha)
        -- Ghosts decays alpha 1 → 0 over ~0.5 s. Mapping straight to
        -- press_alpha gives the rise-out animation: press_alpha=1 at click
        -- (face flat), press_alpha=0 at despawn (face at rest, then ghost
        -- removed). No fade — the rise IS the visual, then it just stops.
        Button.draw(rx, ry, rw, rh, {
            fill_color   = fill,
            border_color = border_color,
            press_alpha  = alpha,
            depth        = depth,
        }, function(fx, fy, fw, fh)
            local font = (fh >= 28) and fonts.heading or fonts.ui_small
            love.graphics.setFont(font)
            Theme.setColor(label_color)
            love.graphics.printf(label, fx,
                                 fy + math.floor((fh - font:getHeight()) * 0.5),
                                 fw, "center")
        end)
    end
end

-- ─── Public API ──────────────────────────────────────────────────────

-- Draw one panel and append any clickable hit-zones to hit_boxes.
function TablePanel.draw(tbl, idx, x, y, w, h, game, controller, hit_boxes)
    if not tbl then
        TablePanel.drawEmpty(x, y, w, h, game.fonts)
        return
    end

    -- Per-table jackpot shake — applied to the entire panel render. The
    -- shake offset is computed once per frame so all sub-elements move
    -- together (chrome + felt + cards + chips), keeping the shake coherent.
    local shake_x, shake_y = shakeOffset(tbl)
    local shaking = (shake_x ~= 0 or shake_y ~= 0)
    if shaking then
        love.graphics.push()
        love.graphics.translate(shake_x, shake_y)
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
        -- Cache each opponent's seat-center on the table so chip-flight
        -- emission can target the winner's cards on a loss. Cards sit
        -- ~22 px below the seat top with OPP_CARD_H = 20, so the card
        -- center is roughly opp_row_y + 32.
        tbl._opp_xy = tbl._opp_xy or {}
        for k in pairs(tbl._opp_xy) do tbl._opp_xy[k] = nil end
        if n_opps > 0 then
            -- HU: single seat centered, capped width so it doesn't sprawl
            -- across the whole felt. Other game types: even-distribute.
            if n_opps == 1 then
                local seat_w = math.min(felt_w, 100)
                local ox     = felt_x + math.floor((felt_w - seat_w) / 2)
                drawOpponentSeat(tbl.opponents[1], 1, tbl, ox, opp_row_y, seat_w, 50, sl, fonts)
                tbl._opp_xy[1] = { ox + seat_w * 0.5, opp_row_y + 32 }
            else
                local opp_w = math.floor(felt_w / n_opps)
                for i = 1, n_opps do
                    local ox = felt_x + (i - 1) * opp_w
                    drawOpponentSeat(tbl.opponents[i], i, tbl, ox, opp_row_y, opp_w, 50, sl, fonts)
                    tbl._opp_xy[i] = { ox + opp_w * 0.5, opp_row_y + 32 }
                end
            end
        end
    end

    -- Community cards first, pot chips painted on TOP at the felt center
    -- (mimics the real-table look where chips pile under/around community
    -- cards). Mini panels still get the text-only fallback.
    drawCommunity(tbl, felt_x, comm_y, felt_w, sl, comm_card_w, comm_card_h)
    drawPotLabel(tbl, felt_x, felt_y, felt_w, felt_h, fonts, not mini)

    -- Default chip-flight anchors for this table (overridden by
    -- drawPlayerSeat / drawPotLabel below if those render).
    tbl.you_x = tbl.you_x or (felt_x + felt_w * 0.5)
    tbl.you_y = tbl.you_y or (felt_y + felt_h - 12)
    tbl.pot_x = tbl.pot_x or (felt_x + felt_w * 0.5)
    tbl.pot_y = tbl.pot_y or (felt_y + felt_h * 0.45)

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

    -- Jackpot vignette — colored wash over the felt area when a jackpot
    -- resolution is fading. Drawn AFTER the gauge so the colored tint
    -- sits over everything inside the panel.
    drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)

    -- Close the shake transform before the hover-hit-test stash, so the
    -- mouse-vs-panel rect calculation in the debug tooltip uses the
    -- panel's actual (non-shaken) screen rect.
    if shaking then
        love.graphics.pop()
    end

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
