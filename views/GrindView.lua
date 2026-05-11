-- views/GrindView.lua
--
-- The grind screen. Three-column layout:
--   • Top bar (50px) — bankroll, PP, run stats
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
local CursorPool     = require("services.CursorPool")
local Chips          = require("views.Chips")
local Denoms        = require("services.DenominationBreakdown")
local ChipData       = require("data.chips")
local FlightSystem   = require("services.FlightSystem")
local ChipFlight     = require("views.ChipFlight")
local ClickFlash     = require("services.ClickFlash")
local TooltipSvc     = require("services.Tooltip")
local AnchorRegistry = require("services.AnchorRegistry")
local Button         = require("views.Button")
local LabelButton    = require("views.widgets.LabelButton")
local Ghosts         = require("services.Ghosts")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local RunUpgrades    = require("data.run_upgrades")
local Catalog        = require("data.catalog")
local Constants      = require("data.constants")
local ShoveRate      = require("models.shove_rate")
local Decks          = require("models.Decks")

local GrindView = {}
GrindView.__index = GrindView


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
    pp = 48, shove = 56, deck = 50,          -- run cluster (deck is a sprite chip)
    tables = 72, focus = 56,                 -- workload cluster
}
local TOPBAR_LABEL_Y       = 8
local TOPBAR_VALUE_Y       = 32

local MARGIN               = 12
-- Button heights are recomputed from font metrics in recomputeLayout
-- so they grow/shrink with whatever sizes data/theme.lua picks.
local SHOVE_BTN_H          = 64
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
local function recomputeLayout(W, H, fonts)
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
    -- stake-add buttons ("+ $0.01/$0.02" + "+1 PP" badge) needs ~290
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
    CELL_W.pp     = cellW("PP",      "9999")
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
                         + CELL_W.pp    + CELL_W.shove
                         + CELL_W.tables + CELL_W.focus
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
        displayed_pp       = state.pp             or 0,
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
    recomputeLayout(W, H, self.game.fonts)

    self.left_panel = Panel:new(0, TOP_BAR_H, LEFT_W, H - TOP_BAR_H)
    self.left_panel:registerTab({
        id       = "tables",
        label    = "Tables",
        priority = 0,
        build    = function() return self:_buildTablesTabComponents() end,
    })
    -- Catalog tab removed — purchases now happen in views/CatalogModal.lua
    -- after each bust. The PP shop is only accessible between runs.

    -- Right panel reserves space at the bottom for the SHOVE button.
    local right_panel_h = H - TOP_BAR_H - SHOVE_BTN_H - 2 * MARGIN
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
        zoom     = "Zoom — anonymous reroll pool. Fastest mode, you win slightly more often, but pots stay small.",
        mtt      = "Tournament — 8 hands in sequence, no rebuys. Cash 6+ wins to cover the buy-in; win all 8 for the top payout.",
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
    local gtype_id = self.selected_gtype
    for _, stake in ipairs(Stakes) do
        -- T4-T6 are designed but not balanced for the demo loop, so the
        -- +ADD-TABLE buttons are hidden when FEATURES.HIGH_TIER_STAKES
        -- is off. Existing T4-T6 tables in a save still render through
        -- TablePanel — those die naturally on the next reset.
        local hidden = (not Constants.FEATURES.HIGH_TIER_STAKES)
                       and (stake.id == "s004" or stake.id == "s005" or stake.id == "s006")
        if not hidden then
            local full         = active >= cap
            local cant_afford  = state.bankroll < (stake.buy_in or 0)
            local disabled     = full or cant_afford

            local sub
            if full then
                sub = "tables full (max " .. cap .. ")"
            elseif cant_afford then
                sub = string.format("buy-in $%.2f  (need more)", stake.buy_in or 0)
            else
                sub = string.format("buy-in $%.2f", stake.buy_in or 0)
            end

            -- PP-bounty status: "+N PP" right-aligned next to the stake
            -- name. Color is the whole signal — default (white) while the
            -- bounty is still up for grabs, green once banked this run.
            local banked = self.controller:bountyBanked(stake.id, gtype_id)
            local award  = self.controller:bountyAward(stake.id)
            local pp_text       = string.format("+%d PP", award)
            local pp_color_tok  = banked and "good" or nil

            components[#components + 1] = {
                type     = "button",
                id       = "add_table:" .. stake.id .. ":" .. gtype_id,
                disabled = disabled,
                tooltip  = string.format("Open a %s %s table — costs the buy-in.",
                                         stake.display_name, gtype_id:gsub("_", "-")),
                lines = {
                    {
                        text  = "+ " .. stake.display_name, style = "heading",
                        right = pp_text, right_color_token = pp_color_tok,
                    },
                    { text = sub, style = "small" },
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
            local max_lvl   = up.max_level or 1
            local at_max    = level >= max_lvl
            local next_cost = self.controller:getRunUpgradeNextCost(up)
            local cant_afford = next_cost and state.bankroll < next_cost
            local disabled  = at_max or cant_afford or locked

            -- 2-line button:
            --   [name (heading)            | level (heading) ]
            --   [description (small)       | cost (small)    ]
            -- Locked / maxed states collapse the right column to a
            -- single status string on line 1.
            local level_text, cost_text
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

            components[#components + 1] = {
                type     = "button",
                id       = "buy_runup_" .. up.id,
                disabled = disabled,
                lines = {
                    { text = up.name,                style = "heading", right = level_text },
                    { text = up.description or "",   style = "small",   right = cost_text  },
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

    -- SHOVE button hover tooltip (direct rect — no hit_box entry). Same
    -- breakdown the top-bar column shows, plus a final "click to lock"
    -- line so the player understands the rate freezes at click time.
    local sb = self:_shoveButtonRect()
    if mx >= sb.x and mx < sb.x + sb.w and my >= sb.y and my < sb.y + sb.h then
        local state = self.game.state
        local ctx = (self.controller and self.controller.ctx) or {}
        local rates = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
        local lines = ShoveRate.formatBreakdown(rates)
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
    -- shove-rate. Rect is stashed by _drawTopBar (1-frame stale).
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
    -- FEATURES.DECKS is on (the cell rect is nil otherwise).
    local dr = self._deck_cell_rect
    if dr and mx >= dr.x and mx < dr.x + dr.w and my >= dr.y and my < dr.y + dr.h then
        local state = self.game.state
        local active_id = state.active_deck_id
        local spec = active_id and Decks.specById(active_id)
        if spec then
            local level = (state.deck_levels and state.deck_levels[active_id]) or 1
            local xp    = (state.deck_xp and state.deck_xp[active_id]) or 0
            local into, span = Decks.progressInLevel(spec, level, xp)
            local lines = {
                spec.name or active_id,
                string.format("L%d / %d  ·  %s",
                    level, spec.max_level, spec.bonus_text or ""),
                spec.xp_action_text or "",
            }
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
    self.displayed_pp       = tweenNumber(self.displayed_pp,       state.pp,                  dt)
    self.displayed_tied     = tweenNumber(self.displayed_tied,     self.controller:tiedUp(),  dt)

    -- Drain the controller's chip-burst queue. Controller produces denomination
    -- indices and source/dest pairs; the view delegates to ChipFlight which
    -- wraps the render-closure composition + FlightSystem dispatch. Keeps
    -- controller→view dependencies out of controllers/GrindController.lua
    -- and shares the same path the script's per-event handlers use.
    local bursts = self.controller:drainBursts()
    for _, b in ipairs(bursts) do
        ChipFlight.flyChipsList(b.source, b.dest, b.chips, b.options)
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

local function ppText(n)
    if not n or n < 1 then return "0" end
    return Format.formatBig(math.floor(n))
end

-- Draws "LABEL" (sm, muted) on top and the value (md, given color)
-- below at the cell's left edge. Keeps every non-bankroll cell visually
-- identical so the eye scans cleanly across the bar. md (not lg) for
-- values because lg=48 overflows the 72px cell width — only bankroll
-- (its own fat cell) gets the lg pop.
local function drawStatCell(x, w, label, value, value_color, fonts)
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(label, x, TOPBAR_LABEL_Y)

    love.graphics.setFont(fonts.md)
    Theme.setColor(value_color)
    love.graphics.print(value, x, TOPBAR_VALUE_Y)
end

-- Draws the active-deck card-back chip at the given x, in a `w`-wide
-- column. Returns the cell hit rect for hover-tooltip dispatch in
-- update(). Caller should only invoke this when FEATURES.DECKS is on.
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

    if sprite then
        local sx = icon_w / sprite:getWidth()
        local sy = icon_h / sprite:getHeight()
        Theme.setColor(Theme.fg.heading)
        love.graphics.draw(sprite, icon_x, icon_y, 0, sx, sy)
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

    -- Level badge overlay (bottom-right of the icon). Compact "L3" tag
    -- so the active level reads at a glance without the tooltip.
    local level = (state.deck_levels and state.deck_levels[active_id]) or 1
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
    local d_pp   = self.displayed_pp       or state.pp
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
    love.graphics.print(moneyText(d_bank), TOPBAR_PAD_X, bank_y)

    local total     = d_bank + d_tied
    local n_tables  = self.controller.pool:count()
    local focus_cap = self.controller:currentFocusCapacity()
    local focus_pct = math.floor(self.controller:currentFocusMult() * 100 + 0.5)

    -- Focus % color-coded: green = 100% (no penalty), amber = 70–99%,
    -- red = <70%.
    local focus_color
    if focus_pct >= 100     then focus_color = Theme.status.good
    elseif focus_pct >= 70  then focus_color = Theme.status.warn
    else                         focus_color = Theme.status.error end

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

    -- Run cluster: PP · SHOVE · (DECK)
    drawStatCell(x, CELL_W.pp, "PP", ppText(d_pp), Theme.fg.heading, fonts)
    x = x + CELL_W.pp
    local shove_cell_x = x
    drawStatCell(x, CELL_W.shove, "SHOVE",
                 string.format("%.0f%%", r1_raw * 100), rate_color, fonts)
    x = x + CELL_W.shove

    -- DECK chip (sprite) sits in the run cluster when FEATURES.DECKS is
    -- on. The chip renders the active deck's card-back at icon size with
    -- a level overlay; the hover tooltip in update() carries the full
    -- name + bonus + XP-to-next breakdown.
    if Constants.FEATURES and Constants.FEATURES.DECKS then
        self._deck_cell_rect = self:_drawDeckCell(x, CELL_W.deck, fonts)
        x = x + CELL_W.deck
    else
        self._deck_cell_rect = nil
    end
    x = x + CLUSTER_GAP

    -- Stash the SHOVE cell rect for hover tooltip in update().
    self._shove_cell_rect = {
        x = shove_cell_x, y = 2, w = CELL_W.shove, h = TOP_BAR_H - 4,
    }

    -- Workload cluster: TABLES (count / focus capacity) · FOCUS %.
    -- The "N / cap" inline format makes the relationship to FOCUS
    -- visible at a glance; the hover tooltip explains the mechanic.
    local workload_x0 = x
    drawStatCell(x, CELL_W.tables, "TABLES",
                 string.format("%d / %d", n_tables, focus_cap),
                 Theme.fg.primary, fonts)
    x = x + CELL_W.tables
    drawStatCell(x, CELL_W.focus, "FOCUS",  focus_pct .. "%",   focus_color, fonts)
    x = x + CELL_W.focus

    -- Stash workload rect for the hover tooltip in update().
    self._workload_rect = {
        x = workload_x0, y = 2, w = x - workload_x0, h = TOP_BAR_H - 4,
    }
end

-- ─── Cash-Out-All button (top bar, leftmost of the 3-button strip) ───

-- The three top-bar buttons span the upgrades-sidebar width:
--   [CASH OUT] gap [CATALOG] gap [SETTINGS] right_pad ‖ screen edge
-- Equal-width buttons, TOPBAR_BTN_GAP between them, MARGIN on the
-- right so the rightmost button doesn't kiss the screen edge.
function GrindView:_topBarBtnW()
    local pad_right = MARGIN
    local gap       = TOPBAR_BTN_GAP
    return math.floor((RIGHT_W - 2 * gap - pad_right) / 3)
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

-- ─── Catalog button (top bar, between Cash-Out and Settings) ─────────

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

-- ─── Settings button (top bar, rightmost) ────────────────────────────

function GrindView:_settingsButtonRect()
    local cb = self:_catalogButtonRect()
    local bw = self:_topBarBtnW()
    return {
        x = cb.x + bw + TOPBAR_BTN_GAP,
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

function GrindView:_drawShoveButton()
    local sb = self:_shoveButtonRect()
    local state = self.game.state
    -- Shove is always allowed. No bankroll floor — softlocking the player
    -- with a "you can't even surrender" gate was strictly worse than letting
    -- them shove with nothing and bank whatever PP they earned.
    local can_shove = true
    local ctx = self.controller.ctx or {}
    -- Live rates match the top-bar column. Headline is gauntlet-clear
    -- (r1·r2·r3); the math-reality clamps live inside ShoveRate.compute.
    local rates      = ShoveRate.compute(ctx, (state.bankroll or 0) + self.controller:tiedUp())
    local pending_pp = state.pp_this_run or 0

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
        -- secondary readouts (live win %, banked PP) tuck into the
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

        -- PP-banked, bottom-right. Muted when 0; green once a bounty
        -- has landed so the player can glance at the SHOVE button and
        -- know whether they have anything riding on the click.
        local pp_text  = string.format("+%d PP", pending_pp)
        local pp_color = (pending_pp > 0) and Theme.status.good
                                          or  Theme.fg.faint
        Theme.setColor(can_shove and pp_color or Theme.fg.faint)
        local pp_w = small:getWidth(pp_text)
        love.graphics.print(pp_text, fx + fw - pad - pp_w, sub_y)
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
            if t.text:find(" PP", 1, true) then
                color = Theme.data.violet
            elseif t.text:sub(1, 1) == "+" then
                -- Default win color: amber/gold, not green. Green blends
                -- with the green felt; gold pops on every stake's color.
                color = Theme.data.amber or Theme.status.good
            else
                color = Theme.status.error
            end
        end
        local font  = fonts[t.font or "lg"] or fonts.lg
        local scale = t.scale or 1.0
        love.graphics.setFont(font)
        local tw = font:getWidth(t.text)
        love.graphics.push()
        love.graphics.translate(t.x - tw * scale * 0.5, t.y)
        if scale ~= 1 then love.graphics.scale(scale, scale) end
        -- Dark stroke ring for legibility against any felt color.
        Theme.setColor(FLOATER_STROKE_COLOR, (t.alpha or 1) * 0.85)
        for _, off in ipairs(FLOATER_STROKE_OFFSETS) do
            love.graphics.print(t.text, off[1], off[2])
        end
        -- Main text on top.
        Theme.setColor(color, t.alpha or 1)
        love.graphics.print(t.text, 0, 0)
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

    local bankroll = self.game.state.bankroll or 0
    if bankroll <= 0 then return end

    local tier = Denoms.tierFromAmount(bankroll)
    local chips = Denoms.breakdown(bankroll, ChipData.denominations,
                                   ChipData.full_palette,
                                   ChipData.tier_chip_target, tier)
    -- Cap to the bottom band's width so a huge bankroll doesn't march
    -- past the center-column edges. drawStack drops smallest-denom
    -- columns from the tail until it fits.
    Chips.drawStack(center_x, stack_y, chips,
        { align = "center", max_w = band_w - 32 })
end

-- ─── Composite draw ───────────────────────────────────────────────────

function GrindView:draw()
    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Reset hit boxes — they're rebuilt during this draw pass.
    self.hit_boxes = {}

    self:_drawTopBar(W)
    self:_drawCashOutButton()
    self:_drawCatalogButton()
    self:_drawSettingsButton()
    self:_drawCenterGrid(W, H)
    self.left_panel:draw(self.game)
    self.right_panel:draw(self.game)
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
    -- can spend PP mid-grind without busting first.
    local cat = self:_catalogButtonRect()
    if x >= cat.x and x < cat.x + cat.w
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

    -- Settings button (top bar, rightmost).
    local set_rect = self:_settingsButtonRect()
    if x >= set_rect.x and x < set_rect.x + set_rect.w
       and y >= set_rect.y and y < set_rect.y + set_rect.h then
        ClickFlash.flash("settings_btn", "settings_btn")
        if self.game.openSettings then self.game.openSettings() end
        return
    end

    -- SHOVE button has priority — it's bottom-right and overlaps the right panel zone.
    local sb = self:_shoveButtonRect()
    if x >= sb.x and x < sb.x + sb.w and y >= sb.y and y < sb.y + sb.h then
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
