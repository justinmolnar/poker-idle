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
local MttSession    = require("models.MttSession_legacy")
local StakesData    = require("data.stakes")
local GameTypesData = require("data.game_types")
local NameData      = require("data.opponent_names")
local PotTiers      = require("data.pot_tiers")
local Timelines     = require("data.cinematic_timelines")
local MttPayouts    = require("data.mtt_payouts")
local Lookups       = require("utils.lookups")
local Constants     = require("data.constants")
local HandScript    = require("models.HandScript_legacy")
local PokerActionWeights = require("data.poker_action_weights")
local PokerBetSizing     = require("data.poker_bet_sizing")
local PokerEventTimings  = require("data.poker_event_timings")

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

-- Cinematic timeline lookup. Per-(gtype, tier) lists of {state, duration}
-- live in data/cinematic_timelines.lua; we resolve at deal-time and walk
-- the list by index in :update.
local function resolveTimeline(gtype_id, tier)
    local key = (gtype_id or "") .. ":" .. (tier or "")
    return Timelines.overrides[key]
        or Timelines.overrides[gtype_id]
        or Timelines.default
end

-- ─── Helpers ──────────────────────────────────────────────────────────

local function sampleDist(dist)
    if not dist then return nil end
    local total = 0
    for _, p in pairs(dist) do total = total + p end
    if total <= 0 then
        for k in pairs(dist) do return k end
    end
    local r = love.math.random() * total
    local acc = 0
    for k, p in pairs(dist) do
        acc = acc + p
        if r <= acc then return k end
    end
    for k in pairs(dist) do return k end
end

local function pickRandomName()
    return NameData[love.math.random(1, #NameData)]
end

-- ─── Outcome model ────────────────────────────────────────────────────

local TIER_KEYS = { "small", "medium", "large", "jackpot" }

-- ── Distribution helpers ──
local function distCopy(src)
    local d = {}
    if src then
        for _, t in ipairs(TIER_KEYS) do d[t] = src[t] or 0 end
    else
        for _, t in ipairs(TIER_KEYS) do d[t] = 0 end
    end
    return d
end

local function distAddInPlace(dst, delta)
    if not delta then return end
    for k, v in pairs(delta) do
        dst[k] = (dst[k] or 0) + v
    end
end

local function distClampAndNormalize(d)
    for _, t in ipairs(TIER_KEYS) do
        if (d[t] or 0) < 0 then d[t] = 0 end
    end
    local s = 0
    for _, t in ipairs(TIER_KEYS) do s = s + (d[t] or 0) end
    if s <= 0 then
        d.small, d.medium, d.large, d.jackpot = 1, 0, 0, 0
        return
    end
    for _, t in ipairs(TIER_KEYS) do d[t] = d[t] / s end
end

-- ── Pipeline helpers ──

local WC_ABSOLUTE_CAP = 0.95   -- final WC ceiling regardless of fill/shifts

-- Returns true if the descriptor's filters match (opp, gtype). Shared by
-- fill descriptors AND legacy shift descriptors (both carry skill/style/gtype).
-- Returns true if the descriptor's gtype filter matches the table's
-- game-type. (Skill / style filters were removed when player types were
-- ripped — the only filter dimension that survived is gtype.)
local function shiftApplies(shift, gtype)
    if shift.gtype and shift.gtype ~= gtype.id then return false end
    return true
end

-- Sum strength across descriptors that match this gtype.
local function sumFills(list, gtype)
    if not list then return 0 end
    local total = 0
    for _, d in ipairs(list) do
        if shiftApplies(d, gtype) then
            total = total + (d.strength or 1)
        end
    end
    return total
end

-- Convert fill units to a [0, 1] ratio via the stake's fill_window.
-- Below window.start: 0 (warmup). At window.complete: 1. Linear in between.
local function fillRatio(units, window)
    if not window then return 1 end
    local start    = window.start    or 0
    local complete = window.complete or (start + 1)
    local span     = complete - start
    if span <= 0 then return units >= complete and 1 or 0 end
    local r = (units - start) / span
    if r < 0 then return 0 end
    if r > 1 then return 1 end
    return r
end

-- Linear interpolation between two distributions (per-tier).
local function lerpDist(naked, capped, t)
    local d = {}
    for _, k in ipairs(TIER_KEYS) do
        local a = (naked  and naked[k])  or 0
        local b = (capped and capped[k]) or a
        d[k] = a + (b - a) * t
    end
    return d
end

-- Build the effective (win_chance, win_dist, loss_dist) tuple for the
-- table, given the player ctx. Returns three fresh values; caller may
-- mutate the dist tables freely. (Opponents no longer carry per-seat
-- mechanical traits, so this no longer needs an `opp` argument.)
local function buildOutcome(ctx, gtype, stake)
    -- 1. Sum fill units per dimension (filtered by gtype).
    local wc_units = sumFills(ctx and ctx.win_chance_fills, gtype)
    local wd_units = sumFills(ctx and ctx.win_dist_fills,   gtype)
    local ld_units = sumFills(ctx and ctx.loss_dist_fills,  gtype)

    -- 2. Convert to fill ratio via stake's window.
    local window = stake and stake.fill_window
    local wc_fill = fillRatio(wc_units, window)
    local wd_fill = fillRatio(wd_units, window)
    local ld_fill = fillRatio(ld_units, window)

    -- 3. Lerp naked → run-capped on each dimension.
    local naked_wc  = (stake and stake.win_chance)        or 0
    local capped_wc = (stake and stake.win_chance_capped) or naked_wc
    local win_chance = naked_wc + (capped_wc - naked_wc) * wc_fill
    local win_dist   = lerpDist(stake and stake.win_dist,  stake and stake.win_dist_capped,  wd_fill)
    local loss_dist  = lerpDist(stake and stake.loss_dist, stake and stake.loss_dist_capped, ld_fill)

    -- 4. Per-gtype additive shape on both dists (depth/pace texture).
    if gtype and gtype.dist_shifts then
        distAddInPlace(win_dist,  gtype.dist_shifts.win_dist)
        distAddInPlace(loss_dist, gtype.dist_shifts.loss_dist)
    end

    -- 4b. Catalog ctx.loss_dist_shifts — additive shape on the loss
    --     distribution (mirror of gtype dist_shifts on the loss side).
    --     Used by the no-poster handicap to skew Run-0 losses toward
    --     Medium+. Renormalized at step 7.
    if ctx and ctx.loss_dist_shifts then
        for _, sh in ipairs(ctx.loss_dist_shifts) do
            if shiftApplies(sh, gtype) then
                distAddInPlace(loss_dist, sh.shift)
            end
        end
    end

    -- 4c. Catalog/deck ctx.win_dist_shifts — same mechanism, win side.
    --     Optional tier_min / tier_max bounds let tier-scoped decks
    --     (e.g. Low Stakes Hero) reshape the win-dist only at certain
    --     stakes. Stake tier index is the 1-based position in the
    --     Stakes data list — looked up via Lookups.indexById.
    if ctx and ctx.win_dist_shifts then
        local tier_idx = stake and Lookups.indexById(StakesData, stake.id) or nil
        for _, sh in ipairs(ctx.win_dist_shifts) do
            local tier_ok = (not sh.tier_min or (tier_idx and tier_idx >= sh.tier_min))
                            and (not sh.tier_max or (tier_idx and tier_idx <= sh.tier_max))
            if shiftApplies(sh, gtype) and tier_ok then
                distAddInPlace(win_dist, sh.shift)
            end
        end
    end

    -- 5. Catalog ctx.win_chance_shifts — flat additive ON TOP of the lerp.
    --    The only mechanism for crossing run-capped toward the absolute cap.
    if ctx and ctx.win_chance_shifts then
        for _, shift in ipairs(ctx.win_chance_shifts) do
            if shiftApplies(shift, gtype) then
                win_chance = win_chance + (shift.amount or 0)
            end
        end
    end

    -- 6. Per-gtype WC shift — gives modes a real win-rate identity (Zoom
    --    higher, HU lower) instead of only shaping dists. Treated as
    --    additive on top of catalog shifts so HU Specialist still works.
    if gtype and gtype.win_chance_shift then
        win_chance = win_chance + gtype.win_chance_shift
    end

    -- 6b. Multiplicative final-WC modifier (no-poster handicap, future
    --     skill discounts). Applied AFTER all additive shifts so the
    --     handicap multiplies the *effective* WC, not the lerped baseline.
    if ctx and ctx.wc_mult then
        win_chance = win_chance * ctx.wc_mult
    end

    -- 7. Jackpot emergence (MUST mirror models/outcome_math step 7 — this is the
    --    Table_legacy copy). For gtypes with `jackpot_emerge`, overwrite the
    --    jackpot cell: ramp it from the emerge fill point up to its target
    --    (stake capped jackpot + the gtype's jackpot shift), so the Stack rate
    --    climbs gradually over the upgrade's top levels instead of dumping the
    --    whole gain into the final level. Without this the legacy path showed a
    --    near-zero stack rate (the lerp+shift cancel out) — the Pot Control ramp
    --    silently broke in the prototype.
    if gtype and gtype.jackpot_emerge then
        local sh     = gtype.dist_shifts and gtype.dist_shifts.win_dist
        local offset = (sh and sh.jackpot) or 0
        local capped = (stake and stake.win_dist_capped and stake.win_dist_capped.jackpot) or 0
        local target = capped + offset
        if target < 0 then target = 0 end
        local thr  = gtype.jackpot_emerge
        local ramp = (wd_fill - thr) / math.max(1e-6, 1 - thr)
        if ramp < 0 then ramp = 0 elseif ramp > 1 then ramp = 1 end
        win_dist.jackpot = target * ramp
    end

    -- 8. Final clamps. Absolute WC ceiling (no 100% wins).
    if     win_chance < 0                 then win_chance = 0
    elseif win_chance > WC_ABSOLUTE_CAP   then win_chance = WC_ABSOLUTE_CAP end
    distClampAndNormalize(win_dist)
    distClampAndNormalize(loss_dist)

    return win_chance, win_dist, loss_dist
end

-- Sample (won, tier) from the 3-distribution outcome.
--
-- Auto-win check fires BEFORE the WC roll: for each ctx.auto_win_chances
-- entry whose gtype filter passes, sum the `amount` and roll once against
-- the total. A successful roll forces won=true regardless of the natural
-- win_chance — used by MTT Pro to flat-bump cash rate without touching
-- the fill / distribution pipeline.
local function sampleOutcome(win_chance, win_dist, loss_dist, ctx, gtype)
    local won = false
    if ctx and ctx.auto_win_chances then
        local total = 0
        for _, e in ipairs(ctx.auto_win_chances) do
            if shiftApplies(e, gtype) then
                total = total + (e.amount or 0)
            end
        end
        if total > 0 and love.math.random() < total then
            won = true
        end
    end
    if not won then
        won = love.math.random() < win_chance
    end
    local tier = sampleDist(won and win_dist or loss_dist) or "small"
    return won, tier
end

-- Walk the shift list, bumping the current tier whenever (a) the gtype
-- filter matches, (b) the descriptor's `from` equals the current tier, and
-- (c) the chance roll succeeds. Bumps chain by design: Self-Help Book
-- (Small→Medium @25%) + Lava Lamp (Medium→Large @15%) can take a hand from
-- Small → Medium → Large in one resolve. Walk order = registration order
-- in poker_effects.lua; deterministic per build.
local function applyTierShift(tier, shifts, gtype)
    if not shifts then return tier end
    for _, sh in ipairs(shifts) do
        if shiftApplies(sh, gtype) and tier == sh.from
           and love.math.random() < (sh.chance or 0) then
            tier = sh.to
        end
    end
    return tier
end

-- Roll a magnitude (in bb) within the cell's tier range.
local function rollTierMagnitude(tier)
    local r = PotTiers[tier]
    if not r then return 0 end
    return r.lo + love.math.random() * (r.hi - r.lo)
end

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
        -- mutates the table's playback state as each event fires). Only
        -- consulted when FEATURES.POKER_THEATER is on; nil otherwise is
        -- harmless because the script branch is never entered.
        poker_events  = poker_events,
        script             = nil,
        script_idx         = 0,
        script_timer       = 0,
        playback_state     = nil,
        view_event_cursor     = 0,

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
        -- at hands_won=0/state=nil so the MTT branches in :_finalizeHand
        -- and the controller no-op. Only meaningful when the gtype carries
        -- binary_outcome=true. See models/MttSession for the lifecycle.
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

    -- Build the table's outcome and sample. Opponents no longer affect
    -- the math — they're cosmetic seats.
    local wc, wd, ld = buildOutcome(ctx, gtype, stake)
    local won, tier = sampleOutcome(wc, wd, ld, ctx, gtype)

    -- Post-sample tier re-rolls (Self-Help Book / Lava Lamp on the win
    -- side; Stress Ball / Worry Stone on the loss side). Each shift fires
    -- independently and can chain — see applyTierShift comment.
    if won then
        tier = applyTierShift(tier, ctx.win_tier_shifts, gtype)
    else
        tier = applyTierShift(tier, ctx.loss_tier_shifts, gtype)
    end

    local magnitude_bb = rollTierMagnitude(tier)

    self.outcome_won  = won
    self.outcome_tier = tier

    -- Binary-outcome (MTT): magnitude doesn't matter; only the win/loss
    -- bit affects state. Skip the $-delta math entirely and force the
    -- delta to 0 so the controller's stack/bankroll mutators no-op.
    if gtype.binary_outcome then
        self.outcome_delta = 0
        self.mtt:begin()
    else
        -- earnings_mult / loss_mult scale magnitude only — they don't reshape
        -- the dists (Pot Odds Master, Damage Control, Headphones).
        local earnings_mult = ctx.earnings_mult or 1
        local loss_mult     = ctx.loss_mult     or 1
        -- jackpot_mult (Branded Hat) stacks on top of earnings_mult — only
        -- jackpot-tier WINS get the extra boost.
        local jackpot_mult  = (won and tier == "jackpot")
                              and (ctx.jackpot_mult or 1) or 1
        if won then
            local raw_win = magnitude_bb * stake.bb * earnings_mult * jackpot_mult
            -- Pot cap: a hand's pot is at most 2× your at-table stack
            -- (your contribution + opponent matching it). So the most
            -- you can WIN from a hand is 2× stack. A $0.05 stack tops
            -- out at $0.10; a full $2 stack at $4. Keeps low-stack
            -- jackpots from feeling like free money while still letting
            -- a healthy stack catch a real haul.
            self.outcome_delta = math.min(raw_win, 2 * (self.stack or 0))
        else
            -- Loss side already capped downstream: GrindController clamps
            -- stack at 0 in its resolution loop.
            self.outcome_delta = -magnitude_bb * stake.bb * loss_mult
        end
    end

    local p_hole, o_hole, board, natural = constructHand(won)
    self.player_hole     = p_hole
    self.opponent_hole   = o_hole
    self.community       = board
    self.natural_outcome = natural

    -- Hand-name labels for showdown reveal. Computed once at deal time
    -- so the view doesn't recompute every frame. HandEval.describe
    -- returns e.g. "pair of Aces" / "trip 7s" / "Ace-high flush".
    -- Cleared in :_finalizeHand so they don't leak across hands.
    -- Name + best-5 combo for each side (the combo drives the view's showdown
    -- emphasis). One shared HandEval.handLabel so this can't drift from the
    -- copy in models/Table.
    self.player_hand_name,   self.player_combo   = HandEval.handLabel(p_hole, board)
    self.opponent_hand_name, self.opponent_combo = HandEval.handLabel(o_hole, board)

    -- Cinematic setup. Two paths gated by FEATURES.POKER_THEATER:
    --   * Theater on  → models/HandScript.write composes a per-hand
    --                   event list (post_blind, fold, call, raise,
    --                   deal_*, pot_push). :update walks events by
    --                   timestamp; the view reads playback_state.
    --   * Theater off → existing timeline walk (rigid phase sequence
    --                   from data/cinematic_timelines).
    if Constants.FEATURES and Constants.FEATURES.POKER_THEATER then
        self.script_idx     = 0
        self.script_timer   = 0
        self.view_event_cursor = 0
        -- gtype.seats is the OPPONENT count (5 for six-max, 1 for HU,
        -- etc.), not the total. Total seats includes the player.
        local n_seats = ((gtype and gtype.seats) or 5) + 1
        local player_seat = love.math.random(1, n_seats)
        local button_seat = love.math.random(1, n_seats)
        self.playback_state = {
            n_seats             = n_seats,
            player_seat         = player_seat,
            in_seats            = {},
            n_in                = n_seats,
            pot                 = 0,
            current_bet         = 0,
            per_seat_committed  = {},
            per_seat_total      = {},
            community_count     = 0,
            player_revealed     = false,
            opp_revealed        = false,
            winner              = nil,
        }
        for i = 1, n_seats do self.playback_state.in_seats[i] = true end
        -- Cap the writer's contribution target at the player's available
        -- stack. The bb-tier roll can exceed what the player can actually
        -- put in; without this cap the script keeps generating call
        -- events past the all-in point and the displayed stack tries to
        -- drain below zero. (The bankroll math already clamps at stack
        -- in GrindController's resolution loop, so r.delta lands correctly
        -- regardless of what the script depicts.)
        local stake_bb        = (stake and stake.bb) or 0
        local effective_bb    = magnitude_bb
        if stake_bb > 0 and (self.stack or 0) > 0 then
            local stack_bb = (self.stack or 0) / stake_bb
            if effective_bb > stack_bb then effective_bb = stack_bb end
        end
        local result = HandScript.write(
            {
                won           = won,
                magnitude_bb  = effective_bb,
                tier          = tier,
                gtype_id      = gtype.id,
                stake_bb      = stake_bb,
                binary_outcome = gtype.binary_outcome,
            },
            {
                n_seats     = n_seats,
                player_seat = player_seat,
                button_seat = button_seat,
            },
            self.poker_events,
            PokerActionWeights,
            PokerBetSizing,
            PokerEventTimings)
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
    else
        -- Resolve the cinematic shape for this (gtype, tier). Walker
        -- advances index in :update; phase[1] is the entry state.
        self.script           = nil
        self.timeline         = resolveTimeline(gtype.id, tier)
        self.phase_idx        = 1
        self.state            = self.timeline[1][1]
        self.state_timer      = 0
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
    -- represents is worse than a fast one. Mirrors models/Table.lua.
    self._script_pace = pace_mult * ctx_pace

    self.state_timer = self.state_timer + effective_dt

    -- ── Script-walker branch (FEATURES.POKER_THEATER on) ──────────────
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
            -- emit + FX fire just like the timeline path.
            self.state       = "settling"
            self.state_timer = 0
            self._pending_resolution = {
                won   = self.outcome_won,
                delta = self.outcome_delta,
                tier  = self.outcome_tier,
                x     = self.x,
                y     = self.y,
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

    -- Walk the cinematic timeline. Each entry is {state_name, duration};
    -- when the timer crosses the current phase's duration we advance and
    -- spend the leftover on the next phase (preserves smoothness when a
    -- single dt exceeds a short phase). Past the last phase, finalize.
    local phase = self.timeline and self.timeline[self.phase_idx]
    while phase and self.state_timer >= phase[2] do
        self.state_timer = self.state_timer - phase[2]
        self.phase_idx   = self.phase_idx + 1
        local next_phase = self.timeline[self.phase_idx]
        if next_phase then
            self.state = next_phase[1]
            -- Resolution dict pushed on entering "settling", regardless
            -- of which phases preceded it (Zoom+small skips most phases).
            if next_phase[1] == "settling" then
                self._pending_resolution = {
                    won   = self.outcome_won,
                    delta = self.outcome_delta,
                    tier  = self.outcome_tier,
                    x     = self.x,
                    y     = self.y,
                }
                -- Slam to rest at the same instant the resolution emits,
                -- not at end-of-settling. _finalizeHand runs ~0.4 s
                -- later and was previously the only place that reset
                -- lift_t — that gap was the "panel hovers up after the
                -- hand resolved, then awkwardly drops on its own"
                -- artifact.
                self.lift_t = 0
            end
            phase = next_phase
        else
            self:_finalizeHand()
            phase = nil
        end
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

    -- Tournament auto-advance. Win = bump hands_won and re-deal; loss
    -- = end the tournament. Cleared all 8 = end with the top payout.
    -- We re-use the latest ctx stashed on :update / :deal so the new
    -- hand samples WC against the player's current effects rollup —
    -- magnitudes don't matter (binary_outcome forces delta=0).
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if gtype and gtype.auto_deal and self.mtt:isPlaying() then
        if self.outcome_won then
            self.mtt:winHand()
            if self.mtt.hands_won >= (gtype.hand_count or 0) then
                self:_endTournament()
            else
                self:deal(self._last_ctx)
            end
        else
            self:_endTournament()
        end
    end
end

-- Settle the tournament: stash the payout on self.mtt for the controller to
-- drain, clear MTT state, and zero the stack so the panel renders REBUY.
function Table:_endTournament()
    local stake   = Lookups.findById(StakesData,self.stake_id)
    local boost   = (self._last_ctx and self._last_ctx.mtt_payout_boost) or 0
    local payouts = MttPayouts[boost] or MttPayouts[0]
    local buy_in  = (stake and stake.buy_in) or 0
    self.mtt:settle(buy_in, payouts)
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

-- Average bb magnitude inside a tier (uniform over [lo, hi]).
local function tierAvgBB(tier)
    local r = PotTiers[tier]
    if not r then return 0 end
    return (r.lo + r.hi) * 0.5
end

function Table:tableOutcome(ctx)
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return nil end
    return buildOutcome(ctx or {}, gtype, stake)
end

-- Debug-only: pool stats for the backtick debug tooltip. Without per-seat
-- mechanical variance, there's no per-opponent breakdown to compute — every
-- seat at a given (stake, gtype, ctx) shares the same outcome.
function Table:debugStats(ctx)
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return nil end

    ctx = ctx or {}
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb

    local wc, wd, ld = self:tableOutcome(ctx)
    if not wc then return nil end

    local win_avg, loss_avg = 0, 0
    for _, t in ipairs(TIER_KEYS) do
        win_avg  = win_avg  + (wd[t] or 0) * tierAvgBB(t)
        loss_avg = loss_avg + (ld[t] or 0) * tierAvgBB(t)
    end
    local ev = wc * win_avg * bb * em - (1 - wc) * loss_avg * bb * lm

    return {
        stake = stake,
        gtype = gtype,
        pool = {
            win_chance  = wc,
            win_dist    = wd,
            loss_dist   = ld,
            ev_per_hand = ev,
            win_avg_bb  = win_avg,
            loss_avg_bb = loss_avg,
        },
    }
end

function Table:estimateStats(ctx)
    local stake = Lookups.findById(StakesData,self.stake_id)
    local gtype = Lookups.findById(GameTypesData,self.game_type_id)
    if not stake or not gtype then return nil end
    if #self.opponents == 0 then return nil end

    ctx = ctx or {}
    local wc, wd, ld = self:tableOutcome(ctx)
    if not wc then return nil end

    -- EV per hand. win_chance × E[win_magnitude] - (1-win_chance) × E[loss_magnitude].
    local em = ctx.earnings_mult or 1
    local lm = ctx.loss_mult     or 1
    local bb = stake.bb

    local win_avg, loss_avg = 0, 0
    for _, t in ipairs(TIER_KEYS) do
        win_avg  = win_avg  + (wd[t] or 0) * tierAvgBB(t)
        loss_avg = loss_avg + (ld[t] or 0) * tierAvgBB(t)
    end

    local ev = wc * win_avg * bb * em - (1 - wc) * loss_avg * bb * lm

    return {
        ev_per_hand = ev,
        win_chance  = wc,
        win_dist    = wd,
        loss_dist   = ld,
    }
end

return Table
