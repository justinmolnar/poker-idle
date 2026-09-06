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
local TablePanelEffects = require("views.TablePanelEffects")
local TableModel     = require("models.Table")
local GameTypeThemes = require("data.game_type_themes")
local Pop            = require("services.Pop")
local RollingValue   = require("services.RollingValue")
local Motion         = require("services.Motion")
local HouseArt       = require("views.HouseArt")
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
local ItemGhosts     = require("views.ItemGhosts")
local TablePanelDrag = require("views.TablePanelDrag")
local TableGrid      = require("models.table_grid")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local RunUpgrades    = require("data.run_upgrades")
local Catalog        = require("data.catalog")
local Constants      = require("data.constants")
local ShoveRate      = require("models.shove_rate")
local GlyphMorph     = require("services.GlyphMorph")
local Decks          = require("models.Decks")
local DeckArt        = require("views.DeckArt")
local OutcomeMath    = require("models.outcome_math")
local Lookups        = require("utils.lookups")
local Rail           = require("data.rail")
local CatalogModal   = require("views.CatalogModal")
local GrindView = {}
GrindView.__index = GrindView

-- RollingValue chase rate for table-panel display positions (the drag
-- preview slide + the drop-settle glide). Declared up here because
-- _drawCenterGrid, well above the mouse-routing section, reads it.
local SLIDE_RATE = 14

-- A stake is visible when its band's milestone is met. Delegates to
-- GrindController:stakeAvailable (the single source of truth) so the
-- add-table buttons and the win-chance / stack-rate range tooltips never
-- disagree. Low band is always on; mid/high/ultra gate behind shove /
-- anti-chip progression, and the whole non-low ladder is off in the
-- prototype build.
local function stakeVisible(view, stake)
    return view.controller:stakeAvailable(stake)
end


-- Layout values. The window-relative ones (LEFT_W, RIGHT_W, RAIL_H) are
-- *recomputed* in recomputeLayout() at init and on resize — derived
-- from window dimensions + font metrics rather than hardcoded px so
-- the rail fits the active font and sidebars scale with the window.
-- Initial values here are placeholders; the first :_buildPanels call
-- replaces them.
local LEFT_W               = 280
local RIGHT_W              = 250
local MARGIN               = 12
-- The rail along the bottom: the chrome, as components (data/rail.lua
-- for the words; _buildRailComponents for the row). Two text lines tall
-- (a small label over a value, what the old top bar was), a little air
-- above and below; every button in it is RAIL_BTN_H tall.
local RAIL_BTN_H           = 40
local RAIL_PAD             = 6
local RAIL_H               = 52
-- THE HOUSE poster (the captor) sits at the bottom of the right sidebar,
-- above the rail; hint bubbles speak from it (views/HintView anchors to
-- "house"). Doubled when the portrait got real art (views/HouseArt);
-- _buildPanels cuts the Upgrades panel by the same amount automatically.
local HOUSE_H              = 184
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

    -- The poster, the pile band and the table chrome bits scale too.
    HOUSE_H              = math.floor(184 * s)
    BOTTOM_BAND_H        = math.floor(90  * s)
    PANEL_REMOVE_BTN_SIZE = math.floor(22 * s)
    PILL_H               = math.floor(18 * s)
    PILL_GAP             = math.floor(4  * s)
    MARGIN               = math.floor(12 * s)

    -- Sidebars: window-fraction with absolute minimums. The minimum
    -- is NOT layout-scale-multiplied — at 720p the heading text on
    -- stake-add buttons ("+ $0.01/$0.02" + "+1 chip" badge) needs ~290
    -- px to fit on a single line at the design font size, and a
    -- scaled-down minimum (220 * 1.0) lets it wrap.
    LEFT_W  = math.max(290, math.floor(W * 0.18))
    RIGHT_W = math.max(320, math.floor(W * 0.22))

    -- The rail: as tall as a small label's glyphs, a gap, a value's glyphs
    -- and a button's chunk, no more (the fonts' line boxes carry leading
    -- that would only push the labels away from their values), plus a
    -- little air above and below (data/theme.lua space.rail_pad).
    RAIL_PAD   = math.floor(Theme.space.rail_pad * s)
    RAIL_BTN_H = fonts.sm:getBaseline() + Theme.space.stat_gap + fonts.md:getBaseline() + Theme.space.button_depth
    RAIL_H     = RAIL_BTN_H + 2 * RAIL_PAD
end

-- ─── Construction ─────────────────────────────────────────────────────

function GrindView:new(game, controller)
    local state = game.state
    local self = setmetatable({
        game       = game,
        controller = controller,
        hit_boxes  = {},   -- per-frame click targets for non-Panel UI (table buttons, SHOVE)
        selected_gtype = "zoom",  -- which game-type sub-tab is showing in the
                                  -- Tables tab. Zoom is the always-open mode
                                  -- (Constants.GTYPE_GATE), so the default is
                                  -- valid on a brand-new save.

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
-- The loan arriving (GameState.loan_fresh): the readout runs 0 → value over this.
local COUNT_UP_SECS = 1.2

local function tweenNumber(curr, target, dt)
    local k = math.min(1, (dt or 0) * 8)
    local out = curr + (target - curr) * k
    if math.abs(target - out) < 0.005 then out = target end
    return out
end

-- Snap every display tween to the live state. Called on hard resets so a
-- fresh game doesn't animate down from the previous game's totals.
function GrindView:resetDisplays()
    local state = self.game.state
    self.displayed_bankroll   = state.bankroll   or 0
    self.displayed_chips      = state.chips      or 0
    self.displayed_anti_chips = state.anti_chips or 0
    self.displayed_tied       = self.controller:tiedUp()
    self.frozen_grid          = nil
end

function GrindView:_buildPanels()
    local W, H = love.graphics.getDimensions()
    recomputeLayout(W, H, self.game.fonts, self.game.state)

    self.left_panel = Panel:new(0, 0, LEFT_W, H - RAIL_H)
    self.left_panel:registerTab({
        id       = "tables",
        label    = "Tables",
        priority = 0,
        build    = function() return self:_buildTablesTabComponents() end,
    })
    -- Catalog tab removed — purchases now happen in views/CatalogModal.lua
    -- after each bust. The chip shop is only accessible between runs.

    -- Right panel runs to the bottom of the screen (the rail stops at its
    -- edge) and reserves THE HOUSE poster at its foot.
    local right_panel_h = H - HOUSE_H - 2 * MARGIN
    self.right_panel = Panel:new(W - RIGHT_W, 0, RIGHT_W, right_panel_h)
    self.right_panel:registerTab({
        id       = "upgrades",
        label    = "Upgrades",
        priority = 0,
        build    = function() return self:_buildUpgradesTabComponents() end,
    })

    -- The rail: the chrome, one flex row along the bottom, left of the
    -- right sidebar, drawn and hit-tested by the same Panel +
    -- ComponentRenderer path. The row spreads inside whatever width that is.
    self.rail = Panel:new(0, H - RAIL_H, W - RIGHT_W, RAIL_H)
    self.rail:registerTab({
        id       = "rail",
        label    = "Rail",
        priority = 0,
        build    = function() return self:_buildRailComponents() end,
    })
end
-- ─── Panel content builders (called every frame by Panel:draw) ────────────

-- Game-type keys: a row of four buttons at the top of the Tables tab.
-- Selecting one swaps which stake-add rows render below. Cassette-deck
-- selection: every open key rides HIGH on a deep rim; the selected one is
-- HELD DOWN, pressed flat with a lit legend, so the shape carries the
-- state. Locked keys (Constants.GTYPE_GATE) stay: dark, flush, blank and
-- inert, a slot to want. The story beats do the explaining when each opens.
function GrindView:_makeGameTypeStrip()
    local fh        = self.game.fonts.sm:getHeight()
    local s         = self.game.ui_scale or 1
    local KEY_DEPTH = 10
    local kids = {}
    for _, gt in ipairs(GameTypes) do
        local locked = not self.controller:gtypeAvailable(gt.id)
        local active = (gt.id == self.selected_gtype) and not locked
        local id     = "gtype:" .. gt.id
        local hov    = (not active) and (not locked) and self.game.hover.is("button", id)
        -- Press TRAVEL is animated: the key eases down when it becomes
        -- selected and back up when it isn't, on a wall-clock lerp.
        local press  = RollingValue.get("gtype_press:" .. gt.id, (active or locked) and 1 or 0, 14, "ui")
        -- The key wears its game type's chrome (data/game_type_themes), the
        -- same colour the table headers wear: full when selected, sunk when
        -- not, near-out when locked.
        local chrome = GameTypeThemes[gt.id] and GameTypeThemes[gt.id].chrome_color
        local fill
        if chrome then
            local k = active and 0.60 or (hov and 1.0 or 0.85)
            fill = { chrome[1] * k, chrome[2] * k, chrome[3] * k }
        else
            fill = active and Theme.bg.widget_hover or Theme.bg.chrome
        end
        kids[#kids + 1] = {
            type = "button", id = id, anchor = id, flex = 1,
            face_h      = fh + math.floor(8 * s),
            depth       = KEY_DEPTH,
            pressed     = active,
            press_alpha = press,
            disabled    = locked,
            face_color  = fill,
            disabled_face_color = chrome and { chrome[1] * 0.12, chrome[2] * 0.12, chrome[3] * 0.12 }
                                  or Theme.bg.sunken,
            border_color = locked and Theme.border.soft
                           or active and Theme.border.strong
                           or Theme.border.default,
            tooltip = (not locked) and Rail.gtype[gt.id] or nil,
            -- A locked key is BLANK: no name until the mode is earned.
            lines = (not locked) and {
                { text = gt.short or gt.name, style = "small", align = "center",
                  color_token = (active or hov) and "heading" or "muted" },
            } or {},
        }
    end
    return { type = "row", gap = 2, children = kids }
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

    -- Game-type keys.
    components[#components + 1] = self:_makeGameTypeStrip()
    components[#components + 1] = { type = "spacer", h = math.floor(4 * s_ui) }

    -- Stake-add buttons for the currently selected game type. Button id
    -- is composite "add_table:<stake>:<gtype>" so the dispatcher routes
    -- to controller:addTable(stake_id, game_type_id).
    -- A stale selection of a still-locked mode (old save state, or a gate
    -- future-tightened) clamps back to zoom, the always-open mode.
    if not self.controller:gtypeAvailable(self.selected_gtype) then
        self.selected_gtype = "zoom"
    end
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
                sub_right = "buy-in " .. Format.price(stake.buy_in or 0)
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

            -- Bounty badges. Every stake pays a {chip} for winning a stack;
            -- in Act 3 every stake also pays an {achip} for losing one, shown
            -- as a second badge beside the gold. Green + full colour once
            -- banked this run; greyed while unearned, greyer still when you
            -- can't even buy in. The trim goes gold when the {chip} is
            -- banked, purple when only the {achip} is.
            local banked  = self.controller:bountyBanked(stake.id, gtype_id)
            local award   = self.controller:bountyAward(stake.id, gtype_id)
            local icon_id = "chip"
            local border_color = banked and Theme.currency.chip or nil

            local chip_text = string.format("+%d", award)
            local chip_color_tok, chip_shade
            if banked then
                chip_color_tok, chip_shade = "chip", 1.0   -- a chip count is gold
            elseif cant_afford then
                chip_color_tok, chip_shade = "faint", 0.15
            else
                chip_color_tok, chip_shade = "muted", 0.35
            end

            local achip_text, achip_color_tok, achip_shade
            if state.shove_r2_won then
                local abanked = self.controller:antiBountyBanked(stake.id, gtype_id)
                achip_text = string.format("+%d", self.controller:antiBountyAward(stake.id))
                if abanked then
                    achip_color_tok, achip_shade = "good", 1.0
                    if not banked then border_color = Theme.sem.corrupt end
                elseif cant_afford then
                    achip_color_tok, achip_shade = "faint", 0.15
                else
                    achip_color_tok, achip_shade = "muted", 0.35
                end
            end

            -- Trailing QOL strip: acts on the tables THIS row opened, not on
            -- the whole pool. Always present, greyed when the row has no open
            -- tables — appearing on the first buy-in would shove the row's
            -- text sideways every time you opened or closed a table.
            local open_n, deal_muted, rebuy_muted =
                self.controller:typeCursorState(stake.id, gtype_id)
            local none    = open_n == 0
            local pending = self.controller:typePendingCloses(stake.id, gtype_id)
            local suffix  = ":" .. stake.id .. ":" .. gtype_id
            local actions = {
                -- "x", the same glyph and neutral ink the per-table close
                -- button uses. Closing a table IS how you cash it out, so the
                -- group control must not invent a different symbol — and it
                -- warn-tints the same way while any of its closes are still
                -- queued behind a live hand.
                { id = "cash_out_type" .. suffix, label = "X",
                  tint_token = Theme.fg.heading,
                  fill_token = (pending > 0) and Theme.border.strong or nil,
                  disabled = none,
                  tooltip = (pending > 0)
                            and string.format(
                                "Closing %d after their hand%s. Click again to leave NOW — forfeits those hands.",
                                pending, pending == 1 and "" or "s")
                            or (not none) and string.format("Cash out all %d %s %s table%s",
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
                    tint_token = Theme.fg.heading,
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
                        tint_token = Theme.sem.lost,
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
                -- The row that has banked, under one shared name, for the
                -- lines about the button that paid.
                anchor_also  = banked and "add_table:banked" or nil,
                badge_anchor = banked and "chip_badge:banked" or nil,
                disabled = disabled,
                -- The stake row wears its stake's felt — the same color
                -- the tables it opens play on. (The game type is already
                -- said by the chrome-colored tab strip above the rows.)
                face_color   = TablePanel.feltForStake(stake.id),
                -- Gold/Purple trim once this (stake, type) has banked its bounty this run
                border_color = border_color,
                -- EV breakdown tooltip only when the table can be opened.
                tooltip  = affordable
                           and TablePanelStats.breakdownLinesFor(self.controller, stake, gtype_obj)
                           or nil,
                lines = {
                    {
                        text  = "+ " .. stake.display_name, style = "heading",
                        -- This row's "+N {chip}" badge, by name, for the
                        -- lines that point at every badge on the strip.
                        right_anchor = "add_table_chip:" .. stake.id .. ":" .. gtype_id,
                        right = chip_text, right_color_token = chip_color_tok,
                        right_icon = icon_id, right_icon_shade = chip_shade,
                        right2 = achip_text, right2_color_token = achip_color_tok,
                        right2_icon = achip_text and "achip" or nil, right2_icon_shade = achip_shade,
                    },
                    { text = sub_left, style = "small", color_token = sub_color,
                      -- This row's $/h readout, by name.
                      text_anchor = "add_table_ev:" .. stake.id .. ":" .. gtype_id,
                      right = sub_right, right_color_token = "muted" },
                },
            }
        end
    end

    -- Tables count / focus / capacity live on the rail (the sidebar
    -- duplicate was redundant). The local `active` and `cap` reads above
    -- still drive the per-button "tables full" / "buy-in unaffordable"
    -- disabled states.

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
    if not window then return false end
    local _, complete = OutcomeMath.effectiveWindow(window, ctx)
    return OutcomeMath.sumFills(ctx[fill_key], gt)
           >= complete + (ctx.run_upgrade_bonus_levels or 0)
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
                                 (nd.stack or 0) - (cd.stack or 0))
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

    -- Why a `fill_scaled` upgrade can read "MAX 11/29". The buyable cap tracks
    -- the highest stake currently available (GrindController:getRunUpgradeMaxLevel
    -- takes the largest fill_window.complete among them), so the level ceiling
    -- climbs as the ladder opens. Without this line the readout looks like a bug.
    if up.fill_scaled then
        local lvl = self.controller:getRunUpgradeLevel(up.id)
        local cap = self.controller:getRunUpgradeMaxLevel(up)
        if lvl >= cap and cap < (up.max_level or cap) then
            rows[#rows + 1] = _blurbRow(self,
                "Maxed for your stakes. Higher stakes raise the cap.")
        end
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
                cost_text  = Format.price(next_cost or 0)
            end
            if would_strand then
                desc_text = "open or rebuy a table first — buying now ends the run"
            end

            -- One upgrade row carries the GLOBAL cursor controls: the same
            -- two toggles as the per-stake rows, scoped to every open table.
            -- Which row that is comes from data/run_upgrades.lua, not from a
            -- name matched here.
            local up_actions
            if up.cursor_master_controls then
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
                -- The rack's face: a muted rose, the same hue the word
                -- "upgrade" takes in copy. Text on the card stays chrome.
                face_color = Theme.bg.upgrade_face,
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

-- The top bar's numbers, tweened toward the live state. Run every frame
-- by update(); the room screen, which draws this chrome too, runs it on
-- its own (no grid, no controller tick, but the bar stays live).
function GrindView:tweenChrome(dt)
    -- Tween top-bar numbers toward live state values.
    local state = self.game.state
    -- The underflow: the count breaks. Snap the display (no tween through
    -- trillions) and start the break (shake + flash) on the transition.
    local broken_now = ShoveRate.underflowed(state.bankroll)
    if broken_now and not self._was_broken then
        self._break_t0 = love.timer.getTime()
        self.displayed_bankroll = state.bankroll
    end
    self._was_broken = broken_now
    -- The loan arriving (a fresh grant, or a run reset renewing it): the
    -- number climbs from 0 to its value over COUNT_UP_SECS, then the normal
    -- tween takes over. GameState raises loan_fresh; this consumes it.
    do
        if state.loan_fresh then
            state.loan_fresh = false
            self.displayed_bankroll = 0
            self._count_up_t = 0
        end
        if self._count_up_t then
            self._count_up_t = self._count_up_t + (dt or 0)
            local p = math.min(1, self._count_up_t / (COUNT_UP_SECS * math.max(Motion.scale("text"), 0.001)))
            if Motion.level("text") <= Motion.LOW then p = 1 end
            self.displayed_bankroll = (state.bankroll or 0) * (1 - (1 - p) ^ 2)
            if p >= 1 then self._count_up_t = nil end
        end
    end
    if not self._count_up_t then
    self.displayed_bankroll = tweenNumber(self.displayed_bankroll, state.bankroll,            dt)
    end
    self.displayed_chips    = tweenNumber(self.displayed_chips,    state.chips,               dt)
    self.displayed_anti_chips = tweenNumber(self.displayed_anti_chips or 0, state.anti_chips or 0, dt)
    self.displayed_tied     = tweenNumber(self.displayed_tied,     self.controller:tiedUp(),  dt)
end

function GrindView:update(dt)
    local mx, my = love.mouse.getPosition()
    self.left_panel:update(my)
    self.right_panel:update(my)
    self.left_panel:updateHover(mx, my, self.game)
    self.right_panel:updateHover(mx, my, self.game)

    -- Drag upkeep. A latch with no button down means the release was
    -- swallowed (modal opened over it, focus lost) — cancel. While
    -- promoted, advance the hold feel (position, velocity tilt, lift).
    if self.drag then
        if not love.mouse.isDown(1) then
            self:cancelDrag()
        elseif self.drag.moved then
            TablePanelDrag.update(self.drag, dt, mx, my)
        end
    end

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

    -- Hit-test components for hover (writes "button" namespace into
    -- HoverService AND stashes any comp.tooltip via Tooltip.set).
    for _, panel in ipairs({ self.left_panel, self.right_panel, self.rail }) do
        local comps = panel:getComponents()
        if comps then
            local cy = panel:toContentY(my)
            CR.hitTest(comps, panel.x, panel.w, mx, cy, self.game)
        end
    end
    -- The chip pile says what it is on hover (its band, from the last draw).
    local pr = self._pile_rect
    if pr and mx >= pr.x and mx < pr.x + pr.w and my >= pr.y and my < pr.y + pr.h then
        TooltipSvc.set(Rail.tooltips.bankroll, mx, my)
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
                -- Key by table id when the box carries one: index-keyed
                -- hover would tint the wrong panel across a drag-reorder.
                self.game.hover.set("hit", hb.action .. ":" .. (hb.table_id or hb.idx))
            end
            if hb.tooltip then
                TooltipSvc.set(hb.tooltip, mx, my)
            end
        end
    end

    self:tweenChrome(dt)

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
        elseif b.kind == "seat_ko" then
            -- A tournament elimination — the mode's signature moment, so
            -- it gets a real one: the seat's stack detonates (tournament
            -- chips, tumbling, scattered to the panel), the panel takes a
            -- shake hit, the seat flashes while its finish tag stamps in
            -- (the panel's busted-seat branch reads the progress), KO
            -- floats off the seat, and the heaviest chip drop in the set
            -- lands it.
            local tbl = b.table
            TablePanelEffects.noteSeatKO(tbl, b.seat)
            tbl.shake_trauma = math.min(1, math.max(tbl.shake_trauma or 0, 0.45))
            local ps = (tbl.playback_state and tbl.playback_state.player_seat)
                       or tbl.player_seat_fixed
            if ps and b.seat ~= ps then
                local vis = (b.seat < ps) and b.seat or (b.seat - 1)
                local pos = AnchorRegistry.get(
                    TableModel.anchorKey(tbl, "opp_" .. vis))
                if pos then
                    -- Their stack, dying. Same tournament-chip vocabulary
                    -- as the bet flights (views/PokerEventAnims).
                    local c = AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
                    local within = (c and c[3] and c[4]) and { c[3], c[4] } or nil
                    local chips = { 1, 1, 1, 1, 1, 1, 1, 1 }
                    ChipFlight.explodeStack(pos[1], pos[2], chips, {
                        labels    = false,
                        within    = within,
                    })
                    self.game.floating_text.emit("KO", pos[1], pos[2],
                        { color_token = "error", lifetime = 1.2,
                          fit_table = tbl })
                end
            end
            FlightSystem.scheduleSound("seat_ko", 0.05)
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

-- Cents under $1k (floored, so the readout never overstates what's
-- purchasable), compact K/M/B above (so the top-bar cluster stays narrow).
local function moneyText(n) return Format.money(n) end

local function chipsText(n)
    if not n or n < 1 then return "0" end
    return Format.formatBig(math.floor(n))
end

-- ─── The rail ─────────────────────────────────────────────────────────
-- The chrome, as components: one row along the bottom, left to right the
-- way the money moves. Nav (gear, the book, the room) · the bankroll under
-- its pile · CASH OUT over what is tied up · FOCUS · the chips (banked,
-- next) · the deck · SHOVE. Every button exists from the first frame, dim
-- with its locked line until earned (data/rail.lua for the words). Drawn,
-- hovered and clicked by the same Panel + ComponentRenderer path the
-- sidebars use; RoomState draws the same rail.

local COVER_CTX = { on_felt = true }   -- the cover as a thumbnail: no invitation

local function iconRows(game, strs, color)
    local out = {}
    for _, str in ipairs(strs) do out[#out + 1] = TablePanelStats.iconRow(game, str, "sm", color) end
    return out
end

-- The room, as the picture on its button: the room (views/RoomView, lit,
-- at zoom 1) rendered once into a frame-sized canvas and kept until
-- something in it changes (what you own, corruption, the switch, a
-- delivery). Returns the canvas and the box the room occupies in it
-- (floor and everything drawn on it), so the face can frame the whole room.
function GrindView:_roomThumb()
    local sm   = self.game.state_machine
    local room = sm and sm.states and sm.states.room
    local rv   = room and room.getRoomView and room:getRoomView()
    if not (rv and love.graphics.newCanvas) then return nil end
    local st   = self.game.state
    local W, H = love.graphics.getDimensions()
    local key  = table.concat({ #(st.owned_items or {}), #(st.corrupted_items or {}),
                                rv.fixture_off and 1 or 0, #(st.room_unseen or {}), W, H }, ":")
    local t = self._room_thumb
    if t and t.key == key then return t.canvas, t.box end
    local ok, canvas = pcall(love.graphics.newCanvas, W, H, { dpiscale = 1 })
    if not ok then return nil end
    local prev = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    rv:draw(true, { zoom = 1, dy = 0, lighting = { fixture = rv.fixture_off and 0 or 1, emitters = true } })
    love.graphics.setCanvas(prev)
    love.graphics.pop()
    -- The room's extent: the floor's corners and the union of what stands
    -- on it (the walls and the things), from the draw that just happened.
    local b = rv._view and rv._view.bounds
    local u = rv._items_union
    local box = { x1 = b and b.x1 or 0, y1 = b and b.y1 or 0, x2 = b and b.x2 or W, y2 = b and b.y2 or H }
    if u then
        box.x1 = math.min(box.x1, u.x1); box.y1 = math.min(box.y1, u.y1)
        box.x2 = math.max(box.x2, u.x2); box.y2 = math.max(box.y2, u.y2)
    end
    self._room_thumb = { key = key, canvas = canvas, box = box }
    return canvas, box
end

-- The deck in play, as its button's face: the art with level pips
-- (views/DeckArt) and the progress bar to the next level along the bottom.
function GrindView:_drawDeckFace(spec, fx, fy, fw, fh)
    local state = self.game.state
    local s, fl = self.game.ui_scale or 1, math.floor
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    local gold  = Theme.currency and Theme.currency.chip or Theme.fg.heading
    DeckArt.draw(self.game, spec, fx, fy, fw, fh, { level = level, scale = s })
    -- The level bar, inside the art's bottom edge on a dark band so it
    -- reads at a glance (the old top-bar cell's); gold and full at max.
    local xp = (state.deck_xp and state.deck_xp[spec.id]) or 0
    local into, span = Decks.progressInLevel(spec, level, xp)
    local frac   = span and math.max(0, math.min(1, into / span)) or 1
    local bar_h  = math.max(Theme.space.hairline, fl(Theme.space.level_bar_h * s))
    local pad    = fl(Theme.space.level_bar_pad * s)
    local band_h = bar_h + pad * 2
    local band_y = fy + fh - band_h
    Theme.setColor(Theme.bg.window, 0.7)
    love.graphics.rectangle("fill", fx, band_y, fw, band_h)
    local bar_x, bar_y, bar_w = fx + pad, band_y + pad, fw - pad * 2
    Theme.setColor(Theme.bg.sunken)
    love.graphics.rectangle("fill", bar_x, bar_y, bar_w, bar_h, 1)
    Theme.setColor(span and Theme.fg.heading or gold)
    love.graphics.rectangle("fill", bar_x, bar_y, fl(bar_w * frac), bar_h, 1)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", bar_x, bar_y, bar_w, bar_h, 1)
end

-- The deck in play, in five lines. Progress is the bar on the button; the
-- roster has the rest.
function GrindView:_deckTooltip(spec)
    local state = self.game.state
    local id    = spec.id
    local level = (state.deck_levels and state.deck_levels[id]) or 0
    local maxed = level >= (spec.max_level or 5)
    local row   = TablePanelStats.iconRow
    local lines = {
        { text = string.format("%s   %s", spec.name or id,
            maxed and "maxed" or string.format("level %d of %d", level, spec.max_level or 5)),
          style = "sm", color_token = "heading" },
    }
    if level > 0 and spec.bonus and spec.bonus.per_level then
        lines[#lines + 1] = row(self.game, Decks.bonusTextAt(spec, level), "sm", "heading")
        lines[#lines + 1] = row(self.game, "(" .. Decks.bonusTextPerLevel(spec) .. ")", "sm", "muted")
    else
        lines[#lines + 1] = row(self.game, Decks.bonusTextPerLevel(spec), "sm", "primary")
    end
    lines[#lines + 1] = row(self.game, Decks.levelsOnText(spec), "sm", "muted")
    if spec.capstone and spec.capstone.text then
        lines[#lines + 1] = row(self.game,
            (maxed and "Capstone, earned: " or "Capstone, at level 5: ") .. spec.capstone.text,
            "sm", maxed and "heading" or "muted")
    end
    lines[#lines + 1] = { text = Rail.tooltips.deck_click, style = "sm", color_token = "faint" }
    return lines
end

function GrindView:_buildRailComponents()
    local game  = self.game
    local state = game.state
    local fonts = game.fonts
    local s     = game.ui_scale or 1
    local fl    = math.floor
    local ctrl  = self.controller
    local R     = Rail
    local SP    = Theme.space
    local sm      = game.state_machine
    local on_room = sm and sm.current and sm:current() == "room"
    local depth   = SP.button_depth
    local face_h  = RAIL_BTN_H - Button.allocatedH(0, depth)
    local btn_w   = fl(RAIL_BTN_H * SP.icon_button_w)
    local gap     = fl(SP.flex_gap * s)
    local n_open  = ctrl.pool:count()
    -- A readout hangs its label and value from the rail's bottom, so every
    -- value shares one baseline and every button one top and bottom.
    -- A readout's slot ends where the buttons' faces end (above their
    -- chunk), and its value's baseline sits on that line.
    local face_bottom = RAIL_BTN_H - depth
    local function stat(c) c.type = "stat"; c.h = c.h or face_bottom; c.valign = c.valign or "bottom"; return c end
    local function group(kids) return { type = "row", gap = gap, h = RAIL_BTN_H, align = "top", children = kids } end

    -- ── The buttons: the gear, the book, the room, the deck ──
    local gear = { type = "button", id = "nav:settings", anchor = "btn:settings",
        w = btn_w, face_h = face_h, depth = depth, tooltip = R.tooltips.settings,
        face_fn = function(fx, fy, fw, fh, g)
            local sz = fl(math.min(fw, fh) * SP.icon_share)
            Icons.drawGear(g, fx + fl((fw - sz) / 2), fy + fl((fh - sz) / 2), sz)
        end }
    -- Locked, a button is BLANK (the locked game-type keys' rule): no
    -- picture, no word, no line. The slot is there; nothing else is said.
    local cat_locked = not state.catalog_seen
    local book = { type = "button", id = "nav:catalog", anchor = "btn:catalog",
        w = btn_w, face_h = face_h, depth = depth,
        disabled = cat_locked, tooltip = (not cat_locked) and R.tooltips.catalog or nil,
        lines = {},
        face_fn = (not cat_locked) and function(fx, fy, fw, fh, _g)
            -- The book's own cover, at thumbnail size (the felt's rule).
            local pad = fl(SP.thumb_pad * s)
            local k = math.min((fw - pad * 2) / CatalogModal.COVER_W, (fh - pad * 2) / CatalogModal.COVER_H)
            local cw, ch = CatalogModal.COVER_W * k, CatalogModal.COVER_H * k
            love.graphics.push()
            love.graphics.translate(fx + fl((fw - cw) / 2), fy + fl((fh - ch) / 2))
            love.graphics.scale(k, k)
            CatalogModal.drawFrontCover(COVER_CTX, 0, 0, CatalogModal.COVER_W, CatalogModal.COVER_H, fonts, 1)
            love.graphics.pop()
        end or nil }
    local room_locked = not state.has_shoved
    -- Something bought and not yet seen in the room: ONE pulse when it
    -- arrives, then quiet. A delivery is a note, not an alarm.
    local unseen_n = state.room_unseen and #state.room_unseen or 0
    if not room_locked and not on_room and unseen_n > (self._room_unseen_n or 0) then
        AwardGlow.flash("nav:room")
    end
    self._room_unseen_n = unseen_n
    local room = { type = "button", id = "nav:room", anchor = "btn:room",
        anchor_also = on_room and "room:play" or nil,
        w = fl(RAIL_BTN_H * SP.room_thumb_w), face_h = face_h, depth = depth,
        disabled = room_locked,
        tooltip  = (not room_locked) and (on_room and R.labels.play or R.tooltips.room) or nil,
        lines    = {},
        face_fn = (not room_locked) and function(fx, fy, fw, fh, _g)
            -- The whole room, framed by its own extent.
            local canvas, box = self:_roomThumb()
            if canvas and box then
                local pad = fl(SP.thumb_pad * s)
                local bw, bh = math.max(1, box.x2 - box.x1), math.max(1, box.y2 - box.y1)
                local k = math.min((fw - pad * 2) / bw, (fh - pad * 2) / bh)
                local cxr, cyr = (box.x1 + box.x2) * 0.5, (box.y1 + box.y2) * 0.5
                local sx0, sy0, sw0, sh0 = love.graphics.getScissor()
                local tx, ty = love.graphics.transformPoint(fx, fy)
                love.graphics.intersectScissor(tx, ty, fw, fh)
                Theme.assetTint()
                love.graphics.draw(canvas, fx + fw * 0.5 - cxr * k, fy + fh * 0.5 - cyr * k, 0, k, k)
                if sx0 then love.graphics.setScissor(sx0, sy0, sw0, sh0) else love.graphics.setScissor() end
            end
            if on_room then
                -- On the room screen the same button is the way back.
                love.graphics.setFont(fonts.sm)
                local th = fonts.sm:getHeight()
                Theme.setColor(Theme.bg.sunken, 0.7)
                love.graphics.rectangle("fill", fx, fy + fl((fh - th) / 2), fw, th)
                Theme.setColor(Theme.fg.heading)
                love.graphics.printf(R.labels.play, fx, fy + fl((fh - th) / 2), fw, "center")
            end
        end or nil }
    local deck_open = Decks.systemUnlocked(state)
    local spec = deck_open and state.active_deck_id and Decks.specById(state.active_deck_id) or nil
    -- A deck opened and hasn't been seen: ONE pulse when it does, like
    -- the room's delivery. A note, not an alarm.
    local decks_unseen_n = state.decks_unseen and #state.decks_unseen or 0
    if deck_open and decks_unseen_n > (self._decks_unseen_n or 0) then
        AwardGlow.flash("deck")
    end
    self._decks_unseen_n = decks_unseen_n
    -- Locked, the key is BLANK: no name, no line, nothing to want by name.
    -- Open, it wears the deck in play; open with none in play yet, its name.
    local deck = { type = "button", id = "deck", anchor = "cell:deck",
        w = fl(RAIL_BTN_H * SP.deck_thumb_w), face_h = face_h, depth = depth,
        disabled = not deck_open,
        tooltip  = spec and self:_deckTooltip(spec) or (deck_open and R.tooltips.deck_click) or nil,
        lines    = (deck_open and not spec) and
                   { { text = R.labels.deck, style = "small", align = "center", color_token = "heading" } } or {},
        face_fn  = spec and function(fx, fy, fw, fh) self:_drawDeckFace(spec, fx, fy, fw, fh) end or nil }

    -- ── FOCUS, and the tables that drive it ──
    local focus_cap   = ctrl:currentFocusCapacity()
    local focus_pct   = fl(ctrl:currentFocusMult() * 100 + 0.5)
    -- Rolls toward the target like the money; the pop keys off the real
    -- target so it fires once per change.
    local focus_shown = fl(RollingValue.get("focus_pct", focus_pct) + 0.5)
    local over        = focus_shown < 100
    -- A healthy focus is simply fine (parchment); any penalty is money lost.
    local focus_color = over and Theme.sem.lost or Theme.fg.heading
    local fpop = Pop.onChange("focus", focus_pct, 0.5)
    if fpop > 0 then
        focus_color = {
            focus_color[1] + (1 - focus_color[1]) * fpop,
            focus_color[2] + (1 - focus_color[2]) * fpop,
            focus_color[3] + (1 - focus_color[3]) * fpop,
        }
    end
    local cap     = ctrl:tableSlotsCap()
    local eff_pen = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * ((ctrl.ctx and ctrl.ctx.focus_penalty_reduce_mult) or 1)
    local focus_tip = {
        R.tooltips.focus,
        string.format(R.tooltips.focus_ok, focus_cap),
        string.format(R.tooltips.focus_pen, eff_pen * 100, Constants.GAMEPLAY.FOCUS_FLOOR * 100),
        string.format(R.tooltips.focus_cap, cap),
    }
    local focus = stat{ label = R.labels.focus,
        value = focus_shown .. "%", value_color = focus_color,
        value_scale = Pop.scale(fpop, 1, 0.45),
        anchor = "cell:focus", tooltip = focus_tip }
    -- TABLES: open against the capacity, as a fill that reddens past it.
    local tables = stat{ label = R.labels.tables, value = "",
        bar = { frac = n_open / math.max(1, focus_cap), w = fl(SP.stat_bar_w * s),
                color = over and Theme.sem.lost or Theme.fg.heading },
        suffix = { text = n_open .. " / " .. focus_cap, color_token = over and "lost" or "muted" },
        tooltip = focus_tip }

    -- ── The money: what is tied up at the tables, and the bankroll under its pile ──
    local d_bank  = self.displayed_bankroll or state.bankroll or 0
    local d_tied  = self.displayed_tied     or ctrl:tiedUp()
    local d_chips = self.displayed_chips    or state.chips or 0
    local broken  = self:_broken()
    -- Tint the bankroll while a tween is in progress: won-green counting
    -- up, lost-red counting down.
    local bank_color = Theme.fg.heading
    local diff_bank  = (state.bankroll or 0) - d_bank
    if math.abs(diff_bank) > 0.01 then
        bank_color = (diff_bank > 0) and Theme.sem.won or Theme.sem.lost
    end
    local bank_str = moneyText(d_bank)
    if broken then
        -- The number is not a number any more. It never resolves.
        bank_str   = self:_brokenText(bank_str, "bank")
        bank_color = Theme.currency.achip
    end
    local tied_str = moneyText(d_tied)
    if broken then tied_str = self:_brokenText(tied_str, "tied") end
    -- "TIED UP $x" as the small line on top (where the labels are), the
    -- CASH OUT button under it on the value row.
    -- The small line's glyphs, then the same gap every value keeps under
    -- its label, then the button, ending on the bottom line like the rest.
    local tied_h = fonts.sm:getBaseline() + SP.stat_gap
    local cash_w = fonts.sm:getWidth(R.labels.cash_out) + fl(SP.word_button_pad * s)
    local tied = { type = "column", children = {
        stat{ value = R.labels.tied_up .. " " .. tied_str, value_style = "sm", h = tied_h, valign = "top",
              value_color = broken and Theme.currency.achip or Theme.fg.muted,
              anchor = "cell:tied", tooltip = R.tooltips.tied_up },
        { type = "button", id = "cash_out", anchor = "btn:cash_out", depth = depth,
          face_h = (RAIL_BTN_H - tied_h) - Button.allocatedH(0, depth),
          w = cash_w,
          disabled = n_open == 0,
          tooltip  = (n_open > 0) and R.tooltips.cash_out or R.locked.cash_out,
          lines = { { text = R.labels.cash_out, style = "small", align = "center", color_token = "heading" } } },
    } }
    -- The bankroll, big, with no label: the chips say what it is (the pile
    -- centres itself over this slot, see _drawBankrollChips).
    local bankroll = stat{ value = bank_str, value_style = "lg", value_color = bank_color,
        value_glow_color = broken and Theme.currency.achip or nil,
        anchor = "cell:bankroll", align = "center", tooltip = R.tooltips.bankroll }

    -- ── The chips: banked (yours) and next (this run's, banked when you shove) ──
    local pending = state.chips_this_run or 0
    -- The chips on top, what the next shove adds under them, on the
    -- bottom line with everything else.
    local chip_dim = (state.shove_count or 0) == 0 and pending == 0
    local count_h  = fonts.md:getBaseline()   -- the count's glyphs
    local banked = { type = "column", anchor = "cell:chips", children = {
        stat{ icon = "chip", value = chipsText(d_chips), h = count_h, valign = "top",
              dim = chip_dim, value_color = Theme.fg.heading,
              tooltip = { R.tooltips.banked, R.tooltips.next } },
        stat{ value = "+" .. pending .. " " .. R.labels.next, value_style = "sm",
              h = face_bottom - count_h, dim = chip_dim,
              value_color_token = (pending > 0) and "chip" or "faint", value_anchor = "chip_badge:shove",
              tooltip = { R.tooltips.banked, R.tooltips.next } },
    } }
    local anti
    if state.shove_r2_won then
        local d_achips = self.displayed_anti_chips or state.anti_chips or 0
        local pend_a   = state.anti_chips_this_run or 0
        anti = { type = "column", anchor = "cell:achips", children = {
            stat{ icon = "achip", value = chipsText(d_achips), h = count_h, valign = "top",
                  value_color = Theme.currency.achip },
            stat{ value = "+" .. pend_a .. " " .. R.labels.next, value_style = "sm",
                  h = face_bottom - count_h,
                  value_color_token = (pend_a > 0) and "corrupt" or "faint", value_anchor = "achip_badge:shove" },
        } }
    end

    -- ── SHOVE: the door, with the chip's gold on its edge ──
    local can_shove = ctrl:shoveUnlocked()
    local rates     = ShoveRate.compute(ctrl.ctx or {}, (state.bankroll or 0) + ctrl:tiedUp())
    local r1        = rates.raw_r1 or 0
    local rate_txt  = string.format("%.0f%%", r1 * 100)
    -- Parchment until the hand is a lock; then the colour of a hand won.
    local rate_tok  = (r1 >= 1.00) and "won" or "heading"
    if broken then
        rate_txt = self:_brokenText("-999%", "shove", 0.92, 0.12)
        rate_tok = "corrupt"
    end
    local shove_tip
    if can_shove then
        shove_tip = {
            { style = "sm", color_token = "muted", text = R.tooltips.shove_lede },
            TablePanelStats.iconRow(game, string.format(R.tooltips.shove_take, pending), "sm",
                                    (pending > 0) and "chip" or "muted"),
        }
        for _, r in ipairs(ShoveRate.formatBreakdown(rates)) do shove_tip[#shove_tip + 1] = r end
        shove_tip[#shove_tip + 1] = R.tooltips.shove_lock
    else
        shove_tip = nil   -- a greyed button does not pitch its own click
    end
    local shove = { type = "button", id = "shove", anchor = "btn:shove",
        w = fonts.md:getWidth(R.labels.shove) + fonts.sm:getWidth(rate_txt) + fl(SP.shove_button_pad * s),
        face_h = face_h, depth = depth,
        disabled = not can_shove,
        face_color = Theme.bg.widget_hover,
        border_color = Theme.sem.chip, border_line_width = Theme.space.line_strong,
        tooltip = shove_tip,
        lines = can_shove and {
            { text = R.labels.shove, style = "heading", align = "center", color_token = "heading",
              right = rate_txt, right_color_token = rate_tok, right_anchor = "cell:shove" },
        } or {},
        -- The quick-reset rescue straddles the shove's top edge when bricked.
        overlay = ctrl:canQuickReset() and {
            type = "button", id = "quick_reset", anchor = "btn:quick_reset", depth = SP.button_depth,
            w = fonts.sm:getWidth(R.labels.quick_reset) + fl(SP.overlay_button_pad * s),
            tooltip = iconRows(game, R.tooltips.quick_reset, "heading"),
            lines = { { text = R.labels.quick_reset, style = "small", align = "center", color_token = "heading" } },
        } or nil }

    -- ── The row ──
    -- Four groups. Things that belong together are a row of their own and
    -- move as one; the space left over spreads evenly between the groups.
    local money = group{ tied, bankroll }
    money.anchor = "rail:money"   -- the pile stands over this group
    local chips = anti and group{ banked, anti, shove } or group{ banked, shove }
    return {
        { type = "spacer", h = RAIL_PAD },
        { type = "row", h = RAIL_BTN_H, align = "top", justify = "between", gap = fl(SP.flex_min_gap * s),
          children = { group{ gear, book, room, deck }, group{ focus, tables }, money, chips } },
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

-- Cell size for a board of exactly cols x rows. The shape is decided by
-- the board itself (models/table_grid: tables own their cell, so the
-- shape is the bounding box of what's occupied) — this only fits pixels
-- to it, preserving the 4:3 aspect and the max-panel clamps.
local function fitCells(cols, rows, grid_w, grid_h)
    if cols <= 0 or rows <= 0 then return 0, 0 end
    local pw_avail = (grid_w - (cols - 1) * MARGIN) / cols
    local ph_avail = (grid_h - (rows - 1) * MARGIN) / rows
    if pw_avail <= 8 or ph_avail <= 8 then return math.max(1, pw_avail), math.max(1, ph_avail) end
    local pw, ph
    if pw_avail / ph_avail > PANEL_ASPECT then
        ph = ph_avail; pw = ph * PANEL_ASPECT
    else
        pw = pw_avail; ph = pw / PANEL_ASPECT
    end
    if pw > PANEL_MAX_W then pw = PANEL_MAX_W; ph = pw / PANEL_ASPECT end
    if ph > PANEL_MAX_H then ph = PANEL_MAX_H; pw = ph * PANEL_ASPECT end
    return pw, ph
end

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
    local grid_y = MARGIN
    local grid_w = W - LEFT_W - RIGHT_W - 2 * MARGIN
    local grid_h = H - RAIL_H - BOTTOM_BAND_H - 2 * MARGIN
    -- The table section's centre, for anything that needs "somewhere over
    -- the tables" without a specific table (item-fired ghosts fall back
    -- here). Same shape as the per-table center anchors: centre point + dims.
    AnchorRegistry.set("grid:center",
        grid_x + grid_w / 2, grid_y + grid_h / 2, grid_w, grid_h)

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

    -- Live drag? Resolve the held table each frame — if it closed
    -- mid-drag (pending_close finalized, tournament settled), the drag
    -- dies with it and the grid draws normally.
    local dragging = self.drag and self.drag.moved and self.drag
    local held_i
    if dragging then
        for i, t in ipairs(tables) do
            if t._id == dragging.table_id then held_i = i; break end
        end
        if not held_i then
            self.drag = nil
            dragging  = nil
        end
    end

    -- The board's shape comes from the tables themselves: each owns a
    -- cell, so the board is the bounding box of what's occupied. Interior
    -- holes stay only while the table count needs a board this size
    -- (TablePool:_reflow packs the moment it doesn't), and they cost
    -- everyone panel size. That is the price of holding a formation.
    local cols, rows = self.controller.pool:boardShape()
    if cols <= 0 or rows <= 0 then cols, rows = 1, 1 end

    -- Freeze cell SIZE while the mouse is stationary so closing several
    -- tables in a row doesn't resize panels under the cursor — successive
    -- [×] clicks land at the same spot. Invalidated on `mousemoved`, on a
    -- board-shape change, or on resize. Never frozen mid-drag.
    local frozen = self.frozen_grid
    local use_frozen = not dragging and frozen
        and frozen.grid_w == grid_w
        and frozen.grid_h == grid_h
        and frozen.cols == cols and frozen.rows == rows

    local pw, ph
    if use_frozen then
        pw, ph = frozen.pw, frozen.ph
    else
        pw, ph = fitCells(cols, rows, grid_w, grid_h)
        if dragging then
            self.frozen_grid = nil
        else
            self.frozen_grid = {
                pw = pw, ph = ph, cols = cols, rows = rows,
                grid_w = grid_w, grid_h = grid_h,
                -- Anchor for the mousemoved deadzone — small jitters
                -- around this point keep the freeze alive.
                anchor_x = love.mouse.getX(), anchor_y = love.mouse.getY(),
            }
        end
    end

    -- Center the cell block within the available grid area so leftover
    -- space (from aspect-clamping) sits as symmetric padding instead of
    -- pushing everything to the top-left.
    local block_w = cols * pw + (cols - 1) * MARGIN
    local block_h = rows * ph + (rows - 1) * MARGIN
    local origin_x = grid_x + math.floor((grid_w - block_w) / 2)
    local origin_y = grid_y + math.floor((grid_h - block_h) / 2)

    -- A cell is (row, col), packed — NOT an index into the table list.
    -- An index would address a different cell the moment the board
    -- widens, which is the renumbering slots exist to prevent.
    local function cellXY(slot)
        local r, c = TableGrid.unpack(slot)
        return origin_x + c * (pw + MARGIN), origin_y + r * (ph + MARGIN)
    end

    -- Which cell is the mouse over? Returns nil outside the board.
    local function slotAtPoint(mx, my)
        local c = math.floor((mx - origin_x) / (pw + MARGIN))
        local r = math.floor((my - origin_y) / (ph + MARGIN))
        if c < 0 or c >= cols or r < 0 or r >= rows then return nil end
        return TableGrid.pack(r, c)
    end

    -- Empty cells: holes the player left, and the unused corner of a
    -- board that grew for one more table. Drawn first so panels and the
    -- held drag panel sit above them.
    do
        local occupied = {}
        for _, t in ipairs(tables) do occupied[t.slot or 0] = true end
        for r = 0, rows - 1 do
            for c = 0, cols - 1 do
                local s = TableGrid.pack(r, c)
                if not occupied[s] then
                    local ex, ey = cellXY(s)
                    TablePanel.drawEmpty(ex, ey, pw, ph, self.game.fonts)
                end
            end
        end
    end

    -- Every panel's display position chases its cell through RollingValue
    -- (snap-on-first-sight, so boot/rebuild don't animate): panels glide
    -- on any reflow, and the drop settle rides the same chase from the
    -- seeded held position (see _settleDrag).
    if dragging then
        -- Drop target is a CELL, not an insertion point. Hovering an
        -- empty cell moves the held table there; hovering an occupied one
        -- swaps the two. The swap preview mirrors that: the table under
        -- the cursor slides to the held table's cell. Model slots are
        -- untouched until the drop, so hit-box idx values stay correct.
        local mx, my = love.mouse.getPosition()
        dragging.drop_slot = slotAtPoint(mx, my)
        local held_slot  = tables[held_i].slot
        local swap_id
        if dragging.drop_slot and dragging.drop_slot ~= held_slot then
            for _, t in ipairs(tables) do
                if t.slot == dragging.drop_slot then swap_id = t._id; break end
            end
        end

        for i = 1, n do
            if i ~= held_i then
                local tbl = tables[i]
                local target = (tbl._id == swap_id) and held_slot or tbl.slot
                local tx, ty = cellXY(target)
                local dx = RollingValue.get("tblx:" .. tbl._id, tx, SLIDE_RATE, "tables")
                local dy = RollingValue.get("tbly:" .. tbl._id, ty, SLIDE_RATE, "tables")
                TablePanel.draw(tbl, i, dx, dy, pw, ph,
                                self.game, self.controller, self.hit_boxes)
            end
        end
        -- Held panel renders from GrindView:draw (above the sidebars) —
        -- stash its live cell size for TablePanelDrag.drawHeld.
        self._held_draw = { tbl = tables[held_i], idx = held_i, pw = pw, ph = ph }
    else
        self._held_draw = nil
        for i = 1, n do
            local tbl = tables[i]
            local tx, ty = cellXY(tbl.slot or 0)
            local dx = RollingValue.get("tblx:" .. tbl._id, tx, SLIDE_RATE, "tables")
            local dy = RollingValue.get("tbly:" .. tbl._id, ty, SLIDE_RATE, "tables")
            -- Post-drop settle: a tiny scale bump as the panel lands,
            -- recentered so it grows in place.
            local pp = Pop.progress("tbl_settle:" .. tbl._id)
            if pp > 0 then
                local sc = Pop.scale(pp, 1, 0.04)
                local gw, gh = pw * sc, ph * sc
                TablePanel.draw(tbl, i, dx - (gw - pw) / 2, dy - (gh - ph) / 2,
                                gw, gh, self.game, self.controller, self.hit_boxes)
            else
                TablePanel.draw(tbl, i, dx, dy, pw, ph,
                                self.game, self.controller, self.hit_boxes)
            end
        end
    end
end

-- ─── THE HOUSE (the captor's poster) ──────────────────────────────────

-- Sits above the SHOVE button (what you shove against). The tutorial's
-- hint bubbles speak from it (views/HintView anchors them to "house"),
-- and the "?" help-desk button lives in its corner (TUTORIAL builds).
-- Drawn from shapes until art lands: a framed poster with a gold-roofed
-- house glyph.
function GrindView:_houseRect()
    local W, H = love.graphics.getDimensions()
    return {
        x = W - RIGHT_W + MARGIN, w = RIGHT_W - 2 * MARGIN,
        y = H - MARGIN - HOUSE_H,
        h = HOUSE_H,
    }
end
-- The "?" badge in the poster's bottom-right corner (TUTORIAL builds only).
function GrindView:_houseHelpBtnRect()
    local r  = self:_houseRect()
    local s  = self.game.ui_scale or 1
    -- Fixed badge size — it used to scale with the poster's height,
    -- which was fine at 92 and a slab at 184.
    local sz = math.floor(30 * s)
    local m  = math.floor(6 * s)
    return { x = r.x + r.w - sz - m, y = r.y + r.h - sz - m, w = sz, h = sz }
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

    -- The House's portrait (views/HouseArt): the same still print that
    -- hangs in the room. A poster, not a window — no animation, no
    -- caption; it doesn't introduce itself.
    local ax = r.x + inset + fl(2 * s)
    local ay = r.y + inset + fl(2 * s)
    local aw = r.w - (inset + fl(2 * s)) * 2
    local ah = r.h - (inset + fl(2 * s)) * 2
    HouseArt.paintPortrait(ax, ay, aw, ah)

    -- The intercom, bolted straight onto the poster's bottom-left: how
    -- the House speaks. Lit, breathing and rattling while a story line
    -- is up; dead otherwise.
    do
        local sw2 = fl(52 * s)
        local sh2 = fl(32 * s)
        -- "Speaking" = the band's text is mid-typewriter, the same window
        -- that drives the balloon buzz and the chopped radio voice.
        local speaking = 0
        local story, sv = self.game.story, self.game.story_view
        if story and story.currentLine and story:currentLine()
           and not story:isPaused()
           and sv and sv.isTyping and sv:isTyping() then
            speaking = 1
        end
        local spx, spy = ax + fl(6 * s), ay + ah - sh2 - fl(6 * s)
        HouseArt.drawSpeaker(spx, spy, sw2, sh2, speaking, love.timer.getTime())
        -- The story band draws a cable to this: the box the words come
        -- out of (views/StoryView).
        AnchorRegistry.set("house:speaker", spx, spy, sw2, sh2)
    end

    -- The "?" help-desk button, bottom-right corner of the poster.
    do
        local hb = self:_houseHelpBtnRect()
        AnchorRegistry.set("btn:help", hb.x, hb.y, hb.w, hb.h)
        local mx, my = love.mouse.getPosition()
        local hov = self.game.hover.rest("button", "help_btn",
                        mx >= hb.x and mx < hb.x + hb.w
                        and my >= hb.y and my < hb.y + hb.h, 0)
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
    end
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
        return Theme.semColor(tok)
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
                color = Theme.sem.won
            else
                color = Theme.status.error
            end
        end
        local font   = fonts[t.font or "lg"] or fonts.lg
        local scale  = t.scale or 1.0
        local alpha  = t.alpha or 1
        -- Never wider than the table it belongs to. At nine panels a
        -- fixed-size "+$3,932.37" is wider than its whole table and
        -- unreadable over the neighbours' floats; clamp the scale so the
        -- widest line fits inside the panel at any board density.
        local fit = t.fit_table or t.table
        if fit then
            local c = AnchorRegistry.get(TableModel.anchorKey(fit, "center"))
            local panel_w = c and c[3]
            if panel_w and panel_w > 24 then
                local widest = 0
                for line in (t.text .. "\n"):gmatch("(.-)\n") do
                    if line ~= "" then
                        local tw = line:find("{", 1, true)
                                   and IconText.measure(line, font)
                                   or font:getWidth(line)
                        if tw > widest then widest = tw end
                    end
                end
                if widest > 0 then
                    scale = math.min(scale, (panel_w - 12) / widest)
                end
            end
        end
        -- Spawn pop — the same one-shot grow-and-ease the showdown cards
        -- use: snaps in oversized, rests at the celebration size within a
        -- quarter second. Transient by construction (Pop.fromTimer hits 0
        -- and stays there), so the resting size is never scaled text.
        if not t.has_persisted then
            local age = (t.lifetime or 0) - (t.timer or 0)
            scale = scale * Pop.scale(Pop.fromTimer(age, 0.25), 1, 0.22)
        end
        -- A floater resting on an idle table (the last-hand residue) is
        -- pinned to its panel, not to the screen: adding or closing other
        -- tables repacks the grid, and a frozen "+$X" left at its spawn
        -- coords would sit over whatever panel moved in. Record the offset
        -- from the table's center anchor at rest and follow it.
        if t.has_persisted and t.table and not t.settle_anchor then
            local c = AnchorRegistry.get(TableModel.anchorKey(t.table, "center"))
            if c then
                if t.rest_dx == nil then
                    t.rest_dx, t.rest_dy = t.x - c[1], t.y - c[2]
                end
                t.x, t.y = c[1] + t.rest_dx, c[2] + t.rest_dy
            end
        end

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
        -- Parked floats sit on the felt indefinitely, over whatever color
        -- happens to be there — plate them like the hand-name pill so the
        -- number is readable on any ground (red on green was not).
        if t.has_persisted then
            local widest = 0
            for line in (t.text .. "\n"):gmatch("(.-)\n") do
                if line ~= "" then
                    local tw = line:find("{", 1, true)
                               and IconText.measure(line, font)
                               or font:getWidth(line)
                    if tw > widest then widest = tw end
                end
            end
            if widest > 0 then
                local block_h = (n_lines - 1) * step + line_h
                -- The parked readout's plate, in screen space, for story
                -- marks: views/TablePanel folds it into the stack box.
                if t.table and t.table._id then
                    AnchorRegistry.set("result:" .. tostring(t.table._id),
                        t.x + (-widest * 0.5 - 6) * scale, t.y + (ly - 3) * scale,
                        (widest + 12) * scale, (block_h + 6) * scale)
                end
                Theme.setColor(Theme.bg.window, 0.9 * alpha)
                love.graphics.rectangle("fill", -widest * 0.5 - 6, ly - 3,
                    widest + 12, block_h + 6, Theme.space.radius)
                Theme.setColor(Theme.border.soft, alpha)
                love.graphics.rectangle("line", -widest * 0.5 - 6, ly - 3,
                    widest + 12, block_h + 6, Theme.space.radius)
            end
        end
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
    local band_y = H - RAIL_H - BOTTOM_BAND_H   -- the pile band sits on the rail
    -- The pile stands over the money group (TIED UP and the bankroll): its
    -- centre is the group's (the rail drew it this frame and registered the
    -- anchor). Without a rail (a harness), the table column's centre.
    local slot = AnchorRegistry.get("rail:money")
    local center_x = slot and (slot[1] + slot[3] * 0.5) or (band_x + band_w * 0.5)
    self._pile_rect = { x = band_x, y = band_y, w = band_w, h = BOTTOM_BAND_H }
    local stack_y  = band_y + BOTTOM_BAND_H - 22

    -- Stash for emission code (1-frame stale, fine).
    AnchorRegistry.set("bankroll", center_x, stack_y)
    -- The House's story band: a strip sitting ON the pile band's top edge,
    -- between the sidebars. The panel bottom-aligns to it (views/StoryView),
    -- so the words end where the chips begin instead of over them.
    local strip_h = math.floor(40 * (self.game.ui_scale or 1))
    AnchorRegistry.set("story:band", band_x, band_y - strip_h, band_w, strip_h)

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
-- ── The underflow ─────────────────────────────────────────────────────
-- Once the bankroll is past the threshold the count is broken: the money
-- cells render as glyphs that never settle, in the anti ink, and SHOVE
-- reads -999%. The break itself (shake and flash) plays once, on the hand
-- that did it.
local BREAK_SECS = 1.4

function GrindView:_broken()
    return ShoveRate.underflowed(self.game.state.bankroll)
end

function GrindView:_breakProgress()
    if not self._break_t0 then return nil end
    local p = (love.timer.getTime() - self._break_t0) / BREAK_SECS
    if p >= 1 then return nil end
    return p
end

-- A string that never resolves: progress wanders between mostly-alien and
-- mostly-real, with a per-key phase so the cells do not breathe in step.
--   base   how resolved the string sits on average (default 0.42)
--   swing  how far it wanders either side of that (default 0.18)
function GrindView:_brokenText(str, key, base, swing)
    local now = love.timer.getTime()
    local ph  = (#key * 1.7) % 6.28
    local progress = (base or 0.42) + (swing or 0.18) * math.sin(now * 1.9 + ph)
    return GlyphMorph.text(str, progress, "underflow:" .. key, math.floor(now * 14))
end

function GrindView:_brokenGlow(str, font, x, y)
    love.graphics.setFont(font)
    Theme.setColor(Theme.currency.achip, 0.22)
    for _, o in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
        love.graphics.print(str, x + o[1], y + o[2])
    end
end

function GrindView:draw(overlay_fn)
    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Reset hit boxes — they're rebuilt during this draw pass.
    self.hit_boxes = {}

    -- The break: for BREAK_SECS after the underflow the whole screen
    -- shakes. Popped before the overlay; the flash goes on after.
    local break_p = self:_breakProgress()
    if break_p and not Motion.at("tables", Motion.FULL) then break_p = nil end
    if break_p then
        local k = (1 - break_p) * 9
        local t = love.timer.getTime() * 60
        love.graphics.push()
        love.graphics.translate(math.sin(t * 1.3) * k, math.cos(t * 1.7) * k)
    end

    self:drawChrome(W)
    self:_drawCenterGrid(W, H)
    self.left_panel:draw(self.game)
    self.right_panel:draw(self.game)
    self:_drawHouse()
    self:_drawFloatingText()

    -- Held (dragged) table panel — drawn after the sidebars and floating
    -- text so it rides above them while it's carried around; the chip
    -- flights, ghosts and cursor swarm below still render on top of it.
    if self.drag and self.drag.moved and self._held_draw then
        TablePanelDrag.drawHeld(self.game, self.controller, self.drag, self._held_draw)
    end

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

    -- Item-fired ghosts: the sprite of whichever catalog item just did its
    -- job, over the table that triggered it.
    ItemGhosts.draw(self.game)

    -- Cursor swarm — drawn last so cursors are always on top, including
    -- on top of the press-fade ghost they just dispatched.
    CursorPool.draw(self.game.fonts)

    if break_p then
        love.graphics.pop()
        Theme.setColor(Theme.currency.achip, (1 - break_p) * 0.55)
        love.graphics.rectangle("fill", 0, 0, W, H)
    end

    if overlay_fn then overlay_fn() end

    -- The hover tooltip is drawn by main.lua now, ABOVE the story dim and
    -- panel — the forced EV-hover lesson was rendering its own teaching
    -- material under the dim from here.

    -- Backtick debug tooltip — flushed last so it draws above every other
    -- view layer (sidebar panels, shove button, floating text, chips,
    -- cursors, hover tooltip all included).
    TablePanelStats.flushDebugOverlay(self.game)
end

-- ─── Mouse routing ────────────────────────────────────────────────────

-- Header actions latch on press and resolve on release, so a >4px move
-- can promote the press into a table drag instead. Felt actions (deal /
-- rebuy) are deliberately NOT here — they fire on mouse-DOWN, unchanged.
local HEADER_DRAG_ACTIONS = {
    remove_table        = true,
    toggle_cursor       = true,
    toggle_rebuy_cursor = true,
    drag_table          = true,
}
local DRAG_PROMOTE_PX = 4    -- < the 8px grid-freeze deadzone; promote
                             -- clears the freeze itself

-- ─── The chrome, shared with the room screen ─────────────────────────
-- The rail: its ground, then its components. The room screen draws the
-- same, so the money, the chips and the way out never leave the screen.

function GrindView:drawChrome(W)
    local H = select(2, love.graphics.getDimensions())
    local rw = self.rail.w
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", 0, H - RAIL_H, rw, RAIL_H)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("fill", 0, H - RAIL_H, rw, 1)
    love.graphics.rectangle("fill", rw - 1, H - RAIL_H, 1, RAIL_H)
    self.rail:draw(self.game)
end

function GrindView:railH() return RAIL_H end

-- The rail component under a point, by id ("shove", "nav:room", …), or nil.
function GrindView:chromeHit(x, y)
    if not self.rail or y < self.rail.y then return nil end
    local comps = self.rail:getComponents()
    if not comps then return nil end
    local hit = CR.hitTest(comps, self.rail.x, self.rail.w, x, self.rail:toContentY(y), self.game)
    return hit and hit.id or nil
end

-- The rail's click, dispatched like any sidebar button. True when the
-- click was the rail's (a control, or its ground).
function GrindView:chromeMousepressed(x, y)
    local id = self:chromeHit(x, y)
    if id then self:_handleSidebarButton(id) end
    local r = self.rail
    return id ~= nil or (r ~= nil and y >= r.y and x >= r.x and x < r.x + r.w)
end

function GrindView:mousepressed(x, y, b)
    if b ~= 1 then return end

    -- The rail first.
    if self:chromeMousepressed(x, y) then return end
    -- The "?" on THE HOUSE poster: the glossary rises from the poster.
    do
        local hb = self:_houseHelpBtnRect()
        if x >= hb.x and x < hb.x + hb.w
           and y >= hb.y and y < hb.y + hb.h then
            ClickFlash.flash("help_btn", "help_btn")
            if self.game.openHelp then self.game.openHelp() end
            return
        end
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

    -- Center grid: per-table hit boxes. Header boxes latch a possible
    -- drag (resolved on release); everything else dispatches on press.
    for _, hb in ipairs(self.hit_boxes) do
        if x >= hb.x and x < hb.x + hb.w and y >= hb.y and y < hb.y + hb.h then
            if HEADER_DRAG_ACTIONS[hb.action] then
                -- Copy the box: self.hit_boxes is wiped every draw, and
                -- this one has to survive until the release. Its idx may
                -- go stale — _handleHitBox re-resolves by table_id.
                local copy = {}
                for k, v in pairs(hb) do copy[k] = v end
                self.drag = {
                    table_id   = hb.table_id,
                    pressed_hb = copy,
                    x0 = x, y0 = y,
                    moved = false,
                    vx = 0, tilt = 0, lift = 0,
                }
                -- Press feel now, dispatch on release — without this the
                -- button would look inert while held.
                if hb.action ~= "drag_table" then
                    ClickFlash.flash("hit", hb.action .. ":" .. (hb.table_id or hb.idx))
                end
            else
                self:_handleHitBox(hb)
            end
            return
        end
    end
end

-- Start the drop glide: panel display positions chase through
-- RollingValue in the grid loop, so seeding the held position makes the
-- panel glide home (commit) or back (cancel) with no extra state.
function GrindView:_settleDrag(d)
    if not (d and d.moved and d.px) then return end
    RollingValue.set("tblx:" .. d.table_id, d.px)
    RollingValue.set("tbly:" .. d.table_id, d.py)
    Pop.trigger("tbl_settle:" .. d.table_id)
end

-- Cancel any drag in flight (ESC, focus loss, modal steal). Returns true
-- when a PROMOTED drag was cancelled, so the caller (GrindState's ESC)
-- knows to swallow the key instead of opening settings.
function GrindView:cancelDrag()
    local d = self.drag
    if not d then return false end
    self.drag = nil
    if d.moved then
        self:_settleDrag(d)
        return true
    end
    return false
end

function GrindView:_handleSidebarButton(id)
    ClickFlash.flash("button", id)
    -- The rail.
    if id == "nav:settings" then if self.game.openSettings   then self.game.openSettings()   end return end
    if id == "nav:catalog"  then if self.game.openCatalog    then self.game.openCatalog()    end return end
    if id == "nav:room"     then if self.game.toggleRoom     then self.game.toggleRoom()     end return end
    if id == "deck"         then if self.game.openDeckRoster then self.game.openDeckRoster() end return end
    if id == "quick_reset"  then if self.game.quickReset     then self.game.quickReset()     end return end
    if id == "cash_out"     then self.controller:cashOutAll()   return end
    if id == "shove"        then self.controller:initiateShove() return end
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
    -- Identity check: hit-boxes are built by draw and consumed up to a
    -- frame later (the cursor swarm especially), and table removals shift
    -- indices in between. When the box carries the table's id, re-resolve
    -- the index against the live pool — and drop the action entirely if
    -- that table is gone.
    if hb.table_id then
        local resolved
        for i, t in ipairs(self.controller.pool.tables) do
            if t._id == hb.table_id then resolved = i; break end
        end
        if not resolved then return end
        hb.idx = resolved
    end

    if hb.action and hb.idx then
        -- table_id-keyed when present (matches the hover key + the
        -- TablePanel render reads) so a reorder can't cross-tint.
        ClickFlash.flash("hit", hb.action .. ":" .. (hb.table_id or hb.idx))
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

function GrindView:mousereleased(x, y, b)
    self.left_panel:handleMouseUp()
    self.right_panel:handleMouseUp()

    local d = self.drag
    if not d then return end
    if b and b ~= 1 then return end
    self.drag = nil

    if not d.moved then
        -- Plain header click: dispatch the button that was pressed.
        -- _handleHitBox re-resolves by table_id and silently drops the
        -- action if the table vanished between press and release.
        if d.pressed_hb and d.pressed_hb.action ~= "drag_table" then
            self:_handleHitBox(d.pressed_hb)
        end
        return
    end

    -- Promoted drag. Negative coords are the synthetic focus-loss
    -- release (main.lua love.mousefocus) — cancel, never derive a cell
    -- from them.
    if x < 0 or y < 0 then
        self:_settleDrag(d)
        return
    end
    if d.drop_slot then self.controller:moveTableToSlot(d.table_id, d.drop_slot) end
    self:_settleDrag(d)
end

-- Deadzone radius (px) for the grid-layout freeze. Real hand jitter on a
-- mouse is typically 1-3 px between clicks; 8 px swallows that without
-- letting an actual nudge toward a different button stay frozen.
local FREEZE_DEADZONE_PX = 8

function GrindView:mousemoved(x, y, _, _)
    -- Drag promote: a latched header press becomes a real drag once the
    -- mouse travels past the threshold. Capture the grab offset from the
    -- panel's last drawn rect (tbl.x/tbl.y, stashed by TablePanel.draw)
    -- so the panel doesn't jump to put its corner under the cursor.
    local d = self.drag
    if d and not d.moved
       and (math.abs(x - d.x0) > DRAG_PROMOTE_PX
            or math.abs(y - d.y0) > DRAG_PROMOTE_PX) then
        local tbl
        for _, t in ipairs(self.controller.pool.tables) do
            if t._id == d.table_id then tbl = t; break end
        end
        if not tbl then
            self.drag = nil          -- table closed while pressed
        else
            d.moved   = true
            d.grab_dx = d.x0 - (tbl.x or x)
            d.grab_dy = d.y0 - (tbl.y or y)
            d.px      = x - d.grab_dx
            d.py      = y - d.grab_dy
            -- Promote threshold (4px) sits inside the freeze deadzone
            -- (8px): drop the freeze explicitly so the preview reflows.
            self.frozen_grid = nil
        end
    end

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
