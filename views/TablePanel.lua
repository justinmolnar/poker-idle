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

local TablePanel = {}

-- Layout constants — relative to a panel's (x, y) origin.
local HEADER_H        = 24
local FELT_INSET      = 6
local REMOVE_BTN_SIZE = 18
local STAKE_UP_H      = 22
local STAKE_UP_PAD    = 6
local DEAL_BTN_W      = 140
local DEAL_BTN_H      = 40

-- Card sizes for the cramped grid panel.
local OPP_CARD_W      = 14
local OPP_CARD_H      = 20
local COMM_CARD_W     = 28
local COMM_CARD_H     = 38
local PLAYER_CARD_W   = 36
local PLAYER_CARD_H   = 50

local OPP_COUNT = 5

-- ─── Helpers ──────────────────────────────────────────────────────────

local function findStake(id)
    for _, s in ipairs(Stakes) do
        if s.id == id then return s end
    end
end

local function nextStakeUnlocked(current_id, bankroll)
    local found = false
    for _, s in ipairs(Stakes) do
        if found then
            if bankroll >= s.unlock_bankroll then return s end
            return nil
        end
        if s.id == current_id then found = true end
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

local function drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove)
    local stake_disp = (tbl:liveStats() or {}).stake_display or "?"
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", x, y, w, HEADER_H, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, HEADER_H, Theme.space.radius)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(stake_disp, x + 8, y + 5)

    -- Hands played (right-aligned, before [x]).
    Theme.setColor(Theme.fg.muted)
    local hands = string.format("%d hands", tbl.hands_played or 0)
    local hw = fonts.ui_small:getWidth(hands)
    love.graphics.print(hands, x + w - hw - 6 - REMOVE_BTN_SIZE - 4, y + 5)

    -- [x] remove
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
end

local function drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts)
    if not opp then return end

    Theme.setColor(Theme.fg.primary, 0.85)
    love.graphics.setFont(fonts.ui_small)
    local name = opp.name or "?"
    -- Truncate by glyph budget (cheap — assume monospace-ish).
    if #name > 8 then name = name:sub(1, 7) .. "…" end
    love.graphics.printf(name, x, y, w, "center")

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
    local cards_y = y + 12
    local card_gap = 3
    local cards_w = OPP_CARD_W * 2 + card_gap
    local cards_x = x + math.floor((w - cards_w) / 2)
    local face_up = opponentFaceUp(tbl.state) and tbl.opponent_idx == opp_idx
    if face_up and tbl.opponent_hole then
        drawCardFront(sl, tbl.opponent_hole[1], cards_x, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
        drawCardFront(sl, tbl.opponent_hole[2], cards_x + OPP_CARD_W + card_gap, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
    elseif holeVisible(tbl.state) then
        drawCardBack(sl, cards_x, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
        drawCardBack(sl, cards_x + OPP_CARD_W + card_gap, cards_y, OPP_CARD_W, OPP_CARD_H, 1)
    end

    -- Stack ($) below cards.
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf(moneyText(opp.stack), x, cards_y + OPP_CARD_H + 1, w, "center")
end

local function drawCommunity(tbl, felt_x, felt_y, felt_w, sl)
    local count = communityCardCount(tbl.state)
    local total_w = COMM_CARD_W * 5 + 4 * 4
    local row_x = felt_x + math.floor((felt_w - total_w) / 2)
    local row_y = felt_y + 56

    for i = 1, 5 do
        local cx = row_x + (i - 1) * (COMM_CARD_W + 4)
        if i <= count and tbl.community and tbl.community[i] then
            drawCardFront(sl, tbl.community[i], cx, row_y, COMM_CARD_W, COMM_CARD_H, 1)
        else
            drawCardSlot(cx, row_y, COMM_CARD_W, COMM_CARD_H)
        end
    end
end

local function drawPotLabel(tbl, felt_x, felt_y, felt_w, fonts)
    -- Show the pending pot value during dealing → showdown phases.
    if tbl.state == "idle" then return end
    local pot
    if tbl.outcome_delta and tbl.outcome_won ~= nil then
        if tbl.outcome_won then
            pot = tbl.outcome_delta              -- player wins this much
        else
            pot = -tbl.outcome_delta * 2         -- approx pot when losing (player's risk doubled)
        end
    else
        pot = 0
    end
    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf("Pot: " .. moneyText(pot), felt_x, felt_y + 42, felt_w, "center")
end

local function drawPlayerSeat(tbl, x, y, w, sl, fonts, bankroll)
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

    -- Label below cards: YOU + bankroll.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf("YOU  " .. moneyText(bankroll),
        x, cards_y + PLAYER_CARD_H + 2, w, "center")
end

local function drawDealOverlay(x, y, w, h, fonts, hit_boxes, idx)
    -- Translucent bar across the felt with "DEAL" centered, hit-targeted.
    local bx = x + math.floor((w - DEAL_BTN_W) / 2)
    local by = y + math.floor((h - DEAL_BTN_H) / 2)
    Theme.setColor(Theme.status.good, 0.85)
    love.graphics.rectangle("fill", bx, by, DEAL_BTN_W, DEAL_BTN_H, Theme.space.radius)
    Theme.setColor(Theme.fg.heading, 0.95)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", bx, by, DEAL_BTN_W, DEAL_BTN_H, Theme.space.radius)
    love.graphics.setLineWidth(1)
    Theme.setColor(Theme.bg.window)
    love.graphics.setFont(fonts.heading)
    love.graphics.printf("DEAL", bx, by + 9, DEAL_BTN_W, "center")
    hit_boxes[#hit_boxes + 1] = {
        x = bx, y = by, w = DEAL_BTN_W, h = DEAL_BTN_H,
        action = "deal", idx = idx,
    }
end

local function drawStakeUp(felt_x, felt_y, felt_w, felt_h, fonts, hit_boxes, idx, next_stake)
    if not next_stake then return end
    local bw = felt_w - 2 * STAKE_UP_PAD
    local bx = felt_x + STAKE_UP_PAD
    local by = felt_y + felt_h - STAKE_UP_H - STAKE_UP_PAD
    Theme.setColor(Theme.bg.widget_hover, 0.85)
    love.graphics.rectangle("fill", bx, by, bw, STAKE_UP_H, Theme.space.radius)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", bx, by, bw, STAKE_UP_H, Theme.space.radius)
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.ui_small)
    love.graphics.printf("UP -> " .. next_stake.display_name,
        bx, by + 4, bw, "center")
    hit_boxes[#hit_boxes + 1] = {
        x = bx, y = by, w = bw, h = STAKE_UP_H,
        action = "stake_up", idx = idx, next_stake_id = next_stake.id,
    }
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

    -- Header.
    local can_remove = controller and controller.pool and (controller.pool:count() > 1) or false
    drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove)

    -- Felt area.
    local felt_x = x + FELT_INSET
    local felt_y = y + HEADER_H + FELT_INSET
    local felt_w = w - 2 * FELT_INSET
    local felt_h = h - HEADER_H - 2 * FELT_INSET
    Theme.setColor(Theme.status.good, 0.18)   -- subdued green felt
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)

    -- Opponents row across the top of the felt.
    local opp_row_y = felt_y + 4
    local opp_w    = math.floor(felt_w / OPP_COUNT)
    for i = 1, OPP_COUNT do
        local opp = tbl.opponents and tbl.opponents[i]
        local ox  = felt_x + (i - 1) * opp_w
        drawOpponentSeat(opp, i, tbl, ox, opp_row_y, opp_w, 50, sl, fonts)
    end

    -- Pot label + community.
    drawPotLabel(tbl, felt_x, felt_y, felt_w, fonts)
    drawCommunity(tbl, felt_x, felt_y, felt_w, sl)

    -- Player seat at bottom.
    local player_y = felt_y + felt_h - PLAYER_CARD_H - 18
    drawPlayerSeat(tbl, felt_x, player_y, felt_w, sl, fonts, state.bankroll)

    -- DEAL overlay (only when idle).
    if tbl.state == "idle" then
        drawDealOverlay(felt_x, felt_y, felt_w, felt_h - STAKE_UP_H - STAKE_UP_PAD,
            fonts, hit_boxes, idx)
    end

    -- Stake-up button (only if next stake exists + affordable AND table is idle).
    if tbl.state == "idle" then
        local next_s = nextStakeUnlocked(tbl.stake_id, state.bankroll)
        drawStakeUp(felt_x, felt_y, felt_w, felt_h, fonts, hit_boxes, idx, next_s)
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
