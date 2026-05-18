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
local Decks         = require("models.Decks")
local PokerEventAnims = require("views.PokerEventAnims")
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
local StakeThemes   = require("data.stake_themes")
local HistoryBars   = require("data.history_bars")
local Lookups       = require("utils.lookups")
local Format        = require("utils.format")
local CardSprites   = require("views.CardSprites")
local Effects       = require("views.TablePanelEffects")

local TablePanel = {}

-- Layout constants — relative to a panel's (x, y) origin.
-- Base sizes are 1× design-space; scaled per-panel at draw time
-- against the panel's actual (w, h) so the chrome shrinks when the
-- grid crams many panels into a single window. Computed as
--   pscale = min(w / PANEL_BASE_W, h / PANEL_BASE_H)
-- and clamped by game.ui_scale so a single panel on a giant window
-- doesn't blow chrome up past the window scale's font budget.
local PANEL_BASE_W    = 520
local PANEL_BASE_H    = 390
local HEADER_H_BASE   = 24
local FELT_INSET_BASE = 6
local REMOVE_BTN_BASE = 18
local DEAL_BTN_W_BASE = 140
local DEAL_BTN_H_BASE = 40

local HEADER_H        = 24
local FELT_INSET      = 6
local REMOVE_BTN_SIZE = 18
local DEAL_BTN_W      = 140
local DEAL_BTN_H      = 40

-- EV readout (bottom-of-panel "+/- N.N bb/h" text) and the backtick
-- debug overlay both live in views/TablePanelStats — that module is the
-- single source of truth for the pool-breakdown line list. We just route
-- the calls through here.

-- Card sprite native aspect (56×80 px). Heights derive from width/aspect
-- so cards never stretch.
local CARD_ASPECT     = 56 / 80   -- 0.7

-- Panel-relative card sizing. Bigger panels get bigger cards; multi-table
-- mini cells get proportionally smaller cards. The skip_player_cards /
-- skip_opponents thresholds in TablePanel.draw bail out below readable
-- minimums, so we don't enforce a floor here.
--
-- Ratios are tuned so a 520-wide panel (single-table cap, see GrindView's
-- PANEL_MAX_W) gives ~68 px player cards — roughly 2× the previous fixed
-- 36 px and big enough to actually read suit/rank at a glance.
local PLAYER_CARD_W_FRAC = 0.130
local COMM_CARD_W_FRAC   = 0.085
local OPP_CARD_W_FRAC    = 0.055

local function cardSizesFor(panel_w)
    local pw = math.floor(panel_w * PLAYER_CARD_W_FRAC)
    local cw = math.floor(panel_w * COMM_CARD_W_FRAC)
    local ow = math.floor(panel_w * OPP_CARD_W_FRAC)
    return {
        player_w = pw, player_h = math.floor(pw / CARD_ASPECT),
        comm_w   = cw, comm_h   = math.floor(cw / CARD_ASPECT),
        opp_w    = ow, opp_h    = math.floor(ow / CARD_ASPECT),
    }
end

-- Opponent count comes from the table's game type now (`#tbl.opponents`).

-- ─── Helpers ──────────────────────────────────────────────────────────


-- Visibility helpers. Two paths: with poker theater on, the table
-- carries a playback_state populated by HandScript event applicators
-- (fold / deal / showdown_reveal mutate playback_state), and we read
-- those fields directly. With theater off, fall back to the legacy
-- state-name keying (dealing/flop/turn/river/showdown/settling).
local function communityCardCount(tbl)
    if tbl.playback_state then return tbl.playback_state.community_count or 0 end
    local s = tbl.state
    if s == "idle" or s == "dealing" then return 0 end
    if s == "flop"     then return 3 end
    if s == "turn"     then return 4 end
    return 5  -- river / showdown / settling
end

local function holeVisible(tbl)
    return tbl.state ~= "idle"
end

local function opponentFaceUp(tbl)
    if tbl.playback_state then
        return tbl.playback_state.opp_revealed == true
    end
    local s = tbl.state
    return s == "showdown" or s == "settling"
end

-- Default back sprite used when no deck override is available (FEATURES.DECKS
-- off, or active deck spec missing). The deck system overrides this per
-- frame in TablePanel.draw — the constant is just the fallback.
local CARD_BACK = Constants.GAUNTLET and Constants.GAUNTLET.CARD_BACK_SPRITE
                  or "cards/backs/03-fish"


-- ─── Card rendering ──────────────────────────────────────────────────
-- Card back / front / slot rendering primitives now live in
-- views/CardSprites.lua so the shove gauntlet shares the same fallback
-- treatment. drawCardBack takes the back sprite explicitly so the active
-- deck's art can flow through without globals.

local function drawCardBack(sl, back, x, y, w, h, alpha)
    CardSprites.back(sl, back or CARD_BACK, x, y, w, h, alpha)
end

local function drawCardFront(sl, card, x, y, w, h, alpha)
    CardSprites.front(sl, card, x, y, w, h, alpha)
end

local function drawCardSlot(x, y, w, h)
    CardSprites.slot(x, y, w, h)
end

-- ─── Sub-panels ──────────────────────────────────────────────────────

-- Mini bar-graph of the last N hand outcomes, drawn into the header strip.
-- Newest entry on the right, oldest on the left. Color: green = win,
-- red = loss. Height: per-tier fraction from data/history_bars.lua.
--
-- Adapts to available width: targets 10 bars, falls back to the min-size
-- pair (min_bar_w / min_bar_gap) when the zone is tight, and renders
-- nothing if even one min-sized bar wouldn't fit. No tier branches —
-- height is a data lookup.
local function drawHistoryBars(tbl, zone_x, zone_y, zone_w, zone_h, s)
    local results = tbl.last_results
    if not results or #results == 0 or zone_w <= 0 or zone_h <= 0 then
        return
    end

    local layout  = HistoryBars.layout
    local heights = HistoryBars.height

    -- Scale bar dimensions with the active ui_scale so the mini-graph
    -- grows with the window. Data file holds 1× sizes; we apply the
    -- scale here at draw time. Min sizes use ceil(... * s) so they
    -- never round down to zero on small windows.
    local sc          = s or 1
    local bar_w_pref  = math.max(1, math.floor(layout.bar_w     * sc))
    local gap_pref    = math.max(1, math.floor(layout.bar_gap   * sc))
    local bar_w_min   = math.max(1, math.ceil (layout.min_bar_w * sc))
    local gap_min     = math.max(1, math.ceil (layout.min_bar_gap * sc))
    local graph_h_max = math.max(1, math.floor(layout.graph_h   * sc))

    -- Pick the largest bar+gap pair that fits at least 1 bar in zone_w.
    -- Try the preferred sizes first; fall back to the min sizes.
    local function fit(bar_w, gap)
        local slot_w = bar_w + gap
        if slot_w <= 0 then return 0 end
        local n = math.floor((zone_w + gap) / slot_w)
        if n > layout.max_bars then n = layout.max_bars end
        return n, bar_w, gap
    end

    local n, bar_w, gap = fit(bar_w_pref, gap_pref)
    if n < 1 then
        n, bar_w, gap = fit(bar_w_min, gap_min)
    end
    if n < 1 then return end

    -- Show the newest n results, in order (oldest left → newest right).
    local total = #results
    local first_visible = math.max(1, total - n + 1)
    local visible_count = total - first_visible + 1

    -- Right-align the bar pack inside the zone. graph baseline = zone bottom.
    local pack_w = visible_count * bar_w + (visible_count - 1) * gap
    local x0 = zone_x + zone_w - pack_w
    local baseline_y = zone_y + zone_h
    local graph_h = math.min(zone_h, graph_h_max)

    -- Faint baseline track behind every slot — gives the empty slots a
    -- tiny dark cap so the graph reads as "10 slots" not "free-floating
    -- bars". Drawn full visible_count wide (not max_bars wide) so it
    -- aligns with the actual bars rendered this frame.
    Theme.setColor(Theme.border.default, layout.baseline_alpha)
    love.graphics.rectangle("fill", x0, baseline_y - 1, pack_w, 1)

    for i = 0, visible_count - 1 do
        local entry = results[first_visible + i]
        if entry and entry.tier then
            local frac = heights[entry.tier] or 0.5
            local bh   = math.max(1, math.floor(graph_h * frac))
            local bx   = x0 + i * (bar_w + gap)
            local by   = baseline_y - bh

            local color = entry.won and Theme.status.good or Theme.status.error
            Theme.setColor(color, 0.95)
            love.graphics.rectangle("fill", bx, by, bar_w, bh)
        end
    end
end

local function drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, can_remove, cursor_on, rebuy_cursor_on, s, ui_s)
    local stats = tbl:liveStats() or {}
    local header_text = stats.stake_display or "?"
    if stats.game_type_short and stats.game_type_short ~= "" then
        header_text = header_text .. " · " .. stats.game_type_short
    end
    -- Per-stake header chrome: T1 dim grey, T6 near-black with a gold
    -- accent. Falls back to default Theme.bg.chrome.
    local stake_theme = StakeThemes[tbl.stake_id]
    local header_fill = (stake_theme and stake_theme.header_bg) or Theme.bg.chrome
    Theme.setColor(header_fill)
    love.graphics.rectangle("fill", x, y, w, HEADER_H, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, HEADER_H, Theme.space.radius)

    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.heading)
    local header_text_y = y + math.floor((HEADER_H - fonts.sm:getHeight()) * 0.5)
    love.graphics.print(header_text, x + 8, header_text_y)

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
            love.graphics.setFont(fonts.sm)
            love.graphics.printf("x", fx, fy + (fh - fonts.sm:getHeight()) * 0.5,
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

    -- Header toggle buttons fill in left of the [×] from right to left.
    -- D shows when the cursor system itself is unlocked; R shows when
    -- the cursor-rebuy upgrade is owned. Each is independent so an
    -- edge-case state where only one is owned still renders correctly.
    local hands_right_offset = REMOVE_BTN_SIZE + 4 + 4
    local next_btn_x         = rb_x - REMOVE_BTN_SIZE - 4

    -- Cursor-deal toggle "D" — green (matches the DEAL button it gates).
    if cursor_on then
        local cb_x = next_btn_x
        local cb_y = y + 3
        local muted = tbl.cursor_muted == true
        local cid     = "toggle_cursor:" .. idx
        local hovered = Hover.is("hit", cid)
        local press   = ClickFlash.alpha("hit", cid)
        local active_color = Theme.status.good       -- DEAL = green
        Button.draw(cb_x, cb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, {
            fill_color   = muted and Theme.bg.sunken or Theme.bg.widget_hover,
            border_color = muted and Theme.border.soft or active_color,
            hovered      = hovered,
            press_alpha  = press,
            depth        = 2,
        }, function(fx, fy, fw, fh)
            Theme.setColor(muted and Theme.fg.disabled or active_color)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf("D", fx, fy + (fh - fonts.sm:getHeight()) * 0.5,
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
        next_btn_x         = next_btn_x - REMOVE_BTN_SIZE - 4
        hands_right_offset = hands_right_offset + REMOVE_BTN_SIZE + 4
    end

    -- Cursor-rebuy toggle "R" — red (matches the REBUY button it gates).
    -- Independent of the D toggle: visible whenever the rebuy upgrade is
    -- owned, even if the cursor-system unlock somehow weren't.
    if rebuy_cursor_on then
        local rcb_x = next_btn_x
        local rcb_y = y + 3
        local rmuted = tbl.cursor_rebuy_muted == true
        local rcid     = "toggle_rebuy_cursor:" .. idx
        local rhovered = Hover.is("hit", rcid)
        local rpress   = ClickFlash.alpha("hit", rcid)
        local r_active_color = Theme.status.error    -- REBUY = red
        Button.draw(rcb_x, rcb_y, REMOVE_BTN_SIZE, REMOVE_BTN_SIZE, {
            fill_color   = rmuted and Theme.bg.sunken or Theme.bg.widget_hover,
            border_color = rmuted and Theme.border.soft or r_active_color,
            hovered      = rhovered,
            press_alpha  = rpress,
            depth        = 2,
        }, function(fx, fy, fw, fh)
            Theme.setColor(rmuted and Theme.fg.disabled or r_active_color)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf("R", fx, fy + (fh - fonts.sm:getHeight()) * 0.5,
                                 fw, "center")
            if rmuted then
                love.graphics.setLineWidth(1)
                Theme.setColor(Theme.fg.disabled)
                love.graphics.line(fx + 3, fy + fh / 2,
                                   fx + fw - 3, fy + fh / 2)
            end
        end)
        hit_boxes[#hit_boxes + 1] = {
            x = rcb_x, y = rcb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "toggle_rebuy_cursor", idx = idx,
            tooltip = rmuted and "Unmute: cursors will rebuy this table."
                             or  "Mute: cursors won't rebuy this table.",
        }
        next_btn_x         = next_btn_x - REMOVE_BTN_SIZE - 4
        hands_right_offset = hands_right_offset + REMOVE_BTN_SIZE + 4
    end

    -- History bars — fit them into the gap between the stake-name text
    -- and the buttons on the right. Vertically centered in the header
    -- strip. The graph uses ui_scale (the window scale) instead of the
    -- per-panel scale, so the bars stay legible even at small panel
    -- sizes — the user wanted the graph to keep size, not vanish into
    -- a single-pixel sliver when the grid crams panels.
    local scale_for_graph = ui_s or s or 1
    local name_right = x + 8 + fonts.sm:getWidth(header_text)
    local zone_x     = name_right + 8
    local zone_w     = (x + w - hands_right_offset) - zone_x
    local graph_h    = math.max(1, math.floor(HistoryBars.layout.graph_h * scale_for_graph))
    local zone_y     = y + math.floor((HEADER_H - graph_h) / 2)
    drawHistoryBars(tbl, zone_x, zone_y, zone_w, graph_h, scale_for_graph)
end

local function drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts, sizes, back_sprite)
    if not opp then return end

    local gtype = Lookups.findById(GameTypes,tbl.game_type_id)

    -- HU seat is the duel — the opponent gets a heading-font name and
    -- 2× cards so they read as A Rival, not a generic seat. Single
    -- boolean check on the gtype id, not a kind chain.
    local big      = tbl.game_type_id == "hu"
    local base_w   = sizes.opp_w
    local base_h   = sizes.opp_h
    local card_w   = big and (base_w * 2) or base_w
    local card_h   = big and (base_h * 2) or base_h
    local card_gap = big and 6 or 3
    local name_font = big and fonts.md or fonts.sm
    local cards_y_offset = big and 30 or 22
    local name_max = big and 14 or 8

    -- Anonymous pool (Zoom): show "Seat N" instead of the rolled name.
    -- The data file flips the flag; the view consumes it. Reroll-flash
    -- adds a brief fade-in so the player visibly sees the swap each hand.
    local anonymous = gtype and gtype.anonymous_opponents
    local raw_name  = anonymous and ("Seat " .. opp_idx)
                      or (opp.name or "?")

    -- Pixel-width truncation, MEMOIZED on the opp object. The naive
    -- per-frame while-loop dominated the grind hot path at multi-table
    -- scale (6 panels × 5 opps × ~12 trim iterations per opp ≈ 360
    -- getWidth calls + 360 string allocations every frame, which fed
    -- enough GC pressure to compound with other heap churn into
    -- observable lag). Cache key = (raw_name, slot_w, font_height).
    -- Reroll rebuilds the opp object so cache fields go away naturally;
    -- a slot resize or font-tier change invalidates via the w / fh
    -- comparisons. Stable steady-state = zero getWidth calls in this
    -- block.
    --
    -- We always shrink the ASCII raw name BEFORE appending "…" —
    -- chopping a string that already has the 3-byte "…" suffix at byte
    -- boundaries leaves a partial UTF-8 codepoint and crashes
    -- name_font:getWidth (real bug we hit before).
    local label_pad = 6
    local fh        = name_font:getHeight()
    if opp._lbl_w   ~= w
       or opp._lbl_fh  ~= fh
       or opp._lbl_raw ~= raw_name then
        local ell = "…"
        local label = raw_name
        if name_font:getWidth(label) > w - label_pad then
            local n = #raw_name
            while n > 0 and name_font:getWidth(raw_name:sub(1, n) .. ell) > w - label_pad do
                n = n - 1
            end
            if n > 0 then
                label = raw_name:sub(1, n) .. ell
            else
                label = ell
            end
        end
        -- Even the bare ellipsis doesn't fit → hide entirely.
        if name_font:getWidth(label) > w - 2 then label = nil end
        opp._lbl     = label
        opp._lbl_w   = w
        opp._lbl_fh  = fh
        opp._lbl_raw = raw_name
    end
    local label = opp._lbl

    -- Reroll-flash alpha multiplier. flash_t decays 0.4 → 0 over ~0.4 s
    -- (set by Table:fillOpponents); we map that to alpha 0 → 1 so seats
    -- pulse-fade-in on each new hand.
    local flash_t = tbl.reroll_flash_t or 0
    local seat_alpha = (flash_t > 0) and (1 - flash_t / 0.4) or 1
    if seat_alpha < 0.15 then seat_alpha = 0.15 end

    -- Map this seat's visual opp_idx (1..n_opps) to a script_seat
    -- (1..n_seats including the player). Used by both fold-dim and the
    -- chip-stack busted lookup.
    local player_seat_for_map =
        (tbl.playback_state and tbl.playback_state.player_seat)
        or tbl.player_seat_fixed
    local script_seat = nil
    if player_seat_for_map then
        script_seat = (opp_idx < player_seat_for_map) and opp_idx or (opp_idx + 1)
    end

    -- Chip-stack tournaments (8-max KO): seats busted in earlier hands
    -- render dimmed permanently with a "BUSTED" tag. Drawn before the
    -- fold-dim so a busted-then-still-in-the-script seat reads as
    -- busted (script's in_seats may briefly include them during the
    -- hand on the first deal after they busted; the alpha tells the
    -- player what's going on).
    local seat_busted_flag = (gtype and gtype.chip_stack_table
        and tbl.seat_busted and script_seat
        and tbl.seat_busted[script_seat]) or false
    if seat_busted_flag then
        seat_alpha = seat_alpha * 0.18
    end

    -- Folded-seat dim. When the script has marked this seat out of the
    -- hand (in_seats[script_seat] is nil), drop the seat to ~30% opacity
    -- so the player can see at a glance who's still in. Theater-only —
    -- when playback_state is nil we don't dim.
    if tbl.playback_state and tbl.playback_state.player_seat and script_seat then
        if not tbl.playback_state.in_seats[script_seat] then
            seat_alpha = seat_alpha * 0.30
        end
    end

    -- Name / label. Drawn on a single line — never wrap. If even the
    -- truncated "…" form doesn't fit, the label was nil-ed out above
    -- and the slot just shows cards.
    if label then
        Theme.setColor(Theme.fg.primary, 0.85 * seat_alpha)
        love.graphics.setFont(name_font)
        local lw = name_font:getWidth(label)
        love.graphics.print(label, x + math.floor((w - lw) / 2), y)
    end

    -- Two face-down cards (or face-up if showdown and this is the revealed opp).
    local cards_y  = y + cards_y_offset
    local cards_w  = card_w * 2 + card_gap
    local cards_x  = x + math.floor((w - cards_w) / 2)
    -- Face-up requires showdown reveal AND this is the showcase opp AND
    -- (theater-mode only) that opp is still in_seats. Without the in-seats
    -- guard a folded opp could flip face-up if opponent_idx pointed at them.
    local face_up = opponentFaceUp(tbl) and tbl.opponent_idx == opp_idx
    if face_up and tbl.playback_state and tbl.playback_state.player_seat then
        local ps = tbl.playback_state.player_seat
        local script_seat = (opp_idx < ps) and opp_idx or (opp_idx + 1)
        if not tbl.playback_state.in_seats[script_seat] then
            face_up = false
        end
    end
    if face_up and tbl.opponent_hole then
        drawCardFront(sl, tbl.opponent_hole[1], cards_x, cards_y, card_w, card_h, seat_alpha)
        drawCardFront(sl, tbl.opponent_hole[2], cards_x + card_w + card_gap, cards_y, card_w, card_h, seat_alpha)
        -- Hand-name label under the revealed cards ("pair of Aces" etc.)
        -- so the showdown reveal earns a real read instead of just card
        -- art. Stored on the table at deal time by Table:_resolve.
        if tbl.opponent_hand_name and fonts and fonts.sm then
            Theme.setColor(Theme.fg.heading, seat_alpha)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf(tbl.opponent_hand_name,
                cards_x - 20, cards_y + card_h + 2,
                cards_w + 40, "center")
        end
    elseif holeVisible(tbl) then
        drawCardBack(sl, back_sprite, cards_x, cards_y, card_w, card_h, seat_alpha)
        drawCardBack(sl, back_sprite, cards_x + card_w + card_gap, cards_y, card_w, card_h, seat_alpha)
    end

    -- Chip-stack tournament: render the seat's current bb stack below
    -- the cards. Busted seats display "BUSTED" in red. Cash games skip
    -- this — opponents there are visual flavor with no per-seat stack
    -- model behind them.
    if gtype and gtype.chip_stack_table and script_seat then
        local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
        local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
        local label_y      = cards_y + card_h + 2
        -- Shift below the hand-name label when this seat is the
        -- face-up showdown reveal — otherwise the bb/BUSTED text
        -- would overdraw the "pair of Aces" line.
        if face_up and tbl.opponent_hand_name and fonts.sm then
            label_y = label_y + fonts.sm:getHeight() + 2
        end
        if seat_busted_flag then
            Theme.setColor(Theme.status.error, 0.90)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf("BUSTED",
                x, label_y, w, "center")
        elseif tbl.seat_stacks and bb_val > 0 then
            local chips = tbl.seat_stacks[script_seat] or 0
            local bb    = chips / bb_val
            local txt   = string.format("%dbb", math.floor(bb + 0.5))
            Theme.setColor(Theme.fg.muted, seat_alpha)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf(txt,
                x, label_y, w, "center")
        end
    end
end

local function drawCommunity(tbl, felt_x, row_y, felt_w, sl, card_w, card_h)
    -- card_w / card_h are required now that sizing is panel-relative.
    -- Caller in TablePanel.draw passes computed sizes; mini override
    -- substitutes smaller values for cramped layouts.
    local count = communityCardCount(tbl)
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
    -- Pot reading. Two paths:
    --   * Theater on  → tbl.playback_state.pot is the running pot, mutated
    --                   by HandScript event applicators as bets land.
    --   * Theater off → 2 × |outcome_delta| (legacy assumption that the
    --                   pot is symmetric around the player's net delta).
    local pot
    if tbl.playback_state and (tbl.playback_state.pot or 0) > 0 then
        pot = tbl.playback_state.pot
    else
        pot = (tbl.outcome_delta and math.abs(tbl.outcome_delta) * 2) or 0
    end
    if pot <= 0 then return end

    local center_x = felt_x + felt_w * 0.5
    local center_y = felt_y + felt_h * 0.5    -- visual middle of the felt

    -- Chip pile when room permits — uses outcome_tier so jackpot pots
    -- visibly dwarf small ones. Falls back to text-only on mini panels.
    if allow_chips then
        local palette = ChipData.stake_palettes[tbl.stake_id]
                        or ChipData.full_palette
        local tier    = tbl.outcome_tier or "medium"
        local chips   = Denoms.breakdown(pot, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
        local stake_theme = StakeThemes[tbl.stake_id]
        local tint    = stake_theme and stake_theme.chip_tint
        -- Stack base anchored at felt center; chips grow upward via the
        -- stack-offset, label below the pile. max_w prevents the pile
        -- from overflowing the felt on huge pots — drawStack drops
        -- smallest-denom columns until the pile fits.
        local pot_max_w = felt_w - 24    -- leave a small margin from felt edges
        Chips.drawStack(center_x, center_y + 6, chips,
            { align = "center", tint = tint, max_w = pot_max_w })
        Anchors.set(Table.anchorKey(tbl, "pot"), center_x, center_y + 6)
    end

    Theme.setColor(Theme.fg.muted)
    love.graphics.setFont(fonts.sm)
    -- Text sits below the chip pile (or, in mini-panel fallback, at the
    -- felt center).
    local text_y = allow_chips and (center_y + 12) or (center_y - 6)
    love.graphics.printf("Pot: " .. Format.moneyExact(pot), felt_x, text_y, felt_w, "center")
end

-- Legacy MTT bottom-band: hand counter + payout ladder keyed by
-- hands_won. Used only when FEATURES.MTT_KO is off and the gtype is
-- the binary_outcome 8-round MTT. The new chip-stack ladder lives in
-- drawTournamentLadder below.
local function drawLegacyMttLadder(tbl, gtype, ctx, x, y, w, fonts)
    local hands_won = (tbl.mtt and tbl.mtt.hands_won) or 0
    local hand_cap  = gtype.hand_count or 8

    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.md)
    love.graphics.printf(string.format("HAND %d / %d", hands_won, hand_cap),
        x, y, w, "center")

    local boost        = (ctx and ctx.mtt_payout_boost) or 0
    local payout_table = MttPayouts[boost] or MttPayouts[0]
    local thresholds   = {}
    for k in pairs(payout_table) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds)

    local pip_h   = 16
    local pip_gap = 6
    local n       = #thresholds
    if n == 0 then return end
    local pip_w   = math.floor((w - (n - 1) * pip_gap - 16) / n)
    if pip_w < 36 then pip_w = 36 end
    local strip_w = pip_w * n + (n - 1) * pip_gap
    local strip_x = x + math.floor((w - strip_w) / 2)
    local strip_y = y + 22

    love.graphics.setFont(fonts.sm)
    for i, th in ipairs(thresholds) do
        local px      = strip_x + (i - 1) * (pip_w + pip_gap)
        local cleared = hands_won >= th
        local is_next = not cleared
        for _, t2 in ipairs(thresholds) do
            if (not cleared) and t2 < th and hands_won < t2 then
                is_next = false
                break
            end
        end

        local fill = cleared and Theme.status.good
                     or is_next and Theme.status.warn
                     or Theme.bg.sunken
        local text_color = (cleared or is_next) and Theme.bg.window
                                                 or Theme.fg.muted
        Theme.setColor(fill)
        love.graphics.rectangle("fill", px, strip_y, pip_w, pip_h, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, strip_y, pip_w, pip_h, Theme.space.radius)

        Theme.setColor(text_color)
        love.graphics.printf(string.format("%d:%dx", th, payout_table[th] or 0),
            px, strip_y + math.floor((pip_h - fonts.sm:getHeight()) * 0.5),
            pip_w, "center")
    end

    Anchors.set(Table.anchorKey(tbl, "you"),
        x + math.floor(w * 0.5),
        strip_y + pip_h * 0.5)
end

-- Tournament bottom-band for chip-stack tables: finish-position payout
-- strip. Same vertical slot the cash-table stack pile occupies, at the
-- same position the original ladder lived in — visually unchanged.
-- The alive-count / FINISH text is rendered separately on the left of
-- the player cards (drawPlayerSeat), not in this function.
local function drawTournamentLadder(tbl, gtype, ctx, x, y, w, fonts)
    -- Pip strip: payout multipliers by finish position. Threshold keys
    -- in mtt_payouts.lua map as (n_seats - key + 1) → finish_position.
    -- Sort descending so 1st reads leftmost (top spot first).
    local n_seats      = (gtype.seats or 0) + 1
    local boost        = (ctx and ctx.mtt_payout_boost) or 0
    local payout_table = MttPayouts[boost] or MttPayouts[0]
    local thresholds   = {}
    for k in pairs(payout_table) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds, function(a, b) return a > b end)

    local pip_h     = 16
    local pip_gap   = 6
    local n         = #thresholds
    local pip_w     = math.floor((w - (n - 1) * pip_gap - 16) / n)
    if pip_w < 36 then pip_w = 36 end
    local strip_w   = pip_w * n + (n - 1) * pip_gap
    local strip_x   = x + math.floor((w - strip_w) / 2)
    -- y + 22 preserves the exact vertical slot the strip occupied when
    -- the counter line lived above it inside this function — the bar's
    -- on-screen position is unchanged from the original.
    local strip_y   = y + 22

    love.graphics.setFont(fonts.sm)
    for i, th in ipairs(thresholds) do
        local px            = strip_x + (i - 1) * (pip_w + pip_gap)
        local finish_pos    = n_seats - th + 1
        local is_player_won = tbl.last_finish == finish_pos

        local fill = is_player_won and Theme.status.good
                     or Theme.bg.sunken
        local text_color = is_player_won and Theme.bg.window
                           or Theme.fg.muted

        Theme.setColor(fill)
        love.graphics.rectangle("fill", px, strip_y, pip_w, pip_h, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, strip_y, pip_w, pip_h, Theme.space.radius)

        Theme.setColor(text_color)
        local function shortPos(p)
            if p == 1 then return "1st"
            elseif p == 2 then return "2nd"
            elseif p == 3 then return "3rd"
            else return p .. "th" end
        end
        local pip_label = string.format("%s:%dx", shortPos(finish_pos), payout_table[th] or 0)
        love.graphics.printf(pip_label, px,
            strip_y + math.floor((pip_h - fonts.sm:getHeight()) * 0.5),
            pip_w, "center")
    end

    -- Anchor for chip-flight target (cash-out from tournament end). Pinned
    -- to the strip center so payout chips fly to a coherent screen point.
    Anchors.set(Table.anchorKey(tbl, "you"),
        x + math.floor(w * 0.5),
        strip_y + pip_h * 0.5)
end

local function drawPlayerSeat(tbl, x, y, w, sl, fonts, ctx, sizes)
    -- Hole cards centered.
    local card_w  = sizes.player_w
    local card_h  = sizes.player_h
    local cards_w = card_w * 2 + 4
    local cards_x = x + math.floor((w - cards_w) / 2)
    local cards_y = y

    if holeVisible(tbl) and tbl.player_hole then
        drawCardFront(sl, tbl.player_hole[1], cards_x, cards_y, card_w, card_h, 1)
        drawCardFront(sl, tbl.player_hole[2], cards_x + card_w + 4, cards_y, card_w, card_h, 1)
        -- Hand-name label on showdown. Theater path keys off player_revealed;
        -- legacy path falls back to state == "showdown"/"settling" which
        -- already implies face-up for the player too. Either way we only
        -- want the label visible once cards have meaning at showdown.
        local revealed
        if tbl.playback_state then
            revealed = tbl.playback_state.player_revealed == true
        else
            local s = tbl.state
            revealed = s == "showdown" or s == "settling"
        end
        if revealed and tbl.player_hand_name and fonts and fonts.sm then
            Theme.setColor(Theme.fg.heading)
            love.graphics.setFont(fonts.sm)
            love.graphics.printf(tbl.player_hand_name,
                cards_x - 20, cards_y + card_h + 2,
                cards_w + 40, "center")
        end
    else
        drawCardSlot(cards_x, cards_y, card_w, card_h)
        drawCardSlot(cards_x + card_w + 4, cards_y, card_w, card_h, 1)
    end

    -- Legacy MTT (FEATURES.MTT_KO off): hand counter + payout ladder
    -- keyed by hands_won. Lives in the same bottom-band slot.
    local gtype = Lookups.findById(GameTypes,tbl.game_type_id)
    if gtype and gtype.hand_count and not gtype.chip_stack_table then
        local ladder_y = cards_y + card_h + 4
        drawLegacyMttLadder(tbl, gtype, ctx, x, ladder_y, w, fonts)
        return
    end

    -- Chip-stack tournaments:
    --   • Right of cards: YOU Nbb label (mirror of cash YOU $X.XX).
    --   • Left of cards:  alive counter / FINISH text.
    --   • Bottom band:    finish-position pip strip — the bar, in its
    --                     original on-screen position, untouched.
    if gtype and gtype.chip_stack_table then
        local label_y = cards_y + card_h + 2
        -- Right side: YOU Nbb (hidden post-bust; FINISH lives on left).
        if not tbl.last_finish then
            local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
            local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
            if bb_val > 0 and tbl.seat_stacks and tbl.player_seat_fixed then
                local chips = tbl.seat_stacks[tbl.player_seat_fixed] or 0
                local bb    = math.floor(chips / bb_val + 0.5)
                Theme.setColor(Theme.fg.heading)
                love.graphics.setFont(fonts.sm)
                love.graphics.print(string.format("YOU  %dbb", bb),
                    cards_x + cards_w + 8, label_y - 12)
            end
        end
        -- Left side: alive counter / final finish position.
        local n_seats = (gtype.seats or 0) + 1
        local alive   = 0
        if tbl.seat_busted then
            for s = 1, n_seats do
                if not tbl.seat_busted[s] then alive = alive + 1 end
            end
        else
            alive = n_seats
        end
        local counter_label
        if tbl.last_finish then
            local function positionName(pos)
                if pos == 1 then return "1st"
                elseif pos == 2 then return "2nd"
                elseif pos == 3 then return "3rd"
                else return string.format("%dth", pos) end
            end
            counter_label = string.format("FINISH %s", positionName(tbl.last_finish))
        else
            counter_label = string.format("%d/%d ALIVE", alive, n_seats)
        end
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.sm)
        local tw = fonts.sm:getWidth(counter_label)
        love.graphics.print(counter_label, cards_x - 8 - tw, label_y - 12)
        -- Bar at the bottom — original position, untouched.
        local ladder_y = cards_y + card_h + 4
        drawTournamentLadder(tbl, gtype, ctx, x, ladder_y, w, fonts)
        return
    end

    -- Stack chip pile to the LEFT of the cards (small, ~8-12 chips), and
    -- "YOU $X.XX" label to the RIGHT for the precise read. Caches the
    -- chip-pile center on tbl so chip-flight emission can anchor here.
    --
    -- While poker theater is mid-hand (winner not yet set), deduct the
    -- player's running per-street contribution from the displayed stack
    -- so the pile visibly drains as chips fly into the pot. Once the
    -- pot pushes (winner set), the actual tbl.stack update is imminent
    -- — fall back to tbl.stack so we don't double-deduct against the
    -- post-resolution value.
    local stack = tbl.stack or 0
    local display_stack = stack
    if tbl.playback_state and not tbl.playback_state.winner then
        -- per_seat_committed resets each street (used by the writer for
        -- bet-matching math). For the stack-drain display we want
        -- cumulative contribution across all streets — per_seat_total.
        local ps        = tbl.playback_state.player_seat
        local committed = (ps and tbl.playback_state.per_seat_total
                              and tbl.playback_state.per_seat_total[ps])
                          or 0
        display_stack = math.max(0, stack - committed)
    end
    local label_y = cards_y + card_h + 2

    if display_stack > 0 then
        local palette = ChipData.stake_palettes[tbl.stake_id]
                        or ChipData.full_palette
        -- Always render player stack at "medium" target (~12 chips) so the
        -- pile stays compact regardless of stake — pot/bankroll are where
        -- magnitude flexes via tier hints.
        local chips = Denoms.breakdown(display_stack, ChipData.denominations, palette, ChipData.tier_chip_target, "medium")
        local pile_anchor_x = cards_x - 8   -- right edge of pile
        local pile_y        = cards_y + card_h - 4
        local stake_theme   = StakeThemes[tbl.stake_id]
        local tint          = stake_theme and stake_theme.chip_tint
        -- max_w = whatever room exists left of the cards. Prevents the
        -- pile from marching off the panel's left edge on big stacks.
        local pile_max_w = math.max(60, pile_anchor_x - x - 6)
        Chips.drawStack(pile_anchor_x, pile_y, chips,
            { align = "right", tint = tint, max_w = pile_max_w })
        Anchors.set(Table.anchorKey(tbl, "you"), pile_anchor_x - 18, pile_y)
    else
        Anchors.set(Table.anchorKey(tbl, "you"),
            cards_x - 26, cards_y + card_h - 4)
    end

    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.sm)
    love.graphics.print("YOU  " .. Format.moneyExact(display_stack),
        cards_x + cards_w + 8, label_y - 12)
end

-- Shared felt-overlay button (DEAL when stacked, REBUY $X when busted).
-- The variant is decided in :draw based on tbl.stack; this just renders.
local DEAL_BTN_DEPTH = 4

-- Pick the felt-button font + horizontal scale that fit `label` inside
-- the button face (`fw` × `fh`). Returns (font, sx, text_x, text_y).
-- Shared between the live render and the press-then-vanish ghost so
-- the ghost can't suddenly switch to a larger font on a label that the
-- live button had to scale-blit down.
local function _pickFeltButtonFont(label, fonts, fx, fy, fw, fh)
    local pad   = 8
    local avail = math.max(1, fw - pad)
    local font  = fonts.sm
    if fh >= 32 and fonts.md:getWidth(label) <= avail then
        font = fonts.md
    end
    local tw   = font:getWidth(label)
    local fh_t = font:getHeight()
    local sx   = (tw > avail) and (avail / tw) or 1
    local draw_w = tw * sx
    local text_x = fx + math.floor((fw - draw_w) / 2)
    local text_y = fy + math.floor((fh - fh_t * sx) * 0.5)
    return font, sx, text_x, text_y
end

local function _drawFeltButtonLabel(label, fonts, fx, fy, fw, fh, enabled)
    local font, sx, text_x, text_y = _pickFeltButtonFont(label, fonts, fx, fy, fw, fh)
    love.graphics.setFont(font)
    Theme.setColor(enabled and Theme.bg.window or Theme.fg.disabled)
    if sx < 1 then
        love.graphics.push()
        love.graphics.translate(text_x, text_y)
        love.graphics.scale(sx, sx)
        love.graphics.print(label, 0, 0)
        love.graphics.pop()
    else
        love.graphics.print(label, text_x, text_y)
    end
end

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
        _drawFeltButtonLabel(label, fonts, fx, fy, fw, fh, enabled)
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

-- ─── Per-table FX (shake / vignette / lift / slam / border-pulse) ───
-- All bounded so adjacent panels in the grid don't get encroached on.
-- Implementations live in views/TablePanelEffects (sibling-module split,
-- mirrors views/TablePanelStats). State decays in models/Table.lua:update;
-- the effects layer just reads tween fields.

-- ─── Ghost factory (press-then-vanish for ephemeral buttons) ─────────
-- Builds a Ghosts.add render closure for a hit_box that's about to vanish
-- (DEAL→dealing state, REBUY→stack refilled, [×]→table removed). The
-- closure captures the rect + label + fill so the ghost matches the live
-- button exactly, and replays the press rise-out animation while the
-- underlying render path is gone.
--
-- Returns nil for actions that don't need ghost-fade (stake-up, [C], etc.
-- — those persist after click and animate via the live ClickFlash path).
-- Per-action ghost style. Functions are called per-frame so the Theme
-- token reads pick up palette swaps. Actions absent here yield no ghost.
local GHOST_STYLES = {
    deal         = function() return 4, Theme.bg.window  end,
    rebuy        = function() return 4, Theme.bg.window  end,
    remove_table = function() return 2, Theme.fg.heading end,
}

function TablePanel.makeGhostFor(hb, fonts)
    if not (hb and hb.action and hb.label) then return nil end

    local style_fn = GHOST_STYLES[hb.action]
    if not style_fn then return nil end
    local depth, label_color = style_fn()

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

    -- DEAL / REBUY ghosts share the live felt-button label renderer so
    -- the auto-fit (sm fallback + scale-blit) matches pixel-for-pixel
    -- between live and ghost. Without this the ghost picks fonts.md
    -- whenever the face is tall enough — even on labels the live
    -- button had to scale-blit down — and the text appears to "grow"
    -- on click before fading out.
    local use_felt_label = (hb.action == "deal" or hb.action == "rebuy")

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
            if use_felt_label then
                _drawFeltButtonLabel(label, fonts, fx, fy, fw, fh, true)
            else
                local font = (fh >= 32) and fonts.md or fonts.sm
                love.graphics.setFont(font)
                Theme.setColor(label_color)
                love.graphics.printf(label, fx,
                                     fy + math.floor((fh - font:getHeight()) * 0.5),
                                     fw, "center")
            end
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

    -- Per-panel scale dominates: when the grid crams 18 panels into
    -- a window, each panel might render at ~340×190 — chrome should
    -- shrink with that, not stay sized for the full window. Capped
    -- by ui_scale so a lone panel on a 4K window doesn't grow past
    -- what the window-scale font budget supports.
    local ui_s = (game and game.ui_scale) or 1
    local panel_s = math.min(w / PANEL_BASE_W, h / PANEL_BASE_H)
    local s = math.min(ui_s, panel_s)
    -- Header has to remain tall enough to hold fonts.sm + tiny padding,
    -- otherwise the per-panel scale-down crushes header text into a
    -- band that's literally shorter than a glyph.
    local fonts = game and game.fonts
    local sm_h  = (fonts and fonts.sm and fonts.sm:getHeight()) or 12
    HEADER_H        = math.max(sm_h + 4, math.floor(HEADER_H_BASE   * s))
    FELT_INSET      = math.max(1, math.floor(FELT_INSET_BASE * s))
    REMOVE_BTN_SIZE = math.max(sm_h + 2, math.floor(REMOVE_BTN_BASE * s))
    DEAL_BTN_W      = math.max(40, math.floor(DEAL_BTN_W_BASE * s))
    DEAL_BTN_H      = math.max(sm_h + 6, math.floor(DEAL_BTN_H_BASE * s))

    -- Stash the panel's current screen-space rect onto the model so the
    -- resolution emitter (Table:_finalizeHand, GrindController:update) can
    -- spawn floating-text and chip bursts at the right table. Without
    -- this, r.x/r.y default to (0, 0) and floaters land in the top-left
    -- corner instead of over the table that produced them.
    tbl.x = x
    tbl.y = y

    -- Per-table FX transform stack. Ordered: lift+slam (vertical hover/
    -- punch) → shake (random shudder on top). All sub-elements (chrome,
    -- felt, cards, chips) inherit the transform so the panel moves as a
    -- single object. State decays in Table:update; we just read.
    local shake_x, shake_y = Effects.shakeOffset(tbl)
    local lift_y           = Effects.liftSlamOffset(tbl)
    local transformed = (shake_x ~= 0 or shake_y ~= 0 or lift_y ~= 0)

    -- Hit-box offset: hit_boxes are pushed during sub-element rendering
    -- with un-transformed coords. After the panel finishes drawing, we
    -- walk the entries added during THIS panel and offset their y by
    -- lift_y so the click target tracks the visually-lifted button.
    -- Shake is intentionally excluded — folding random per-frame jitter
    -- into the hit-test would make click targets dance around.
    local hit_boxes_start = hit_boxes and #hit_boxes or 0

    -- Hover shadow — drawn BEFORE the transform push so it stays at the
    -- panel's resting position while the panel itself lifts off it. When
    -- the panel is at rest (lift_t = 0) the shadow sits exactly under the
    -- panel and isn't visible; as the panel lifts, the shadow becomes
    -- exposed and spreads slightly for a soft hover feel.
    Effects.drawHoverShadow(tbl, x, y, w, h)

    if transformed then
        love.graphics.push()
        love.graphics.translate(shake_x, shake_y + lift_y)
    end

    -- Screen-space center for floating-text spawn (read by GrindController
    -- via AnchorRegistry; written here once per draw).
    Anchors.set(Table.anchorKey(tbl, "center"), x + w / 2, y + h / 2)

    local fonts = game.fonts
    local sl    = game.sprite_loader
    local state = game.state

    -- Drain any newly-fired script events since the last frame. Each
    -- event whose model index is past tbl.view_event_cursor gets dispatched
    -- through views/PokerEventAnims (kind→fn table) — typically pops a
    -- floater near the actor's seat anchor. The anchors used by the
    -- floaters were registered in the prior frame's draw, so reading
    -- them here is 1-frame stale on the very first event of a hand;
    -- imperceptible at 60fps.
    if tbl.script and tbl.playback_state then
        local cursor = tbl.view_event_cursor or 0
        local idx    = tbl.script_idx or 0
        for i = cursor + 1, idx do
            local ev = tbl.script[i]
            if ev then
                local fn = PokerEventAnims[ev.kind]
                if fn then fn(ev, tbl, game) end
            end
        end
        tbl.view_event_cursor = idx
    end

    -- Card-back override per frame: when the deck system is on, the
    -- active deck's sprite replaces the constant default for every
    -- face-down card on this panel. Decks.activeSprite returns nil if
    -- the spec is missing → drawCardBack falls back to CARD_BACK.
    local back_sprite = (Constants.FEATURES.DECKS and Decks.activeSprite(state))
                        or CARD_BACK

    -- Panel chrome — fill stays Theme.bg.widget for chrome contrast.
    -- Border color/width come from the per-stake theme so T6 looks gold-
    -- trimmed, T1 looks plain, etc. Falls back to the default Theme token
    -- when no per-stake entry exists.
    local stake_theme_pre = StakeThemes[tbl.stake_id]
    Theme.setColor(Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    local border_color = (stake_theme_pre and stake_theme_pre.border_color)
                         or Theme.border.default
    local border_width = (stake_theme_pre and stake_theme_pre.border_width) or 1
    Theme.setColor(border_color)
    love.graphics.setLineWidth(border_width)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    -- Border-pulse flash on top of the static border. Decays in
    -- Table:update; color comes from the win/lost branch in the
    -- resolution loop. Drawn here so it overlays the panel border
    -- but sits beneath all felt content.
    Effects.drawBorderPulse(tbl, x, y, w, h)

    -- Header. Removing always allowed now that buy-ins are refundable —
    -- the previous "keep at least one table" gate was a leftover from
    -- before cost-to-open and trapped the player's bankroll.
    -- The "C" cursor mute toggle only renders once the cursor system is
    -- catalog-unlocked.
    local cursor_on        = (controller and controller.ctx and controller.ctx.cursor_unlocked) or false
    local rebuy_cursor_on  = (controller and controller.ctx and controller.ctx.cursor_rebuy_unlocked) or false
    drawHeader(tbl, x, y, w, fonts, hit_boxes, idx, true, cursor_on, rebuy_cursor_on, s, ui_s)

    -- Felt area.
    local felt_x = x + FELT_INSET
    local felt_y = y + HEADER_H + FELT_INSET
    local felt_w = w - 2 * FELT_INSET
    local felt_h = h - HEADER_H - 2 * FELT_INSET
    -- Per-stake felt tint (data/stake_themes.lua). Falls back to the old
    -- default green if the stake has no theme entry. Higher tiers feel
    -- visibly different — first step of the per-stake panel-identity work.
    local stake_theme = StakeThemes[tbl.stake_id]
    local felt_color  = (stake_theme and stake_theme.felt_tint)
                        or { Theme.status.good[1], Theme.status.good[2],
                             Theme.status.good[3], 0.18 }
    Theme.setColor(felt_color)
    love.graphics.rectangle("fill", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", felt_x, felt_y, felt_w, felt_h, Theme.space.radius)

    -- Card sizes are panel-relative — bigger panels get bigger cards. The
    -- skip thresholds below stop drawing entirely on cramped grid cells.
    local sizes = cardSizesFor(w)

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
    -- HU's opponent band scales with the 2× card size used by drawOpponentSeat.
    local opp_band_h    = hu_layout and (sizes.opp_h * 2 + 36) or (sizes.opp_h + 28)
    local content_top   = skip_opponents and (felt_y + 4) or (felt_y + opp_band_h)
    -- Mini layout uses the smallest panel-relative cards anyway; no extra
    -- override needed (sizes.comm_w on a tiny panel is already tiny).
    local comm_card_w   = sizes.comm_w
    local comm_card_h   = sizes.comm_h
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
        -- Card center sits ~half-card-height below the seat top, computed
        -- from the panel-relative sizes struct.
        if n_opps > 0 then
            -- HU: single seat centered, capped width so it doesn't sprawl
            -- across the whole felt. Other game types: even-distribute.
            if n_opps == 1 then
                -- HU's "duel" seat — wider + taller than 6-max seats so
                -- the single rival has visible presence. Sized relative
                -- to the felt + the panel-relative card dims.
                local seat_w = math.min(felt_w, math.max(180, sizes.opp_w * 2 + 80))
                local seat_h = sizes.opp_h * 2 + 36
                local ox     = felt_x + math.floor((felt_w - seat_w) / 2)
                drawOpponentSeat(tbl.opponents[1], 1, tbl, ox, opp_row_y, seat_w, seat_h, sl, fonts, sizes, back_sprite)
                -- Chip-flight target: roughly the card center under the
                -- `big` layout.
                Anchors.set(Table.anchorKey(tbl, "opp_1"),
                    ox + seat_w * 0.5, opp_row_y + sizes.opp_h + 20)
            else
                local opp_w   = math.floor(felt_w / n_opps)
                local seat_h  = sizes.opp_h + 28
                for i = 1, n_opps do
                    local ox = felt_x + (i - 1) * opp_w
                    drawOpponentSeat(tbl.opponents[i], i, tbl, ox, opp_row_y, opp_w, seat_h, sl, fonts, sizes, back_sprite)
                    Anchors.set(Table.anchorKey(tbl, "opp_" .. i),
                        ox + opp_w * 0.5, opp_row_y + math.floor(sizes.opp_h * 0.5) + 20)
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
        local player_y = felt_y + felt_h - sizes.player_h - 18
        local ctx = controller and controller.ctx
        drawPlayerSeat(tbl, felt_x, player_y, felt_w, sl, fonts, ctx, sizes)
    elseif not mini then
        -- Compact mode: no hole-card sprites, just a YOU $X.XX text strip
        -- (stack on this table, not global bankroll).
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf("YOU  " .. Format.moneyExact(tbl.stack or 0),
            felt_x, felt_y + felt_h - 16, felt_w, "center")
    end

    -- DEAL / REBUY overlay (only when idle). Stack > 0 → DEAL. Stack at
    -- 0 means the player busted out and must rebuy the buy-in to keep
    -- playing; the green DEAL button is replaced by a red REBUY $X.XX
    -- button gated on bankroll.
    if tbl.state == "idle" then
        if (tbl.stack or 0) <= 0 then
            local stake = Lookups.findById(Stakes,tbl.stake_id)
            local cost  = (stake and stake.buy_in) or 0
            local can_rebuy = state.bankroll >= cost
            local label = string.format("REBUY %s", Format.moneyExact(cost))
            drawFeltButton(felt_x, felt_y, felt_w, felt_h,
                fonts, hit_boxes, idx, label, "rebuy",
                Theme.status.error, can_rebuy)
            -- Tag the rebuy hit_box with the per-table rebuy-mute flag
            -- so CursorPool can skip this table when the player has
            -- opted out of auto-rebuy here.
            local last = hit_boxes[#hit_boxes]
            if last and last.action == "rebuy" then
                last.cursor_rebuy_muted = tbl.cursor_rebuy_muted == true
            end
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
    Effects.drawVignette(tbl, felt_x, felt_y, felt_w, felt_h)

    -- Radial-glow halo (jackpot wins). Additive shader pass over the
    -- whole panel rect; lasts ~0.7s after a jackpot win.
    Effects.drawGlow(tbl, x, y, w, h)

    -- Close the shake/lift transform before the hover-hit-test stash, so
    -- the mouse-vs-panel rect calculation in the debug tooltip uses the
    -- panel's actual (un-transformed) screen rect.
    if transformed then
        love.graphics.pop()
    end

    -- Sync hit_boxes pushed during this panel's render with the lift
    -- offset so the click target tracks the visually-lifted button.
    -- Without this, clicking on the elevated DEAL button hits empty
    -- space below it. Shake is excluded — it's per-frame jitter that
    -- would make click targets dance.
    if hit_boxes and lift_y ~= 0 and #hit_boxes > hit_boxes_start then
        for i = hit_boxes_start + 1, #hit_boxes do
            local hb = hit_boxes[i]
            hb.y = hb.y + lift_y
            if hb.visual_y then hb.visual_y = hb.visual_y + lift_y end
        end
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
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("empty slot", x, y + math.floor(h / 2) - 8, w, "center")
end

return TablePanel
