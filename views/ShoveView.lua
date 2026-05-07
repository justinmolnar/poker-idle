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

local Theme                  = require("views.Theme")
local HandEval               = require("models.HandEval")
local Constants              = require("data.constants")
local SpriteRenderer         = require("services.SpriteRenderer")
local Chips                  = require("views.Chips")
local DenominationBreakdown  = require("services.DenominationBreakdown")
local ChipData               = require("data.chips")

local ShoveView = {}
ShoveView.__index = ShoveView

-- Card sizes / gaps. Recomputed in ShoveView:draw against the live
-- ui_scale so the gauntlet visuals grow with the window.
local CARD_W = 88
local CARD_H = math.floor(CARD_W * 3.5 / 2.5)
local CARD_GAP = 12
local CARD_BASE_W   = 88
local CARD_BASE_GAP = 12

-- Reading order top → bottom: banner ("ALL-IN") → stats line
-- (BASE × MULT = SHOVE%) → POT chip pile → dealer hole → dealer
-- label → community board → player label → player hole → runout
-- result chips. Stats and pot live above the cards so the pile the
-- player just shoved stays the visual focus, with cards landing
-- under it.
local POT_BAND_H = 110

-- Y positions for the gauntlet stack. Initial values are placeholders;
-- recomputeLayout() reassigns them at draw start so the layout
-- responds to ui_scale + the current font heights.
local Y_BANNER      = 40
local Y_STATS       = 80
local Y_POT         = 120
local Y_DEALER_HOLE = 240
local Y_DEALER_LABEL = Y_DEALER_HOLE + CARD_H + 8
local Y_BOARD        = Y_DEALER_LABEL + 22
local Y_PLAYER_LABEL = Y_BOARD + CARD_H + 8
local Y_PLAYER_HOLE  = Y_PLAYER_LABEL + 22
local Y_CHIPS        = Y_PLAYER_HOLE + CARD_H + 18

local function recomputeLayout(H, fonts, s)
    local md_h = (fonts and fonts.md and fonts.md:getHeight()) or 18
    local lg_h = (fonts and fonts.lg and fonts.lg:getHeight()) or 32
    s = s or 1
    -- Vertically center the full stack (banner → result chips) in the
    -- viewport. At small windows this keeps the bottom from clipping;
    -- at large windows the equal top/bottom margin reads as deliberate
    -- framing.
    local gap      = math.floor(8 * s)
    local banner_h = lg_h
    local stats_h  = md_h + gap
    local pot_h    = POT_BAND_H + gap
    local cards_h  = 3 * CARD_H + 8 + 22 + 8 + 22
    local chips_h  = 18 + 36
    local stack_h  = banner_h + stats_h + pot_h + cards_h + chips_h
    local top      = math.max(8, math.floor((H - stack_h) / 2))

    Y_BANNER       = top
    Y_STATS        = Y_BANNER + banner_h + gap
    Y_POT          = Y_STATS + md_h + gap
    Y_DEALER_HOLE  = Y_POT + POT_BAND_H + gap
    Y_DEALER_LABEL = Y_DEALER_HOLE + CARD_H + 8
    Y_BOARD        = Y_DEALER_LABEL + 22
    Y_PLAYER_LABEL = Y_BOARD + CARD_H + 8
    Y_PLAYER_HOLE  = Y_PLAYER_LABEL + 22
    Y_CHIPS        = Y_PLAYER_HOLE + CARD_H + 18
end

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

-- Buildup-phase pacing (pre-cinematic spectacle, before any cards
-- deal). Player sees a fade-in from black, then their chips fly in
-- arcs from the player stack at the bottom into the pot at the
-- center, one chip at a time. Pacing accelerates: first chips ease
-- in slowly so the player reads what's happening, later chips fire
-- in quick succession so big bankrolls don't take forever. Mult /
-- win-% counters tick up as chips land, then a brief "ALL IN" lock
-- beat before the gauntlet's card timeline starts.
local BUILDUP_FADE_DURATION    = 0.5
local BUILDUP_LOCK_DURATION    = 1.0
local BUILDUP_FLIGHT_DURATION  = 0.45      -- per-chip flight time
local BUILDUP_INTERVAL_START   = 0.30      -- delay before chip 1
local BUILDUP_INTERVAL_END     = 0.05      -- delay before final chip
local BUILDUP_MAX_CHIPS        = 30
local BUILDUP_MIN_CHIPS        = 8

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
        -- Pre-cinematic buildup (spectacle moment): "idle" | "buildup"
        -- | "ready_to_deal" | "running". ShoveState:enter calls
        -- :beginBuildup which sets phase="buildup"; when phase_t crosses
        -- BUILDUP_TOTAL the view reports isReadyToDeal so the host
        -- transitions phase="running" and fires _beginGauntlet.
        phase           = "idle",
        phase_t         = 0,
        buildup_rates   = nil,
        buildup_chip_count_shown = 0,  -- last-frame count for sound triggers
    }, ShoveView)
    self.fonts = nil
    return self
end

function ShoveView:beginBuildup(rates)
    self.phase   = "buildup"
    self.phase_t = 0
    self.buildup_rates = rates
    self.timeline = nil
    self.elapsed  = 0
    self.next_event_idx = 1
    self.card_anims = {}
    self.chip_visible = { false, false, false }

    -- Compute the chip list to push in. Source: bankroll snapshot at
    -- shove-time. Larger bankroll = more chips (longer spectacle) but
    -- bounded by BUILDUP_MAX_CHIPS so a $1M shove doesn't take a
    -- minute. Pacing accelerates per chip so bigger pours feel
    -- punchy at the end instead of dragging.
    local bankroll = (rates and rates.bankroll)
                     or (self.game.state and self.game.state.bankroll)
                     or 0
    local n_target = math.floor(BUILDUP_MIN_CHIPS
        + math.log10(math.max(1, bankroll)) * 4 + 0.5)
    if n_target < BUILDUP_MIN_CHIPS then n_target = BUILDUP_MIN_CHIPS end
    if n_target > BUILDUP_MAX_CHIPS then n_target = BUILDUP_MAX_CHIPS end

    local breakdown = DenominationBreakdown.breakdown(
        bankroll, ChipData.full_palette, "jackpot")
    -- Truncate / pad to n_target. The breakdown returns largest-first;
    -- we keep the front so the showcase + primary chunks survive even
    -- when the trailing small-denom tail gets cut.
    local chips = {}
    for i = 1, math.min(#breakdown, n_target) do
        chips[i] = breakdown[i]
    end
    -- If the bankroll's natural breakdown is shorter than the target,
    -- pad with the smallest-denom of the breakdown so the visual is
    -- always a satisfying pour rather than 3 chips for $2.
    if #chips < BUILDUP_MIN_CHIPS and #breakdown > 0 then
        local last = breakdown[#breakdown]
        for i = #chips + 1, BUILDUP_MIN_CHIPS do chips[i] = last end
    end
    if #chips == 0 then
        -- Edge case: zero bankroll. Use the smallest denom in the
        -- ladder so the spectacle still plays.
        for i = 1, BUILDUP_MIN_CHIPS do chips[i] = 1 end
    end

    -- Emit-time curve: linearly interpolate the per-chip interval
    -- from BUILDUP_INTERVAL_START down to BUILDUP_INTERVAL_END across
    -- the chip count. Each chip's emit_t is the cumulative sum,
    -- offset by the fade-in duration so chips don't start flying
    -- before the room is lit.
    local n = #chips
    self.buildup_chips = {}
    local t_acc = BUILDUP_FADE_DURATION
    for i = 1, n do
        local frac = (n > 1) and ((i - 1) / (n - 1)) or 0
        local interval = BUILDUP_INTERVAL_START
            + (BUILDUP_INTERVAL_END - BUILDUP_INTERVAL_START) * frac
        t_acc = t_acc + interval
        self.buildup_chips[i] = {
            denom_idx = chips[i],
            emit_t    = t_acc,
            arrive_t  = t_acc + BUILDUP_FLIGHT_DURATION,
        }
    end
    self.buildup_arrived_count = 0
    self.buildup_total = (self.buildup_chips[n] and self.buildup_chips[n].arrive_t or 0)
                         + BUILDUP_LOCK_DURATION
end

function ShoveView:isReadyToDeal()
    return self.phase == "ready_to_deal"
end

function ShoveView:markRunning()
    self.phase = "running"
end

-- Use the shared game.fonts table so this view picks up the
-- DPI-scaled fonts that FontService rebuilds on resize. The local
-- self.fonts assignment is a per-frame view onto game.fonts and stays
-- a thin reference; we don't cache instances anymore.
function ShoveView:_ensureFonts()
    self.fonts = self.game.fonts
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

    -- Prototype build stops here — R2 / R3 (the dealer's cheats) stay
    -- unrevealed, so first-time players never see the 6th community
    -- card or the second chip slot. Win → prototype-end modal; loss
    -- → standard prestige. R2 / R3 visuals are dev-build only.
    if r.outcomes[1] and not Constants.PROTOTYPE_MODE then
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

    -- Hold the final state on screen for a beat so the player reads
    -- the result chips before the prestige / prototype-end modal pops
    -- over the cinematic. 0.5s was effectively "modal slams over the
    -- last reveal"; ~2.0s lets the WIN/LOSS land.
    self.total_duration = t + 2.0
end

function ShoveView:isAnimating()
    if self.phase == "buildup" or self.phase == "ready_to_deal" then
        return true
    end
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
    -- Drop buildup state so the next ShoveState:enter starts clean.
    self.phase          = "idle"
    self.phase_t        = 0
    self.buildup_rates  = nil
    self.buildup_chip_count_shown = 0
end

function ShoveView:skip()
    -- Buildup-skip: jump to ready-to-deal so the host fires the gauntlet
    -- on its next update tick. Player wanted out of the buildup spectacle.
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        self.phase_t = BUILDUP_TOTAL
        return
    end
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
    -- Buildup phase: advance phase_t, trigger a chip-land sound each
    -- time a new chip lands in the pot. Once phase_t crosses the
    -- buildup total we transition to "ready_to_deal" so ShoveState's
    -- update can fire _beginGauntlet on its next tick.
    if self.phase == "buildup" then
        self.phase_t = self.phase_t + dt
        if self.buildup_chips then
            local arrived = 0
            for _, c in ipairs(self.buildup_chips) do
                if self.phase_t >= c.arrive_t then arrived = arrived + 1 end
            end
            if arrived > (self.buildup_arrived_count or 0) then
                self.buildup_arrived_count = arrived
                if self.game.sounds and self.game.sounds.playNamed then
                    self.game.sounds.playNamed("chip_land_pot")
                end
            end
        end
        if self.phase_t >= (self.buildup_total or 0) then
            self.phase = "ready_to_deal"
            if self.game.sounds and self.game.sounds.playNamed then
                self.game.sounds.playNamed("shove_initiated")
            end
        end
        return
    end

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

-- Buildup spectacle: the player's chips fly from a stack at the
-- bottom of the screen up into a pot at the center, one at a time.
-- Each chip is a real Chips.drawChip render at the proper denomi-
-- nation so the visual reads as the actual bankroll being shoved.
-- Mult / win-% counters tick up as chips land, then "ALL IN" pops
-- once every chip is in the pot.
function ShoveView:_drawBuildup(W, H)
    local rates = self.buildup_rates or {}
    local s     = (self.game and self.game.ui_scale) or 1
    local fonts = self.fonts
    local function easeOut(t) return 1 - (1 - t) * (1 - t) end

    local fade_t        = math.min(1, self.phase_t / BUILDUP_FADE_DURATION)
    local total_chips   = self.buildup_chips and #self.buildup_chips or 0
    local last_arrive_t = (total_chips > 0) and self.buildup_chips[total_chips].arrive_t or 0
    local lock_t        = math.max(0, self.phase_t - last_arrive_t)
    local in_lock       = lock_t > 0 and total_chips > 0

    -- Anchor positions. Stack lives at the bottom-center of the
    -- window; pot lands in the dedicated POT band between the board
    -- and the player hole cards — same spot it'll occupy during the
    -- cinematic, so the pile doesn't relocate or vanish when cards
    -- start dealing.
    local stack_cx = math.floor(W / 2)
    local stack_cy = math.floor(H * 0.85)
    local pot_cx   = math.floor(W / 2)
    local pot_cy   = Y_POT + math.floor(POT_BAND_H * 0.55)
    local arc_lift = math.max(40, math.floor(120 * s))

    -- Build the per-chip "in flight / arrived / waiting" partition.
    -- waiting_chips draws as a stack at the bottom; arrived_chips as
    -- a pot pile in the center; in_flight gets per-chip animated
    -- positions.
    local arrived_indices = {}
    local waiting_indices = {}
    local in_flight = {}
    if self.buildup_chips then
        for _, c in ipairs(self.buildup_chips) do
            if self.phase_t >= c.arrive_t then
                arrived_indices[#arrived_indices + 1] = c.denom_idx
            elseif self.phase_t >= c.emit_t then
                in_flight[#in_flight + 1] = c
            else
                waiting_indices[#waiting_indices + 1] = c.denom_idx
            end
        end
    end

    -- Counters tick up against the fraction of chips that have
    -- arrived. Mult: 1.0 → rates.mult; win %: 0 → all-in win chance.
    -- Win chance shows the R1 rate (what the player is actually
    -- shoving on); displaying clear% would expose the gauntlet's
    -- multi-runout structure and is also 0% in prototype mode where
    -- R2/R3 are hard-gated to losses.
    local arrival_frac = (total_chips > 0)
        and math.min(1, #arrived_indices / total_chips) or 0
    local p_eased = easeOut(arrival_frac)
    local target_mult = rates.mult or 1.0
    local target_win  = (rates.r1 or 0) * 100
    local mult_now = 1.0 + (target_mult - 1.0) * p_eased
    local win_pct  = target_win * p_eased
    if in_lock then
        mult_now = target_mult
        win_pct  = target_win
    end

    -- Stats readout above the pot pile. Reading order: BASE × MULT
    -- = SHOVE. The total is the takeaway, so it renders in fonts.md
    -- (heading-color when locked); the inputs (base, mult) sit
    -- smaller in fonts.sm so they read as supporting data.
    local catalog_pct = math.floor((rates.catalog or 0) * 100 + 0.5)
    local stats_y = Y_STATS
    local text_left  = string.format("BASE %d%%   ×   MULT %.2f   =   ",
        catalog_pct, mult_now)
    local text_right = string.format("SHOVE %d%%", math.floor(win_pct + 0.5))
    local left_w  = fonts.sm:getWidth(text_left)
    local right_w = fonts.md:getWidth(text_right)
    local total_w = left_w + right_w
    local sx      = math.floor((W - total_w) / 2)
    -- Vertically center sm against md so the baselines align.
    local md_h = fonts.md:getHeight()
    local sm_h = fonts.sm:getHeight()
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(text_left, sx, stats_y + math.floor((md_h - sm_h) / 2))
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(text_right, sx + left_w, stats_y)

    -- Stack at the bottom — chips not yet flown. Drawn through Chips
    -- so they match in-game chip art exactly.
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    if #waiting_indices > 0 or total_chips > #arrived_indices then
        printCentered("YOUR STACK", fonts.sm,
            0, stack_cy - math.floor(36 * s), W)
        Chips.drawStack(stack_cx, stack_cy, waiting_indices,
            { align = "center" })
    end

    -- Pot pile centered in the pot band. Just the chip visual — the
    -- pile itself reads as "this is the pot".
    if #arrived_indices > 0 or in_lock then
        Chips.drawStack(pot_cx, pot_cy, arrived_indices,
            { align = "center" })
    end

    -- In-flight chips: parabolic arc from stack to pot. Drawn as
    -- single chips at their interpolated positions.
    for _, c in ipairs(in_flight) do
        local t   = (self.phase_t - c.emit_t) / BUILDUP_FLIGHT_DURATION
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local et  = easeOut(t)
        local cx  = stack_cx + (pot_cx - stack_cx) * et
        local cy  = stack_cy + (pot_cy - stack_cy) * et
        cy = cy - arc_lift * math.sin(math.pi * t)
        Chips.drawChip(cx, cy, c.denom_idx, 1.0, false, nil)
    end

    -- Lock-in flash + "ALL IN" headline.
    if in_lock then
        local lock_progress = math.min(1, lock_t / BUILDUP_LOCK_DURATION)
        local flash_alpha = math.max(0, 0.45 * (1 - lock_progress * 2))
        if flash_alpha > 0 then
            love.graphics.setColor(1.0, 0.95, 0.80, flash_alpha)
            love.graphics.rectangle("fill", 0, 0, W, H)
        end
        love.graphics.setFont(fonts.lg)
        Theme.setColor(Theme.status.error)
        local headline = "ALL IN"
        local hw = fonts.lg:getWidth(headline)
        local hy = math.floor(H * 0.36)
        local pop = math.min(1, lock_t / 0.25)
        local pop_scale = 0.85 + 0.15 * easeOut(pop)
        love.graphics.push()
        love.graphics.translate(W / 2, hy)
        love.graphics.scale(pop_scale, pop_scale)
        love.graphics.print(headline, -hw / 2, 0)
        love.graphics.pop()
    end

    if fade_t > 0.4 then
        local label_alpha = math.min(1, (fade_t - 0.4) / 0.6)
        love.graphics.setFont(fonts.md)
        love.graphics.setColor(1, 1, 1, label_alpha * 0.6)
        printCentered("PUSHING ALL IN…", fonts.md, 0, math.floor(H * 0.10), W)
    end
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

-- Persistent shove HUD drawn during the gauntlet cinematic. Keeps
-- the pot stack + rate breakdown visible the whole time so the
-- player never loses sight of what's at stake or what their odds
-- are. Without this the screen goes from "buildup with full
-- context" to "cards floating in a black void" the instant the
-- cinematic starts, which the player reads as everything vanishing.
function ShoveView:_drawShoveStatus(W, H)
    local rates = self.buildup_rates
    if not rates then return end
    local fonts = self.fonts
    local s     = (self.game and self.game.ui_scale) or 1

    -- Stats readout in Y_STATS slot — same position the buildup uses.
    -- Total renders bigger (md, status-good color) than the inputs
    -- (sm, muted) so the takeaway lands and the math reads as
    -- supporting context.
    local catalog_pct = math.floor((rates.catalog or 0) * 100 + 0.5)
    local shove_pct   = math.floor((rates.r1 or 0) * 100 + 0.5)
    local stats_y = Y_STATS
    local text_left  = string.format("BASE %d%%   ×   MULT %.2f   =   ",
        catalog_pct, rates.mult or 1.0)
    local text_right = string.format("SHOVE %d%%", shove_pct)
    local left_w  = fonts.sm:getWidth(text_left)
    local right_w = fonts.md:getWidth(text_right)
    local total_w = left_w + right_w
    local sx      = math.floor((W - total_w) / 2)
    local md_h    = fonts.md:getHeight()
    local sm_h    = fonts.sm:getHeight()
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    love.graphics.print(text_left, sx, stats_y + math.floor((md_h - sm_h) / 2))
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.heading)
    love.graphics.print(text_right, sx + left_w, stats_y)

    -- Pot pile in the center of the pot band. Same chip list the
    -- buildup arrived with, so the pile stays exactly where it
    -- landed when the cards take over.
    if self.buildup_chips and #self.buildup_chips > 0 then
        local chip_indices = {}
        for i, c in ipairs(self.buildup_chips) do
            chip_indices[i] = c.denom_idx
        end
        local pot_cx = math.floor(W / 2)
        local pot_cy = Y_POT + math.floor(POT_BAND_H * 0.55)
        Chips.drawStack(pot_cx, pot_cy, chip_indices, { align = "center" })
    end
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
    -- Scale card / gap sizes by ui_scale so the gauntlet doesn't sit
    -- as a tiny island in the middle of a 4K screen.
    local s = (self.game and self.game.ui_scale) or 1
    CARD_W   = math.floor(CARD_BASE_W * s)
    CARD_H   = math.floor(CARD_W * 3.5 / 2.5)
    CARD_GAP = math.floor(CARD_BASE_GAP * s)
    -- Vertically center the gauntlet stack in the current window.
    recomputeLayout(H, self.fonts, s)

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

    love.graphics.setFont(self.fonts.sm)
    Theme.setColor(Theme.status.error)
    love.graphics.print("SHOVE", 16, 12)

    -- Buildup phase: spectacle moment before the gauntlet's card
    -- timeline starts. Draws over the same felt/spotlight backdrop
    -- the cinematic uses, then early-returns so card rendering and
    -- chip strip don't draw on top.
    if self.phase == "buildup" or self.phase == "ready_to_deal" then
        self:_drawBuildup(W, H)
        -- Black fade-in: opaque at phase_t=0, transparent at the end
        -- of BUILDUP_FADE_DURATION. Anything drawn before this gets
        -- the casino room "lights coming up" effect.
        local fade_alpha = 1 - math.min(1, self.phase_t / BUILDUP_FADE_DURATION)
        if fade_alpha > 0 then
            love.graphics.setColor(0, 0, 0, fade_alpha)
            love.graphics.rectangle("fill", 0, 0, W, H)
        end
        return
    end

    local g = self.ss.gauntlet
    local result = g and g.result or nil

    love.graphics.setFont(self.fonts.lg)
    Theme.setColor(Theme.fg.heading)
    printCentered(bannerFor(g, self), self.fonts.lg, 0, Y_BANNER, W)

    -- Persistent shove status (pot $ + chip stack + base × mult =
    -- shove %) so the player always sees what's at stake and what
    -- their odds are during the cards.
    self:_drawShoveStatus(W, H)

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

    -- Hand labels (dealer above board, player below board). Drawn as
    -- solid status-color pills with dark text so they stay legible
    -- regardless of what cards happen to sit underneath. The previous
    -- thin red / green text on the shove backdrop blended into the
    -- card art.
    if result and revealed_idx > 0 then
        local eval = result.evals[revealed_idx]
        if eval then
            local function drawLabelPill(text, y, color)
                love.graphics.setFont(self.fonts.md)
                local fh    = self.fonts.md:getHeight()
                local pad_x = 14
                local pad_y = 6
                local tw    = self.fonts.md:getWidth(text)
                local pill_w = tw + pad_x * 2
                local pill_h = fh + pad_y * 2
                local pill_x = math.floor((W - pill_w) / 2)
                local pill_y = y - pad_y
                Theme.setColor(color)
                love.graphics.rectangle("fill", pill_x, pill_y, pill_w, pill_h, Theme.space.radius)
                Theme.setColor(Theme.border.strong)
                love.graphics.setLineWidth(2)
                love.graphics.rectangle("line", pill_x, pill_y, pill_w, pill_h, Theme.space.radius)
                love.graphics.setLineWidth(1)
                Theme.setColor(Theme.bg.window)
                love.graphics.print(text, pill_x + pad_x, pill_y + pad_y)
            end
            drawLabelPill("dealer: " .. HandEval.describe(eval.dealer_rank),
                Y_DEALER_LABEL, Theme.status.error)
            drawLabelPill("player: " .. HandEval.describe(eval.player_rank),
                Y_PLAYER_LABEL, Theme.status.good)
        end
    end

    -- Runout result chips — only render the ones that have actually
    -- been revealed. Pre-revealed grey chips spoiled the structure (the
    -- player could count "ah, three runouts coming" before any cards
    -- landed). Now each chip pops in as it's earned. Chips stay anchored
    -- to their original positions so they fill in left-to-right without
    -- the layout shifting around.
    -- Result chips: solid status-color fill + dark text so the WIN/LOSS
    -- reads at a glance regardless of the underlying shove backdrop.
    -- Sizes scale with ui_scale so the chips grow on bigger windows.
    -- Prototype build only ever resolves R1 — R2 / R3 are gated to
    -- losses and never deal a 6th/7th card. So we render a single
    -- chip slot instead of the three-slot strip; the empty R2/R3
    -- slots would tip the player off that more is coming.
    local n_slots  = Constants.PROTOTYPE_MODE and 1 or 3
    local s        = (self.game.ui_scale) or 1
    local chip_w   = math.max(72, math.floor(110 * s))
    local chip_h   = math.max(28, math.floor(42  * s))
    local total_chip_w = n_slots * chip_w + math.max(0, n_slots - 1) * CARD_GAP
    local chip_x0 = math.floor((W - total_chip_w) / 2)
    love.graphics.setFont(self.fonts.md)
    for i = 1, n_slots do
        if self.chip_visible[i] then
            local x = chip_x0 + (i - 1) * (chip_w + CARD_GAP)
            local outcome = result and result.outcomes[i]
            local fill_color
            local label
            if outcome == true then
                label, fill_color = "WIN",  Theme.status.good
            else
                label, fill_color = "LOSS", Theme.status.error
            end
            Theme.setColor(fill_color)
            love.graphics.rectangle("fill", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
            Theme.setColor(Theme.border.strong)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", x, Y_CHIPS, chip_w, chip_h, Theme.space.radius)
            love.graphics.setLineWidth(1)
            -- Dark text on the bright fill — high contrast either way.
            Theme.setColor(Theme.bg.window)
            local text_y = Y_CHIPS + math.floor((chip_h - self.fonts.md:getHeight()) / 2)
            printCentered(label, self.fonts.md, x, text_y, chip_w)
        end
    end
end

return ShoveView
