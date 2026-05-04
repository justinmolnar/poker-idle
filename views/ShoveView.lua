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

local Theme          = require("views.Theme")
local HandEval       = require("models.HandEval")
local Constants      = require("data.constants")
local SpriteRenderer = require("services.SpriteRenderer")

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

-- Target slot 1's left edge so the currently-visible pack of cards is
-- centered horizontally on screen. n is 5, 6, or 7 depending on how
-- many cheats have been earned.
local function packOriginFor(n_slots, screen_w)
    local pack_w = n_slots * CARD_W + (n_slots - 1) * CARD_GAP
    return math.floor((screen_w - pack_w) / 2)
end

-- How many slots the visible pack should currently center on, given
-- which runout chips have flipped (and whether those runouts won — a
-- losing R1 doesn't trigger a 6th-card shift).
local function visiblePackSize(view, result)
    local n = 5
    if view.chip_visible[1] and result and result.outcomes[1] == true then n = 6 end
    if view.chip_visible[2] and result and result.outcomes[2] == true then n = 7 end
    return n
end

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
        -- Animated board-pack origin (slot 1's left edge). The pack of
        -- visible cards stays centered on screen at every step: 5 cards
        -- centered → slide left to re-center for 6 → slide left again
        -- for 7. nil means "uninitialised; snap to target on first
        -- update". Lerped toward `board_x_target` each frame.
        board_x         = nil,
        board_x_target  = nil,
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
    -- Snap the board origin back to the 5-centered baseline on the
    -- next update so a fresh shove always starts visually centered.
    self.board_x        = nil
    self.board_x_target = nil
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
    -- Snap the board origin to the final pack size so a fast-forwarded
    -- reveal doesn't get caught mid-slide.
    local result = self.ss.gauntlet and self.ss.gauntlet.result
    local n      = visiblePackSize(self, result)
    self.board_x_target = packOriginFor(n, love.graphics.getWidth())
    self.board_x        = self.board_x_target
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

    -- Animate the board-pack origin so the pack stays centered as new
    -- slots appear. Target is computed each frame from chip state. On
    -- first call we snap (board_x == nil) so the initial render is
    -- already centered; subsequent retargets lerp over ~0.5 s. The
    -- shift fires when the runout chip flips — i.e. during the
    -- RUNOUT_PAUSE + CHEAT_PAUSE window before the cheat card slides
    -- in — so the slide finishes before the new card lands.
    local W      = love.graphics.getWidth()
    local result = self.ss.gauntlet and self.ss.gauntlet.result
    local n      = visiblePackSize(self, result)
    self.board_x_target = packOriginFor(n, W)
    if self.board_x == nil then
        self.board_x = self.board_x_target
    else
        local k = math.min(1, dt * 6)
        self.board_x = self.board_x + (self.board_x_target - self.board_x) * k
        if math.abs(self.board_x_target - self.board_x) < 0.5 then
            self.board_x = self.board_x_target
        end
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
    SpriteRenderer.draw(sl, sprite_name, actual_x, y, effective_w, h, { 1, 1, 1, alpha })
end

local function visibleBoardCount(g)
    if not g or not g.result then return 0 end
    local r = g.result
    if r.outcomes[2] == nil then return 5 end
    if r.outcomes[3] == nil then return 6 end
    return 7
end

-- Banner is reveal-aware: while the runouts are still being walked, we
-- show a neutral "ALL-IN" so g.result (which is pre-baked the moment the
-- player presses SPACE) doesn't leak the outcome through banner text.
-- Result text only appears once the terminal runout chip has flipped.
local function bannerFor(g, view)
    if not g or not g.result then return "PRESS SPACE TO SHOVE" end
    local r = g.result
    local revealed = view and view:_revealedRunoutIdx() or 0
    local terminal_idx = r.won and 3 or (r.busted_at or 0)
    if revealed < terminal_idx then return "ALL-IN" end
    if r.won then return "GAUNTLET CLEARED" end
    return "BUSTED"
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

    -- Atmospheric backdrop: pitch-black base, a deep felt band centered
    -- on the board so the cards land "on a table" rather than floating
    -- in a black void, plus a soft spotlight halo above it. No textures
    -- or shaders — just stacked rectangles with alpha falloff. Cheap,
    -- but turns the empty void into a casino room.
    Theme.setColor(Theme.bg.window)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Felt band — runs horizontally across the full width behind the
    -- board area. Color is a deep desaturated green; deliberately not
    -- the bright grind-table green so the gauntlet still reads as
    -- "different / serious" tonally.
    local FELT_R, FELT_G, FELT_B = 0.045, 0.075, 0.060
    local felt_top    = Y_DEALER_HOLE - 40
    local felt_height = (Y_PLAYER_HOLE + CARD_H + 40) - felt_top

    -- Soft top fade → felt → soft bottom fade. Three rectangles, each
    -- with alpha scaled, give a gradient without needing meshes/shaders.
    love.graphics.setColor(FELT_R, FELT_G, FELT_B, 0.25)
    love.graphics.rectangle("fill", 0, felt_top - 60, W, 60)
    love.graphics.setColor(FELT_R, FELT_G, FELT_B, 1.00)
    love.graphics.rectangle("fill", 0, felt_top, W, felt_height)
    love.graphics.setColor(FELT_R, FELT_G, FELT_B, 0.25)
    love.graphics.rectangle("fill", 0, felt_top + felt_height, W, 60)

    -- Thin gold rule above and below the felt band — suggests the rim
    -- of a table without committing to a full elliptical felt sprite.
    love.graphics.setColor(0.45, 0.35, 0.18, 0.70)
    love.graphics.rectangle("fill", 0, felt_top - 1, W, 1)
    love.graphics.rectangle("fill", 0, felt_top + felt_height, W, 1)

    -- Centered spotlight glow over the board area — adds the "this is
    -- the moment" focus. Painted as concentric rounded rects with
    -- decreasing alpha. Wider than the felt band so it bleeds slightly
    -- past the edges.
    local spot_cy = (felt_top + felt_height * 0.5)
    for i = 1, 6 do
        local frac  = i / 6
        local alpha = 0.06 * (1 - frac)
        local rw    = W * 0.55 * frac + 200
        local rh    = felt_height * 0.50 * frac + 60
        love.graphics.setColor(1.0, 0.95, 0.80, alpha)
        love.graphics.rectangle("fill",
            (W - rw) * 0.5, spot_cy - rh * 0.5,
            rw, rh, Theme.space.radius * 4)
    end

    love.graphics.setFont(self.fonts.eyebrow)
    Theme.setColor(Theme.status.error)
    love.graphics.print("SHOVE", 16, 12)

    local g = self.ss.gauntlet
    local result = g and g.result or nil

    love.graphics.setFont(self.fonts.heading)
    Theme.setColor(Theme.fg.heading)
    printCentered(bannerFor(g, self), self.fonts.heading, 0, 40, W)

    local n_board         = visibleBoardCount(g)
    local n_slots_visible = visiblePackSize(self, result)
    -- Pack origin is animated by :update so the visible pack of cards
    -- stays centered at every step. Default to the snapped 5-centered
    -- position if update hasn't run yet (first frame edge case).
    local board_x = self.board_x or packOriginFor(n_slots_visible, W)

    -- Board placeholder slots — only as many as are currently in play.
    -- Centered on the same 7-slot anchor so cards 1..5 sit where the
    -- player expects a normal NLHE board.
    Theme.setColor(Theme.bg.sunken)
    for i = 1, n_slots_visible do
        local x = board_x + (i - 1) * (CARD_W + CARD_GAP)
        love.graphics.rectangle("fill", x, Y_BOARD, CARD_W, CARD_H, Theme.space.radius)
    end

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

    -- Runout result chips — only render the ones that have actually
    -- been revealed. Pre-revealed grey chips spoiled the structure (the
    -- player could count "ah, three runouts coming" before any cards
    -- landed). Now each chip pops in as it's earned. Chips stay anchored
    -- to their original positions so they fill in left-to-right without
    -- the layout shifting around.
    local chip_w, chip_h = 92, 32
    local total_chip_w = 3 * chip_w + 2 * CARD_GAP
    local chip_x0 = math.floor((W - total_chip_w) / 2)
    love.graphics.setFont(self.fonts.ui)
    for i = 1, 3 do
        if self.chip_visible[i] then
            local x = chip_x0 + (i - 1) * (chip_w + CARD_GAP)
            local outcome = result and result.outcomes[i]
            local label, color
            if outcome == true then
                label, color = "WIN",  Theme.status.good
            else
                label, color = "LOSS", Theme.status.error
            end
            Theme.setColor(Theme.bg.widget)
            love.graphics.rectangle("fill", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
            Theme.setColor(color)
            love.graphics.rectangle("line", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
            printCentered(label, self.fonts.ui, x, Y_CHIPS + 9, chip_w)
        end
    end
end

return ShoveView
