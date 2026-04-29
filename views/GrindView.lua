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
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local RunUpgrades = require("data.run_upgrades")
local Catalog     = require("data.catalog")
local Constants   = require("data.constants")

local GrindView = {}
GrindView.__index = GrindView

-- Layout constants.
local TOP_BAR_H            = 50
local LEFT_W               = 280
local RIGHT_W              = 250
local MARGIN               = 12
local SHOVE_BTN_H          = 64
local PANEL_REMOVE_BTN_SIZE = 22
local STAKE_UP_BTN_H       = 26
local STAKE_UP_BTN_PAD     = 8
local PILL_H               = 18
local PILL_GAP             = 4

-- ─── Construction ─────────────────────────────────────────────────────

function GrindView:new(game, controller)
    local self = setmetatable({
        game       = game,
        controller = controller,
        hit_boxes  = {},   -- per-frame click targets for non-Panel UI (table buttons, SHOVE)
        selected_gtype = "six_max",  -- which game-type sub-tab is showing in the Tables tab
    }, GrindView)

    self:_buildPanels()
    return self
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
            love.graphics.setFont(fonts.ui_small)
            for i, gt in ipairs(GameTypes) do
                local bx = strip_x + (i - 1) * btn_w
                local active = (gt.id == self_ref.selected_gtype)
                Theme.setColor(active and Theme.bg.widget_hover or Theme.bg.chrome)
                love.graphics.rectangle("fill", bx, y, btn_w - 2, STRIP_H - 4, Theme.space.radius)
                Theme.setColor(active and Theme.border.strong or Theme.border.default)
                love.graphics.rectangle("line", bx, y, btn_w - 2, STRIP_H - 4, Theme.space.radius)
                Theme.setColor(active and Theme.fg.heading or Theme.fg.muted)
                love.graphics.printf(gt.short or gt.name, bx, y + 8, btn_w - 2, "center")
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
                    return { id = "gtype:" .. gt.id }
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

        components[#components + 1] = {
            type     = "button",
            id       = "add_table:" .. stake.id .. ":" .. gtype_id,
            disabled = disabled,
            lines = {
                { text = "+ " .. stake.display_name, style = "heading" },
                { text = sub, style = "small" },
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
        local is_owned    = owned[item.id]
        local cant_afford = (not is_owned) and state.pp < item.cost_pp
        local disabled    = is_owned or cant_afford

        local cost_label
        if is_owned then
            cost_label = "OWNED"
        else
            cost_label = item.cost_pp .. " PP"
        end

        components[#components + 1] = {
            type     = "button",
            id       = "buy_catalog_" .. item.id,
            disabled = disabled,
            lines = {
                { text = item.name, style = "heading" },
                { text = item.description or "", style = "small" },
                { text = cost_label, style = is_owned and "muted" or "body" },
            },
        }
    end

    return components
end

function GrindView:_buildUpgradesTabComponents()
    local state = self.game.state

    local components = {}
    components[#components + 1] = { type = "label", style = "muted", text = "RUN UPGRADES", h = 22 }

    for _, up in ipairs(RunUpgrades) do
        local level   = self.controller:getRunUpgradeLevel(up.id)
        local max_lvl = up.max_level or 1
        local at_max  = level >= max_lvl
        local next_cost = self.controller:getRunUpgradeNextCost(up)
        local cant_afford = next_cost and state.bankroll < next_cost
        local disabled    = at_max or cant_afford

        local cost_label
        if at_max then
            cost_label = string.format("MAX  Lv %d/%d", level, max_lvl)
        else
            cost_label = string.format("Lv %d/%d  ·  $%.2f", level, max_lvl, next_cost or 0)
        end

        components[#components + 1] = {
            type     = "button",
            id       = "buy_runup_" .. up.id,
            disabled = disabled,
            lines = {
                { text = up.name, style = "heading" },
                { text = up.description or "", style = "small" },
                { text = cost_label, style = at_max and "muted" or "body" },
            },
        }
    end

    return components
end

-- ─── Per-frame update + hover ─────────────────────────────────────────────

function GrindView:update(_)
    local mx, my = love.mouse.getPosition()
    self.left_panel:update(my)
    self.right_panel:update(my)
    self.left_panel:updateHover(mx, my, self.game)
    self.right_panel:updateHover(mx, my, self.game)

    -- Hit-test components for hover (writes "button" namespace into HoverService).
    for _, panel in ipairs({ self.left_panel, self.right_panel }) do
        local comps = panel:getComponents()
        if comps then
            local cy = panel:toContentY(my)
            CR.hitTest(comps, panel.x, panel.w, mx, cy, self.game)
        end
    end
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

    -- BANKROLL = spendable / off-table money. The big number — that's
    -- what the player actually buys upgrades with.
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.kpi)
    love.graphics.print(moneyText(state.bankroll), 16, 8)

    local tied_up = self.controller:tiedUp()
    local total   = state.bankroll + tied_up
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

    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(moneyText(tied_up), 200, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(total), 300, 22)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(ppText(state.pp), 400, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(state.peak_bankroll), 470, 22)
    love.graphics.print(tostring(n_tables), 580, 22)

    -- Focus % color-coded: green = 100% (no penalty), amber = 70–99%,
    -- red = <70%.
    local focus_color
    if focus_pct >= 100     then focus_color = Theme.status.good
    elseif focus_pct >= 70  then focus_color = Theme.status.warn
    else                         focus_color = Theme.status.error end
    Theme.setColor(focus_color)
    love.graphics.print(focus_pct .. "%", 660, 22)
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
    local grid_h = H - TOP_BAR_H - 2 * MARGIN

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
        return
    end

    local layout = bestGridLayout(n, grid_w, grid_h)
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
    local rate = math.min(Constants.GAMEPLAY.SHOVE_RATE_CAP, ctx.shove_rate or 0)
    local pending_pp = state.pp_this_run or 0

    Theme.setColor(can_shove and Theme.status.error or Theme.bg.sunken, can_shove and 0.85 or 0.4)
    love.graphics.rectangle("fill", sb.x, sb.y, sb.w, sb.h, Theme.space.radius)
    Theme.setColor(can_shove and Theme.status.error or Theme.border.soft)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", sb.x, sb.y, sb.w, sb.h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    Theme.setColor(can_shove and Theme.fg.heading or Theme.fg.disabled)
    love.graphics.setFont(self.game.fonts.heading)
    love.graphics.printf("SHOVE", sb.x, sb.y + 4, sb.w, "center")

    -- Pending PP — what the player banks if they pull the trigger now.
    -- Violet matches the bounty floating-text so the connection is visible.
    Theme.setColor(can_shove and Theme.data.violet or Theme.fg.faint)
    love.graphics.setFont(self.game.fonts.ui_small)
    love.graphics.printf(string.format("+%d PP banked", pending_pp),
        sb.x, sb.y + 30, sb.w, "center")

    Theme.setColor(can_shove and Theme.fg.primary or Theme.fg.faint)
    love.graphics.printf(string.format("%.1f%% per runout", rate * 100),
        sb.x, sb.y + 46, sb.w, "center")
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

-- ─── Composite draw ───────────────────────────────────────────────────

function GrindView:draw()
    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Reset hit boxes — they're rebuilt during this draw pass.
    self.hit_boxes = {}

    self:_drawTopBar(W)
    self:_drawCenterGrid(W, H)
    self.left_panel:draw(self.game)
    self.right_panel:draw(self.game)
    self:_drawShoveButton()
    self:_drawFloatingText()

    -- Cursor swarm — drawn above panels / sidebars / shove / floating text
    -- so the swarm is always visible. Renders BEFORE the debug tooltip so
    -- that tooltip stays on top of everything (including cursors).
    CursorPool.draw()

    -- Backtick debug tooltip — flushed last so it draws above every other
    -- view layer (sidebar panels, shove button, floating text included).
    TablePanel.flushDebugOverlay(self.game)
end

-- ─── Mouse routing ────────────────────────────────────────────────────

function GrindView:mousepressed(x, y, b)
    if b ~= 1 then return end

    -- SHOVE button has priority — it's bottom-right and overlaps the right panel zone.
    local sb = self:_shoveButtonRect()
    if x >= sb.x and x < sb.x + sb.w and y >= sb.y and y < sb.y + sb.h then
        -- Bank the run's pending PP at the moment of pulling the trigger.
        -- Bounties locked during the run only convert to spendable PP if
        -- the player actually shoves — F2 debug toggles bypass this, so
        -- dev shortcuts don't grant free PP.
        local state = self.game.state
        state.pp = state.pp + (state.pp_this_run or 0)
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

function GrindView:mousemoved(_, _, _, _) end

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
