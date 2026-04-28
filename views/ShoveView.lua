-- views/ShoveView.lua
--
-- The shove screen. Reads the active Gauntlet off the ShoveState (passed
-- as `ss` at construction) and renders, in order:
--
--   • runout banner       — "RUNOUT N" / "DEALER ADDS A CARD" / final result
--   • board cards         — 5 community cards, plus 1 cheat card per
--                           runout 2/3 that played, laid out left to right
--   • board hand label    — best 5-card hand made from the board alone
--   • hole cards          — 2 cards centered below the board
--   • hole hand label     — best 5-card hand made from hole + current board
--   • runout result chips — WIN / LOSS / — for each of the three runouts
--
-- Phase C: everything renders statically (no per-card animation, no
-- face-down → face-up flip). The cinematic deal lands in Phase D by
-- gating each card's render on a per-card reveal timer driven from the
-- gauntlet's event publishes.

local Theme    = require("views.Theme")
local HandEval = require("utils.hand_eval")

local ShoveView = {}
ShoveView.__index = ShoveView

-- Card sprite sizing. 2.5:3.5 ratio scaled to fit roughly 7 cards across
-- the centerline with comfortable gaps.
local CARD_W = 96
local CARD_H = math.floor(CARD_W * 3.5 / 2.5)
local CARD_GAP = 12

function ShoveView:new(game, ss)
    local self = setmetatable({
        game = game,
        ss   = ss,
    }, ShoveView)
    self.fonts = nil
    return self
end

function ShoveView:_ensureFonts()
    if self.fonts then return end
    self.fonts = {
        eyebrow = love.graphics.newFont(Theme.font.size_ui_small),
        ui      = love.graphics.newFont(Theme.font.size_ui),
        heading = love.graphics.newFont(Theme.font.size_heading),
        kpi     = love.graphics.newFont(Theme.font.size_kpi),
    }
end

function ShoveView:update(_) end

local function printCentered(text, font, x, y, w)
    local tw = font:getWidth(text)
    love.graphics.print(text, math.floor(x + (w - tw) / 2), y)
end

-- How many board cards should be visible right now. The gauntlet's full
-- board grows up to 7; a runout that wasn't reached should not display.
local function visibleBoardCount(g)
    if not g or not g.result then return 0 end
    local r = g.result
    if r.outcomes[2] == nil then return 5 end   -- bust on R1, only 5 board cards dealt
    if r.outcomes[3] == nil then return 6 end   -- bust on R2, 6 dealt
    return 7
end

-- Banner text reflects how far the gauntlet got.
local function bannerFor(g)
    if not g or not g.result then return "PRESS SPACE TO SHOVE" end
    local r = g.result
    if r.won then return "GAUNTLET CLEARED" end
    return "BUSTED ON RUNOUT " .. tostring(r.busted_at or 0)
end

function ShoveView:draw()
    self:_ensureFonts()

    local W, H = love.graphics.getDimensions()

    -- Background.
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Eyebrow.
    love.graphics.setFont(self.fonts.eyebrow)
    Theme.setColor(Theme.status.error)
    love.graphics.print("SHOVE", 16, 12)

    local g = self.ss.gauntlet
    local result = g and g.result or nil

    -- Banner.
    love.graphics.setFont(self.fonts.heading)
    Theme.setColor(Theme.fg.heading)
    printCentered(bannerFor(g), self.fonts.heading, 0, 64, W)

    -- Layout anchors.
    local n_board = visibleBoardCount(g)
    local board_y = 130
    local board_w = math.max(5, n_board) * CARD_W + math.max(4, n_board - 1) * CARD_GAP
    local board_x = math.floor((W - board_w) / 2)

    -- Board placeholder slots (drawn under the cards so empty seats are visible).
    Theme.setColor(Theme.bg.sunken)
    for i = 1, 7 do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        love.graphics.rectangle("fill", x, board_y, CARD_W, CARD_H, Theme.space.radius)
    end

    -- Cheat-card slot indicators (6 and 7 get a thin red outline so the
    -- player can clock them as the dealer's additions even before they fill).
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong)
    for i = 6, 7 do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        love.graphics.rectangle("line", x, board_y, CARD_W, CARD_H, Theme.space.radius)
    end
    love.graphics.setLineWidth(1)

    -- Board cards (front-facing).
    if result then
        for i = 1, n_board do
            local card = result.board[i]
            if card then
                local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
                self.game.sprite_loader:drawSprite(card:spriteName(), x, board_y, CARD_W, CARD_H)
            end
        end
    end

    -- Board hand label (using the latest runout's board eval).
    local board_label_y = board_y + CARD_H + 14
    if result then
        local idx = math.min(n_board - 4, 3)  -- 5→1, 6→2, 7→3
        local eval = result.evals[idx]
        if eval then
            love.graphics.setFont(self.fonts.ui)
            Theme.setColor(Theme.fg.muted)
            printCentered("board: " .. HandEval.describe(eval.board_rank),
                self.fonts.ui, 0, board_label_y, W)
        end
    end

    -- Hole cards.
    local hole_y = board_y + CARD_H + 64
    local hole_w = 2 * CARD_W + CARD_GAP
    local hole_x = math.floor((W - hole_w) / 2)
    Theme.setColor(Theme.bg.sunken)
    for i = 0, 1 do
        love.graphics.rectangle("fill", hole_x + i * (CARD_W + CARD_GAP), hole_y, CARD_W, CARD_H, Theme.space.radius)
    end
    if result then
        for i, card in ipairs(result.hole) do
            local x = hole_x + (i - 1) * (CARD_W + CARD_GAP)
            self.game.sprite_loader:drawSprite(card:spriteName(), x, hole_y, CARD_W, CARD_H)
        end
    end

    -- Hole hand label (player's best 5 of hole + current board).
    if result then
        local idx = math.min(n_board - 4, 3)
        local eval = result.evals[idx]
        if eval then
            love.graphics.setFont(self.fonts.heading)
            Theme.setColor(Theme.fg.heading)
            printCentered(HandEval.describe(eval.player_rank),
                self.fonts.heading, 0, hole_y + CARD_H + 12, W)
        end
    end

    -- Runout chips (WIN / LOSS / —).
    local chip_y = hole_y + CARD_H + 56
    local chip_w, chip_h = 92, 32
    local total_chip_w = 3 * chip_w + 2 * CARD_GAP
    local chip_x0 = math.floor((W - total_chip_w) / 2)
    love.graphics.setFont(self.fonts.ui)
    for i = 1, 3 do
        local x = chip_x0 + (i - 1) * (chip_w + CARD_GAP)
        local outcome = result and result.outcomes[i]
        local label, color
        if outcome == true then
            label, color = "R" .. i .. "  WIN",  Theme.status.good
        elseif outcome == false then
            label, color = "R" .. i .. "  LOSS", Theme.status.error
        else
            label, color = "R" .. i,             Theme.fg.faint
        end
        Theme.setColor(Theme.bg.widget)
        love.graphics.rectangle("fill", x, chip_y, chip_w, chip_h, Theme.space.radius)
        Theme.setColor(color)
        love.graphics.rectangle("line", x, chip_y, chip_w, chip_h, Theme.space.radius)
        printCentered(label, self.fonts.ui, x, chip_y + 9, chip_w)
    end
end

return ShoveView
