-- views/GrindView.lua
--
-- The grind screen. Reads state through `self.game` (DI). The controller
-- handles all mutation; this view only renders + dispatches click intents.
--
-- Phase 2 layout (single table, no sidebars yet):
--   • Top bar (50px) — bankroll, PP, peak-this-run
--   • Center — one table panel, centered
--   • Floating text — `+$X` / `-$Y` over the table on each hand resolution
-- Phase 3 will add the left sidebar (stake-add buttons + slot counter) and
-- the 2×3 grid layout for up to MAX_TABLES tables.
-- Phase 4 will add the right sidebar (run upgrades + SHOVE button) using
-- the lifted Panel + ComponentRenderer infrastructure.

local Theme  = require("views.Theme")
local Format = require("utils.format")

local GrindView = {}
GrindView.__index = GrindView

local TOP_BAR_H   = 50
local TABLE_W     = 300
local TABLE_H     = 180
local PILL_W      = 52
local PILL_H      = 22
local PILL_GAP    = 4

function GrindView:new(game, controller)
    return setmetatable({
        game       = game,
        controller = controller,
    }, GrindView)
end

function GrindView:update(_)
    -- View is stateless for now. The controller drives the model tick.
end

-- Format bankroll-style numbers: below $1000 shows precise cents, above
-- falls back to the abbreviated `Format.money` ("$1.2K"). Players need
-- the granular numbers when grinding NL2; abbreviation only matters once
-- they're climbing.
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

-- Center text within a rect using a specific font.
local function printAt(text, font, x, y)
    love.graphics.setFont(font)
    love.graphics.print(text, x, y)
end

-- ─── Top bar ───────────────────────────────────────────────────────────
function GrindView:_drawTopBar(W)
    Theme.setColor(Theme.bg.chrome)
    love.graphics.rectangle("fill", 0, 0, W, TOP_BAR_H)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("fill", 0, TOP_BAR_H - 1, W, 1)

    local fonts = self.game.fonts
    local state = self.game.state

    -- Bankroll (large, left).
    Theme.setColor(Theme.fg.heading)
    love.graphics.setFont(fonts.kpi)
    love.graphics.print(moneyText(state.bankroll), 16, 8)

    -- PP and peak (smaller, right of center).
    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    local pp_label   = "PP"
    local peak_label = "PEAK"
    love.graphics.print(pp_label,   240, 6)
    love.graphics.print(peak_label, 360, 6)

    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(ppText(state.pp),                   240, 22)
    Theme.setColor(Theme.fg.primary)
    love.graphics.print(moneyText(state.peak_bankroll),     360, 22)
end

-- ─── Table panel ──────────────────────────────────────────────────────
function GrindView:_drawTablePanel(t, x, y)
    -- Write screen position back so the controller can spawn floating
    -- text at the right location when this table resolves a hand.
    t.x = x + TABLE_W / 2
    t.y = y + TABLE_H / 2

    Theme.setColor(Theme.bg.widget)
    love.graphics.rectangle("fill", x, y, TABLE_W, TABLE_H, Theme.space.radius)
    Theme.setColor(Theme.border.default)
    love.graphics.rectangle("line", x, y, TABLE_W, TABLE_H, Theme.space.radius)

    local fonts = self.game.fonts
    local stats = t:liveStats(self:_ctx())
    if not stats then return end

    -- Header: stake name + hands count.
    love.graphics.setFont(fonts.heading)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(stats.stake_display, x + 12, y + 10)

    love.graphics.setFont(fonts.ui_small)
    Theme.setColor(Theme.fg.muted)
    local hands_label = string.format("%d hands", t.hands_played)
    local hw = fonts.ui_small:getWidth(hands_label)
    love.graphics.print(hands_label, x + TABLE_W - hw - 12, y + 14)

    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("fill", x + 10, y + 38, TABLE_W - 20, Theme.space.hairline)

    -- Last-N results as colored pills.
    local strip_y = y + 50
    local strip_x = x + 12
    local n = #t.last_results
    for i, r in ipairs(t.last_results) do
        local px = strip_x + (i - 1) * (PILL_W + PILL_GAP)
        Theme.setColor(r.won and Theme.status.good or Theme.status.error, 0.35)
        love.graphics.rectangle("fill", px, strip_y, PILL_W, PILL_H, Theme.space.radius)
        Theme.setColor(r.won and Theme.status.good or Theme.status.error)
        love.graphics.rectangle("line", px, strip_y, PILL_W, PILL_H, Theme.space.radius)

        love.graphics.setFont(fonts.ui_small)
        Theme.setColor(Theme.fg.heading)
        local label = (r.won and "+" or "-") ..
            string.format("%.2f", math.abs(r.delta))
        local lw = fonts.ui_small:getWidth(label)
        love.graphics.print(label, px + (PILL_W - lw) / 2, strip_y + 4)
    end
    if n == 0 then
        Theme.setColor(Theme.fg.faint)
        love.graphics.setFont(fonts.ui_small)
        love.graphics.print("waiting for first hand…", strip_x, strip_y + 4)
    end

    Theme.setColor(Theme.border.soft)
    love.graphics.rectangle("fill", x + 10, y + 84, TABLE_W - 20, Theme.space.hairline)

    -- Live stat line: win rate · pot · pace.
    love.graphics.setFont(fonts.ui)
    Theme.setColor(Theme.fg.muted)
    local stat_text = string.format(
        "win %s  ·  pot %s  ·  %d/min",
        Format.percent(stats.win_rate, 1),
        moneyText(stats.pot_size),
        math.floor(stats.hands_per_min + 0.5)
    )
    love.graphics.print(stat_text, x + 12, y + 96)
end

-- Effects ctx is owned by the controller; pull it lazily through the state.
-- For Phase 2 we go through `effects_cache` set by the controller's
-- invalidateEffects(). Falls back to an empty ctx if not yet computed.
function GrindView:_ctx()
    return self.game.state.effects_cache or {}
end

-- ─── Floating text overlay ─────────────────────────────────────────────
function GrindView:_drawFloatingText()
    local fonts = self.game.fonts
    love.graphics.setFont(fonts.heading)
    for _, t in ipairs(self.game.floating_text.getTexts()) do
        local color = (t.text:sub(1, 1) == "+") and Theme.status.good or Theme.status.error
        Theme.setColor(color, t.alpha or 1)
        love.graphics.print(t.text, t.x - 24, t.y)
    end
end

-- ─── Composite ─────────────────────────────────────────────────────────
function GrindView:draw()
    local W, H = love.graphics.getDimensions()

    -- Background.
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    self:_drawTopBar(W)

    -- Single table centered for Phase 2. Multi-table grid lands in Phase 3.
    local tables = self.controller.pool.tables
    if tables[1] then
        local tx = math.floor((W - TABLE_W) / 2)
        local ty = math.floor((H - TABLE_H) / 2)
        self:_drawTablePanel(tables[1], tx, ty)
    end

    -- Hint (will be replaced by the SHOVE button in Phase 4).
    love.graphics.setFont(self.game.fonts.ui_small)
    Theme.setColor(Theme.fg.faint)
    love.graphics.print("F2 → SHOVE", W - 90, H - 24)

    self:_drawFloatingText()
end

return GrindView
