-- views/GrindView.lua
--
-- The grind screen. Three-column layout:
--   • Top bar (50px) — bankroll, chips, run stats
--   • Left sidebar (Panel) — Tables tab with stake-add buttons + slot count.
--                             Phase 5 will add a Catalog tab here.
--   • Center grid — up to MAX_TABLES tiled table panels (a full 6×6 board).
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
local HoldPress      = require("services.HoldPress")
local HoverSvc       = require("services.HoverService")
local TablePanel     = require("views.TablePanel")
local TablePanelStats = require("views.TablePanelStats")
local TablePanelEffects = require("views.TablePanelEffects")
local TableModel     = require("models.Table")
local GameTypeThemes = require("data.game_type_themes")
local Pop            = require("services.Pop")
local RollingValue   = require("services.RollingValue")
local Memo           = require("services.Memo")
local Motion         = require("services.Motion")
local Perf           = require("services.Perf")
local HouseArt       = require("views.HouseArt")
local CursorPool     = require("services.CursorPool")
local Icons          = require("views.Icons")
local IconText       = require("views.IconText")
local Denoms        = require("services.DenominationBreakdown")
local ChipData       = require("data.chips")
local FlightSystem   = require("services.FlightSystem")
local ChipFlight     = require("views.ChipFlight")
local ChipPile       = require("views.ChipPile")
local PanelSheet     = require("views.PanelSheet")
local BoardPreview   = require("models.board_preview")
local CursorIntent   = require("services.CursorIntent")
-- Tables open and close like windows: OPEN_FROM smaller, over OPEN_SECS / CLOSE_SECS.
local OPEN_FROM, OPEN_SECS, CLOSE_SECS = 0.15, 0.28, 0.26
local ClickSurfaces  = require("services.ClickSurfaces")
local Poke           = require("services.Poke")
local Chips          = require("views.Chips")
local ClickFlash     = require("services.ClickFlash")
local TooltipSvc     = require("services.Tooltip")
local AnchorRegistry = require("services.AnchorRegistry")
local Button         = require("views.Button")
local LabelButton    = require("views.widgets.LabelButton")
local AwardGlow      = require("views.AwardGlow")
local Ghosts         = require("services.Ghosts")
local ItemStream     = require("views.ItemStream")
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
local OutcomeBar     = require("views.OutcomeBar")
local Lookups        = require("utils.lookups")
local Rail           = require("data.rail")
local RateTicker     = require("data.rate_ticker")
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

-- The right column's measures for a window: the layout below and
-- GrindView.storyBoxRect (which every screen's House box uses) both read
-- these, so the box sits in the same place whether the grind drew or not.
local function rightColumnW(W) return math.max(320, math.floor(W * 0.22)) end
local function marginFor(s)    return math.floor(12 * s) end
local function houseHFor(s)    return math.floor(184 * s) end

-- The House's text box height: STORY_BOX_LINES lines of the small font,
-- its padding and the "click" cue row (views/StoryView).
local STORY_BOX_LINES = 3
local function storyBoxH(game)
    local s  = game.ui_scale or 1
    local fh = (game.fonts and game.fonts.sm and game.fonts.sm:getHeight())
               or math.floor(16 * s)
    return math.floor(10 * s) * 2 + fh * STORY_BOX_LINES + fh + math.floor(4 * s)
end

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
    HOUSE_H              = houseHFor(s)
    BOTTOM_BAND_H        = math.floor(90  * s)
    PANEL_REMOVE_BTN_SIZE = math.floor(22 * s)
    PILL_H               = math.floor(18 * s)
    PILL_GAP             = math.floor(4  * s)
    MARGIN               = marginFor(s)

    -- Sidebars: window-fraction with absolute minimums. The minimum
    -- is NOT layout-scale-multiplied — at 720p the heading text on
    -- stake-add buttons ("+ $0.01/$0.02" + "+1 chip" badge) needs ~290
    -- px to fit on a single line at the design font size, and a
    -- scaled-down minimum (220 * 1.0) lets it wrap.
    LEFT_W  = math.max(290, math.floor(W * 0.18))
    RIGHT_W = rightColumnW(W)

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

    -- The Tables tab's rolled numbers, read once per frame in its inputs
    -- (RollingValue.get advances a value, so a second read would roll it
    -- twice) and stashed here for the build. The keys are made once:
    -- building "gtype_press:zoom" every frame was a string per key per
    -- frame.
    self._press, self._press_key, self._btn_ev = {}, {}, {}
    for _, gt in ipairs(GameTypes) do self._press_key[gt.id] = "gtype_press:" .. gt.id end
    self:_makeRailClosures()
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

    -- Each tab's tree is retained by the Panel and rebuilt only when its
    -- `inputs` move (the keys each builder reads; see the inputs functions
    -- beside the builders). The rail also `refresh`es its live numbers in
    -- place every frame.
    self.left_panel = Panel:new(0, 0, LEFT_W, H - RAIL_H)
    self.left_panel:registerTab({
        id       = "tables",
        label    = "Tables",
        priority = 0,
        build    = function() return self:_buildTablesTabComponents() end,
        inputs   = function(_, arr) return self:_tablesTabInputs(arr) end,
    })
    -- Catalog tab removed — purchases now happen in views/CatalogModal.lua
    -- after each bust. The chip shop is only accessible between runs.

    -- Right panel runs to the bottom of the screen (the rail stops at its
    -- edge) and reserves THE HOUSE poster at its foot, with the House's
    -- text box between them (:_storyBoxRect).
    local right_panel_h = H - HOUSE_H - 2 * MARGIN - self:_storyBoxH() - MARGIN
    self.right_panel = Panel:new(W - RIGHT_W, 0, RIGHT_W, right_panel_h)
    self.right_panel:registerTab({
        id       = "upgrades",
        label    = "Upgrades",
        priority = 0,
        build    = function() return self:_buildUpgradesTabComponents() end,
        inputs   = function(_, arr) return self:_upgradesTabInputs(arr) end,
    })

    -- The rail: the chrome, one flex row along the bottom, left of the
    -- right sidebar, drawn and hit-tested by the same Panel +
    -- ComponentRenderer path. The row spreads inside whatever width that is.
    self.rail = Panel:new(0, H - RAIL_H, W - RIGHT_W, RAIL_H)
    self._side_panels = { self.left_panel, self.right_panel }
    self.rail:registerTab({
        id       = "rail",
        label    = "Rail",
        priority = 0,
        build    = function() return self:_buildRailComponents() end,
        inputs   = function(_, arr) return self:_railInputs(arr) end,
        refresh  = function() self:_refreshRail() end,
    })

    -- The three panels as one list, so the per-frame hover walk stops
    -- rebuilding a throwaway table to iterate them.
    self._panels = { self.left_panel, self.right_panel, self.rail }
end
-- ─── Panel content builders (called by Panel:draw when a tab's inputs move) ──

-- Game-type keys: a row of four buttons at the top of the Tables tab.
-- Selecting one swaps which stake-add rows render below. Cassette-deck
-- selection: every open key rides HIGH on a deep rim; the selected one is
-- HELD DOWN, pressed flat with a lit legend, so the shape carries the
-- state. Locked keys (Constants.GTYPE_GATE) stay: dark, flush, blank and
-- inert, a slot to want. The story beats do the explaining when each opens.
-- Hover is the renderer's (CR._button lightens the face): a key tinted
-- here on hover would make the pointer a rebuild key for the whole tab.
local STRIP_ORDER = { "zoom", "hu", "six_max", "ko" }

function GrindView:_makeGameTypeStrip()
    local fh        = self.game.fonts.sm:getHeight()
    local s         = self.game.ui_scale or 1
    local KEY_DEPTH = 10
    local kids = {}
    -- In unlock order, left to right: Zoom opens first, then Heads-Up,
    -- 6-Max, the tournament (not the data order).
    for _, gid in ipairs(STRIP_ORDER) do
        local gt = Lookups.findById(GameTypes, gid)
        if gt then
        local locked = not self.controller:gtypeAvailable(gt.id)
        local active = (gt.id == self.selected_gtype) and not locked
        local id     = "gtype:" .. gt.id
        -- Press TRAVEL is animated: the key eases down when it becomes
        -- selected and back up when it isn't, on a wall-clock lerp. Read
        -- in _tablesTabInputs (which rebuilds this strip as it moves).
        local press  = self._press[gt.id]
        if press == nil then press = (active or locked) and 1 or 0 end
        -- The key wears its game type's chrome (data/game_type_themes), the
        -- same colour the table headers wear: full when selected, sunk when
        -- not, near-out when locked.
        local chrome = GameTypeThemes[gt.id] and GameTypeThemes[gt.id].chrome_color
        local fill
        if chrome then
            local k = active and 0.60 or 0.85
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
                  color_token = active and "heading" or "muted" },
            } or {},
        }
        end
    end
    return { type = "row", gap = 2, children = kids }
end

-- "btn_ev:<stake>:<gtype>", the stake row's rolled-EV key, made once per
-- combo (a bounded set) instead of concatenated per row per frame.
function GrindView:_evKey(stake_id, gtype_id)
    local keys = self._ev_keys
    if not keys then keys = {}; self._ev_keys = keys end
    local by = keys[gtype_id]
    if not by then by = {}; keys[gtype_id] = by end
    local k = by[stake_id]
    if not k then k = "btn_ev:" .. stake_id .. ":" .. gtype_id; by[stake_id] = k end
    return k
end

-- What the Tables tab is built from (views/Panel inputs): the fonts and
-- scale, the display revision, the selected key, whether the board is
-- full, the Act 3 badge, the bounty and pool-summary revisions, the cursor
-- perks, each key's lock and press travel (quantized to 1/64), and per
-- stake its visibility, its affordability and its rolled EV in cents.
-- The rolled values are read here, once, and stashed for the build. The
-- clamp of a stale selection to zoom lives here too, since it is the
-- selection the build reads.
function GrindView:_tablesTabInputs(arr)
    local game, state, ctrl = self.game, self.game.state, self.controller
    if not ctrl:gtypeAvailable(self.selected_gtype) then
        self.selected_gtype = "zoom"
    end
    local gtype_id = self.selected_gtype
    local ctx      = ctrl.ctx
    local full     = ctrl.pool:count() >= ctrl:tableSlotsCap()
    local n = 0
    n = n + 1; arr[n] = CR.layout_gen
    n = n + 1; arr[n] = game.ui_scale or 1
    n = n + 1; arr[n] = ctrl.display_rev or 0
    n = n + 1; arr[n] = gtype_id
    n = n + 1; arr[n] = full
    n = n + 1; arr[n] = state.shove_r2_won == true
    n = n + 1; arr[n] = ctrl.banked_rev or 0
    n = n + 1; arr[n] = ctrl.summary_rev or 0
    n = n + 1; arr[n] = (ctx and ctx.cursor_unlocked) == true
    n = n + 1; arr[n] = (ctx and ctx.cursor_rebuy_unlocked) == true
    n = n + 1; arr[n] = self._preview_up or false
    local gmask = 0
    for _, gt in ipairs(GameTypes) do
        local locked = not ctrl:gtypeAvailable(gt.id)
        local active = (gt.id == gtype_id) and not locked
        gmask = gmask * 2 + (locked and 1 or 0)
        local press = RollingValue.get(self._press_key[gt.id], (active or locked) and 1 or 0, 14, "ui")
        self._press[gt.id] = press
        n = n + 1; arr[n] = math.floor(press * 64)
    end
    n = n + 1; arr[n] = gmask
    local gtype_obj = Lookups.findById(GameTypes, gtype_id)
    local bankroll  = state.bankroll or 0
    local smask = 0
    for _, stake in ipairs(Stakes) do
        local vis    = ctrl:stakeAvailable(stake)
        local afford = vis and bankroll >= (stake.buy_in or 0)
        smask = smask * 4 + (vis and 2 or 0) + (afford and 1 or 0)
        if afford and not full then
            local ev = TablePanelStats.evPerHand(ctrl, stake, gtype_obj)
            if ev then
                local rolled = RollingValue.get(self:_evKey(stake.id, gtype_id), ev)
                self._btn_ev[stake.id] = rolled
                n = n + 1; arr[n] = math.floor(rolled * 100)
            end
        end
    end
    n = n + 1; arr[n] = smask
    return n
end

function GrindView:_buildTablesTabComponents()
    local state  = self.game.state
    local cap    = self.controller:tableSlotsCap()
    local active = self.controller.pool:count()

    local components = {}
    local s_ui = self.game.ui_scale or 1
    components[#components + 1] = {
        type = "label", style = "muted", text = "{table} ADD TABLE",
        h = self.game.fonts.md:getHeight() + math.floor(10 * s_ui),
    }

    -- Game-type keys.
    components[#components + 1] = self:_makeGameTypeStrip()
    components[#components + 1] = { type = "spacer", h = math.floor(4 * s_ui) }
    -- A full board says so once, here, not on every row below.
    if active >= cap then
        components[#components + 1] = {
            type = "label", style = "muted",
            text = string.format("Tables full: %d of %d", active, cap),
            h = self.game.fonts.md:getHeight() + math.floor(6 * s_ui),
        }
    end

    -- Stake-add buttons for the currently selected game type. Button id
    -- is composite "add_table:<stake>:<gtype>" so the dispatcher routes
    -- to controller:addTable(stake_id, game_type_id).
    -- A stale selection of a still-locked mode (old save state, or a gate
    -- future-tightened) was clamped back to zoom in _tablesTabInputs.
    local gtype_id  = self.selected_gtype
    local gtype_obj = Lookups.findById(GameTypes, gtype_id)
    -- Cursor perks gate the per-row cursor toggles, same two flags the
    -- per-table cursor switch reads.
    local ctx       = self.controller and self.controller.ctx
    local cursor_on = (ctx and ctx.cursor_unlocked) or false
    local first_open_row = false   -- "add_table:open" names the first row with open tables
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

            -- The row's odds bar and, while a previewing upgrade is hovered,
            -- its next level.
            -- Only for a table you can open now: a row out of reach says its
            -- buy-in and nothing else.
            local row_ev   = (affordable and gtype_obj) and self.controller:evStats(stake, gtype_obj) or nil
            local row_stats = row_ev and row_ev.pool or nil
            local prev_up  = row_stats and self._preview_up and Lookups.findById(RunUpgrades, self._preview_up)
            local row_next = prev_up and self:_stakePreview(prev_up, stake, gtype_obj) or nil
            local row_pv   = row_next and GrindView.previewText(prev_up.tooltip_metric, row_stats, row_next) or nil
            -- $/h EV — only when the table can actually be opened. The
            -- bb-normalized value stays the color threshold so good/bad
            -- doesn't shift with stake size; bb/h itself is tooltip-only.
            local sub_left, sub_right, sub_color
            -- A full board is said once above the list; a row keeps its
            -- buy-in and, when the bankroll covers it, its $/h.
            do
                sub_right = "buy-in " .. Format.price(stake.buy_in or 0)
                if not cant_afford then
                    local ev = TablePanelStats.evPerHand(self.controller, stake, gtype_obj)
                    if ev then
                        -- Rolls like the per-table readouts (read this frame
                        -- in _tablesTabInputs); color from the rolled value
                        -- so tint and number always agree.
                        local rolled = self._btn_ev[stake.id]
                        if rolled ~= nil then ev = rolled end
                        local bb    = (stake.bb and stake.bb > 0) and stake.bb or 1
                        local ev_bb = ev / bb
                        sub_left  = TablePanelStats.evLabel(ev)
                        sub_color = (ev_bb > 0.05 and "good") or (ev_bb < -0.05 and "error") or "muted"
                    end
                end
                -- A hovered upgrade's next level stands in for the $/h
                -- while it is hovered (same line, so the row keeps its size).
                if row_pv then
                    sub_left  = row_pv.short
                    sub_color = (prev_up.tooltip_metric == "win_chance") and "good" or "chip"
                end
            end
            -- The bar's line fits into the row's padding (pad_trim).
            local row_bar_h = math.max(3, math.floor(4 * s_ui))

            -- Bounty badges. Every stake pays a {chip} for winning a stack;
            -- in Act 3 every stake also pays an {achip} for losing one, shown
            -- as a second badge beside the gold. Green + full colour once
            -- banked this run; greyed while unearned, greyer still when you
            -- can't even buy in. The trim goes gold when the {chip} is
            -- banked, purple when only the {achip} is.
            local banked  = self.controller:bountyBanked(stake.id, gtype_id)
            -- Advertised while unbanked; once banked, what it actually paid.
            local award   = (banked and self.controller:bountyPaid(stake.id, gtype_id))
                            or self.controller:bountyAward(stake.id, gtype_id)
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
            local open_n, deal_muted =
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
                  anchor = "cash_out_type" .. suffix,    -- the story points at the X's (focus_overload)
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
            -- The cursors deal at none of this row's tables: faint hatching
            -- on the button (each table's own DEAL says so too). Right-click
            -- the row to switch (:_rightClick).
            local no_cursors = cursor_on and not none and deal_muted >= open_n

            components[#components + 1] = {
                type     = "button",
                actions  = actions,
                no_cursors = no_cursors,
                id       = "add_table:" .. stake.id .. ":" .. gtype_id,
                -- Named hint-anchor (same string as the id) so tutorial
                -- hints can highlight this button. Once this combo has
                -- banked its bounty, the "+N {chip}" badge also registers
                -- as "chip_badge:banked" (any banked button; last drawn
                -- wins) for the chip-teaching hints.
                anchor       = "add_table:" .. stake.id .. ":" .. gtype_id,
                -- The row that has banked, under one shared name, for the
                -- lines about the button that paid.
                -- "add_table:open": the first row with open tables, for the
                -- cursor beat's "right click a table button".
                anchor_also  = { banked and "add_table:banked" or nil,
                                 (open_n > 0 and not first_open_row) and "add_table:open" or nil },
                badge_anchor = banked and "chip_badge:banked" or nil,
                disabled = disabled,
                -- The stake row wears its stake's felt — the same color
                -- the tables it opens play on. (The game type is already
                -- said by the chrome-colored tab strip above the rows.)
                face_color   = TablePanel.feltForStake(stake.id),
                -- A full board is plain grey (said once above); out of
                -- reach keeps the felt, darkened, the buy-in in red.
                state        = (cant_afford and not full) and "cant_afford" or nil,
                pad_trim     = row_stats and (row_bar_h + 3) or nil,
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
                      right = sub_right,
                      right_color_token = (cant_afford and not full) and "error" or "muted" },
                    -- Its odds (views/OutcomeBar), and a hovered upgrade's
                    -- next level as numbers.
                    -- While an upgrade is hovered: the next level, its
                    -- segments in focus, outlined (the $/h line above says
                    -- the numbers).
                    row_stats and { bar = (row_pv and row_pv.next) or row_stats, bar_h = row_bar_h,
                                    focus = row_pv and row_pv.focus, highlight = row_pv and row_pv.color } or nil,
                },
            }
            if open_n > 0 then first_open_row = true end
        end
    end

    -- Tables count / focus / capacity live on the rail (the sidebar
    -- duplicate was redundant). The local `active` and `cap` reads above
    -- still drive the rows' disabled state and the one "tables full"
    -- line under the header.

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

-- Upgrades whose effect "fills" toward a per-stake cap preview their next
-- level as an odds bar (views/OutcomeBar): in the tooltip, on the tables
-- and on the add-table rows. `keys` are the ctx fill lists one more level
-- appends to (GrindView:_nextCtx).
local RANGE_TOOLTIP = {
    win_chance = { keys = { "win_chance_fills" } },
    win_dist   = { keys = { "win_dist_fills", "loss_dist_fills" } },
}

-- ── The outcome bar's next-level preview ────────────────────────────────
-- An upgrade with a range tooltip (RANGE_TOOLTIP) previews its next level:
-- the ctx with one more fill on its keys. Built once per display revision
-- and upgrade.
local function statsDiffer(a, b)
    if not (a and b) then return false end
    if math.abs((a.win_chance or 0) - (b.win_chance or 0)) > 1e-9 then return true end
    for _, side in ipairs({ "win_dist", "loss_dist" }) do
        local x, y = a[side] or {}, b[side] or {}
        for _, t in ipairs({ "small", "medium", "large", "stack" }) do
            if math.abs((x[t] or 0) - (y[t] or 0)) > 1e-9 then return true end
        end
    end
    return false
end
GrindView.statsDiffer = statsDiffer

-- What a hovered upgrade's next level changes, as numbers: its own metric,
-- now and next. Sharper Reads moves the win chance; Pot Control the stack
-- win (and the stack loss down). { text, short (narrow tables), color }.
local function pctStr(x) return string.format("%.1f%%", x * 100) end
local function previewText(metric, now, nxt)
    if not (now and nxt) then return nil end
    local wc0, wc1 = now.win_chance or 0, nxt.win_chance or 0
    local focus = (metric == "win_chance") and "win" or "stack"
    -- Nothing moves on this table: say so and why, rather than show no
    -- card (a table at the win-chance ceiling, a Zoom table lifted there
    -- by the hands-per-second items, gains nothing from more odds).
    if not statsDiffer(now, nxt) then
        local why = (wc0 >= OutcomeMath.WC_ABSOLUTE_CAP - 1e-6) and ("at the ceiling, " .. pctStr(wc0))
                    or "maxed at this stake"
        return { text = "No change: " .. why, short = "No change", color = Theme.fg.muted,
                 now = now, next = nxt, focus = focus, none = true }
    end
    if metric == "win_chance" then
        local t = "Win " .. pctStr(wc0) .. " {arrow} " .. pctStr(wc1)
        return { text = t, short = t, color = Theme.sem.won, now = now, next = nxt, focus = "win" }
    end
    local st0 = wc0 * ((now.win_dist or {}).stack or 0)
    local st1 = wc1 * ((nxt.win_dist or {}).stack or 0)
    local sl0 = (1 - wc0) * ((now.loss_dist or {}).stack or 0)
    local sl1 = (1 - wc1) * ((nxt.loss_dist or {}).stack or 0)
    local short = "Stack win " .. pctStr(st0) .. " {arrow} " .. pctStr(st1)
    local text = short
    if math.abs(sl1 - sl0) > 5e-4 then
        text = short .. "   loss " .. pctStr(sl0) .. " {arrow} " .. pctStr(sl1)
    end
    return { text = text, short = short, color = Theme.sem.chip, now = now, next = nxt, focus = "stack" }
end
GrindView.previewText = previewText

function GrindView:_nextCtx(up)
    local spec = up and up.tooltip_metric and RANGE_TOOLTIP[up.tooltip_metric]
    if not spec then return nil end
    local ctrl = self.controller
    local token = tostring(ctrl.display_rev or 0) .. ":" .. up.id
    local nc = self._next_ctx
    if nc and nc.token == token then return nc.ctx end
    local ctx, nextctx = ctrl.ctx or {}, {}
    for k, v in pairs(ctx) do nextctx[k] = v end
    for _, key in ipairs(spec.keys) do
        local list = {}
        for _, d in ipairs(ctx[key] or {}) do list[#list + 1] = d end
        list[#list + 1] = { strength = 1 }
        nextctx[key] = list
    end
    self._next_ctx = { token = token, ctx = nextctx }
    self._preview_memo = {}
    return nextctx
end

-- The upgrade whose button is under the pointer, when it previews.
local PREVIEW_UPS
function GrindView:_hoveredPreview()
    if not PREVIEW_UPS then
        PREVIEW_UPS = {}
        for _, up in ipairs(RunUpgrades) do
            if up.tooltip_metric and RANGE_TOOLTIP[up.tooltip_metric] then
                PREVIEW_UPS[#PREVIEW_UPS + 1] = { key = "buy_runup_" .. up.id, up = up }
            end
        end
    end
    local Hover = self.game.hover or require("services.HoverService")
    for _, p in ipairs(PREVIEW_UPS) do
        if Hover.is("button", p.key) then return p.up end
    end
    return nil
end

-- Per frame (update): every table's next-level numbers while a previewing
-- upgrade is hovered (tbl._preview = previewText's { text, short, color },
-- read by TablePanel's preview layer), nil otherwise or where the next
-- level changes nothing for that table.
function GrindView:_updatePreview()
    local up = self:_hoveredPreview()
    self._preview_up = up and up.id or nil
    local nextctx = up and self:_nextCtx(up)
    local ctrl = self.controller
    for _, t in ipairs(ctrl.pool.tables) do
        local nxt = nil
        if nextctx and t.estimateStats then
            local memo = self._preview_memo
            local hit = memo[t._id]
            if hit == nil then
                -- Priced without the table's passing statuses: a heater
                -- can push a table to the win-chance ceiling, where the
                -- next level changes nothing until it burns out, and the
                -- card came and went with every heater. The upgrade is
                -- permanent; the comparison is against what lasts (the
                -- table's position and hand bonuses included, opts.table).
                local gt = Lookups.findById(GameTypes, t.game_type_id)
                local st = Lookups.findById(Stakes, t.stake_id)
                local opts = ctrl:_tableEvOpts(t)
                local a = gt and st and OutcomeMath.evStats(ctrl.ctx, gt, st, opts)
                local b = gt and st and OutcomeMath.evStats(nextctx, gt, st, opts)
                local now, n = a and a.pool, b and b.pool
                hit = (now and n) and previewText(up.tooltip_metric, now, n) or false
                memo[t._id] = hit
            end
            nxt = hit or nil
        end
        t._preview = nxt
    end
end

-- The next level's stats for a stake and game type (add-table rows, the
-- tooltip), or nil when it changes nothing there.
function GrindView:_stakePreview(up, stake, gtype)
    local nextctx = self:_nextCtx(up)
    if not nextctx then return nil end
    local memo = self._preview_memo
    local key = stake.id .. "|" .. gtype.id
    local hit = memo[key]
    if hit == nil then
        local now = self.controller:evStats(stake, gtype)
        local n = OutcomeMath.evStats(nextctx, gtype, stake)
        hit = (now and n and statsDiffer(now.pool, n.pool)) and n.pool or false
        memo[key] = hit
    end
    return hit or nil
end

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
-- The upgrade tooltips that show "what the next level buys you" run
-- OutcomeMath.buildOutcome for every visible stake × every game type,
-- twice (now and next level) — about 110 of them. That was happening every
-- frame, for every upgrade in the sidebar, to fill a tooltip nobody was
-- necessarily hovering. Memoized per upgrade on the display revision; the
-- rows only move when the rollup or the upgrade's level does, and both
-- bump it.
local _range_memo = Memo.new("range_tooltip")

-- ── The earn rate's tooltip ─────────────────────────────────────────
-- The lede, one line per table (its $/hand, its pace, the product), the
-- focus factor when it bites, the run's ACTUAL $/min and last run's, the
-- ticker, then the total. Memoized on the rollup, the table count and the
-- board's clock second: services/Tooltip lays a lines table out once per
-- identity, so the array must hold still between rebuilds; the ticker
-- row's `render` reads the live trace every frame regardless.
local _rate_memo = Memo.new("rate_tooltip")

function GrindView:_buildRateTooltip(br, n_open)
    local ctrl  = self.controller
    br = br or ctrl:boardRate()   -- hovered before the rail's clock has polled it
    local token = tostring(ctrl.display_rev or 0) .. ":" .. tostring(n_open or 0)
                  .. ":" .. tostring(math.floor(ctrl.clock or 0))
    return _rate_memo:get("rail_rate", token, self._buildRateTooltipUncached, self, br)
end

-- The rate graph's points: for each finished bucket, $/min over the
-- minute ending with it (a rolling window of ~60 s of buckets; at least
-- the bucket itself once buckets are a minute wide). Reused table.
local _graph_pts, _graph_line = {}, {}
local function rateGraphPoints(rt, n)
    local b, w = rt.b, rt.w
    local k = math.max(1, math.floor(60 / w + 0.5))
    local sum = 0
    for i = 1, n do
        sum = sum + b[i]
        if i > k then sum = sum - b[i - k] end
        local span = math.min(i, k) * w
        _graph_pts[i] = sum / span * 60
    end
    for i = #_graph_pts, n + 1, -1 do _graph_pts[i] = nil end
    return _graph_pts
end
local function rateGraphLabel(v)
    return Format.money(v) .. "/min"
end

GrindView.rateGraphPoints = function(rt, n) return rateGraphPoints(rt, n) end

local function minutesText(secs)
    secs = secs or 0
    if secs < 60 then return string.format("%d s", math.floor(secs + 0.5)) end
    return string.format("%d min", math.floor(secs / 60 + 0.5))
end

function GrindView:_buildRateTooltipUncached(br)
    local R     = Rail
    local rate  = TablePanelStats.rateLabel
    local state = self.game.state
    local rows  = { { text = R.tooltips.rate_lede, style = "sm", color_token = "muted" } }

    -- One line per stake and game type that has dealt inside the window,
    -- with a count: a full board is a handful of lines, not one per table.
    local any = false
    local groups, order = {}, {}
    for _, e in ipairs(br.tables or {}) do
        if (e.hpm or 0) > 0 then
            any = true
            local tbl = e.tbl
            local key = tostring(tbl.stake_id) .. "|" .. tostring(tbl.game_type_id)
            local gr = groups[key]
            if not gr then
                gr = { tbl = tbl, n = 0, hpm = 0, rate = 0, ev_w = 0 }
                groups[key] = gr
                order[#order + 1] = gr
            end
            gr.n, gr.hpm, gr.rate = gr.n + 1, gr.hpm + e.hpm, gr.rate + e.rate
            gr.ev_w = gr.ev_w + (e.ev_hand or 0) * e.hpm
        end
    end
    for _, gr in ipairs(order) do
        local tbl   = gr.tbl
        local stake = Lookups.findById(Stakes, tbl.stake_id)
        local gtype = Lookups.findById(GameTypes, tbl.game_type_id)
        local label = ((stake and stake.display_name) or tbl.stake_id or "?") .. " · "
                      .. ((gtype and gtype.short) or tbl.game_type_id or "?")
        if gr.n > 1 then label = label .. " ×" .. gr.n end
        local ev = (gr.hpm > 0) and (gr.ev_w / gr.hpm) or 0
        local tok = (gr.rate > 0.005 and "good") or (gr.rate < -0.005 and "error") or "muted"
        rows[#rows + 1] = { style = "sm", color_token = tok,
            text = string.format(R.tooltips.rate_table, label, rate(ev, ""),
                                 math.floor(gr.hpm + 0.5), rate(gr.rate, "")) }
    end
    if not any then
        rows[#rows + 1] = { text = R.tooltips.rate_idle, style = "sm", color_token = "muted" }
    end
    if (br.focus_mult or 1) < 0.999 then
        rows[#rows + 1] = { text = string.format(R.tooltips.rate_focus, br.focus_mult),
                            style = "sm", color_token = "warn" }
    end

    -- What actually happened: this run, and the one before it.
    rows[#rows + 1] = { style = "sm", color_token = "muted",
        text = string.format(R.tooltips.rate_run, rate(br.run_net, ""),
                             minutesText(br.run_elapsed), rate(br.run_rate, "")) }
    if (state.shove_count or 0) > 0 then
        rows[#rows + 1] = { style = "sm", color_token = "muted",
            text = string.format(R.tooltips.rate_last, rate(br.last_run_rate, "")) }
    end

    -- The graph: the run's $/min as a line, start of the run on the left,
    -- now on the right. Each point is the rate over the minute up to the
    -- end of a finished bucket (GrindController:_tickRateTrace), so a
    -- point never moves once it is drawn; the bucket still filling is not
    -- plotted. A zero line, and the top (and bottom, when the run has gone
    -- negative) value at the left edge. Fixed size so the box never
    -- breathes; the trace is read live.
    rows[#rows + 1] = { style = "sm", color_token = "muted",
        text = string.format(R.tooltips.rate_graph, minutesText(br.run_elapsed)) }
    local s   = self.game.ui_scale or 1
    local TK  = RateTicker
    local W   = math.max(40, math.floor((TK.w or 180) * s))
    local H   = math.max(12, math.floor((TK.h or 36) * s))
    local state_ref = self.game.state
    rows[#rows + 1] = {
        measure = function(_) return W, H end,
        render  = function(x, y, fonts)
            local rt = state_ref.run_rate_trace
            local n  = rt and (#rt.b - 1) or 0      -- finished buckets only
            Theme.setColor(Theme.border.default, TK.baseline_alpha or 0.18)
            if n < 2 then
                love.graphics.rectangle("fill", x, y + H - 1, W, 1)
                return
            end
            local pts = rateGraphPoints(rt, n)
            local lo, hi = 0, 0
            for i = 1, n do
                local r = pts[i]
                if r < lo then lo = r end
                if r > hi then hi = r end
            end
            if hi - lo < 1e-9 then hi = lo + 1 end
            local function py(r) return y + (H - 1) * (hi - r) / (hi - lo) end
            local zero = math.floor(py(0) + 0.5)
            love.graphics.rectangle("fill", x, zero, W, 1)
            local line = _graph_line
            local k = 0
            for i = 1, n do
                line[k + 1] = x + (W - 1) * (i - 1) / (n - 1)
                line[k + 2] = py(pts[i])
                k = k + 2
            end
            for i = #line, k + 1, -1 do line[i] = nil end
            local last = pts[n]
            Theme.setColor(last >= 0 and Theme.sem.won or Theme.sem.lost)
            love.graphics.setLineWidth((TK.line_w or 1.5) * s)
            love.graphics.setLineJoin("bevel")
            love.graphics.line(line)
            love.graphics.setLineWidth(1)
            local f = fonts and (fonts.xs or fonts.sm)
            if f then
                love.graphics.setFont(f)
                Theme.setColor(Theme.fg.muted)
                love.graphics.print(rateGraphLabel(hi), x + 2, y)
                if lo < 0 then
                    love.graphics.print(rateGraphLabel(lo), x + 2, y + H - f:getHeight())
                end
            end
        end,
    }
    return rows
end

-- The upgrade tooltip: the stakes the next level moves, as stake pills
-- ({s:…}, IconText), in ladder order — the line is built from the board,
-- and reads like it. How much follows it in the same tooltip
-- (_upgradeInfoRows), and the board shows the change on each table while
-- the button is hovered.
function GrindView:_upgradeNextRows(up)
    local pills = {}
    for _, stake in ipairs(Stakes) do
        if stakeVisible(self, stake) then
            for _, g in ipairs(GameTypes) do
                if self:_stakePreview(up, stake, g) then
                    pills[#pills + 1] = "{s:" .. stake.id .. "}"
                    break
                end
            end
        end
    end
    if #pills == 0 then
        return { { text = "The next level changes nothing at your stakes.", style = "sm", color_token = "muted" } }
    end
    local str = "Next level affects " .. table.concat(pills, " ") .. "."
    local row = _blurbRow(self, str)
    row.say = str
    return { row }
end

-- Sharper Reads and Pot Control: the full breakdown of the next level
-- (it follows the sentence in the row's hover tooltip), a table of the
-- stakes it moves by the open game types, each
-- cell "now {arrow} next". Sharper Reads: the odds. Pot Control: the stack
-- win. Memoised per display revision.
local _info_memo = Memo.new("upgrade_info")
local GT_PILL = { zoom = "{t:zoom}", hu = "{t:hu}", six_max = "{t:6m}", ko = "{t:ko}" }
-- One decimal: a level moves odds by a point or two, whole percents would
-- often read "52% -> 52%".
local function pctCell(v) return string.format("%.1f%%", v * 100) end
-- One table as a tooltip row, laid out like the board: the metric in the
-- corner (ODDS / STACK WINS), the game-type pills across in the strip's order, stake names
-- down, each cell "now {arrow} next" (a dash where the level moves nothing).
-- Ruled: a shaded header row, a line under it and between columns.
local CELL_PAD_X, CELL_PAD_Y = 8, 3
local function gridRow(game, title, cols, rows_)
    local function layout(f)
        local lh = f:getHeight() + CELL_PAD_Y * 2
        local w0 = f:getWidth(title)
        for _, r in ipairs(rows_) do w0 = math.max(w0, f:getWidth(r.name)) end
        local cw = { w0 + CELL_PAD_X * 2 }
        for ci, c in ipairs(cols) do
            local w = IconText.measure(c.head, f)
            for _, r in ipairs(rows_) do w = math.max(w, IconText.measure(r.cells[ci] or "-", f)) end
            cw[ci + 1] = w + CELL_PAD_X * 2
        end
        local W = 0
        for _, w in ipairs(cw) do W = W + w end
        return cw, W, lh
    end
    return {
        measure = function(fonts)
            local _, W, lh = layout(fonts.sm)
            return W, lh * (#rows_ + 1)
        end,
        render = function(x, y, fonts)
            local f = fonts.sm
            local cw, W, lh = layout(f)
            local H = lh * (#rows_ + 1)
            -- the header band and the rules
            Theme.setColor(Theme.border.soft, 0.6)
            love.graphics.rectangle("fill", x, y, W, lh)
            Theme.setColor(Theme.border.default)
            love.graphics.setLineWidth(1)
            love.graphics.rectangle("line", x + 0.5, y + 0.5, W - 1, H - 1)
            love.graphics.line(x, y + lh + 0.5, x + W, y + lh + 0.5)
            local cx = x
            for ci = 1, #cw - 1 do
                cx = cx + cw[ci]
                love.graphics.line(cx + 0.5, y, cx + 0.5, y + H)
            end
            -- the corner and the stake names
            love.graphics.setFont(f)
            Theme.setColor(Theme.fg.muted)
            love.graphics.print(title, x + CELL_PAD_X, y + CELL_PAD_Y)
            Theme.setColor(Theme.fg.heading)
            for ri, r in ipairs(rows_) do
                love.graphics.print(r.name, x + CELL_PAD_X, y + lh * ri + CELL_PAD_Y)
            end
            -- the pills and the cells, centred in their columns
            cx = x + cw[1]
            for ci, c in ipairs(cols) do
                local w = cw[ci + 1]
                IconText.draw(game, c.head, cx + math.floor((w - IconText.measure(c.head, f)) / 2), y + CELL_PAD_Y, f, Theme.fg.heading, 1)
                for ri, r in ipairs(rows_) do
                    local str = r.cells[ci]
                    local cy = y + lh * ri + CELL_PAD_Y
                    if str then
                        IconText.draw(game, str, cx + math.floor((w - IconText.measure(str, f, IconText.PLAIN)) / 2), cy, f, Theme.fg.heading, 1, IconText.PLAIN)
                    else
                        Theme.setColor(Theme.fg.muted)
                        love.graphics.setFont(f)
                        love.graphics.print("-", cx + math.floor((w - f:getWidth("-")) / 2), cy)
                    end
                end
                cx = cx + w
            end
        end,
    }
end

-- The shares a table shows, from a pool: odds, stack wins (an absolute
-- share of all hands) and, for a tournament, the chance of 1st.
local function shares(pool)
    local wc = pool.win_chance or 0
    return {
        odds  = wc,
        swin  = wc * ((pool.win_dist or {}).stack or 0),
        first = pool.pos_probs and pool.pos_probs[1],
    }
end

function GrindView:_upgradeInfoRowsUncached(up)
    local ctrl = self.controller
    local cols, has_ko = {}, false
    for _, gid in ipairs(STRIP_ORDER) do
        local g = Lookups.findById(GameTypes, gid)
        if g and ctrl:gtypeAvailable(gid) then
            cols[#cols + 1] = { g = g, head = GT_PILL[gid] or g.short or gid }
            if g.chip_stack_table then has_ko = true end
        end
    end
    local sharper = up.tooltip_metric == "win_chance"
    local function cell(a, b) return pctCell(a) .. " {arrow} " .. pctCell(b) end
    local win_rows = {}
    for _, stake in ipairs(Stakes) do
        if stakeVisible(self, stake) then
            local name = stake.display_name or stake.id
            local wr_ = { name = name, cells = {} }
            local moved = false
            for ci, c in ipairs(cols) do
                local nxt = self:_stakePreview(up, stake, c.g)
                local now = ctrl:evStats(stake, c.g)
                now = now and now.pool
                if nxt and now then
                    local a, b = shares(now), shares(nxt)
                    if c.g.chip_stack_table then
                        -- A tournament: what both upgrades move is the
                        -- chance of finishing 1st.
                        if a.first and b.first and math.abs(b.first - a.first) > 0.0005 then
                            wr_.cells[ci] = cell(a.first, b.first)
                            moved = true
                        end
                    elseif sharper then
                        wr_.cells[ci] = cell(a.odds, b.odds); moved = true
                    else
                        wr_.cells[ci] = cell(a.swin, b.swin); moved = true
                    end
                end
            end
            if moved then win_rows[#win_rows + 1] = wr_ end
        end
    end
    if #win_rows == 0 then
        return {}   -- the sentence above the grid has said it changes nothing
    end
    local rows = {}
    if sharper then
        rows[#rows + 1] = gridRow(self.game, "ODDS", cols, win_rows)
    else
        rows[#rows + 1] = gridRow(self.game, "STACK WINS", cols, win_rows)
    end
    if has_ko then
        rows[#rows + 1] = _blurbRow(self, "{t:ko}: your chance of finishing 1st.")
    end
    return rows
end

function GrindView:_upgradeInfoRows(up)
    return _info_memo:get(up.id, tostring(self.controller.display_rev or 0) .. ":"
                          .. tostring(self.controller.summary_rev or 0),
                          self._upgradeInfoRowsUncached, self, up)
end

function GrindView:_buildRangeTooltip(up)
    if not up then return nil end
    return _range_memo:get(up.id, tostring(self.controller.display_rev or 0) .. ":"
                           .. tostring(self.controller.summary_rev or 0),
                           self._buildRangeTooltipUncached, self, up)
end

function GrindView:_buildRangeTooltipUncached(up)
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
            -- The sentence, then the numbers: the grid of the stakes it
            -- moves by game type (it used to sit behind an "i").
            for _, r in ipairs(self:_upgradeNextRows(up)) do rows[#rows + 1] = r end
            for _, r in ipairs(self:_upgradeInfoRows(up)) do rows[#rows + 1] = r end
        end
    end

    if #rows == 0 then return nil end
    return rows
end

-- The owned-item set, kept across frames and rebuilt in place when the
-- catalog revision or the list's length moves (a harness appends to the
-- list without marking it, and the length catches that).
local EMPTY = {}
function GrindView:_ownedSet()
    local state = self.game.state
    local list  = state.owned_items or EMPTY
    local rev, n = state.owned_rev or 0, #list
    local set = self._owned_set
    if not set then set = {}; self._owned_set = set end
    if rev ~= self._owned_set_rev or n ~= self._owned_set_n then
        for k in pairs(set) do set[k] = nil end
        for _, id in ipairs(list) do set[id] = true end
        self._owned_set_rev, self._owned_set_n = rev, n
    end
    return set
end

-- What the Upgrades tab is built from (views/Panel inputs): the fonts and
-- scale, the display and catalog revisions, the pool summary (the master
-- cursor toggles), the cursor perks, and per upgrade one number folding
-- its level, its cap and its four states (can't afford, would strand, at
-- max, locked); a hidden row keeps its slot as -1 so a row appearing is a
-- change too. The bankroll is in here only through the affordability bit.
function GrindView:_upgradesTabInputs(arr)
    local game, state, ctrl = self.game, self.game.state, self.controller
    local ctx = ctrl.ctx
    local n = 0
    n = n + 1; arr[n] = CR.layout_gen
    n = n + 1; arr[n] = game.ui_scale or 1
    n = n + 1; arr[n] = ctrl.display_rev or 0
    n = n + 1; arr[n] = state.owned_rev or 0
    n = n + 1; arr[n] = ctrl.summary_rev or 0
    n = n + 1; arr[n] = (ctx and ctx.cursor_unlocked) == true
    n = n + 1; arr[n] = (ctx and ctx.cursor_rebuy_unlocked) == true
    local owned    = self:_ownedSet()
    local bankroll = state.bankroll or 0
    for _, up in ipairs(RunUpgrades) do
        local locked = up.requires and not owned[up.requires]
        local key = -1
        if not (locked and up.requires_hide) then
            local level     = ctrl:getRunUpgradeLevel(up.id)
            local max_lvl   = ctrl:getRunUpgradeMaxLevel(up)
            local at_max    = level >= max_lvl
            local next_cost = ctrl:getRunUpgradeNextCost(up)
            local cant_afford  = next_cost ~= nil and bankroll < next_cost
            local would_strand = (not at_max) and (not locked) and (not cant_afford)
                                 and ctrl:wouldStrandRun(next_cost)
            key = (cant_afford and 8 or 0) + (would_strand and 4 or 0)
                + (at_max and 2 or 0) + (locked and 1 or 0)
                + level * 16 + max_lvl * 1024
        end
        n = n + 1; arr[n] = key
    end
    return n
end

function GrindView:_buildUpgradesTabComponents()
    local state = self.game.state
    local owned = self:_ownedSet()

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
            -- The Cursor upgrade is the master switch (right-click it,
            -- :_rightClick): faint hatching on it while the cursors deal at
            -- none of the open tables.
            local up_actions, up_no_cursors
            if up.cursor_master_controls then
                local ctx = self.controller and self.controller.ctx
                if ctx and ctx.cursor_unlocked then
                    local total, deal_muted = self.controller:typeCursorState(nil, nil)
                    up_no_cursors = total > 0 and deal_muted >= total
                end
            end

            components[#components + 1] = {
                type     = "button",
                actions  = up_actions,
                no_cursors = up_no_cursors,
                id       = "buy_runup_" .. up.id,
                -- Named hint-anchor (same string as the id) so tutorial
                -- hints can highlight this card.
                anchor   = "buy_runup_" .. up.id,
                disabled = disabled,
                -- Why it can't act (CR._button draws each differently).
                state    = (locked and "locked") or (at_max and "maxed")
                           or (would_strand and "strand") or (cant_afford and "cant_afford") or nil,
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
                        -- Out of reach: the price says so.
                        right_color_token = cant_afford and "error" or nil,
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

-- Chip-bounty fanfare: the moment a (stake, gtype) bounty first banks this
-- run, pulse its add-table button gold — or, if the player isn't on that
-- game type's sub-tab (the button isn't shown), pulse the game-type tab
-- instead so the cue still lands. Swept across every combo so it fires
-- exactly when the chip is earned.
--
-- The sweep itself only runs when the banked set has actually moved: it is
-- 44 combos building two key strings apiece, to notice something that
-- happens a handful of times a run.
function GrindView:_sweepBountyGlow()
    local banked_rev = self.controller.banked_rev or 0
    if banked_rev == self._bounty_glow_rev then return end
    self._bounty_glow_rev  = banked_rev
    self._bounty_glow_seen = self._bounty_glow_seen or {}

    local seen  = self._bounty_glow_seen
    local prime = not self._bounty_glow_primed   -- first sweep only syncs
    for _, stake in ipairs(Stakes) do
        for _, gt in ipairs(GameTypes) do
            local key    = stake.id .. ":" .. gt.id
            local banked = self.controller:bountyBanked(stake.id, gt.id)
            if banked and not prime and not seen[key] then
                if gt.id == self.selected_gtype then
                    AwardGlow.flash("add_table:" .. key)
                else
                    AwardGlow.flash("gtype:" .. gt.id)
                end
            end
            seen[key] = banked
        end
    end
    self._bounty_glow_primed = true
end

-- After the underflow the rail's readouts flicker as broken glyphs
-- (_brokenText, fourteen changes a second); one of the glyph_tear takes
-- plays under them now and then, never every flicker.
local GLYPH_GAP_MIN, GLYPH_GAP_MAX = 0.7, 2.2
function GrindView:_tickGlyphTear()
    local st = self.game.state
    if not (st and ShoveRate.underflowed(st.bankroll)) then self._glyph_next = nil; return end
    local now = love.timer.getTime()
    if not self._glyph_next then self._glyph_next = now + GLYPH_GAP_MIN end
    if now >= self._glyph_next then
        self._glyph_next = now + GLYPH_GAP_MIN + love.math.random() * (GLYPH_GAP_MAX - GLYPH_GAP_MIN)
        local sounds = self.game.sounds
        if sounds and sounds.playNamed then sounds.playNamed("glyph_tear") end
    end
end

function GrindView:update(dt)
    self:_tickGlyphTear()
    -- Last frame's hover (HoverService is set by the hit tests below and
    -- read during the draw): the hovered upgrade's preview on the tables.
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

    self:_sweepBountyGlow()

    -- Hit-test components for hover (writes "button" namespace into
    -- HoverService AND stashes any comp.tooltip via Tooltip.set).
    for _, panel in ipairs(self._panels) do
        local comps = panel:getComponents()
        if comps then
            local cy = panel:toContentY(my)
            CR.hitTest(comps, panel.x, panel.w, mx, cy, self.game)
        end
    end
    -- The hovered upgrade's preview on the board: after the hit test, which
    -- is what reports this frame's hover (main clears it every frame).
    self:_updatePreview()
    -- What dropping the held table here would change (memoised on the cell).
    self:_updateDragPreview()
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
            -- The player's cursor: an open hand on a header (it can be
            -- picked up), a pointing hand on anything else that acts.
            if hb.action == "drag_table" then CursorIntent.mark("open")
            elseif hb.action then CursorIntent.mark("point") end
            if hb.tooltip then
                TooltipSvc.set(hb.tooltip, mx, my)
            elseif hb.tooltip_fn then
                -- Resolved here and only here: the box under the pointer is
                -- the only one whose lines are worth building.
                TooltipSvc.set(hb.tooltip_fn(hb.tooltip_arg1, hb.tooltip_arg2),
                               mx, my)
            end
        end
    end

    -- Carrying a table: a closed hand.
    if self.drag and self.drag.moved then CursorIntent.mark("fist") end

    self:tweenChrome(dt)
    self:_tickRail(dt)

    -- Drain the controller's chip-burst queue. Controller produces denomination
    -- indices and source/dest pairs; the view delegates to ChipFlight which
    -- wraps the render-closure composition + FlightSystem dispatch. Keeps
    -- controller→view dependencies out of controllers/GrindController.lua
    -- and shares the same path the script's per-event handlers use.
    local bursts = self.controller:drainBursts()
    -- A closed table's piles go now, not after the sweep's thirty seconds
    -- (the controller queues the keys; it never names a view).
    -- A table closed in play: copy its last picture out of the panel sheet
    -- (before this frame's draw reuses the slot) into a closing ghost.
    local ct = self.controller.closed_tables
    if ct and #ct > 0 then
        for i = 1, #ct do self:_ghostClosedTable(ct[i]) end
        for i = #ct, 1, -1 do ct[i] = nil end
    end
    local fp = self.controller.forget_piles
    if fp and #fp > 0 then
        for i = 1, #fp do ChipPile.forget(fp[i]) end
        for i = #fp, 1, -1 do fp[i] = nil end
    end
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
                    self.game.floating_text.emit("{ko}", pos[1], pos[2],
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
--
-- The row is RETAINED (views/Panel): _railInputs names what its shape
-- depends on and the builder runs only when one of those moves;
-- _refreshRail writes the live numbers into the retained components each
-- frame; _tickRail, from update, owns the pulses, the alarm and the
-- rolled values; the tooltips with numbers in them are built on hover.

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
    -- One persistent canvas, reallocated only when the frame resizes. This
    -- used to build a key STRING every frame just to compare, and on a miss
    -- allocate a fresh full-screen canvas while dropping the old one on the
    -- floor — a steady VRAM leak every time the player bought something.
    local t = self._room_thumb
    if not t then t = {}; self._room_thumb = t end
    local dirty = t.owned  ~= (st.owned_rev or 0)
               or t.unseen ~= #(st.room_unseen or {})
               or t.w ~= W or t.h ~= H
    if not dirty and t.canvas then return t.canvas, t.box end

    local canvas = t.canvas
    if not canvas or t.w ~= W or t.h ~= H then
        local ok, fresh = pcall(love.graphics.newCanvas, W, H, { dpiscale = 1 })
        if not ok then return nil end
        if canvas and canvas.release then pcall(canvas.release, canvas) end
        canvas = fresh
    end
    t.owned  = st.owned_rev or 0
    t.unseen = #(st.room_unseen or {})
    t.w, t.h = W, H
    local prev = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    rv:draw(true, { zoom = 1, dy = 0, lighting = { fixture = 0, emitters = true } })   -- dark, as the room is
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
    t.canvas, t.box = canvas, box
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
-- roster has the rest. Memoized on the deck's level: the lines move only
-- when it does, and services/Tooltip lays a lines table out once per
-- identity, so the same table must come back until then.
local _deck_memo = Memo.new("deck_tooltip")

function GrindView:_deckTooltip(spec)
    if not spec then return nil end
    local state = self.game.state
    local level = (state.deck_levels and state.deck_levels[spec.id]) or 0
    return _deck_memo:get(spec.id, level, self._deckTooltipUncached, self, spec, level)
end

function GrindView:_deckTooltipUncached(spec, level)
    local id    = spec.id
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

-- FOCUS's tooltip: the capacity and the hard cap are the only numbers in
-- it and the penalty comes off the rollup, so it is keyed on those three.
local _focus_memo = Memo.new("focus_tooltip")

function GrindView:_focusTip(focus_cap, cap)
    local token = ((self.controller.display_rev or 0) * 1000 + focus_cap) * 1000 + cap
    return _focus_memo:get("focus", token, self._focusTipUncached, self, focus_cap, cap)
end

function GrindView:_focusTipUncached(focus_cap, cap)
    local R    = Rail
    local ctx  = self.controller.ctx
    local eff_pen = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * ((ctx and ctx.focus_penalty_reduce_mult) or 1)
    return {
        R.tooltips.focus,
        string.format(R.tooltips.focus_ok, focus_cap),
        string.format(R.tooltips.focus_pen, eff_pen * 100, Constants.GAMEPLAY.FOCUS_FLOOR * 100),
        string.format(R.tooltips.focus_cap, cap),
    }
end

-- SHOVE's tooltip, built only while the button is hovered (tooltip_fn)
-- and then only when what it prints has moved: the rollup, the rounded
-- rate, the multiplier to a tenth, this run's chips. The rates it reads
-- are the ones _railInputs cached for the button's own readout.
local _shove_memo = Memo.new("shove_tooltip")

function GrindView:_shoveTooltip()
    local rates = self._shove_rates
    if not rates then return nil end
    local pending = self.game.state.chips_this_run or 0
    local token = tostring(self.controller.display_rev or 0) .. ":" .. tostring(self._shove_pct or 0)
                  .. ":" .. tostring(math.floor((rates.mult or 0) * 10 + 0.5)) .. ":" .. tostring(pending)
    return _shove_memo:get("shove", token, self._shoveTooltipUncached, self, rates, pending)
end

function GrindView:_shoveTooltipUncached(rates, pending)
    local R   = Rail
    local tip = {
        { style = "sm", color_token = "muted", text = R.tooltips.shove_lede },
        TablePanelStats.iconRow(self.game, string.format(R.tooltips.shove_take, pending), "sm",
                                (pending > 0) and "chip" or "muted"),
    }
    for _, r in ipairs(ShoveRate.formatBreakdown(rates)) do tip[#tip + 1] = r end
    tip[#tip + 1] = R.tooltips.shove_lock
    return tip
end

-- The quick reset's lines carry no numbers: made once per font generation.
local _rail_memo = Memo.new("rail_tooltips")

local function quickResetTipBuild(game)
    return iconRows(game, Rail.tooltips.quick_reset, "heading")
end

function GrindView:_quickResetTip()
    return _rail_memo:get("quick_reset", CR.layout_gen, quickResetTipBuild, self.game)
end

-- The chips' two lines: one table for the session (the tooltip's layout
-- is cached on the table's identity).
local CHIPS_TIP = { Rail.tooltips.banked }

-- ── The rail's helpers, hoisted ──
-- The builder used to make these as closures on every frame (three
-- helpers and four faces); now it runs only when the rail's shape changes
-- and what they closed over comes in as an argument or sits on the view.

-- A readout hangs its label and value from the rail's bottom, so every
-- value shares one baseline and every button one top and bottom. A
-- readout's slot ends where the buttons' faces end (above their chunk),
-- and its value's baseline sits on that line.
-- The bankroll pile as a click surface: the column under the click hops.
local BANKROLL_SURFACE = { pile = "bankroll" }

local function railStat(c, face_bottom)
    c.type = "stat"; c.h = c.h or face_bottom; c.valign = c.valign or "bottom"
    -- A click on a readout is a knock on the rail, and the readout jostles.
    c.surface = "rail"
    return c
end

local function railGroup(kids, gap)
    return { type = "row", gap = gap, h = RAIL_BTN_H, align = "top", children = kids }
end

-- A slot is as wide as the widest value it can hold (data/rail.lua
-- reserve), never as wide as the value it holds now: the row does not
-- move as the numbers change. Cached per (font, string): the reserve
-- strings are a fixed set and a font's answer holds until the fonts are
-- rebuilt (CR.layout_gen).
local _reserve_w, _reserve_gen = {}, nil
local function reserveW(font, text, extra)
    if _reserve_gen ~= CR.layout_gen then
        for k in pairs(_reserve_w) do _reserve_w[k] = nil end
        _reserve_gen = CR.layout_gen
    end
    local by_font = _reserve_w[font]
    if not by_font then by_font = {}; _reserve_w[font] = by_font end
    local w = by_font[text]
    if not w then w = font:getWidth(text); by_font[text] = w end
    return w + (extra or 0) + Theme.space.stat_pad
end

local function gearFace(fx, fy, fw, fh, g)
    local fl = math.floor
    local sz = fl(math.min(fw, fh) * Theme.space.icon_share)
    Icons.drawGear(g, fx + fl((fw - sz) / 2), fy + fl((fh - sz) / 2), sz)
end

-- The faces and the lazy tooltips, made once per view. They read the
-- view at call time (the room thumbnail, the deck in play, the cached
-- rates, which screen is up), so one of each serves every rebuild.
function GrindView:_makeRailClosures()
    local game = self.game
    local fl   = math.floor
    -- The book's own cover, at thumbnail size (the felt's rule).
    self._face_book = function(fx, fy, fw, fh)
        local fonts, s = game.fonts, game.ui_scale or 1
        local pad = fl(Theme.space.thumb_pad * s)
        local k = math.min((fw - pad * 2) / CatalogModal.COVER_W, (fh - pad * 2) / CatalogModal.COVER_H)
        local cw, ch = CatalogModal.COVER_W * k, CatalogModal.COVER_H * k
        love.graphics.push()
        love.graphics.translate(fx + fl((fw - cw) / 2), fy + fl((fh - ch) / 2))
        love.graphics.scale(k, k)
        CatalogModal.drawFrontCover(COVER_CTX, 0, 0, CatalogModal.COVER_W, CatalogModal.COVER_H, fonts, 1)
        love.graphics.pop()
    end
    -- The whole room, framed by its own extent.
    self._face_room = function(fx, fy, fw, fh)
        local fonts, s = game.fonts, game.ui_scale or 1
        local canvas, box = self:_roomThumb()
        if canvas and box then
            local pad = fl(Theme.space.thumb_pad * s)
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
        if self._rail_on_room then
            -- On the room screen the same button is the way back.
            love.graphics.setFont(fonts.sm)
            local th = fonts.sm:getHeight()
            Theme.setColor(Theme.bg.sunken, 0.7)
            love.graphics.rectangle("fill", fx, fy + fl((fh - th) / 2), fw, th)
            Theme.setColor(Theme.fg.heading)
            love.graphics.printf(Rail.labels.play, fx, fy + fl((fh - th) / 2), fw, "center")
        end
    end
    self._face_deck = function(fx, fy, fw, fh)
        local spec = self._rail_deck_spec
        if spec then self:_drawDeckFace(spec, fx, fy, fw, fh) end
    end
    self._tip_rate  = function() return self:_buildRateTooltip(self._rail_br, self.controller.pool:count()) end
    self._tip_shove = function() return self:_shoveTooltip() end
    self._tip_deck  = function() return self:_deckTooltip(self._rail_deck_spec) end
end

-- ── The rail's clock ──
-- What moves on its own, once per frame: run from update (the grind) and
-- from the room screen (RoomState:update), never from the builder. The
-- pulses on a delivery, the focus alarm's step, and the two rolled
-- numbers. The board's earn rate is polled every RATE_POLL_SECS
-- (GrindController:boardRate builds a table per open table) and eased
-- every frame.
local RATE_POLL_SECS = 0.25

function GrindView:_tickRail(dt)
    local state, ctrl = self.game.state, self.controller
    local R  = Rail
    local fl = math.floor
    local sm = self.game.state_machine
    local on_room = (sm and sm.current and sm:current() == "room") or false
    self._rail_on_room = on_room

    -- Something bought and not yet seen in the room: ONE pulse when it
    -- arrives, then quiet. A delivery is a note, not an alarm. A deck
    -- that opened and hasn't been seen, the same.
    local unseen_n = state.room_unseen and #state.room_unseen or 0
    if state.has_shoved and not on_room and unseen_n > (self._room_unseen_n or 0) then
        AwardGlow.flash("nav:room")
    end
    self._room_unseen_n = unseen_n
    local decks_unseen_n = state.decks_unseen and #state.decks_unseen or 0
    if Decks.systemUnlocked(state) and decks_unseen_n > (self._decks_unseen_n or 0) then
        AwardGlow.flash("deck")
    end
    self._decks_unseen_n = decks_unseen_n

    -- FOCUS rolls toward the target like the money; the pop keys off the
    -- real target so it fires once per change.
    local n_open      = ctrl.pool:count()
    local focus_cap   = ctrl:currentFocusCapacity()
    local focus_pct   = fl(ctrl:currentFocusMult() * 100 + 0.5)
    local focus_shown = fl(RollingValue.get("focus_pct", focus_pct) + 0.5)
    local over        = focus_shown < 100
    self._focus_pop   = Pop.onChange("focus", focus_pct, 0.5)
    -- Over the cap the cell is an alarm, and every table further over is
    -- a visible step: the label says OVER FOCUS, the value goes to the
    -- bankroll's big font, the plate under the pair (drawChrome) fills
    -- and thickens per table, each step bursts the readout up out of the
    -- rail (drawChrome) and plays the overload sound pitched lower (the
    -- controller), and the whole screen loses focus around this one
    -- readout (main.lua, the strain shader). Between steps it holds
    -- STILL: being over focus can be a strategy for a while, and a
    -- readout that blinks the whole time would be unbearable.
    local extra = math.max(0, n_open - focus_cap)
    if over and extra > (self._focus_extra or 0) then
        ClickFlash.flash("focus_alarm", "step", 1.3)
    end
    self._focus_extra = over and extra or 0
    self._focus_over  = over
    -- The step's kick: the readout bursts out of the rail and shakes,
    -- then settles. The rail clips its contents, so while the kick runs
    -- the cell draws nothing and drawChrome redraws the label and value
    -- above the rail, scaled and shaken about the cell (its anchors).
    local kick = over and ClickFlash.raw("focus_alarm", "step") or 0
    self._focus_kick  = kick
    self._focus_label = over and R.labels.over_focus or R.labels.focus
    if focus_shown ~= self._focus_shown then
        self._focus_shown = focus_shown
        self._focus_value = focus_shown .. "%"
    end

    -- The board's earn rate: what the open tables should make a minute at
    -- the pace they are being dealt (GrindController:boardRate), eased.
    local now = love.timer.getTime()
    if not self._rail_br or (now - (self._rail_br_t or -1e9)) >= RATE_POLL_SECS then
        self._rail_br, self._rail_br_t = ctrl:boardRate(), now
    end
    self._rail_rate_v = RollingValue.get("rail_rate", self._rail_br.total)
end

-- What the rail is built from (views/Panel inputs): its SHAPE only. The
-- fonts and scale, the display revision, which screen is up, what is
-- earned (the catalog, the room, the deck system, the deck in play and
-- its level), the table count against the focus capacity and whether the
-- board is over it, the Act 3 column, whether SHOVE and the quick reset
-- are offered, the underflow, whether a shove has happened, the alarm's
-- kick, and SHOVE's rate to the whole percent. Every number that moves on
-- its own (the money, the chips, FOCUS's value) is left to _refreshRail.
function GrindView:_railInputs(arr)
    -- A draw before any update (a harness): the clock runs once so the
    -- readouts have something to show.
    if self._focus_shown == nil then self:_tickRail(0) end
    local game, state, ctrl = self.game, self.game.state, self.controller
    local sm = game.state_machine
    local on_room = (sm and sm.current and sm:current() == "room") or false
    self._rail_on_room = on_room
    local deck_open  = Decks.systemUnlocked(state) == true
    local deck_id    = deck_open and state.active_deck_id or false
    local deck_level = (deck_id and state.deck_levels and state.deck_levels[deck_id]) or 0
    local bankroll   = state.bankroll or 0
    local rev        = ctrl.display_rev or 0
    -- SHOVE's rate, on the rollup and the whole dollar of the bankroll
    -- plus what is tied up (ShoveRate.compute allocates its result), kept
    -- for the button's readout and its tooltip.
    local total = bankroll + ctrl:tiedUp()
    local tq    = math.floor(total)
    if not self._shove_rates or self._shove_rates_rev ~= rev or self._shove_rates_q ~= tq then
        self._shove_rates = ShoveRate.compute(ctrl.ctx or {}, total)
        self._shove_rates_rev, self._shove_rates_q = rev, tq
    end
    local pct = math.floor((self._shove_rates.raw_r1 or 0) * 100 + 0.5)
    self._shove_pct = pct
    local n = 0
    n = n + 1; arr[n] = CR.layout_gen
    n = n + 1; arr[n] = game.ui_scale or 1
    n = n + 1; arr[n] = rev
    n = n + 1; arr[n] = on_room
    n = n + 1; arr[n] = state.catalog_seen == true
    n = n + 1; arr[n] = state.has_shoved == true
    n = n + 1; arr[n] = deck_open
    n = n + 1; arr[n] = deck_id
    n = n + 1; arr[n] = deck_level
    n = n + 1; arr[n] = ctrl.pool:count()
    n = n + 1; arr[n] = ctrl:currentFocusCapacity()
    n = n + 1; arr[n] = self._focus_over == true
    n = n + 1; arr[n] = state.shove_r2_won == true
    n = n + 1; arr[n] = ctrl:shoveUnlocked() == true
    n = n + 1; arr[n] = ctrl:canQuickReset() == true
    n = n + 1; arr[n] = ShoveRate.underflowed(bankroll) == true
    n = n + 1; arr[n] = (state.shove_count or 0) > 0
    n = n + 1; arr[n] = (self._focus_kick or 0) > 0.01
    n = n + 1; arr[n] = pct
    -- The live counters show only while an item reads them.
    local cx = ctrl.ctx or {}
    n = n + 1; arr[n] = (cx.odds_per_hand_per_second or 0) > 0
    n = n + 1; arr[n] = (cx.odds_per_heater or 0) > 0
    return n
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
    local on_room = self._rail_on_room or false
    local depth   = SP.button_depth
    local face_h  = RAIL_BTN_H - Button.allocatedH(0, depth)
    local btn_w   = fl(RAIL_BTN_H * SP.icon_button_w)
    local gap     = fl(SP.flex_gap * s)
    local n_open  = ctrl.pool:count()
    local face_bottom = RAIL_BTN_H - depth
    local glyph_w = fl(fonts.md:getHeight() * SP.stat_glyph) + SP.stat_pad
    -- The live components by name, for _refreshRail. One table, reused;
    -- the values themselves are left blank here and filled by the first
    -- refresh, which follows the build inside the same draw.
    local rc = self._rail_c
    if not rc then rc = {}; self._rail_c = rc end
    for k in pairs(rc) do rc[k] = nil end

    -- ── The buttons: the gear, the book, the room, the deck ──
    local gear = { type = "button", id = "nav:settings", anchor = "btn:settings",
        w = btn_w, face_h = face_h, depth = depth,
        face_fn = gearFace }
    -- Locked, a button is BLANK (the locked game-type keys' rule): no
    -- picture, no word, no line. The slot is there; nothing else is said.
    local cat_locked = not state.catalog_seen
    local book = { type = "button", id = "nav:catalog", anchor = "btn:catalog",
        w = btn_w, face_h = face_h, depth = depth,
        disabled = cat_locked, tooltip = (not cat_locked) and R.tooltips.catalog or nil,
        lines = {},
        face_fn = (not cat_locked) and self._face_book or nil }
    local room_locked = not state.has_shoved
    local room = { type = "button", id = "nav:room", anchor = "btn:room",
        anchor_also = on_room and "room:play" or nil,
        w = fl(RAIL_BTN_H * SP.room_thumb_w), face_h = face_h, depth = depth,
        disabled = room_locked,
        tooltip  = (not room_locked and on_room) and R.labels.play or nil,
        lines    = {},
        face_fn  = (not room_locked) and self._face_room or nil }
    local deck_open = Decks.systemUnlocked(state)
    local spec = deck_open and state.active_deck_id and Decks.specById(state.active_deck_id) or nil
    self._rail_deck_spec = spec
    -- Locked, the key is BLANK: no name, no line, nothing to want by name.
    -- Open, it wears the deck in play; open with none in play yet, its name.
    local deck = { type = "button", id = "deck", anchor = "cell:deck",
        w = fl(RAIL_BTN_H * SP.deck_thumb_w), face_h = face_h, depth = depth,
        disabled = not deck_open,
        tooltip    = (deck_open and not spec) and R.tooltips.deck_click or nil,
        tooltip_fn = spec and self._tip_deck or nil,
        lines    = (deck_open and not spec) and
                   { { text = R.labels.deck, style = "small", align = "center", color_token = "heading" } } or {},
        face_fn  = spec and self._face_deck or nil }

    -- ── FOCUS, and the tables that drive it ──
    local focus_cap = ctrl:currentFocusCapacity()
    local over      = self._focus_over == true
    local kicking   = (self._focus_kick or 0) > 0.01
    self._focus_kicking = kicking
    local cap       = ctrl:tableSlotsCap()
    local focus_tip = self:_focusTip(focus_cap, cap)
    -- A healthy focus is simply fine (parchment); under 100% every table
    -- is playing that much slower, which is money lost. The colour is one
    -- table the refresh blends in place (the pop lifts it toward white).
    local fc = self._focus_color
    if not fc then fc = { 0, 0, 0 }; self._focus_color = fc end
    local focus = railStat({ label = kicking and "" or self._focus_label,
        label_color_token = over and "lost" or nil,
        value = "", value_color = fc, value_scale = 1,
        value_style = over and "lg" or "md",
        anchor = "cell:focus", value_anchor = "cell:focus_value", tooltip = focus_tip,
        w = reserveW(over and fonts.lg or fonts.md, R.reserve.focus) }, face_bottom)
    rc.focus = focus
    -- TABLES: open against the capacity, as a fill that reddens past it.
    local tables = railStat({ label = R.labels.tables, value = "",
        bar = { frac = n_open / math.max(1, focus_cap), w = fl(SP.stat_bar_w * s),
                color = over and Theme.sem.lost or Theme.fg.heading },
        suffix = { text = n_open .. " / " .. focus_cap, color_token = over and "lost" or "muted" },
        tooltip = focus_tip,
        w = fl(SP.stat_bar_w * s) + SP.stat_gap + reserveW(fonts.sm, R.reserve.tables) }, face_bottom)
    rc.tables = tables
    -- The counters an owned item reads, beside TABLES while it is owned:
    -- the board's hands a second (Hybrid Console) and the heaters burning
    -- (Desk Speakers). Values refreshed in _refreshRail; each pops when it
    -- climbs.
    local cx = ctrl.ctx or {}
    rc.hands_s, rc.heaters = nil, nil
    local live_stats = {}
    if (cx.odds_per_hand_per_second or 0) > 0 then
        rc.hands_s = railStat({ label = R.labels.hands_s, value = "", value_color = { 1, 1, 1, 1 },
            anchor = "cell:hands_s", w = reserveW(fonts.md or fonts.sm, R.reserve.hands_s) }, face_bottom)
        live_stats[#live_stats + 1] = rc.hands_s
    end
    if (cx.odds_per_heater or 0) > 0 then
        rc.heaters = railStat({ label = R.labels.heaters, value = "", value_color = { 1, 1, 1, 1 },
            anchor = "cell:heaters", w = reserveW(fonts.md or fonts.sm, R.reserve.heaters) }, face_bottom)
        live_stats[#live_stats + 1] = rc.heaters
    end

    -- ── The money: what is tied up at the tables, and the bankroll under its pile ──
    local broken = self:_broken()
    self._rail_broken = broken
    -- "TIED UP $x" as the small line on top (where the labels are), the
    -- CASH OUT button under it on the value row.
    -- The small line's glyphs, then the same gap every value keeps under
    -- its label, then the button, ending on the bottom line like the rest.
    local tied_h = fonts.sm:getBaseline() + SP.stat_gap
    local cash_w = fonts.sm:getWidth(R.labels.cash_out) + fl(SP.word_button_pad * s)
    local tied_stat = railStat({ value = "", value_style = "sm", h = tied_h, valign = "top",
        value_color = broken and Theme.currency.achip or Theme.fg.muted,
        anchor = "cell:tied",
        w = reserveW(fonts.sm, R.labels.tied_up .. " " .. R.reserve.tied_up) }, face_bottom)
    rc.tied = tied_stat
    local tied = { type = "column", children = {
        tied_stat,
        { type = "button", id = "cash_out", anchor = "btn:cash_out", depth = depth,
          face_h = (RAIL_BTN_H - tied_h) - Button.allocatedH(0, depth),
          w = cash_w,
          disabled = n_open == 0,
          tooltip  = (n_open > 0) and R.tooltips.cash_out or R.locked.cash_out,
          lines = { { text = R.labels.cash_out, style = "small", align = "center", color_token = "heading" } } },
    } }
    -- The bankroll, big, with no label: the chips say what it is (the pile
    -- centres itself over this slot, see _drawBankrollChips). Over it, in
    -- the slot TIED UP has over CASH OUT, the board's earn rate, eased
    -- like the other readouts and coloured from the eased value so tint
    -- and number never disagree (both in _refreshRail).
    local rate = railStat({ value = "", value_style = "sm", h = tied_h, valign = "top", align = "center",
        value_color = Theme.fg.muted, dim = (n_open == 0),
        anchor = "cell:rate", tooltip_fn = self._tip_rate,
        w = reserveW(fonts.sm, R.reserve.rate_min) }, face_bottom)
    rc.rate = rate
    local bank = railStat({ value = "", value_style = "lg", value_color = Theme.fg.heading,
        h = face_bottom - tied_h,
        -- The number is not a number any more. It never resolves.
        value_glow_color = broken and Theme.currency.achip or nil,
        anchor = "cell:bankroll", align = "center", tooltip = R.tooltips.bankroll,
        w = reserveW(fonts.lg, R.reserve.bankroll) }, face_bottom)
    rc.bank = bank
    local bankroll = { type = "column", children = { rate, bank } }

    -- ── The chips: yours, banked as they are won ──
    -- One readout with nothing over it: the count big, the chip beside
    -- it at the same size, centred in the rail's height like the button
    -- next to it (the bankroll sits low because its rate sits over it).
    local chips = railStat({ icon = "chip", value = "", value_style = "lg",
        h = face_bottom, align = "center", valign = "center",
        value_color = Theme.fg.heading, tooltip = CHIPS_TIP,
        w = fl(fonts.lg:getHeight() * SP.stat_glyph) + SP.stat_pad + reserveW(fonts.lg, R.reserve.chips) }, face_bottom)
    rc.chips = chips
    local banked = { type = "column", anchor = "cell:chips", children = { chips } }
    local anti
    if state.shove_r2_won then
        local count_h = fonts.md:getBaseline()   -- the count's glyphs; the NEXT row under it
        local achips = railStat({ icon = "achip", value = "", h = count_h, valign = "top",
            value_color = Theme.currency.achip,
            w = glyph_w + reserveW(fonts.md, R.reserve.chips) }, face_bottom)
        local achips_next = railStat({ value = "", value_style = "sm",
            h = face_bottom - count_h,
            value_color_token = "faint", value_anchor = "achip_badge:shove",
            w = reserveW(fonts.sm, R.reserve.next .. " " .. R.labels.next) }, face_bottom)
        rc.achips, rc.achips_next = achips, achips_next
        anti = { type = "column", anchor = "cell:achips", children = { achips, achips_next } }
    end

    -- ── SHOVE: the door, with the chip's gold on its edge ──
    local can_shove = ctrl:shoveUnlocked()
    local rates     = self._shove_rates
    local r1        = (rates and rates.raw_r1) or 0
    local rate_txt  = string.format("%.0f%%", r1 * 100)
    -- Parchment until the hand is a lock; then the colour of a hand won.
    local rate_tok  = (r1 >= 1.00) and "won" or "heading"
    if broken then
        rate_txt = ""          -- the morph (never resolving) is the refresh's
        rate_tok = "corrupt"
    end
    local shove_line = { text = R.labels.shove, style = "heading", align = "center", color_token = "heading",
        right = rate_txt, right_color_token = rate_tok, right_anchor = "cell:shove" }
    rc.shove_line = can_shove and shove_line or nil
    local shove = { type = "button", id = "shove", anchor = "btn:shove",
        -- Held, not clicked (services/HoldPress): the face fills under the
        -- press and the shove goes when it is full.
        hold_id = "shove", hold_color = Theme.sem.chip,
        tooltip_clear_of = "btn:shove",   -- the tooltip sits above, off the fill
        w = fonts.md:getWidth(R.labels.shove) + fonts.sm:getWidth(R.reserve.rate) + fl(SP.shove_button_pad * s),
        face_h = face_h, depth = depth,
        disabled = not can_shove,
        face_color = Theme.bg.widget_hover,
        border_color = Theme.sem.chip, border_line_width = Theme.space.line_strong,
        -- A greyed button does not pitch its own click.
        tooltip_fn = can_shove and self._tip_shove or nil,
        lines = can_shove and { shove_line } or {},
        -- The quick-reset rescue straddles the shove's top edge when bricked.
        overlay = ctrl:canQuickReset() and {
            type = "button", id = "quick_reset", anchor = "btn:quick_reset", depth = SP.button_depth,
            w = fonts.sm:getWidth(R.labels.quick_reset) + fl(SP.overlay_button_pad * s),
            tooltip = self:_quickResetTip(),
            lines = { { text = R.labels.quick_reset, style = "small", align = "center", color_token = "heading" } },
        } or nil }

    -- ── The row ──
    -- Four groups. Things that belong together are a row of their own and
    -- move as one; the space left over spreads evenly between the groups.
    local money = railGroup({ tied, bankroll }, gap)
    money.anchor = "rail:money"   -- the pile stands over this group
    local watch_kids = { focus, tables }
    for _, st in ipairs(live_stats) do watch_kids[#watch_kids + 1] = st end
    local watch = railGroup(watch_kids, gap)
    watch.anchor = "rail:focus"   -- the alarm plate (drawChrome) and the strain shader's hole (main.lua)
    local chips_g = anti and railGroup({ banked, anti, shove }, gap) or railGroup({ banked, shove }, gap)
    return {
        { type = "spacer", h = RAIL_PAD },
        { type = "row", h = RAIL_BTN_H, align = "top", justify = "between", gap = fl(SP.flex_min_gap * s),
          children = { railGroup({ gear, book, room, deck }, gap), watch, money, chips_g } },
    }
end

-- ── The rail's live numbers ──
-- The bucket a number prints in, so a readout is formatted again only
-- when its text would change: a tween moves the number every frame, its
-- text far less often. moneyQ follows Format.money (cents under $1,000,
-- three figures above); rateQ follows the compact signed money the rates
-- use (TablePanelStats.rateLabel).
local Q_EPS = 1e-6
local function moneyQ(n)
    n = n or 0
    if n ~= n then return 0 end
    local a = math.abs(n)
    local q
    if a < 1000 then
        q = math.floor(a * 100 + Q_EPS)
    else
        local m, idx = a, 0
        while m >= 1000 and idx < 8 do m = m / 1000; idx = idx + 1 end
        if     m >= 100 then q = math.floor(m + Q_EPS)
        elseif m >= 10  then q = math.floor(m * 10 + Q_EPS)
        else                 q = math.floor(m * 100 + Q_EPS) end
        q = q + idx * 1e6
    end
    return n < 0 and -q or q
end
local function rateQ(n)
    n = n or 0
    if n ~= n then return 0 end
    local a = math.abs(n)
    local q
    if     a >= 1000 then q = 1e8 + moneyQ(a)
    elseif a >= 100  then q = 3e6 + math.floor(a + 0.5)
    elseif a >= 10   then q = 2e6 + math.floor(a * 10 + 0.5)
    else                  q = math.floor(a * 100 + 0.5) end
    return n < 0 and -q or q
end

-- Every frame, on the retained tree (views/Panel refresh): the values that
-- move on their own, each written only when its bucket moved (comp._q).
-- Only fields that leave the tree's shape alone are touched here: a
-- stat's value, colour, scale and dim, and SHOVE's right badge (whose
-- line height memo is dropped with it).
-- One live item counter on the rail: its value when the tenth moves, a pop
-- each time it climbs, the colour easing back from white.
local function liveRailStat(c, v, fmt, base, now)
    if not c then return end
    local q = math.floor(v * 10 + 0.5)
    if c._q ~= q then
        if c._q and q > c._q then c._pop_t = now end
        c._q = q
        c.value = string.format(fmt, v)
    end
    local pop = math.max(0, 1 - (now - (c._pop_t or -10)) / 0.4)
    c.value_scale = 1 + 0.35 * pop
    local vc = c.value_color
    vc[1] = base[1] + (1 - base[1]) * pop
    vc[2] = base[2] + (1 - base[2]) * pop
    vc[3] = base[3] + (1 - base[3]) * pop
end

function GrindView:_refreshRail()
    local rc = self._rail_c
    if not rc then return end
    local state, ctrl = self.game.state, self.controller
    local R      = Rail
    local broken = self._rail_broken
    -- The underflow's glyphs never settle: they redraw at fourteen a second.
    local morph  = broken and math.floor(love.timer.getTime() * 14) or nil

    -- FOCUS: the rolled percent, its pop, and its colour, blended in place.
    local f = rc.focus
    if not self._focus_kicking then
        local shown = self._focus_shown
        if f._q ~= shown then f._q = shown; f.value = self._focus_value or "" end
    end
    local fpop = self._focus_pop or 0
    f.value_scale = Pop.scale(fpop, 1, 0.45)
    local base = self._focus_over and Theme.sem.lost or Theme.fg.heading
    local fc = f.value_color
    fc[1] = base[1] + (1 - base[1]) * fpop
    fc[2] = base[2] + (1 - base[2]) * fpop
    fc[3] = base[3] + (1 - base[3]) * fpop

    -- The live item counters: the value when its tenth moves, a pop each
    -- time it climbs, the colour easing back from white.
    local cx = ctrl.ctx or {}
    local now = love.timer.getTime()
    liveRailStat(rc.hands_s, cx.hands_per_second or 0, "%.1f", Theme.sem.won, now)
    liveRailStat(rc.heaters, cx.heater_count or 0, "%d", Theme.sem.heat, now)

    -- TIED UP.
    local d_tied = self.displayed_tied or ctrl:tiedUp()
    local t  = rc.tied
    local tq = morph or moneyQ(d_tied)
    if t._q ~= tq then
        t._q = tq
        local str = moneyText(d_tied)
        if broken then str = self:_brokenText(str, "tied") end
        t.value = R.labels.tied_up .. " " .. str
    end

    -- The bankroll, tinted while a tween is in progress: won-green
    -- counting up, lost-red counting down.
    local d_bank = self.displayed_bankroll or state.bankroll or 0
    local b  = rc.bank
    local bq = morph or moneyQ(d_bank)
    if b._q ~= bq then
        b._q = bq
        local str = moneyText(d_bank)
        if broken then str = self:_brokenText(str, "bank") end
        b.value = str
    end
    if broken then
        b.value_color = Theme.currency.achip
    else
        local diff = (state.bankroll or 0) - d_bank
        b.value_color = (diff > 0.01 and Theme.sem.won) or (diff < -0.01 and Theme.sem.lost) or Theme.fg.heading
    end

    -- The earn rate.
    local rv = self._rail_rate_v or 0
    local r  = rc.rate
    local rq = rateQ(rv)
    if r._q ~= rq then r._q = rq; r.value = TablePanelStats.rateLabel(rv, R.labels.rate_unit) end
    r.value_color = (rv > 0.005 and Theme.sem.won) or (rv < -0.005 and Theme.sem.lost) or Theme.fg.muted

    -- The chips: dim until the first one.
    local d_chips  = self.displayed_chips or state.chips or 0
    local chip_dim = (state.shove_count or 0) == 0 and d_chips < 1
    local c  = rc.chips
    local cq = math.floor(d_chips)
    if c._q ~= cq then c._q = cq; c.value = chipsText(d_chips) end
    c.dim = chip_dim
    local a = rc.achips
    if a then
        local d_achips = self.displayed_anti_chips or state.anti_chips or 0
        local aq = math.floor(d_achips)
        if a._q ~= aq then a._q = aq; a.value = chipsText(d_achips) end
        local pend_a = state.anti_chips_this_run or 0
        local an = rc.achips_next
        if an._q ~= pend_a then
            an._q = pend_a
            an.value = "+" .. pend_a .. " " .. R.labels.next
            an.value_color_token = (pend_a > 0) and "corrupt" or "faint"
        end
    end

    -- SHOVE under the underflow: -999%, never resolving.
    local sl = rc.shove_line
    if broken and sl and sl._q ~= morph then
        sl._q  = morph
        sl.right = self:_brokenText("-999%", "shove", 0.92, 0.12)
        sl._rh = nil
    end
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
    -- Whole pixels: the panel cache blits a slot of exactly this size, and
    -- the 1-bit fonts are nearest-filtered, so a fractional cell would
    -- resample every glyph. Aspect drift is under a pixel.
    return math.floor(pw), math.floor(ph)
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
            pw, ph = math.floor(pw), math.floor(ph)
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
    -- the tables" without a specific table (the item stream falls back
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

    -- The table in the player's hand (the Lava Lamp reads it; its cell is
    -- empty to the board reads while held).
    for i, t in ipairs(tables) do t._held = (i == held_i) or nil end

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
    -- The cell geometry, kept for the drag preview (drawn after the grid).
    do
        local gg = self._grid_geom
        if not gg then gg = {}; self._grid_geom = gg end
        gg.ox, gg.oy, gg.pw, gg.ph, gg.m, gg.cols, gg.rows = origin_x, origin_y, pw, ph, MARGIN, cols, rows
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
                    ClickSurfaces.add("empty", ex, ey, pw, ph)
                end
            end
        end
    end

    -- Every panel's display position chases its cell through RollingValue
    -- (snap-on-first-sight, so boot/rebuild don't animate): panels glide
    -- on any reflow, and the drop settle rides the same chase from the
    -- seeded held position (see _settleDrag).
    --
    -- Two passes (views/TablePanel). Pass A places every panel (its cell
    -- position snapped to whole pixels, so a blit lands on texels) and
    -- PREPARES it: the script events, the animating/at-rest classifier,
    -- and for a resting panel whose key moved, a render of its static
    -- picture into the panel sheet, all inside one canvas switch. Pass B
    -- draws the shadows, then every panel at the same position: a blit
    -- with the live layers over it, or the whole panel. The positions are
    -- kept between the passes in a flat pooled list (four numbers per
    -- panel) so the rolled value is read once and both passes agree.
    local held_slot, swap_id
    if dragging then
        -- Drop target is a CELL, not an insertion point. Hovering an
        -- empty cell moves the held table there; hovering an occupied one
        -- swaps the two. The swap preview mirrors that: the table under
        -- the cursor slides to the held table's cell. Model slots are
        -- untouched until the drop, so hit-box idx values stay correct.
        local mx, my = love.mouse.getPosition()
        dragging.drop_slot = slotAtPoint(mx, my)
        held_slot = tables[held_i].slot
        if dragging.drop_slot and dragging.drop_slot ~= held_slot then
            for _, t in ipairs(tables) do
                if t.slot == dragging.drop_slot then swap_id = t._id; break end
            end
        end
    end

    local P = self._grid_pos
    if not P then P = {}; self._grid_pos = P end
    local cache_on = TablePanel.sheetBegin(n, pw, ph)

    -- Pass A.
    Perf.enter("panel_static")
    for i = 1, n do
        if i ~= held_i then
            local tbl = tables[i]
            local target = (dragging and tbl._id == swap_id) and held_slot or (tbl.slot or 0)
            local tx, ty = cellXY(target)
            local dx = RollingValue.get(TableModel.rollingKey(tbl, "tblx"), tx, SLIDE_RATE, "tables")
            local dy = RollingValue.get(TableModel.rollingKey(tbl, "tbly"), ty, SLIDE_RATE, "tables")
            dx, dy = math.floor(dx + 0.5), math.floor(dy + 0.5)
            -- Post-drop settle: a tiny scale bump as the panel lands,
            -- recentered so it grows in place. Never mid-drag.
            local gw, gh = pw, ph
            if not dragging then
                local pp = Pop.progress(TableModel.rollingKey(tbl, "tbl_settle"))
                if pp > 0 then
                    local sc = Pop.scale(pp, 1, 0.04)
                    gw, gh = pw * sc, ph * sc
                end
            end
            -- A table opening grows in like a window (a scaled panel draws
            -- whole; the cache sends it the immediate way by its size).
            if not tbl._grid_seen then
                tbl._grid_seen = true
                Pop.trigger(TableModel.rollingKey(tbl, "tbl_open"))
            end
            local op = Pop.progress(TableModel.rollingKey(tbl, "tbl_open"), OPEN_SECS)
            if op > 0 then
                local sc = 1 - OPEN_FROM * op
                gw, gh = gw * sc, gh * sc
            end
            local k = i * 4
            P[k - 3], P[k - 2], P[k - 1], P[k] = dx, dy, gw, gh
            -- A scaled (settling) panel is prepared at its drawn size, which
            -- the sheet does not hold: it classifies as a bypass and draws
            -- whole in pass B.
            TablePanel.prepare(tbl, i, dx - (gw - pw) / 2, dy - (gh - ph) / 2, gw, gh,
                               self.game, self.controller)
        end
    end
    TablePanel.sheetEnd()
    Perf.exit("panel_static")

    -- Pass B. Every shadow before any panel when the cache is on: one
    -- batch of rects, and no panel is ever painted over a neighbour's
    -- shadow. With the cache off, draw keeps the shadow inside the panel
    -- (the single pass that shipped).
    Perf.enter("panel_live")
    if cache_on then
        for i = 1, n do
            if i ~= held_i then
                local k = i * 4
                local dx, dy, gw, gh = P[k - 3], P[k - 2], P[k - 1], P[k]
                TablePanel.drawShadow(tables[i], dx - (gw - pw) / 2, dy - (gh - ph) / 2, gw, gh)
            end
        end
    end
    for i = 1, n do
        if i ~= held_i then
            local tbl = tables[i]
            local k = i * 4
            local dx, dy, gw, gh = P[k - 3], P[k - 2], P[k - 1], P[k]
            TablePanel.draw(tbl, i, dx - (gw - pw) / 2, dy - (gh - ph) / 2, gw, gh,
                            self.game, self.controller, self.hit_boxes, cache_on)
            self:_notePanel(tbl, i, dx, dy, pw, ph)
        end
    end
    Perf.exit("panel_live")

    if dragging then
        -- Held panel renders from GrindView:draw (above the sidebars) —
        -- stash its live cell size for TablePanelDrag.drawHeld.
        self._held_draw = { tbl = tables[held_i], idx = held_i, pw = pw, ph = ph }
    else
        self._held_draw = nil
    end
end

-- The closing ghost of table `tbl`: its rect from last frame's panel list,
-- its picture from its panel sheet slot (when the slot is still its own;
-- otherwise it just goes).
function GrindView:_ghostClosedTable(tbl)
    local list_p = self.table_panels or {}
    for n = 1, (self._panels_n or 0) do
        local e = list_p[n]
        if e and e.table_id == tbl._id then
            local canvas, pad = PanelSheet.copySlot(tbl._pslot, tbl)
            if canvas then
                local list = self._closing
                if not list then list = {}; self._closing = list end
                list[#list + 1] = { canvas = canvas, pad = pad, x = e.x, y = e.y, w = e.w, h = e.h,
                                    t0 = love.timer.getTime() }
            end
            return
        end
    end
end

function GrindView:_drawClosing()
    local list = self._closing
    if not list or #list == 0 then return end
    local now = love.timer.getTime()
    local lg = love.graphics
    for i = #list, 1, -1 do
        local g = list[i]
        local p = (now - g.t0) / CLOSE_SECS
        if p >= 1 then
            if g.canvas.release then g.canvas:release() end
            table.remove(list, i)
        else
            local ease = p * p
            local sc, a = 1 - OPEN_FROM * ease, 1 - ease
            local cx, cy = g.x + g.w * 0.5, g.y + g.h * 0.5
            lg.setBlendMode("alpha", "premultiplied")
            lg.setColor(a, a, a, a)
            lg.draw(g.canvas, cx, cy, 0, sc, sc, g.w * 0.5 + g.pad, g.h * 0.5 + g.pad)
            lg.setBlendMode("alpha")
        end
    end
    lg.setColor(1, 1, 1, 1)
end

-- ── The drag preview ───────────────────────────────────────────────────
-- While a table is carried, each table whose position bonuses the drop
-- would change shows the change at the cell it would end up in ("+10%
-- odds", "x1.5 lost", "+20% pace", "tilt risk"), and the in-bounds empty
-- cells that count as empty are outlined while a Sticky Note reads them.
-- models/board_preview does the arithmetic on a virtual layout; nothing
-- moves until the drop. Recomputed only when the drop cell changes.
function GrindView:_updateDragPreview()
    local d = self.drag
    if not (d and d.moved and d.drop_slot) then self._drag_prev = nil; return end
    local dp = self._drag_prev
    if dp and dp.table_id == d.table_id and dp.slot == d.drop_slot then return end
    local tables = self.controller.pool.tables
    local moved
    for _, t in ipairs(tables) do if t._id == d.table_id then moved = t; break end end
    if not moved then self._drag_prev = nil; return end
    local ctx = self.controller.ctx or {}
    local virt, cols, rows, occ = BoardPreview.layout(tables, moved, d.drop_slot, ctx)
    local cur = BoardPreview.layout(tables, moved, moved.slot or 0, ctx)
    local deltas = BoardPreview.deltas(tables, virt, function(t) return cur[t] end, ctx)
    local empties = {}
    if (ctx.odds_per_empty_adjacent or 0) > 0 then
        for r = 0, rows - 1 do
            for c = 0, cols - 1 do
                local slot = TableGrid.pack(r, c)
                local o = occ[slot]
                if not o or (ctx.six_max_counts_empty and o.game_type_id == "six_max") then
                    empties[#empties + 1] = slot
                end
            end
        end
    end
    self._drag_prev = { table_id = d.table_id, slot = d.drop_slot, deltas = deltas, virt = virt, empties = empties }
end

function GrindView:_drawDragPreview()
    local dp, gg = self._drag_prev, self._grid_geom
    if not (dp and gg) then return end
    local lg = love.graphics
    local function cell(slot)
        local r, c = TableGrid.unpack(slot)
        return gg.ox + c * (gg.pw + gg.m), gg.oy + r * (gg.ph + gg.m)
    end
    -- the cells that count as empty
    if #dp.empties > 0 then
        Theme.setColor(Theme.sem.won, 0.45)
        lg.setLineWidth(2)
        for _, slot in ipairs(dp.empties) do
            local x, y = cell(slot)
            lg.rectangle("line", x + 3, y + 3, gg.pw - 6, gg.ph - 6, 6, 6)
        end
        lg.setLineWidth(1)
    end
    local f = self.game.fonts.sm
    lg.setFont(f)
    local th = f:getHeight()
    for t, lines in pairs(dp.deltas) do
        local v = dp.virt[t]
        if v then
            local x, y = cell(v.slot)
            local tw = 0
            for i, l in ipairs(lines) do tw = tw + f:getWidth(l.text) + (i > 1 and 10 or 0) end
            local px = math.floor(x + (gg.pw - tw) / 2)
            local py = math.floor(y + gg.ph * 0.42 - th / 2)
            Theme.setColor(Theme.bg.chrome, 0.92)
            lg.rectangle("fill", px - 6, py - 3, tw + 12, th + 6, 4, 4)
            local cx = px
            for _, l in ipairs(lines) do
                Theme.setColor(l.good and Theme.sem.won or Theme.sem.lost)
                lg.print(l.text, cx, py)
                cx = cx + f:getWidth(l.text) + 10
            end
        end
    end
    lg.setColor(1, 1, 1, 1)
end

-- One entry per drawn table panel for the cursor swarm: where it is, which
-- table it is, and whether a heater is burning on it (a crossing can light
-- a cursor). Rebuilt every draw beside the hit boxes.
function GrindView:_notePanel(tbl, i, x, y, w, h)
    local list = self.table_panels
    if not list then return end
    local n = (self._panels_n or 0) + 1
    self._panels_n = n
    local e = list[n]
    if not e then e = {}; list[n] = e end
    e.x, e.y, e.w, e.h = x, y, w, h
    e.idx, e.table_id = i, tbl._id
    e.heater = tbl.hasStatus and tbl:hasStatus("heater") or false
end

-- ─── THE HOUSE (the captor's poster) ──────────────────────────────────

-- Sits above the SHOVE button (what you shove against). The tutorial's
-- hint bubbles speak from it (views/HintView anchors them to "house"),
-- and the "?" help-desk button lives in its corner.
-- Drawn from shapes until art lands: a framed poster with a gold-roofed
-- house glyph.
-- The House's text box: a fixed rect directly above the poster, the
-- poster's width. It never moves or resizes; text that needs more lines
-- pages (views/StoryView). Computed from the window alone, so every screen
-- puts it in the same place, the grind drawn or not.
function GrindView.storyBoxRect(game)
    local W, H = love.graphics.getDimensions()
    local s  = require("services.FontService").layoutScale(W, H)
    local rw, m, hh = rightColumnW(W), marginFor(s), houseHFor(s)
    local h = storyBoxH(game)
    return { x = W - rw + m, y = H - m - hh - m - h, w = rw - 2 * m, h = h }
end
function GrindView:_storyBoxH()    return storyBoxH(self.game) end
function GrindView:_storyBoxRect() return GrindView.storyBoxRect(self.game) end

function GrindView:_houseRect()
    local W, H = love.graphics.getDimensions()
    return {
        x = W - RIGHT_W + MARGIN, w = RIGHT_W - 2 * MARGIN,
        y = H - MARGIN - HOUSE_H,
        h = HOUSE_H,
    }
end
-- The "?" badge in the poster's bottom-right corner.
function GrindView:_houseHelpBtnRect()
    local r  = self:_houseRect()
    local s  = self.game.ui_scale or 1
    -- Fixed badge size — it used to scale with the poster's height,
    -- which was fine at 92 and a slab at 184.
    local sz = math.floor(30 * s)
    local m  = math.floor(6 * s)
    return { x = r.x + r.w - sz - m, y = r.y + r.h - sz - m, w = sz, h = sz }
end


-- The poster hangs from a pin at its top centre: a click swings it there
-- (services/Poke), and the speaker bolted to it rattles on its own.
function GrindView:_drawHouse()
    local r = self:_houseRect()
    ClickSurfaces.add("paper", r.x, r.y, r.w, r.h, { poke = "house:poster" })
    if Poke.active("house:poster") then
        return Poke.draw("house:poster", r.x + r.w * 0.5, r.y, self._drawHouseBody, self)
    end
    return self:_drawHouseBody()
end

-- The portrait is a still (HouseArt.paintPortrait, one frozen moment), so
-- it is painted once into its own canvas at its size and drawn from there:
-- the painting clips itself with a scissor, which ignores the poster's
-- swing, so painted live it swung inside a box that stayed put. Without a
-- canvas (headless, a refusing GPU) it paints live.
function GrindView:_drawPortrait(ax, ay, aw, ah)
    aw, ah = math.floor(aw), math.floor(ah)
    local pc = self._portrait
    if not pc or pc.w ~= aw or pc.h ~= ah then
        if pc and pc.canvas and pc.canvas.release then pc.canvas:release() end
        pc = { w = aw, h = ah }
        local ok, c = pcall(love.graphics.newCanvas, aw, ah, { dpiscale = 1 })
        if ok and c then
            love.graphics.push("all")
            love.graphics.setCanvas(c)
            love.graphics.clear(0, 0, 0, 0)
            love.graphics.origin()
            love.graphics.setScissor()
            HouseArt.paintPortrait(0, 0, aw, ah)
            love.graphics.pop()
            pc.canvas = c
        end
        self._portrait = pc
    end
    if pc.canvas then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(pc.canvas, ax, ay)
    else
        HouseArt.paintPortrait(ax, ay, aw, ah)
    end
end

function GrindView:_drawHouseBody()
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
    self:_drawPortrait(ax, ay, aw, ah)

    -- The intercom, bolted onto the poster's top-left, under the House's
    -- text box (the box's tail points down at it): how the House speaks. Lit, breathing and rattling while a story line
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
        local spx, spy = ax + fl(6 * s), ay + fl(6 * s)
        ClickSurfaces.addLocal("speaker", spx, spy, sw2, sh2, { poke = "house:speaker" })
        Poke.draw("house:speaker", spx + sw2 * 0.5, spy + sh2 * 0.5,
                  HouseArt.drawSpeaker, spx, spy, sw2, sh2, speaking, love.timer.getTime())
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

-- A floater's text is fixed for its life, so it is split once and its
-- widest line measured once per font, instead of three gmatch passes per
-- floater per frame (and every idle table keeps a parked one).
local function floaterLines(t)
    local lines = t._lines
    if not lines then
        lines = {}
        for line in (t.text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        t._lines = lines
    end
    return lines
end

local function floaterWidest(t, font)
    if t._widest_font == font then return t._widest end
    local widest = 0
    for _, line in ipairs(floaterLines(t)) do
        if line ~= "" then
            local tw = line:find("{", 1, true)
                       and IconText.measure(line, font, IconText.PLAIN)
                       or font:getWidth(line)
            if tw > widest then widest = tw end
        end
    end
    t._widest, t._widest_font = widest, font
    return widest
end

-- One text object per floater for its plain lines (LÖVE 12 calls it a
-- TextBatch, 11 a Text; love.js has the latter). nil when the engine has
-- neither (the headless stub), and the caller falls back to prints.
local _newTextBatch = love and love.graphics
    and (love.graphics.newTextBatch or love.graphics.newText) or nil
local _stroke_ct = { { 0, 0, 0, 0.85 }, "" }   -- coloured-text scratch for the stroke adds
local _text_ct   = { { 1, 1, 1, 1 }, "" }      -- and for the line itself
local function floaterBatch(t, font, color, lines, step, line_h)
    if not _newTextBatch then return nil end
    if t._tb and t._tb_font == font and t._tb_color == color and t._tb_lines == lines then
        return t._tb
    end
    local tb = t._tb
    if tb then
        if tb.setFont then tb:setFont(font) end
        tb:clear()
    else
        local ok, fresh = pcall(_newTextBatch, font)
        if not ok or not fresh then return nil end
        tb = fresh
        t._tb = tb
    end
    t._tb_font, t._tb_color, t._tb_lines = font, color, lines
    local sc = _stroke_ct[1]
    sc[1], sc[2], sc[3] = FLOATER_STROKE_COLOR[1], FLOATER_STROKE_COLOR[2], FLOATER_STROKE_COLOR[3]
    local tc = _text_ct[1]
    tc[1], tc[2], tc[3], tc[4] = color[1], color[2], color[3], 1
    local n_lines = #lines
    local ly = -((n_lines - 1) * step + line_h) * 0.5
    for _, line in ipairs(lines) do
        if line ~= "" and not line:find("{", 1, true) then
            local tw = font:getWidth(line)
            _stroke_ct[2] = line
            for _, off in ipairs(FLOATER_STROKE_OFFSETS) do
                tb:add(_stroke_ct, -tw * 0.5 + off[1], ly + off[2])
            end
            _text_ct[2] = line
            tb:add(_text_ct, -tw * 0.5, ly)
        end
        ly = ly + step
    end
    return tb
end

function GrindView:_drawFloatingText()
    local fonts = self.game.fonts
    -- Resolve a controller-supplied color_token through Theme palettes.
    -- Keeps the controller free of view imports while still letting it
    -- name colors symbolically (e.g., "amber" for streak callouts).
    local resolveToken = Theme.color
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
                local widest = floaterWidest(t, font)
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
            -- The table's pot label stands aside while this pops over it.
            local owner = t.fit_table or t.table
            if owner then owner._floater_pop_t = love.timer.getTime() end
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
        local lines   = floaterLines(t)
        local n_lines = #lines

        love.graphics.push()
        love.graphics.translate(t.x, t.y)
        if scale ~= 1 then love.graphics.scale(scale, scale) end
        local ly = -((n_lines - 1) * step + line_h) * 0.5
        -- Parked floats sit on the felt indefinitely, over whatever color
        -- happens to be there — plate them like the hand-name pill so the
        -- number is readable on any ground (red on green was not).
        if t.has_persisted then
            local widest = floaterWidest(t, font)
            if widest > 0 then
                local block_h = (n_lines - 1) * step + line_h
                -- The parked readout's plate, in screen space, for story
                -- marks: views/TablePanel folds it into the stack box.
                if t.table and t.table._id then
                    AnchorRegistry.set(TableModel.rollingKey(t.table, "result"),
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
        -- The plain lines and their stroke rings are one text batch per
        -- floater, rebuilt only when the font, the colour or the lines
        -- change (nine prints per line per frame otherwise, on a board
        -- carrying a parked readout per table). The batch is drawn under
        -- setColor(1,1,1,alpha): the stroke's 0.85 and the text's colour
        -- are baked into its adds, so the multiply gives today's exact
        -- values. Icon lines keep the IconText path. Headless, or on a
        -- build without text objects, the print ring stays.
        local tb = floaterBatch(t, font, color, lines, step, line_h)
        if tb then
            love.graphics.setColor(1, 1, 1, alpha)
            love.graphics.draw(tb)
        end
        for _, line in ipairs(lines) do
            if line:find("{", 1, true) then
                -- Inline icons (e.g. "+1 {chip}") — IconText, no stroke ring.
                local tw = IconText.measure(line, font, IconText.PLAIN)
                IconText.draw(self.game, line, -tw * 0.5, ly, font, color, alpha, IconText.PLAIN)
            elseif line ~= "" and not tb then
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
    local pr = self._pile_rect
    if not pr then pr = {}; self._pile_rect = pr end
    pr.x, pr.y, pr.w, pr.h = band_x, band_y, band_w, BOTTOM_BAND_H
    local stack_y  = band_y + BOTTOM_BAND_H - 22

    -- Stash for emission code (1-frame stale, fine).
    AnchorRegistry.set("bankroll", center_x, stack_y)
    -- The House's story band: a strip sitting ON the pile band's top edge,
    -- between the sidebars. The panel bottom-aligns to it (views/StoryView),
    -- so the words end where the chips begin instead of over them.
    local strip_h = math.floor(40 * (self.game.ui_scale or 1))
    AnchorRegistry.set("story:band", band_x, band_y - strip_h, band_w, strip_h)
    -- ...but on this screen the box is fixed above the poster: same place,
    -- same size, whatever it says.
    local sb = self:_storyBoxRect()
    AnchorRegistry.set("story:box", sb.x, sb.y, sb.w, sb.h)

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
    -- cards on every side. As many columns as the band holds, and at the
    -- stack tier a chip target that fills one row of them (a pile that
    -- held ten columns at ten sextillion read as a modest stack); below
    -- that tier the tier's own count, so an early bankroll is not a wall
    -- of pennies.
    local cols = math.max(BANKROLL_PILE_COLS,
                          math.floor((band_w - 32) / Chips.columnPitch()))
    local tier = Denoms.tierFromAmount(bankroll)
    local o = self._bankroll_place
    if not o then o = { align = "center" }; self._bankroll_place = o end
    o.max_w, o.max_cols, o.max_rows = band_w - 32, cols, BANKROLL_PILE_ROWS
    ChipPile.place("bankroll", center_x, stack_y, o)
    local so = self._bankroll_sync
    if not so then so = { palette = ChipData.full_palette }; self._bankroll_sync = so end
    so.tier        = tier
    so.chip_target = (tier == "stack") and cols * Chips.MAX_PER_COLUMN or nil
    ChipPile.sync("bankroll", bankroll, so)
    ChipPile.draw("bankroll")
    -- The pile as a click surface: a tap wobbles it (services/ClickFX).
    do
        local fw, fh = ChipPile.footprint("bankroll")
        if fw > 0 then
            local R = Chips.radius()
            fw = math.min(fw, band_w - 32)
            ClickSurfaces.add("chips", center_x - fw * 0.5, stack_y - fh - R * 0.5, fw, fh + R * 1.5,
                              BANKROLL_SURFACE)
        end
    end
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
    for _, o in ipairs(Theme.HALO_OFFSETS) do
        love.graphics.print(str, x + o[1], y + o[2])
    end
end

function GrindView:draw(overlay_fn)
    local W, H = love.graphics.getDimensions()
    -- The board's click surfaces start over with its draw. main.lua clears
    -- them every frame too; this keeps a harness that drives the view
    -- directly (sim/) from growing the list without bound.
    ClickSurfaces.beginFrame()

    -- No window fill here: the frame canvas is cleared to the palette's
    -- window colour (Theme.setActive sets love's background colour), so a
    -- second full-screen quad under everything was pure overdraw.

    -- Reset hit boxes — they're rebuilt during this draw pass. The panel
    -- list beside them is the cursor swarm's map of the board
    -- (services/CursorPool: clashes and crossings).
    -- The hit-box list is wiped in place, not replaced: at a full board
    -- a fresh list regrew through every size each frame.
    do
        local hb = self.hit_boxes
        if hb then for i = #hb, 1, -1 do hb[i] = nil end else self.hit_boxes = {} end
    end
    -- The panel list is pooled: entries are rewritten in place and the
    -- tail is trimmed after the grid draws (_notePanel).
    self.table_panels = self.table_panels or {}
    self._panels_n = 0

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

    -- Click surfaces under what draws on them (services/ClickSurfaces):
    -- the rail's ground, then its readouts and buttons register on top.
    if self.rail and self.rail.w then
        ClickSurfaces.add("rail", self.rail.x, self.rail.y, self.rail.w, self.rail.h or (H - self.rail.y))
    end
    Perf.enter("rail");     self:drawChrome(W);               Perf.exit("rail")
    Perf.enter("grid");     self:_drawCenterGrid(W, H);       Perf.exit("grid")
    self:_drawClosing()
    do
        local list, n = self.table_panels, self._panels_n or 0
        for i = #list, n + 1, -1 do list[i] = nil end
    end
    for _, pnl in ipairs(self._side_panels or {}) do
        if pnl.w then ClickSurfaces.add("chrome", pnl.x, pnl.y, pnl.w, pnl.h or H) end
    end
    Perf.enter("sidebars"); self.left_panel:draw(self.game)
                            self.right_panel:draw(self.game);  Perf.exit("sidebars")
    Perf.enter("house");    self:_drawHouse();                 Perf.exit("house")

    -- Held (dragged) table panel — drawn after the sidebars and floating
    -- text so it rides above them while it's carried around; the chip
    -- flights, ghosts and cursor swarm below still render on top of it.
    if self.drag and self.drag.moved and self._held_draw then
        TablePanelDrag.drawHeld(self.game, self.controller, self.drag, self._held_draw)
    end

    -- Bankroll chip pile in the bottom-middle band. Registers the
    -- screen-space anchor (via AnchorRegistry) flying-chip emission targets.
    Perf.enter("piles");    self:_drawBankrollChips(W, H);     Perf.exit("piles")

    -- Flying chips between source and destination (pot ↔ player ↔
    -- bankroll). Renders above panels and the bankroll pile but below
    -- the cursor swarm.
    Perf.enter("flights");  FlightSystem.draw();               Perf.exit("flights")
    Perf.gauge("flights", FlightSystem.count())

    -- Press-then-vanish ghosts for DEAL / REBUY / [×] click animations.
    -- Drawn above panels so they sit visually where the live button
    -- was. Must be drawn BEFORE cursors, otherwise the ghost rendered
    -- after a cursor click covers the cursor that just clicked it.
    Perf.enter("ghosts");   Ghosts.draw();                     Perf.exit("ghosts")

    -- The item stream: every catalog item that just did its job floats up
    -- the table area, one icon per fire (views/ItemStream).
    Perf.enter("items");    ItemStream.draw(self.game);        Perf.exit("items")

    -- Cursor swarm — drawn last so cursors are always on top, including
    -- on top of the press-fade ghost they just dispatched.
    Perf.enter("cursors");  CursorPool.draw(self.game);        Perf.exit("cursors")

    -- What a hand resolved to, over the flights, the item triggers and the
    -- cursors: the showdown hand names, then the result floaters.
    TablePanel.flushHandLabels(self.game)
    Perf.enter("floaters"); self:_drawFloatingText();          Perf.exit("floaters")

    -- A hovered upgrade's cards over the tables it moves: above all of
    -- that, under the tooltip (main), so they can be read.
    TablePanel.flushPreviewCards(self.game)
    -- And while a table is carried: what dropping it here would change.
    self:_drawDragPreview()

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
    -- Over the focus cap: a red plate under the FOCUS and TABLES pair,
    -- the full height of the rail and no wider than the pair's slot, so
    -- it never crosses a neighbour; its fill and frame step up per table
    -- over and otherwise hold still. Drawn before the rail so the
    -- readouts sit on it; the rect is last frame's anchor.
    if self._focus_over then
        local slot = AnchorRegistry.get("rail:focus")
        if slot then
            local step = math.min(self._focus_extra or 1, 5)
            local pad  = Theme.space.stat_pad
            local x, w = slot[1] - pad, slot[3] + pad * 2
            local y, h = H - RAIL_H + 2, RAIL_H - 4
            Theme.setColor(Theme.sem.lost, 0.14 + 0.08 * step)
            love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
            Theme.setColor(Theme.sem.lost, 0.9)
            love.graphics.setLineWidth(1 + step)
            love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
            love.graphics.setLineWidth(1)
        end
    end
    self.rail:draw(self.game)
    -- The step's kick: the OVER FOCUS readout redrawn above the rail,
    -- free of its clip, bursting UP out of the bar (it sits at the bottom
    -- of the screen, so it grows from its own bottom edge and lifts) and
    -- shaking, harder the further over, white at the kick and settling
    -- to red as it comes back down into the cell (the cell draws nothing
    -- meanwhile). Overlapping whatever is above it is the point: it is a
    -- pop, it settles. Motion low: a still, larger flash.
    local kick = self._focus_kick or 0
    if self._focus_over and kick > 0.01 then
        local cell = AnchorRegistry.get("cell:focus")
        local val  = AnchorRegistry.get("cell:focus_value")
        if cell and val then
            local fonts = self.game.fonts
            local k     = math.min(1, kick)
            local step  = math.min(self._focus_extra or 1, 5)
            local scale = 1 + (0.45 + 0.1 * step) * k
            local lift  = -(10 + 5 * step) * k
            local jx, jy = 0, 0
            if Motion.level("ui") > Motion.LOW then
                local t = love.timer.getTime() * 60
                jx = (2 + 1.5 * step) * k * math.sin(t * 1.9)
                jy = (1.5 + step) * k * math.cos(t * 2.3)
            else
                scale, lift = 1 + 0.3 * k, -6 * k
            end
            -- About the cell's bottom-centre: the growth goes upward.
            local cx, cy = cell[1] + cell[3] * 0.5, cell[2] + cell[4]
            local c = Theme.sem.lost
            Theme.setColor({ c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k })
            love.graphics.push()
            love.graphics.translate(cx + jx, cy + jy + lift)
            love.graphics.scale(scale, scale)
            love.graphics.translate(-cx, -cy)
            love.graphics.setFont(fonts.sm)
            love.graphics.print(self._focus_label or "", cell[1], cell[2])
            love.graphics.setFont(fonts.lg)
            love.graphics.print(self._focus_value or "", val[1], val[2])
            love.graphics.pop()
        end
    end
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
    if id == "shove" then
        -- SHOVE is held, not clicked: it fires when the fill is full.
        HoldPress.begin("shove", function() self:_handleSidebarButton("shove") end,
            function(mx, my) return self:chromeHit(mx, my) == "shove" end)
    elseif id then
        self:_handleSidebarButton(id)
    end
    local r = self.rail
    return id ~= nil or (r ~= nil and y >= r.y and x >= r.x and x < r.x + r.w)
end

function GrindView:mousepressed(x, y, b)
    if b == 2 then return self:_rightClick(x, y) end
    if b ~= 1 then return end

    -- The rail first.
    if self:chromeMousepressed(x, y) then return end
    -- The "?" on THE HOUSE poster: the glossary rises from the poster.
    do
        local hb = self:_houseHelpBtnRect()
        if x >= hb.x and x < hb.x + hb.w
           and y >= hb.y and y < hb.y + hb.h then
            ClickFlash.press("help_btn", "help_btn")
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
                    ClickFlash.press("hit", hb.action .. ":" .. (hb.table_id or hb.idx))
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
    ClickFlash.press("button", id)
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
    local up_id = id:match("^buy_runup_(.+)$")
    if up_id then
        self.controller:buyRunUpgrade(up_id)
        return
    end
    -- buy_catalog_ removed — catalog purchases now happen in the post-bust
    -- CatalogModal (see views/CatalogModal.lua).
end

-- Right-click: the cursor switch for what is under the pointer. A table
-- stops (or lets) the cursors dealing there; an add-table row, its whole
-- group; the Cursor upgrade, every table (data/story first_cursors).
function GrindView:_rightClick(x, y)
    local ctx = self.controller and self.controller.ctx
    if not (ctx and ctx.cursor_unlocked) then return end
    for _, panel in ipairs({ self.right_panel, self.left_panel }) do
        if x >= panel.x and x < panel.x + panel.w then
            local comps = panel:getComponents()
            if not comps then return end
            -- Whatever button is under the pointer, affordable or not: a
            -- disabled button gives no hit, but it does report the hover.
            HoverSvc.clearNamespace("button")
            CR.hitTest(comps, panel.x, panel.w, x, panel:toContentY(y), self.game)
            if HoverSvc.is("button", "buy_runup_cursor") then
                self:_handleSidebarButton("type_cursor_deal")
                return
            end
            for _, comp in ipairs(comps) do
                local id = comp.id
                if id and id:match("^add_table:") and HoverSvc.is("button", id) then
                    self:_handleSidebarButton("type_cursor_deal:" .. id:sub(#"add_table:" + 1))
                    return
                end
            end
            return
        end
    end
    local P = self._grid_pos
    if not P then return end
    for i, t in ipairs(self.controller.pool.tables) do
        local k = i * 4
        local px, py, pw, ph = P[k - 3], P[k - 2], P[k - 1], P[k]
        if px and x >= px and x < px + pw and y >= py and y < py + ph then
            self.controller:toggleCursorMute(i)
            ClickFlash.press("hit", "toggle_cursor:" .. (t._id or i))
            return
        end
    end
end

-- Hit-box action handlers. Adding a new clickable region = one entry here
-- + one hit-box record in TablePanel/GrindView's draw walk that carries
-- the same action key. No if/elseif chain on hb.action.
local HIT_BOX_HANDLERS = {
    deal                = function(self, hb) self.controller:dealHand(hb.idx)              end,
    rebuy               = function(self, hb) self.controller:rebuyTable(hb.idx)            end,
    remove_table        = function(self, hb) self.controller:removeTable(hb.idx)           end,
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
        ClickFlash.press("hit", hb.action .. ":" .. (hb.table_id or hb.idx))
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
