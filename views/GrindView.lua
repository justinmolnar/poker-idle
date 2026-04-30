-- views/GrindView.lua
--
-- The grind screen. Three-column layout:
--   • Top bar (50px) — bankroll, PP, peak-this-run
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

local Theme       = require("views.Theme")
local Format      = require("utils.format")
local Panel       = require("views.Panel")
local CR          = require("views.ComponentRenderer")
local TablePanel  = require("views.TablePanel")
local CursorPool  = require("services.CursorPool")
local Chips       = require("views.Chips")
local ChipData    = require("data.chips")
local ChipFlight  = require("services.ChipFlightSystem")
local ClickFlash  = require("services.ClickFlash")
local TooltipSvc  = require("services.Tooltip")
local Button      = require("views.Button")
local Ghosts      = require("services.Ghosts")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local RunUpgrades = require("data.run_upgrades")
local Catalog     = require("data.catalog")
local Constants   = require("data.constants")
local ShoveRate   = require("models.shove_rate")

local GrindView = {}
GrindView.__index = GrindView

-- Layout constants.
local TOP_BAR_H            = 50
local LEFT_W               = 280
local RIGHT_W              = 250
local MARGIN               = 12
local SHOVE_BTN_H          = 64
local CASH_OUT_BTN_W       = 110
local CASH_OUT_BTN_H       = 36
-- Reserved band at the bottom of the center column for the bankroll
-- chip pile. Center grid shrinks vertically by this much. Sidebars are
-- unaffected — they keep running their full height.
local BOTTOM_BAND_H        = 90
local PANEL_REMOVE_BTN_SIZE = 22
local STAKE_UP_BTN_H       = 26
local STAKE_UP_BTN_PAD     = 8
local PILL_H               = 18
local PILL_GAP             = 4

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
        displayed_peak     = state.peak_bankroll  or 0,
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

    self.left_panel = Panel:new(0, TOP_BAR_H, LEFT_W, H - TOP_BAR_H)
    self.left_panel:registerTab({
        id       = "tables",
        label    = "Tables",
        priority = 0,
        build    = function() return self:_buildTablesTabComponents() end,
    })
    self.left_panel:registerTab({
        id       = "catalog",
        label    = "Catalog",
        priority = 1,
        build    = function() return self:_buildCatalogTabComponents() end,
    })

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
    local STRIP_H = 32
    local self_ref = self
    -- Per-gtype short blurb for the hover tooltip. Hardcoded next to
    -- where the strip is built so callers don't have to juggle a string
    -- table; the data file (data/game_types.lua) only carries gameplay
    -- knobs (seats, pace, dist_shifts), not UI copy.
    local GTYPE_BLURB = {
        six_max  = "6-max — standard pace, 5 seated opponents.",
        hu       = "Heads-Up — long showdowns; small wins, big losses.",
        zoom     = "Zoom — anonymous pool, fold-spam. Tiny pots, no reads.",
        mtt      = "Tournament — pay buy-in once, play 8 hands. Cash 6+ to win.",
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
                    love.graphics.setFont(fonts.ui_small)
                    love.graphics.printf(label, fx,
                        fy + math.floor((fh - fonts.ui_small:getHeight()) * 0.5),
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
    components[#components + 1] = { type = "label", style = "muted", text = "ADD TABLE", h = 22 }

    -- Game-type sub-tab strip.
    components[#components + 1] = self:_makeGameTypeStrip()
    components[#components + 1] = { type = "spacer", h = 4 }

    -- Stake-add buttons for the currently selected game type. Button id
    -- is composite "add_table:<stake>:<gtype>" so the dispatcher routes
    -- to controller:addTable(stake_id, game_type_id).
    local gtype_id = self.selected_gtype
    for _, stake in ipairs(Stakes) do
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

        -- PP-bounty status line. Shows whether this (stake, gtype) combo
        -- has banked PP this run (locked in) or how much is still up
        -- for grabs. Helps the player skip combos they've already won.
        local banked = self.controller:bountyBanked(stake.id, gtype_id)
        local pp_line
        if banked then
            pp_line = { text = "PP banked this run", style = "muted" }
        else
            local award = self.controller:bountyAward(stake.id)
            pp_line = { text = string.format("PP +%d on jackpot win", award),
                        style = "small" }
        end

        components[#components + 1] = {
            type     = "button",
            id       = "add_table:" .. stake.id .. ":" .. gtype_id,
            disabled = disabled,
            tooltip  = string.format("Open a %s %s table — costs the buy-in.",
                                     stake.display_name, gtype_id:gsub("_", "-")),
            lines = {
                { text = "+ " .. stake.display_name, style = "heading" },
                { text = sub, style = "small" },
                pp_line,
            },
        }
    end

    components[#components + 1] = { type = "spacer", h = 8 }
    components[#components + 1] = { type = "divider", h = 6 }

    -- Live focus stats.
    local focus_cap = self.controller:currentFocusCapacity()
    local focus_pct = math.floor(self.controller:currentFocusMult() * 100 + 0.5)
    components[#components + 1] = {
        type  = "label",
        style = "body",
        text  = string.format("Tables: %d  ·  Focus: %d%%", active, focus_pct),
        h     = 20,
    }
    components[#components + 1] = {
        type  = "label",
        style = "small",
        text  = string.format("Capacity: %d  (max %d tables)", focus_cap, cap),
        h     = 18,
    }

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

function GrindView:_buildCatalogTabComponents()
    local state = self.game.state
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local components = {}
    components[#components + 1] = { type = "label", style = "muted", text = "PP SHOP", h = 22 }
    components[#components + 1] = {
        type  = "label",
        style = "small",
        text  = string.format("you have %d PP", state.pp),
        h     = 18,
    }

    for _, item in ipairs(Catalog) do
        local is_owned = owned[item.id]
        local locked   = item.requires and not owned[item.requires]
        -- Items flagged `requires_hide` vanish from the list entirely
        -- when locked. Without the flag, locked items render greyed-out
        -- with a "Requires X" label so the player can see what to buy.
        if not (locked and item.requires_hide) then
            local cant_afford = (not is_owned) and state.pp < item.cost_pp
            local disabled    = is_owned or cant_afford or locked

            local cost_label, tooltip
            if is_owned then
                cost_label = "OWNED"
                tooltip    = item.description or item.name
            elseif locked then
                local req = catalogName(item.requires)
                cost_label = "Requires " .. req
                tooltip    = string.format("Locked. Buy %s in the catalog first.", req)
            else
                cost_label = item.cost_pp .. " PP"
                tooltip    = item.description or item.name
            end

            components[#components + 1] = {
                type     = "button",
                id       = "buy_catalog_" .. item.id,
                disabled = disabled,
                tooltip  = tooltip,
                lines = {
                    { text = item.name, style = "heading" },
                    { text = item.description or "", style = "small" },
                    { text = cost_label, style = (is_owned or locked) and "muted" or "body" },
                },
            }
        end
    end

    return components
end

function GrindView:_buildUpgradesTabComponents()
    local state = self.game.state
    local owned = {}
    for _, id in ipairs(state.owned_items) do owned[id] = true end

    local components = {}
    components[#components + 1] = { type = "label", style = "muted", text = "RUN UPGRADES", h = 22 }

    for _, up in ipairs(RunUpgrades) do
        local locked = up.requires and not owned[up.requires]
        if not (locked and up.requires_hide) then
            local level     = self.controller:getRunUpgradeLevel(up.id)
            local max_lvl   = up.max_level or 1
            local at_max    = level >= max_lvl
            local next_cost = self.controller:getRunUpgradeNextCost(up)
            local cant_afford = next_cost and state.bankroll < next_cost
            local disabled  = at_max or cant_afford or locked

            local cost_label, tooltip
            if locked then
                local req = catalogName(up.requires)
                cost_label = "Requires " .. req
                tooltip    = string.format("Locked. Buy %s in the catalog first.", req)
            elseif at_max then
                cost_label = string.format("MAX  Lv %d/%d", level, max_lvl)
                tooltip    = up.description or up.name
            else
                cost_label = string.format("Lv %d/%d  ·  $%.2f", level, max_lvl, next_cost or 0)
                tooltip    = up.description or up.name
            end

            components[#components + 1] = {
                type     = "button",
                id       = "buy_runup_" .. up.id,
                disabled = disabled,
                tooltip  = tooltip,
                lines = {
                    { text = up.name, style = "heading" },
                    { text = up.description or "", style = "small" },
                    { text = cost_label, style = (at_max or locked) and "muted" or "body" },
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
        local _, breakdown = ShoveRate.compute(ctx,
            state.bankroll or 0,
            state.pp_this_run or 0)
        local lines = ShoveRate.formatBreakdown(breakdown)
        lines[#lines + 1] = "Click to lock this rate."
        TooltipSvc.set(lines, mx, my)
    end

    -- Cash-Out-All button hover tooltip. Same direct-rect treatment as
    -- SHOVE — sits in the top bar above the panels, not a hit_box entry.
    local cb = self:_cashOutButtonRect()
    if self.controller.pool:count() > 0
       and mx >= cb.x and mx < cb.x + cb.w
       and my >= cb.y and my < cb.y + cb.h then
        TooltipSvc.set(
            "Cash out all tables — busy tables finish their hand first.",
            mx, my)
    end

    -- Top-bar SHOVE column hover tooltip. The rect spans both the label
    -- and the value (y=2..46) so a hover anywhere on the column lands.
    -- Width covers the readout + a small comfort margin.
    if mx >= 716 and mx < 800 and my >= 2 and my < 46 then
        local state = self.game.state
        local ctx = (self.controller and self.controller.ctx) or {}
        local _, breakdown = ShoveRate.compute(ctx,
            state.bankroll or 0,
            state.pp_this_run or 0)
        TooltipSvc.set(ShoveRate.formatBreakdown(breakdown), mx, my)
    end

    -- Tween top-bar numbers toward live state values.
    local state = self.game.state
    self.displayed_bankroll = tweenNumber(self.displayed_bankroll, state.bankroll,            dt)
    self.displayed_pp       = tweenNumber(self.displayed_pp,       state.pp,                  dt)
    self.displayed_tied     = tweenNumber(self.displayed_tied,     self.controller:tiedUp(),  dt)
    self.displayed_peak     = tweenNumber(self.displayed_peak,     state.peak_bankroll,       dt)
end

-- ─── Top bar ───────────────────────────────────────────────────────────

local function moneyText(n)
    if math.abs(n) < 1000 then
        return string.format("$%.2f", n)
    end
    return Format.money(n)
end

local function ppText(n)
    if not n or n < 1 then return "0" end
    return Format.formatBig(math.floor(n))
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
    local d_peak = self.displayed_peak     or state.peak_bankroll

    -- Tint the bankroll while a tween is in progress: green when counting
    -- up (target > displayed), red when counting down.
    local bankroll_tint = Theme.fg.heading
    local diff_bank = (state.bankroll or 0) - d_bank
    if math.abs(diff_bank) > 0.01 then
        bankroll_tint = (diff_bank > 0) and Theme.status.good or Theme.status.error
    end

    -- BANKROLL = spendable / off-table money. The big number — that's
    -- what the player actually buys upgrades with.
    Theme.setColor(bankroll_tint)
    love.graphics.setFont(fonts.kpi)
    love.graphics.print(moneyText(d_bank), 16, 8)

    local total     = d_bank + d_tied
    local n_tables  = self.controller.pool:count()
    local focus_pct = math.floor(self.controller:currentFocusMult() * 100 + 0.5)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("TIED UP", 200, 6)
    love.graphics.print("TOTAL",   300, 6)
    love.graphics.print("PP",      400, 6)
    love.graphics.print("PEAK",    470, 6)
    love.graphics.print("TABLES",  580, 6)
    love.graphics.print("FOCUS",   660, 6)
    love.graphics.print("SHOVE",   720, 6)

    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(moneyText(d_tied), 200, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(total), 300, 22)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(ppText(d_pp), 400, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(d_peak), 470, 22)
    love.graphics.print(tostring(n_tables), 580, 22)

    -- Focus % color-coded: green = 100% (no penalty), amber = 70–99%,
    -- red = <70%.
    local focus_color
    if focus_pct >= 100     then focus_color = Theme.status.good
    elseif focus_pct >= 70  then focus_color = Theme.status.warn
    else                         focus_color = Theme.status.error end
    Theme.setColor(focus_color)
    love.graphics.print(focus_pct .. "%", 660, 22)

    -- SHOVE: live shove-rate readout. Same compute the gauntlet locks
    -- in at click time — players see the grind feed the rate in real
    -- time. Tinted by rate breakpoints: red below 20%, amber 20-50%,
    -- green at 50%+. Hover tooltip (set in :update) shows the
    -- breakdown (base, bankroll mult, pp bonus).
    local ctx = (self.controller and self.controller.ctx) or {}
    local rate = ShoveRate.compute(ctx,
        state.bankroll or 0,
        state.pp_this_run or 0)
    local rate_color
    if     rate < 0.20 then rate_color = Theme.status.error
    elseif rate < 0.50 then rate_color = Theme.status.warn
    else                    rate_color = Theme.status.good
    end
    Theme.setColor(rate_color)
    love.graphics.print(string.format("%.1f%%", rate * 100), 720, 22)
end

-- ─── Cash-Out-All button (top bar, right side) ───────────────────────

function GrindView:_cashOutButtonRect()
    local W = love.graphics.getWidth()
    -- Anchor to the right panel's left edge so the button never overlaps
    -- the upgrades panel. y centers within the top bar with room for the
    -- chunky-button depth + lift.
    return {
        x = W - RIGHT_W - MARGIN - CASH_OUT_BTN_W,
        y = math.floor((TOP_BAR_H - CASH_OUT_BTN_H) / 2),
        w = CASH_OUT_BTN_W,
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
    local press   = ClickFlash.alpha("cash_out", "cash_out")

    Button.draw(rect.x, rect.y, rect.w, rect.h, {
        fill_color   = enabled and Theme.status.warn or Theme.bg.sunken,
        border_color = enabled and Theme.fg.heading   or Theme.border.soft,
        hovered      = hovered,
        press_alpha  = press,
        disabled     = not enabled,
        depth        = 4,
    }, function(fx, fy, fw, fh)
        local fonts = self.game.fonts
        Theme.setColor(enabled and Theme.bg.window or Theme.fg.disabled)
        love.graphics.setFont(fonts.ui_small)
        local text_y = fy + math.floor((fh - fonts.ui_small:getHeight()) * 0.5)
        love.graphics.printf("CASH OUT", fx, text_y, fw, "center")
    end)
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
        -- buttons. Without this, fresh-save players get a blank center.
        love.graphics.setFont(self.game.fonts.heading)
        Theme.setColor(Theme.fg.muted)
        love.graphics.printf("No tables open.",
            grid_x, grid_y + math.floor(grid_h / 2) - 24, grid_w, "center")
        love.graphics.setFont(self.game.fonts.ui)
        Theme.setColor(Theme.fg.faint)
        love.graphics.printf("Click an ADD TABLE button in the left sidebar.",
            grid_x, grid_y + math.floor(grid_h / 2) + 4, grid_w, "center")
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
    -- Live rate matches the top-bar column. The math-reality clamp lives
    -- inside ShoveRate.compute so we don't double-clamp here.
    local rate = ShoveRate.compute(ctx,
        state.bankroll or 0,
        state.pp_this_run or 0)
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
        local fonts = self.game.fonts
        Theme.setColor(can_shove and Theme.fg.heading or Theme.fg.disabled)
        love.graphics.setFont(fonts.heading)
        love.graphics.printf("SHOVE", fx, fy + 4, fw, "center")

        Theme.setColor(can_shove and Theme.data.violet or Theme.fg.faint)
        love.graphics.setFont(fonts.ui_small)
        love.graphics.printf(string.format("+%d PP banked", pending_pp),
            fx, fy + 30, fw, "center")

        Theme.setColor(can_shove and Theme.fg.primary or Theme.fg.faint)
        love.graphics.printf(string.format("%.1f%% per runout", rate * 100),
            fx, fy + 46, fw, "center")
    end)
end

-- ─── Floating text overlay ────────────────────────────────────────────

function GrindView:_drawFloatingText()
    local fonts = self.game.fonts
    love.graphics.setFont(fonts.heading)
    for _, t in ipairs(self.game.floating_text.getTexts()) do
        local color
        if t.text:find(" PP", 1, true) then
            -- PP-bounty awards (e.g. "+3 PP") in violet so the player reads
            -- them as distinct from the green +$ / red -$ pot deltas.
            color = Theme.data.violet
        elseif t.text:sub(1, 1) == "+" then
            color = Theme.status.good
        else
            color = Theme.status.error
        end
        Theme.setColor(color, t.alpha or 1)
        love.graphics.print(t.text, t.x - 24, t.y)
    end
end

-- ─── Bankroll chip pile (bottom-middle band) ──────────────────────────
-- Renders the player's bankroll as a procedural chip pile in the center
-- column's bottom band. The numeric bankroll reading stays in the top
-- bar — the chip pile is visual flavor + animation anchor for chip-flight
-- emissions. Stashes the screen-space anchor on game.bankroll_xy so
-- emission code (controllers) can find this pile without reaching into
-- the view layer directly.
function GrindView:_drawBankrollChips(W, H)
    local band_x = LEFT_W + MARGIN
    local band_w = W - LEFT_W - RIGHT_W - 2 * MARGIN
    local band_y = H - BOTTOM_BAND_H
    local center_x = band_x + band_w * 0.5
    local stack_y  = band_y + BOTTOM_BAND_H - 22

    -- Stash for emission code (1-frame stale, fine).
    self.game.bankroll_xy = { center_x, stack_y }

    local bankroll = self.game.state.bankroll or 0
    if bankroll <= 0 then return end

    local tier = Chips.tierFromAmount(bankroll)
    local chips = Chips.breakdown(bankroll, ChipData.full_palette, tier)
    Chips.drawStack(center_x, stack_y, chips, { align = "center" })
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
    self:_drawCenterGrid(W, H)
    self.left_panel:draw(self.game)
    self.right_panel:draw(self.game)
    self:_drawShoveButton()
    self:_drawFloatingText()

    -- Bankroll chip pile in the bottom-middle band. Sets game.bankroll_xy
    -- as the screen-space anchor flying-chip emission can target.
    self:_drawBankrollChips(W, H)

    -- Flying chips between source and destination (pot ↔ player ↔
    -- bankroll). Renders above panels and the bankroll pile but below
    -- the cursor swarm so cursors visibly land on the buttons.
    ChipFlight.draw()

    -- Cursor swarm — drawn above flying chips so cursors remain readable
    -- against the chip fountain.
    CursorPool.draw()

    -- Press-then-vanish ghosts for DEAL / REBUY / [×] click animations.
    -- Drawn above panels so they sit visually where the live button was.
    Ghosts.draw()

    -- Hover tooltip — sits above gameplay layers but below the backtick
    -- debug overlay (which is the absolute top).
    TooltipSvc.draw(self.game.fonts.ui_small)

    -- Backtick debug tooltip — flushed last so it draws above every other
    -- view layer (sidebar panels, shove button, floating text, chips,
    -- cursors, hover tooltip all included).
    TablePanel.flushDebugOverlay(self.game)
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

    -- SHOVE button has priority — it's bottom-right and overlaps the right panel zone.
    local sb = self:_shoveButtonRect()
    if x >= sb.x and x < sb.x + sb.w and y >= sb.y and y < sb.y + sb.h then
        ClickFlash.flash("shove", "shove")
        -- The PP-bank is now done inside ShoveState:enter so the rate
        -- sample sees the un-banked pp_this_run for the bonus
        -- calculation (the formula adds pp_banked × 0.5%).
        self.game.state_machine:switch("shove")
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
    local catalog_id = id:match("^buy_catalog_(.+)$")
    if catalog_id then
        self.controller:buyCatalogItem(catalog_id)
        return
    end
end

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

    if hb.action == "deal" then
        self.controller:dealHand(hb.idx)
    elseif hb.action == "rebuy" then
        self.controller:rebuyTable(hb.idx)
    elseif hb.action == "remove_table" then
        self.controller:removeTable(hb.idx)
    elseif hb.action == "stake_up" then
        self.controller:changeTableStake(hb.idx, hb.next_stake_id)
    elseif hb.action == "toggle_cursor" then
        self.controller:toggleCursorMute(hb.idx)
    end
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
