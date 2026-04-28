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
local Stakes      = require("data.stakes")
local RunUpgrades = require("data.run_upgrades")
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

function GrindView:_buildTablesTabComponents()
    local state  = self.game.state
    local cap    = self.controller:tableSlotsCap()
    local active = self.controller.pool:count()

    local components = {}
    components[#components + 1] = { type = "label", style = "muted", text = "ADD TABLE", h = 22 }

    for _, stake in ipairs(Stakes) do
        local locked   = state.bankroll < stake.unlock_bankroll
        local full     = active >= cap
        local disabled = locked or full

        local sub
        if locked then
            sub = "unlocks at $" .. tostring(stake.unlock_bankroll)
        elseif full then
            sub = "all slots filled"
        else
            sub = string.format("win %.0f%%  ·  pot $%.2f",
                stake.win_rate * 100, stake.pot_size)
        end

        components[#components + 1] = {
            type     = "button",
            id       = "add_table_" .. stake.id,
            disabled = disabled,
            lines = {
                { text = "+ " .. stake.display_name, style = "heading" },
                { text = sub, style = "small" },
            },
        }
    end

    components[#components + 1] = { type = "spacer", h = 8 }
    components[#components + 1] = { type = "divider", h = 6 }
    components[#components + 1] = {
        type  = "label",
        style = "small",
        text  = string.format("Active: %d / %d", active, cap),
        h     = 24,
    }

    return components
end

function GrindView:_buildUpgradesTabComponents()
    local state = self.game.state
    local owned = {}
    for _, id in ipairs(state.run_upgrade_ids) do owned[id] = true end

    local components = {}
    components[#components + 1] = { type = "label", style = "muted", text = "RUN UPGRADES", h = 22 }

    for _, up in ipairs(RunUpgrades) do
        local is_owned    = owned[up.id]
        local cant_afford = (not is_owned) and state.bankroll < up.cost
        local disabled    = is_owned or cant_afford

        local cost_label
        if is_owned then
            cost_label = "OWNED"
        else
            cost_label = "$" .. tostring(up.cost)
        end

        components[#components + 1] = {
            type     = "button",
            id       = "buy_runup_" .. up.id,
            disabled = disabled,
            lines = {
                { text = up.name, style = "heading" },
                { text = up.description or "", style = "small" },
                { text = cost_label, style = is_owned and "muted" or "body" },
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

    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.kpi)
    love.graphics.print(moneyText(state.bankroll), 16, 8)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print("PP",   260, 6)
    love.graphics.print("PEAK", 380, 6)

    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(ppText(state.pp), 260, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(state.peak_bankroll), 380, 22)
end

-- ─── Center grid ──────────────────────────────────────────────────────

function GrindView:_drawCenterGrid(W, H)
    local grid_x = LEFT_W + MARGIN
    local grid_y = TOP_BAR_H + MARGIN
    local grid_w = W - LEFT_W - RIGHT_W - 2 * MARGIN
    local grid_h = H - TOP_BAR_H - 2 * MARGIN

    local cols, rows = 2, 3
    local pw = (grid_w - (cols - 1) * MARGIN) / cols
    local ph = (grid_h - (rows - 1) * MARGIN) / rows

    local cap = self.controller:tableSlotsCap()
    local tables = self.controller.pool.tables

    -- Render every slot up to cap (occupied + empty).
    local slots_to_show = math.min(cap, cols * rows)
    for i = 1, slots_to_show do
        local r = math.floor((i - 1) / cols)
        local c = (i - 1) % cols
        local x = grid_x + c * (pw + MARGIN)
        local y = grid_y + r * (ph + MARGIN)
        local t = tables[i]
        if t then
            self:_drawTablePanel(t, i, x, y, pw, ph)
        else
            self:_drawEmptySlot(x, y, pw, ph)
        end
    end
end

function GrindView:_drawEmptySlot(x, y, w, h)
    Theme.setColor(Theme.bg.sunken, 0.4)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)
    love.graphics.setFont(self.game.fonts.ui_small)
    Theme.setColor(Theme.fg.faint)
    love.graphics.printf("empty slot", x, y + h / 2 - 8, w, "center")
end

-- Returns the next stake tier in order if it exists AND the player's
-- bankroll has unlocked it. Returns nil otherwise.
function GrindView:_nextStakeAvailable(t)
    local found = false
    for _, s in ipairs(Stakes) do
        if found then
            if self.game.state.bankroll >= s.unlock_bankroll then
                return s
            end
            return nil
        end
        if s.id == t.stake_id then found = true end
    end
    return nil
end

function GrindView:_drawTablePanel(t, idx, x, y, w, h)
    -- Update screen-space center for floating text spawn.
    t.x = x + w / 2
    t.y = y + h / 2

    local fonts = self.game.fonts
    local stats = t:liveStats(self.controller.ctx or {})

    -- Card background.
    Theme.setColor(Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, w, h, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, w, h, Theme.space.radius)

    -- Header.
    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print((stats and stats.stake_display) or "?", x + 12, y + 10)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(t.hands_played .. " hands", x + 12, y + 36)

    -- Remove [×] button (top right). Disabled if it's the last table.
    local can_remove = self.controller.pool:count() > 1
    local rb_x = x + w - 12 - PANEL_REMOVE_BTN_SIZE
    local rb_y = y + 10
    Theme.setColor(can_remove and Theme.bg.widget_hover or Theme.bg.sunken, 0.6)
    love.graphics.rectangle("fill", rb_x, rb_y, PANEL_REMOVE_BTN_SIZE, PANEL_REMOVE_BTN_SIZE, Theme.space.radius)
    Theme.setColor(can_remove and Theme.border.strong or Theme.border.soft)
    love.graphics.rectangle("line", rb_x, rb_y, PANEL_REMOVE_BTN_SIZE, PANEL_REMOVE_BTN_SIZE, Theme.space.radius)
    Theme.setColor(can_remove and Theme.fg.heading or Theme.fg.disabled)
    love.graphics.setFont(fonts.ui)
    love.graphics.printf("x", rb_x, rb_y + 3, PANEL_REMOVE_BTN_SIZE, "center")
    if can_remove then
        self.hit_boxes[#self.hit_boxes + 1] = {
            x = rb_x, y = rb_y, w = PANEL_REMOVE_BTN_SIZE, h = PANEL_REMOVE_BTN_SIZE,
            action = "remove_table", idx = idx,
        }
    end

    -- Last-N results pill strip.
    local strip_y = y + 64
    local strip_x = x + 12
    local n_pills = #t.last_results
    local pill_w  = math.floor((w - 24 - (5 - 1) * PILL_GAP) / 5)
    if pill_w < 24 then pill_w = 24 end
    for i, r in ipairs(t.last_results) do
        local px = strip_x + (i - 1) * (pill_w + PILL_GAP)
        Theme.setColor(r.won and Theme.status.good or Theme.status.error, 0.30)
        love.graphics.rectangle("fill", px, strip_y, pill_w, PILL_H, Theme.space.radius)
        Theme.setColor(r.won and Theme.status.good or Theme.status.error)
        love.graphics.rectangle("line", px, strip_y, pill_w, PILL_H, Theme.space.radius)

        love.graphics.setFont(fonts.ui_small)
        Theme.setColor(Theme.fg.heading)
        local label = (r.won and "+" or "-") .. string.format("%.2f", math.abs(r.delta))
        local lw = fonts.ui_small:getWidth(label)
        love.graphics.print(label, px + (pill_w - lw) / 2, strip_y + 2)
    end
    if n_pills == 0 then
        Theme.setColor(Theme.fg.faint)
        love.graphics.setFont(fonts.ui_small)
        love.graphics.print("waiting for first hand…", strip_x, strip_y + 2)
    end

    -- Live stat line.
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    if stats then
        local stat_text = string.format(
            "win %s  ·  pot %s  ·  %d/min",
            Format.percent(stats.win_rate, 1),
            moneyText(stats.pot_size),
            math.floor(stats.hands_per_min + 0.5)
        )
        love.graphics.print(stat_text, x + 12, strip_y + PILL_H + 8)
    end

    -- Stake-up button (bottom). Only when next stake exists AND is affordable.
    local next_stake = self:_nextStakeAvailable(t)
    if next_stake then
        local btn_x = x + STAKE_UP_BTN_PAD
        local btn_y = y + h - STAKE_UP_BTN_H - STAKE_UP_BTN_PAD
        local btn_w = w - 2 * STAKE_UP_BTN_PAD
        Theme.setColor(Theme.bg.widget_hover)
        love.graphics.rectangle("fill", btn_x, btn_y, btn_w, STAKE_UP_BTN_H, Theme.space.radius)
        Theme.setColor(Theme.border.strong)
        love.graphics.rectangle("line", btn_x, btn_y, btn_w, STAKE_UP_BTN_H, Theme.space.radius)
        Theme.setColor(Theme.fg.heading)
        love.graphics.setFont(fonts.ui)
        love.graphics.printf("UP -> " .. next_stake.display_name,
            btn_x, btn_y + 5, btn_w, "center")
        self.hit_boxes[#self.hit_boxes + 1] = {
            x = btn_x, y = btn_y, w = btn_w, h = STAKE_UP_BTN_H,
            action = "stake_up", idx = idx, next_stake_id = next_stake.id,
        }
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
    local can_shove = self.game.state.bankroll >= Constants.GAMEPLAY.SHOVE_MIN_BANKROLL
    local ctx = self.controller.ctx or {}
    local rate = math.min(Constants.GAMEPLAY.SHOVE_RATE_CAP, ctx.shove_rate or 0)

    Theme.setColor(can_shove and Theme.status.error or Theme.bg.sunken, can_shove and 0.85 or 0.4)
    love.graphics.rectangle("fill", sb.x, sb.y, sb.w, sb.h, Theme.space.radius)
    Theme.setColor(can_shove and Theme.status.error or Theme.border.soft)
    love.graphics.setLineWidth(Theme.space.line_strong)
    love.graphics.rectangle("line", sb.x, sb.y, sb.w, sb.h, Theme.space.radius)
    love.graphics.setLineWidth(1)

    Theme.setColor(can_shove and Theme.fg.heading or Theme.fg.disabled)
    love.graphics.setFont(self.game.fonts.heading)
    love.graphics.printf("SHOVE", sb.x, sb.y + 8, sb.w, "center")

    Theme.setColor(can_shove and Theme.fg.primary or Theme.fg.faint)
    love.graphics.setFont(self.game.fonts.ui_small)
    love.graphics.printf(string.format("%.1f%% per runout", rate * 100),
        sb.x, sb.y + 36, sb.w, "center")
end

-- ─── Floating text overlay ────────────────────────────────────────────

function GrindView:_drawFloatingText()
    local fonts = self.game.fonts
    love.graphics.setFont(fonts.heading)
    for _, t in ipairs(self.game.floating_text.getTexts()) do
        local color = (t.text:sub(1, 1) == "+") and Theme.status.good or Theme.status.error
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
end

-- ─── Mouse routing ────────────────────────────────────────────────────

function GrindView:mousepressed(x, y, b)
    if b ~= 1 then return end

    -- SHOVE button has priority — it's bottom-right and overlaps the right panel zone.
    local sb = self:_shoveButtonRect()
    if x >= sb.x and x < sb.x + sb.w and y >= sb.y and y < sb.y + sb.h then
        if self.game.state.bankroll >= Constants.GAMEPLAY.SHOVE_MIN_BANKROLL then
            self.game.state_machine:switch("shove")
        end
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
    local stake_id = id:match("^add_table_(.+)$")
    if stake_id then
        self.controller:addTable(stake_id)
        return
    end
    local up_id = id:match("^buy_runup_(.+)$")
    if up_id then
        self.controller:buyRunUpgrade(up_id)
        return
    end
end

function GrindView:_handleHitBox(hb)
    if hb.action == "remove_table" then
        self.controller:removeTable(hb.idx)
    elseif hb.action == "stake_up" then
        self.controller:changeTableStake(hb.idx, hb.next_stake_id)
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

return GrindView
