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
--       └ bottom:  2 player hole cards centered; chip pile + its $ amount
--                  at the left edge, EV readout at the right
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
local ChipFlight    = require("views.ChipFlight")
local ChipPile      = require("views.ChipPile")
local ChipData      = require("data.chips")
local ClickFlash    = require("services.ClickFlash")
local RollingValue  = require("services.RollingValue")
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
local FeltDecor     = require("views.FeltDecor")
local FeltLayout    = require("views.FeltLayout")
local BandStack     = require("services.BandStack")
local Pop           = require("services.Pop")

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

-- EV readout (bottom-of-panel "+/- $N.NN/h" text) and the backtick
-- debug overlay both live in views/TablePanelStats — that module is the
-- single source of truth for the pool-breakdown line list. We just route
-- the calls through here.

-- Panel-relative card sizing now lives in views/FeltLayout (sourced from
-- data/felt_layout's card fractions) so the layout calculator and the panel
-- share one sizing path. Thin alias kept for the existing call sites.
local cardSizesFor = FeltLayout.cardSizes

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

-- Backs take no `plate` argument: the deck's art is drawn at every size (see
-- views/CardSprites), so there is no decision to force.
local function drawCardBack(sl, back, x, y, w, h, alpha, shadow)
    CardSprites.shadow(x, y, w, h, alpha, shadow)
    CardSprites.back(sl, back or CARD_BACK, x, y, w, h, alpha)
end

-- Fronts take the layout's FORCED small-card decision, not a per-call size
-- test: the showdown emphasis pass redraws the winning cards up to 1.26x, and
-- letting each call re-derive it from its own width would flip a card near the
-- threshold between art and plate mid-pop. `shadow` (the drop-shadow offset in
-- px, 0 = none) comes from the layout for the same reason.
local function drawCardFront(sl, card, x, y, w, h, alpha, plate, shadow)
    if not card then return end
    CardSprites.shadow(x, y, w, h, alpha, shadow)
    CardSprites.front(sl, card, x, y, w, h, alpha, plate)
end

local function drawCardSlot(x, y, w, h)
    CardSprites.slot(x, y, w, h)
end

-- Showdown win highlight. `combo` is the winner's best-5 (the 5 cards from
-- models/Table's player_combo / opponent_combo). A card glows when it is one
-- of those references. Matches the gauntlet's best-5 treatment so "which
-- cards won" reads at a glance — the winner's two hole cards + the board
-- cards they used light up green, the rest stay plain.
-- Value match (suit+rank) -- a 7-card deal has no duplicates, so this uniquely
-- identifies a card and can't break on reference identity the way `c == card`
-- could if the combo and the drawn card ever came from different objects.
local function inCombo(card, combo)
    if not combo or not card then return false end
    for _, c in ipairs(combo) do
        if c.rank == card.rank and c.suit == card.suit then return true end
    end
    return false
end

-- Showdown emphasis is done as a single overlay pass (drawShowdownEmphasis,
-- below) that runs AFTER every normal card/anim draw, so it can't be buried.

-- ─── Sub-panels ──────────────────────────────────────────────────────

-- Mini bar-graph of the last N hand outcomes, drawn into the header strip.
-- Newest entry on the right, oldest on the left. Color: per-tier ramp
-- (green for wins, red for losses) so a Stack result pops gold/pink at a
-- glance. Height: per-tier fraction from data/history_bars.lua.
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

            -- Color by tier so a Stack (jackpot) result pops at a glance,
            -- while win/loss stays legible (green ramp vs red ramp). Keyed
            -- lookup — no tier branches; flat win/loss color is the fallback.
            local ramp  = entry.won and Theme.tier.win or Theme.tier.loss
            local color = ramp[entry.tier]
                          or (entry.won and Theme.status.good or Theme.status.error)
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
            love.graphics.printf("X", fx, fy + (fh - fonts.sm:getHeight()) * 0.5,
                                 fw, "center")
        end)
    end
    if can_remove then
        hit_boxes[#hit_boxes + 1] = {
            x = rb_x, y = rb_y, w = REMOVE_BTN_SIZE, h = REMOVE_BTN_SIZE,
            action = "remove_table", idx = idx,
            label = "X",
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

local function drawOpponentSeat(opp, opp_idx, tbl, x, y, w, h, sl, fonts, sizes,
                                cards_y_offset, back_sprite, show_names, plate,
                                shadow, plate_rect, felt_color, button)
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
    -- All seat names use the small xs tier (HU included). HU was md, which
    -- dwarfed the felt and shrank the opp/community cards -- it's low-priority
    -- chrome, not worth the space.
    local name_font = fonts.xs or fonts.sm
    -- cards_y_offset is supplied by views/FeltLayout (= reserved name height +
    -- gap) so cards always begin BELOW the name, at any font/panel size.
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
    if show_names == false then
        -- The layout decided this seat is too narrow to hold a name. Names are
        -- flavor and there is no smaller font to shrink into, so nothing is
        -- drawn and nothing is measured (the memo below is the hot path at 32
        -- panels x 7 seats). Clearing _lbl_raw is what makes the memo rebuild
        -- if the grid opens back up; the guard keeps this to one write.
        if opp._lbl_raw ~= nil then
            opp._lbl, opp._lbl_w, opp._lbl_fh, opp._lbl_raw = nil, nil, nil, nil
        end
    elseif opp._lbl_w  ~= w
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
    local seat_folded = false
    if tbl.playback_state and tbl.playback_state.player_seat and script_seat then
        if not tbl.playback_state.in_seats[script_seat] then
            seat_alpha  = seat_alpha * 0.30
            seat_folded = true
        end
    end
    -- Out of the hand, either way. The dim above says HOW MUCH; this says the
    -- seat draws flat slabs instead of deck art, which is what actually reads
    -- at a glance (see CardSprites.folded).
    local seat_out = seat_folded or seat_busted_flag

    -- Seat plate: the backing this seat's name and cards sit on, so the seat
    -- reads as a position at the table. Published by the layout only when the
    -- seat is showing a name (the plate IS the nameplate), and dimmed with the
    -- seat so a folded or busted one recedes as a whole.
    FeltDecor.drawSeatPlate(plate_rect, felt_color, seat_alpha)

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
        drawCardFront(sl, tbl.opponent_hole[1], cards_x, cards_y, card_w, card_h, seat_alpha,
                      plate, shadow)
        drawCardFront(sl, tbl.opponent_hole[2], cards_x + card_w + card_gap, cards_y, card_w, card_h,
                      seat_alpha, plate, shadow)
        -- Showdown win emphasis (dim losers / grow winners) is applied later as
        -- a single on-top overlay pass in TablePanel.draw -- see
        -- drawShowdownEmphasis. The hand-name label renders under this seat.
    elseif holeVisible(tbl) then
        -- A seat that's out of the hand shows flat slabs, not deck art. The
        -- alpha dim alone left a folded seat carrying every bit of detail a
        -- live one has, so "who's still in" took a second look; two shapes
        -- side by side read instantly, and keep reading at nine pixels wide.
        local drawOne = seat_out and CardSprites.folded or nil
        if drawOne then
            drawOne(cards_x, cards_y, card_w, card_h, seat_alpha)
            drawOne(cards_x + card_w + card_gap, cards_y, card_w, card_h, seat_alpha)
        else
            drawCardBack(sl, back_sprite, cards_x, cards_y, card_w, card_h, seat_alpha, shadow)
            drawCardBack(sl, back_sprite, cards_x + card_w + card_gap, cards_y, card_w, card_h,
                         seat_alpha, shadow)
        end
    end

    -- Dealer button. `button` is the layout's SIZE decision (nil below the
    -- diameter where a disc stops being a disc); the model says which seat
    -- holds it, and it advances ONE seat per hand — a button that jumps around
    -- is worse than no button, since moving is the whole thing it communicates.
    --
    -- Read from button_visual_seat, NOT button_seat: the latter is script space
    -- and cash re-rolls player_seat every hand, so it maps to a different drawn
    -- seat each time. Visual space is the fixed ring the panel actually draws --
    -- opponents 1..n left to right, you last.
    --
    -- Straddles the lower-LEFT corner of the seat's cards, clamped inside the
    -- seat box so it can never drift over a neighbouring seat, and on the
    -- opposite side from the bb stack label that hangs under them.
    local btn_seat = tbl.playback_state and tbl.playback_state.button_visual_seat
    if button and btn_seat and opp_idx == btn_seat then
        local br = button.d * 0.5
        FeltDecor.drawButton(math.max(x + br, cards_x),
                             cards_y + card_h, button.d, seat_alpha)
    end

    -- Chip-stack tournament: render the seat's current bb stack below
    -- the cards. Busted seats display "BUSTED" in red. Cash games skip
    -- this — opponents there are visual flavor with no per-seat stack
    -- model behind them.
    if gtype and gtype.chip_stack_table and script_seat then
        local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
        local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
        local label_y      = cards_y + card_h + 2
        -- Same rule as the seat name: 8px is the floor, so a label that
        -- doesn't fit its seat is dropped rather than clipped mid-glyph.
        local function seatLabel(txt, color, alpha)
            love.graphics.setFont(fonts.sm)
            if fonts.sm:getWidth(txt) > w - 2 then return end
            Theme.setColor(color, alpha)
            love.graphics.printf(txt, x, label_y, w, "center")
        end
        if seat_busted_flag then
            seatLabel("BUSTED", Theme.status.error, 0.90)
        elseif tbl.seat_stacks and bb_val > 0 then
            local chips = tbl.seat_stacks[script_seat] or 0
            local bb    = chips / bb_val
            seatLabel(string.format("%dbb", math.floor(bb + 0.5)),
                      Theme.fg.muted, seat_alpha)
        end
    end
end

-- Draws the 5 community slots centered in the comm layout rect
-- (`{ x, y, w, card_w, card_h, gap }` from views/FeltLayout).
local function drawCommunity(tbl, comm, sl, plate)
    local count   = communityCardCount(tbl)
    local total_w = comm.card_w * 5 + 4 * comm.gap
    local row_x   = comm.x + math.floor((comm.w - total_w) / 2)

    for i = 1, 5 do
        local cx = row_x + (i - 1) * (comm.card_w + comm.gap)
        if i <= count and tbl.community and tbl.community[i] then
            drawCardFront(sl, tbl.community[i], cx, comm.y, comm.card_w, comm.card_h, 1,
                          plate, comm.shadow)
        else
            drawCardSlot(cx, comm.y, comm.card_w, comm.card_h)
        end
    end
end

-- Draws the pot pile + "Pot: $X" into the `pot` layout anchor
-- (`{ center_x, chips_y, text_x, text_w, text_y, max_w, allow_chips }` from
-- views/FeltLayout). chips_y is the base chip's CENTRE and the pile grows
-- upward from it over the community row, which is by design; the layout
-- reserves only the bottom half plus the text line below it.
--
-- `allow_chips` is false once the felt is too short for a chip bigger than a
-- dot. The pot is then the number alone.
local function drawPotLabel(tbl, pot, fonts)
    local pot_key = Table.anchorKey(tbl, "pot")
    -- Record the pile's spot before any early-out. The first bet of a hand
    -- is reserved into this pile on a frame where the pot is still empty
    -- and nothing below here runs, and it has to land somewhere real.
    if pot.allow_chips then
        local stake_theme_pot = StakeThemes[tbl.stake_id]
        ChipPile.place(pot_key, pot.center_x, pot.chips_y, {
            align = "center",
            max_w = pot.max_w,
            -- The layout decides how wide the pot may spread: unbounded it
            -- runs a single line of chips out under the community cards.
            max_cols = pot.max_cols,
            max_rows = pot.max_rows,
            scale = pot.chip_scale or 1,
            tint  = stake_theme_pot and stake_theme_pot.chip_tint,
        })
    else
        -- Felt too short for a chip that isn't a dot, so the pot is the number
        -- alone. The pile still needs CLEARING (it would otherwise sit there
        -- holding last hand's chips, invisible, and hand them to a detonation)
        -- and the anchor still needs a real spot, since bet flights aim at it
        -- whether or not anything is drawn when they land.
        ChipPile.clear(pot_key)
        Anchors.set(pot_key, pot.center_x, pot.chips_y)
    end

    if tbl.state == "idle" then
        RollingValue.reset("table_pot:" .. (tbl._id or 0))
        -- Next hand gets its pile back.
        tbl.pot_exploded       = nil
        tbl.pot_explode_pending = nil
        ChipPile.clear(pot_key)
        return
    end
    -- Pot reading. Two paths:
    --   * Theater on  → tbl.playback_state.pot is the running pot, mutated
    --                   by HandScript event applicators as bets land. Taken
    --                   RAW, zero included.
    --   * Theater off → 2 × |outcome_delta| (legacy assumption that the
    --                   pot is symmetric around the player's net delta).
    --
    -- The theater path must not fall through to the outcome_delta guess
    -- when the running pot is zero. That value is the PREVIOUS hand's, so
    -- the pot never reads as empty, and the pile below never gets the
    -- `potval <= 0` clear that ends a hand — it carries its chips into the
    -- next one and the next hand's bets pile on top of them. Harmless when
    -- the pile was a number recomputed every frame; not harmless now that
    -- it's a collection that persists.
    local theater = Constants.FEATURES and Constants.FEATURES.POKER_THEATER
    local potval
    if theater then
        potval = (tbl.playback_state and tbl.playback_state.pot) or 0
    elseif tbl.playback_state and (tbl.playback_state.pot or 0) > 0 then
        potval = tbl.playback_state.pot
    else
        potval = (tbl.outcome_delta and math.abs(tbl.outcome_delta) * 2) or 0
    end

    -- What the PILE is allowed to show: chips that have actually been
    -- committed, and nothing else. Never outcome_delta.
    --
    -- outcome_delta is decided at deal, so feeding it to the pile fills
    -- the pot the instant DEAL is clicked, before a blind is posted —
    -- and its SIZE is the tier, which hands the player the result of the
    -- hand up front. It also runs straight past what the stake's chips
    -- can express: a four-figure delta through a $1 top denomination is a
    -- wall of hundreds of identical chips. The reading above keeps it for
    -- the text, but under the theater the pile only ever draws real
    -- committed chips. A legacy build has no per-action pot to read and
    -- no per-action flights either, so it keeps the estimate — its pile
    -- would otherwise be empty all hand.
    local pile_val = theater
        and ((tbl.playback_state and tbl.playback_state.pot) or 0)
        or potval

    local rolled_pot = RollingValue.get("table_pot:" .. (tbl._id or 0), potval)
    -- NB: no early-out on a near-zero rolled_pot here. The pile below has
    -- to be told the pot is empty — that's the call that ends its hand —
    -- and the rolling value lags behind the real one, so bailing on it
    -- would skip exactly the frames where potval first reads zero. Only
    -- the text at the bottom of this function is suppressed.

    -- Chip pile when room permits — uses outcome_tier so jackpot pots
    -- visibly dwarf small ones. Text-only once the chip would be a dot.
    --
    -- The pile is a COLLECTION owned by views/ChipPile, not a breakdown of
    -- potval recomputed here every frame. Bets are reserved into it by the
    -- theater's chip flights and fill in as they land, so the pot grows
    -- with the chips arriving instead of jumping the instant they launch.
    if pot.allow_chips then
        local palette = ChipData.stake_palettes[tbl.stake_id]
                        or ChipData.full_palette
        -- FIXED tier while the hand is live — NOT tbl.outcome_tier.
        --
        -- outcome_tier is decided at deal, and it drives the pile's chip
        -- COUNT (data/chips.lua tier_chip_target: 4 for small, 50 for
        -- jackpot). Composing the running pot against it means a $2 pot
        -- that is about to become a Stack sits there as fifty chips from
        -- the first blind — the pile announces the tier before a single
        -- card is dealt. The pot is worth what's been bet and should look
        -- like it; the tier is the payout's business, and the payout is
        -- what the detonation and the resolution bursts are for.
        local tier    = "medium"
        local stake_theme = StakeThemes[tbl.stake_id]
        local tint    = stake_theme and stake_theme.chip_tint
        -- The base chip is CENTERED on chips_y (the community-row bottom edge,
        -- per FeltLayout) and the pile grows UPWARD over the community cards
        -- (overlap by design). The layout reserves the base chip's lower half +
        -- the "Pot:" text BELOW chips_y, so the pile is never lifted further
        -- over the cards and the text always has clear room underneath it.
        local cs = pot.chip_scale or 1

        if pile_val > 0 then
            ChipPile.sync(pot_key, pile_val, { palette = palette, tier = tier })
        else
            ChipPile.clear(pot_key)
        end

        -- Jackpot detonation: the pile comes apart INSTEAD of being drawn.
        -- The controller raises pot_explode_pending on a stack win; we
        -- consume it here and hand ChipFlight the pile's own chips, so the
        -- debris IS the collection that was sitting there — not a
        -- breakdown recomputed at the moment of the explosion. The debris
        -- then regroups into your stack, so the explosion IS the payout.
        --
        -- With poker theater on this never fires: the script's pot_push
        -- handler detonates at the moment the pot is pushed and sets
        -- pot_exploded itself. This is the legacy build's path.
        if tbl.pot_explode_pending and not tbl.pot_exploded then
            tbl.pot_explode_pending = nil
            local debris = ChipPile.takeAll(pot_key)
            if debris then
                tbl.pot_exploded = true
                local you_key = Table.anchorKey(tbl, "you")
                -- Scale the burst to this panel (see the center anchor,
                -- stamped with the panel size each draw) so a table one of
                -- twelve doesn't detonate at the size of a solo table.
                local c = Anchors.get(Table.anchorKey(tbl, "center"))
                ChipFlight.explodeTaken(debris, {
                    tint         = tint,
                    scale        = cs,
                    dest_key     = you_key,
                    dest         = Anchors.get(you_key),
                    within       = (c and c[3] and c[4]) and { c[3], c[4] } or nil,
                    gather_sound = "chip_land_you",
                })
            end
        end

        if not tbl.pot_exploded then
            ChipPile.draw(pot_key)
        end
        Anchors.set(pot_key, pot.center_x, pot.chips_y)
    end

    -- Pot amount uses the xs tier -- it's low-priority chrome that shouldn't
    -- read as big as the cards (falls back to sm at 1×, see FontService).
    -- Hidden while there's no pot to speak of, which is what the early-out
    -- up top used to do for this whole function.
    if rolled_pot > 0.01 then
        Theme.setColor(Theme.fg.muted)
        love.graphics.setFont(fonts.xs or fonts.sm)
        love.graphics.printf("Pot: " .. Format.moneyExact(rolled_pot),
            pot.text_x, pot.text_y, pot.text_w, "center")
    end
end

-- Legacy MTT bottom row: "HAND N/M" on the left + the payout pip ladder
-- filling the rest — ONE thin row that sits in the same bottom band the cash
-- table uses for its chips/tied-up/EV stats (so the cards never shrink and the
-- ladder lands at the felt bottom). Used when FEATURES.MTT_KO is off and the
-- gtype is the binary_outcome 8-round MTT.
local function drawLegacyMttLadder(tbl, gtype, ctx, band, fonts)
    local hands_won = (tbl.mtt and tbl.mtt.hands_won) or 0
    local f, fh = fonts.sm, fonts.sm:getHeight()
    love.graphics.setFont(f)

    -- The HAND x/x counter lives at the (empty) pot slot now (drawn by the
    -- orchestrator); the payout ladder gets the FULL bottom-band width here.
    local boost        = (ctx and ctx.mtt_payout_boost) or 0
    local payout_table = MttPayouts[boost] or MttPayouts[0]
    local thresholds   = {}
    for k in pairs(payout_table) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds)
    local n = #thresholds
    if n == 0 then return end

    local pip_gap = 4
    local left    = band.x
    local strip_w = band.w
    local pip_w   = math.floor((strip_w - (n - 1) * pip_gap) / n)
    if pip_w < 24 then pip_w = 24 end
    local pip_h   = band.h
    local pip_y   = band.y

    for i, th in ipairs(thresholds) do
        local px      = left + (i - 1) * (pip_w + pip_gap)
        local prev    = thresholds[i - 1] or 0     -- previous tier (0 for the first)
        local cleared = hands_won >= th
        -- Progress toward THIS tier, measured from the previous tier. The first
        -- pip fills over its full hand span (e.g. 0->6), so it starts empty and
        -- gains ~1/span per won hand instead of flashing yellow at hand 0. Once
        -- reached it's a solid green pip. Later (1-hand) tiers fill in one step.
        local progress = 0
        if cleared then
            progress = 1
        elseif hands_won > prev then
            progress = (hands_won - prev) / math.max(1, th - prev)
        end

        -- Empty pip background, then a left-anchored green fill for the progress.
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", px, pip_y, pip_w, pip_h, Theme.space.radius)
        if progress > 0 then
            Theme.setColor(Theme.status.good)
            love.graphics.rectangle("fill", px, pip_y,
                math.max(1, math.floor(pip_w * progress)), pip_h, Theme.space.radius)
        end
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, pip_y, pip_w, pip_h, Theme.space.radius)
        -- Dark text on a solid (cleared) pip; light text otherwise so it reads
        -- over both the sunken background and a partial green fill.
        Theme.setColor(cleared and Theme.bg.window or Theme.fg.heading)
        love.graphics.printf(string.format("%d:%dx", th, payout_table[th] or 0),
            px, pip_y + math.floor((pip_h - fh) / 2), pip_w, "center")
    end

    Anchors.set(Table.anchorKey(tbl, "you"), band.x + band.w * 0.5, band.y + band.h * 0.5)
end

-- Tournament bottom row for chip-stack tables: finish-position payout pips,
-- a single row filling the `band` (same thin bottom band the cash stats use).
-- The alive-count / FINISH text is rendered separately by drawPlayerSeat.
local function drawTournamentLadder(tbl, gtype, ctx, band, fonts)
    local n_seats      = (gtype.seats or 0) + 1
    local boost        = (ctx and ctx.mtt_payout_boost) or 0
    local payout_table = MttPayouts[boost] or MttPayouts[0]
    local thresholds   = {}
    for k in pairs(payout_table) do thresholds[#thresholds + 1] = k end
    table.sort(thresholds, function(a, b) return a > b end)   -- 1st leftmost

    local f, fh   = fonts.sm, fonts.sm:getHeight()
    local n       = #thresholds
    if n == 0 then return end
    local pip_gap = 4
    local pip_w   = math.floor((band.w - (n - 1) * pip_gap) / n)
    if pip_w < 24 then pip_w = 24 end
    local pip_h, pip_y = band.h, band.y

    love.graphics.setFont(f)
    local function shortPos(p)
        if p == 1 then return "1st" elseif p == 2 then return "2nd"
        elseif p == 3 then return "3rd" else return p .. "th" end
    end
    for i, th in ipairs(thresholds) do
        local px            = band.x + (i - 1) * (pip_w + pip_gap)
        local finish_pos    = n_seats - th + 1
        local is_player_won = tbl.last_finish == finish_pos
        local fill       = is_player_won and Theme.status.good or Theme.bg.sunken
        local text_color = is_player_won and Theme.bg.window or Theme.fg.muted
        Theme.setColor(fill)
        love.graphics.rectangle("fill", px, pip_y, pip_w, pip_h, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", px, pip_y, pip_w, pip_h, Theme.space.radius)
        Theme.setColor(text_color)
        love.graphics.printf(string.format("%s:%dx", shortPos(finish_pos), payout_table[th] or 0),
            px, pip_y + math.floor((pip_h - fh) / 2), pip_w, "center")
    end

    Anchors.set(Table.anchorKey(tbl, "you"), band.x + band.w * 0.5, band.y + band.h * 0.5)
end

-- The player's RUNNING stack through a theater hand: what they sat down with,
-- minus what they've pushed in, plus the pot if they've just been pushed it.
-- tbl.stack itself doesn't move until the table enters settling and the
-- controller applies the resolution — so reading it raw mid-hand would claim
-- the player still holds the chips they bet.
--
-- Crossing pot_push has to stay CONTINUOUS. Falling back to tbl.stack there
-- (what this used to do the moment a winner was set) jumps the number back up
-- for the second or so between the pot pushing and the resolution landing, and
-- the pile would tidy down to it and straight back up again.
local function displayStack(tbl)
    local stack = tbl.stack or 0
    local pbs   = tbl.playback_state
    if pbs and tbl.state ~= "idle" and tbl.state ~= "settling" then
        local seat      = pbs.player_seat
        local committed = (seat and pbs.per_seat_total and pbs.per_seat_total[seat]) or 0
        local won       = (seat and pbs.winner == seat and (pbs.pot_at_push or 0)) or 0
        return math.max(0, stack - committed + won)
    end
    return stack
end

-- The bottom-left money line, in the form the layout picked. "Tied up" is the
-- same term as the top-bar TIED UP cell, which is the sum of these (NOT
-- "Stack": that word is the win/loss tier). The printed number rolls toward
-- its target (top-bar money feel); the pile above stays on the raw value so
-- its denominations don't reshuffle every frame mid-roll.
--
-- Called twice per frame — once to MEASURE before the layout runs, once to
-- draw. RollingValue eases by wall-clock delta, so the second call in a frame
-- advances by ~0 and returns the value the first one measured.
local function tiedText(tbl, parts)
    local rolled = RollingValue.get("table_tied:" .. (tbl._id or 0), displayStack(tbl))
    local money  = Format.moneyExact(rolled)
    if parts == "short" then return money end
    return "Tied up  " .. money
end

-- Renders the player seat into the layout `hole` rect (centered hole cards +
-- showdown hand-name) and `bottom` anchors (chip pile + its $ amount at the
-- felt LEFT edge — both from views/FeltLayout; the EV readout takes the
-- right edge later in :draw). Tournament tables draw their ladder as a
-- single row in the bottom band (bottom.band). `tied_anchor_key` (e.g.
-- "tied:1") registers the "Tied up $X" label as a hint-anchor.
local function drawPlayerSeat(tbl, hole, bottom, sl, fonts, ctx, tied_anchor_key, button)
    local card_w  = hole.card_w
    local card_h  = hole.card_h
    local cards_w = card_w * 2 + hole.gap
    local cards_x = hole.x + math.floor((hole.w - cards_w) / 2)
    local cards_y = hole.y

    if holeVisible(tbl) and tbl.player_hole then
        drawCardFront(sl, tbl.player_hole[1], cards_x, cards_y, card_w, card_h, 1,
                      hole.plate, hole.shadow)
        drawCardFront(sl, tbl.player_hole[2], cards_x + card_w + hole.gap, cards_y, card_w, card_h, 1,
                      hole.plate, hole.shadow)
        -- Showdown win emphasis (dim losers / grow winners) is applied later as
        -- a single on-top overlay pass in TablePanel.draw (drawShowdownEmphasis).
    else
        drawCardSlot(cards_x, cards_y, card_w, card_h)
        drawCardSlot(cards_x + card_w + hole.gap, cards_y, card_w, card_h, 1)
    end

    -- Dealer button when it's on YOUR seat. In visual space you are the LAST
    -- seat (opponents are 1..n, drawn left to right, you are below them), which
    -- is where the button lands after it walks off the right-hand seat. Same
    -- lower-left placement the opponent seats use, so the disc means one thing
    -- wherever it sits.
    local pbs = tbl.playback_state
    if button and pbs and pbs.button_visual_seat
       and pbs.button_visual_seat == (#tbl.opponents + 1) then
        FeltDecor.drawButton(math.max(hole.x + button.d * 0.5, cards_x),
                             cards_y + card_h, button.d, 1)
    end

    -- Legacy MTT (FEATURES.MTT_KO off): hand counter + payout ladder in the
    -- bottom band (the felt-bottom slot), spanning the felt width.
    local gtype = Lookups.findById(GameTypes,tbl.game_type_id)
    if gtype and gtype.hand_count and not gtype.chip_stack_table then
        drawLegacyMttLadder(tbl, gtype, ctx, bottom.band, fonts)
        return
    end

    -- Chip-stack tournaments: alive/FINISH counter at the felt LEFT edge,
    -- Depth Nbb at the RIGHT edge, finish-position pip strip below — all in
    -- the bottom band.
    if gtype and gtype.chip_stack_table then
        -- Alive/Depth labels sit just ABOVE the pip band (the band itself is
        -- one thin row filled by the pips).
        local label_y = bottom.band.y - fonts.sm:getHeight() - 2
        local font    = fonts.sm
        love.graphics.setFont(font)

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

        -- Tournament chips aren't reclaimable cash, so not "Tied up" —
        -- "Depth" is the poker term for a stack in bb.
        local depth_full, depth_short
        if not tbl.last_finish then
            local stake_for_bb = Lookups.findById(Stakes, tbl.stake_id)
            local bb_val       = (stake_for_bb and stake_for_bb.bb) or 0
            if bb_val > 0 and tbl.seat_stacks and tbl.player_seat_fixed then
                local chips = tbl.seat_stacks[tbl.player_seat_fixed] or 0
                local bb    = math.floor(chips / bb_val + 0.5)
                depth_short = string.format("%dbb", bb)
                depth_full  = "Depth  " .. depth_short
            end
        end

        -- Same shed as the cash row: two edge-anchored strings on one line with
        -- no smaller font to fall back on, so the right-hand one gives up its
        -- label and then leaves rather than running into the counter.
        Theme.setColor(Theme.fg.heading)
        love.graphics.print(counter_label, bottom.chips.x, label_y)
        if depth_full then
            local left_w = font:getWidth(counter_label)
            for _, txt in ipairs({ depth_full, depth_short }) do
                local tw = font:getWidth(txt)
                local t  = BandStack.threeUp(bottom.inner_w, left_w, tw, 0, bottom.pad)
                if t.center_show then
                    love.graphics.print(txt, bottom.right_x - tw, label_y)
                    break
                end
            end
        end
        drawTournamentLadder(tbl, gtype, ctx, bottom.band, fonts)
        return
    end

    -- Cash: chip pile + its $ amount hug the felt LEFT edge; the EV
    -- readout takes the RIGHT edge (drawn later from L.bottom.ev).
    --
    -- displayStack / tiedText live at module scope so TablePanel.draw can
    -- MEASURE the tied-up line before the layout runs (the felt sheds the
    -- "Tied up" label when the row is too narrow to hold it beside the EV
    -- readout) and hand the exact same string back here to draw.
    local display_stack = displayStack(tbl)

    -- No hold-back ledger any more: the pile no longer follows the scalar
    -- while chips are in the air. Chips the player bets are TAKEN out of
    -- this collection and chips they win are RESERVED into it, so it is
    -- already showing exactly what has actually arrived. It reconciles
    -- against display_stack only once everything has landed (rake, rebuys,
    -- anything that moves the number without a flight) — see ChipPile.sync.
    local you_key = Table.anchorKey(tbl, "you")
    local palette = ChipData.stake_palettes[tbl.stake_id]
                    or ChipData.full_palette
    local stake_theme = StakeThemes[tbl.stake_id]
    local tint        = stake_theme and stake_theme.chip_tint
    -- The pile's base chip is centered on its y; offset up by the (scaled)
    -- chip radius so the pile's visual BOTTOM sits on the tied-up baseline.
    -- The pile scales with the cards (bottom.chip_scale) to stay proportional.
    local cs     = bottom.chip_scale or 1
    local pile_y = bottom.chips.y - Chips.radius() * cs

    ChipPile.place(you_key, bottom.chips.x, pile_y, {
        align = "left", max_w = bottom.chips.max_w, scale = cs, tint = tint,
        max_cols = bottom.chips.max_cols, max_rows = bottom.chips.max_rows,
    })
    -- "medium" target (~12 chips) keeps the pile compact regardless of stake.
    ChipPile.sync(you_key, display_stack, { palette = palette, tier = "medium" })
    ChipPile.draw(you_key)

    if ChipPile.count(you_key) > 0 then
        Anchors.set(you_key, bottom.chips.x + 18, pile_y)
    else
        Anchors.set(you_key, bottom.chips.x, bottom.chips.y)
    end

    -- "Tied up $X.XX" on the bottom line beneath the pile it prices — the
    -- same term as the top-bar TIED UP cell, which is the sum of these
    -- (NOT "Stack": that word is the win/loss tier). The printed number
    -- rolls toward its target (top-bar money feel); the pile above stays
    -- on the raw value so its denominations don't reshuffle every frame
    -- mid-roll.
    --
    -- The label goes first when the row is tight: it is chrome, and the
    -- number's position under the pile already says what it prices.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.sm)
    local tied_str = tiedText(tbl, bottom.tied.parts)
    love.graphics.print(tied_str, bottom.tied.x, bottom.tied.y)
    if tied_anchor_key then
        Anchors.set(tied_anchor_key, bottom.tied.x, bottom.tied.y,
            fonts.sm:getWidth(tied_str), fonts.sm:getHeight())
    end
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
    -- Hint-anchor on the visual button ("deal:1", "rebuy:3", ...). Goes
    -- stale while a hand plays (button hidden) — fine, hints keyed to it
    -- complete on the click that hides it. "rebuy:any" aliases whichever
    -- busted table drew last, so a hint can point at "a" rebuy button
    -- without knowing the panel index.
    Anchors.set(action .. ":" .. idx, bx, by, btn_w, btn_h)
    if action == "rebuy" then
        Anchors.set("rebuy:any", bx, by, btn_w, btn_h)
    end
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
-- Gather the on-screen rect of every FACE-UP card (community + player hole +
-- the revealed showcase opponent's hole), recomputing the exact same
-- positions the draw functions used. Pure geometry — no rendering — so the
-- emphasis pass can re-target each card after everything else has drawn.
local function collectShownCards(tbl, L)
    local out = {}
    if L.community then
        local comm    = L.community
        local count   = communityCardCount(tbl)
        local total_w = comm.card_w * 5 + 4 * comm.gap
        local row_x   = comm.x + math.floor((comm.w - total_w) / 2)
        for i = 1, count do
            if tbl.community and tbl.community[i] then
                out[#out + 1] = { card = tbl.community[i],
                    x = row_x + (i - 1) * (comm.card_w + comm.gap),
                    y = comm.y, w = comm.card_w, h = comm.card_h,
                    plate = comm.plate, shadow = comm.shadow }
            end
        end
    end
    if L.hole and holeVisible(tbl) and tbl.player_hole then
        local hole    = L.hole
        local cards_w = hole.card_w * 2 + hole.gap
        local cards_x = hole.x + math.floor((hole.w - cards_w) / 2)
        out[#out + 1] = { card = tbl.player_hole[1], x = cards_x,
                          y = hole.y, w = hole.card_w, h = hole.card_h,
                          plate = hole.plate, shadow = hole.shadow }
        out[#out + 1] = { card = tbl.player_hole[2], x = cards_x + hole.card_w + hole.gap,
                          y = hole.y, w = hole.card_w, h = hole.card_h,
                          plate = hole.plate, shadow = hole.shadow }
    end
    -- Only the revealed, in-seat showcase opponent shows hole cards.
    local oi = tbl.opponent_idx
    if oi and L.opponents and L.opponents.seats[oi] and tbl.opponent_hole and opponentFaceUp(tbl) then
        local reveal = true
        if tbl.playback_state and tbl.playback_state.player_seat then
            local ps = tbl.playback_state.player_seat
            local ss = (oi < ps) and oi or (oi + 1)
            if not tbl.playback_state.in_seats[ss] then reveal = false end
        end
        if reveal then
            local ob      = L.opponents
            local seat    = ob.seats[oi]
            local big     = tbl.game_type_id == "hu"
            local cw      = big and (L.sizes.opp_w * 2) or L.sizes.opp_w
            local ch      = big and (L.sizes.opp_h * 2) or L.sizes.opp_h
            local cgap    = big and 6 or 3
            local cards_w = cw * 2 + cgap
            local cards_x = seat.x + math.floor((seat.w - cards_w) / 2)
            local cards_y = ob.y + ob.cards_y_offset
            out[#out + 1] = { card = tbl.opponent_hole[1], x = cards_x, y = cards_y,
                              w = cw, h = ch, plate = ob.plate, shadow = ob.shadow }
            out[#out + 1] = { card = tbl.opponent_hole[2], x = cards_x + cw + cgap, y = cards_y,
                              w = cw, h = ch, plate = ob.plate, shadow = ob.shadow }
        end
    end
    return out
end

-- Showdown emphasis. The "which cards won" signal, drawn after every card and
-- animation pass so nothing buries it: cards NOT in the winning five are dimmed
-- (board + both holes), and the winning cards stay lit and ENLARGED with a
-- brief pop on reveal. No borders. `win5` is the winner's best-5 hand
-- (player_combo on a player win, opponent_combo on an opp win).
local function drawShowdownEmphasis(tbl, L, sl, win5)
    if not win5 then return end
    local shown = collectShownCards(tbl, L)
    if #shown == 0 then return end

    -- Pass 1: dim the cards that did NOT make the winning hand.
    for _, c in ipairs(shown) do
        if not inCombo(c.card, win5) then
            Theme.setColor(Theme.bg.window, 0.62)
            love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, Theme.space.radius)
        end
    end
    -- Pass 2: the winning cards stay full-bright and enlarged, with a single
    -- POP at the reveal that eases back to the steady size. state_timer is the
    -- per-state clock and resets on every phase change, so it would re-fire the
    -- pop when chips move (settling). Gate it OFF during settling: the pop plays
    -- once on the showdown reveal, then the cards just hold their enlarged size
    -- through the chip move (same scale at the boundary -> no snap).
    local st    = tbl.state_timer or 0
    local pop   = (tbl.state ~= "settling") and Pop.fromTimer(st, 0.25) or 0
    local scale = Pop.scale(pop, 1.13, 0.13)      -- rests at 1.13, pops to ~1.26
    for _, c in ipairs(shown) do
        if inCombo(c.card, win5) then
            local gw, gh = c.w * scale, c.h * scale
            local gx = c.x - (gw - c.w) / 2
            local gy = c.y - (gh - c.h) / 2
            -- Shadow travels with the pop. The un-popped card's shadow is
            -- still on the felt underneath at the old offset, so redrawing it
            -- under the enlarged card is what covers it.
            CardSprites.shadow(gx, gy, gw, gh, 1, c.shadow)
            CardSprites.front(sl, c.card, gx, gy, gw, gh, 1, c.plate)
        end
    end
end

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
    -- via AnchorRegistry; written here once per draw). Carries the panel's
    -- SIZE as well, so effects that should be scaled to this table rather
    -- than to the screen — the pot detonation, which otherwise throws the
    -- same 600px cloud over a panel a quarter that wide — have something
    -- to measure against. Point readers only touch [1]/[2].
    Anchors.set(Table.anchorKey(tbl, "center"), x + w / 2, y + h / 2, w, h)

    -- Seed a default pot anchor BEFORE the script-event loop below runs. The
    -- first bet of a hand flies its chips to the "pot" anchor during that loop,
    -- but the precise pile position isn't computed until drawPotLabel later in
    -- this frame — so on a table's very first bet the anchor would be unset and
    -- the chips would fly to (0,0). Default it to the panel center (on the
    -- felt); drawPotLabel overwrites it with the exact pile spot each frame.
    if not Anchors.get(Table.anchorKey(tbl, "pot")) then
        Anchors.set(Table.anchorKey(tbl, "pot"), x + w / 2, y + h / 2)
    end

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

    -- Card-back override per frame: once the deck system has unlocked,
    -- the active deck's sprite replaces the constant default for every
    -- face-down card on this panel. Decks.activeSprite returns nil if
    -- the spec is missing → drawCardBack falls back to CARD_BACK.
    local back_sprite = (Decks.systemUnlocked(state) and Decks.activeSprite(state))
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
    -- Whether this (stake, game type) has banked its bounty this run — used for
    -- the chrome trim, drawn AFTER the header below so it wraps the whole
    -- panel (the header draws its own border over the top edge otherwise).
    local banked = controller and controller:bountyBanked(tbl.stake_id, tbl.game_type_id)
    local anti_banked = controller and controller.antiBountyBanked and controller:antiBountyBanked(tbl.stake_id, tbl.game_type_id)

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

    -- "{chip} banked" or "{achip} banked" trim around the WHOLE panel chrome. Drawn after the
    -- header so it overdraws the header's own border on the top edge/sides.
    if banked then
        Theme.setColor(Theme.currency.chip)
        love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
        love.graphics.setLineWidth(1)
    elseif anti_banked then
        Theme.setColor({ 0.65, 0.35, 0.95 })
        love.graphics.setLineWidth(math.max(1, math.floor(2 * s)))
        love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
        love.graphics.setLineWidth(1)
    end

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
    -- ── Felt layout ─────────────────────────────────────────────────────
    -- ONE pass (views/FeltLayout) maps the felt rect → an explicit rect/anchor
    -- for every element; the draw functions below just render into what they
    -- are handed. No more per-element offset math, no h<N degradation cliffs.
    local sizes  = cardSizesFor(w)
    local gtype  = Lookups.findById(GameTypes, tbl.game_type_id)
    local is_tournament = (gtype and (gtype.chip_stack_table or gtype.hand_count)) and true or false
    local sm_h2  = fonts.sm:getHeight()
    local md_h   = fonts.md:getHeight()
    local xs_h   = (fonts.xs or fonts.sm):getHeight()   -- opp names + pot text reserve
    -- The caller measures text widths so FeltLayout stays pure geometry. The
    -- bottom row holds two edge-anchored strings on ONE line with no smaller
    -- font to fall back on, so the layout needs every form it might shed to.
    local ev_w, ev_money_w = Stats.measureEvReadout(tbl, controller, fonts)
    ev_w, ev_money_w = ev_w or 0, ev_money_w or 0
    local tied_w       = fonts.sm:getWidth(tiedText(tbl, "full"))
    local tied_short_w = fonts.sm:getWidth(tiedText(tbl, "short"))
    -- One character's advance in the seat-name font: what the layout converts
    -- a seat's width into "how many characters of name fit".
    local name_ch_w    = fonts.sm:getWidth("0")

    -- UNIVERSAL LAYOUT: every game type uses the SAME thin bottom row (one
    -- text-line tall) — cash draws chips/tied-up/EV in it, a tournament draws its
    -- HAND counter + payout ladder as a single row in it. No game type gets a
    -- taller band, so cards/opponents/community/hole are identical everywhere
    -- and stay full-size. (bottom_extra/card_bottom default to the thin row.)
    local L = FeltLayout.compute({
        felt_x = felt_x, felt_y = felt_y, felt_w = felt_w, felt_h = felt_h,
        hu = (tbl.game_type_id == "hu"), n_opps = #tbl.opponents,
        sizes = sizes, s = s, sm_h = sm_h2, md_h = md_h, xs_h = xs_h,
        ev_w = ev_w, ev_money_w = ev_money_w,
        tied_w = tied_w, tied_short_w = tied_short_w,
        name_ch_w = name_ch_w,
        pile_r = Chips.radius(),
    })

    -- ── Felt surface ────────────────────────────────────────────────────
    -- Drawn AFTER the layout solve, not before, because the layout is what
    -- decides whether this felt gets a rail — and if it does, the playing
    -- surface is the rect INSIDE the ring, which is also the rect every band
    -- above was solved against. Below the rail's gate L.rail is nil and the
    -- surface is the whole felt, exactly as before.
    --
    -- Decor makes no decisions of its own: views/FeltDecor draws what the
    -- layout published and skips what it published as nil.
    local surf = L.rail
    if surf then
        FeltDecor.drawRail(surf, stake_theme)
        local rw = surf.width
        FeltDecor.drawSurface(surf.x + rw, surf.y + rw,
                              surf.w - 2 * rw, surf.h - 2 * rw,
                              felt_color, math.max(0, (surf.radius or 0) - 1))
    else
        FeltDecor.drawSurface(felt_x, felt_y, felt_w, felt_h,
                              felt_color, Theme.space.radius)
        Theme.setColor(Theme.border.soft)
        love.graphics.rectangle("line", felt_x, felt_y, felt_w, felt_h,
                                Theme.space.radius)
    end
    -- The community plate sits on the surface and under every card, so it
    -- draws here rather than with its band.
    FeltDecor.drawCommPlate(L.community and L.community.plate_rect, felt_color)

    -- Showdown winner state, computed once. At a reveal, win5 is the winner's
    -- best-5 (player_combo on a player win, opponent_combo on an opp win; both
    -- set by models/Table at deal time). The emphasis pass dims everything else
    -- and grows those five; the hand-name label is parked AT the winner (above
    -- your hole cards if you won, under the winning opp's seat if they did) so
    -- position says who, the label just says with-what.
    local show_winner = opponentFaceUp(tbl)
    local player_won  = (tbl.outcome_delta or 0) > 0
    local win5        = show_winner
                        and (player_won and tbl.player_combo or tbl.opponent_combo)
                        or nil

    -- Opponents row (seats pre-split by the layout; chip-flight anchor per seat).
    if L.opponents then
        local ob = L.opponents
        for i, seat in ipairs(ob.seats) do
            local opp = tbl.opponents[i]
            if opp then
                drawOpponentSeat(opp, i, tbl, seat.x, ob.y, seat.w, ob.h,
                    sl, fonts, L.sizes, ob.cards_y_offset, back_sprite,
                    ob.show_names, ob.plate, ob.shadow,
                    seat.plate_rect, felt_color, L.button)
                Anchors.set(Table.anchorKey(tbl, "opp_" .. i),
                    seat.x + seat.w * 0.5, ob.anchor_y)
            end
        end
    end

    -- Community cards. The pot pile is drawn LATER (after the showdown emphasis)
    -- so the chips -- which by design overlap the community cards -- sit on top
    -- of the dim/grow overlay instead of getting painted over by it.
    if L.community then drawCommunity(tbl, L.community, sl, L.community.plate) end

    -- Default chip-flight anchors — re-stamped each frame; drawPlayerSeat /
    -- drawPotLabel overwrite with more specific positions when they run.
    if not Anchors.get(Table.anchorKey(tbl, "you")) then
        Anchors.set(Table.anchorKey(tbl, "you"),
            felt_x + felt_w * 0.5, felt_y + felt_h - 12)
    end
    if not Anchors.get(Table.anchorKey(tbl, "pot")) then
        Anchors.set(Table.anchorKey(tbl, "pot"),
            felt_x + felt_w * 0.5, felt_y + felt_h * 0.45)
    end

    -- Player seat. Every band survives at every felt size now (the layout
    -- adapts what goes inside them instead of dropping them), so there is no
    -- cards-dropped fallback to branch to.
    local ctx = controller and controller.ctx
    drawPlayerSeat(tbl, L.hole, L.bottom, sl, fonts, ctx, "tied:" .. idx, L.button)

    -- DEAL / REBUY overlay (only when idle). Stack > 0 → DEAL. Stack at
    -- 0 means the player busted out and must rebuy the buy-in to keep
    -- playing; the green DEAL button is replaced by a red REBUY $X.XX
    -- button gated on bankroll.
    if tbl.state == "idle" then
        if (tbl.stack or 0) <= 0 then
            -- Price comes from the controller, which owns the discount math
            -- (Night Table's rebuy_discount). Reading raw stake.buy_in here
            -- made the button lie about the price and refuse affordable
            -- rebuys. rebuyCostFor is deterministic — Medical Kit's free
            -- roll happens inside rebuyTable, and only ever costs less.
            local stake = Lookups.findById(Stakes,tbl.stake_id)
            local cost  = (controller and controller.rebuyCostFor)
                          and controller:rebuyCostFor(idx)
                          or ((stake and stake.buy_in) or 0)
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

    -- EV readout — cash tables only (tournaments fill this row with their
    -- ladder). Drawn into the layout's bottom-center slot, and dropped when
    -- there's no room for it (L.bottom.ev.show).
    if L.bottom and L.bottom.ev.show and not is_tournament then
        Stats.drawEvReadout(tbl, L.bottom.ev, controller, fonts, hit_boxes,
            "ev:" .. idx)
    end

    -- Showdown emphasis — dim the losing/unused cards, grow + pop the winning
    -- five. Runs here, after every card + EV pass, so it sits on top and reads.
    drawShowdownEmphasis(tbl, L, sl, win5)

    -- Pot pile + "Pot: $X", drawn AFTER the emphasis so the chips stay on top of
    -- the dim/grow overlay (the pile is meant to overlap the community cards).
    if L.pot then drawPotLabel(tbl, L.pot, fonts) end

    -- Legacy MTT: the binary-outcome pot is always empty, so the felt-center
    -- pot slot shows the HAND x/x tournament counter instead (the payout ladder
    -- spans the full bottom band below).
    if L.pot and tbl.state ~= "idle"
       and gtype and gtype.hand_count and not gtype.chip_stack_table then
        local hands_won = (tbl.mtt and tbl.mtt.hands_won) or 0
        local fh  = fonts.sm:getHeight()
        -- Center vertically in the OPEN gap between the community and hole cards
        -- (L.pot.text_y is offset low for the cash pile, which lands on the
        -- hole cards when there's no pile).
        local top = (L.community and (L.community.y + L.community.card_h)) or L.pot.text_y
        local bot = (L.hole and L.hole.y) or (top + fh)
        local hy  = top + math.floor((bot - top - fh) / 2)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf(string.format("HAND %d/%d", hands_won, gtype.hand_count or 8),
            L.pot.text_x, hy, L.pot.text_w, "center")
    end

    -- Payout-bar hover (tournaments): surface the SAME breakdown tooltip the EV
    -- section / add-table button show, so the ladder explains itself. A
    -- tooltip-only hit_box over the bottom band.
    if hit_boxes and L.bottom and L.bottom.band
       and gtype and (gtype.chip_stack_table or gtype.hand_count) then
        local stake = Lookups.findById(Stakes, tbl.stake_id)
        local b     = L.bottom.band
        hit_boxes[#hit_boxes + 1] = {
            x = b.x, y = b.y, w = b.w, h = b.h,
            tooltip = Stats.breakdownLinesFor(controller, stake, gtype),
        }
    end

    -- Showdown hand-name label — the prefix-free name ("two pair, Ks and 3s")
    -- of the WINNING hand, parked AT the winner so position names who: just
    -- above your hole cards when you win, centered under the winning opp's seat
    -- when they win (the seat's cards are glowing green to match). Dark pill,
    -- on top, sized to the text and clamped inside the felt so it never crops.
    if show_winner then
        local hand = player_won and tbl.player_hand_name or tbl.opponent_hand_name
        if hand and hand ~= "" then
            local f = fonts.sm
            love.graphics.setFont(f)
            local tw = math.min(felt_w - 8, f:getWidth(hand) + 16)
            local th = f:getHeight() + 4

            -- Center-x + baseline depend on who won.
            local cx, by
            if player_won and L.hole then
                cx = felt_x + felt_w * 0.5
                by = L.hole.y + math.floor((L.hole.card_h - th) / 2)  -- centered OVER your cards
            elseif (not player_won) and L.opponents
                   and tbl.opponent_idx and L.opponents.seats[tbl.opponent_idx] then
                local seat = L.opponents.seats[tbl.opponent_idx]
                cx = seat.x + seat.w * 0.5
                by = L.opponents.y + L.opponents.cards_y_offset
                     + L.opponents.card_h + 2              -- just under their cards
            else
                cx = felt_x + felt_w * 0.5                 -- fallback: top-center
                by = felt_y + 2
            end

            -- Clamp the pill fully inside the felt (so a wide name under a
            -- narrow edge seat slides in rather than cropping).
            local bx = math.floor(cx - tw / 2)
            bx = math.max(felt_x + 4, math.min(bx, felt_x + felt_w - 4 - tw))

            Theme.setColor(Theme.bg.window, 0.9)
            love.graphics.rectangle("fill", bx, by, tw, th, Theme.space.radius)
            Theme.setColor(Theme.border.soft)
            love.graphics.rectangle("line", bx, by, tw, th, Theme.space.radius)
            -- Gold text to match the gold cards it labels (one win language).
            Theme.setColor(Theme.currency.chip)
            love.graphics.printf(hand, bx, by + 2, tw, "center")
        end
    end

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
