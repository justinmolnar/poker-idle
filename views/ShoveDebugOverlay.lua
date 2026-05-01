-- views/ShoveDebugOverlay.lua
--
-- Always-on HUD during the shove prototype. Surfaces the live rate struct
-- (r1/r2/r3/clear), the rolling clear-rate vs. the math-expected
-- (r1·r2·r3), per-runout pass counts, last-result summary, and a hotkey
-- legend. The point: the prototype is verifiable end-to-end from the LÖVE
-- window — no console.
--
-- Reads shove_rates from the ShoveState (which owns the debug-controllable
-- struct). Stats live on the overlay itself; they're session-only and
-- reset on D-toggle / Shift+R / state re-entry.

local Theme     = require("views.Theme")
local Constants = require("data.constants")

local Overlay = {}
Overlay.__index = Overlay

function Overlay:new(game, shove_state)
    return setmetatable({
        game        = game,
        ss          = shove_state,
        visible     = Constants.DEBUG.SHOW_DEBUG_OVERLAY,
        attempts    = 0,
        wins        = 0,
        runout_att  = { 0, 0, 0 },
        runout_won  = { 0, 0, 0 },
        natural_failures = 0,        -- how many runouts had their outcome forced by rejection-cap exhaustion
        last_result = nil,
        font_small  = nil,
        font_main   = nil,
        font_big    = nil,
    }, Overlay)
end

function Overlay:_ensureFonts()
    if self.font_main then return end
    self.font_small = love.graphics.newFont(Theme.font.size_ui_small)
    self.font_main  = love.graphics.newFont(Theme.font.size_ui)
    self.font_big   = love.graphics.newFont(Theme.font.size_kpi)
end

function Overlay:recordAttempt(result)
    self.attempts = self.attempts + 1
    if result.won then self.wins = self.wins + 1 end
    -- Runout 1 is always attempted.
    self.runout_att[1] = self.runout_att[1] + 1
    if result.outcomes[1] then
        self.runout_won[1] = self.runout_won[1] + 1
        self.runout_att[2] = self.runout_att[2] + 1
        if result.outcomes[2] then
            self.runout_won[2] = self.runout_won[2] + 1
            self.runout_att[3] = self.runout_att[3] + 1
            if result.outcomes[3] then
                self.runout_won[3] = self.runout_won[3] + 1
            end
        end
    end
    for i = 1, 3 do
        if result.natural[i] == false then
            self.natural_failures = self.natural_failures + 1
        end
    end
    self.last_result = result
end

function Overlay:resetStats()
    self.attempts = 0
    self.wins = 0
    self.runout_att = { 0, 0, 0 }
    self.runout_won = { 0, 0, 0 }
    self.natural_failures = 0
end

local function pct(num, denom)
    if denom == 0 then return "—" end
    return string.format("%.1f%%", 100 * num / denom)
end

function Overlay:draw()
    if not self.visible then return end
    self:_ensureFonts()

    local W, H = love.graphics.getDimensions()
    local pad = Theme.space.popup_pad
    local rowh = Theme.font.size_ui + 4
    local prev_font = love.graphics.getFont()

    -- ── Top-left panel: live state ──────────────────────────────────────
    local lx, ly, lw, lh = 12, 12, 320, 132
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", lx, ly, lw, lh, Theme.space.radius)
    Theme.setColor(Theme.debug.hud_border)
    love.graphics.rectangle("line", lx, ly, lw, lh, Theme.space.radius)

    love.graphics.setFont(self.font_small)
    Theme.setColor(Theme.debug.hud_dim)
    love.graphics.print("LIVE STATE", lx + pad, ly + pad)

    local r = self.ss.shove_rates
    love.graphics.setFont(self.font_big)
    Theme.setColor(Theme.debug.hud_accent)
    love.graphics.print(
        string.format("clear %.2f%%", (r and r.clear or 0) * 100),
        lx + pad, ly + pad + 14)

    love.graphics.setFont(self.font_main)
    Theme.setColor(Theme.debug.hud_dim)
    -- Per-runout breakdown locked in at :enter. R3 is always the wall —
    -- math.md: "The drama lives there at every tier."
    local breakdown_line
    if r then
        breakdown_line = string.format("R1 %.0f%% · R2 %.0f%% · R3 %.0f%%  (cat %.0f%% × %d×)",
            r.r1 * 100, r.r2 * 100, r.r3 * 100, r.catalog * 100, r.mult)
    else
        breakdown_line = "(no breakdown)"
    end
    love.graphics.print(breakdown_line,
        lx + pad, ly + pad + 14 + Theme.font.size_kpi + 2)

    Theme.setColor(Theme.debug.hud_text)
    local g = self.ss.gauntlet
    local g_state = g and g.state or "no gauntlet"
    love.graphics.print("state: " .. g_state,
        lx + pad, ly + lh - rowh * 2 - pad)

    local last_text = "last: —"
    if self.last_result then
        if self.last_result.won then
            last_text = "last: WON gauntlet"
        else
            last_text = "last: LOST runout " .. tostring(self.last_result.busted_at)
        end
    end
    love.graphics.print(last_text, lx + pad, ly + lh - rowh - pad)

    -- ── Top-right panel: aggregate stats ────────────────────────────────
    local rw, rh = 380, 168
    local rx, ry = W - rw - 12, 12
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", rx, ry, rw, rh, Theme.space.radius)
    Theme.setColor(Theme.debug.hud_border)
    love.graphics.rectangle("line", rx, ry, rw, rh, Theme.space.radius)

    love.graphics.setFont(self.font_small)
    Theme.setColor(Theme.debug.hud_dim)
    love.graphics.print("AGGREGATE  (session)", rx + pad, ry + pad)

    love.graphics.setFont(self.font_main)
    local cy = ry + pad + 14
    Theme.setColor(Theme.debug.hud_text)
    love.graphics.print(string.format("attempts: %d", self.attempts), rx + pad, cy); cy = cy + rowh
    love.graphics.print(string.format("wins:     %d", self.wins),     rx + pad, cy); cy = cy + rowh

    Theme.setColor(Theme.debug.hud_accent)
    love.graphics.print(string.format("clear rate: %s", pct(self.wins, self.attempts)),
        rx + pad, cy); cy = cy + rowh
    Theme.setColor(Theme.debug.hud_dim)
    -- Expected = r1*r2*r3 (the "clear" field from the rate struct). Old
    -- model was rate^3 because all three runouts shared one rate; the
    -- gauntlet halving made each runout's rate distinct.
    local expected = (self.ss.shove_rates and self.ss.shove_rates.clear) or 0
    love.graphics.print(string.format("expected:   %.1f%%  (r1·r2·r3)", expected * 100),
        rx + pad, cy); cy = cy + rowh + 4

    Theme.setColor(Theme.debug.hud_text)
    love.graphics.print(
        string.format("R1: %d/%d (%s)   R2: %d/%d (%s)   R3: %d/%d (%s)",
            self.runout_won[1], self.runout_att[1], pct(self.runout_won[1], self.runout_att[1]),
            self.runout_won[2], self.runout_att[2], pct(self.runout_won[2], self.runout_att[2]),
            self.runout_won[3], self.runout_att[3], pct(self.runout_won[3], self.runout_att[3])
        ),
        rx + pad, cy)
    cy = cy + rowh

    if self.natural_failures > 0 then
        Theme.setColor(Theme.debug.hud_warn)
        love.graphics.print(
            string.format("rejection-cap exhausted: %d (cards forced outcome)", self.natural_failures),
            rx + pad, cy)
    end

    -- ── Bottom strip: hotkey legend ─────────────────────────────────────
    local sh = 28
    local sx, sy, sw = 12, H - sh - 12, W - 24
    Theme.setColor(Theme.debug.hud_bg)
    love.graphics.rectangle("fill", sx, sy, sw, sh, Theme.space.radius)
    Theme.setColor(Theme.debug.hud_border)
    love.graphics.rectangle("line", sx, sy, sw, sh, Theme.space.radius)

    love.graphics.setFont(self.font_main)
    local segments = {
        { "SPACE", "begin/advance" },
        { "R",     "reset gauntlet" },
        { "[ / ]", "catalog ±0.05" },
        { "Shift+R", "clear stats" },
        { "D",     "toggle overlay" },
        { "F2",    "toggle grind" },
        { "ESC",   "quit" },
    }
    local x = sx + pad
    local y = sy + (sh - Theme.font.size_ui) / 2 - 1
    for _, seg in ipairs(segments) do
        Theme.setColor(Theme.debug.hud_hot)
        love.graphics.print(seg[1], x, y)
        x = x + self.font_main:getWidth(seg[1]) + 5
        Theme.setColor(Theme.debug.hud_dim)
        love.graphics.print(seg[2], x, y)
        x = x + self.font_main:getWidth(seg[2]) + 18
    end

    if prev_font then love.graphics.setFont(prev_font) end
end

return Overlay
