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
--   6. Construct cards (rejection sampling) so best5(player) beats / loses
--      to best5(opp), matching the rolled `won`.

local RNG           = require("utils.rng")
local Deck          = require("models.Deck")
local Opponent      = require("models.Opponent")
local HandEval      = require("models.HandEval")
local MttSession    = require("models.MttSession")
local StakesData    = require("data.stakes")
local GameTypesData = require("data.game_types")
local NameData      = require("data.opponent_names")
local MttPayouts    = require("data.mtt_payouts")
local Lookups       = require("utils.lookups")
local Constants     = require("data.constants")
local HandScript    = require("models.HandScript")
local OutcomeMath   = require("models.outcome_math")
local PokerActionWeights = require("data.poker_action_weights")
local PokerBetSizing     = require("data.poker_bet_sizing")
local PokerEventTimings  = require("data.poker_event_timings")
local HandStructure      = require("data.hand_structure")

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
local CONSTRUCTION_CAP = 200

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

function Table:new(stake_id, game_type_id, ctx, poker_events)
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
                end
            end
            self.seat_stacks[seat] = stack
        end
    end

    local new_stack = self.seat_stacks[player_seat] or 0
    self.stack = new_stack
    return new_stack - old_stack
end

-- ─── Per-hand math ────────────────────────────────────────────────────

local function constructHand(want_win)
    local p_hole, o_hole, board
    for _ = 1, CONSTRUCTION_CAP do
        local deck = Deck:new()
        p_hole = { deck:draw(), deck:draw() }
        o_hole = { deck:draw(), deck:draw() }
        board  = { deck:draw(), deck:draw(), deck:draw(), deck:draw(), deck:draw() }

        local p_cards, o_cards = {}, {}
        for _, c in ipairs(p_hole) do table.insert(p_cards, c) end
        for _, c in ipairs(board)  do table.insert(p_cards, c) end
        for _, c in ipairs(o_hole) do table.insert(o_cards, c) end
        for _, c in ipairs(board)  do table.insert(o_cards, c) end

        local p_rank = HandEval.bestFiveOfN(p_cards)
        local o_rank = HandEval.bestFiveOfN(o_cards)
        local p_wins = HandEval.compare(p_rank, o_rank) > 0
        if p_wins == want_win then
            return p_hole, o_hole, board, true
        end
    end
    return p_hole, o_hole, board, false
end

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
        local wc, wd, ld = OutcomeMath.buildOutcome(ctx, gtype, stake)
        won, tier = OutcomeMath.sampleOutcome(wc, wd, ld, ctx, gtype)
        if won then
            tier = OutcomeMath.applyTierShift(tier, ctx.win_tier_shifts, gtype)
        else
            tier = OutcomeMath.applyTierShift(tier, ctx.loss_tier_shifts, gtype)
        end
    end

    -- Per-resolve tier bump + payout double (Maniac capstone). Generic
    -- capability flags — one-step, non-chaining bump via the shared tier
    -- ranking; magnitude double applied below.
    local payout_double = 1.0
    if ctx then
        if ctx.tier_bump_chance and love.math.random() < ctx.tier_bump_chance then
            local rank = OutcomeMath.TIER_INDEX[tier]
            if rank then
                tier = OutcomeMath.TIER_KEYS[math.min(#OutcomeMath.TIER_KEYS, rank + 1)]
            end
        end
        if ctx.payout_double_chance and love.math.random() < ctx.payout_double_chance then
            payout_double = 2.0
        end
    end

    local magnitude_bb = OutcomeMath.rollTierMagnitude(tier, gtype, won)

    self.outcome_won  = won
    self.outcome_tier = tier

    -- earnings_mult / loss_mult scale magnitude only — they don't reshape
    -- the dists (Pot Odds Master, Damage Control, Headphones).
    local earnings_mult = ctx.earnings_mult or 1
    if ctx.earnings_per_tier then
        local tier_idx = stake and Lookups.indexById(StakesData, stake.id) or 0
        earnings_mult = earnings_mult * (1.0 + ctx.earnings_per_tier * tier_idx)
    end
    local loss_mult     = ctx.loss_mult     or 1
    -- jackpot_mult (Branded Hat) stacks on top of earnings_mult — only
    -- jackpot-tier WINS get the extra boost.
    local jackpot_mult  = (won and tier == "jackpot")
                          and (ctx.jackpot_mult or 1) or 1
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

    local p_hole, o_hole, board, natural = constructHand(won)
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
    return true
end

-- ─── Animation tick ───────────────────────────────────────────────────

-- Decay rates per-second. Tuned for visible punch — slow enough that the
-- effect lingers long enough to read, fast enough not to fight the next
-- hand's animation.
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

function Table:update(dt, ctx)
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

    if self.state == "idle" then return nil end

    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    local pace_mult = (gtype and gtype.pace_mult) or 1
    -- ctx.hand_pace_mult (Energy Drink, future pace items) compounds on
    -- top of the gtype baseline.
    local ctx_pace = (self._last_ctx and self._last_ctx.hand_pace_mult) or 1
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
            if gtype and gtype.chip_stack_table then
                resolved_delta = self:_reconcileChipFlow()
                self.outcome_delta = resolved_delta
            end
            self.state       = "settling"
            self.state_timer = 0
            self._pending_resolution = {
                won   = self.outcome_won,
                delta = resolved_delta,
                tier  = self.outcome_tier,
                x     = self.x,
                y     = self.y,
                chip_stack_table = gtype and gtype.chip_stack_table or false,
                felt_pot = self.playback_state and self.playback_state.pot_at_push or 0,
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
function Table:debugStats(ctx)
    return OutcomeMath.evStats(ctx,
        Lookups.findById(GameTypesData, self.game_type_id),
        Lookups.findById(StakesData, self.stake_id))
end

function Table:estimateStats(ctx)
    if #self.opponents == 0 then return nil end
    local s = OutcomeMath.evStats(ctx,
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
