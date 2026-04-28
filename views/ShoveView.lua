-- views/ShoveView.lua
--
-- The shove screen. Reads the active Gauntlet off the ShoveState (passed
-- as `ss` at construction) and renders the heads-up showdown:
--
--   • dealer hole cards (top, face-down → flipped face-up at showdown)
--   • banner          (state-of-play / final result text)
--   • community board (3 + 1 + 1 NLHE pacing for the flop / turn / river,
--                      then 1 + 1 cheat cards on R2 / R3 with the slow
--                      `cheat_card_dealt` curve for emphasis)
--   • player hole cards (bottom, face-down → flipped face-up at showdown)
--   • per-side hand label  ("dealer: pair of Aces", "player: trip 7s")
--   • runout result chips  (R1 / R2 / R3 → WIN / LOSS / —)
--   • best-5 highlighting  (after each reveal lands, the 5 cards making
--                           the player's best hand get a green border;
--                           the dealer's get a red border just outside)
--
-- Timeline: hole cards deal face-down on shove (player first, then dealer,
-- staggered) → simultaneous flip face-up (showdown moment) → flop (3
-- cards in quick succession) → turn (single, with pause) → river (single,
-- with pause) → R1 chip + hand labels → if R1 won, suspense pause then the
-- 6th community card (cheat) → R2 chip → if R2 won, same for the 7th →
-- R3 chip. SPACE during animation calls :skip() to fast-forward.

local Theme     = require("views.Theme")
local HandEval  = require("utils.hand_eval")
local Constants = require("data.constants")

local ShoveView = {}
ShoveView.__index = ShoveView

local CARD_W = 88
local CARD_H = math.floor(CARD_W * 3.5 / 2.5)
local CARD_GAP = 12

-- Vertical layout anchors.
local Y_DEALER_HOLE  = 80
local Y_DEALER_LABEL = Y_DEALER_HOLE + CARD_H + 8
local Y_BOARD        = Y_DEALER_LABEL + 22
local Y_PLAYER_LABEL = Y_BOARD + CARD_H + 8
local Y_PLAYER_HOLE  = Y_PLAYER_LABEL + 22
local Y_CHIPS        = Y_PLAYER_HOLE + CARD_H + 18

function ShoveView:new(game, ss)
    local self = setmetatable({
        game            = game,
        ss              = ss,
        elapsed         = 0,
        timeline        = nil,
        next_event_idx  = 1,
        total_duration  = 0,
        card_anims      = {},
        chip_visible    = { false, false, false },
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

-- ─── Timeline construction ─────────────────────────────────────────────

function ShoveView:onGauntletBegin()
    local g = self.ss.gauntlet
    if not g or not g.result then return end

    self.elapsed        = 0
    self.next_event_idx = 1
    self.card_anims     = {}
    self.chip_visible   = { false, false, false }
    self.timeline       = {}

    local r     = g.result
    local anims = self.game.animations

    local DEAL_INTERVAL = Constants.GAUNTLET.CARD_DEAL_INTERVAL
    local RUNOUT_PAUSE  = Constants.GAUNTLET.RUNOUT_PAUSE
    local CHEAT_PAUSE   = Constants.GAUNTLET.CHEAT_REVEAL_PAUSE

    local function startAnim(key, preset)
        return function()
            self.card_anims[key] = anims:create(preset, {})
            self.card_anims[key]:start()
        end
    end

    local function showChip(i)
        return function() self.chip_visible[i] = true end
    end

    -- Each timeline event has fire (state mutation, always run) and an
    -- optional sound (skipped on fast-forward to avoid an audio flood).
    local function add(at, fn, sound)
        self.timeline[#self.timeline + 1] = { at = at, fire = fn, sound = sound }
    end

    -- Pick the right resolution sound for runout i: gauntlet-final win/loss
    -- supersedes the per-runout chime so the moment lands.
    local function chipSound(i)
        local out = r.outcomes[i]
        if out == false then return "gauntlet_lost" end       -- any bust ends the gauntlet
        if i == 3   and out then return "gauntlet_won" end    -- full clear
        return "runout_won"                                   -- R1/R2 win, more to come
    end

    local t = 0

    -- Shove kickoff sound (deck shuffle) at t=0.
    add(t, function() end, "shove_initiated")

    -- Deal four hole cards face-down (player first, then dealer, staggered).
    add(t,        startAnim("ph_1", "card_deal_slide"), "card_dealt")
    add(t + 0.08, startAnim("ph_2", "card_deal_slide"), "card_dealt")
    add(t + 0.20, startAnim("dh_1", "card_deal_slide"), "card_dealt")
    add(t + 0.28, startAnim("dh_2", "card_deal_slide"), "card_dealt")
    t = t + 0.65

    -- Showdown — all four hole cards flip together.
    add(t, startAnim("hole_flip", "hole_card_flip"), "hole_card_flip")
    t = t + 0.55

    -- Flop: 3 cards in quick succession.
    add(t,                     startAnim("board_1", "card_deal_slide"), "card_dealt")
    add(t + DEAL_INTERVAL,     startAnim("board_2", "card_deal_slide"), "card_dealt")
    add(t + 2 * DEAL_INTERVAL, startAnim("board_3", "card_deal_slide"), "card_dealt")
    t = t + 2 * DEAL_INTERVAL + 0.40

    -- Turn.
    t = t + 0.50
    add(t, startAnim("board_4", "card_deal_slide"), "card_dealt")
    t = t + 0.40

    -- River.
    t = t + 0.50
    add(t, startAnim("board_5", "card_deal_slide"), "card_dealt")
    t = t + 0.45

    -- R1 resolution.
    add(t, showChip(1), chipSound(1))

    if r.outcomes[1] then
        t = t + RUNOUT_PAUSE + CHEAT_PAUSE
        add(t, startAnim("board_6", "cheat_card_dealt"), "cheat_card_dealt")
        t = t + 0.75

        add(t, showChip(2), chipSound(2))

        if r.outcomes[2] then
            t = t + RUNOUT_PAUSE + CHEAT_PAUSE
            add(t, startAnim("board_7", "cheat_card_dealt"), "cheat_card_dealt")
            t = t + 0.75

            add(t, showChip(3), chipSound(3))
        end
    end

    self.total_duration = t + 0.5
end

function ShoveView:isAnimating()
    return self.timeline ~= nil and self.elapsed < self.total_duration
end

function ShoveView:resetTimeline()
    self.timeline       = nil
    self.next_event_idx = 1
    self.elapsed        = 0
    self.total_duration = 0
    self.card_anims     = {}
    self.chip_visible   = { false, false, false }
end

function ShoveView:skip()
    if not self.timeline then return end
    -- Fire all remaining events but suppress sounds — otherwise mashing
    -- SPACE during a multi-runout reveal triggers a stack of chimes.
    while self.next_event_idx <= #self.timeline do
        self.timeline[self.next_event_idx].fire()
        self.next_event_idx = self.next_event_idx + 1
    end
    for _, anim in pairs(self.card_anims) do
        if anim.update then anim:update(10) end
    end
    self.elapsed = self.total_duration
end

function ShoveView:update(dt)
    if not self.timeline then return end
    self.elapsed = self.elapsed + dt

    while self.next_event_idx <= #self.timeline do
        local ev = self.timeline[self.next_event_idx]
        if self.elapsed >= ev.at then
            ev.fire()
            if ev.sound then
                self.game.sounds.playNamed(ev.sound)
            end
            self.next_event_idx = self.next_event_idx + 1
        else
            break
        end
    end

    for _, anim in pairs(self.card_anims) do
        if anim.update then anim:update(dt) end
    end
end

-- ─── Drawing helpers ───────────────────────────────────────────────────

local function printCentered(text, font, x, y, w)
    local tw = font:getWidth(text)
    love.graphics.print(text, math.floor(x + (w - tw) / 2), y)
end

local function drawCardSprite(sl, sprite_name, x, y, w, h, scale_x, alpha)
    scale_x = scale_x or 1
    alpha   = alpha   or 1
    local effective_w = w * scale_x
    local cx = x + w / 2
    local actual_x = cx - effective_w / 2
    sl:drawSprite(sprite_name, actual_x, y, effective_w, h, { 1, 1, 1, alpha })
end

local function visibleBoardCount(g)
    if not g or not g.result then return 0 end
    local r = g.result
    if r.outcomes[2] == nil then return 5 end
    if r.outcomes[3] == nil then return 6 end
    return 7
end

local function bannerFor(g)
    if not g or not g.result then return "PRESS SPACE TO SHOVE" end
    local r = g.result
    if r.won then return "GAUNTLET CLEARED" end
    return "BUSTED ON RUNOUT " .. tostring(r.busted_at or 0)
end

local function isInCombo(card, combo)
    if not combo then return false end
    for _, c in ipairs(combo) do
        if c == card then return true end
    end
    return false
end

-- After a runout's reveal has fully landed, we can show the best-5
-- highlighting and the hand labels. Definition of "fully landed":
--   • runout's chip is visible AND
--   • the latest visible card's deal animation has completed (alpha = 1)
function ShoveView:_revealedRunoutIdx()
    local idx
    if self.chip_visible[3] then idx = 3
    elseif self.chip_visible[2] then idx = 2
    elseif self.chip_visible[1] then idx = 1
    else return 0 end
    -- Also gate on hole flip having completed. Without the flip we can't
    -- show face-up cards, so highlights/labels aren't meaningful yet.
    local flip = self.card_anims.hole_flip
    if not flip or (flip.getProgress and flip:getProgress() < 1) then return 0 end
    return idx
end

function ShoveView:_drawHoleCard(card, slot_x, slot_y, deal_key)
    local sl = self.game.sprite_loader
    local back = Constants.GAUNTLET.CARD_BACK_SPRITE
    local front = card:spriteName()
    local deal_anim = self.card_anims[deal_key]
    local flip_anim = self.card_anims.hole_flip

    if not deal_anim then return end

    local deal_alpha = deal_anim.getAlpha and deal_anim:getAlpha() or 1

    if not flip_anim then
        drawCardSprite(sl, back, slot_x, slot_y, CARD_W, CARD_H, 1, deal_alpha)
        return
    end

    local p = flip_anim.getProgress and flip_anim:getProgress() or 0
    if p < 0.5 then
        local sx = 1 - 2 * p
        drawCardSprite(sl, back, slot_x, slot_y, CARD_W, CARD_H, sx, deal_alpha)
    else
        local sx = 2 * p - 1
        drawCardSprite(sl, front, slot_x, slot_y, CARD_W, CARD_H, sx, deal_alpha)
    end
end

function ShoveView:_drawBoardCard(i, x, y)
    local sl = self.game.sprite_loader
    local result = self.ss.gauntlet and self.ss.gauntlet.result
    if not result then return end

    local card = result.board[i]
    if not card then return end

    local anim = self.card_anims["board_" .. i]
    if not anim then return end

    local alpha = anim.getAlpha and anim:getAlpha() or 1
    drawCardSprite(sl, card:spriteName(), x, y, CARD_W, CARD_H, 1, alpha)
end

-- Outline a card slot with a stroke. inset > 0 draws inside the card,
-- inset < 0 draws outside. Used for the player/dealer best-5 highlights.
local function strokeSlot(x, y, w, h, inset, lw)
    love.graphics.setLineWidth(lw)
    love.graphics.rectangle("line", x + inset, y + inset, w - 2 * inset, h - 2 * inset, Theme.space.radius)
    love.graphics.setLineWidth(1)
end

function ShoveView:draw()
    self:_ensureFonts()

    local W, H = love.graphics.getDimensions()

    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    love.graphics.setFont(self.fonts.eyebrow)
    Theme.setColor(Theme.status.error)
    love.graphics.print("SHOVE", 16, 12)

    local g = self.ss.gauntlet
    local result = g and g.result or nil

    love.graphics.setFont(self.fonts.heading)
    Theme.setColor(Theme.fg.heading)
    printCentered(bannerFor(g), self.fonts.heading, 0, 40, W)

    local n_board = visibleBoardCount(g)
    local board_w = 7 * CARD_W + 6 * CARD_GAP
    local board_x = math.floor((W - board_w) / 2)

    -- Board placeholder slots.
    Theme.setColor(Theme.bg.sunken)
    for i = 1, 7 do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        love.graphics.rectangle("fill", x, Y_BOARD, CARD_W, CARD_H, Theme.space.radius)
    end

    -- Cheat-card slot indicators (positions 6 and 7).
    Theme.setColor(Theme.border.strong)
    love.graphics.setLineWidth(Theme.space.line_strong)
    for i = 6, 7 do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        love.graphics.rectangle("line", x, Y_BOARD, CARD_W, CARD_H, Theme.space.radius)
    end
    love.graphics.setLineWidth(1)

    -- Board cards.
    for i = 1, n_board do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        self:_drawBoardCard(i, x, Y_BOARD)
    end

    -- Hole card slots (player + dealer placeholder rectangles).
    local hole_w = 2 * CARD_W + CARD_GAP
    local hole_x = math.floor((W - hole_w) / 2)
    Theme.setColor(Theme.bg.sunken)
    for i = 0, 1 do
        local x = hole_x + i * (CARD_W + CARD_GAP)
        love.graphics.rectangle("fill", x, Y_DEALER_HOLE, CARD_W, CARD_H, Theme.space.radius)
        love.graphics.rectangle("fill", x, Y_PLAYER_HOLE, CARD_W, CARD_H, Theme.space.radius)
    end

    -- Hole cards (face-down → flipped at showdown moment).
    if result then
        self:_drawHoleCard(result.player_hole[1], hole_x,                     Y_PLAYER_HOLE, "ph_1")
        self:_drawHoleCard(result.player_hole[2], hole_x + CARD_W + CARD_GAP, Y_PLAYER_HOLE, "ph_2")
        self:_drawHoleCard(result.dealer_hole[1], hole_x,                     Y_DEALER_HOLE, "dh_1")
        self:_drawHoleCard(result.dealer_hole[2], hole_x + CARD_W + CARD_GAP, Y_DEALER_HOLE, "dh_2")
    end

    -- Best-5 highlights (post-reveal).
    local revealed_idx = self:_revealedRunoutIdx()
    if result and revealed_idx > 0 then
        local eval = result.evals[revealed_idx]
        if eval then
            -- Player's best 5 → green inset border.
            -- Dealer's best 5 → red outset border.
            local function outline(x, y, color, inset, lw)
                Theme.setColor(color, 0.95)
                strokeSlot(x, y, CARD_W, CARD_H, inset, lw)
            end

            -- Player hole cards.
            if isInCombo(result.player_hole[1], eval.player_combo) then
                outline(hole_x, Y_PLAYER_HOLE, Theme.status.good, 2, 3)
            end
            if isInCombo(result.player_hole[2], eval.player_combo) then
                outline(hole_x + CARD_W + CARD_GAP, Y_PLAYER_HOLE, Theme.status.good, 2, 3)
            end

            -- Dealer hole cards (their own combo).
            if isInCombo(result.dealer_hole[1], eval.dealer_combo) then
                outline(hole_x, Y_DEALER_HOLE, Theme.status.error, 2, 3)
            end
            if isInCombo(result.dealer_hole[2], eval.dealer_combo) then
                outline(hole_x + CARD_W + CARD_GAP, Y_DEALER_HOLE, Theme.status.error, 2, 3)
            end

            -- Board cards (could be in player_combo, dealer_combo, or both).
            for i = 1, n_board do
                local card = result.board[i]
                local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
                if isInCombo(card, eval.player_combo) then
                    outline(x, Y_BOARD, Theme.status.good, 2, 3)
                end
                if isInCombo(card, eval.dealer_combo) then
                    outline(x, Y_BOARD, Theme.status.error, -3, 3)
                end
            end
        end
    end

    -- Hand labels (dealer above board, player below board).
    if result and revealed_idx > 0 then
        local eval = result.evals[revealed_idx]
        if eval then
            love.graphics.setFont(self.fonts.ui)
            Theme.setColor(Theme.status.error)
            printCentered("dealer: " .. HandEval.describe(eval.dealer_rank),
                self.fonts.ui, 0, Y_DEALER_LABEL, W)
            Theme.setColor(Theme.status.good)
            printCentered("player: " .. HandEval.describe(eval.player_rank),
                self.fonts.ui, 0, Y_PLAYER_LABEL, W)
        end
    end

    -- Runout chips.
    local chip_w, chip_h = 92, 32
    local total_chip_w = 3 * chip_w + 2 * CARD_GAP
    local chip_x0 = math.floor((W - total_chip_w) / 2)
    love.graphics.setFont(self.fonts.ui)
    for i = 1, 3 do
        local x = chip_x0 + (i - 1) * (chip_w + CARD_GAP)
        local outcome = result and result.outcomes[i]
        local revealed = self.chip_visible[i]
        local label, color
        if revealed and outcome == true then
            label, color = "R" .. i .. "  WIN",  Theme.status.good
        elseif revealed and outcome == false then
            label, color = "R" .. i .. "  LOSS", Theme.status.error
        else
            label, color = "R" .. i,             Theme.fg.faint
        end
        Theme.setColor(Theme.bg.widget)
        love.graphics.rectangle("fill", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
        Theme.setColor(color)
        love.graphics.rectangle("line", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
        printCentered(label, self.fonts.ui, x, Y_CHIPS + 9, chip_w)
    end
end

return ShoveView
