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
local Decks                  = require("models.Decks")
local SpriteRenderer         = require("services.SpriteRenderer")
local Chips                  = require("views.Chips")
local Tumble                 = require("services.Tumble")
local DenominationBreakdown  = require("services.DenominationBreakdown")
local ChipData               = require("data.chips")
local CardSprites            = require("views.CardSprites")
local ShoveDecor             = require("views.ShoveDecor")
local Style                  = require("data.shove_style")
local ShoveRate              = require("models.shove_rate")

local ShoveView = {}
ShoveView.__index = ShoveView

-- Card sizes / gaps.
--
-- CARD_W is a FIXED 112, not a fraction of ui_scale. The draw size has to be an
-- exact ratio of the source art or the pixel grid comes apart. Fronts ship
-- 56x80, so 112x160 is an exact 2x nearest-neighbour double; services/
-- SpriteLoader's card-back mip chain tops out at exactly 112x160, so backs draw
-- 1:1. The old 88 * 1.25 = 110 magnified fronts 1.964x horizontally and 1.925x
-- vertically -- a non-integer nearest upscale with the two axes disagreeing,
-- which gives uneven pixel runs across the card.
--
-- The height comes from the SPRITE aspect (80/56 = 1.4286), not a nominal
-- playing-card 3.5/2.5 (1.4). Those differ, so the old chain squashed every
-- gauntlet card 2% vertically against the same art on the felt, where
-- views/FeltLayout uses CARD_ASPECT = 56/80 correctly.
local CARD_W   = 112
local CARD_H   = math.floor(CARD_W * 80 / 56)     -- 160
local CARD_GAP = 15

-- Pot band. Scaled with everything else now; the old flat 110 was the only
-- unscaled constant in the chain. views/Chips at this scale draws a 44px chip
-- and stacks 6 to a column, so a full column is 69px -- 80 holds it.
local POT_BAND_BASE_H = 64
local POT_BAND_H      = 80

-- Reading order top to bottom: banner ("ALL-IN") -> POT chip pile -> dealer
-- hole -> the board row -> player hole -> result chips.
--
-- There is no separate SHOVE % headline any more: the stats panel on the right
-- of the board row carries the total, and a second copy above the table would
-- be the same number twice.
--
-- The hand labels do not own bands here. They draw BESIDE the hole cards they
-- describe: a pill is fonts.md:getHeight() + 2*pad_y = 54px tall and the chain
-- used to allot it 22, so both pills painted over 26px of card, including any
-- best-5 stroke underneath. There is clear felt either side of the 239px hole
-- row, so the pills move out rather than the band growing.
local Y_BANNER       = 0
local Y_POT          = 0
local Y_DEALER_HOLE  = 0
local Y_BOARD        = 0
local Y_PLAYER_HOLE  = 0
local Y_CHIPS        = 0
local Y_DEALER_LABEL = 0
local Y_PLAYER_LABEL = 0

local function recomputeLayout(H, fonts, s)
    local md_h = (fonts and fonts.md and fonts.md:getHeight()) or 18
    local lg_h = (fonts and fonts.lg and fonts.lg:getHeight()) or 32
    s = s or 1

    local gap      = math.floor(8  * s)
    local row_gap  = math.floor(6  * s)
    local chip_gap = math.floor(14 * s)
    local chip_h   = math.max(28, math.floor(42 * s))

    POT_BAND_H = math.floor(POT_BAND_BASE_H * s)

    -- Every term here is a real span in the chain below. The previous version
    -- dropped the banner's trailing gap and used a hardcoded 36 for the result
    -- chips against a real 52, so it understated the stack by 26px and the whole
    -- gauntlet sat 13px above centre.
    local stack_h = lg_h + gap          -- banner
                  + POT_BAND_H + gap
                  + 3 * CARD_H + 2 * row_gap
                  + chip_gap + chip_h
    local top = math.max(8, math.floor((H - stack_h) / 2))

    Y_BANNER      = top
    Y_POT         = Y_BANNER + lg_h + gap
    Y_DEALER_HOLE = Y_POT + POT_BAND_H + gap
    Y_BOARD       = Y_DEALER_HOLE + CARD_H + row_gap
    Y_PLAYER_HOLE = Y_BOARD + CARD_H + row_gap
    Y_CHIPS       = Y_PLAYER_HOLE + CARD_H + chip_gap

    -- Labels centre vertically on the card row they describe.
    local pill_h   = md_h + 12
    Y_DEALER_LABEL = Y_DEALER_HOLE + math.floor((CARD_H - pill_h) / 2)
    Y_PLAYER_LABEL = Y_PLAYER_HOLE + math.floor((CARD_H - pill_h) / 2)
end

-- ─── The board row ────────────────────────────────────────────────────
--
-- SEVEN positions in one line. 1-5 are the community cards; 6 and 7 are where
-- the dealer's cheat cards land, and until they do those positions carry the
-- BASE and MULT readouts.
--
-- A wider gap sits between 5 and 6 so the right-hand pair reads as a breakdown
-- panel beside the board rather than as part of it. That is what keeps the
-- runout structure a surprise: nothing on screen says two more cards are
-- coming, and the reveal is that it was one row all along.
--
-- The row never moves. The old code lerped an animated pack origin so a
-- 5-centred board could re-centre itself for 6 and again for 7; with a fixed
-- seven-wide row there is nothing to slide.
local function rowWidth()
    return 7 * CARD_W + 4 * CARD_GAP
         + Style.row.section_gap + Style.stats.op_gap
end

local function rowOriginFor(screen_w)
    return math.floor((screen_w - rowWidth()) / 2)
end

-- Left edge of row position i (1..7).
--
-- Two gaps are wider than the card gap and REPLACE it rather than adding to it,
-- so rowWidth counts each exactly once: `section_gap` between the board and the
-- panel, and `op_gap` between the panel's two columns (it holds the
-- multiplication sign).
local function slotX(origin, i)
    local x = origin + (i - 1) * (CARD_W + CARD_GAP)
    if i > 5 then x = x + (Style.row.section_gap - CARD_GAP) end
    if i > 6 then x = x + (Style.stats.op_gap    - CARD_GAP) end
    return x
end

-- Centre of the five-card board, and the anchor for everything that belongs to
-- THE TABLE: the banner, the pot pile, both hole rows, the result chips.
--
-- Not the centre of the screen. The stats panel occupies the right of the row,
-- so a screen-centred table would sit half under it; the table is its own
-- column and the panel is another.
local function tableCenterX(screen_w)
    local origin = rowOriginFor(screen_w)
    return origin + (5 * CARD_W + 4 * CARD_GAP) / 2
end

-- Centre of the stats panel (positions 6 and 7 together).
local function panelCenterX(screen_w)
    local origin = rowOriginFor(screen_w)
    return (slotX(origin, 6) + slotX(origin, 7) + CARD_W) / 2
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
-- Fake-3D character for a buildup chip's flight (services/Tumble). Exactly
-- one flip and one spin from phase 0, so the chip is face-on and upright
-- at BOTH ends: it leaves looking like a chip in the stack and arrives
-- looking like a chip in the pot, with no pose to snap out of when the
-- pile takes over drawing it. `loft` is the new part — the chip comes
-- toward the camera on the way over, which is what makes the arc the
-- flight already has read as height rather than as a detour. Axis and
-- spin direction are left to randomise per chip.
local BUILDUP_TUMBLE = {
    flips = 1, spins = 1, phase = 0, min_squash = 0.28,
    loft  = { 0.30, 0.50 },
}

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
        bankroll, ChipData.denominations, ChipData.full_palette,
        ChipData.tier_chip_target, "jackpot")
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
        local denom = chips[i]
        self.buildup_chips[i] = {
            denom_idx = denom,
            emit_t    = t_acc,
            arrive_t  = t_acc + BUILDUP_FLIGHT_DURATION,
            -- Fake-3D motion for the flight, rolled ONCE per chip here.
            -- services/Tumble randomises its axis and spin direction per
            -- wrap, so wrapping in the draw would reroll them every frame
            -- and the chip would jitter instead of tumble.
            render_fn = Tumble.wrap(function(px, py, _t, squash)
                if squash and squash < Chips.EDGE_SQUASH then
                    Chips.drawChipEdge(px, py, denom, 1.0, nil)
                else
                    Chips.drawChip(px, py, denom, 1.0, false, nil)
                end
            end, BUILDUP_TUMBLE),
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

    -- Demo cut stops here — R2 / R3 (the dealer's cheats) stay
    -- unrevealed, so first-time players never see the 6th community
    -- card or the second chip slot. Win → prototype-end modal; loss
    -- → standard prestige. R2 / R3 visuals run when DEMO_CUT is off.
    if r.outcomes[1] and not Constants.FEATURES.DEMO_CUT then
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

end

-- ─── Drawing helpers ───────────────────────────────────────────────────

local function printCentered(text, font, x, y, w)
    local tw = font:getWidth(text)
    love.graphics.print(text, math.floor(x + (w - tw) / 2), y)
end

-- Every card in the gauntlet goes through here, so the drop shadow does too.
-- The shadow tracks the card's VISIBLE width: a hole card mid-flip is scaled
-- horizontally toward zero, and a full-width shadow under a card on edge would
-- read as a slab the card is standing on.
--
-- No size gate. views/FeltDecor gates shadows on card width because the felt
-- runs down to 9px cards; these are a fixed 112px, far above that threshold.
local function drawCardSprite(sl, sprite_name, x, y, w, h, scale_x, alpha)
    local ew = w * (scale_x or 1)
    CardSprites.shadow(x + (w - ew) / 2, y, ew, h, alpha, ShoveDecor.shadowOffset())
    CardSprites.sprite(sl, sprite_name, x, y, w, h, scale_x, alpha)
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

-- Wrapper for the best-5 stroke; lives in views/CardSprites.
local function strokeSlot(x, y, w, h, inset, lw)
    CardSprites.strokeSlot(x, y, w, h, inset, lw)
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
    local stack_cx = math.floor(tableCenterX(W))
    local stack_cy = math.floor(H * 0.85)
    local pot_cx   = math.floor(tableCenterX(W))
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
    -- raw_r1, not the clamped r1: the grind top bar already shows the uncapped
    -- figure, so clamping here made a 220% player watch their number collapse
    -- to 100% at the moment they pressed the button.
    local target_win  = (rates.raw_r1 or rates.r1 or 0) * 100
    local mult_now = 1.0 + (target_mult - 1.0) * p_eased
    local win_pct  = target_win * p_eased
    if in_lock then
        mult_now = target_mult
        win_pct  = target_win
    end

    -- The readout, ticking up as the chips land. Nothing is covered during the
    -- buildup: the dealer has not dealt anything yet.
    local base_v = (rates.catalog or 0) + (rates.deck or 0)
    self:_drawStats(math.floor(base_v * 100 + 0.5), mult_now,
                    math.floor(win_pct + 0.5), nil)

    -- Stack at the bottom — chips not yet flown. Drawn through Chips
    -- so they match in-game chip art exactly.
    love.graphics.setFont(fonts.sm)
    Theme.setColor(Theme.fg.muted)
    if #waiting_indices > 0 or total_chips > #arrived_indices then
        printCentered("YOUR STACK", fonts.sm,
            stack_cx - math.floor(W / 4), stack_cy - math.floor(36 * s),
            math.floor(W / 2))
        Chips.drawStack(stack_cx, stack_cy, waiting_indices,
            { align = "center" })
    end

    -- Pot pile centered in the pot band. Just the chip visual — the
    -- pile itself reads as "this is the pot".
    if #arrived_indices > 0 or in_lock then
        Chips.drawStack(pot_cx, pot_cy, arrived_indices,
            { align = "center" })
    end

    -- In-flight chips: parabolic arc from stack to pot, tumbling and
    -- rising toward the camera as they go. Position eases out; the
    -- tumble takes RAW t, so its loft peaks at the same instant the arc
    -- does and the chip is largest at the top of its own arc.
    for _, c in ipairs(in_flight) do
        local t   = (self.phase_t - c.emit_t) / BUILDUP_FLIGHT_DURATION
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local et  = easeOut(t)
        local cx  = stack_cx + (pot_cx - stack_cx) * et
        local cy  = stack_cy + (pot_cy - stack_cy) * et
        cy = cy - arc_lift * math.sin(math.pi * t)
        if c.render_fn then
            c.render_fn(cx, cy, t)
        else
            Chips.drawChip(cx, cy, c.denom_idx, 1.0, false, nil)
        end
    end

    -- Lock-in flash + "ALL IN" headline.
    if in_lock then
        local lock_progress = math.min(1, lock_t / BUILDUP_LOCK_DURATION)
        local flash_alpha = math.max(0, 0.45 * (1 - lock_progress * 2))
        if flash_alpha > 0 then
            Theme.setColor(Theme.fg.heading, flash_alpha)
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
        Theme.setColor(Theme.fg.heading, label_alpha * 0.6)
        printCentered("PUSHING ALL IN…", fonts.md, 0, math.floor(H * 0.10), W)
    end
end

-- === The shove readout ================================================
--
-- The headline SHOVE % sits above the table. Its two inputs, BASE and MULT, sit
-- at row positions 6 and 7 -- the two places the dealer's cheat cards land.
--
-- One publisher, called by both the buildup and the persistent cinematic HUD.
-- Those used to carry near-identical copies of this block, which is two places
-- deciding one thing.
--
-- Nothing is drawn behind BASE and MULT: no plate, no panel, no slot. They are
-- text sitting in a gap beside the board, which is what lets the right-hand
-- pair read as a breakdown panel rather than as two empty card positions. The
-- runout structure has to stay a surprise.
function ShoveView:_drawStats(base_pct, mult_val, total_pct, covered)
    local fonts  = self.fonts
    local W      = love.graphics.getWidth()
    local origin = rowOriginFor(W)
    local md_h   = fonts.md:getHeight()

    -- BASE and MULT, centred in their columns and on the cards beside them.
    local ty = Y_BOARD + math.floor(CARD_H * Style.stats.row_align - md_h / 2)
    love.graphics.setFont(fonts.md)
    local function put(i, kind, text)
        Theme.setColor((covered and covered[kind]) and Theme.fg.faint or Theme.fg.muted)
        printCentered(text, fonts.md, slotX(origin, i), ty, CARD_W)
    end
    put(6, "base", string.format("BASE %d%%", base_pct))
    -- Decimals shrink as the number grows: the column is one card wide and the
    -- Act 3 underflow puts 999 in it. "MULT 999.00" would not fit; "MULT 999"
    -- does, and the decimals mean nothing at that magnitude anyway.
    local mfmt = (mult_val >= 100 and "MULT %.0f")
              or (mult_val >= 10  and "MULT %.1f")
              or "MULT %.2f"
    put(7, "mult", string.format(mfmt, mult_val))

    -- The multiplication sign, in the gap between the two columns. Part of the
    -- frame, not a value: it stays put when a cheat card buries a term.
    Theme.setColor(Theme.fg.faint)
    printCentered("\u{00D7}", fonts.md,
                  slotX(origin, 6) + CARD_W, ty, Style.stats.op_gap)

    -- The total, under both columns. This is the number that collapses as the
    -- dealer buries its inputs, so it carries the emphasis.
    local lg_h = fonts.lg:getHeight()
    local ty2  = Y_BOARD + CARD_H + Style.stats.total_gap
    local px   = slotX(origin, 6)
    local pw   = (slotX(origin, 7) + CARD_W) - px
    love.graphics.setFont(fonts.lg)
    Theme.setColor(Theme.fg.heading)
    printCentered(string.format("= %d%%", total_pct), fonts.lg, px, ty2, pw)
    love.graphics.setFont(fonts.md)
    Theme.setColor(Theme.fg.faint)
    printCentered("ALL-IN", fonts.md, px, ty2 + lg_h, pw)
end

-- The live terms behind the readout, after whatever the dealer has taken.
--
--   r1 = cat  x mult          both live
--   r2 = 0    x mult          card 6 covered the catalog base
--   r3 = deck x 0             card 7 covered the mult
--
-- A covered term is zero for the runouts after it. The one exception is the
-- multiplier once the bankroll has underflowed: that is a number the dealer
-- cannot bury, and it is how the last runout is finally won.
function ShoveView:_underflowed(rates)
    return ShoveRate.underflowed(rates.bankroll)
end

function ShoveView:_statsValues(rates, covered)
    local base = (rates.catalog or 0) + (rates.deck or 0)
    local mult = rates.mult or 1.0
    if covered and covered.base then base = rates.deck or 0 end
    if covered and covered.mult and not self:_underflowed(rates) then mult = 0 end
    return base, mult, base * mult
end

-- Which readouts the dealer has buried. Keyed off the cheat cards having
-- actually been dealt, so the numbers and the cards can never disagree.
function ShoveView:_coveredRuns()
    return { base = self.card_anims.board_6 ~= nil,
             mult = self.card_anims.board_7 ~= nil }
end

-- The dealer's cheat cards: board cards 6 and 7, dealt UPRIGHT into row
-- positions 6 and 7 like any other community card. They land on the BASE and
-- MULT readouts and bury them, and the seven-card line is complete.
--
-- Under FEATURES.DEMO_CUT the timeline never creates board_6 / board_7, so this
-- draws nothing and needs no flag of its own.
function ShoveView:_drawCheatCards(result, eval)
    if not (Style.cheat.enabled and result) then return end
    local origin = rowOriginFor(love.graphics.getWidth())

    for _, i in ipairs{ 6, 7 } do
        local anim = self.card_anims["board_" .. i]
        local card = result.board[i]
        if anim and card then
            local x     = slotX(origin, i)
            local alpha = anim.getAlpha and anim:getAlpha() or 1
            drawCardSprite(self.game.sprite_loader, card:spriteName(),
                           x, Y_BOARD, CARD_W, CARD_H, 1, alpha)
            if eval then
                if isInCombo(card, eval.player_combo) then
                    Theme.setColor(Theme.status.good, 0.95)
                    strokeSlot(x, Y_BOARD, CARD_W, CARD_H, 2, 3)
                end
                if isInCombo(card, eval.dealer_combo) then
                    Theme.setColor(Theme.status.error, 0.95)
                    strokeSlot(x, Y_BOARD, CARD_W, CARD_H, -3, 3)
                end
            end
        end
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
    -- Active-deck override for the gauntlet hole-card back. Falls back
    -- to the constant default when the deck system hasn't unlocked or
    -- the active spec is missing, so pre-clear builds render cleanly.
    local back = (Decks.systemUnlocked(self.game.state)
                  and Decks.activeSprite(self.game.state))
                 or Constants.GAUNTLET.CARD_BACK_SPRITE
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
-- the pot pile + rate breakdown visible the whole time so the
-- player never loses sight of what's at stake or what their odds
-- are. The pile is the only pot readout; there is no $ figure. Without this the screen goes from "buildup with full
-- context" to "cards floating in a black void" the instant the
-- cinematic starts, which the player reads as everything vanishing.
function ShoveView:_drawShoveStatus(W, H)
    local rates = self.buildup_rates
    if not rates then return end
    local fonts = self.fonts
    local s     = (self.game and self.game.ui_scale) or 1

    -- The readout, with whatever the dealer has already buried. Values come
    -- from _statsValues so the printed breakdown is always the live one.
    local covered = self:_coveredRuns()
    local base_v, mult_v, shove_v = self:_statsValues(rates, covered)
    self:_drawStats(math.floor(base_v * 100 + 0.5), mult_v,
                    math.floor(shove_v * 100 + 0.5), covered)

    -- Pot pile in the center of the pot band. Same chip list the
    -- buildup arrived with, so the pile stays exactly where it
    -- landed when the cards take over.
    if self.buildup_chips and #self.buildup_chips > 0 then
        local chip_indices = {}
        for i, c in ipairs(self.buildup_chips) do
            chip_indices[i] = c.denom_idx
        end
        local pot_cx = math.floor(tableCenterX(W))
        local pot_cy = Y_POT + math.floor(POT_BAND_H * 0.55)
        Chips.drawStack(pot_cx, pot_cy, chip_indices, { align = "center" })
    end
end

function ShoveView:draw()
    self:_ensureFonts()

    local W, H = love.graphics.getDimensions()
    -- Scale card / gap sizes by ui_scale so the gauntlet doesn't sit
    -- as a tiny island in the middle of a 4K screen.
    local s = (self.game and self.game.ui_scale) or 1
    -- Card sizes are fixed (see the constant block): they have to stay an exact
    -- ratio of the source art. Only the chain around them scales.
    recomputeLayout(H, self.fonts, s)

    -- The table. views/ShoveDecor paints the room, the felt band, its rim and
    -- the lighting; this view only says where the band goes. The band is sized
    -- off the card rows so the cards always land on it.
    local felt_top    = Y_DEALER_HOLE - 40
    local felt_height = (Y_PLAYER_HOLE + CARD_H + 40) - felt_top
    ShoveDecor.drawBackdrop({
        x = 0, y = felt_top, w = W, h = felt_height,
        screen_w = W, screen_h = H,
    })

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
            Theme.setColor(Theme.bg.sunken, fade_alpha)
            love.graphics.rectangle("fill", 0, 0, W, H)
        end
        return
    end

    local g = self.ss.gauntlet
    local result = g and g.result or nil

    love.graphics.setFont(self.fonts.lg)
    Theme.setColor(Theme.fg.heading)
    -- Centred on the TABLE, not the screen: the banner belongs to the felt,
    -- and the stats panel owns the right of the row.
    printCentered(bannerFor(g, self), self.fonts.lg,
                  math.floor(tableCenterX(W) - W / 4), Y_BANNER, math.floor(W / 2))

    -- Persistent shove status (pot chip pile + the SHOVE % breakdown) so the
    -- player always sees what's at stake and what their odds are during the
    -- cards. No dollar figure: the pile IS the pot readout.
    self:_drawShoveStatus(W, H)

    local n_board  = visibleBoardCount(g)
    local board_x  = rowOriginFor(W)

    -- Recessed slots under positions 1-5 ONLY. Positions 6 and 7 carry the
    -- BASE / MULT readout until a cheat card lands on them, and a card-shaped
    -- hole sitting there would announce the cheats before they happen.
    for i = 1, 5 do
        ShoveDecor.drawSlot(slotX(board_x, i), Y_BOARD, CARD_W, CARD_H)
    end

    -- Board cards. 6 and 7 are dealt by _drawCheatCards, after the readout they
    -- bury has been drawn.
    for i = 1, math.min(5, n_board) do
        self:_drawBoardCard(i, slotX(board_x, i), Y_BOARD)
    end

    -- Hole card slots (player + dealer placeholder rectangles).
    local hole_w = 2 * CARD_W + CARD_GAP
    -- Under the five-card board, not the middle of the screen.
    local hole_x = math.floor(tableCenterX(W) - hole_w / 2)
    for i = 0, 1 do
        local x = hole_x + i * (CARD_W + CARD_GAP)
        ShoveDecor.drawSlot(x, Y_DEALER_HOLE, CARD_W, CARD_H)
        ShoveDecor.drawSlot(x, Y_PLAYER_HOLE, CARD_W, CARD_H)
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
            -- All seven positions: a cheat card is usually the card that
            -- decided the runout, so leaving 6 and 7 unmarked would drop the
            -- most important one.
            for i = 1, n_board do
                local card = result.board[i]
                local x = slotX(board_x, i)
                if isInCombo(card, eval.player_combo) then
                    outline(x, Y_BOARD, Theme.status.good, 2, 3)
                end
                if isInCombo(card, eval.dealer_combo) then
                    outline(x, Y_BOARD, Theme.status.error, -3, 3)
                end
            end
        end
    end

    -- The dealer's cheats, completing the seven-card line. Drawn after the
    -- highlight pass so each carries its own best-5 marking.
    self:_drawCheatCards(result, (revealed_idx > 0) and result
                                 and result.evals[revealed_idx] or nil)

    -- Hand labels. Solid status-colour pills with dark text so they stay
    -- legible over whatever is behind them.
    --
    -- They sit BESIDE the hole cards they describe, right-aligned into the clear
    -- felt left of the row and centred vertically on it. They used to sit between
    -- the card rows in a 22px band while measuring 54px tall (fonts.md line box +
    -- 2*pad_y), so each one painted over the top 26px of the row below it -- the
    -- middle board cards and both player hole cards, best-5 strokes included.
    if result and revealed_idx > 0 then
        local eval = result.evals[revealed_idx]
        if eval then
            local gutter = math.floor(24 * s)
            local function drawLabelPill(text, y, color)
                love.graphics.setFont(self.fonts.md)
                local fh     = self.fonts.md:getHeight()
                local pad_x  = 14
                local pad_y  = 6
                local pill_w = self.fonts.md:getWidth(text) + pad_x * 2
                local pill_h = fh + pad_y * 2
                -- Right edge lands a gutter clear of the cards; the pill grows
                -- leftward into the open felt, so a long hand name never reaches
                -- the row.
                local pill_x = math.max(gutter, hole_x - gutter - pill_w)
                Theme.setColor(color)
                love.graphics.rectangle("fill", pill_x, y, pill_w, pill_h, Theme.space.radius)
                Theme.setColor(Theme.border.strong)
                love.graphics.setLineWidth(2)
                love.graphics.rectangle("line", pill_x, y, pill_w, pill_h, Theme.space.radius)
                love.graphics.setLineWidth(1)
                Theme.setColor(Theme.bg.window)
                love.graphics.print(text, pill_x + pad_x, y + pad_y)
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
    -- DEMO_CUT only ever resolves R1 visually — R2 / R3 are gated to
    -- losses and never deal a 6th/7th card. So we render a single
    -- chip slot instead of the three-slot strip; the empty R2/R3
    -- slots would tip the player off that more is coming.
    local n_slots  = Constants.FEATURES.DEMO_CUT and 1 or 3
    local s        = (self.game.ui_scale) or 1
    local chip_w   = math.max(72, math.floor(110 * s))
    local chip_h   = math.max(28, math.floor(42  * s))
    local total_chip_w = n_slots * chip_w + math.max(0, n_slots - 1) * CARD_GAP
    local chip_x0 = math.floor(tableCenterX(W) - total_chip_w / 2)
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
