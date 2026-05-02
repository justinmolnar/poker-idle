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

local Theme         = require("views.Theme")
local Constants     = require("data.constants")
local Stakes        = require("data.stakes")
local GameTypes     = require("data.game_types")
local MttPayouts    = require("data.mtt_payouts")
local Chips         = require("views.Chips")
local Denoms        = require("services.DenominationBreakdown")
local ChipData      = require("data.chips")
local ClickFlash    = require("services.ClickFlash")
local Hover         = require("services.HoverService")
local Button        = require("views.Button")
local Ghosts        = require("services.Ghosts")
local Anchors       = require("services.AnchorRegistry")
local Table         = require("models.Table")
local Stats         = require("views.TablePanelStats")
local SpriteRenderer = require("services.SpriteRenderer")

local TablePanel = {}

-- Layout constants — relative to a panel's (x, y) origin.
local HEADER_H        = 24
local FELT_INSET      = 6
local REMOVE_BTN_SIZE = 18
local DEAL_BTN_W      = 140
local DEAL_BTN_H      = 40

-- EV readout (bottom-of-panel "+/- N.N bb/h" text) and the backtick
-- debug overlay both live in views/TablePanelStats — that module is the
-- single source of truth for the pool-breakdown line list. We just route
-- the calls through here.

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

local function findGameType(id)
    for _, gt in ipairs(GameTypes) do
        if gt.id == id then return gt end
    end
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
    if sl then
        SpriteRenderer.draw(sl, CARD_BACK, x, y, w, h, { 1, 1, 1, alpha or 1 })
    else
        Theme.setColor(Theme.bg.sunken, alpha or 1)
        love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
        Theme.setColor(Theme.border.default, alpha or 1)
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    end
end

local function drawCardFront(sl, card, x, y, w, h, alpha)
    if not card then return end
    if sl then
        SpriteRenderer.draw(sl, card:spriteName(), x, y, w, h, { 1, 1, 1, alpha or 1 })
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

    local gtype = findGameType(tbl.game_type_id)

    -- HU seat is the duel — the opponent gets a heading-font name and
    -- 2× cards so they read as A Rival, not a generic seat. Single
    -- boolean check on the gtype id, not a kind chain.
    local big      = tbl.game_type_id == "hu"
    local card_w   = big and (OPP_CARD_W * 2) or OPP_CARD_W
    local card_h   = big and (OPP_CARD_H * 2) or OPP_CARD_H
    local card_gap = big and 6 or 3
    local name_font = big and fonts.heading or fonts.ui_small
    local cards_y_offset = big and 30 or 22
    local name_max = big and 14 or 8

    -- Anonymous pool (Zoom): show "Seat N" instead of the rolled name.
    -- The data file flips the flag; the view consumes it. Reroll-flash
    -- adds a brief fade-in so the player visibly sees the swap each hand.
    local anonymous = gtype and gtype.anonymous_opponents
    local label     = anonymous and ("Seat " .. opp_idx)
                      or (opp.name or "?")
    if #label > name_max then label = label:sub(1, name_max - 1) .. "…" end

    -- Reroll-flash alpha multiplier. flash_t decays 0.4 → 0 over ~0.4 s
    -- (set by Table:fillOpponents); we map that to alpha 0 → 1 so seats
    -- pulse-fade-in on each new hand.
    local flash_t = tbl.reroll_flash_t or 0
    local seat_alpha = (flash_t > 0) and (1 - flash_t / 0.4) or 1
    if seat_alpha < 0.15 then seat_alpha = 0.15 end

    -- Name / label (always shown).
    Theme.setColor(Theme.fg.primary, 0.85 * seat_alpha)
    love.graphics.setFont(name_font)
    love.graphics.printf(label, x, y, w, "center")

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
    local cards_y  = y + cards_y_offset
    local cards_w  = card_w * 2 + card_gap
    local cards_x  = x + math.floor((w - cards_w) / 2)
    local face_up  = opponentFaceUp(tbl.state) and tbl.opponent_idx == opp_idx
    if face_up and tbl.opponent_hole then
        drawCardFront(sl, tbl.opponent_hole[1], cards_x, cards_y, card_w, card_h, seat_alpha)
        drawCardFront(sl, tbl.opponent_hole[2], cards_x + card_w + card_gap, cards_y, card_w, card_h, seat_alpha)
    elseif holeVisible(tbl.state) then
        drawCardBack(sl, cards_x, cards_y, card_w, card_h, seat_alpha)
        drawCardBack(sl, cards_x + card_w + card_gap, cards_y, card_w, card_h, seat_alpha)
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
        local chips   = Denoms.breakdown(pot, palette, tier)
        -- Stack base anchored at felt center; chips grow upward via the
        -- stack-offset, label below the pile.
        Chips.drawStack(center_x, center_y + 6, chips, { align = "center" })
        Anchors.set(Table.anchorKey(tbl, "pot"), center_x, center_y + 6)
    end

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.ui_small)
    -- Text sits below the chip pile (or, in mini-panel fallback, at the
    -- felt center).
    local text_y = allow_chips and (center_y + 12) or (center_y - 6)
    love.graphics.printf("Pot: " .. moneyText(pot), felt_x, text_y, felt_w, "center")
end

-- Tournament bottom-band: hand counter + payout ladder. Replaces the
-- stack/YOU strip when the gtype carries hand_count. Lives in the same
-- vertical slot, so panel layout is unchanged between cash and MTT.
local function drawTournamentLadder(tbl, gtype, ctx, x, y, w, fonts)
    local hands_won = (tbl.mtt and tbl.mtt.hands_won) or 0
    local hand_cap  = gtype.hand_count or 8

    -- Counter line — current hand on top.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.heading)
    local counter_label = string.format("HAND %d / %d", hands_won, hand_cap)
    love.graphics.printf(counter_label, x, y, w, "center")

    -- Pip strip with payout multipliers underneath.
    local boost  = (ctx and ctx.mtt_payout_boost) or 0
    local payout_table = MttPayouts[boost] or MttPayouts[0]

    -- Ordered ascending — collect threshold keys present in the table.
    local thresholds = {}
    for k in pairs(payout_table) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds)

    local pip_h     = 16
    local pip_gap   = 6
    local n         = #thresholds
    local pip_w     = math.floor((w - (n - 1) * pip_gap - 16) / n)
    if pip_w < 28 then pip_w = 28 end
    local strip_w   = pip_w * n + (n - 1) * pip_gap
    local strip_x   = x + math.floor((w - strip_w) / 2)
    local strip_y   = y + 22

    love.graphics.setFont(fonts.ui_small)
    for i, th in ipairs(thresholds) do
        local px = strip_x + (i - 1) * (pip_w + pip_gap)

        -- State coloring:
        --   cleared      → good (already past this threshold; payout locked)
        --   next-to-reach → warn (this is the next milestone in line)
        --   distant       → faint (still possible if you keep winning, but
        --                          not the immediate target)
        local cleared    = hands_won >= th
        local is_next    = (not cleared) and (th == thresholds[1] or hands_won >= th - (th - thresholds[1]))
        -- "is_next" approximates: the lowest uncleared threshold.
        is_next = (not cleared)
        for _, t2 in ipairs(thresholds) do
            if (not cleared) and t2 < th and hands_won < t2 then
                is_next = false
                break
            end
        end

        local fill = cleared and Theme.status.good
                     or is_next and Theme.status.warn
                     or Theme.bg.sunken
        local text_color = cleared and Theme.bg.window
                           or is_next and Theme.bg.window
                           or Theme.fg.faint

        Theme.setColor(fill)
        love.graphics.rectangle("fill", px, strip_y, pip_w, pip_h, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, strip_y, pip_w, pip_h, Theme.space.radius)

        Theme.setColor(text_color)
        local pip_label = string.format("%d:%dx", th, payout_table[th] or 0)
        love.graphics.printf(pip_label, px,
            strip_y + math.floor((pip_h - fonts.ui_small:getHeight()) * 0.5),
            pip_w, "center")
    end

    -- Anchor for chip-flight loss target (loss in MTT == tournament end;
    -- the current hand's pot still flies somewhere). Anchor at the
    -- center of the strip so the visual still reads as "chips leave."
    Anchors.set(Table.anchorKey(tbl, "you"),
        x + math.floor(w * 0.5),
        strip_y + pip_h * 0.5)
end

local function drawPlayerSeat(tbl, x, y, w, sl, fonts, ctx)
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

    -- Tournament tables swap the bottom band for a hand-counter + payout
    -- ladder; cash tables show the stack chip pile + "YOU $X.XX" label.
    local gtype = findGameType(tbl.game_type_id)
    if gtype and gtype.hand_count then
        local ladder_y = cards_y + PLAYER_CARD_H + 4
        drawTournamentLadder(tbl, gtype, ctx, x, ladder_y, w, fonts)
        return
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
        local chips = Denoms.breakdown(stack, palette, "small")
        local pile_anchor_x = cards_x - 8   -- right edge of pile
        local pile_y        = cards_y + PLAYER_CARD_H - 4
        Chips.drawStack(pile_anchor_x, pile_y, chips, { align = "right" })
        Anchors.set(Table.anchorKey(tbl, "you"), pile_anchor_x - 18, pile_y)
    else
        Anchors.set(Table.anchorKey(tbl, "you"),
            cards_x - 26, cards_y + PLAYER_CARD_H - 4)
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

-- Felt-overlay button: visual button stays centered for affordance (still
-- chunky and obviously clickable), but the hit_box now covers the entire
-- felt rect — so the player can click anywhere on the table to fire the
-- DEAL / REBUY action. The CursorPool still finds the same `action="deal"`
-- entries and clicks at the rect's center, which sits over the visual
-- button so the click animation feels natural.
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
            -- Full felt rect — click-anywhere semantics. Visual button
            -- stays centered above for affordance.
            x = x, y = y, w = w, h = h,
            -- Visual rect (where the chunky button sits) so ghost-fade
            -- animations on click can render the button shape correctly
            -- after the hit_box vanishes.
            visual_x = bx, visual_y = by, visual_w = btn_w, visual_h = btn_h,
            action = action, idx = idx,
            label = label,
            fill_color = fill_color,
            tooltip = (action == "deal")
                  and "Deal a hand at this table."
                  or  "Refill the stack and deal the next hand.",
        }
    end
end

-- Drop the unused inline ghost factory; TablePanel.makeGhostFor below is
-- the public entry point for ephemeral-button ghost-rendering.

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

    -- DEAL / REBUY hit_boxes carry visual_* fields for the actual button
    -- rect (which sits centered inside the full felt — the felt is the
    -- click area, the button is the visual). Fall back to hb.x/y/w/h for
    -- other actions (remove_table) that don't split the two.
    local rx = hb.visual_x or hb.x
    local ry = hb.visual_y or hb.y
    local rw = hb.visual_w or hb.w
    local rh = hb.visual_h or hb.h
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

    -- Screen-space center for floating-text spawn (read by GrindController
    -- via AnchorRegistry; written here once per draw).
    Anchors.set(Table.anchorKey(tbl, "center"), x + w / 2, y + h / 2)

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
    -- HU's "duel" seat is taller (80 px vs 6-max's 50 px) so push the
    -- community-card row down to make room. Single boolean check on
    -- gtype id, not a kind chain.
    local hu_layout     = tbl.game_type_id == "hu"
    local opp_band_h    = hu_layout and 86 or 56
    local content_top   = skip_opponents and (felt_y + 4) or (felt_y + opp_band_h)
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
        -- Record each opponent's seat-center as an AnchorRegistry anchor
        -- so chip-flight emission can target the winner's cards on a loss.
        -- Cards sit ~22 px below the seat top with OPP_CARD_H = 20, so the
        -- card center is roughly opp_row_y + 32.
        if n_opps > 0 then
            -- HU: single seat centered, capped width so it doesn't sprawl
            -- across the whole felt. Other game types: even-distribute.
            if n_opps == 1 then
                -- HU's "duel" seat — wider + taller than 6-max seats so the
                -- single rival has visible presence. Bumped from 100×50 to
                -- 180×80 to fit the heading-font name + 2× cards drawn by
                -- drawOpponentSeat's `big` branch.
                local seat_w = math.min(felt_w, 180)
                local ox     = felt_x + math.floor((felt_w - seat_w) / 2)
                drawOpponentSeat(tbl.opponents[1], 1, tbl, ox, opp_row_y, seat_w, 80, sl, fonts)
                -- Chip-flight target: card center sits ~30+40/2=50 px below
                -- the seat top under the `big` layout.
                Anchors.set(Table.anchorKey(tbl, "opp_1"),
                    ox + seat_w * 0.5, opp_row_y + 50)
            else
                local opp_w = math.floor(felt_w / n_opps)
                for i = 1, n_opps do
                    local ox = felt_x + (i - 1) * opp_w
                    drawOpponentSeat(tbl.opponents[i], i, tbl, ox, opp_row_y, opp_w, 50, sl, fonts)
                    Anchors.set(Table.anchorKey(tbl, "opp_" .. i),
                        ox + opp_w * 0.5, opp_row_y + 32)
                end
            end
        end
    end

    -- Community cards first, pot chips painted on TOP at the felt center
    -- (mimics the real-table look where chips pile under/around community
    -- cards). Mini panels still get the text-only fallback.
    drawCommunity(tbl, felt_x, comm_y, felt_w, sl, comm_card_w, comm_card_h)
    drawPotLabel(tbl, felt_x, felt_y, felt_w, felt_h, fonts, not mini)

    -- Default chip-flight anchors for this table — re-stamped every frame
    -- so they track the panel through layout changes. drawPlayerSeat and
    -- drawPotLabel overwrite with more specific positions when they run.
    if not Anchors.get(Table.anchorKey(tbl, "you")) then
        Anchors.set(Table.anchorKey(tbl, "you"),
            felt_x + felt_w * 0.5, felt_y + felt_h - 12)
    end
    if not Anchors.get(Table.anchorKey(tbl, "pot")) then
        Anchors.set(Table.anchorKey(tbl, "pot"),
            felt_x + felt_w * 0.5, felt_y + felt_h * 0.45)
    end

    -- Player seat at bottom.
    if not skip_player_cards then
        local player_y = felt_y + felt_h - PLAYER_CARD_H - 18
        local ctx = controller and controller.ctx
        drawPlayerSeat(tbl, felt_x, player_y, felt_w, sl, fonts, ctx)
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
        if (tbl.stack or 0) <= 0 then
            local stake = findStake(tbl.stake_id)
            local cost  = (stake and stake.buy_in) or 0
            local can_rebuy = state.bankroll >= cost
            local label = string.format("REBUY %s", moneyText(cost))
            drawFeltButton(felt_x, felt_y, felt_w, felt_h,
                fonts, hit_boxes, idx, label, "rebuy",
                Theme.status.error, can_rebuy)
        else
            drawFeltButton(felt_x, felt_y, felt_w, felt_h,
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

    -- EV readout — bottom-of-panel "+/- N.N bb/h" text. The hover-tooltip
    -- breakdown and the backtick debug overlay both live in
    -- views/TablePanelStats; we just route the calls.
    Stats.drawEvReadout(tbl, x, y, w, h, controller, fonts, hit_boxes)

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
    -- (tbl, ctx). Actual render happens in TablePanelStats.flushDebugOverlay
    -- AFTER the caller has drawn every panel, so the tooltip is never
    -- overdrawn by adjacent panels.
    Stats.stashDebugTooltipIfHover(tbl, x, y, w, h, game, controller)
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
