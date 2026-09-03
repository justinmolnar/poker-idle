-- models/Table.lua
--
-- A single ticking poker table. Per-hand state machine: the player clicks
-- DEAL, the outcome is rolled at deal-time from the 3-distribution outcome
-- model, then cards are constructed via rejection sampling so what's drawn
-- matches the rolled win/lose. Animation timeline plays over ~2.2 seconds,
-- ending in settling that returns the resolution to the controller.
--
-- ─── State machine ─────────────────────────────────────────────────────
--   idle / dealing / flop / turn / river / showdown / settling → idle.
--   Resolution returns on the transition INTO settling.
--
-- ─── Math layer (3-distribution outcome model) ─────────────────────────
-- Each hand resolves through three independent dimensions:
--
--   • win_chance — single probability ∈ [0, 1] that the hand is a Win
--   • win_dist   — { small, medium, large, jackpot } sums to 1; sampled
--                  when winning
--   • loss_dist  — { small, medium, large, jackpot } sums to 1; sampled
--                  when losing
--
-- Each stake declares both naked AND run-capped values for these three.
-- Run upgrades push fill descriptors onto ctx lists; the sum of matching
-- descriptor strengths becomes "fill units" that lerp the dimension from
-- naked toward run-capped via the stake's fill_window. Catalog perks add
-- flat additive bumps on top — the only mechanism for crossing run-capped
-- toward the absolute 0.95 WC ceiling.
--
-- Pipeline (buildOutcome(opp, ctx, gtype, stake)):
--   1. Sum fill units per dimension (only descriptors whose gtype filter
--      matches the table's game_type).
--   2. Convert units → fill ratio via stake.fill_window {start, complete}.
--   3. Lerp naked → run-capped per dimension.
--   4. Gtype additive shape on dists.
--   5. Catalog ctx.win_chance_shifts (additive on top of lerp).
--   6. Clamp WC to [0, 0.95]. Clamp dist cells ≥0 and renormalize.
--
-- Per hand:
--   1. Pick opponent uniformly from seated.
--   2. buildOutcome → (win_chance, win_dist, loss_dist).
--   3. sampleOutcome → (won, tier).
--   4. magnitude_bb = uniform(PotTiers[tier]).
--   5. delta = ±magnitude × stake.bb × (earnings_mult on win, loss_mult on lose).
--   6. Construct cards (models/HandRealism) so best5(player) beats / loses
--      to best5(opp), matching the rolled `won` — and so the matchup it
--      shows fits the tier: a stack lost looks like a hand worth losing a
--      stack with.

local RNG           = require("utils.rng")
local Opponent      = require("models.Opponent")
local HandEval      = require("models.HandEval")
local HandRealism   = require("models.HandRealism")
local MttSession    = require("models.MttSession")
local StakesData    = require("data.stakes")
local GameTypesData = require("data.game_types")
local NameData      = require("data.opponent_names")
local MttPayouts    = require("data.mtt_payouts")
local Lookups       = require("utils.lookups")
local StatusData    = require("data.statuses")
local Constants     = require("data.constants")
local HandScript    = require("models.HandScript")
local OutcomeMath   = require("models.outcome_math")
local PokerActionWeights = require("data.poker_action_weights")
local PokerBetSizing     = require("data.poker_bet_sizing")
local PokerEventTimings  = require("data.poker_event_timings")
local HandStructure      = require("data.hand_structure")
local ShowdownRealism    = require("data.showdown_realism")

local Table = {}
Table.__index = Table

-- Per-process unique id, used as a stable key into AnchorRegistry so views
-- can record screen-space anchor positions for a table (player stack, pot,
-- opponent seats, table center) without mutating the model. Resets to 1 on
-- process boot — anchors don't survive across runs anyway, so there's no
-- value in persisting it.
local _next_id = 1

-- Per-table rolling history of the last N hand results (won, delta, tier).
-- Drawn as a mini bar-graph in the panel header so the player can glance at
-- a table and see "won big a lot lately" or "bleeding". 10 entries is the
-- target; the renderer fits fewer if the panel is too narrow to show 10
-- legibly.
local LAST_RESULTS_CAP = 10

-- Build the AnchorRegistry key for a slot ("you", "pot", "center",
-- "opp_<i>") on a given table. Centralized so the view (writer) and the
-- controller (reader) can't drift on the format.
function Table.anchorKey(t, slot)
    return "table_" .. (t._id or 0) .. "_" .. slot
end

-- (The old per-(gtype, tier) cinematic timeline is gone: hand length is
-- the sum of its script's event beats — data/poker_event_timings.lua,
-- per-gtype overrides included — divided by pace. The script walker in
-- :update is what advances it.)
-- ─── Helpers ──────────────────────────────────────────────────────────

local function pickRandomName()
    return NameData[love.math.random(1, #NameData)]
end

-- ─── Outcome model ────────────────────────────────────────────────────
--
-- The 3-distribution outcome pipeline (buildOutcome, sampleOutcome,
-- applyTierShift, rollTierMagnitude, TIER_KEYS, WC_ABSOLUTE_CAP, the dist
-- and fill helpers) lives in models/outcome_math.lua so MttSession can
-- reuse it for tournament-level outcome rolls. Per-hand call sites below
-- go through OutcomeMath.

-- ─── Construction ─────────────────────────────────────────────────────

function Table:new(stake_id, game_type_id, ctx, poker_events, effects_registry, bus)
    local stake = Lookups.findById(StakesData,stake_id)
    local id = _next_id
    _next_id = _next_id + 1
    local self = setmetatable({
        _id           = id,
        stake_id      = stake_id,
        game_type_id  = game_type_id or "six_max",
        opponents     = {},
        state         = "idle",
        state_timer   = 0,
        hands_played  = 0,
        last_results  = {},

        -- Poker-event registry. Used at deal time (writer state mutation
        -- inside HandScript.write) and at play time (cinematic walker
        -- mutates the table's playback state as each event fires).
        poker_events  = poker_events,
        -- The same EffectsRegistry the global rollup uses. A status is
        -- applied through it onto this table's ctx overlay, so statuses
        -- need no effect vocabulary of their own (see :effectiveCtx).
        effects_registry = effects_registry,
        -- The notification spine. A table says what happened to it and has
        -- no idea who is listening; it is optional, so a headless test can
        -- build a table without one.
        bus                = bus,
        -- Last state anyone was told about. The diff lives here rather than
        -- in the controller (which used to snapshot every table every frame
        -- to find it) because a table is the only thing that knows when it
        -- changed — including changes made outside :update, like a deal or
        -- a forced resolve, which the old snapshot missed and which needed
        -- two separate patches at the call sites to paper over.
        _prev_state        = "idle",
        -- One-shot: an interrupted hand makes the next one go the same
        -- way. Consumed by the next :deal, cleared with the hand.
        _forced_next_won   = nil,
        _interrupted       = false,
        script             = nil,
        script_idx         = 0,
        script_timer       = 0,
        playback_state     = nil,
        view_event_cursor     = 0,
        -- Dealer button in VISUAL seat space; see :deal. Persists across hands
        -- so the button MOVES one seat instead of being re-rolled.
        button_visual_seat = nil,

        stack = (stake and stake.buy_in) or 0,

        player_hole         = nil,
        opponent_hole       = nil,
        opponent_idx        = nil,
        community           = nil,
        outcome_won         = nil,
        outcome_delta       = nil,
        outcome_tier        = nil,    -- "small" / "medium" / "large" / "jackpot"
        natural_outcome     = true,
        -- True when :interrupt flipped this hand's side after the deal. A
        -- flipped hand keeps its tier for the felt but is NOT the chip
        -- event: jackpot-keyed triggers gate on it (GrindController).
        outcome_flipped     = false,

        -- When true, the autonomous cursor swarm (services/CursorPool)
        -- ignores this table's DEAL button. Mouse clicks still work.
        -- Persisted parallel to active_table_specs in GameState.
        cursor_muted        = false,
        -- Same as above but for REBUY hit_boxes — only consulted when
        -- the catalog perk `cursor_rebuy_unlocked` is owned. Lets the
        -- player keep auto-deal on but block auto-rebuy at specific
        -- tables (e.g., let a busted experiment table die instead of
        -- bleeding more buy-ins).
        cursor_rebuy_muted  = false,

        x = 0, y = 0,
        _pending_resolution = nil,

        -- Per-table FX state. All fields decay each frame in :update. The
        -- shake_trauma uses the trauma² model — per-frame amplitude =
        -- SHAKE_MAX × trauma² × random — so the shake feels organic.
        -- GrindController writes these fields on resolution; intensities
        -- come from data/feedback_intensity.lua keyed by the rolled tier.
        --
        -- shake_trauma     0..1   — panel-confined screen shake
        -- vignette_*       0..1   — colored wash over felt (good/bad)
        -- border_pulse_t   0..1   — colored border-line flash post-resolve
        -- border_pulse_color "good" | "bad" — drives pulse hue
        -- lift_t           0..1   — held-aloft offset; 1 during a hand,
        --                            eases back to 0 when state == idle
        -- slam_t           0..1   — brief down-spike triggered on settle
        -- glow_t           0..1   — radial-glow shader intensity, fired
        --                            on jackpot wins
        --
        shake_trauma       = 0,
        vignette_kind      = nil,
        vignette_alpha     = 0,
        border_pulse_t     = 0,
        border_pulse_color = nil,
        lift_t             = 0,
        slam_t             = 0,
        glow_t             = 0,

        -- Bump direction: this table just shoved a neighbour, or just got
        -- shoved. Only the DIRECTION lives here — the envelope is a
        -- services/Pop entry keyed "tbl_bump:<id>", so there is no timer
        -- to declare or decay. bump_out is true for the one doing the
        -- shoving (lunges out and back), false for the one taking it
        -- (knocked away, settles home).
        bump_dx            = 0,
        bump_dy            = 0,
        bump_out           = false,
        -- The fist. Set when this table is the one being slammed on
        -- rather than shoving or being shoved: the strike is instant and
        -- what animates is the recovery.
        bump_slam          = false,
        -- Seconds until an incoming shockwave reaches this table. While
        -- it is counting down the table has already taken its status but
        -- shows NOTHING of it: nothing reacts until the fist lands.
        impact_wait        = 0,

        -- Shaking a lean off. When a status that tilted this table
        -- expires, the panel doesn't snap back to level — it rocks and
        -- settles. untilt_t is the 0..1 decay, untilt_mag the lean it is
        -- unwinding from.
        untilt_t           = 0,
        untilt_mag         = 0,

        -- Statuses (data/statuses.lua): the temporary things happening TO
        -- this table. Left nil until something applies one — the decay
        -- block runs for every table every frame, so the common case is a
        -- single nil check. Transient by design: TablePool:_syncStateList
        -- doesn't carry them, so they evaporate on load, which is right —
        -- autosave is every 10s and every status is shorter than that.
        statuses           = nil,
        -- Bumped whenever the ctx contribution changes (add, stronger
        -- refresh, expiry). Keys the overlay cache; a pure duration
        -- refresh deliberately does NOT bump it.
        _status_rev        = 0,

        -- Cash-out gate. Set to true by GrindController:removeTable /
        -- :cashOutAll when the player asks to close a table that's mid-
        -- hand. The controller's update loop finalises the close (chip
        -- flight + pool removal) once the table returns to idle.
        pending_close  = false,

        -- Tournament bookkeeping. Composed in always; cash tables leave it
        -- at hands_won=0/state=nil so the chip-stack branches in
        -- :_finalizeHand and the controller no-op. Only meaningful when
        -- the gtype carries chip_stack_table=true. See models/MttSession
        -- for the lifecycle.
        mtt = MttSession:new(),
    }, Table)
    self:fillOpponents(ctx)
    return self
end

function Table:fillOpponents(_ctx)
    self.opponents = {}
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return end

    -- Opponents are pure visual flavour now: a name + a stack at the
    -- table's buy-in. No per-seat mechanical traits.
    for i = 1, gtype.seats do
        self.opponents[i] = Opponent:new(pickRandomName(), stake.buy_in or 0)
    end

    -- Visible cue when an anonymous-pool gtype rerolls between hands —
    -- the seat row briefly fades in so the player sees "the pool changed."
    -- Decayed in :update; consumed by drawOpponentSeat for an alpha multi.
    self.reroll_flash_t = 0.4
end

function Table:setStake(stake_id, ctx)
    self.stake_id = stake_id
    local stake = Lookups.findById(StakesData,stake_id)
    self.stack = (stake and stake.buy_in) or 0
    self.state = "idle"
    self.state_timer = 0
    self:fillOpponents(ctx)
    -- Stake-change resets the chip-stack tournament so the next deal
    -- starts a fresh run at the new stake's bb. Without this, leftover
    -- per-seat stacks (sized in the old stake's bb) would persist.
    self:_clearChipStackState()
end

-- ─── Chip-stack tournament helpers ────────────────────────────────────
-- For chip_stack_table gtypes (8-max KO): every seat sits down with
-- starting_stack_bb chips, hands play with real chip flow, seats bust
-- at 0, tournament ends when the player busts or wins it all. Payout
-- comes from data/mtt_payouts.lua keyed by finish position.

function Table:_clearChipStackState()
    self.seat_stacks       = nil
    self.seat_busted       = nil
    self.player_seat_fixed = nil
    self.button_seat       = nil
    self.bust_order        = nil
    self.last_finish       = nil
end

-- Called from Table:deal when the gtype is chip_stack_table. Initializes
-- per-seat state on the first deal of a fresh tournament; no-op when
-- mid-run (mtt:isPlaying() returns true).
function Table:_initChipStackIfNeeded(stake, gtype)
    if self.mtt:isPlaying() then return end
    local n_seats     = (gtype.seats or 0) + 1
    local start_chips = (gtype.starting_stack_bb or 100) * ((stake and stake.bb) or 0)
    self.seat_stacks  = {}
    self.seat_busted  = {}
    for s = 1, n_seats do
        self.seat_stacks[s] = start_chips
        self.seat_busted[s] = false
    end
    self.player_seat_fixed = love.math.random(1, n_seats)
    self.button_seat       = love.math.random(1, n_seats)
    self.bust_order        = {}
    self.last_finish       = nil
    -- tbl.stack mirrors seat_stacks[player_seat_fixed] for visual reads
    -- (chip pile + the felt's money label). The reconciliation pass keeps
    -- these in sync after every hand.
    self.stack             = start_chips
end

-- End-of-hand chip flow → seat stack reconciliation. Reads the script's
-- per_seat_total + pot_at_push + winner and applies the net deltas to
-- self.seat_stacks. Marks busted seats. Returns the player's net delta
-- so the resolution dict can carry it back to the controller for the
-- floater label.
--
-- Called from Table:update at the settling-state transition for
-- chip_stack_table tables — runs BEFORE _pending_resolution is built so
-- the resolution dict's delta reflects actual chip flow (not the cash
-- branch's pre-cap outcome_delta).
function Table:_reconcileChipFlow()
    local ps = self.playback_state
    if not ps or not ps.winner then return 0 end
    if not self.seat_stacks then return 0 end

    local player_seat = self.player_seat_fixed
    local old_stack   = self.seat_stacks[player_seat] or 0
    local busted_opps = nil

    local n_seats = ps.n_seats or 0
    for seat = 1, n_seats do
        if not self.seat_busted[seat] then
            local contributed = (ps.per_seat_total and ps.per_seat_total[seat]) or 0
            local stack       = (self.seat_stacks[seat] or 0) - contributed
            if seat == ps.winner then
                stack = stack + (ps.pot_at_push or 0)
            end
            -- Round to cents to kill float residuals. Without this, a
            -- seat can be left with $0.001 from accumulated FP drift,
            -- which is below the writer's r2() threshold for blinds —
            -- they post $0.00, neither contribute nor get whittled
            -- down, and "live" at 0bb display forever. Rounding folds
            -- the residual cleanly into the bust check below.
            stack = math.floor(stack * 100 + 0.5) / 100
            if stack <= 0 then
                stack = 0
                if not self.seat_busted[seat] then
                    self.seat_busted[seat] = true
                    self.bust_order[#self.bust_order + 1] = seat
                    -- Knockouts, collected for the procs that key off
                    -- them. The player's OWN seat is in bust_order too,
                    -- and it is filtered out right here at the source so
                    -- no consumer downstream can forget: busting out of a
                    -- tournament must not fire your "on knockout" buffs.
                    if seat ~= self.player_seat_fixed then
                        busted_opps = busted_opps or {}
                        busted_opps[#busted_opps + 1] = seat
                    end
                end
            end
            self.seat_stacks[seat] = stack
        end
    end

    local new_stack = self.seat_stacks[player_seat] or 0
    self.stack = new_stack
    return new_stack - old_stack, busted_opps
end

-- ─── Per-hand math ────────────────────────────────────────────────────

function Table:deal(ctx)
    if self.state ~= "idle" then return false end
    ctx = ctx or {}
    -- Stash ctx so the timeline walker's tournament auto-advance hook
    -- (in :_finalizeHand → :deal / :_endTournament) has the latest
    -- effects rollup without needing to thread ctx through every call.
    self._last_ctx = ctx

    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return false end

    if gtype.rerolls_opponents then
        self:fillOpponents(ctx)
    end

    local n_opps = #self.opponents
    if n_opps <= 0 then return false end
    self.opponent_idx = love.math.random(1, n_opps)
    if not self.opponents[self.opponent_idx] then return false end

    -- Chip-stack tournaments: initialize seat stacks + bust state on
    -- the first deal of a fresh MTT run, then roll the tournament plan.
    -- Subsequent deals reuse the per-seat state and pull the next hand's
    -- pre-rolled outcome from the plan. See models/MttSession.
    local forced_winner_seat = nil
    if gtype.chip_stack_table then
        self:_initChipStackIfNeeded(stake, gtype)
        if not self.mtt:isPlaying() then
            self.mtt:begin()
            local n_seats = (gtype.seats or 0) + 1
            self.mtt:planRun(ctx, gtype, stake, self.player_seat_fixed, n_seats)
        end
        -- Snapshot bust count BEFORE this hand so :reconcile in
        -- _finalizeHand can identify new busts this hand only.
        self._pre_hand_bust_count = (self.bust_order and #self.bust_order) or 0
    end

    -- Outcome resolution: plan-driven for tournaments, sample-driven
    -- for cash. Both paths produce (won, tier); chip-stack tables also
    -- produce a forced_winner_seat + forced_bust_seats that flow into
    -- HandScript.write.
    local won, tier
    local forced_bust_seats = nil
    if gtype.chip_stack_table and self.mtt:isPlaying() then
        local entry = self.mtt:currentHand()
        if entry then
            won                 = entry.won
            tier                = entry.tier
            forced_winner_seat  = entry.forced_winner
            forced_bust_seats   = entry.bust_seats
            -- A latched punch (heater/tilt — Table:interrupt defers the
            -- whole thing to this hand on tournaments) overrides the
            -- plan's side for THIS hand only. On a flip the plan's winner
            -- and scheduled busts belonged to the other direction — drop
            -- them; HandScript's alive-guard and MttSession:reconcile
            -- re-steer the schedule from the next hand. The tier stays
            -- the plan's: the punch decides who, not how big.
            if self._forced_next_won ~= nil then
                local fw = self._forced_next_won
                self._forced_next_won = nil
                self._punch_live = true
                if fw == false then self._tilt_spent_pending = true end
                if fw ~= won then
                    won                = fw
                    forced_winner_seat = fw and self.player_seat_fixed or nil
                    forced_bust_seats  = nil
                end
            end
        else
            -- Plan exhausted (all n_hands played + reconcile's extension
            -- window burned). Settle at current standings instead of
            -- falling into live per-hand rolls — that regime lets the
            -- player structurally outlast the field and produced 50-100
            -- hand near-guaranteed wins.
            local n_seats = (gtype.seats or 0) + 1
            local alive_opps = 0
            for s = 1, n_seats do
                if s ~= self.player_seat_fixed and not self.seat_busted[s] then
                    alive_opps = alive_opps + 1
                end
            end
            self:_endTournament(alive_opps + 1, n_seats)
            return false
        end
    else
        -- Cash-table path: roll the 3-distribution outcome live. Tier-
        -- shift perks (Self-Help Book / Lava Lamp on win, Stress Ball /
        -- Worry Stone on loss) chain on top — only the cash path uses
        -- these; tournaments shape difficulty via the plan instead.
        local ec = self:effectiveCtx(ctx)
        local wc, wd, ld = OutcomeMath.buildOutcome(ec, gtype, stake)
        -- The Red Rug: whoever sits in the board's top-left cell plays a
        -- little better. Slot 0 is the packed (row 0, col 0) cell; this is
        -- the one place that knows both the rolled ctx and the table's cell.
        if (ec.corner_win_chance or 0) > 0 and (self.slot or -1) == 0 then
            wc = wc + ec.corner_win_chance
        end
        -- A hand that was interrupted forces the NEXT one to go the same
        -- way. Only the side: the tier still rolls — from the forced side's
        -- distribution, which is why the flag goes INTO sampleOutcome — so
        -- a forced win on a heated table is a win of whatever size, one
        -- rung better. Same shape as the tournament branch above taking
        -- `won` from its plan, for exactly one hand.
        -- A consumed forced LOSS is a tilt running its course: the punch's
        -- second half is spent on this hand. Latched here, announced when
        -- the hand finishes (on_tilt_spent — the Waste Basket's moment).
        if self._forced_next_won == false then
            self._tilt_spent_pending = true
        end
        -- This hand spends the punch: the status that latched it expires
        -- when this hand finalizes, so the fire lives exactly as long as
        -- the mechanic (_finalizeHand).
        if self._forced_next_won ~= nil then self._punch_live = true end
        won, tier = OutcomeMath.sampleOutcome(wc, wd, ld, ec, gtype,
                                              self._forced_next_won)
        self._forced_next_won = nil
        if won then
            tier = OutcomeMath.applyTierShift(tier, ec.win_tier_shifts, gtype)
            -- House Cat's one-shot (table_procs next_win_tier_up): the next
            -- WIN reads a tier higher. Wins only, so a pending flag rides
            -- through losses untouched until a win spends it.
            if self._next_win_tier_up then
                self._next_win_tier_up = nil
                local rank = OutcomeMath.TIER_INDEX[tier]
                if rank then
                    tier = OutcomeMath.TIER_KEYS[math.min(#OutcomeMath.TIER_KEYS, rank + 1)]
                end
            end
        else
            tier = OutcomeMath.applyTierShift(tier, ec.loss_tier_shifts, gtype)
        end
    end

    -- Everything below prices the hand, so it reads THIS table's ctx —
    -- the global rollup plus whatever statuses are riding on this table.
    -- Identical to `ctx` (same object) whenever nothing is active.
    -- Deliberately after the MTT branch above: a tournament's outcomes
    -- come from a plan rolled once at the start, so a transient status
    -- must not be baked into it.
    local ectx = self:effectiveCtx(ctx)

    -- Per-resolve tier bump + payout double (Maniac capstone). Generic
    -- capability flags — one-step, non-chaining bump via the shared tier
    -- ranking; magnitude double applied below.
    local payout_double = 1.0
    if ectx then
        if ectx.tier_bump_chance and love.math.random() < ectx.tier_bump_chance then
            local rank = OutcomeMath.TIER_INDEX[tier]
            if rank then
                tier = OutcomeMath.TIER_KEYS[math.min(#OutcomeMath.TIER_KEYS, rank + 1)]
            end
        end
        if ectx.payout_double_chance and love.math.random() < ectx.payout_double_chance then
            payout_double = 2.0
        end
    end

    local magnitude_bb = OutcomeMath.rollTierMagnitude(tier, gtype, won)

    self.outcome_won     = won
    self.outcome_tier    = tier
    self.outcome_flipped = false

    -- earnings_mult / loss_mult scale magnitude only — they don't reshape
    -- the dists (Pot Odds Master, Damage Control, Headphones).
    local earnings_mult = ectx.earnings_mult or 1
    if ectx.earnings_per_tier then
        local tier_idx = stake and Lookups.indexById(StakesData, stake.id) or 0
        earnings_mult = earnings_mult * (1.0 + ectx.earnings_per_tier * tier_idx)
    end
    local loss_mult     = ectx.loss_mult     or 1
    -- jackpot_mult (Branded Hat) stacks on top of earnings_mult — only
    -- jackpot-tier WINS get the extra boost.
    local jackpot_mult  = (won and tier == "jackpot")
                          and (ectx.jackpot_mult or 1) or 1
    if won then
        local raw_win = magnitude_bb * stake.bb
        -- The seats rule: the most a hand can pay is one stack from each
        -- opponent matching your all-in — max win = seats × stack (HU:
        -- one stack; 6-max: five). Shares its definition with the
        -- theater's magnitude clamp (OutcomeMath.maxWinBB) so the
        -- cinematic and the payout can never disagree. Also keeps
        -- low-stack jackpots from being free money: a short stack caps
        -- proportionally.
        local capped_win = math.min(raw_win,
            OutcomeMath.maxWinBB(gtype, self.stack or 0))
        self.outcome_delta = capped_win * earnings_mult * jackpot_mult * payout_double
    else
        -- Loss side already capped downstream: GrindController clamps
        -- stack at 0 in its resolution loop.
        self.outcome_delta = -magnitude_bb * stake.bb * loss_mult * payout_double
    end
    -- earnings_scale_by_bankroll (Bank capstone) is applied at resolve time
    -- in GrindController, where live bankroll is available.

    -- Cards last, and cards only: the money above is already final. The
    -- outcome's tier picks the matchup this hand SHOWS, so a stack that
    -- crosses the table looks like a hand worth stacking off with.
    local p_hole, o_hole, board, natural = HandRealism.constructShowdownHand(
        won, tier, { policy = ShowdownRealism, gtype_id = self.game_type_id })
    -- Point of no return: the new hand is real, so the previous hand's
    -- residue leaves the felt. Cleared HERE and not at the top of :deal
    -- so a failed deal attempt (missing gtype, no opponents, exhausted
    -- MTT plan) leaves the last result visible instead of blanking it.
    self.last_hand       = nil
    self.player_hole     = p_hole
    self.opponent_hole   = o_hole
    self.community       = board
    self.natural_outcome = natural

    -- Hand-name labels for showdown reveal. Computed once at deal time
    -- so the view doesn't recompute every frame. HandEval.describe
    -- returns e.g. "pair of Aces" / "trip 7s" / "Ace-high flush".
    -- Cleared in :_finalizeHand so they don't leak across hands.
    -- Name + best-5 combo for each side (the combo drives the view's
    -- showdown emphasis), through the one shared HandEval.handLabel.
    self.player_hand_name,   self.player_combo   = HandEval.handLabel(p_hole, board)
    self.opponent_hand_name, self.opponent_combo = HandEval.handLabel(o_hole, board)

    -- Cinematic setup: models/HandScript.write composes a per-hand
    -- event list (post_blind, fold, call, raise, deal_*, pot_push).
    -- :update walks events by timestamp; the view reads playback_state.
    do
        self.script_idx     = 0
        self.script_timer   = 0
        self.view_event_cursor = 0
        -- gtype.seats is the OPPONENT count (5 for six-max, 1 for HU,
        -- etc.), not the total. Total seats includes the player.
        local n_seats = ((gtype and gtype.seats) or 5) + 1
        -- Chip-stack tournaments use the persisted player_seat / button
        -- so the visual position stays stable and blinds rotate as opps
        -- bust. Cash games re-roll both each hand (existing behavior).
        local player_seat, button_seat
        if gtype.chip_stack_table then
            player_seat = self.player_seat_fixed
            button_seat = self.button_seat
            -- Advance the button clockwise to the next ALIVE seat each
            -- hand. Defensive: if button_seat is somehow on a busted seat
            -- (e.g. opp busted on the previous hand from this position),
            -- the loop walks past it.
            local advanced = nil
            local s = (button_seat % n_seats) + 1
            for _ = 1, n_seats do
                if not self.seat_busted[s] then advanced = s; break end
                s = (s % n_seats) + 1
            end
            if advanced then
                self.button_seat = advanced
                button_seat      = advanced
            end
        else
            player_seat = love.math.random(1, n_seats)
            button_seat = love.math.random(1, n_seats)
        end

        -- ── Dealer button, in VISUAL seat space ──────────────────────
        -- Seats 1..n_opps are the opponents as the panel draws them, left to
        -- right; seat n_seats is you, at the bottom. Deliberately separate from
        -- `button_seat` above, which is SCRIPT space and belongs to HandScript.
        --
        -- The two can't be the same number. Cash re-rolls player_seat every
        -- hand, and the view maps a script seat to a drawn seat THROUGH
        -- player_seat, so a script-space button lands somewhere different every
        -- hand however carefully the script advances it. On screen that reads
        -- as the button teleporting, which is worse than no button at all: a
        -- dealer button that doesn't move one seat isn't a dealer button.
        local button_visual
        if gtype.chip_stack_table then
            -- KO seating is fixed (player_seat_fixed), so the script button
            -- maps straight across -- and it already advances past busted
            -- seats, which is exactly what should show.
            button_visual = (button_seat == player_seat) and n_seats
                            or ((button_seat < player_seat) and button_seat
                                                            or button_seat - 1)
        else
            -- Cash: advance one seat clockwise, wrapping through you. Only the
            -- very first hand of a table rolls a starting position.
            local prev = self.button_visual_seat
            button_visual = prev and ((prev % n_seats) + 1)
                            or love.math.random(1, n_seats)
        end
        self.button_visual_seat = button_visual

        self.playback_state = {
            n_seats             = n_seats,
            player_seat         = player_seat,
            -- Script space, for anything reasoning about blind order.
            button_seat         = button_seat,
            -- VISUAL space, which is what views/TablePanel draws the button
            -- from. Transient per-hand state (playback_state is nil-ed on
            -- reset), so nothing is serialized and there is no save migration.
            button_visual_seat  = button_visual,
            in_seats            = {},
            n_in                = 0,
            pot                 = 0,
            current_bet         = 0,
            per_seat_committed  = {},
            per_seat_total      = {},
            community_count     = 0,
            player_revealed     = false,
            opp_revealed        = false,
            winner              = nil,
            pot_at_push         = 0,
        }
        -- alive_seats: in chip-stack mode, busted seats stay out of the
        -- hand. For cash games every seat is alive.
        local alive_seats = {}
        local n_alive = 0
        for i = 1, n_seats do
            local is_alive = true
            if gtype.chip_stack_table and self.seat_busted then
                is_alive = not self.seat_busted[i]
            end
            if is_alive then
                self.playback_state.in_seats[i] = true
                alive_seats[i] = true
                n_alive = n_alive + 1
            end
        end
        self.playback_state.n_in = n_alive
        -- Cap the writer's contribution target at the player's available
        -- stack. The bb-tier roll can exceed what the player can actually
        -- put in; without this cap the script keeps generating call
        -- events past the all-in point and the displayed stack tries to
        -- drain below zero. For chip-stack tables, also cap at the
        -- biggest alive opponent stack so the pot is feasible.
        local stake_bb        = (stake and stake.bb) or 0
        local effective_bb    = magnitude_bb
        -- Cash tables: THE POT IS WHAT YOU WIN. The writer's contract
        -- builds pot_total = target + player's match (2× target), so a
        -- win hands it HALF the payout — the final pot lands at exactly
        -- outcome_delta, and "pot $145, +$145" replaces the old
        -- "pot $145, +$77" (real-poker net accounting, which read as a
        -- 50% rake). outcome_delta carries the item multipliers that raw
        -- magnitude_bb does not, so this also keeps the pot in the same
        -- universe as the payout under x25 items. Losses keep the full
        -- figure: you lose your own contribution, and that contribution
        -- must BE the loss. Chip-stack tournaments are exempt — their
        -- magnitude drives real chip flow between seat stacks.
        if not gtype.chip_stack_table and stake_bb > 0 then
            local payout_bb = math.abs(self.outcome_delta or 0) / stake_bb
            effective_bb = won and (payout_bb * 0.5) or payout_bb
        end
        if stake_bb > 0 and (self.stack or 0) > 0 then
            local stack_bb = (self.stack or 0) / stake_bb
            -- Wins clamp at the SEATS RULE (one stack from each opponent
            -- matching your all-in) — the same definition the payout cap
            -- uses in :deal, so the cinematic and the money can't drift.
            -- Losses clamp at one stack: you can only lose your own.
            local cap_bb = won and OutcomeMath.maxWinBB(gtype, stack_bb) or stack_bb
            if effective_bb > cap_bb then effective_bb = cap_bb end
        end
        if gtype.chip_stack_table and stake_bb > 0 and self.seat_stacks then
            local max_opp = 0
            for seat = 1, n_seats do
                if seat ~= player_seat and not self.seat_busted[seat] then
                    local s_chips = self.seat_stacks[seat] or 0
                    if s_chips > max_opp then max_opp = s_chips end
                end
            end
            local opp_bb = max_opp / stake_bb
            if effective_bb > opp_bb then effective_bb = opp_bb end
        end
        -- Per-seat stack table passed to the writer so it can cap any
        -- single seat's contribution at their remaining chips (emits
        -- all_in instead of call when short).
        --
        -- Tournaments pass their live per-seat chips. CASH tables pass
        -- stacks too (player = their stack, opponents = one buy-in each,
        -- matching the stacks the seats are drawn with): under the seats
        -- rule a win can be worth several stacks, and the writer needs to
        -- know who can cover what so a 500bb pot renders as everyone
        -- all-in instead of five impossible calls.
        local seat_stacks_for_writer = nil
        if gtype.chip_stack_table and self.seat_stacks then
            seat_stacks_for_writer = {}
            for seat = 1, n_seats do
                seat_stacks_for_writer[seat] = self.seat_stacks[seat] or 0
            end
        elseif not gtype.chip_stack_table then
            local buy_in = (stake and stake.buy_in) or 0
            seat_stacks_for_writer = {}
            for seat = 1, n_seats do
                seat_stacks_for_writer[seat] =
                    (seat == player_seat) and (self.stack or 0) or buy_in
            end
        end
        local result = HandScript.write(
            {
                won                = won,
                magnitude_bb       = effective_bb,
                tier               = tier,
                gtype_id           = gtype.id,
                stake_bb           = stake_bb,
                -- Tournament plan supplies the winner_seat on player-loss
                -- hands and the scheduled bust target(s) on bust hands.
                -- Nil for cash games — the writer falls back to its
                -- existing random pick. Dead seats are guarded against
                -- inside HandScript.
                forced_winner_seat = forced_winner_seat,
                forced_bust_seats  = forced_bust_seats,
            },
            {
                n_seats     = n_seats,
                player_seat = player_seat,
                button_seat = button_seat,
                alive_seats = (gtype.chip_stack_table and alive_seats) or nil,
                seat_stacks = seat_stacks_for_writer,
            },
            self.poker_events,
            PokerActionWeights,
            PokerBetSizing,
            PokerEventTimings,
            HandStructure)
        self.script           = result.events
        self.script_total     = result.total_duration
        self.timeline         = nil
        self.phase_idx        = nil
        self.state            = "dealing"  -- neutral non-idle state for lift/FX gates
        self.state_timer      = 0

        -- Align tbl.opponent_idx (visual position 1..n_opps in
        -- tbl.opponents) to the script's showcase opp — the seat whose
        -- cards flip face-up at showdown. Without this, the legacy
        -- random opponent_idx might point at a folded opp, making the
        -- post-resolution view read as if the folded seat won.
        if result.showcase_opp_seat then
            local s = result.showcase_opp_seat
            if s == player_seat then
                -- Defensive: if the writer somehow returned the player as
                -- the showcase seat, leave the legacy opponent_idx in place.
            elseif s < player_seat then
                self.opponent_idx = s
            else
                self.opponent_idx = s - 1
            end
            -- Clamp into valid range (n_opps < n_seats).
            local n_opps = #self.opponents
            if n_opps > 0 and self.opponent_idx > n_opps then
                self.opponent_idx = n_opps
            end
        end
    end

    -- Past every early-out above, so a hand that never started never
    -- burns a charge. Timed statuses are untouched here — they run on
    -- the clock, not on hands.
    self:_spendStatusCharges()
    return true
end

-- ─── Animation tick ───────────────────────────────────────────────────

-- Decay rates per-second. Tuned for visible punch — slow enough that the
-- effect lingers long enough to read, fast enough not to fight the next
-- hand's animation.
-- Shaking off a lean: slow enough to read as the table righting itself.
local UNTILT_DECAY_RATE       = 1.6
local SHAKE_DECAY_RATE        = 1.2
local VIGNETTE_DECAY_RATE     = 1.2
local BORDER_PULSE_DECAY_RATE = 1.0
-- Lift lerp. Panel rises during the playing phases (dealing → showdown).
-- Panel snaps to rest at "settling" (when chips fly + resolution feedback
-- fires) and stays at rest while idle. The set of "panel down" states is
-- explicit so adding a new cinematic phase is one entry, not a code
-- branch.
local LIFT_RISE_RATE       = 6.0    -- ~0.3 s up
local LIFT_DOWN_STATES     = { idle = true, settling = true }

-- Runs the tick, then tells anyone listening if the state moved. Wrapping
-- rather than announcing inline because :_update returns from four places,
-- and a transition missed is a sound not played.
function Table:update(dt, ctx)
    local r = self:_update(dt, ctx)
    local prev = self._prev_state
    if prev ~= self.state then
        self._prev_state = self.state
        if self.bus then
            self.bus:publish("table_state_changed",
                { table = self, from = prev, to = self.state })
        end
    end
    return r
end

function Table:_update(dt, ctx)
    -- Stash latest ctx for the auto-deal path on tournament tables.
    if ctx then self._last_ctx = ctx end

    -- Decay per-table FX every frame regardless of table state.
    local d = dt or 0
    if (self.shake_trauma or 0) > 0 then
        self.shake_trauma = math.max(0, self.shake_trauma - d * SHAKE_DECAY_RATE)
    end
    if (self.vignette_alpha or 0) > 0 then
        self.vignette_alpha = math.max(0, self.vignette_alpha - d * VIGNETTE_DECAY_RATE)
        if self.vignette_alpha <= 0 then self.vignette_kind = nil end
    end
    if (self.border_pulse_t or 0) > 0 then
        self.border_pulse_t = math.max(0, self.border_pulse_t - d * BORDER_PULSE_DECAY_RATE)
        if self.border_pulse_t <= 0 then self.border_pulse_color = nil end
    end
    if (self.glow_t or 0) > 0 then
        -- Lingers ~1.7s so the player has time to register the halo.
        self.glow_t = math.max(0, self.glow_t - d * 0.6)
    end
    -- Lift_t: smooth rise during playing phases, instant snap-to-rest
    -- once we hit "settling" or "idle" (LIFT_DOWN_STATES). The snap
    -- lands on the same frame the resolution fires so chips, floater,
    -- border pulse, and the panel drop all happen as one moment. Any
    -- lerped fall would visibly "rise back up" during the 0.4s settling
    -- phase before snapping down again at end-of-hand.
    local lift_curr = self.lift_t or 0
    if LIFT_DOWN_STATES[self.state] then
        self.lift_t = 0
    else
        local k = math.min(1, d * LIFT_RISE_RATE)
        self.lift_t = lift_curr + (1 - lift_curr) * k
    end

    -- Reroll flash decay (Zoom's anonymous-seat fade-in). Linear over 0.4s.
    if (self.reroll_flash_t or 0) > 0 then
        self.reroll_flash_t = math.max(0, self.reroll_flash_t - d)
    end
    if (self.untilt_t or 0) > 0 then
        self.untilt_t = math.max(0, self.untilt_t - d * UNTILT_DECAY_RATE)
    end
    -- Statuses tick on RAW dt like the FX above, NOT on the pace-scaled
    -- effective_dt computed below: a status that makes a table play faster
    -- must not shorten itself by doing so.
    if self.statuses then self:_tickStatuses(d) end

    if self.state == "idle" then
        -- A latched punch AUTO-DEALS. Heat or tilt landing on a table
        -- means the forced hand plays NOW — however the table got idle
        -- (was idle when it landed, or just finished the hand it
        -- interrupted) — and the status expires when that hand finishes.
        -- If the table can't play it (busted to the REBUY screen mid-
        -- punch — application-time retargeting in table_procs keeps
        -- punches off busted tables, but a tilt can bust the table it
        -- rides) or the deal is refused, the punch FIZZLES: dealing must
        -- never spend money, and fire must never sit on a table with
        -- nothing to deal.
        if self._forced_next_won ~= nil then
            if (self.stack or 0) > 0 and self:deal(ctx or self._last_ctx) then
                return nil
            end
            self._forced_next_won = nil
            self:_expirePunchStatuses()
        end
        -- Wall-clock idle timer (raw dt, not pace-scaled): drives the
        -- residue desaturation ease-in. _finalizeHand resets it to 0.
        self.state_timer = (self.state_timer or 0) + (dt or 0)
        return nil
    end

    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    local pace_mult = (gtype and gtype.pace_mult) or 1
    -- ctx.hand_pace_mult (Energy Drink, future pace items) compounds on
    -- top of the gtype baseline.
    -- The OVERLAY, not the raw ctx: a heated table deals faster, and that
    -- is the most legible thing a status does. Safe because _tickStatuses
    -- above runs on raw dt, so a status that speeds a table up cannot
    -- shorten itself by doing so.
    local pace_ctx = self:effectiveCtx(self._last_ctx)
    local ctx_pace = (pace_ctx and pace_ctx.hand_pace_mult) or 1
    local effective_dt = (dt or 0) * pace_mult * ctx_pace
    -- Script time runs at this multiple of wall time. Published so the
    -- view can convert a gap between script events into the real seconds
    -- it has to animate in — a chip flight that outruns the action it
    -- represents is worse than a fast one.
    self._script_pace = pace_mult * ctx_pace

    self.state_timer = self.state_timer + effective_dt

    -- ── Script walker ──────────────────────────────────────────────────
    -- When the table has a script attached, walk it event-by-event.
    -- Each event whose absolute timestamp `t` has been crossed gets
    -- popped, applied via the registry (mutates self.playback_state),
    -- and stamped on self.view_event_cursor so views can detect new events.
    -- When all events are consumed, transition to "settling" the same
    -- way the timeline walker does — preserves resolution emit, lift
    -- snap, and _finalizeHand timing.
    if self.script then
        self.script_timer = (self.script_timer or 0) + effective_dt
        local events = self.script
        while self.script_idx < #events do
            local next_ev = events[self.script_idx + 1]
            if next_ev.t > self.script_timer then break end
            self.script_idx = self.script_idx + 1
            if self.poker_events and self.playback_state then
                self.poker_events:apply(next_ev, self.playback_state)
            end
        end
        if self.script_idx >= #events and self.state ~= "settling" then
            -- Script exhausted — transition into settling so resolution
            -- emit + FX fire just like the timeline path. For chip-stack
            -- tables, reconcile per-seat chip flow into seat_stacks
            -- BEFORE building the resolution dict so r.delta reflects
            -- the actual stack change (and seat busts have been marked
            -- for end-condition checks in _finalizeHand).
            local gtype = Lookups.findById(GameTypesData, self.game_type_id)
            local resolved_delta = self.outcome_delta
            local busted_opps
            if gtype and gtype.chip_stack_table then
                resolved_delta, busted_opps = self:_reconcileChipFlow()
                self.outcome_delta = resolved_delta
            end
            self.state       = "settling"
            self.state_timer = 0
            self._pending_resolution = {
                won   = self.outcome_won,
                delta = resolved_delta,
                tier  = self.outcome_tier,
                flipped = self.outcome_flipped or nil,
                x     = self.x,
                y     = self.y,
                chip_stack_table = gtype and gtype.chip_stack_table or false,
                felt_pot = self.playback_state and self.playback_state.pot_at_push or 0,
                -- The player's own money in the pot. What a win NATURALLY
                -- pays is pot minus this (your own chips coming back are
                -- not profit), and what a loss naturally costs is exactly
                -- this — the baselines the floater's item-multiplier
                -- readout divides against.
                felt_stake = (function()
                    local ps = self.playback_state
                    local seat = ps and ps.player_seat
                    return (seat and ps.per_seat_total
                            and ps.per_seat_total[seat]) or 0
                end)(),
                -- Knockout signal, opponents only. nil on cash tables and
                -- on tournament hands where nobody busted. This is the
                -- ONLY outlet: the per-hand bust list computed later in
                -- _finalizeHand is consumed by the tournament planner and
                -- thrown away, and it arrives a frame late besides.
                busted_seats = busted_opps,
                busted_total = busted_opps and #(self.bust_order or {}) or nil,
            }
            self.lift_t = 0
        elseif self.state == "settling" and self.state_timer >= 0.4 then
            -- Settling beat over — clean up and return to idle.
            self:_finalizeHand()
        end

        if self._pending_resolution then
            local r = self._pending_resolution
            self._pending_resolution = nil
            return r
        end
        return nil
    end

    if self._pending_resolution then
        local r = self._pending_resolution
        self._pending_resolution = nil
        return r
    end
    return nil
end

-- Finish this hand NOW, returning its resolution exactly as :update would.
--
-- The outcome was decided back in :deal — the script only controls WHEN it
-- lands. So this is a time compressor, not a payout change: the hand rolls
-- what it was always going to roll, it just stops waiting. Jumping the
-- script clock past the final event makes the walker above drain every
-- remaining event in order through the registry, which matters — the pot
-- total (playback_state.pot_at_push) and, for tournaments, the per-seat
-- chip reconciliation only exist because those events were APPLIED, not
-- skipped.
--
-- dt = 0 is deliberate: state_timer doesn't advance, so the settling beat
-- still plays out over its normal 0.4s on later frames and _finalizeHand
-- writes its history-bar entry as usual.
--
-- Returns nil when there is nothing to finish (idle, already settling, or
-- the script is spent). That nil IS the throttle for cascade effects — a
-- table with no live hand simply can't be swept again.
-- ─── Statuses ──────────────────────────────────────────────────────────
-- See data/statuses.lua for the model. Applying is idempotent-ish: a live
-- status of the same kind REFRESHES (max magnitude, max remaining life)
-- rather than stacking, so overlapping sources extend uptime without
-- compounding power.

local STATUS_CAP = 6   -- runaway guard; entries are keyed by kind, so the
                       -- real bound is the number of authored kinds.

function Table:applyStatus(kind, spec)
    local def = StatusData[kind]
    if not def or not spec then return false end
    -- The mental game (Dish Soap, ctx.tilt_resist_chance): a bad status
    -- sometimes just doesn't stick. Rolled before anything else — a
    -- resisted tilt neither lands fresh nor refreshes one already running,
    -- and nothing announces, because nothing happened.
    if def.polarity == "bad" then
        local resist = self._last_ctx and self._last_ctx.tilt_resist_chance
        if resist and resist > 0 and love.math.random() < resist then
            return false
        end
    end
    -- A punch status IS its interrupt. An application that opts out of
    -- interrupting (`no_interrupt`, ambient sources) would leave an
    -- eternal decoration — a fire that never had a punch to spend and so
    -- never goes out. Refuse it outright.
    if def.lifetime == "punch" and spec and spec.no_interrupt then
        return false
    end
    self.statuses = self.statuses or {}
    local mag = spec.magnitude or 0

    -- Most kinds refresh: the strongest magnitude and the longest remaining
    -- life win, so two sources overlapping extend uptime without doubling
    -- power. A kind marked `stack = "add"` accumulates instead, because for
    -- those the whole point is that the tenth one is worth more than the
    -- first (data/statuses.lua).
    local adds = (def.stack == "add")
    for _, e in ipairs(self.statuses) do
        if e.kind == kind then
            local before = e.magnitude or 0
            if adds then
                local cap = def.stack_cap
                e.magnitude = before + mag
                if cap then e.magnitude = math.min(cap, e.magnitude) end
            else
                e.magnitude = math.max(before, mag)
            end
            if def.lifetime == "run" or def.lifetime == "punch" then
                -- Nothing to extend: run lasts until the run ends, punch
                -- until the punch is spent (_finalizeHand).
            elseif def.lifetime == "charges" then
                local c = spec.charges or 0
                e.charges     = adds and ((e.charges or 0) + c)
                                     or math.max(e.charges or 0, c)
                e.charges_max = math.max(e.charges_max or 0, e.charges)
            else
                e.t     = math.max(e.t or 0, spec.t or 0)
                e.t_max = math.max(e.t_max or 0, e.t)
            end
            e.source = spec.source or e.source
            -- A pure duration refresh doesn't change what this table
            -- rolls, so it must not invalidate the overlay cache.
            if e.magnitude ~= before then
                self._status_rev = self._status_rev + 1
            end
            -- The second return says this landed on a table that ALREADY
            -- had it. "A tilt on an already tilted table" is a real trigger,
            -- and this is the only place that fact exists.
            --
            -- Except for heartbeat sources. A status re-applied on a timer
            -- would turn its upkeep into a proc trigger — the tank items
            -- listening on on_status_applied would convert the hum itself
            -- (sharp pinned at cap in seconds). `silent_refresh` says the
            -- FIRST landing is the event and the upkeep is not. No live
            -- source sets it today; it exists so the next ambient status
            -- doesn't reopen that hole.
            if not spec.silent_refresh then
                self:_announceStatus(kind, e.magnitude, spec.source, true)
            end
            self:_maybeInterrupt(def, spec)
            return true, true
        end
    end

    if #self.statuses >= STATUS_CAP then return false end
    if adds and def.stack_cap then mag = math.min(def.stack_cap, mag) end
    self.statuses[#self.statuses + 1] = {
        kind        = kind,
        magnitude   = mag,
        -- A "run" status carries NEITHER a timer nor charges, so both tick
        -- loops skip it (each guards on its field being present) and it
        -- lives until resetRun clears the saved list. That is what "for the
        -- rest of the run" means, without a third countdown to maintain.
        t           = (def.lifetime == "seconds") and (spec.t or 0) or nil,
        t_max       = (def.lifetime == "seconds") and (spec.t or 0) or nil,
        charges     = (def.lifetime == "charges") and (spec.charges or 0) or nil,
        charges_max = (def.lifetime == "charges") and (spec.charges or 0) or nil,
        source      = spec.source,
    }
    self._status_rev = self._status_rev + 1
    self:_announceStatus(kind, mag, spec.source, false)
    self:_maybeInterrupt(def, spec)
    return true, false
end

-- A status that declares an `interrupt` ends the hand it lands in, in its
-- own direction (data/statuses.lua).
--
-- Fires on a REFRESH as well as a new application. Restricting it to new
-- ones looked tidy and was wrong: a table under a continuous aura is
-- permanently heated, so every genuine heater that reached it was "just a
-- refresh" and nothing ever happened. One interrupt per hand is the honest
-- throttle, and Table:interrupt already enforces it.
--
-- An application can opt out with `no_interrupt`. That is for ambient
-- sources -- anything re-applied on a timer is a hum, not an event, and
-- would otherwise cut every hand short. No live source sets it today
-- (heat/tilt sources are all punches now); it stays as the guard a future
-- ambient application must reach for.
function Table:_maybeInterrupt(def, spec)
    local want = def and def.interrupt
    if not want then return end
    if spec and spec.no_interrupt then return end
    self:interrupt(want == "win")
end

-- Something landed here. The tank items are built on this: a table that
-- converts what it absorbs has to be told it absorbed something, and only
-- the table itself knows whether it already had one.
function Table:_announceStatus(kind, magnitude, source, was_refresh)
    if not self.bus then return end
    -- A status marked `silent` is a RESULT, not an event. The tank items
    -- convert what lands on a table into marks and sharpness, so if those
    -- announced themselves they would be their own input: one tilt fed
    -- itself 512 times and pinned the accumulator at its cap inside a
    -- single frame. Only the bus budget stopped it, which is a runaway
    -- guard doing a designer's job.
    local def = StatusData[kind]
    if def and def.silent then return end
    self.bus:publish("on_status_applied", {
        table = self, status = kind, magnitude = magnitude,
        source = source, was_refresh = was_refresh,
    })
end

-- Drop every punch-lifetime status (heater/tilt): the punch is spent —
-- or fizzled on a refused auto-deal. Tilt hands its lean to the
-- shake-off, same as a timed expiry. The list nils out when emptied so
-- the per-frame nil check stays the common case.
function Table:_expirePunchStatuses()
    if not self.statuses then return end
    for i = #self.statuses, 1, -1 do
        local e   = self.statuses[i]
        local def = StatusData[e.kind]
        if def and def.lifetime == "punch" then
            if (def.rotate or 0) > 0 then
                self.untilt_t   = 1
                self.untilt_mag = e.magnitude or 0
            end
            table.remove(self.statuses, i)
            self._status_rev = self._status_rev + 1
        end
    end
    if #self.statuses == 0 then self.statuses = nil end
end

function Table:_tickStatuses(d)
    for i = #self.statuses, 1, -1 do
        local e = self.statuses[i]
        if e.t then
            e.t = math.max(0, e.t - d)
            if e.t <= 0 then
                -- A status that had the table leaning hands the lean over
                -- to the shake-off, so the panel rights itself instead of
                -- snapping level between two frames.
                local def = StatusData[e.kind]
                if def and (def.rotate or 0) > 0 then
                    self.untilt_t   = 1
                    self.untilt_mag = e.magnitude or 0
                end
                table.remove(self.statuses, i)
                self._status_rev = self._status_rev + 1
            end
        end
    end
    if #self.statuses == 0 then self.statuses = nil end
end

-- Charge statuses are spent by DEALING, not by time. Called at the end of
-- :deal, past every early-out, so a hand that never started never burns
-- one. forceResolve goes through :update rather than :deal, so a cascaded
-- resolution correctly spends neither a charge nor a second of a timer.
function Table:_spendStatusCharges()
    if not self.statuses then return end
    for i = #self.statuses, 1, -1 do
        local e = self.statuses[i]
        if e.charges then
            e.charges = e.charges - 1
            if e.charges <= 0 then
                table.remove(self.statuses, i)
                self._status_rev = self._status_rev + 1
            end
        end
    end
    if #self.statuses == 0 then self.statuses = nil end
end

-- The ctx this table actually plays against.
--
-- Returns `base` BY IDENTITY when nothing is active — the overwhelmingly
-- common case allocates nothing, which matters at ~35 hands/sec across a
-- full board. Otherwise a shallow-copy overlay, cached until either the
-- base rollup or this table's statuses change.
--
-- The copy is not optional. ctx is ONE table shared by every Table (each
-- stashes it as _last_ctx), and several effect applicators APPEND to
-- list-valued fields — appending to the shared list would leak this
-- table's status onto every other table, permanently. Every table-valued
-- key is copied rather than an authored list of them, so a new
-- list-valued effect kind can never silently reintroduce that bug.
function Table:effectiveCtx(base)
    if not base or not self.statuses then return base end
    if self._ctx_ov and self._ctx_ov_base == base
       and self._ctx_ov_rev == self._status_rev then
        return self._ctx_ov
    end

    local ov = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            local c = {}
            for kk, vv in pairs(v) do c[kk] = vv end
            ov[k] = c
        else
            ov[k] = v
        end
    end

    local reg = self.effects_registry
    if reg then
        for _, e in ipairs(self.statuses) do
            local def = StatusData[e.kind]
            for _, tpl in ipairs((def and def.effects) or {}) do
                local m = (e.magnitude or 0) * (tpl.mag_sign or 1)
                if tpl.mag_form == "one_plus" then m = 1 + m end
                local entry = {}
                for k, v in pairs(tpl) do
                    if k ~= "mag_field" and k ~= "mag_sign" and k ~= "mag_form" then
                        entry[k] = v
                    end
                end
                -- `mag_field = false` means this template takes no
                -- magnitude: it is a fixed statement ("outcomes land a tier
                -- up") rather than a dial, and writing m into it would
                -- overwrite an authored field.
                if tpl.mag_field ~= false then
                    entry[tpl.mag_field or "value"] = m
                end
                reg:apply(entry, ov)
            end
        end
    end

    self._ctx_ov, self._ctx_ov_base, self._ctx_ov_rev = ov, base, self._status_rev
    return ov
end

-- Re-deal ONLY the opponent's hole so the showdown genuinely produces
-- `want_win`. The player's cards and the board stay exactly as they are:
-- they may already be face up, and a hand that rewrote what the player was
-- holding would read as a cheat rather than a swing.
--
-- Lives in models/HandRealism, which enumerates every remaining two-card
-- combination rather than sampling — see the notes there.

-- ─── THE INTERRUPT ──────────────────────────────────────────────────────
-- A heater or a tilt landing mid-hand ends that hand, now, in its own
-- direction. Without this a status could not touch the hand it arrived in
-- at all: everything about a hand is decided at deal, so at 18.5 seconds a
-- hand a six-second heater routinely lived and died inside one and changed
-- nothing.
--
-- It FAST-FORWARDS rather than truncates, and that is the whole design.
-- Cutting the script short would cash whatever small pot had gathered so
-- far, which turns a heater landing early on a hand that was going to win
-- big into a downgrade -- trading a stack for the blinds. Jumping the clock
-- instead lets the ordinary walker drain every remaining event through the
-- registry, so the pot fills to the size it was always going to reach and
-- the hand pays what it was worth. It ends where it was going to end, just
-- immediately.
function Table:interrupt(want_win, ctx)
    -- THE PUNCH ALWAYS LANDS. At minimum the NEXT hand goes this way —
    -- that latch is set first, unconditionally, so no path below can
    -- leave a lit status with nothing owed behind it. Everything after
    -- this line is the bonus half: ending the CURRENT hand too, taken
    -- only where a live cash hand can honestly be ended.
    self._forced_next_won = want_win

    -- No live hand — there is only the next, already latched.
    if self.state == "idle" or self.state == "settling" then return true end
    -- Tournaments: no mid-hand rewrite of a scripted multiway hand (the
    -- pot is the bust schedule, _reconcileChipFlow owns the delta). The
    -- whole punch defers to the next hand, where the deal override
    -- rewrites the PLAN's outcome instead (see the chip-stack branch of
    -- :deal).
    local gtype = Lookups.findById(GameTypesData, self.game_type_id)
    if gtype and gtype.chip_stack_table then return true end
    -- Script spent / missing: nothing left to fast-forward.
    if not self.script or self.script_idx >= #self.script then return true end
    -- Once per hand. An interrupt resolves a hand, a resolution fires
    -- procs, and a proc can apply a status: without this it can re-enter.
    -- The latch above still moved, so a second punch chains to the next
    -- hand rather than vanishing.
    if self._interrupted then return true end
    -- The push must still be ahead of us; past it the hand is spent.
    local last = self.script[#self.script]
    if not last or last.kind ~= "pot_push" then return true end

    self._interrupted = true

    -- Flip the side, and make the cards say so.
    if self.outcome_won ~= want_win then
        -- Only a FLIP recomputes the money. A same-side interrupt is a pure
        -- fast-forward and must leave outcome_delta exactly alone: the
        -- deal-time payout and the script's pot are two independent
        -- computations of the same hand (dollars against big blinds, and
        -- the payout carries earnings/jackpot multipliers the script never
        -- sees), so recomputing one from the other would quietly change
        -- what a hand pays just because a status touched it.
        --
        -- Predict the final pot by summing what has not played yet. The
        -- view reads outcome_delta and outcome_tier at the moment pot_push
        -- dispatches, so both have to be final BEFORE the drain -- which
        -- means projecting rather than measuring. Deterministic, no rolls.
        local ps = self.playback_state or {}
        local pot = ps.pot or 0
        local mine = (ps.per_seat_total
                      and ps.per_seat_total[self.player_seat_fixed]) or 0
        for i = self.script_idx + 1, #self.script - 1 do
            local ev = self.script[i]
            local amt = ev and ev.amount or 0
            if amt > 0 then
                pot = pot + amt
                if ev.seat == self.player_seat_fixed then mine = mine + amt end
            end
        end

        self.outcome_won = want_win
        -- The tier stays for the felt, but a flipped hand is not the chip
        -- event: jackpot-keyed triggers (bounty, cascade, lifetime count)
        -- gate on this in the controller's resolution loop.
        self.outcome_flipped = true
        local o_hole = HandRealism.redealOpponent(
            self.player_hole, self.community, want_win,
            { policy = ShowdownRealism, gtype_id = self.game_type_id })
        if o_hole then
            self.opponent_hole = o_hole
            self.player_hand_name,   self.player_combo   =
                HandEval.handLabel(self.player_hole, self.community)
            self.opponent_hand_name, self.opponent_combo =
                HandEval.handLabel(o_hole, self.community)
        end
        -- The push goes to whoever now wins it.
        if want_win then
            last.seat = self.player_seat_fixed
        elseif last.seat == self.player_seat_fixed then
            for s in pairs((self.playback_state or {}).in_seats or {}) do
                if s ~= self.player_seat_fixed then last.seat = s; break end
            end
        end

        -- The HandScript contract, straight out of the projection: a win
        -- nets the pot minus what the player put in, a loss nets minus what
        -- they put in. The same arithmetic the writer used, so the felt and
        -- the payout cannot disagree -- and it caps a flipped loss at the
        -- player's own stack for free, because that is all they ever put in.
        self.outcome_delta = want_win and (pot - mine) or -mine
        last.amount = pot
    end

    -- Deal the next hand the same way this one just went. One hand is a
    -- blip; two in a row is a moment.
    self._forced_next_won = want_win

    -- Move the clock and stop. Deliberately NOT calling :update here the
    -- way forceResolve does: that returns the resolution to its caller,
    -- and forceResolve has one waiting (the cascade payload appends it to
    -- the list being drained). An interrupt is fired from applyStatus,
    -- which has nobody to hand it to -- so resolving inline would swallow
    -- the resolution and the hand would never be paid. The pool's next
    -- tick drains it through the ordinary path instead.
    self.script_timer = (last.t or 0) + 1
    return true
end

function Table:forceResolve(ctx)
    if self.state == "idle" or self.state == "settling" then return nil end
    if not self.script or self.script_idx >= #self.script then return nil end
    local last = self.script[#self.script]
    self.script_timer = (last and last.t or 0) + 1
    return self:update(0, ctx or self._last_ctx)
end

-- Settling-phase end: log the result, increment hands_played, drop hole
-- and community cards, return to idle. Extracted so the timeline walker
-- has one tidy call site at end-of-list.
function Table:_finalizeHand()
    self.last_results[#self.last_results + 1] = {
        won   = self.outcome_won,
        delta = self.outcome_delta,
        tier  = self.outcome_tier,
    }
    if #self.last_results > LAST_RESULTS_CAP then
        table.remove(self.last_results, 1)
    end
    self.hands_played  = self.hands_played + 1
    -- Per-hand latch: the next hand may be interrupted in its own right.
    self._interrupted  = false
    -- The tilt's forced loss has fully run its course. Announced at the
    -- END of that hand, not at deal, so a converter (Waste Basket) reacts
    -- to the beat being over rather than to it starting.
    if self._tilt_spent_pending then
        self._tilt_spent_pending = nil
        if self.bus then
            self.bus:publish("on_tilt_spent", { table = self })
        end
    end
    -- The hand that just finished was the punch's forced hand (latched
    -- at :deal) — the punch is SPENT, so the status that carried it
    -- expires now. This is the whole lifetime of a "punch" status: lit
    -- from landing to here, so the fire and the mechanic can never
    -- disagree (and the auto-deal in :update means "here" is at most one
    -- hand after landing).
    if self._punch_live then
        self._punch_live = nil
        self:_expirePunchStatuses()
    end
    -- Snapshot the finished hand before the clears below destroy it. The
    -- felt keeps drawing this (desaturated) until the next :deal removes
    -- it. Keys deliberately mirror both tbl.* and playback_state.* names
    -- so the view can substitute the snapshot for either source.
    -- Reference copies are safe: :deal builds fresh arrays every hand.
    local ps = self.playback_state or {}
    self.last_hand = {
        community          = self.community,
        player_hole        = self.player_hole,
        opponent_hole      = self.opponent_hole,
        player_hand_name   = self.player_hand_name,
        opponent_hand_name = self.opponent_hand_name,
        player_combo       = self.player_combo,
        opponent_combo     = self.opponent_combo,
        opponent_idx       = self.opponent_idx,
        outcome_delta      = self.outcome_delta,
        outcome_won        = self.outcome_won,
        community_count    = ps.community_count or (self.community and #self.community) or 0,
        in_seats           = ps.in_seats,
        player_seat        = ps.player_seat,
        button_visual_seat = ps.button_visual_seat or self.button_visual_seat,
        n_seats            = ps.n_seats,
        opp_revealed       = ps.opp_revealed == true,
        winner             = ps.winner,
    }
    self.state         = "idle"
    self.state_timer   = 0
    self.timeline      = nil
    self.phase_idx     = nil
    self.script           = nil
    self.script_idx       = 0
    self.script_timer     = 0
    self.script_total     = nil
    self.view_event_cursor   = 0
    self.playback_state   = nil
    self.player_hole   = nil
    self.opponent_hole = nil
    self.community     = nil
    self.player_hand_name   = nil
    self.opponent_hand_name = nil
    self.player_combo       = nil
    self.opponent_combo     = nil
    -- Slam to rest in the same frame the resolution fires. Without this
    -- the lift decay runs ONCE per :update at the top, BEFORE the
    -- cinematic walker reaches _finalizeHand — so the resolution frame
    -- still sees state="settling" and keeps lift_t at 1; the drop only
    -- happens in the next update. Setting it here closes that gap so the
    -- slam coincides with the chip burst, floater, border pulse, etc.
    self.lift_t        = 0

    -- Tournament auto-advance for chip-stack tables. On each hand:
    --   * Bump mtt.hands_won (lifetime deck-XP / stat tracking).
    --   * Reconcile the plan against actual chip flow.
    --   * Advance the plan cursor.
    --   * Detect end conditions:
    --       - Player busted → settle with finish_position based on
    --         bust order (1 = winner, n_seats = first bust).
    --       - All non-player seats busted → player wins, finish 1.
    --       - Else → auto-deal the next hand.
    -- We re-use the latest ctx stashed on :update / :deal so the new
    -- hand samples WC against the player's current effects rollup.
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if gtype and gtype.chip_stack_table and self.mtt:isPlaying() then
        if self.outcome_won then
            self.mtt:winHand()
        end
        local n_seats = (gtype.seats or 0) + 1
        local player_seat = self.player_seat_fixed

        -- Build the list of seats that busted DURING this hand (not
        -- cumulative). _pre_hand_bust_count was snapshotted in :deal.
        local new_busts = {}
        local pre_count = self._pre_hand_bust_count or 0
        if self.bust_order then
            for i = pre_count + 1, #self.bust_order do
                new_busts[#new_busts + 1] = self.bust_order[i]
            end
        end

        -- Advance the plan cursor BEFORE reconcile so reconcile's two
        -- arithmetic anchors line up:
        --   * "next_hand_idx - 1" identifies the hand that just finished
        --     (used to decide which scheduled busts were expected).
        --   * "next_hand_idx" identifies the upcoming hand (used to
        --     overwrite the re-attack outcome).
        self.mtt:advanceHand()
        -- Patch the plan: drop seats that busted incidentally; re-attack
        -- planned busts that didn't materialize (extends up to +3 hands).
        self.mtt:reconcile(new_busts, self.seat_busted, n_seats, player_seat)

        local player_busted = self.seat_busted and self.seat_busted[player_seat] == true
        local alive_opps = 0
        for s = 1, n_seats do
            if s ~= player_seat and not self.seat_busted[s] then
                alive_opps = alive_opps + 1
            end
        end
        if player_busted then
            -- Player's finish position = (alive_opps_when_player_busts) + 1.
            -- If 5 opps alive when player busts: player is 6th (3rd place
            -- among 8 seats once the other 5 also bust). Player's order
            -- among finishers is determined by who's still alive AT THE
            -- MOMENT they bust.
            local finish_position = alive_opps + 1
            self:_endTournament(finish_position, n_seats)
        elseif alive_opps == 0 then
            self:_endTournament(1, n_seats)
        elseif gtype.auto_deal then
            self:deal(self._last_ctx)
        end
    elseif self._forced_next_won ~= nil then
        -- An interrupted hand deals its successor immediately: one hand
        -- ending abruptly is a glitch, two in a row going the same way is
        -- a moment. The forced side is consumed by this deal.
        self:deal(self._last_ctx)
    end
end

-- Settle the tournament: stash the payout on self.mtt for the controller to
-- drain, clear chip-stack state, and zero the stack so the panel renders
-- REBUY. Payout is read from data/mtt_payouts.lua keyed by
-- (n_seats - finish_position + 1) — so 1st=8, 2nd=7, 3rd=6, 4th+ gets no
-- entry and pays nothing. The Plastic Trophy / Engraved Plaque perks
-- still raise the floor at lower finishes via ctx.mtt_payout_boost.
function Table:_endTournament(finish_position, n_seats)
    local stake   = Lookups.findById(StakesData,self.stake_id)
    local boost   = (self._last_ctx and self._last_ctx.mtt_payout_boost) or 0
    local payouts = MttPayouts[boost] or MttPayouts[0]
    local buy_in  = (stake and stake.buy_in) or 0
    self.last_finish = finish_position
    -- Lifetime tournaments THIS TABLE has completed, any finish position.
    -- High Roller Pass derives its stake backing from these counts across
    -- the open tournament tables (GrindController:invalidateEffects), so
    -- closing the table is what retires its contribution.
    self.mtt.finish_count = (self.mtt.finish_count or 0) + 1
    self.mtt:settle(buy_in, payouts, finish_position, n_seats, self._last_ctx)
    -- Per-seat state (seat_stacks / seat_busted / player_seat_fixed /
    -- button_seat / bust_order) is left in place — the post-tournament
    -- panel renders the final bust pattern until the player rebuys.
    -- The next _initChipStackIfNeeded (fired from deal() after rebuy)
    -- overwrites everything for the fresh run.
    self.stack    = 0  -- triggers REBUY rendering in TablePanel
end

-- Read-only summary the view header pulls each frame.
function Table:liveStats(_ctx)
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake then return nil end
    return {
        stake_display   = stake.display_name,
        bb              = stake.bb,
        buy_in          = stake.buy_in,
        game_type_id    = self.game_type_id,
        game_type_short = (gtype and gtype.short) or "",
        seats           = (gtype and gtype.seats) or #self.opponents,
    }
end

function Table:isBusy()
    return self.state ~= "idle"
end

-- ─── Estimation (UI gauge) ────────────────────────────────────────────
-- Build the expected outcome tuple for this (stake, game_type, ctx). With
-- player types ripped, every hand at a given (stake, gtype, ctx) draws from
-- the same outcome — no per-seat variance to average over — so this is
-- just a single buildOutcome call.

function Table:tableOutcome(ctx)
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return nil end
    return OutcomeMath.buildOutcome(ctx or {}, gtype, stake)
end

-- Debug-only: pool stats for the backtick debug tooltip. Without per-seat
-- mechanical variance, there's no per-opponent breakdown to compute — every
-- seat at a given (stake, gtype, ctx) shares the same outcome.
-- Both readouts price against THIS table's ctx (statuses included), not
-- the global rollup — otherwise a heated table's panel would quote a win
-- chance and $/hand it isn't actually playing. Identical to the raw ctx
-- whenever no status is active. The stake-add buttons in the sidebar
-- deliberately stay on the raw ctx: they describe a table you haven't
-- opened, which by definition has no statuses.
function Table:debugStats(ctx)
    return OutcomeMath.evStats(self:effectiveCtx(ctx),
        Lookups.findById(GameTypesData, self.game_type_id),
        Lookups.findById(StakesData, self.stake_id))
end

function Table:estimateStats(ctx)
    if #self.opponents == 0 then return nil end
    local s = OutcomeMath.evStats(self:effectiveCtx(ctx),
        Lookups.findById(GameTypesData, self.game_type_id),
        Lookups.findById(StakesData, self.stake_id))
    if not s then return nil end
    -- Flat shape the EV readout expects (drawEvReadout).
    return {
        ev_per_hand = s.pool.ev_per_hand,
        win_chance  = s.pool.win_chance,
        win_dist    = s.pool.win_dist,
        loss_dist   = s.pool.loss_dist,
    }
end

return Table
