-- views/GrindView.lua
--
-- The grind screen. Three-column layout:
--   • Top bar (50px) — bankroll, chips, run stats
--   • Left sidebar (Panel) — Tables tab with stake-add buttons + slot count.
--                             Phase 5 will add a Catalog tab here.
--   • Center grid — up to MAX_TABLES tiled table panels (2 cols × 3 rows).
--                   Each panel: stake header + [×] remove, last-N pill strip,
--                   live stat line, and a [⤴ next-stake] button when the
--                   next tier is unlocked + affordable.
--   • Right sidebar — Panel with Upgrades tab listing run-upgrade buttons,
--                     plus a fixed-position SHOVE button at the bottom.
--   • Floating text — `+$X` / `-$Y` over each table on hand resolution.
--
-- Mutation goes through GrindController. View hit-tests, dispatches intents.

local Theme          = require("views.Theme")
local Format         = require("utils.format")
local Panel          = require("views.Panel")
local CR             = require("views.ComponentRenderer")
local TablePanel     = require("views.TablePanel")
local TablePanelStats = require("views.TablePanelStats")
local Pop            = require("services.Pop")
local RollingValue   = require("services.RollingValue")
local CursorPool     = require("services.CursorPool")
local Icons          = require("views.Icons")
local IconText       = require("views.IconText")
local Denoms        = require("services.DenominationBreakdown")
local ChipData       = require("data.chips")
local FlightSystem   = require("services.FlightSystem")
local ChipFlight     = require("views.ChipFlight")
local ChipPile       = require("views.ChipPile")
local ClickFlash     = require("services.ClickFlash")
local TooltipSvc     = require("services.Tooltip")
local AnchorRegistry = require("services.AnchorRegistry")
local Button         = require("views.Button")
local LabelButton    = require("views.widgets.LabelButton")
local AwardGlow      = require("views.AwardGlow")
local Ghosts         = require("services.Ghosts")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local RunUpgrades    = require("data.run_upgrades")
local Catalog        = require("data.catalog")
local Constants      = require("data.constants")
local ShoveRate      = require("models.shove_rate")
local Decks          = require("models.Decks")
local OutcomeMath    = require("models.outcome_math")
local Lookups        = require("utils.lookups")

local GrindView = {}
GrindView.__index = GrindView

-- A stake is visible when its band's milestone is met. Delegates to
-- GrindController:stakeAvailable (the single source of truth) so the
-- add-table buttons and the win-chance / stack-rate range tooltips never
-- disagree. Low band is always on; mid/high/ultra gate behind shove /
-- anti-chip progression, and the whole non-low ladder is off in the
-- prototype build.
local function stakeVisible(view, stake)
    return view.controller:stakeAvailable(stake)
end


-- Layout values. The window-relative ones (TOP_BAR_H, LEFT_W, RIGHT_W,
-- CELL_W.*, BANKROLL_CELL_W, TOPBAR_LABEL_Y, TOPBAR_VALUE_Y) are
-- *recomputed* in recomputeLayout() at init and on resize — derived
-- from window dimensions + font metrics rather than hardcoded px so
-- the bar fits the active font and sidebars scale with the window.
-- Initial values here are placeholders; the first :_buildPanels call
-- replaces them.
local TOP_BAR_H            = 70
local LEFT_W               = 280
local RIGHT_W              = 250
local BANKROLL_CELL_W      = 160
-- Per-cell widths sized to fit each cell's actual label / value so
-- within-cluster cells pack tight against their content. Recomputed
-- in recomputeLayout from the active fonts. Order matches the draw
-- walk in _drawTopBar.
local CELL_W = {
    tied = 72, total = 72,                   -- money cluster
    chip = 48, achip = 48, shove = 56, deck = 50, -- run cluster (chip + deck are icon/sprite)
    tables = 72, focus = 56,                 -- workload cluster
}
local TOPBAR_LABEL_Y       = 8
local TOPBAR_VALUE_Y       = 32

local MARGIN               = 12
-- Button heights are recomputed from font metrics in recomputeLayout
-- so they grow/shrink with whatever sizes data/theme.lua picks.
local SHOVE_BTN_H          = 64
-- THE HOUSE poster (the captor) sits above the SHOVE button; hint
-- bubbles speak from it (views/HintView anchors to "house").
local HOUSE_H              = 92
local CASH_OUT_BTN_W       = 110
local CASH_OUT_BTN_H       = 36
local CATALOG_BTN_W        = 110
local CATALOG_BTN_H        = 36
local TOPBAR_BTN_GAP       = 8
local CLUSTER_GAP          = 24
local TOPBAR_PAD_X         = 16
-- Reserved band at the bottom of the center column for the bankroll
-- chip pile. Center grid shrinks vertically by this much. Sidebars are
-- unaffected — they keep running their full height.
-- How wide the bankroll pile may spread before it wraps onto rows behind
-- itself. It owns the full bottom band, so it can afford a long line.
local BANKROLL_PILE_COLS = 10
local BANKROLL_PILE_ROWS = 2

local BOTTOM_BAND_H        = 90
local PANEL_REMOVE_BTN_SIZE = 22
local PILL_H               = 18
local PILL_GAP             = 4
-- Table panel max dims — declared up here so recomputeLayout's
-- assignment lands on the same upvalue bestGridLayout reads (the
-- second declaration below would otherwise shadow this one and
-- recomputeLayout would silently set a global).
local PANEL_MAX_W = 520
local PANEL_MAX_H = 390

-- Recompute the window-relative layout values from current dimensions
-- and the active fonts. Called on init and on resize. Reassigns the
-- file-local upvalues above so every reference inside instance methods
-- picks up the new values automatically.
local function recomputeLayout(W, H, fonts, state)
    -- Float layout scale (smooth) — used for sizing visual elements
    -- so they grow with the window. Fonts use a separate INTEGER
    -- scale handled by FontService so they stay on the pixel grid.
    local FontService = require("services.FontService")
    local s = FontService.layoutScale(W, H)

    -- Table panel max dims grow with the layout scale. Base 520
    -- (matches the original cap) means at default 1600×900 the cap
    -- (650) is below the grid width (~768) so empty margin remains
    -- around the felt. At fullscreen 3840×2160 the cap scales to
    -- 1560 — visibly bigger felt while still leaving breathing room.
    PANEL_MAX_W = math.floor(520 * s)
    PANEL_MAX_H = math.floor(390 * s)

    -- Top-bar buttons + bottom band + table chrome bits scale too.
    SHOVE_BTN_H          = math.floor(64 * s)
    HOUSE_H              = math.floor(92 * s)
    -- Top-bar button widths are derived from the longest label in
    -- their font so they don't waste horizontal space the stat cells
    -- could use. fonts.sm at any scale already grew with the integer
    -- font scale.
    local longest = math.max(
        fonts.sm:getWidth("SETTINGS"),
        fonts.sm:getWidth("CATALOG"),
        fonts.sm:getWidth("CASH OUT"))
    local btn_pad_x = math.floor(28 * s)
    CASH_OUT_BTN_W       = longest + btn_pad_x
    CATALOG_BTN_W        = longest + btn_pad_x
    BOTTOM_BAND_H        = math.floor(90  * s)
    PANEL_REMOVE_BTN_SIZE = math.floor(22 * s)
    PILL_H               = math.floor(18 * s)
    PILL_GAP             = math.floor(4  * s)
    MARGIN               = math.floor(12 * s)
    TOPBAR_BTN_GAP       = math.floor(8  * s)
    CLUSTER_GAP          = math.floor(40 * s)
    TOPBAR_PAD_X         = math.floor(16 * s)

    -- Sidebars: window-fraction with absolute minimums. The minimum
    -- is NOT layout-scale-multiplied — at 720p the heading text on
    -- stake-add buttons ("+ $0.01/$0.02" + "+1 chip" badge) needs ~290
    -- px to fit on a single line at the design font size, and a
    -- scaled-down minimum (220 * 1.0) lets it wrap.
    LEFT_W  = math.max(290, math.floor(W * 0.18))
    RIGHT_W = math.max(320, math.floor(W * 0.22))

    -- Top bar height + label/value y-offsets derived from font heights.
    -- Padding kept minimal — pixel fonts already include leading inside
    -- getHeight() so extra px just produces visible empty space.
    local label_h = fonts.sm:getHeight()
    local value_h = fonts.md:getHeight()
    TOPBAR_LABEL_Y = 2
    TOPBAR_VALUE_Y = TOPBAR_LABEL_Y + label_h
    TOP_BAR_H      = TOPBAR_VALUE_Y + value_h + 2

    -- Top-bar buttons (CATALOG / CASH OUT) draw their text in fonts.sm,
    -- so size their height from sm + padding, not md.
    CASH_OUT_BTN_H = fonts.sm:getHeight() + 16
    CATALOG_BTN_H  = fonts.sm:getHeight() + 16

    -- Top-bar layout: each cell sized to its own label/value (the
    -- max of fonts.sm:getWidth(label) and fonts.md:getWidth(value))
    -- plus a small intrinsic pad. Cells inside a cluster draw flush,
    -- so within-cluster spacing equals just that intrinsic pad —
    -- which keeps it visually distinct from the larger CLUSTER_GAP
    -- between clusters (3 gaps: BANK|MONEY, MONEY|RUN, RUN|WORKLOAD).
    local button_zone = RIGHT_W
    local cell_pad    = math.floor(8 * s)
    local function cellW(label, value_ref)
        return math.max(
            math.ceil(fonts.sm:getWidth(label)),
            math.ceil(fonts.md:getWidth(value_ref))) + cell_pad
    end

    CELL_W.tied   = cellW("TIED UP", "$999.99")
    CELL_W.total  = cellW("TOTAL",   "$999.99")
    -- Chip cell is a prominent glyph + count (not a stacked label/value),
    -- so size it from the chip diameter + gap + the widest count.
    CELL_W.chip   = math.floor(TOP_BAR_H * 0.6) + math.floor(6 * s)
                    + math.ceil(fonts.md:getWidth("9999")) + cell_pad
    CELL_W.achip  = math.floor(TOP_BAR_H * 0.6) + math.floor(6 * s)
                    + math.ceil(fonts.md:getWidth("9999")) + cell_pad
    CELL_W.shove  = cellW("SHOVE",   "999%")
    -- Deck cell is a sprite chip, not a text value — size it from the
    -- label width plus a fixed icon footprint (~36px scaled). Only takes
    -- bar space when FEATURES.DECKS is on; the cluster collapses
    -- otherwise (the cells_total sum below excludes it).
    CELL_W.deck   = math.max(cellW("DECK", "L9"), math.floor(36 * s) + math.floor(8 * s))
    CELL_W.tables = cellW("TABLES",  "99 / 99")
    CELL_W.focus  = cellW("FOCUS",   "100%")


    local ideal_bankroll = math.ceil(fonts.lg:getWidth("$999.99K")) + math.floor(24 * s)
    local cells_total    = CELL_W.tied  + CELL_W.total
                         + CELL_W.chip  + CELL_W.shove
                         + CELL_W.tables + CELL_W.focus
    if state and state.shove_r2_won then
        cells_total = cells_total + CELL_W.achip
    end
    -- Reserve on the static flag, not Decks.systemUnlocked: the system
    -- unlocks mid-session (first gauntlet clear) and this only reruns on
    -- resize — reserving up front keeps the bar from reflowing under the
    -- player when the chip appears.
    if Constants.FEATURES and Constants.FEATURES.DECKS then
        cells_total = cells_total + CELL_W.deck
    end
    local ideal_total    = ideal_bankroll + cells_total + 3 * CLUSTER_GAP
    local available      = W - TOPBAR_PAD_X - button_zone

    if ideal_total <= available then
        BANKROLL_CELL_W = ideal_bankroll
    else
        -- Squeeze: scale bankroll + every cell + cluster gaps by
        -- the same ratio so the bar still fits without overlap.
        local ratio = available / ideal_total
        BANKROLL_CELL_W = math.max(80, math.floor(ideal_bankroll * ratio))
        for k, v in pairs(CELL_W) do CELL_W[k] = math.max(28, math.floor(v * ratio)) end
        CLUSTER_GAP     = math.max(8, math.floor(CLUSTER_GAP * ratio))
    end
end

-- ─── Construction ─────────────────────────────────────────────────────

function GrindView:new(game, controller)
    local state = game.state
    local self = setmetatable({
        game       = game,
        controller = controller,
        hit_boxes  = {},   -- per-frame click targets for non-Panel UI (table buttons, SHOVE)
        selected_gtype = "six_max",  -- which game-type sub-tab is showing in the Tables tab

        -- Tweened display values for the top-bar. Each frame these lerp
        -- toward their state.* targets so wins/losses flow smoothly instead
        -- of snapping the number. Initialised to current state so a first
        -- frame doesn't tween from 0.
        displayed_bankroll = state.bankroll       or 0,
        displayed_chips    = state.chips           or 0,
        displayed_anti_chips = state.anti_chips    or 0,
        displayed_tied     = controller:tiedUp(),
    }, GrindView)

    self:_buildPanels()
    return self
end

-- Smooth lerp helper for the top-bar number tween. ~95% catch-up in 0.4 s
-- with k = dt * 8; snaps when within a hundredth-cent so the displayed
-- value doesn't jitter forever near the target.
local function tweenNumber(curr, target, dt)
    local k = math.min(1, (dt or 0) * 8)
    local out = curr + (target - curr) * k
    if math.abs(target - out) < 0.005 then out = target end
    return out
end

function GrindView:_buildPanels()
    local W, H = love.graphics.getDimensions()
    recomputeLayout(W, H, self.game.fonts, self.game.state)

    self.left_panel = Panel:new(0, TOP_BAR_H, LEFT_W, H - TOP_BAR_H)
    self.left_panel:registerTab({
        id       = "tables",
        label    = "Tables",
        priority = 0,
        build    = function() return self:_buildTablesTabComponents() end,
    })
    -- Catalog tab removed — purchases now happen in views/CatalogModal.lua
    -- after each bust. The chip shop is only accessible between runs.

    -- Right panel reserves space at the bottom for the SHOVE button, a
    -- few px so the quick-reset button can straddle the shove's top edge
    -- without overlapping panel content, and THE HOUSE poster above that.
    local qr_reserve    = math.floor(18 * (self.game.ui_scale or 1))
    local house_reserve = HOUSE_H + MARGIN
    local right_panel_h = H - TOP_BAR_H - SHOVE_BTN_H - 2 * MARGIN
                          - qr_reserve - house_reserve
    self.right_panel = Panel:new(W - RIGHT_W, TOP_BAR_H, RIGHT_W, right_panel_h)
    self.right_panel:registerTab({
        id       = "upgrades",
        label    = "Upgrades",
        priority = 0,
        build    = function() return self:_buildUpgradesTabComponents() end,
    })
end

-- ─── Panel content builders (called every frame by Panel:draw) ────────────

-- Game-type sub-tab strip — 4 horizontal buttons at the top of the Tables
-- tab. Selecting one swaps which set of stake-add buttons render below.
-- Built as a `custom` ComponentRenderer entry so the row layout sits in
-- one component instead of stacking 4 separate buttons vertically.
function GrindView:_makeGameTypeStrip()
    -- Strip height tracks the active sm font + a tight pad. The pad
    -- DOESN'T multiply by ui_scale — at fullscreen the font itself
    -- already grew via the integer fontScale, so adding another
    -- 20*ui_scale on top doubled the band height. Plain pad keeps
    -- the buttons compact at every window size.
    local fh      = self.game.fonts.sm:getHeight()
    local STRIP_H = fh + 12
    local self_ref = self
    -- Per-gtype short blurb for the hover tooltip. Hardcoded next to
    -- where the strip is built so callers don't have to juggle a string
    -- table; the data file (data/game_types.lua) only carries gameplay
    -- knobs (seats, pace, dist_shifts), not UI copy.
    local GTYPE_BLURB = {
        six_max  = "6-Max — the baseline. Standard pace, 5 seated opponents, no pot-shape bias.",
        hu       = "Heads-Up — duel with one opponent. Fast pace, you win less often, but pots run deep both ways.",
        zoom     = "Zoom — fast hands, random opponents. Easier to win, but pots smaller overall.",
        mtt      = Constants.FEATURES.MTT_KO
                   and "8-max KO — sit down with 100bb chips. Hands play normally; seats bust at zero. Win it all or finish top-3 to cash."
                   or  {
                       "Tournament — 8 hands play out automatically. Win more hands to climb the payout ladder; lose one and the run ends.",
                       {  -- {chip} icon row: chips only come from winning all 8
                           measure = function(fonts) local f = fonts.sm
                               return IconText.measure("Winning all 8 also pays {chip}.", f), f:getHeight() end,
                           render  = function(x, y, fonts)
                               IconText.draw(self_ref.game,
                                   "Winning all 8 also pays {chip}.",
                                   x, y, fonts.sm, Theme.fg.heading, 1) end,
                       },
                   },
    }
    return {
        type = "custom",
        h    = STRIP_H,
        draw_fn = function(px, y, pw, _, game)
            local fonts = game.fonts
            local pad   = 6
            local strip_x = px + pad
            local strip_w = pw - pad * 2
            local n = #GameTypes
            local btn_w = strip_w / n
            for i, gt in ipairs(GameTypes) do
                local bx = strip_x + (i - 1) * btn_w
                local rect_w, rect_h = btn_w - 2, STRIP_H - 4
                local active = (gt.id == self_ref.selected_gtype)
                local id     = "gtype:" .. gt.id
                local hov    = game.hover.is("button", id) and not active
                local press  = ClickFlash.alpha("button", id)
                local label  = gt.short or gt.name
                Button.draw(bx, y, rect_w, rect_h, {
                    fill_color   = active and Theme.bg.widget_hover or Theme.bg.chrome,
                    border_color = active and Theme.border.strong
                                  or hov  and Theme.border.strong
                                  or Theme.border.default,
                    hovered      = hov,
                    press_alpha  = press,
                    depth        = 3,
                }, function(fx, fy, fw, fh)
                    Theme.setColor(active and Theme.fg.heading
                                  or hov  and Theme.fg.heading
                                  or Theme.fg.muted)
                    love.graphics.setFont(fonts.sm)
                    love.graphics.printf(label, fx,
                        fy + math.floor((fh - fonts.sm:getHeight()) * 0.5),
                        fw, "center")
                end)
                -- Chip-award pulse routed here when a bounty banks for a
                -- game type the player isn't currently viewing.
                AwardGlow.draw(id, bx, y, rect_w, rect_h)
            end
        end,
        hit_fn = function(px, y, pw, _, cx, cy)
            local pad = 6
            local strip_x = px + pad
            local strip_w = pw - pad * 2
            local n = #GameTypes
            local btn_w = strip_w / n
            for i, gt in ipairs(GameTypes) do
                local bx = strip_x + (i - 1) * btn_w
                if cx >= bx and cx < bx + btn_w - 2
                   and cy >= y and cy < y + STRIP_H - 4 then
                    local id = "gtype:" .. gt.id
                    -- Set hover + tooltip here so the dispatch flow reaches
                    -- both even though custom components don't have generic
                    -- post-hit-test logic in ComponentRenderer.
                    require("services.HoverService").set("button", id)
                    if GTYPE_BLURB[gt.id] then
                        local mx, my = love.mouse.getPosition()
                        TooltipSvc.set(GTYPE_BLURB[gt.id], mx, my)
                    end
                    return { id = id }
                end
            end
            return nil
        end,
    }
end

function GrindView:_buildTablesTabComponents()
    local state  = self.game.state
    local cap    = self.controller:tableSlotsCap()
    local active = self.controller.pool:count()

    local components = {}
    local s_ui = self.game.ui_scale or 1
    components[#components + 1] = {
        type = "label", style = "muted", text = "ADD TABLE",
        h = self.game.fonts.md:getHeight() + math.floor(10 * s_ui),
    }

    -- Game-type sub-tab strip.
    components[#components + 1] = self:_makeGameTypeStrip()
    components[#components + 1] = { type = "spacer", h = math.floor(4 * s_ui) }

    -- Stake-add buttons for the currently selected game type. Button id
    -- is composite "add_table:<stake>:<gtype>" so the dispatcher routes
    -- to controller:addTable(stake_id, game_type_id).
    local gtype_id  = self.selected_gtype
    local gtype_obj = Lookups.findById(GameTypes, gtype_id)
    -- Cursor perks gate the per-row cursor toggles, same two flags the
    -- per-table [D] / [R] header buttons read.
    local ctx       = self.controller and self.controller.ctx
    local cursor_on = (ctx and ctx.cursor_unlocked) or false
    local rebuy_on  = (ctx and ctx.cursor_rebuy_unlocked) or false
    for _, stake in ipairs(Stakes) do
        -- Bands gate the +ADD-TABLE buttons by milestone (mid after R1,
        -- high after R2, ultra once bought; see stakeVisible →
        -- controller:stakeAvailable). Tables from a save in a now-locked
        -- band still render through TablePanel and die on the next reset.
        if stakeVisible(self, stake) then
            local full         = active >= cap
            local cant_afford  = state.bankroll < (stake.buy_in or 0)
            local disabled     = full or cant_afford
            local affordable   = not disabled   -- can open this table right now

            -- $/h EV — only when the table can actually be opened. The
            -- bb-normalized value stays the color threshold so good/bad
            -- doesn't shift with stake size; bb/h itself is tooltip-only.
            local sub_left, sub_right, sub_color
            if full then
                sub_left, sub_right = "tables full (max " .. cap .. ")", ""
            else
                sub_right = string.format("buy-in $%.2f", stake.buy_in or 0)
                if affordable then
                    local ev = TablePanelStats.evPerHand(self.controller, stake, gtype_obj)
                    if ev then
                        -- Rolls like the per-table readouts; color from the
                        -- rolled value so tint and number always agree.
                        ev = RollingValue.get(
                            "btn_ev:" .. stake.id .. ":" .. gtype_id, ev)
                        local bb    = (stake.bb and stake.bb > 0) and stake.bb or 1
                        local ev_bb = ev / bb
                        sub_left  = TablePanelStats.evLabel(ev)
                        sub_color = (ev_bb > 0.05 and "good") or (ev_bb < -0.05 and "error") or "muted"
                    end
                end
            end

            -- Chip-bounty badge: green + full gold/purple once banked this run; greyed
            -- while still unearned, greyer still when you can't even buy in.
            local is_achip = (stake.band == "high" or stake.band == "ultra")
            local banked, award, icon_id, border_color
            if is_achip then
                banked = self.controller:antiBountyBanked(stake.id, gtype_id)
                award  = self.controller:antiBountyAward(stake.id)
                icon_id = "achip"
                border_color = banked and { 0.65, 0.35, 0.95 } or nil
            else
                banked = self.controller:bountyBanked(stake.id, gtype_id)
                award  = self.controller:bountyAward(stake.id)
                icon_id = "chip"
                border_color = banked and Theme.currency.chip or nil
            end

            local chip_text = string.format("+%d", award)
            local chip_color_tok, chip_shade
            if banked then
                chip_color_tok, chip_shade = "good", 1.0
            elseif cant_afford then
                chip_color_tok, chip_shade = "faint", 0.15
            else
                chip_color_tok, chip_shade = "muted", 0.35
            end

            -- Trailing QOL strip: acts on the tables THIS row opened, not on
            -- the whole pool. Always present, greyed when the row has no open
            -- tables — appearing on the first buy-in would shove the row's
            -- text sideways every time you opened or closed a table.
            local open_n, deal_muted, rebuy_muted =
                self.controller:typeCursorState(stake.id, gtype_id)
            local none    = open_n == 0
            local suffix  = ":" .. stake.id .. ":" .. gtype_id
            local actions = {
                -- "x", the same glyph and neutral ink the per-table close
                -- button uses. Closing a table IS how you cash it out, so the
                -- group control must not invent a different symbol.
                { id = "cash_out_type" .. suffix, label = "X",
                  tint_token = Theme.fg.heading,
                  disabled = none,
                  tooltip = (not none) and string.format("Cash out all %d %s %s table%s",
                                open_n, stake.display_name,
                                (gtype_obj and gtype_obj.name) or "",
                                open_n == 1 and "" or "s") },
            }
            -- Cursor controls mirror the per-table [D] / [R] header toggles,
            -- applied to the whole group. Same letters and same colours so
            -- the two read as the same control.
            if cursor_on then
                actions[#actions + 1] = {
                    id = "type_cursor_deal" .. suffix, label = "D",
                    tint_token = Theme.status.good,
                    disabled = none,
                    muted = (not none) and deal_muted >= open_n,
                    tooltip = none and nil
                              or (deal_muted >= open_n)
                              and "Let cursors deal these tables"
                              or  "Stop cursors dealing these tables",
                }
                if rebuy_on then
                    actions[#actions + 1] = {
                        id = "type_cursor_rebuy" .. suffix, label = "R",
                        tint_token = Theme.status.error,
                        disabled = none,
                        muted = (not none) and rebuy_muted >= open_n,
                        tooltip = none and nil
                                  or (rebuy_muted >= open_n)
                                  and "Let cursors rebuy these tables"
                                  or  "Stop cursors rebuying these tables",
                    }
                end
            end

            components[#components + 1] = {
                type     = "button",
                actions  = actions,
                id       = "add_table:" .. stake.id .. ":" .. gtype_id,
                -- Named hint-anchor (same string as the id) so tutorial
                -- hints can highlight this button. Once this combo has
                -- banked its bounty, the "+N {chip}" badge also registers
                -- as "chip_badge:banked" (any banked button; last drawn
                -- wins) for the chip-teaching hints.
                anchor       = "add_table:" .. stake.id .. ":" .. gtype_id,
                badge_anchor = banked and "chip_badge:banked" or nil,
                disabled = disabled,
                -- Gold/Purple trim once this (stake, type) has banked its bounty this run
                border_color = border_color,
                -- EV breakdown tooltip only when the table can be opened.
                tooltip  = affordable
                           and TablePanelStats.breakdownLinesFor(self.controller, stake, gtype_obj)
                           or nil,
                lines = {
                    {
                        text  = "+ " .. stake.display_name, style = "heading",
                        right = chip_text, right_color_token = chip_color_tok,
                        right_icon = icon_id, right_icon_shade = chip_shade,
                    },
                    { text = sub_left, style = "small", color_token = sub_color,
                      right = sub_right, right_color_token = "muted" },
                },
            }
        end
    end

    -- Tables count / focus / capacity all live in the top-bar workload
    -- cluster now (the sidebar duplicate was redundant). The local `active`
    -- and `cap` reads above still drive the per-button "tables full" /
    -- "buy-in unaffordable" disabled states.

    return components
end

-- Look up the display name of a catalog item id (for "Requires X" labels).
local function catalogName(item_id)
    if not item_id then return nil end
    for _, item in ipairs(Catalog) do
        if item.id == item_id then return item.name end
    end
    return item_id
end

-- Upgrades whose effect "fills" toward a per-stake cap get a dynamic "next
-- level" tooltip — built fresh from the outcome model so it reflects real
-- upgrades/perks and whatever stakes exist. Both builders omit non-changing
-- stakes (only show what the level moves) and short-circuit to "MAX".

-- Per-stake cell value: "MAX" once the dimension's fill is past this stake's
-- window, "+N%" while it's still moving, "-" when the gain rounds to nothing.
local function _cell(capped, delta)
    if capped then return "MAX" end
    if delta >= 0.005 then return string.format("+%d%%", math.floor(delta * 100 + 0.5)) end
    return "-"
end

local function _capped(ctx, fill_key, gt, stake)
    local window = stake.fill_window
    return window ~= nil
        and OutcomeMath.sumFills(ctx[fill_key], gt) >= (window.complete or 0)
end

-- Win chance: the fill delta cancels the per-mode additive shift, so a single
-- mode-agnostic value per stake is honest. Every stake shown (MAX / +N% / -).
local function _winChanceRows(view, ctx, nextctx)
    local f     = view.game.fonts.sm
    local gtype = Lookups.findById(GameTypes, "six_max") or GameTypes[1]
    local data, name_w = {}, 0
    for _, stake in ipairs(Stakes) do
        if stakeVisible(view, stake) then
            local cw  = OutcomeMath.buildOutcome(ctx,     gtype, stake)
            local nw  = OutcomeMath.buildOutcome(nextctx, gtype, stake)
            local txt = _cell(_capped(ctx, "win_chance_fills", gtype, stake), nw - cw)
            data[#data + 1] = { name = stake.display_name or stake.id, txt = txt }
            name_w = math.max(name_w, f:getWidth(stake.display_name or stake.id))
        end
    end

    local col  = name_w + math.floor(f:getHeight() * 1.4)
    local rows = { { text = "Win chance, next level:", style = "sm", color_token = "muted" } }
    for _, e in ipairs(data) do
        local name, txt = e.name, e.txt
        local dim = (txt == "MAX" or txt == "-")
        rows[#rows + 1] = {
            measure = function(_) return col + f:getWidth(txt), f:getHeight() end,
            render  = function(x, y, _)
                love.graphics.setFont(f)
                Theme.setColor(Theme.fg.muted); love.graphics.print(name, x, y)
                Theme.setColor(dim and Theme.fg.faint or Theme.fg.heading)
                love.graphics.print(txt, x + col, y)
            end,
        }
    end
    return rows
end

-- Stack rate: the win-dist renormalization makes the stack-tier delta
-- genuinely mode-dependent, so it's a per-mode grid (one column per game
-- type). Every stake shown; each cell is MAX / +N% / -.
local function _stackRateRows(view, ctx, nextctx)
    local f      = view.game.fonts.sm
    local gtypes = GameTypes

    local data, name_w = {}, 0
    for _, stake in ipairs(Stakes) do
        if stakeVisible(view, stake) then
            local cells = {}
            for i, gt in ipairs(gtypes) do
                local _, cd = OutcomeMath.buildOutcome(ctx,     gt, stake)
                local _, nd = OutcomeMath.buildOutcome(nextctx, gt, stake)
                cells[i] = _cell(_capped(ctx, "win_dist_fills", gt, stake),
                                 (nd.jackpot or 0) - (cd.jackpot or 0))
            end
            data[#data + 1] = { name = stake.display_name or stake.id, cells = cells }
            name_w = math.max(name_w, f:getWidth(stake.display_name or stake.id))
        end
    end

    local gap      = math.floor(f:getHeight() * 0.8)
    local name_col = name_w + gap
    local col_w    = f:getWidth("+99%")
    for _, gt in ipairs(gtypes) do col_w = math.max(col_w, f:getWidth(gt.short or gt.id)) end
    col_w = col_w + gap
    local total_w  = name_col + #gtypes * col_w

    local rows = {
        {   -- header: stack icon (the word "Stack" reads as nothing) + label
            measure = function(_) return IconText.measure("{stack} rate, next level:", f), f:getHeight() end,
            render  = function(x, y, _)
                IconText.draw(view.game, "{stack} rate, next level:", x, y, f, Theme.fg.muted)
            end,
        },
        {   -- column header: game-type short names
            measure = function(_) return total_w, f:getHeight() end,
            render  = function(x, y, _)
                love.graphics.setFont(f)
                Theme.setColor(Theme.fg.muted)
                for i, gt in ipairs(gtypes) do
                    love.graphics.print(gt.short or gt.id, x + name_col + (i - 1) * col_w, y)
                end
            end,
        },
    }
    for _, row in ipairs(data) do
        local name, cells = row.name, row.cells
        rows[#rows + 1] = {
            measure = function(_) return total_w, f:getHeight() end,
            render  = function(x, y, _)
                love.graphics.setFont(f)
                Theme.setColor(Theme.fg.heading)
                love.graphics.print(name, x, y)
                for i, c in ipairs(cells) do
                    Theme.setColor((c == "MAX" or c == "-") and Theme.fg.faint or Theme.fg.heading)
                    love.graphics.print(c, x + name_col + (i - 1) * col_w, y)
                end
            end,
        }
    end
    return rows
end

local RANGE_TOOLTIP = {
    win_chance = { keys = { "win_chance_fills" },                  build = _winChanceRows },
    win_dist   = { keys = { "win_dist_fills", "loss_dist_fills" }, build = _stackRateRows },
}

-- One IconText tooltip row for a blurb line (heading color; {icon} markers
-- resolve to real glyphs). Single line — blurbs are authored pre-wrapped as a
-- list of short strings in data/run_upgrades.lua.
local function _blurbRow(view, str)
    local f = view.game.fonts.sm
    return {
        measure = function(_) return IconText.measure(str, f), f:getHeight() end,
        render  = function(x, y, _) IconText.draw(view.game, str, x, y, f, Theme.fg.heading) end,
    }
end

-- Build an upgrade's hover tooltip: a leading plain-language blurb ("what it
-- does", icons where applicable) followed by the per-stake "next level" range
-- grid when the upgrade carries one. Maxed upgrades show the blurb + "MAX";
-- the grid builders drop non-changing stakes so the table only shows what the
-- next level actually moves. Returns nil only when there's nothing to show.
function GrindView:_buildRangeTooltip(up)
    local rows = {}

    local blurb = up.tooltip_blurb
    if type(blurb) == "string" then blurb = { blurb } end
    if blurb then
        for _, line in ipairs(blurb) do rows[#rows + 1] = _blurbRow(self, line) end
    end

    local spec = up.tooltip_metric and RANGE_TOOLTIP[up.tooltip_metric]
    if spec then
        if self.controller:getRunUpgradeLevel(up.id) >= self.controller:getRunUpgradeMaxLevel(up) then
            rows[#rows + 1] = { text = "MAX", style = "sm", color_token = "muted" }
        else
            -- blank spacer between the blurb and the range grid
            if #rows > 0 then rows[#rows + 1] = { text = "", style = "sm", color_token = "muted" } end

            local ctx     = self.controller.ctx or {}
            local nextctx = {}
            for k, v in pairs(ctx) do nextctx[k] = v end
            for _, key in ipairs(spec.keys) do
                local list = {}
                for _, d in ipairs(ctx[key] or {}) do list[#list + 1] = d end
                list[#list + 1] = { strength = 1 }
                nextctx[key] = list
            end
            for _, r in ipairs(spec.build(self, ctx, nextctx)) do rows[#rows + 1] = r end
        end
    end

    if #rows == 0 then return nil end
    return rows
end

function GrindView:_buildUpgradesTabComponents()
    local state = self.game.state
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local components = {}
    components[#components + 1] = {
        type = "label", style = "muted", text = "UPGRADES",
        h = self.game.fonts.md:getHeight() + 10,
    }

    for _, up in ipairs(RunUpgrades) do
        local locked = up.requires and not owned[up.requires]
        if not (locked and up.requires_hide) then
            local level     = self.controller:getRunUpgradeLevel(up.id)
            local max_lvl   = self.controller:getRunUpgradeMaxLevel(up)
            local at_max    = level >= max_lvl
            local next_cost = self.controller:getRunUpgradeNextCost(up)
            local cant_afford = next_cost and state.bankroll < next_cost
            -- Strand block: even if affordable, refuse purchases that would
            -- leave the player unable to open a table — upgrades aren't
            -- refundable, so this would silently end the run.
            local would_strand = (not at_max) and (not locked) and (not cant_afford)
                                 and self.controller:wouldStrandRun(next_cost)
            local disabled  = at_max or cant_afford or locked or would_strand

            -- 2-line button:
            --   [name (heading)            | level (heading) ]
            --   [description (small)       | cost (small)    ]
            -- Locked / maxed states collapse the right column to a
            -- single status string on line 1.
            local level_text, cost_text, desc_text
            desc_text = up.description or ""
            if locked then
                level_text = "Requires " .. catalogName(up.requires)
                cost_text  = ""
            elseif at_max then
                level_text = string.format("MAX %d/%d", level, max_lvl)
                cost_text  = ""
            else
                level_text = string.format("Lv %d/%d", level, max_lvl)
                cost_text  = string.format("$%.2f", next_cost or 0)
            end
            if would_strand then
                desc_text = "open or rebuy a table first — buying now ends the run"
            end

            -- The Cursor upgrade owns the GLOBAL cursor controls: same two
            -- toggles as the per-stake rows, scoped to every open table. They
            -- hang off this row because it is the thing that made cursors
            -- exist, so that is where you look for their master switch.
            local up_actions
            if up.id == "box_of_mice" then
                local ctx = self.controller and self.controller.ctx
                if ctx and ctx.cursor_unlocked then
                    local total, deal_muted, rebuy_muted =
                        self.controller:typeCursorState(nil, nil)
                    local none = total == 0
                    up_actions = { {
                        id = "type_cursor_deal", label = "D",
                        tint_token = Theme.status.good,
                        disabled = none,
                        muted = (not none) and deal_muted >= total,
                        tooltip = none and nil
                                  or (deal_muted >= total)
                                  and "Let cursors deal every table"
                                  or  "Stop cursors dealing any table",
                    } }
                    if ctx.cursor_rebuy_unlocked then
                        up_actions[#up_actions + 1] = {
                            id = "type_cursor_rebuy", label = "R",
                            tint_token = Theme.status.error,
                            disabled = none,
                            muted = (not none) and rebuy_muted >= total,
                            tooltip = none and nil
                                      or (rebuy_muted >= total)
                                      and "Let cursors rebuy every table"
                                      or  "Stop cursors rebuying any table",
                        }
                    end
                end
            end

            components[#components + 1] = {
                type     = "button",
                actions  = up_actions,
                id       = "buy_runup_" .. up.id,
                -- Named hint-anchor (same string as the id) so tutorial
                -- hints can highlight this card.
                anchor   = "buy_runup_" .. up.id,
                disabled = disabled,
                tooltip  = self:_buildRangeTooltip(up),
                icon     = up.icon,   -- icon id (data/icons); drawn when art ships
                lines = {
                    { text = up.name, style = "heading", right = level_text },
                    {
                        text  = desc_text, style = "small",
                        right = cost_text,
                    },
                },
            }
        end
    end

    return components
end

-- ─── Per-frame update + hover ─────────────────────────────────────────────

function GrindView:update(dt)
    local mx, my = love.mouse.getPosition()
    self.left_panel:update(my)
    self.right_panel:update(my)
    self.left_panel:updateHover(mx, my, self.game)
    self.right_panel:updateHover(mx, my, self.game)

    -- Chip-bounty fanfare: the moment a (stake, gtype) bounty first banks
    -- this run, pulse its add-table button gold — or, if the player isn't on
    -- that game type's sub-tab (the button isn't shown), pulse the game-type
    -- tab instead so the cue still lands. Swept across every combo so it fires
    -- exactly when the chip is earned.
    self._bounty_glow_seen = self._bounty_glow_seen or {}
    local prime = not self._bounty_glow_primed   -- first sweep only syncs
    for _, stake in ipairs(Stakes) do
        for _, gt in ipairs(GameTypes) do
            local key    = stake.id .. ":" .. gt.id
            local banked = self.controller:bountyBanked(stake.id, gt.id)
            if banked and not prime and not self._bounty_glow_seen[key] then
                if gt.id == self.selected_gtype then
                    AwardGlow.flash("add_table:" .. key)
                else
                    AwardGlow.flash("gtype:" .. gt.id)
                end
            end
            self._bounty_glow_seen[key] = banked
        end
    end
    self._bounty_glow_primed = true

    -- Quick-reset button (overlaps the shove) — explain it on hover. Rendered
    -- as IconText rows so the {chip} glyph shows instead of the word.
    if self.controller:canQuickReset() then
        local qr = self:_quickResetButtonRect()
        if mx >= qr.x and mx < qr.x + qr.w and my >= qr.y and my < qr.y + qr.h then
            local function iconRow(str)
                return {
                    render  = function(rx, ry, fonts)
                        IconText.draw(self.game, str, rx, ry, fonts.sm, Theme.fg.heading)
                    end,
                    measure = function(fonts)
                        return IconText.measure(str, fonts.sm), fonts.sm:getHeight()
                    end,
                }
            end
            TooltipSvc.set({
                iconRow("Banks your {chip} and starts a fresh $2 stake."),
                iconRow("No Shove — for when you're broke and stuck."),
            }, mx, my)
        end
    end

    -- Hit-test components for hover (writes "button" namespace into
    -- HoverService AND stashes any comp.tooltip via Tooltip.set).
    for _, panel in ipairs({ self.left_panel, self.right_panel }) do
        local comps = panel:getComponents()
        if comps then
            local cy = panel:toContentY(my)
            CR.hitTest(comps, panel.x, panel.w, mx, cy, self.game)
        end
    end

    -- Center-grid hit_boxes: same hover-walk for tooltips AND for the
    -- "hit" HoverService namespace so TablePanel button renderers can
    -- light up on hover (mirroring how ComponentRenderer treats sidebar
    -- buttons). The hit_boxes list is populated by the previous frame's
    -- draw — 1-frame stale, invisible at 60 fps. Last hit_box wins.
    for _, hb in ipairs(self.hit_boxes) do
        if mx >= hb.x and mx < hb.x + hb.w
           and my >= hb.y and my < hb.y + hb.h then
            if hb.action and hb.idx then
                self.game.hover.set("hit", hb.action .. ":" .. hb.idx)
            end
            if hb.tooltip then
                TooltipSvc.set(hb.tooltip, mx, my)
            end
        end
    end

    -- SHOVE button hover tooltip (direct rect — no hit_box entry). Leads
    -- with what a shove actually does (all-in for the bankroll, ends the
    -- run, prestige), then the {chip} the run will bank (mirrors the "+N"
    -- readout on the button), the rate breakdown, and a "click to lock".
    -- Silent while the button is still locked (TUTORIAL reveal) — a
    -- greyed button shouldn't pitch its own click.
    local sb = self:_shoveButtonRect()
    if self.controller:shoveUnlocked()
       and mx >= sb.x and mx < sb.x + sb.w and my >= sb.y and my < sb.y + sb.h then
        local state = self.game.state
        local ctx = (self.controller and self.controller.ctx) or {}
        local rates = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
        local pending    = state.chips_this_run or 0
        local chip_line  = string.format("Banks +%d {chip} for the catalog.", pending)
        local chip_color = (pending > 0) and Theme.status.good or Theme.fg.muted
        local game       = self.game
        local lines = {
            { style = "sm", color_token = "muted",
              text = "Bet everything on one all-in hand at the rate below."
                  .. " Winning beats the prototype (you can keep playing"
                  .. " after). Either way you bank this run's chips to spend"
                  .. " in the catalog on permanent upgrades, then a new run"
                  .. " starts." },
            { measure = function(fonts) local f = fonts.sm
                  return IconText.measure(chip_line, f), f:getHeight() end,
              render  = function(x, y, fonts)
                  IconText.draw(game, chip_line, x, y, fonts.sm, chip_color, 1) end },
        }
        for _, r in ipairs(ShoveRate.formatBreakdown(rates)) do lines[#lines + 1] = r end
        lines[#lines + 1] = "Click to lock this rate."
        TooltipSvc.set(lines, mx, my)
    end

    -- Cash-Out-All button hover tooltip. Same direct-rect treatment as
    -- SHOVE — sits in the top bar above the panels, not a hit_box entry.
    local cb = self:_cashOutButtonRect()
    if mx >= cb.x and mx < cb.x + cb.w
       and my >= cb.y and my < cb.y + cb.h then
        local pool_count = self.controller.pool:count()
        if pool_count > 0 then
            TooltipSvc.set(
                "Cash out all tables — refunds each table's current"
                .. " stack to your bankroll.", mx, my)
        else
            TooltipSvc.set("No tables open to cash out.", mx, my)
        end
    end

    -- TIED UP cell hover tooltip — explains where that money is.
    local tr = self._tied_cell_rect
    if tr and mx >= tr.x and mx < tr.x + tr.w and my >= tr.y and my < tr.y + tr.h then
        TooltipSvc.set("Currently held in tables.", mx, my)
    end

    -- Top-bar SHOVE cell hover tooltip — full breakdown of the live
    -- shove-rate. Rect is stashed by _drawTopBar (1-frame stale); nil
    -- while the shove hasn't revealed itself (TUTORIAL gate).
    local sh = self._shove_cell_rect
    if sh and mx >= sh.x and mx < sh.x + sh.w and my >= sh.y and my < sh.y + sh.h then
        local state = self.game.state
        local ctx = (self.controller and self.controller.ctx) or {}
        local rates = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
        TooltipSvc.set(ShoveRate.formatBreakdown(rates), mx, my)
    end

    -- Top-bar DECK chip hover tooltip — name + level + bonus + how to
    -- gain XP + progress + a footer note that all banked decks stack and
    -- a click hint pointing at the roster modal. Only fires when
    -- the deck system has unlocked (the cell rect is nil otherwise).
    local dr = self._deck_cell_rect
    if dr and mx >= dr.x and mx < dr.x + dr.w and my >= dr.y and my < dr.y + dr.h then
        local state = self.game.state
        local active_id = state.active_deck_id
        local spec = active_id and Decks.specById(active_id)
        if spec then
            local level = (state.deck_levels and state.deck_levels[active_id]) or 0
            local xp    = (state.deck_xp and state.deck_xp[active_id]) or 0
            local into, span = Decks.progressInLevel(spec, level, xp)
            local lines = {
                spec.name or active_id,
                string.format("L%d / %d  ·  %s",
                    level, spec.max_level, spec.bonus_text or ""),
            }
            if spec.capstone and spec.capstone.text then
                lines[#lines + 1] = "Capstone: " .. spec.capstone.text
            end
            lines[#lines + 1] = spec.xp_action_text or ""
            if span then
                lines[#lines + 1] = string.format("%d / %d XP to L%d",
                    math.floor(into), math.floor(span), level + 1)
            else
                lines[#lines + 1] = "MAXED"
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Only the active deck earns XP."
            lines[#lines + 1] = "All unlocked decks' bonuses still apply,"
            lines[#lines + 1] = "active or not. Swap at shove to train"
            lines[#lines + 1] = "a different one."
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Click to view your full roster."
            TooltipSvc.set(lines, mx, my)
        end
    end

    -- Top-bar workload cluster (TABLES · FOCUS) hover tooltip. Explains
    -- what the "N / cap" reading means, what FOCUS does, and the
    -- penalty math the inline cells deliberately don't surface.
    local wr = self._workload_rect
    if wr and mx >= wr.x and mx < wr.x + wr.w and my >= wr.y and my < wr.y + wr.h then
        local cap        = self.controller:tableSlotsCap()
        local focus_cap  = self.controller:currentFocusCapacity()
        local penalty    = Constants.GAMEPLAY.FOCUS_BASE_PENALTY
        local floor_v    = Constants.GAMEPLAY.FOCUS_FLOOR
        local ctx        = (self.controller and self.controller.ctx) or {}
        local reduce     = ctx.focus_penalty_reduce_mult or 1
        local eff_pen    = penalty * reduce
        TooltipSvc.set({
            "TABLES — currently open / focus capacity.",
            "FOCUS — multiplier on every $ you win or lose.",
            string.format("Stays 100%% at or under %d tables.", focus_cap),
            string.format("Each table over capacity drops focus by %.0f%% (min %.0f%%).",
                          eff_pen * 100, floor_v * 100),
            string.format("Hard cap: %d tables.", cap),
        }, mx, my)
    end

    -- Tween top-bar numbers toward live state values.
    local state = self.game.state
    self.displayed_bankroll = tweenNumber(self.displayed_bankroll, state.bankroll,            dt)
    self.displayed_chips    = tweenNumber(self.displayed_chips,    state.chips,               dt)
    self.displayed_anti_chips = tweenNumber(self.displayed_anti_chips or 0, state.anti_chips or 0, dt)
    self.displayed_tied     = tweenNumber(self.displayed_tied,     self.controller:tiedUp(),  dt)

    -- Drain the controller's chip-burst queue. Controller produces denomination
    -- indices and source/dest pairs; the view delegates to ChipFlight which
    -- wraps the render-closure composition + FlightSystem dispatch. Keeps
    -- controller→view dependencies out of controllers/GrindController.lua
    -- and shares the same path the script's per-event handlers use.
    local bursts = self.controller:drainBursts()
    for _, b in ipairs(bursts) do
        if b.kind == "scatter" then
            -- No destination — form the pile at b.source and blow it apart.
            ChipFlight.explodeStack(b.source[1], b.source[2], b.chips, b.options)
        elseif b.kind == "stack" then
            -- Pile to pile: the chips leave one collection and join the
            -- other. b.options carries the ChipPile keys the controller
            -- built from the table's anchor keys; b.chips is the fallback
            -- composition for when the source end has no pile.
            local o = b.options or {}
            o.chips = b.chips
            ChipFlight.transfer(b.source, b.dest, o)
        else
            ChipFlight.flyChipsList(b.source, b.dest, b.chips, b.options)
        end
    end
end

-- ─── Top bar ───────────────────────────────────────────────────────────

-- Hybrid: precise to two decimals under $1k (so the readout never
-- overstates what's purchasable), abbreviated K/M/B at $1k+ (so the
-- top-bar cluster stays narrow). TablePanel uses Format.moneyExact
-- directly because per-table readouts want the precise integer instead.
local function moneyText(n)
    if math.abs(n or 0) < 1000 then return Format.moneyExact(n) end
    return Format.money(n)
end

local function chipsText(n)
    if not n or n < 1 then return "0" end
    return Format.formatBig(math.floor(n))
end

-- Draws "LABEL" (sm, muted) on top and the value (md, given color)
-- below at the cell's left edge. Keeps every non-bankroll cell visually
-- identical so the eye scans cleanly across the bar. md (not lg) for
-- values because lg=48 overflows the 72px cell width — only bankroll
-- (its own fat cell) gets the lg pop.
-- Optional `icon_fn(ix, iy, size)` draws a glyph in the label slot and
-- returns true when it rendered; if so, the text label is skipped. When
-- it returns false/nil (e.g. a not-yet-shipped sprite) the text label
-- still draws, so a cell never loses its identity waiting on art.
-- value_scale (optional, default 1): a transient grow/pop applied to JUST the
-- value number (scaled about its own center) so a stat can flag a change
-- without disturbing its label.
local function drawStatCell(x, w, label, value, value_color, fonts, icon_fn, value_scale)
    local drew_icon = false
    if icon_fn then
        drew_icon = icon_fn(x, TOPBAR_LABEL_Y, fonts.sm:getHeight()) and true or false
    end
    if not drew_icon then
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.fg.muted)
        love.graphics.print(label, x, TOPBAR_LABEL_Y)
    end

    love.graphics.setFont(fonts.md)
    Theme.setColor(value_color)
    if value_scale and value_scale ~= 1 then
        local vcx = x + fonts.md:getWidth(value) / 2
        local vcy = TOPBAR_VALUE_Y + fonts.md:getHeight() / 2
        love.graphics.push()
        love.graphics.translate(vcx, vcy)
        love.graphics.scale(value_scale, value_scale)
        love.graphics.translate(-vcx, -vcy)
        love.graphics.print(value, x, TOPBAR_VALUE_Y)
        love.graphics.pop()
    else
        love.graphics.print(value, x, TOPBAR_VALUE_Y)
    end
end

-- Draws the active-deck card-back chip at the given x, in a `w`-wide
-- column. Returns the cell hit rect for hover-tooltip dispatch in
-- update(). Caller should only invoke this once the deck system unlocked.
function GrindView:_drawDeckCell(x, w, fonts)
    local state = self.game.state
    local active_id = state.active_deck_id
    local spec = active_id and Decks.specById(active_id)
    local cell_rect = { x = x, y = 0, w = w, h = TOP_BAR_H }
    if not spec then return cell_rect end

    local s = self.game.ui_scale or 1
    local sprite = self.game.sprite_loader:getSprite(spec.sprite)

    -- Icon sized to fit the bar height with a small inset. Maintains a
    -- 2.5:3.5 card-shaped aspect ratio so it reads as a card back even
    -- when the texture below is missing.
    local inset = math.floor(4 * s)
    local icon_h = TOP_BAR_H - inset * 2
    local icon_w = math.floor(icon_h * 2.5 / 3.5)
    local icon_x = x + math.floor((w - icon_w) / 2)
    local icon_y = inset

    local level = (state.deck_levels and state.deck_levels[active_id]) or 0

    if sprite then
        local sx = icon_w / sprite:getWidth()
        local sy = icon_h / sprite:getHeight()

        -- Shaders for level progression
        local ShaderRegistry = require("services.ShaderRegistry")
        local active_shader = nil
        if level == 0 then
            active_shader = ShaderRegistry.get("dirty")
        elseif level == 5 then
            active_shader = ShaderRegistry.get("foil")
            if active_shader then
                active_shader:send("u_time", self.game.time.total_time)
            end
        end

        if active_shader then
            love.graphics.setShader(active_shader)
        end

        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, icon_x, icon_y, 0, sx, sy)

        if active_shader then
            love.graphics.setShader()
        end
    else
        -- Fallback rect with a "?" marker if the asset failed to load.
        Theme.setColor(Theme.bg.sunken)
        love.graphics.rectangle("fill", icon_x, icon_y, icon_w, icon_h, 2)
        Theme.setColor(Theme.fg.faint)
        love.graphics.setFont(fonts.sm)
        love.graphics.printf("?", icon_x,
            icon_y + math.floor((icon_h - fonts.sm:getHeight()) / 2),
            icon_w, "center")
    end

    -- Draw border for level 2, 3, 4 active deck
    if level >= 2 and level <= 4 then
        local border_colors = {
            [2] = { 0.72, 0.45, 0.20, 1.0 }, -- Bronze
            [3] = { 0.80, 0.80, 0.85, 1.0 }, -- Silver
            [4] = { 0.98, 0.82, 0.12, 1.0 }, -- Gold
        }
        local bc = border_colors[level]
        local bw = math.max(2, math.floor(4 * s))
        local inset = math.floor(bw / 2)
        love.graphics.setLineWidth(bw)
        Theme.setColor(bc)
        love.graphics.rectangle("line", icon_x + inset, icon_y + inset, icon_w - inset * 2, icon_h - inset * 2, 2)
        love.graphics.setLineWidth(1)
    end

    -- Level badge overlay (bottom-right of the icon). Compact "L3" tag
    -- so the active level reads at a glance without the tooltip.
    local level = (state.deck_levels and state.deck_levels[active_id]) or 0
    local lvl_text = "L" .. tostring(level)
    love.graphics.setFont(fonts.sm)
    local lvl_w = fonts.sm:getWidth(lvl_text) + math.floor(6 * s)
    local lvl_h = fonts.sm:getHeight() + math.floor(2 * s)
    local lvl_x = icon_x + icon_w - lvl_w + math.floor(2 * s)
    local lvl_y = icon_y + icon_h - lvl_h + math.floor(2 * s)
    Theme.setColor(Theme.bg.window, 0.85)
    love.graphics.rectangle("fill", lvl_x, lvl_y, lvl_w, lvl_h, 2)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(lvl_text, lvl_x + math.floor(3 * s),
                        lvl_y + math.floor(1 * s))

    return cell_rect
end

function GrindView:_drawTopBar(W)
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", 0, 0, W, TOP_BAR_H)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("fill", 0, TOP_BAR_H - 1, W, 1)

    local fonts = self.game.fonts
    local state = self.game.state

    -- Tweened display values (set in :update each frame). Reading these
    -- instead of state.* gives a smooth count-up/down after a hand.
    local d_bank = self.displayed_bankroll or state.bankroll
    local d_chips = self.displayed_chips or state.chips
    local d_tied = self.displayed_tied     or self.controller:tiedUp()

    -- Tint the bankroll while a tween is in progress: green when counting
    -- up (target > displayed), red when counting down.
    local bankroll_tint = Theme.fg.heading
    local diff_bank = (state.bankroll or 0) - d_bank
    if math.abs(diff_bank) > 0.01 then
        bankroll_tint = (diff_bank > 0) and Theme.status.good or Theme.status.error
    end

    -- BANKROLL cluster — solo, lg font. The big spendable number.
    -- Center vertically in the bar.
    Theme.setColor(bankroll_tint)
    love.graphics.setFont(fonts.lg)
    local bank_y = math.floor((TOP_BAR_H - fonts.lg:getHeight()) * 0.5)
    local bank_str = moneyText(d_bank)
    love.graphics.print(bank_str, TOPBAR_PAD_X, bank_y)
    -- Hint-anchor on the big number (distinct from "bankroll", the chip
    -- pile point anchor chip-flights target).
    AnchorRegistry.set("cell:bankroll", TOPBAR_PAD_X, bank_y,
        fonts.lg:getWidth(bank_str), fonts.lg:getHeight())

    local total     = d_bank + d_tied
    local n_tables  = self.controller.pool:count()
    local focus_cap = self.controller:currentFocusCapacity()
    local focus_pct = math.floor(self.controller:currentFocusMult() * 100 + 0.5)
    -- Shift the DISPLAYED % smoothly toward the target instead of snapping (same
    -- roll feel as the money). The pop/change-watch still keys off focus_pct (the
    -- real target) so it fires once per change, not on each roll step.
    local focus_shown = math.floor(RollingValue.get("focus_pct", focus_pct) + 0.5)

    -- Color-coded off the SHOWN value so the tint tracks the rolling number:
    -- green = 100% (no penalty), amber = 70–99%, red = <70%.
    local focus_color
    if focus_shown >= 100     then focus_color = Theme.status.good
    elseif focus_shown >= 70  then focus_color = Theme.status.warn
    else                          focus_color = Theme.status.error end

    -- SHOVE: live gauntlet-clear readout. Same compute the gauntlet
    -- locks in at click time — players see the grind feed the rate in
    -- real time. Mechanically the displayed value is raw_r1 (catalog ×
    -- bankroll-mult, uncapped) so the player can see overshoots like
    -- "120%" / "220%" — that's the "I've ground past anything that
    -- matters" feel.
    local ctx = (self.controller and self.controller.ctx) or {}
    local rates = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
    local r1_raw = rates.raw_r1 or 0
    local rate_color
    if     r1_raw < 0.50 then rate_color = Theme.status.error
    elseif r1_raw < 1.00 then rate_color = Theme.status.warn
    else                      rate_color = Theme.status.good
    end

    -- Cluster layout: walk left→right. Cells inside a cluster sit
    -- flush, each sized to its own content. Clusters are separated
    -- by CLUSTER_GAP whitespace so the grouping (Bankroll | Money |
    -- Run | Workload) reads visually without divider lines.
    local x = TOPBAR_PAD_X + BANKROLL_CELL_W + CLUSTER_GAP

    -- Money cluster: TIED · TOTAL
    local tied_cell_x = x
    drawStatCell(x, CELL_W.tied,  "TIED UP", moneyText(d_tied), Theme.fg.muted,   fonts)
    x = x + CELL_W.tied
    drawStatCell(x, CELL_W.total, "TOTAL",   moneyText(total),  Theme.fg.primary, fonts)
    x = x + CELL_W.total + CLUSTER_GAP

    -- Stash the TIED UP cell rect for hover tooltip in update().
    self._tied_cell_rect = {
        x = tied_cell_x, y = 2, w = CELL_W.tied, h = TOP_BAR_H - 4,
    }
    AnchorRegistry.set("cell:tied", tied_cell_x, 2, CELL_W.tied, TOP_BAR_H - 4)

    -- Run cluster: CHIPS · SHOVE · (DECK). The Gold Chip is the meta
    -- currency — drawn prominently as a real-sized glyph + count, not a
    -- tiny label-slot dot. (Procedural until ui/icons/chip art lands.)
    -- TUTORIAL builds hide it until the player has shoved once:
    -- pre-shove the banked balance is always 0 and this-run chips live
    -- on the SHOVE button's "+N" badge instead. Slot still advances —
    -- no reflow at the reveal.
    if (not Constants.FEATURES.TUTORIAL) or (state.shove_count or 0) > 0 then
        local cs = self.game.ui_scale or 1
        local cd = math.floor(TOP_BAR_H * 0.6)
        Icons.drawChip(self.game, x, math.floor((TOP_BAR_H - cd) / 2), cd)
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.heading)
        love.graphics.print(chipsText(d_chips),
            x + cd + math.floor(6 * cs),
            math.floor((TOP_BAR_H - fonts.md:getHeight()) / 2))
        AnchorRegistry.set("cell:chips", x, 2, CELL_W.chip, TOP_BAR_H - 4)
    end
    x = x + CELL_W.chip

    if state.shove_r2_won then
        local cs = self.game.ui_scale or 1
        local cd = math.floor(TOP_BAR_H * 0.6)
        Icons.drawAntiChip(self.game, x, math.floor((TOP_BAR_H - cd) / 2), cd)
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.heading)
        local d_achips = self.displayed_anti_chips or state.anti_chips or 0
        love.graphics.print(chipsText(d_achips),
            x + cd + math.floor(6 * cs),
            math.floor((TOP_BAR_H - fonts.md:getHeight()) / 2))
        AnchorRegistry.set("cell:achips", x, 2, CELL_W.achip, TOP_BAR_H - 4)
        x = x + CELL_W.achip
    end
    -- SHOVE % cell — hidden until the shove reveals itself (TUTORIAL
    -- gate: 3 chips banked on the first-ever run). The slot still
    -- advances so the bar doesn't reflow at the reveal.
    local shove_unlocked = self.controller:shoveUnlocked()
    local shove_cell_x = x
    if shove_unlocked then
        drawStatCell(x, CELL_W.shove, "SHOVE",
                     string.format("%.0f%%", r1_raw * 100), rate_color, fonts,
                     function(ix, iy, isize) return Icons.draw(self.game, "shove", ix, iy, isize, isize) end)
    end
    x = x + CELL_W.shove

    -- DECK chip (sprite) sits in the run cluster once the deck system
    -- has unlocked (first gauntlet clear). The chip renders the active
    -- deck's card-back at icon size with a level overlay; the hover
    -- tooltip in update() carries the full name + bonus + XP-to-next
    -- breakdown. Rect nil while locked, so clicks/tooltips no-op.
    if Decks.systemUnlocked(self.game.state) then
        self._deck_cell_rect = self:_drawDeckCell(x, CELL_W.deck, fonts)
        x = x + CELL_W.deck
    else
        self._deck_cell_rect = nil
    end
    x = x + CLUSTER_GAP

    -- Stash the SHOVE cell rect for hover tooltip in update(); nil while
    -- the cell is hidden so hover/hints stay inert.
    if shove_unlocked then
        self._shove_cell_rect = {
            x = shove_cell_x, y = 2, w = CELL_W.shove, h = TOP_BAR_H - 4,
        }
        AnchorRegistry.set("cell:shove", shove_cell_x, 2, CELL_W.shove, TOP_BAR_H - 4)
    else
        self._shove_cell_rect = nil
    end

    -- Workload cluster: TABLES (count / focus capacity) · FOCUS %.
    -- Each number watches itself via Pop.onChange and pops when it changes:
    -- the open-count X pops on buy/close, the capacity Y only when an upgrade
    -- moves it, FOCUS% on any focus change. (Both pops are the SAME reusable
    -- treatment as the showdown winning cards.)
    local md = fonts.md
    local function popText(str, px, scale, color)
        love.graphics.setFont(md)
        Theme.setColor(color)
        if scale ~= 1 then
            local cx, cy = px + md:getWidth(str) / 2, TOPBAR_VALUE_Y + md:getHeight() / 2
            love.graphics.push()
            love.graphics.translate(cx, cy)
            love.graphics.scale(scale, scale)
            love.graphics.translate(-cx, -cy)
            love.graphics.print(str, px, TOPBAR_VALUE_Y)
            love.graphics.pop()
        else
            love.graphics.print(str, px, TOPBAR_VALUE_Y)
        end
    end

    -- TABLES: "X / Y" with X and Y popping independently.
    local workload_x0 = x
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("TABLES", x, TOPBAR_LABEL_Y)
    local x_str, sep, y_str = tostring(n_tables), " / ", tostring(focus_cap)
    local xw, sw = md:getWidth(x_str), md:getWidth(sep)
    popText(x_str, x,           Pop.changeScale("tables_x", n_tables, 1, 0.30, 0.45), Theme.fg.primary)
    Theme.setColor(Theme.fg.primary)
    love.graphics.setFont(md)
    love.graphics.print(sep, x + xw, TOPBAR_VALUE_Y)
    popText(y_str, x + xw + sw, Pop.changeScale("tables_y", focus_cap, 1, 0.30, 0.45), Theme.fg.primary)
    x = x + CELL_W.tables

    -- FOCUS%: pops + flashes white when the focus value changes.
    local fpop    = Pop.onChange("focus", focus_pct, 0.5)
    local focusFn = function(ix, iy, isize) return Icons.draw(self.game, "focus", ix, iy, isize, isize) end
    local fcolor  = focus_color
    if fpop > 0 then
        fcolor = {
            focus_color[1] + (1 - focus_color[1]) * fpop,
            focus_color[2] + (1 - focus_color[2]) * fpop,
            focus_color[3] + (1 - focus_color[3]) * fpop,
        }
    end
    drawStatCell(x, CELL_W.focus, "FOCUS", focus_shown .. "%", fcolor, fonts, focusFn,
                 Pop.scale(fpop, 1, 0.45))
    AnchorRegistry.set("cell:focus", x, 2, CELL_W.focus, TOP_BAR_H - 4)
    x = x + CELL_W.focus

    -- Stash workload rect for the hover tooltip in update().
    self._workload_rect = {
        x = workload_x0, y = 2, w = x - workload_x0, h = TOP_BAR_H - 4,
    }
end

-- ─── Cash-Out-All button (top bar, leftmost of the 3-button strip) ───

-- The four top-bar buttons span the upgrades-sidebar width:
--   [CASH OUT] gap [CATALOG] gap [ROOM] gap [SETTINGS] right_pad ‖ screen edge
-- Equal-width buttons, TOPBAR_BTN_GAP between them, MARGIN on the
-- right so the rightmost button doesn't kiss the screen edge.
function GrindView:_topBarBtnW()
    local pad_right = MARGIN
    local gap       = TOPBAR_BTN_GAP
    local num_btns  = 4
    return math.floor((RIGHT_W - (num_btns - 1) * gap - pad_right) / num_btns)
end

function GrindView:_cashOutButtonRect()
    local W = love.graphics.getWidth()
    local bw = self:_topBarBtnW()
    return {
        x = W - RIGHT_W,                                    -- leftmost
        y = math.floor((TOP_BAR_H - CASH_OUT_BTN_H) / 2),
        w = bw,
        h = CASH_OUT_BTN_H,
    }
end

function GrindView:_drawCashOutButton()
    local rect    = self:_cashOutButtonRect()
    AnchorRegistry.set("btn:cash_out", rect.x, rect.y, rect.w, rect.h)
    local n       = self.controller.pool:count()
    local enabled = n > 0
    local mx, my  = love.mouse.getPosition()
    local hovered = enabled
                    and mx >= rect.x and mx < rect.x + rect.w
                    and my >= rect.y and my < rect.y + rect.h
    LabelButton.draw{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        text         = "CASH OUT",
        fonts        = self.game.fonts,
        hovered      = hovered,
        press_alpha  = ClickFlash.alpha("cash_out", "cash_out"),
        disabled     = not enabled,
        fill_token   = enabled and Theme.status.warn or Theme.bg.sunken,
        border_token = enabled and Theme.fg.heading  or Theme.border.soft,
        text_token   = enabled and Theme.bg.window   or Theme.fg.disabled,
    }
end

-- ─── Catalog button (top bar, between Cash-Out and Room) ─────────

-- Hidden until the post-shove catalog has introduced itself (persisted
-- as state.catalog_seen, set by ShoveState when the modal first opens).
-- Only the tutorial build gates it — the scripted-intro build always
-- shows the button. The rect itself stays put, so the button pops into
-- its slot on unlock without moving CASH OUT or SETTINGS.
function GrindView:_catalogButtonVisible()
    return (not Constants.FEATURES.TUTORIAL) or self.game.state.catalog_seen
end

function GrindView:_catalogButtonRect()
    local cb = self:_cashOutButtonRect()
    local bw = self:_topBarBtnW()
    return {
        x = cb.x + bw + TOPBAR_BTN_GAP,
        y = math.floor((TOP_BAR_H - CATALOG_BTN_H) / 2),
        w = bw,
        h = CATALOG_BTN_H,
    }
end

function GrindView:_drawCatalogButton()
    local rect   = self:_catalogButtonRect()
    AnchorRegistry.set("btn:catalog", rect.x, rect.y, rect.w, rect.h)
    local mx, my = love.mouse.getPosition()
    LabelButton.draw{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        text        = "CATALOG",
        fonts       = self.game.fonts,
        hovered     = mx >= rect.x and mx < rect.x + rect.w
                      and my >= rect.y and my < rect.y + rect.h,
        press_alpha = ClickFlash.alpha("catalog_btn", "catalog_btn"),
    }
end

-- ─── Room button (top bar, between Catalog and Settings) ──────────────

function GrindView:_roomButtonRect()
    local cb = self:_catalogButtonRect()
    local bw = self:_topBarBtnW()
    return {
        x = cb.x + bw + TOPBAR_BTN_GAP,
        y = math.floor((TOP_BAR_H - CATALOG_BTN_H) / 2),
        w = bw,
        h = CATALOG_BTN_H,
    }
end

function GrindView:_drawRoomButton()
    local rect   = self:_roomButtonRect()
    AnchorRegistry.set("btn:room", rect.x, rect.y, rect.w, rect.h)
    local mx, my = love.mouse.getPosition()
    local is_room_active = self.game.state_machine
        and self.game.state_machine.current_state_name == "room"
    local btn_text = is_room_active and "PLAY" or "ROOM"
    LabelButton.draw{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        text        = btn_text,
        fonts       = self.game.fonts,
        hovered     = mx >= rect.x and mx < rect.x + rect.w
                      and my >= rect.y and my < rect.y + rect.h,
        press_alpha = ClickFlash.alpha("room_btn", "room_btn"),
    }
end

-- ─── Settings button (top bar, rightmost) ────────────────────────────

function GrindView:_settingsButtonRect()
    local rb = self:_roomButtonRect()
    local bw = self:_topBarBtnW()
    return {
        x = rb.x + bw + TOPBAR_BTN_GAP,
        y = math.floor((TOP_BAR_H - CATALOG_BTN_H) / 2),
        w = bw,
        h = CATALOG_BTN_H,
    }
end

function GrindView:_drawSettingsButton()
    local rect   = self:_settingsButtonRect()
    local mx, my = love.mouse.getPosition()
    LabelButton.draw{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        text        = "SETTINGS",
        fonts       = self.game.fonts,
        hovered     = mx >= rect.x and mx < rect.x + rect.w
                      and my >= rect.y and my < rect.y + rect.h,
        press_alpha = ClickFlash.alpha("settings_btn", "settings_btn"),
    }
end

-- ─── Help button (top bar, "?" — reopens the how-to-play modal) ──────

function GrindView:_helpButtonRect()
    local cb = self:_cashOutButtonRect()
    local sz = CATALOG_BTN_H
    return {
        x = cb.x - TOPBAR_BTN_GAP - sz,
        y = math.floor((TOP_BAR_H - sz) / 2),
        w = sz, h = sz,
    }
end

-- TUTORIAL builds have no top-bar "?" — THE HOUSE poster is the help
-- desk (click it). The button survives only for prototype builds, where
-- it reopens the how-to-play modal.
function GrindView:_drawHelpButton()
    if Constants.FEATURES.TUTORIAL then return end
    local rect   = self:_helpButtonRect()
    AnchorRegistry.set("btn:help", rect.x, rect.y, rect.w, rect.h)
    local mx, my = love.mouse.getPosition()
    LabelButton.draw{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
        text        = "?",
        fonts       = self.game.fonts,
        hovered     = mx >= rect.x and mx < rect.x + rect.w
                      and my >= rect.y and my < rect.y + rect.h,
        press_alpha = ClickFlash.alpha("help_btn", "help_btn"),
    }
end

-- ─── Center grid ──────────────────────────────────────────────────────

-- Target aspect for each table panel — wider than tall so the felt reads
-- as a poker table, not a vertical billboard. Picked 4:3; tweak here if
-- the felt feels off at large table counts.
local PANEL_ASPECT = 4 / 3

-- Pick the (cols, rows) split that gives the biggest 4:3 cell within the
-- available grid area. Trying every cols ∈ [1..n] is cheap (n ≤ 32) and
-- handles the asymmetric grid (wide-but-shortish) cleanly: for n=2 in a
-- wide area it'll pick 2×1, but each cell renders at 4:3 instead of
-- stretching to fill the full grid height.
--
-- PANEL_MAX_W / PANEL_MAX_H are declared at the top of the file with
-- the other layout upvalues (recomputeLayout updates them at boot +
-- resize). Old duplicate `local` here was shadowing — removed.

local function bestGridLayout(n, grid_w, grid_h)
    local best = { cols = 1, rows = n, pw = 0, ph = 0, area = -1 }
    for cols = 1, n do
        local rows = math.ceil(n / cols)
        local pw_avail = (grid_w - (cols - 1) * MARGIN) / cols
        local ph_avail = (grid_h - (rows - 1) * MARGIN) / rows
        if pw_avail > 8 and ph_avail > 8 then
            local pw, ph
            if pw_avail / ph_avail > PANEL_ASPECT then
                ph = ph_avail
                pw = ph * PANEL_ASPECT
            else
                pw = pw_avail
                ph = pw / PANEL_ASPECT
            end
            -- Clamp to max panel size, preserving aspect ratio.
            if pw > PANEL_MAX_W then
                pw = PANEL_MAX_W
                ph = pw / PANEL_ASPECT
            end
            if ph > PANEL_MAX_H then
                ph = PANEL_MAX_H
                pw = ph * PANEL_ASPECT
            end
            local area = pw * ph
            if area > best.area then
                best = { cols = cols, rows = rows, pw = pw, ph = ph, area = area }
            end
        end
    end
    return best
end

-- Small "Quick reset" button straddling the SHOVE button's top edge (half on
-- the shove, half in the reserved strip above it) — an obvious overlapping
-- alternative. Only shown / hit-tested when GrindController:canQuickReset().
function GrindView:_quickResetButtonRect()
    local sb   = self:_shoveButtonRect()
    local s    = self.game.ui_scale or 1
    local font = self.game.fonts.sm
    local bw   = font:getWidth("Quick reset") + math.floor(28 * s)
    local bh   = font:getHeight() + math.floor(14 * s)
    return {
        x = sb.x + math.floor((sb.w - bw) / 2),
        y = sb.y - math.floor(bh / 2),
        w = bw, h = bh,
    }
end

function GrindView:_drawCenterGrid(W, H)
    local grid_x = LEFT_W + MARGIN
    local grid_y = TOP_BAR_H + MARGIN
    local grid_w = W - LEFT_W - RIGHT_W - 2 * MARGIN
    local grid_h = H - TOP_BAR_H - BOTTOM_BAND_H - 2 * MARGIN

    local tables = self.controller.pool.tables
    local n = #tables
    if n <= 0 then
        -- Empty-state hint: prompt the player toward the sidebar add-table
        -- buttons. Y positions derived from the active fonts so the two
        -- lines never overlap regardless of font size.
        local fonts = self.game.fonts
        local lg_h  = fonts.lg:getHeight()
        local cy    = grid_y + math.floor(grid_h / 2)
        local gap   = 8
        love.graphics.setFont(fonts.lg)
        Theme.setColor(Theme.fg.muted)
        love.graphics.printf("No tables open.",
            grid_x, cy - lg_h - gap, grid_w, "center")
        love.graphics.setFont(fonts.md)
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf("Click an ADD TABLE button in the left sidebar.",
            grid_x, cy + gap, grid_w, "center")
        self.frozen_grid = nil
        return
    end

    -- Freeze layout while the mouse is stationary so closing multiple
    -- tables in a row doesn't reflow cell sizes/positions under the
    -- cursor — successive [×] clicks land at the same spot. Frozen
    -- layout is invalidated on `mousemoved` (or count grew past the
    -- frozen cell count, or the window was resized).
    local frozen = self.frozen_grid
    local use_frozen = frozen
        and frozen.grid_w == grid_w
        and frozen.grid_h == grid_h
        and n <= frozen.n

    local layout
    if use_frozen then
        layout = frozen.layout
    else
        layout = bestGridLayout(n, grid_w, grid_h)
        self.frozen_grid = {
            layout = layout, n = n, grid_w = grid_w, grid_h = grid_h,
            -- Anchor for the mousemoved deadzone — small jitters around
            -- this point keep the freeze alive.
            anchor_x = love.mouse.getX(), anchor_y = love.mouse.getY(),
        }
    end
    local cols, rows, pw, ph = layout.cols, layout.rows, layout.pw, layout.ph

    -- Center the cell block within the available grid area so leftover
    -- space (from aspect-clamping) sits as symmetric padding instead of
    -- pushing everything to the top-left.
    local block_w = cols * pw + (cols - 1) * MARGIN
    local block_h = rows * ph + (rows - 1) * MARGIN
    local origin_x = grid_x + math.floor((grid_w - block_w) / 2)
    local origin_y = grid_y + math.floor((grid_h - block_h) / 2)

    for i = 1, n do
        local r = math.floor((i - 1) / cols)
        local c = (i - 1) % cols
        local x = origin_x + c * (pw + MARGIN)
        local y = origin_y + r * (ph + MARGIN)
        TablePanel.draw(tables[i], i, x, y, pw, ph, self.game, self.controller, self.hit_boxes)
    end
end

-- ─── SHOVE button (right sidebar bottom) ──────────────────────────────

function GrindView:_shoveButtonRect()
    local W, H = love.graphics.getDimensions()
    return {
        x = W - RIGHT_W + MARGIN,
        y = H - SHOVE_BTN_H - MARGIN,
        w = RIGHT_W - 2 * MARGIN,
        h = SHOVE_BTN_H,
    }
end

-- ─── THE HOUSE (the captor's poster) ──────────────────────────────────

-- Sits above the SHOVE button (what you shove against). The tutorial's
-- hint bubbles speak from it (views/HintView anchors them to "house"),
-- and the "?" help-desk button lives in its corner (TUTORIAL builds).
-- Drawn from shapes until art lands: a framed poster with a gold-roofed
-- house glyph.
function GrindView:_houseRect()
    local sb = self:_shoveButtonRect()
    local qr = math.floor(18 * (self.game.ui_scale or 1))
    return {
        x = sb.x, w = sb.w,
        y = sb.y - qr - HOUSE_H,
        h = HOUSE_H,
    }
end

-- The "?" badge in the poster's bottom-right corner (TUTORIAL builds only).
function GrindView:_houseHelpBtnRect()
    local r  = self:_houseRect()
    local s  = self.game.ui_scale or 1
    local sz = math.floor(r.h * 0.40)
    local m  = math.floor(6 * s)
    return { x = r.x + r.w - sz - m, y = r.y + r.h - sz - m, w = sz, h = sz }
end

-- The "i" badge in the poster's top-right corner (TUTORIAL builds only).
function GrindView:_houseInfoBtnRect()
    local r  = self:_houseRect()
    local s  = self.game.ui_scale or 1
    local sz = math.floor(r.h * 0.40)
    local m  = math.floor(6 * s)
    return { x = r.x + r.w - sz - m, y = r.y + m, w = sz, h = sz }
end

function GrindView:_drawHouse()
    local r  = self:_houseRect()
    local s  = self.game.ui_scale or 1
    local fl = math.floor
    AnchorRegistry.set("house", r.x, r.y, r.w, r.h)

    -- Poster: sunken card + double frame.
    local inset = fl(4 * s)
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, fl(3 * s))
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("line", r.x, r.y, r.w, r.h, fl(3 * s))
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", r.x + inset, r.y + inset,
        r.w - inset * 2, r.h - inset * 2, fl(2 * s))

    -- House glyph, centered: gold roof, warm body, dark door.
    local pad = fl(12 * s)
    local gh  = r.h - pad * 2
    local gw  = gh
    local gx  = r.x + fl((r.w - gw) * 0.5)
    local gy  = r.y + pad
    local roof_y = gy + fl(gh * 0.42)
    Theme.setColor(Theme.currency.chip)
    love.graphics.polygon("fill",
        gx - fl(gw * 0.08), roof_y,
        gx + fl(gw * 0.5),  gy,
        gx + gw + fl(gw * 0.08), roof_y)
    Theme.setColor(Theme.border.strong)
    love.graphics.rectangle("fill",
        gx + fl(gw * 0.10), roof_y,
        gw - fl(gw * 0.20), gy + gh - roof_y)
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill",
        gx + fl(gw * 0.40), gy + gh - fl(gh * 0.34),
        fl(gw * 0.20), fl(gh * 0.34))

    -- The "?" help-desk button, bottom-right corner of the poster.
    if Constants.FEATURES.TUTORIAL then
        local hb = self:_houseHelpBtnRect()
        AnchorRegistry.set("btn:help", hb.x, hb.y, hb.w, hb.h)
        local mx, my = love.mouse.getPosition()
        local hov = mx >= hb.x and mx < hb.x + hb.w
                and my >= hb.y and my < hb.y + hb.h
        LabelButton.draw{
            x = hb.x, y = hb.y, w = hb.w, h = hb.h,
            text        = "?",
            fonts       = self.game.fonts,
            font        = self.game.fonts.md,
            hovered     = hov,
            -- Rest state matches the poster card; hover actually changes it.
            fill_token  = hov and Theme.bg.widget_hover or Theme.bg.sunken,
            press_alpha = ClickFlash.alpha("help_btn", "help_btn"),
        }

        -- Register the "btn:info" anchor for the HintView to draw the [i] button.
        local ib = self:_houseInfoBtnRect()
        AnchorRegistry.set("btn:info", ib.x, ib.y, ib.w, ib.h)
    end
end

-- The shove face always draws; until unlocked (TUTORIAL:
-- SHOVE_UNLOCK_CHIPS banked on the first-ever run) it renders greyed-out
-- and ignores clicks — the "+N {chip}" badge stays live so the player
-- watches their pile grow toward the reveal. The quick-reset rescue is
-- independent and draws either way.
function GrindView:_drawShoveButton()
    local sb = self:_shoveButtonRect()
    self:_drawShoveFace(sb)
    -- Quick-reset alternative, overlaid on the shove face when the player is
    -- bricked with no chips to bank (GrindController:canQuickReset). Drawn
    -- after the shove so it sits on top; the shove (when revealed) peeks as
    -- a red frame + bottom readouts so it's clearly an alternative, not a
    -- replacement.
    if self.controller:canQuickReset() then
        local qr     = self:_quickResetButtonRect()
        AnchorRegistry.set("btn:quick_reset", qr.x, qr.y, qr.w, qr.h)
        local mx, my = love.mouse.getPosition()
        local hov    = mx >= qr.x and mx < qr.x + qr.w
                   and my >= qr.y and my < qr.y + qr.h
        LabelButton.draw{
            x = qr.x, y = qr.y, w = qr.w, h = qr.h,
            text = "Quick reset",
            fonts = self.game.fonts, font = self.game.fonts.sm,
            hovered = hov, depth = 4,
            press_alpha = ClickFlash.alpha("quick_reset", "quick_reset"),
        }
    end
end

function GrindView:_drawShoveFace(sb)
    AnchorRegistry.set("btn:shove", sb.x, sb.y, sb.w, sb.h)
    local state = self.game.state
    -- No bankroll floor — softlocking the player with a "you can't even
    -- surrender" gate was strictly worse than letting them shove with
    -- nothing. The only lock is the tutorial reveal (3 chips, first run);
    -- while locked the button renders in its disabled state.
    local can_shove = self.controller:shoveUnlocked()
    local ctx = self.controller.ctx or {}
    -- Live rates match the top-bar column. Headline is gauntlet-clear
    -- (r1·r2·r3); the math-reality clamps live inside ShoveRate.compute.
    local rates      = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
    local pending_chips = state.chips_this_run or 0

    local mx, my = love.mouse.getPosition()
    local hovered = can_shove and mx >= sb.x and mx < sb.x + sb.w
                                and my >= sb.y and my < sb.y + sb.h
    local press   = ClickFlash.alpha("shove", "shove")

    Button.draw(sb.x, sb.y, sb.w, sb.h, {
        fill_color   = can_shove and Theme.status.error or Theme.bg.sunken,
        border_color = can_shove and Theme.fg.heading   or Theme.border.soft,
        line_width   = Theme.space.line_strong,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = not can_shove,
        depth        = 5,
    }, function(fx, fy, fw, fh)
        -- Restructured layout: SHOVE is the headline — kpi-sized,
        -- vertically centered, fills most of the button. The two
        -- secondary readouts (live win %, banked chips) tuck into the
        -- bottom corners as small labels so they don't compete with
        -- the action verb.
        local fonts   = self.game.fonts
        local small   = fonts.sm
        local title   = fonts.lg

        -- Title — massive, centered both axes. Vertical center is
        -- biased a few pixels up so the bottom-corner labels have
        -- breathing room without crowding the title.
        Theme.setColor(can_shove and Theme.fg.heading or Theme.fg.disabled)
        love.graphics.setFont(title)
        local title_y = fy + math.floor((fh - title:getHeight()) * 0.5) - 4
        love.graphics.printf("SHOVE", fx, title_y, fw, "center")

        -- Bottom corners. Both sit on the same baseline.
        local pad   = 10
        local sub_y = fy + fh - small:getHeight() - 5
        love.graphics.setFont(small)

        -- Win-chance, bottom-left. Number-only — the "to win" suffix
        -- was redundant with the giant SHOVE label above it.
        Theme.setColor(can_shove and Theme.fg.heading or Theme.fg.faint)
        love.graphics.print(
            string.format("%.0f%%", (rates.raw_r1 or 0) * 100),
            fx + pad, sub_y)

        -- Chips-banked, bottom-right: "+N ◆" and "+N (achip)". Muted when 0;
        -- active color once a bounty has landed so the player can glance at
        -- the SHOVE button and know whether they have anything riding.
        local pending_achips = state.anti_chips_this_run or 0
        local crx = fx + fw - pad
        local gsize = small:getHeight()
        local cgap  = 3

        if state.shove_r2_won then
            local achip_text = string.format("+%d", pending_achips)
            local achip_color = (pending_achips > 0) and Theme.currency.achip or Theme.fg.faint
            Theme.setColor(achip_color)
            local actw = small:getWidth(achip_text)
            crx = crx - (actw + cgap + gsize)
            love.graphics.print(achip_text, crx, sub_y)
            Icons.drawAntiChip(self.game, crx + actw + cgap, sub_y, gsize)
            AnchorRegistry.set("achip_badge:shove", crx, sub_y,
                actw + cgap + gsize, gsize)
            crx = crx - 8 -- Gap between chips and anti-chips
        end

        local chip_text  = string.format("+%d", pending_chips)
        local chip_color = (pending_chips > 0) and Theme.status.good
                                               or  Theme.fg.faint
        Theme.setColor(chip_color)
        local ctw   = small:getWidth(chip_text)
        crx   = crx - (ctw + cgap + gsize)
        love.graphics.print(chip_text, crx, sub_y)
        Icons.drawChip(self.game, crx + ctw + cgap, sub_y, gsize)
        AnchorRegistry.set("chip_badge:shove", crx, sub_y,
            ctw + cgap + gsize, gsize)
    end)
end

-- ─── Floating text overlay ────────────────────────────────────────────

-- Stroke offsets for the text outline. 8 cardinal+diagonal positions
-- give a clean ring; we draw the text at each in dark color, then once
-- in the main color at center. Cheap legibility win against any felt.
local FLOATER_STROKE_OFFSETS = {
    {-1, -1}, {0, -1}, {1, -1},
    {-1,  0},          {1,  0},
    {-1,  1}, {0,  1}, {1,  1},
}
local FLOATER_STROKE_COLOR = { 0, 0, 0 }

function GrindView:_drawFloatingText()
    local fonts = self.game.fonts
    -- Resolve a controller-supplied color_token through Theme palettes.
    -- Keeps the controller free of view imports while still letting it
    -- name colors symbolically (e.g., "amber" for streak callouts).
    local function resolveToken(tok)
        if not tok then return nil end
        return (Theme.data and Theme.data[tok])
            or (Theme.status and Theme.status[tok])
            or nil
    end
    for _, t in ipairs(self.game.floating_text.getTexts()) do
        -- Color priority: explicit RGB override > color_token lookup > auto.
        local color = t.color or resolveToken(t.color_token)
        if not color then
            if t.text:sub(1, 1) == "+" then
                -- Default win color: amber/gold, not green. Green blends
                -- with the green felt; gold pops on every stake's color.
                color = Theme.data.amber or Theme.status.good
            else
                color = Theme.status.error
            end
        end
        local font   = fonts[t.font or "lg"] or fonts.lg
        local scale  = t.scale or 1.0
        local alpha  = t.alpha or 1
        local line_h = font:getHeight()
        local step   = math.floor(line_h * 0.78)   -- tighter stack so the lines read as one group
        love.graphics.setFont(font)

        -- Multi-line aware: split on "\n", center each line on t.x, and CENTER
        -- the whole block on t.y (it used to stack downward from t.y, dropping a
        -- win banner's payout lines well below the table center). The renderer
        -- owns the layout, so callers emit ONE float for a whole block.
        local n_lines = 1
        for _ in t.text:gmatch("\n") do n_lines = n_lines + 1 end

        love.graphics.push()
        love.graphics.translate(t.x, t.y)
        if scale ~= 1 then love.graphics.scale(scale, scale) end
        local ly = -((n_lines - 1) * step + line_h) * 0.5
        for line in (t.text .. "\n"):gmatch("(.-)\n") do
            if line:find("{", 1, true) then
                -- Inline icons (e.g. "+1 {chip}") — IconText, no stroke ring.
                local tw = IconText.measure(line, font)
                IconText.draw(self.game, line, -tw * 0.5, ly, font, color, alpha)
            elseif line ~= "" then
                local tw = font:getWidth(line)
                -- Dark stroke ring for legibility against any felt color.
                Theme.setColor(FLOATER_STROKE_COLOR, alpha * 0.85)
                for _, off in ipairs(FLOATER_STROKE_OFFSETS) do
                    love.graphics.print(line, -tw * 0.5 + off[1], ly + off[2])
                end
                Theme.setColor(color, alpha)
                love.graphics.print(line, -tw * 0.5, ly)
            end
            ly = ly + step
        end
        love.graphics.pop()
    end
end

-- ─── Bankroll chip pile (bottom-middle band) ──────────────────────────
-- Renders the player's bankroll as a procedural chip pile in the center
-- column's bottom band. The numeric bankroll reading stays in the top
-- bar — the chip pile is visual flavor + animation anchor for chip-flight
-- emissions. Registers the screen-space anchor with AnchorRegistry so
-- emission code (controllers) can find this pile without reaching into
-- the view layer directly.
function GrindView:_drawBankrollChips(W, H)
    local band_x = LEFT_W + MARGIN
    local band_w = W - LEFT_W - RIGHT_W - 2 * MARGIN
    local band_y = H - BOTTOM_BAND_H
    local center_x = band_x + band_w * 0.5
    local stack_y  = band_y + BOTTOM_BAND_H - 22

    -- Stash for emission code (1-frame stale, fine).
    AnchorRegistry.set("bankroll", center_x, stack_y)

    -- A collection, not a breakdown of the scalar (views/ChipPile). Chips
    -- flown here — a table cashing out, a stack-cap overflow — are
    -- inserted as they land, so the pile grows with the chips instead of
    -- ahead of them. No hold-back ledger needed.
    --
    -- max_w caps the pile to the bottom band's width so a huge bankroll
    -- doesn't march past the center-column edges; the layout drops
    -- smallest-denom columns from the tail until it fits.
    local bankroll = self.game.state.bankroll or 0
    -- The bankroll gets the whole band, so it spreads wide before it
    -- stacks back — the opposite of the table piles, which are boxed in by
    -- cards on every side.
    ChipPile.place("bankroll", center_x, stack_y,
        { align = "center", max_w = band_w - 32,
          max_cols = BANKROLL_PILE_COLS, max_rows = BANKROLL_PILE_ROWS })
    ChipPile.sync("bankroll", bankroll, {
        palette = ChipData.full_palette,
        tier    = Denoms.tierFromAmount(bankroll),
    })
    ChipPile.draw("bankroll")
end

-- ─── Composite draw ───────────────────────────────────────────────────

-- `overlay_fn` (optional): host-provided layer (the tutorial hint) drawn
-- above every gameplay layer but below the hover tooltip, so tooltips —
-- including the one a hint asks the player to go look at — stay on top.
function GrindView:draw(overlay_fn)
    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Reset hit boxes — they're rebuilt during this draw pass.
    self.hit_boxes = {}

    self:_drawTopBar(W)
    -- Origin for the tutorial [i] hint-queue strip (views/HintView):
    -- hugs the tables sidebar's right edge, below the top bar.
    do
        local m = math.floor(8 * (self.game.ui_scale or 1))
        AnchorRegistry.set("hint_queue", LEFT_W + m, TOP_BAR_H + m)
    end
    self:_drawHelpButton()
    self:_drawCashOutButton()
    if self:_catalogButtonVisible() then self:_drawCatalogButton() end
    self:_drawRoomButton()
    self:_drawSettingsButton()

    self:_drawCenterGrid(W, H)

    self.left_panel:draw(self.game)
    self.right_panel:draw(self.game)
    self:_drawHouse()
    self:_drawShoveButton()
    self:_drawFloatingText()

    -- Bankroll chip pile in the bottom-middle band. Registers the
    -- screen-space anchor (via AnchorRegistry) flying-chip emission targets.
    self:_drawBankrollChips(W, H)

    -- Flying chips between source and destination (pot ↔ player ↔
    -- bankroll). Renders above panels and the bankroll pile but below
    -- the cursor swarm.
    FlightSystem.draw()

    -- Press-then-vanish ghosts for DEAL / REBUY / [×] click animations.
    -- Drawn above panels so they sit visually where the live button
    -- was. Must be drawn BEFORE cursors, otherwise the ghost rendered
    -- after a cursor click covers the cursor that just clicked it.
    Ghosts.draw()

    -- Cursor swarm — drawn last so cursors are always on top, including
    -- on top of the press-fade ghost they just dispatched.
    CursorPool.draw()

    if overlay_fn then overlay_fn() end

    -- Hover tooltip — sits above gameplay layers but below the backtick
    -- debug overlay (which is the absolute top).
    TooltipSvc.draw(self.game.fonts)

    -- Backtick debug tooltip — flushed last so it draws above every other
    -- view layer (sidebar panels, shove button, floating text, chips,
    -- cursors, hover tooltip all included).
    TablePanelStats.flushDebugOverlay(self.game)
end

-- ─── Mouse routing ────────────────────────────────────────────────────

function GrindView:mousepressed(x, y, b)
    if b ~= 1 then return end

    -- Quick-reset button — overlaid on the SHOVE face when bricked with no
    -- chips to bank. Checked before SHOVE so the overlay wins; clicks on the
    -- peeking shove frame/readouts still fall through to the shove below.
    if self.controller:canQuickReset() then
        local qr = self:_quickResetButtonRect()
        if x >= qr.x and x < qr.x + qr.w and y >= qr.y and y < qr.y + qr.h then
            ClickFlash.flash("quick_reset", "quick_reset")
            if self.game.quickReset then self.game.quickReset() end
            return
        end
    end

    -- Cash-Out-All button (top bar). Checked first so the right-side hit
    -- doesn't fall through to the right panel's tab-strip / scroll zone.
    local cb = self:_cashOutButtonRect()
    if self.controller.pool:count() > 0
       and x >= cb.x and x < cb.x + cb.w
       and y >= cb.y and y < cb.y + cb.h then
        ClickFlash.flash("cash_out", "cash_out")
        self.controller:cashOutAll()
        return
    end

    -- Catalog button (top bar, between cash-out and settings). Opens
    -- the same modal the post-bust prestige flow uses, so the player
    -- can spend chips mid-grind without busting first.
    local cat = self:_catalogButtonRect()
    if self:_catalogButtonVisible()
       and x >= cat.x and x < cat.x + cat.w
       and y >= cat.y and y < cat.y + cat.h then
        ClickFlash.flash("catalog_btn", "catalog_btn")
        if self.game.openCatalog then self.game.openCatalog() end
        return
    end

    -- DECK chip (top bar, run cluster). Opens the read-only roster
    -- modal — swapping the active deck is restricted to the post-shove
    -- ritual, but the player can inspect their decks any time.
    local deck_rect = self._deck_cell_rect
    if deck_rect
       and x >= deck_rect.x and x < deck_rect.x + deck_rect.w
       and y >= deck_rect.y and y < deck_rect.y + deck_rect.h then
        if self.game.openDeckRoster then self.game.openDeckRoster() end
        return
    end

    -- Room toggle button (top bar, between catalog and settings).
    local room_rect = self:_roomButtonRect()
    if x >= room_rect.x and x < room_rect.x + room_rect.w
       and y >= room_rect.y and y < room_rect.y + room_rect.h then
        ClickFlash.flash("room_btn", "room_btn")
        if self.game.toggleRoom then self.game.toggleRoom() end
        return
    end

    -- Settings button (top bar, rightmost).
    local set_rect = self:_settingsButtonRect()
    if x >= set_rect.x and x < set_rect.x + set_rect.w
       and y >= set_rect.y and y < set_rect.y + set_rect.h then
        ClickFlash.flash("settings_btn", "settings_btn")
        if self.game.openSettings then self.game.openSettings() end
        return
    end

    -- Help button ("?", top bar) — prototype builds only. Reopens the
    -- how-to-play modal.
    if not Constants.FEATURES.TUTORIAL then
        local help_rect = self:_helpButtonRect()
        if x >= help_rect.x and x < help_rect.x + help_rect.w
           and y >= help_rect.y and y < help_rect.y + help_rect.h then
            ClickFlash.flash("help_btn", "help_btn")
            if self.game.openHelp then self.game.openHelp() end
            return
        end
    end

    -- The "?" on THE HOUSE poster: the help desk (TUTORIAL builds — the
    -- hint-log list rises from the poster).
    if Constants.FEATURES.TUTORIAL then
        local hb = self:_houseHelpBtnRect()
        if x >= hb.x and x < hb.x + hb.w
           and y >= hb.y and y < hb.y + hb.h then
            ClickFlash.flash("help_btn", "help_btn")
            if self.game.openHelp then self.game.openHelp() end
            return
        end
    end

    -- SHOVE button has priority — it's bottom-right and overlaps the right
    -- panel zone. Inert until the shove has revealed itself.
    local sb = self:_shoveButtonRect()
    if self.controller:shoveUnlocked()
       and x >= sb.x and x < sb.x + sb.w and y >= sb.y and y < sb.y + sb.h then
        ClickFlash.flash("shove", "shove")
        self.controller:initiateShove()
        return
    end

    -- Right panel.
    if x >= self.right_panel.x then
        if self.right_panel:handleMouseDown(x, y, b, self.game) then return end
        local comps = self.right_panel:getComponents()
        if comps then
            local cy = self.right_panel:toContentY(y)
            local hit = CR.hitTest(comps, self.right_panel.x, self.right_panel.w, x, cy, self.game)
            if hit and hit.id then
                self:_handleSidebarButton(hit.id)
            end
        end
        return
    end

    -- Left panel.
    if x < LEFT_W then
        if self.left_panel:handleMouseDown(x, y, b, self.game) then return end
        local comps = self.left_panel:getComponents()
        if comps then
            local cy = self.left_panel:toContentY(y)
            local hit = CR.hitTest(comps, self.left_panel.x, self.left_panel.w, x, cy, self.game)
            if hit and hit.id then
                self:_handleSidebarButton(hit.id)
            end
        end
        return
    end

    -- Center grid: per-table hit boxes (×, stake-up).
    for _, hb in ipairs(self.hit_boxes) do
        if x >= hb.x and x < hb.x + hb.w and y >= hb.y and y < hb.y + hb.h then
            self:_handleHitBox(hb)
            return
        end
    end
end

function GrindView:_handleSidebarButton(id)
    ClickFlash.flash("button", id)

    -- Game-type sub-tab selection.
    local gtype = id:match("^gtype:(.+)$")
    if gtype then
        self.selected_gtype = gtype
        return
    end
    -- Composite "add_table:<stake>:<gtype>" — non-greedy on the first
    -- group so stake_ids with underscores still parse.
    local stake_id, gtype_id = id:match("^add_table:(.-):(.+)$")
    if stake_id and gtype_id then
        self.controller:addTable(stake_id, gtype_id)
        return
    end

    -- Trailing action strip on the +ADD rows. Same non-greedy split as
    -- add_table; a nil stake means the global control on the Cursor upgrade,
    -- which applies to every open table.
    local function scopeOf(prefix)
        local s, g = id:match("^" .. prefix .. ":(.-):(.+)$")
        if s then return s, g, true end
        if id == prefix then return nil, nil, true end
        return nil, nil, false
    end

    local s_id, g_id, ok = scopeOf("cash_out_type")
    if ok then
        self.controller:cashOutType(s_id, g_id)
        return
    end
    s_id, g_id, ok = scopeOf("type_cursor_deal")
    if ok then
        -- Set, not toggle: read the group's current state and flip the whole
        -- group to the opposite, so a mixed group resolves instead of
        -- inverting into another mixed one.
        local total, muted = self.controller:typeCursorState(s_id, g_id)
        self.controller:setTypeCursorMute(s_id, g_id, muted < total)
        return
    end
    s_id, g_id, ok = scopeOf("type_cursor_rebuy")
    if ok then
        local total, _, muted = self.controller:typeCursorState(s_id, g_id)
        self.controller:setTypeCursorRebuyMute(s_id, g_id, muted < total)
        return
    end
    local up_id = id:match("^buy_runup_(.+)$")
    if up_id then
        self.controller:buyRunUpgrade(up_id)
        return
    end
    -- buy_catalog_ removed — catalog purchases now happen in the post-bust
    -- CatalogModal (see views/CatalogModal.lua).
end

-- Hit-box action handlers. Adding a new clickable region = one entry here
-- + one hit-box record in TablePanel/GrindView's draw walk that carries
-- the same action key. No if/elseif chain on hb.action.
local HIT_BOX_HANDLERS = {
    deal                = function(self, hb) self.controller:dealHand(hb.idx)              end,
    rebuy               = function(self, hb) self.controller:rebuyTable(hb.idx)            end,
    remove_table        = function(self, hb) self.controller:removeTable(hb.idx)           end,
    toggle_cursor       = function(self, hb) self.controller:toggleCursorMute(hb.idx)      end,
    toggle_rebuy_cursor = function(self, hb) self.controller:toggleCursorRebuyMute(hb.idx) end,
}

function GrindView:_handleHitBox(hb)
    -- Click-feedback flash. Single trigger point catches mouse-driven and
    -- cursor-swarm dispatches alike (cursor pool routes through here).
    -- Key by (action + idx) so [x] / [C] / DEAL on the same table don't
    -- share a flash bucket and tint each other on click.
    if hb.action and hb.idx then
        ClickFlash.flash("hit", hb.action .. ":" .. hb.idx)
    end

    -- Press-then-vanish: ephemeral buttons (DEAL / REBUY / [×]) stop
    -- being rendered the moment the click fires (state changes, table
    -- removed). Snapshot a ghost into Ghosts so the rise-out press
    -- animation plays out for ~0.5 s before despawning.
    --
    -- [×] on a busy table is a *deferred* close — the live button keeps
    -- rendering (now warn-tinted to flag the queued state). Skip the
    -- ghost in that case so we don't double-render the press animation
    -- with a colour mismatch.
    local tbl_for_ghost = self.controller.pool.tables[hb.idx]
    local defer_remove  = hb.action == "remove_table"
                          and tbl_for_ghost and tbl_for_ghost.state ~= "idle"
    if (hb.action == "deal" or hb.action == "rebuy"
        or hb.action == "remove_table") and not defer_remove then
        local ghost = TablePanel.makeGhostFor(hb, self.game.fonts)
        if ghost then Ghosts.add(ghost) end
    end

    local handler = HIT_BOX_HANDLERS[hb.action]
    if handler then handler(self, hb) end
end

function GrindView:mousereleased(_, _, _)
    self.left_panel:handleMouseUp()
    self.right_panel:handleMouseUp()
end

-- Deadzone radius (px) for the grid-layout freeze. Real hand jitter on a
-- mouse is typically 1-3 px between clicks; 8 px swallows that without
-- letting an actual nudge toward a different button stay frozen.
local FREEZE_DEADZONE_PX = 8

function GrindView:mousemoved(x, y, _, _)
    -- Mouse-stationary freeze on the center grid (see _drawCenterGrid).
    -- Movement past the deadzone releases the freeze; tiny jitters are
    -- ignored so closing tables in a streak doesn't reflow.
    local f = self.frozen_grid
    if not f or not f.anchor_x then return end
    local dx = x - f.anchor_x
    local dy = y - f.anchor_y
    if dx * dx + dy * dy > FREEZE_DEADZONE_PX * FREEZE_DEADZONE_PX then
        self.frozen_grid = nil
    end
end

function GrindView:wheelmoved(_, dy)
    local mx, _ = love.mouse.getPosition()
    if mx < LEFT_W then
        self.left_panel:handleScroll(dy)
    elseif mx >= self.right_panel.x then
        self.right_panel:handleScroll(dy)
    end
end

-- Window resized — rebuild Panel objects so the right panel reanchors to
-- the new right edge and both panels reflow their content/scroll heights.
-- Per-tab scroll position is reset (cheap acceptable cost; per-tab UI is
-- short enough that scroll mid-resize isn't load-bearing).
function GrindView:resize(_w, _h)
    self:_buildPanels()
end

return GrindView
