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
local Story                  = require("data.story")
local StoryView              = require("views.StoryView")
local FlightSystem           = require("services.FlightSystem")
local ChipFlight             = require("views.ChipFlight")
local Confetti               = require("services.Confetti")
local RollingValue           = require("services.RollingValue")
local IconText               = require("views.IconText")
local AnchorRegistry         = require("services.AnchorRegistry")
local Timeline               = require("services.Timeline")
local Decal                  = require("services.Decal")
local Button                 = require("views.Button")
local PaletteData            = require("data.theme")
local ClickFlash             = require("services.ClickFlash")

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
-- The pot no longer lives in a band above the dealer (it sits beside the
-- board), so the band collapses to a plain gap.
local POT_BAND_BASE_H = 8
local POT_BAND_H      = 10
-- The House poster and the slot the cards deal from, between the pot band
-- and the dealer's cards. Both derive from data/shove_style.house.
local Y_POSTER        = 0
local Y_SLOT          = 0
local POSTER_H        = 0
local SLOT_H          = 0

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
    local house = Style.house
    POSTER_H = house.enabled and math.floor(house.h * s) or 0
    SLOT_H   = house.enabled and math.floor(house.slot_h * s) or 0

    -- Every term here is a real span in the chain below. The previous version
    -- dropped the banner's trailing gap and used a hardcoded 36 for the result
    -- chips against a real 52, so it understated the stack by 26px and the whole
    -- gauntlet sat 13px above centre.
    local sm_h = (fonts and fonts.sm and fonts.sm:getHeight()) or 12
    local stack_h = lg_h + sm_h + gap   -- headline + prompt line
                  + POT_BAND_H + math.floor(28 * s)
                  + POSTER_H + SLOT_H + row_gap
                  + 3 * CARD_H + 2 * row_gap
                  + chip_gap + chip_h
    local top = math.max(8, math.floor((H - stack_h) / 2))

    Y_BANNER      = top
    -- The headline and its prompt, then clear air before the dealer's
    -- cards. This gap was the pot band; when the pot moved beside the
    -- board the band collapsed to 10px and the headline crowded the cards.
    Y_POT         = Y_BANNER + lg_h + sm_h + gap
    Y_POSTER      = Y_POT + POT_BAND_H + math.floor(28 * s)
    Y_SLOT        = Y_POSTER + POSTER_H
    Y_DEALER_HOLE = Y_SLOT + SLOT_H + row_gap
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

-- The FIVE BOARD CARDS are centred on the screen; the stats panel hangs off
-- their right. The whole seven-wide row used to be centred instead, which put
-- the board's midpoint 154px left of the screen's while the hole cards,
-- banner, poster and result chips all sat on tableCenterX. Two different
-- centre lines, and the felt read as a staircase.
local function rowOriginFor(screen_w)
    local board_w = 5 * CARD_W + 4 * CARD_GAP
    return math.floor((screen_w - board_w) / 2)
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
        -- Beat machine. A timeline event may be a HOLD: the clock stops
        -- there until the player advances it. `hold_id` names the current
        -- hold (nil when running) so hint conditions can key on the beat.
        -- `house_line` is what the House is currently saying, if anything.
        hold_id         = nil,
        house_line      = nil,
        -- Result staging, set by timeline beats: who the felt lights for,
        -- whether the pot pile has left, whether the summary is showing.
        winner          = nil,     -- nil | "player" | "dealer"
        winner_t        = 0,       -- seconds since the winner was lit (drives the lift)
        pot_gone        = false,
        summary_shown   = false,
        robbed          = false,
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

-- `milestone` is "act2" / "act3" / nil for the act this shove opens, and
-- `chips_banked` the {chip} pending from the run. Both are pushed here
-- rather than read later because the House speaks them mid-timeline.
function ShoveView:onGauntletBegin(milestone, chips_banked)
    local g = self.ss.gauntlet
    if not g or not g.result then return end
    self.milestone    = milestone
    self.chips_banked = chips_banked or 0

    self.elapsed        = 0
    self.card_anims     = {}
    self.chip_visible   = { false, false, false }
    self.ending         = false
    self.pile           = nil
    -- The beat machine is services/Timeline: the same engine the House's
    -- story beats run on everywhere else. This view mirrors its clock and
    -- hold into self.elapsed / self.hold_id / self.phase after each tick so
    -- every reader of those fields (the host's end gate, the hint ctx) is
    -- unchanged.
    self.timeline       = Timeline:new{
        on_sound = function(name) self.game.sounds.playNamed(name) end,
    }

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
        self.timeline:add(at, fn, sound)
    end

    -- A HOLD: the clock stops here until :advance(). The result stays on
    -- the felt for as long as the player wants to read it, which is the
    -- whole reason the modal that used to cover it is gone. Everything
    -- post-reveal derives from chip_visible + card_anims, not elapsed, so
    -- the held frame renders for free.
    local function hold(at, id)
        self.timeline:hold(at, id)
    end

    -- The House speaks. `line_id` keys data/story.lua's shove block; a once-line
    -- routes through hints_seen so it plays a single time per save.
    local function say(at, line_id)
        add(at, function() self:_say(line_id) end)
    end

    -- Light one side of the felt: the winner's cards stay bright with the
    -- best-5 stroke, the loser's fade. Both sides used to get equal-weight
    -- strokes, which is a diagram, not a result.
    local function light(at, who)
        add(at, function() self.winner = who; self.winner_t = 0 end)
    end

    -- The pot pile leaves the felt toward whoever won it. The money is
    -- SEEN going; before this the pile just sat there through a loss.
    local function potTo(at, who, sound)
        add(at, function() self:_potTo(who) end, sound)
    end

    -- `robbed` is sticky once set: the generic summary that precedes every
    -- result hold must not un-rob a shove the panic already marked.
    local function summary(at, robbed)
        add(at, function()
            self.summary_shown = true
            if robbed then self.robbed = true end
        end)
    end

    -- The dealer throws the catalog onto the felt. A BEAT, on the timeline,
    -- before the hold: it used to be created on the click that advanced the
    -- hold, so it arrived as a reaction to the player rather than as
    -- something the dealer did.
    local function throwCatalog(at)
        add(at, function()
            if self.ss and self.ss.throwCatalog then self.ss:throwCatalog() end
        end)
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

    -- The PLAYER's cards flip now: you know your own hand. The dealer's
    -- stay face-down through the whole board. They used to flip together
    -- here, before the flop, which meant the hand was already decided
    -- before a single board card came out and nothing after it could carry
    -- any tension. The dealer's flip is the showdown, at the end.
    add(t, startAnim("player_flip", "hole_card_flip"), "hole_card_flip")
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

    -- ── Showdown ──────────────────────────────────────────────────────
    -- One thing at a time, in the order the eye needs them:
    --   1. the dealer's cards turn over          (the reveal)
    --   2. the winning hand lights, the loser dims (who won)
    --   3. the result chip                          (WIN / LOSS, named)
    --   4. the pot leaves toward the winner         (what it cost / paid)
    --   5. the House, one line                      (only after the above)
    --   6. hold
    -- Nothing else is on screen at any of those moments. The summary and
    -- the catalog come after the hold, not with it.
    -- A held beat with the dealer's cards still down: the hesitation IS
    -- the tension. Then a slow turn.
    t = t + 0.85
    add(t, startAnim("dealer_flip", "showdown_flip"), "hole_card_flip")
    t = t + 1.15                                   -- flip lands, beat
    if r.outcomes[1] then
        light(t, "player")
        add(t + 0.60, showChip(1), chipSound(1))
        potTo(t + 1.00, "player", "chip_land_you")
        add(t + 1.30, function() self:_confetti() end)
        -- No line on a win. The won-hold is the House being SILENT because
        -- it is losing; that silence is what the panic then breaks. The
        -- confetti and the pot flying to the player are the headline.
    else
        light(t, "dealer")
        add(t + 0.60, showChip(1), chipSound(1))
        -- The pot is pushed up to the dealer over Style.pot.take_secs; the
        -- House does not speak until the money has left.
        potTo(t + 1.00, "house", "chip_land_pot")
        say(t + 1.00 + (Style.pot.take_secs or 1) + 0.5, "loss")
        t = t + (Style.pot.take_secs or 1)
    end

    -- Demo cut stops here — R2 / R3 (the dealer's cheats) stay
    -- unrevealed, so first-time players never see the 6th community
    -- card or the second chip slot. Win → prototype-end modal; loss
    -- → standard prestige. R2 / R3 visuals run when DEMO_CUT is off.
    if r.outcomes[1] and not Constants.FEATURES.DEMO_CUT then
        -- ── The panic ─────────────────────────────────────────────────
        -- The player just WON a runout, and the felt says so: their cards
        -- lit, the pot flying to them, confetti. Hold there. The House's
        -- silence is the beat: it has nothing to say because it is
        -- losing. Then the player clicks, and it finds something.
        --
        -- This used to be RUNOUT_PAUSE + CHEAT_PAUSE of nothing, then a
        -- card. Three seconds of a still screen, which read as a hang.
        -- The timing slot is the same; it is no longer empty.
        t = t + 1.2
        hold(t, "won")
        t = t + 0.0
        say(t + 0.10, "panic_wait")
        say(t + 0.95, "panic_won")
        -- The pile stops. The flight the win started is cleared mid-air
        -- and the pot is simply gone: the House has it.
        add(t + 1.60, function() FlightSystem.clear(); self.pot_gone = true end)
        say(t + 1.90, "panic_no")
        -- Card 6 comes out of the slot and lands on BASE. The readout's
        -- catalog term is buried and the bar drains.
        add(t + 2.50, startAnim("board_6", "cheat_card_dealt"), "cheat_card_dealt")
        say(t + 3.10, "panic_new_card")
        t = t + 3.70

        add(t, showChip(2), chipSound(2))
        if r.outcomes[2] then
            light(t + 0.05, "player")
            add(t + 0.40, function() self:_confetti() end)
            -- Twice. The House is past surprise and into spite.
            t = t + 1.2
            hold(t, "won")
            say(t + 0.10, "panic_again")
            add(t + 1.20, function() FlightSystem.clear(); self.pot_gone = true end)
            say(t + 1.50, "panic_no_more")
            add(t + 2.20, startAnim("board_7", "cheat_card_dealt"), "cheat_card_dealt")
            t = t + 3.20

            add(t, showChip(3), chipSound(3))
            if r.outcomes[3] then
                -- Full clear. He does not believe it. Another card has always
                -- worked, so: another card. The rest of the deck, one after
                -- another, every one still a win, until the felt and then
                -- the screen are buried. Then credits, over the pile.
                light(t + 0.05, "player")
                potTo(t + 0.10, "player", "chip_land_you")
                add(t + 0.40, function() self:_confetti() end)
                add(t + 0.90, function() self:_confetti() end)
                t = self:_scheduleEnding(t, add, say)
            else
                light(t + 0.05, "dealer")
                summary(t + 0.80, true)
                -- (The act 3 lede plays on the grind: story beat "act3".)
            end
        else
            -- Robbed at runout 2. This is the common Act 2 shove and the
            -- one an act lede lands on.
            light(t + 0.05, "dealer")
            summary(t + 0.80, true)
            -- (The act 2 lede plays on the grind: story beat "act2".)
        end
    end

    -- The result holds on the felt until the player advances. It used to
    -- be a 2.0s timer and then a modal over the cards: the answer to
    -- "why did I lose" was covered before it could be read.
    -- The summary gets its own beat after everything else has settled, then
    -- the hold. Nothing arrives at the same instant as anything else.
    if self.ending then
        -- No summary, no catalog, no hold: the ending carries itself to
        -- credits. `t` is the end of the curtain.
        self.total_duration = t
        return
    end
    summary(t + 2.6)
    throwCatalog(t + 3.4)
    hold(t + 3.6, "result")
    self.total_duration = t + 3.6
end

-- ─── The ending ───────────────────────────────────────────────────────

-- Seconds until the next card, by card index (data/shove_style ending).
local function endingInterval(i)
    for _, band in ipairs(Style.ending.intervals) do
        if i <= band.upto then return band.secs end
    end
    return Style.ending.intervals[#Style.ending.intervals].secs
end

-- Lay the rest of the deck onto the timeline. Returns the time the
-- curtain ends (the caller makes it total_duration). `t` is when chip 3
-- landed.
function ShoveView:_scheduleEnding(t, add, say)
    local E = Style.ending
    self.ending      = true
    self.pile        = {}
    self.extra_dealt = 0
    -- The real remaining deck: 41 cards after 4 hole, 5 board, 2 cheats.
    -- Stashed now; the host nils the gauntlet once the ending is over.
    local deck = self.ss and self.ss.gauntlet and self.ss.gauntlet.deck
    self.extra_cards = (deck and deck.remaining and deck:remaining()) or {}

    say(t + 0.9, "deck_no")
    local tt = t + 1.5
    local lines = { [9] = "deck_again", [10] = "deck_doesnt", [11] = "deck_deal", [12] = "deck_all" }
    local last_i = 7 + math.max(#self.extra_cards, 45)
    for i = 8, last_i do
        local idx = i
        if lines[i] then say(tt - 0.6, lines[i]) end
        add(tt, function() self:_dealExtra(idx) end)
        tt = tt + endingInterval(i)
    end
    local t_last = tt - endingInterval(last_i) + (E.flight_secs or 0.55)
    say(t_last + 0.8, "deck_out")
    add(t_last + 0.8, function() self.pot_gone = true end)
    return t_last + 0.8 + (E.curtain_secs or 2.6)
end

-- Where card i (8..52) lands. The first few extend the board row outward,
-- alternating sides, so the readout and the hand names go under first;
-- after that anywhere on the felt, and past card 30 anywhere on the
-- screen. Hashed from the index, so a replay lands the same way.
function ShoveView:_pileTarget(i)
    local E  = Style.ending
    local W, H = love.graphics.getDimensions()
    local k  = i - 7
    if i <= (E.spread_rows or 12) then
        local origin = rowOriginFor(W)
        local step   = math.ceil(k / 2)
        local x = (k % 2 == 1) and (slotX(origin, 5) + step * (CARD_W + CARD_GAP))
                                 or (slotX(origin, 1) - step * (CARD_W + CARD_GAP))
        local _, _, angle = Decal.place("pile:" .. i, { angle = 0.12 })
        return x, Y_BOARD, angle
    end
    local x0, x1, y0, y1
    if i <= 30 then
        x0, x1 = 0, W - CARD_W
        y0, y1 = Y_DEALER_HOLE - 40, Y_PLAYER_HOLE + 40
    else
        x0, x1 = -CARD_W * 0.3, W - CARD_W * 0.7
        y0, y1 = -CARD_H * 0.3, H - CARD_H * 0.7
    end
    local x = Decal.lerp("pile_x:" .. i, 1, x0, x1)
    local y = Decal.lerp("pile_y:" .. i, 2, y0, y1)
    local _, _, angle = Decal.place("pile:" .. i, { angle = E.max_angle or 0.6 })
    return x, y, angle
end

-- Deal card i: fly it from the top of the screen to its spot, tumbling,
-- and land it on the pile. `_land_now` (skip) lands it without the flight.
function ShoveView:_dealExtra(i)
    local E    = Style.ending
    local card = self.extra_cards and self.extra_cards[i - 7]
    local x, y, angle = self:_pileTarget(i)
    local landed = false
    local function land()
        if landed then return end
        landed = true
        self.pile[#self.pile + 1] = { card = card, x = x, y = y, angle = angle }
        self.extra_dealt = (self.extra_dealt or 0) + 1
        -- Still a win. The lift re-fires and the cards glow again.
        self.winner   = "player"
        self.winner_t = 0
        if self.game.sounds and self.game.sounds.playNamed then
            self.game.sounds.playNamed("cheat_card_dealt")
        end
        local k = i - 7
        if i <= (E.confetti_first or 17) or k % (E.confetti_every or 5) == 0 then
            Confetti.burst({ math.floor(x + CARD_W / 2), math.floor(y + CARD_H / 2) },
                           E.confetti_count or 14, { duration = 1.2 })
        end
    end
    if self._land_now then land(); return end

    local sl = self.game.sprite_loader
    local name = card and card.spriteName and card:spriteName()
    local W = love.graphics.getWidth()
    local from = { math.floor(tableCenterX(W)), (Style.house.deal_from_y or -180) }
    local to   = { x + CARD_W / 2, y + CARD_H / 2 }
    local function face(px, py)
        if not name then return end
        CardSprites.shadow(px - CARD_W / 2, py - CARD_H / 2, CARD_W, CARD_H, 1, ShoveDecor.shadowOffset())
        CardSprites.sprite(sl, name, px - CARD_W / 2, py - CARD_H / 2, CARD_W, CARD_H, 1, 1)
    end
    -- One full spin and one full flip so the card lands face-up at its
    -- resting angle: at t = 1 the tumble frame is exactly `angle`.
    local fn = Tumble.wrap(face, { axis = angle, spins = 1, flips = 1, phase = 0, loft = 0.15, spin_dir = 1 })
    FlightSystem.emit(from, to, fn, {
        duration   = E.flight_secs or 0.55,
        arc_height = E.flight_arc or 120,
        on_arrive  = land,
    })
end

-- The pile, in deal order, each card at its resting angle.
function ShoveView:_drawPile()
    if not self.pile or #self.pile == 0 then return end
    local sl = self.game.sprite_loader
    for _, p in ipairs(self.pile) do
        local name = p.card and p.card.spriteName and p.card:spriteName()
        if name then
            love.graphics.push()
            love.graphics.translate(p.x + CARD_W / 2, p.y + CARD_H / 2)
            love.graphics.rotate(p.angle or 0)
            CardSprites.shadow(-CARD_W / 2, -CARD_H / 2, CARD_W, CARD_H, 1, ShoveDecor.shadowOffset())
            CardSprites.sprite(sl, name, -CARD_W / 2, -CARD_H / 2, CARD_W, CARD_H, 1, 1)
            love.graphics.pop()
        end
    end
end

-- The last frame of the ending, for credits to fade in over.
function ShoveView:snapshot()
    local W, H = love.graphics.getDimensions()
    local ok, canvas = pcall(love.graphics.newCanvas, W, H)
    if not ok or not canvas then return nil end
    local prev = love.graphics.getCanvas()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    self:draw()
    FlightSystem.draw()
    love.graphics.setCanvas(prev)
    return canvas
end

-- True while the host must wait: the buildup, the deal, and every hold.
-- ShoveState's end gate reads this, so a hold defers the post-shove chain
-- until the player advances it, with no change to the gate itself.
function ShoveView:isAnimating()
    if self.phase == "buildup" or self.phase == "ready_to_deal"
       or self.phase == "hold" then
        return true
    end
    return self.timeline ~= nil and self.elapsed < self.total_duration
end

function ShoveView:isHolding()
    return self.phase == "hold"
end

-- The player moved on from a hold. Pops it, clears the House's line, and
-- lets the clock run into whatever follows.
function ShoveView:advance()
    if self.phase ~= "hold" then return false end
    if self.timeline then self.timeline:advance() end
    self.phase      = "running"
    -- A mid-sequence hold clears the line: the next beat speaks. The
    -- RESULT hold keeps it, because the catalog rises beneath the headline
    -- and the top band must not go empty at the moment the player acts.
    if self.hold_id ~= "result" then self.house_line = nil end
    self.hold_id    = nil
    return true
end

-- Set the House's current line from data/story.lua's shove block.
-- Once-lines are gated on story_seen["shove:<id>"] and marked there when
-- they play, alongside the story beats.
function ShoveView:_say(line_id)
    local spec = Story.shove[line_id]
    if not spec then return end
    if spec.once then
        local seen = self.game.state and self.game.state.story_seen
        local key  = "shove:" .. line_id
        if seen and seen[key] then return end
        if seen then seen[key] = true end
    end
    self.house_line = spec.text
end

-- How many cheat cards are on the felt this shove. Read by the host for the
-- `cheat_dealt` hint kind, which is what stops a cheat hint from firing
-- before the card exists.
function ShoveView:cheatsDealt()
    local n = 0
    if self.card_anims.board_6 then n = n + 1 end
    if self.card_anims.board_7 then n = n + 1 end
    return n
end

function ShoveView:resetTimeline()
    self.timeline       = nil
    self.elapsed        = 0
    self.total_duration = 0
    self.card_anims     = {}
    self.chip_visible   = { false, false, false }
    -- Drop buildup state so the next ShoveState:enter starts clean.
    self.phase          = "idle"
    self.phase_t        = 0
    self.hold_id        = nil
    self.house_line     = nil
    self.winner         = nil
    self.winner_t       = 0
    self.pot_gone       = false
    self.summary_shown  = false
    self.robbed         = false
    self.ending         = false
    self.pile           = nil
    self.extra_cards    = nil
    self.extra_dealt    = 0
    RollingValue.reset("shove:allin")
    self.buildup_rates  = nil
    self.buildup_chip_count_shown = 0
end

function ShoveView:skip()
    -- Buildup-skip: jump to ready-to-deal so the host fires the gauntlet
    -- on its next update tick. Player wanted out of the buildup spectacle.
    if self.phase == "buildup" then
        self.phase   = "ready_to_deal"
        -- Was `BUILDUP_TOTAL`, a global that was never defined; it set
        -- phase_t to nil and only failed to crash because ShoveState flips
        -- to "running" before the next draw reads it.
        self.phase_t = self.buildup_total or 0
        return
    end
    if self.phase == "hold" then self:advance(); return end
    if not self.timeline then return end
    -- Fire remaining events, sounds suppressed, up to and INCLUDING the
    -- next hold, then stop there. A skip lands the player on the next
    -- thing worth reading, never past it. During the ending the remaining
    -- cards land where they were going, no flight, so a skip gives the
    -- buried screen and not a half-dealt one.
    self._land_now = self.ending or nil
    self.timeline:skip()
    self._land_now = nil
    self:_mirrorTimeline()
    for _, anim in pairs(self.card_anims) do
        if anim.update then anim:update(10) end
    end
    if self.phase ~= "hold" then
        self.elapsed = self.total_duration
        self.timeline:seek(self.total_duration)
    end
end

-- Copy the engine's clock and hold into the fields this view and its host
-- read. Called after every tick of the timeline.
function ShoveView:_mirrorTimeline()
    local tl = self.timeline
    self.elapsed = tl.elapsed
    if tl:isHolding() then
        self.phase   = "hold"
        self.hold_id = tl:holdId()
    elseif self.phase == "hold" then
        self.phase   = "running"
        self.hold_id = nil
    end
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
    -- Card anims keep ticking during a hold (a mid-flip card should land),
    -- but the clock does not, so nothing after the hold fires.
    if self.winner then self.winner_t = self.winner_t + dt end
    self.timeline:update(dt)
    self:_mirrorTimeline()

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
-- Where a dealing card is right now: it leaves the slot under the House
-- poster and eases to its seat over the deal anim's progress. With the
-- House disabled (the golden harness) the card just sits at its target.
local function dealPos(anim, target_x, target_y, slot_cx)
    local house = Style.house
    if not anim or not anim.getProgress then return target_x, target_y end
    local p = anim:getProgress() or 1
    local e = 1 - (1 - p) ^ (house.deal_ease or 3)
    local from_x = slot_cx - CARD_W / 2
    -- From the slot under the poster when there is one; otherwise from
    -- above the felt, where the dealer's hands would be.
    local from_y = house.enabled and (Y_SLOT - CARD_H + SLOT_H)
                   or (house.deal_from_y or -CARD_H)
    return from_x + (target_x - from_x) * e, from_y + (target_y - from_y) * e
end

-- `verdict` is nil (no result yet), "win" or "lose" for this card. A
-- winning card rises and gets a warm halo; a losing card sinks a little and
-- is drawn at the loser alpha the caller already applied. This is the whole
-- of how the felt says who won. There is no label that does it.
local function drawCardSprite(sl, sprite_name, x, y, w, h, scale_x, alpha, verdict, lift_p)
    local ew  = w * (scale_x or 1)
    local cfg = Style.cards
    local dy  = 0
    if verdict == "win" then
        dy = -math.floor((cfg.lift_px or 0) * (lift_p or 0))
        -- Halo: expanding rounded rects behind the card, ramping with the lift.
        local a = (cfg.glow_alpha or 0) * (lift_p or 0)
        if a > 0.005 then
            for i = (cfg.glow_steps or 1), 1, -1 do
                local g = (cfg.glow_grow or 0) * i / (cfg.glow_steps or 1)
                Theme.setColor(Theme.data.amber, a * (1 - (i - 1) / (cfg.glow_steps or 1)))
                love.graphics.rectangle("fill", x - g, y + dy - g, w + 2 * g, h + 2 * g,
                                        Theme.space.radius + g)
            end
        end
    elseif verdict == "lose" then
        dy = math.floor((cfg.lift_px or 0) * 0.4 * (lift_p or 0))
    end
    CardSprites.shadow(x + (w - ew) / 2, y + dy, ew, h, alpha, ShoveDecor.shadowOffset())
    CardSprites.sprite(sl, sprite_name, x, y + dy, w, h, scale_x, alpha)
end

local function visibleBoardCount(g)
    if not g or not g.result then return 0 end
    local r = g.result
    if r.outcomes[2] == nil then return 5 end
    if r.outcomes[3] == nil then return 6 end
    return 7
end

-- (bannerFor is gone. It produced a headline that changed style and words
-- at the reveal: a dim ALL-IN, then BUSTED in the largest font. The band
-- above the table now holds one line the beats set, drawn one way.)

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
    local pot_cx, pot_cy = self:_potPos()
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
        Chips.drawStack(stack_cx, stack_cy, waiting_indices,
            { align = "center" })
    end

    -- Pot pile centered in the pot band. Just the chip visual — the
    -- pile itself reads as "this is the pot".
    if #arrived_indices > 0 or in_lock then
        self:_drawPot(arrived_indices)
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

    -- The lock-in flash: a white blink when the last chip lands. That is
    -- all that survives of the old finale. The red mid-screen "ALL IN" pop,
    -- "PUSHING ALL IN…" at the top and "YOUR STACK" at the bottom were
    -- three more strings appearing and vanishing on a screen that already
    -- had four. The band above the table carries ONE line now, and holds
    -- it: it changes words, it never blinks out.
    if in_lock then
        local lock_progress = math.min(1, lock_t / BUILDUP_LOCK_DURATION)
        local flash_alpha = math.max(0, 0.45 * (1 - lock_progress * 2))
        if flash_alpha > 0 then
            Theme.setColor(Theme.fg.heading, flash_alpha)
            love.graphics.rectangle("fill", 0, 0, W, H)
        end
    end
    if fade_t > 0.4 then
        self.house_line = Story.shove[in_lock and "arrive" or "pushing"].text
        self:_drawHeadline(W)
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
    -- BASE is a count of things (each catalog item is one; the readout's
    -- units are 1/100 of the rate, which is exactly one item), not a %.
    put(6, "base", string.format("BASE %d", base_pct))
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
    printCentered("all in", fonts.md, px, ty2 + lg_h, pw)

    -- The drain bar. Eased toward the live total so a buried term is a
    -- visible fall, not a number that is suddenly different.
    local mcfg  = Style.meter
    local md_h  = fonts.md:getHeight()
    local bar_y = ty2 + lg_h + md_h + mcfg.gap
    local shown = RollingValue.get("shove:allin", total_pct, mcfg.rate)
    ShoveDecor.drawMeter(px, bar_y, pw, mcfg.h, shown / 100, shown > 100)

    -- Hint targets: the whole readout, and the bar on its own.
    AnchorRegistry.set("shove:readout", px, ty, pw, (bar_y + mcfg.h) - ty)
    AnchorRegistry.set("shove:meter",   px, bar_y, pw, mcfg.h)
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
            local dx, dy = dealPos(anim, x, Y_BOARD, tableCenterX(love.graphics.getWidth()))
            local v = self:_verdictFor(card, eval)
            if v == "lose" then alpha = alpha * (Style.cards.loser_alpha or 1) end
            drawCardSprite(self.game.sprite_loader, card:spriteName(),
                           dx, dy, CARD_W, CARD_H, 1, alpha, v, self:_liftP())
            -- Registered only once the card exists, which is what keeps a
            -- hint about it from firing before the player has seen it.
            AnchorRegistry.set("shove:cheat_" .. i, dx, dy, CARD_W, CARD_H)
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
    local flip = self.card_anims.dealer_flip
    if not flip or (flip.getProgress and flip:getProgress() < 1) then return 0 end
    return idx
end

-- Where the pot sits: left of the board, centred on the board row. One
-- function, because three places used to compute it independently and the
-- buildup landed chips somewhere the cinematic then drew them elsewhere.
-- Returns the pile's BASE point (drawStack centres a pile on x and grows
-- upward from y).
function ShoveView:_potPos()
    local W      = love.graphics.getWidth()
    local cfg    = Style.pot
    local origin = rowOriginFor(W)
    -- Centre the pile in the open felt between the screen's left edge and
    -- the board, rather than a fixed gap off the board: a 30-chip pile at
    -- 1.6x is ~310px wide, and a gap sized for a small pile ran it into
    -- slot 1.
    local cx     = math.floor((origin - cfg.gap) / 2)
    local cy     = Y_BOARD + math.floor(CARD_H * 0.78)
    return cx, cy
end

-- Draw the pot pile, scaled up, at _potPos. views/Chips draws under a
-- transform the way the felt already does; the label plate cancels the
-- caller's scale so the pixel font stays on its grid.
function ShoveView:_drawPot(chip_indices)
    if not chip_indices or #chip_indices == 0 then return end
    local cx, cy = self:_potPos()
    local k = Style.pot.scale or 1
    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.scale(k, k)
    Chips.drawStack(0, 0, chip_indices, { align = "center", max_cols = Style.pot.max_cols })
    love.graphics.pop()
end

-- Alpha for a card on the resolved felt: the loser's side fades. `side` is
-- "player" or "dealer"; nil winner (mid-deal) means full alpha.
-- Lift progress 0..1 since the winner was lit.
function ShoveView:_liftP()
    if not self.winner then return 0 end
    local p = math.min(1, self.winner_t / (Style.cards.lift_secs or 0.5))
    return 1 - (1 - p) ^ 3
end

-- Whether `card` is in the WINNER's best five ("win"), in the loser's
-- ("lose"), or neither (nil) once a side is lit.
function ShoveView:_verdictFor(card, eval)
    if not self.winner or not eval then return nil end
    local wc = (self.winner == "player") and eval.player_combo or eval.dealer_combo
    local lc = (self.winner == "player") and eval.dealer_combo or eval.player_combo
    if isInCombo(card, wc) then return "win" end
    if isInCombo(card, lc) then return "lose" end
    return nil
end

function ShoveView:_sideAlpha(side)
    if not self.winner or self.winner == side then return 1 end
    return Style.cards.loser_alpha or 1
end

function ShoveView:_drawHoleCard(card, slot_x, slot_y, deal_key, side)
    local sl = self.game.sprite_loader
    -- Active-deck override for the gauntlet hole-card back. Falls back
    -- to the constant default when the deck system hasn't unlocked or
    -- the active spec is missing, so pre-clear builds render cleanly.
    local back = (Decks.systemUnlocked(self.game.state)
                  and Decks.activeSprite(self.game.state))
                 or Constants.GAUNTLET.CARD_BACK_SPRITE
    local front = card:spriteName()
    local deal_anim = self.card_anims[deal_key]
    -- Each side has its own flip. The player's fires on the deal, the
    -- dealer's at the showdown.
    local flip_anim = self.card_anims[(side == "dealer") and "dealer_flip" or "player_flip"]

    if not deal_anim then return end

    local deal_alpha = (deal_anim.getAlpha and deal_anim:getAlpha() or 1)
                       * self:_sideAlpha(side)
    slot_x, slot_y = dealPos(deal_anim, slot_x, slot_y,
                             tableCenterX(love.graphics.getWidth()))

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
        local result = self.ss.gauntlet and self.ss.gauntlet.result
        local eval = result and result.evals[self:_revealedRunoutIdx()]
        drawCardSprite(sl, front, slot_x, slot_y, CARD_W, CARD_H, sx, deal_alpha,
                       self:_verdictFor(card, eval), self:_liftP())
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
    x, y = dealPos(anim, x, y, tableCenterX(love.graphics.getWidth()))
    local eval = result.evals[self:_revealedRunoutIdx()]
    local v = self:_verdictFor(card, eval)
    if v == "lose" then alpha = alpha * (Style.cards.loser_alpha or 1) end
    drawCardSprite(sl, card:spriteName(), x, y, CARD_W, CARD_H, 1, alpha, v, self:_liftP())
end

-- The ONE line in the band above the table. Set by the beats (the
-- buildup, the deal, the House at the reveal) and drawn the same way every
-- time. Nothing else prints in this band.
-- The same rect the grind's SHOVE button occupies (views/GrindView
-- _shoveButtonRect): bottom-right, RIGHT_W = max(320, 22% of W) wide less
-- margins, 64*s tall. Kept numerically identical rather than shared so this
-- view does not require the grind view.
function ShoveView:_continueRect()
    local W, H = love.graphics.getDimensions()
    local s = self.game.ui_scale or 1
    local right_w = math.max(320, math.floor(W * 0.22))
    local margin  = math.floor(12 * s)
    local h       = math.floor(64 * s)
    return { x = W - right_w + margin, y = H - h - margin, w = right_w - 2 * margin, h = h }
end

-- True if (x, y) is on the CONTINUE / LEAVE button while a hold is up.
function ShoveView:hitContinue(x, y)
    if not self:isHolding() then return false end
    local r = self:_continueRect()
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- The band above the table. Registered as the story band so a beat that
-- plays on this screen (the catalog, deck select) speaks from the same
-- slot; while one is running, its line owns the band and this view's
-- line waits underneath.
function ShoveView:_bandRect(W)
    return { x = math.floor(tableCenterX(W) - W / 3), y = Y_BANNER,
             w = math.floor(2 * W / 3), h = self.fonts.lg:getHeight() }
end

function ShoveView:_drawHeadline(W)
    local r = self:_bandRect(W)
    AnchorRegistry.set("story:band", r.x, r.y, r.w, r.h)
    if not self.house_line then return end
    local story = self.game.story
    if story and story.isActive and story:isActive() then return end
    StoryView.drawLine(self.game, self.house_line, r)
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

    -- The pot, beside the board. Same chip list the buildup arrived with,
    -- at the same spot, so the pile does not move when the cards take over.
    local pot_cx, pot_cy = self:_potPos()
    local pr = math.floor(CARD_W * Style.pot.scale * 0.5)
    AnchorRegistry.set("shove:pot", pot_cx - pr, pot_cy - pr, pr * 2, pr * 2)
    if not self.pot_gone and self.buildup_chips and #self.buildup_chips > 0 then
        local chip_indices = {}
        for i, c in ipairs(self.buildup_chips) do
            chip_indices[i] = c.denom_idx
        end
        self:_drawPot(chip_indices)
    end
end

-- The pot pile flies to whoever won it and the static pile stops drawing.
-- Chips are the ones the buildup poured in, so the pile that leaves is the
-- pile that arrived.
function ShoveView:_potTo(who)
    if self.pot_gone or not self.buildup_chips then return end
    local W = love.graphics.getWidth()
    local denoms = {}
    for i, c in ipairs(self.buildup_chips) do denoms[i] = c.denom_idx end
    local px, py = self:_potPos()
    local src = { px, py - math.floor(CARD_H * 0.3) }
    -- On a loss the pile is pushed UP and off the top of the felt, toward
    -- the dealer: it is taken, slowly. On a win it comes down to the
    -- player's cards.
    local dest = (who == "player")
        and { math.floor(tableCenterX(W)), Y_PLAYER_HOLE + math.floor(CARD_H / 2) }
        or  { math.floor(tableCenterX(W)), -CARD_H }
    local cfg = Style.pot
    ChipFlight.flyChipsList(src, dest, denoms, {
        max_per_event = #denoms,
        duration      = cfg.take_secs,
        stagger       = cfg.take_stagger,
        arc_height    = cfg.take_arc,
        arrival_sound = (who == "player") and "chip_land_you" or nil,
    })
    self.pot_gone = true
end

function ShoveView:_confetti()
    local W = love.graphics.getWidth()
    Confetti.burst({ math.floor(tableCenterX(W)), Y_PLAYER_HOLE + math.floor(CARD_H / 2) },
                   40, { duration = 1.6 })
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
    -- The RAIL frames the card rows, where it was: that split the screen
    -- well. What was wrong was the felt stopping at the rail with a hard cut
    -- to black outside it. The felt now covers the whole screen; the rail
    -- is a frame on it, not the edge of it.
    local felt_top    = Y_DEALER_HOLE - 40
    local felt_height = (Y_PLAYER_HOLE + CARD_H + 40) - felt_top
    ShoveDecor.drawBackdrop({
        x = 0, y = felt_top, w = W, h = felt_height,
        screen_w = W, screen_h = H,
        felt_everywhere = true,
        -- The light stays on the CARDS, not the felt: a glow sized off a
        -- full-screen felt would be a flat wash with nothing to light.
        glow_y = Y_DEALER_HOLE - 20,
        glow_h = (Y_PLAYER_HOLE + CARD_H + 20) - (Y_DEALER_HOLE - 20),
    })

    -- The House, above the dealer's seat, with the slot the cards come out
    -- of. Drawn in every phase including the buildup so the House can
    -- speak as the chips arrive.
    if Style.house.enabled then
        local pw  = 2 * CARD_W + CARD_GAP
        local prx = math.floor(tableCenterX(W) - pw / 2)
        local pr  = { x = prx, y = Y_POSTER, w = pw, h = POSTER_H, s = s }
        ShoveDecor.drawHousePoster(pr, SLOT_H)
        AnchorRegistry.set("house", pr.x, pr.y, pr.w, pr.h)
    end


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
    -- The band holds the buildup's "All in." through the deal; the House's
    -- line replaces it at the reveal. Same slot, same font, same colour, so
    -- a change of line reads as the line changing, never as text vanishing.
    if not self.house_line then self.house_line = Story.shove.arrive.text end

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
        self:_drawHoleCard(result.player_hole[1], hole_x,                     Y_PLAYER_HOLE, "ph_1", "player")
        self:_drawHoleCard(result.player_hole[2], hole_x + CARD_W + CARD_GAP, Y_PLAYER_HOLE, "ph_2", "player")
        self:_drawHoleCard(result.dealer_hole[1], hole_x,                     Y_DEALER_HOLE, "dh_1", "dealer")
        self:_drawHoleCard(result.dealer_hole[2], hole_x + CARD_W + CARD_GAP, Y_DEALER_HOLE, "dh_2", "dealer")
    end

    -- Who won is in the cards themselves (drawCardSprite lifts and warms
    -- the winning five, sinks the losing five). There used to be a stroke
    -- pass here painting green and red borders on both hands at once; the
    -- lift replaces it, because a diagram of two hands is not a result.
    local revealed_idx = self:_revealedRunoutIdx()

    -- The dealer's cheats, completing the seven-card line. Drawn after the
    -- highlight pass so each carries its own best-5 marking.
    self:_drawCheatCards(result, (revealed_idx > 0) and result
                                 and result.evals[revealed_idx] or nil)

    -- The hand name: one line of plain muted text under the WINNING hole
    -- cards. A caption, not a label. The red and green pills that used to
    -- flank the felt were form-field chrome from the prototype; a box with
    -- a border and inverted text is the loudest thing a UI can draw, and
    -- it was being used to restate what the cards already show.
    -- BOTH hands are named, beside their rows in the clear felt left of the
    -- cards. The winner's name is bright and lifts with its cards; the
    -- loser's is muted and sinks. Reading which hand beat which needs both
    -- names on the felt; a single caption told the player the answer
    -- without the question.
    if result and revealed_idx > 0 and self.winner then
        local eval = result.evals[revealed_idx]
        if eval then
            local lift_p = self:_liftP()
            local lift   = math.floor((Style.cards.lift_px or 0) * lift_p)
            local gutter = math.floor(28 * (self.game.ui_scale or 1))
            local f      = self.fonts.md
            love.graphics.setFont(f)
            local function name(side, rank, row_y)
                local text = HandEval.describe(rank)
                local won  = (self.winner == side)
                local dy   = won and -lift or math.floor(lift * 0.4)
                local y    = row_y + dy + math.floor((CARD_H - f:getHeight()) / 2)
                if won then
                    Theme.setColor(Theme.fg.heading, lift_p)
                else
                    Theme.setColor(Theme.fg.muted, 0.35 + 0.35 * (1 - lift_p))
                end
                love.graphics.print(text, hole_x - gutter - f:getWidth(text), y)
            end
            name("dealer", eval.dealer_rank, Y_DEALER_HOLE)
            name("player", eval.player_rank, Y_PLAYER_HOLE)
        end
    end

    -- In-flight chips and confetti. FlightSystem is drawn in exactly one
    -- other place, the grind view; without this line a flight emitted here
    -- ticks invisibly and pops into existence back on the grind.
    FlightSystem.draw()

    -- There is no WIN / LOSS strip. It said the same thing as the cards a
    -- third time, in a red box, and it was the ugliest thing on the screen.
    -- The chip_visible flags still gate the reveal logic; they just no
    -- longer draw anything.
    local s2 = self.game.ui_scale or 1
    AnchorRegistry.set("shove:chips", math.floor(tableCenterX(W)) - 100, Y_CHIPS, 200, 8)

    -- The run summary: the {chip} count, large, alone. The one thing on the
    -- felt with weight, because it is the one thing the player keeps.
    if self.summary_shown and Style.summary.enabled then
        local fonts = self.fonts
        local tcx   = math.floor(tableCenterX(W))
        -- BELOW the bottom rail, in the open felt under the frame. The rail
        -- is at Y_PLAYER_HOLE + CARD_H + 40 and 17px tall; the summary is
        -- 84px tall, so "inside the rail" was on it.
        local sy    = Y_PLAYER_HOLE + CARD_H + 40 + 17 + Style.summary.gap
        local n     = self.chips_banked or 0
        love.graphics.setFont(fonts.sm)
        Theme.setColor(Theme.fg.faint)
        printCentered(n > 0 and "BANKED" or "NOTHING BANKED", fonts.sm, tcx - 200, sy, 400)
        local line_y = sy + fonts.sm:getHeight()
        if n > 0 then
            local txt = string.format("{chip} %d", n)
            local tw  = IconText.measure(txt, fonts.lg)
            IconText.draw(self.game, txt, tcx - math.floor(tw / 2), line_y,
                          fonts.lg, Theme.fg.heading, 1)
            line_y = line_y + fonts.lg:getHeight()
        end
        AnchorRegistry.set("shove:summary", tcx - 200, sy, 400, line_y - sy)
    end

    self:_drawHeadline(W)

    -- The ending's pile buries everything drawn above, the headline
    -- included; the cards still in the air stay on top of the pile.
    if self.ending then
        self:_drawPile()
        FlightSystem.draw()
    end

    -- Leaving is a deliberate act on a button, never a stray click on the
    -- felt. The button is the grind's SHOVE button: same rect, same face,
    -- same red, in the same corner, so the hand that pressed SHOVE to get
    -- here presses the same spot to leave. On the mid-sequence hold it
    -- reads CONTINUE; on the result hold it reads LEAVE, because the
    -- catalog is on the felt and "continue" would not say which.
    if self:isHolding() then
        local r = self:_continueRect()
        AnchorRegistry.set("btn:continue", r.x, r.y, r.w, r.h)
        local mx, my = love.mouse.getPosition()
        local hov = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
        -- The grind's SHOVE button uses Theme.status.error, and so did
        -- this one, but the same token is a different colour under each
        -- palette: the grind's is the room palette's soft pink, this
        -- screen's is the shove palette's alarm red. Read the ROOM
        -- palette's tokens directly so the two buttons are the same colour.
        local room = PaletteData.palettes.room
        local label = "CONTINUE"
        Button.draw(r.x, r.y, r.w, r.h, {
            fill_color   = room.status.error,
            border_color = room.fg.heading,
            line_width   = Theme.space.line_strong,
            hovered      = hov,
            press_alpha  = ClickFlash.alpha("continue_btn", "continue_btn"),
            depth        = 5,
        }, function(fx, fy, fw, fh)
            local f = self.fonts.lg
            love.graphics.setFont(f)
            Theme.setColor(room.fg.heading)
            printCentered(label, f, fx, fy + math.floor((fh - f:getHeight()) / 2), fw)
        end)
    end
end

return ShoveView
