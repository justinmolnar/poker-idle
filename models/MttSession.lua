-- models/MttSession.lua
--
-- Per-table tournament state. Composed onto Table for any game type with
-- `chip_stack_table = true` (the 8-max KO mode). Cash tables instantiate
-- but leave it at hands_won=0 / state=nil / plan=nil — no-op.
--
-- ─── Two-level outcome model ──────────────────────────────────────────
--
-- Per-hand WC for cash tables is symmetric — the player's WC is the
-- only thing being rolled. In MTT mode that breaks down: the player's
-- ~50% WC means opps share the *other* 50% across 7 seats, so each opp
-- only has a ~7-17% effective per-hand WC and the player structurally
-- outlasts the field. Tournaments dragged 30-50+ hands.
--
-- The fix is a TWO-LEVEL outcome roll. Once per tournament, planRun
-- samples (finish_position, n_hands) from a distribution shaped by the
-- player's effective WC + fill state — same pipeline cash tables use,
-- just one level up. Then it generates a per-hand outcome list that
-- delivers the planned finish in the planned number of hands. Per-hand
-- math still feels normal (the player's tier shape, magnitude, etc.
-- still come from the cash-table pipeline) but the per-hand WIN/LOSE
-- rolls are pre-determined.
--
-- The plan is advisory — actual seat stacks (from
-- Table:_reconcileChipFlow) remain ground truth for bust detection.
-- :reconcile patches the plan when writer randomization causes drift
-- (planned bust didn't bust → re-attack next hand; incidental bust →
-- drop the seat's future slot).
--
-- ─── Lifecycle ────────────────────────────────────────────────────────
--
--   • :begin()            — flag the session as live (first deal of a
--                            new MTT run from Table:deal).
--   • :planRun(...)       — roll finish_position + n_hands + bust
--                            schedule + per-hand outcome list. One-shot
--                            per tournament.
--   • :currentHand()      — read the pre-rolled outcome for the hand
--                            about to be dealt.
--   • :advanceHand()      — bump next_hand_idx after a hand resolves.
--   • :reconcile(...)     — patch the plan against actual chip flow.
--   • :winHand()          — bump lifetime hands-won counter (deck XP,
--                            stats), independent of plan cursor.
--   • :settle(...)        — finalize: look up payout, clear plan/state.
--   • :drainPayout()      — controller pulls cash payout each frame.
--   • :reset()            — REBUY / save-clear.
--
-- Persistence: hands_won, state, plan persist via TablePool parallel
-- arrays on GameState. pending_payout and last_finish are transient.
--
-- ctx note: the plan is rolled with the ctx in effect at click-DEAL of
-- the first hand. Mid-tournament ctx changes (player buys a perk) do
-- NOT replan — the plan is a contract for THIS tournament; the perk
-- benefits land next run.

local OutcomeMath   = require("models.outcome_math")
local MttFinishDist = require("data.mtt_finish_dist")
local MttHandCount  = require("data.mtt_hand_count")
local MttBustPacing = require("data.mtt_bust_pacing")

local MttSession = {}
MttSession.__index = MttSession

function MttSession:new()
    return setmetatable({
        hands_won      = 0,
        state          = nil,    -- nil | "playing"
        pending_payout = nil,    -- $ amount, transient
        last_finish    = nil,    -- finish position from most recent settle,
                                 -- read by controller for bounty gating
        plan           = nil,    -- tournament plan (see :planRun)
    }, MttSession)
end

function MttSession:begin()
    if self.state == nil then self.state = "playing" end
end

function MttSession:isPlaying()
    return self.state == "playing"
end

function MttSession:winHand()
    self.hands_won = self.hands_won + 1
end

-- ─── Plan generation ──────────────────────────────────────────────────

-- Find the index of `value` in `dist` cumulatively. Used to translate
-- the OutcomeMath.sampleDist return (key) back into a numeric finish
-- position. (sampleDist already returns the key, so this is just an
-- identity for {[1..N]=weight} maps — kept inline for clarity.)
local function _pickSurvivor(plan, seat_busted, n_seats, player_seat)
    -- Prefer alive seats NOT in the bust schedule (planned to survive).
    local planned_to_bust = {}
    for _, b in ipairs(plan.bust_schedule) do
        planned_to_bust[b.seat] = true
    end
    local candidates = {}
    for s = 1, n_seats do
        if s ~= player_seat and not (seat_busted and seat_busted[s])
           and not planned_to_bust[s] then
            candidates[#candidates + 1] = s
        end
    end
    if #candidates == 0 then
        -- Fallback: any alive non-player seat.
        for s = 1, n_seats do
            if s ~= player_seat and not (seat_busted and seat_busted[s]) then
                candidates[#candidates + 1] = s
            end
        end
    end
    if #candidates == 0 then return player_seat end
    return candidates[love.math.random(1, #candidates)]
end

-- Distribute `count` opp seats across [1, window_max] hand indices using
-- pacing weights {front, mid, back}. Returns a list of hand indices the
-- same length as `seats`. Multiple opps may land on the same hand —
-- per-seat caps in HandScript handle multi-bust pots organically.
local function _placeBusts(seats, window_max, pacing)
    local third = math.max(1, math.floor(window_max / 3))
    local front_hi = math.min(third, window_max)
    local mid_hi   = math.min(third * 2, window_max)
    local front_w  = pacing.front or 0.34
    local mid_w    = pacing.mid   or 0.33
    local hands = {}
    for _, _seat in ipairs(seats) do
        local r = love.math.random()
        local h
        if r < front_w then
            h = love.math.random(1, front_hi)
        elseif r < (front_w + mid_w) then
            local lo = front_hi + 1
            if lo > mid_hi then lo = mid_hi end
            if lo > window_max then lo = window_max end
            h = love.math.random(lo, math.max(lo, mid_hi))
        else
            local lo = mid_hi + 1
            if lo > window_max then lo = window_max end
            h = love.math.random(lo, window_max)
        end
        hands[#hands + 1] = h
    end
    return hands
end

-- Roll the full tournament plan. Called once on the first deal of a
-- fresh run from Table:deal (after :begin). The caller passes
-- player_seat + n_seats so MttSession doesn't have to know about the
-- table's seat layout (engine-agnostic). The plan is the source of
-- truth for what the player experiences; actual chip flow drifts and
-- is patched by :reconcile.
function MttSession:planRun(ctx, gtype, stake, player_seat, n_seats)
    -- 1. Build the 3-distribution outcome the same way cash tables do.
    --    Fold ctx.auto_win_chances (MTT Pro) into the effective WC —
    --    this is the ONE place those perks apply for tournaments, so
    --    the per-hand path can safely skip the auto-win check.
    local wc, win_dist, loss_dist = OutcomeMath.buildOutcome(ctx, gtype, stake)
    local auto_win_total = 0
    if ctx and ctx.auto_win_chances then
        for _, e in ipairs(ctx.auto_win_chances) do
            if OutcomeMath.shiftApplies(e, gtype) then
                auto_win_total = auto_win_total + (e.amount or 0)
            end
        end
    end
    local eff_wc = wc + auto_win_total
    if eff_wc < 0 then eff_wc = 0
    elseif eff_wc > OutcomeMath.WC_ABSOLUTE_CAP then eff_wc = OutcomeMath.WC_ABSOLUTE_CAP end

    -- 2. Lerp finish_dist by the player's win_chance_fills ratio (same
    --    fill curve cash tables use to lerp win_dist / loss_dist).
    --    auto_win_total pushes the effective fill toward `capped` so
    --    MTT Pro biases toward top finishes without touching naked.
    local wc_units    = OutcomeMath.sumFills(ctx and ctx.win_chance_fills, gtype)
    local fill_ratio  = OutcomeMath.fillRatio(wc_units, stake and stake.fill_window)
    local eff_fill    = fill_ratio + auto_win_total
    if eff_fill > 1 then eff_fill = 1 end

    local finish_weights = {}
    for pos = 1, n_seats do
        local naked  = MttFinishDist.naked[pos]  or 0
        local capped = MttFinishDist.capped[pos] or naked
        finish_weights[pos] = naked + (capped - naked) * eff_fill
    end
    local finish_position = OutcomeMath.sampleDist(finish_weights) or n_seats

    -- 3. Sample n_hands from the finish-keyed range.
    local hc      = MttHandCount[finish_position] or MttHandCount[#MttHandCount]
    local n_hands = love.math.random(hc.lo, hc.hi)

    -- 4. Build bust schedule. K = finish, N = n_seats.
    local K = finish_position
    local N = n_seats
    local n_pre_busts = N - K                  -- opps who bust BEFORE player
    local player_busts_on_final = (K > 1)      -- K=1 means player never busts

    -- Pick pre-bust opps uniformly from non-player seats.
    local non_player_seats = {}
    for s = 1, N do
        if s ~= player_seat then non_player_seats[#non_player_seats + 1] = s end
    end
    -- Fisher-Yates partial shuffle (we only need the first n_pre_busts).
    for i = #non_player_seats, 2, -1 do
        local j = love.math.random(1, i)
        non_player_seats[i], non_player_seats[j] = non_player_seats[j], non_player_seats[i]
    end
    local pre_bust_seats = {}
    for i = 1, n_pre_busts do
        pre_bust_seats[i] = non_player_seats[i]
    end

    -- Distribute their bust hands across the available window.
    local pre_bust_window = player_busts_on_final and (n_hands - 1) or n_hands
    if pre_bust_window < 1 then pre_bust_window = 1 end
    local pacing = MttBustPacing[K] or MttBustPacing[#MttBustPacing]
    local pre_bust_hands = _placeBusts(pre_bust_seats, pre_bust_window, pacing)

    local bust_schedule = {}
    for i, seat in ipairs(pre_bust_seats) do
        bust_schedule[#bust_schedule + 1] = { hand = pre_bust_hands[i], seat = seat }
    end
    if player_busts_on_final then
        bust_schedule[#bust_schedule + 1] = { hand = n_hands, seat = player_seat }
    end
    table.sort(bust_schedule, function(a, b) return a.hand < b.hand end)

    -- 5. Build per-hand outcome list. Group bust_schedule by hand so a
    --    single hand that's supposed to bust two opps generates one
    --    jackpot pot (the writer's per-seat caps drain both organically).
    local busts_by_hand = {}
    for _, b in ipairs(bust_schedule) do
        busts_by_hand[b.hand] = busts_by_hand[b.hand] or {}
        busts_by_hand[b.hand][#busts_by_hand[b.hand] + 1] = b.seat
    end

    -- Walk through hands, tracking the player's projected stack (bb) so
    -- filler-loss tiers don't accidentally bust the player early.
    local proj_player_bb = (gtype.starting_stack_bb or 100)
    local SAFETY_BB      = 25      -- min remaining bb before downgrading filler losses

    local plan_hands = {}
    for i = 1, n_hands do
        local busts_this_hand = busts_by_hand[i]
        local entry
        if busts_this_hand and busts_this_hand[1] then
            local player_in_busts = false
            for _, s in ipairs(busts_this_hand) do
                if s == player_seat then player_in_busts = true; break end
            end
            if player_in_busts then
                -- Player-bust hand. Jackpot loss to a survivor.
                entry = {
                    won           = false,
                    tier          = "jackpot",
                    forced_winner = _pickSurvivor(
                        { bust_schedule = bust_schedule }, nil, n_seats, player_seat),
                }
                proj_player_bb = 0
            else
                -- Opp-bust hand. Player wins jackpot pot; bust target(s)
                -- get whittled to 0 by per-seat caps.
                entry = {
                    won           = true,
                    tier          = "jackpot",
                    forced_winner = player_seat,
                }
                proj_player_bb = proj_player_bb + OutcomeMath.tierAvgBB("jackpot") * 0.7
            end
        else
            -- Filler hand. Roll won from eff_wc, tier from the actual
            -- win/loss dist — preserves the cash-table "feel" of the
            -- per-hand pipeline.
            local won = love.math.random() < eff_wc
            local tier = OutcomeMath.sampleDist(won and win_dist or loss_dist) or "small"
            local forced_winner
            if won then
                forced_winner = player_seat
                proj_player_bb = proj_player_bb + OutcomeMath.tierAvgBB(tier) * 0.7
            else
                -- Downgrade loss tier if the projected stack would dip
                -- under SAFETY_BB before the planned bust hand.
                local proposed_loss = OutcomeMath.tierAvgBB(tier)
                while proj_player_bb - proposed_loss < SAFETY_BB and tier ~= "small" do
                    if     tier == "jackpot" then tier = "large"
                    elseif tier == "large"   then tier = "medium"
                    elseif tier == "medium"  then tier = "small" end
                    proposed_loss = OutcomeMath.tierAvgBB(tier)
                end
                proj_player_bb = proj_player_bb - proposed_loss
                -- Route the win to a planned survivor — the bust targets
                -- shouldn't gain chips on filler-loss hands.
                forced_winner = _pickSurvivor(
                    { bust_schedule = bust_schedule }, nil, n_seats, player_seat)
            end
            entry = {
                won           = won,
                tier          = tier,
                forced_winner = forced_winner,
            }
        end
        plan_hands[i] = entry
    end

    self.plan = {
        finish_position = finish_position,
        n_hands         = n_hands,
        n_hands_max     = n_hands + 3,    -- :reconcile may extend up to this cap
        player_seat     = player_seat,
        n_seats         = n_seats,
        bust_schedule   = bust_schedule,
        hands           = plan_hands,
        next_hand_idx   = 1,
        last_bust_count = 0,              -- for :reconcile diff
    }
end

-- Read the outcome entry for the hand about to be dealt. nil if the
-- plan is exhausted (caller should fall back to the live :sampleOutcome
-- path or treat as "tournament over").
function MttSession:currentHand()
    local p = self.plan
    if not p then return nil end
    return p.hands[p.next_hand_idx]
end

-- Bump the plan cursor. Called from Table:_finalizeHand after a hand
-- resolves, before the bust/auto-deal branch.
function MttSession:advanceHand()
    local p = self.plan
    if p then p.next_hand_idx = p.next_hand_idx + 1 end
end

-- Patch the plan against actual chip-flow results. `new_busts` is the
-- list of seat numbers that hit 0 during the just-completed hand
-- (caller diffs Table.bust_order from its pre-hand snapshot). The
-- plan's `last_bust_count` field tracks the same cumulative count and
-- is used as a fallback when callers don't pass new_busts.
function MttSession:reconcile(new_busts, seat_busted, n_seats, player_seat)
    local plan = self.plan
    if not plan then return end
    local just_completed = plan.next_hand_idx - 1
    if just_completed < 1 then return end

    -- (a) Drop future slots for seats that busted INCIDENTALLY (i.e.
    --     busted this hand but the plan didn't have them scheduled).
    local expected_this_hand = {}
    for _, b in ipairs(plan.bust_schedule) do
        if b.hand == just_completed then expected_this_hand[b.seat] = true end
    end
    for _, seat in ipairs(new_busts or {}) do
        if not expected_this_hand[seat] then
            for i = #plan.bust_schedule, 1, -1 do
                local entry = plan.bust_schedule[i]
                if entry.seat == seat and entry.hand > just_completed then
                    table.remove(plan.bust_schedule, i)
                end
            end
        end
    end

    -- (b) Re-attack expected busts that didn't materialize. Overwrite
    --     the next hand's outcome to be a kill (or a player-bust); if
    --     the plan is already at the end, extend up to n_hands_max.
    for seat, _ in pairs(expected_this_hand) do
        if not (seat_busted and seat_busted[seat]) then
            local next_hand = plan.next_hand_idx
            if next_hand <= plan.n_hands_max then
                if next_hand > plan.n_hands then
                    plan.n_hands = next_hand
                end
                if seat == player_seat then
                    plan.hands[next_hand] = {
                        won           = false,
                        tier          = "jackpot",
                        forced_winner = _pickSurvivor(plan, seat_busted, n_seats, player_seat),
                    }
                else
                    plan.hands[next_hand] = {
                        won           = true,
                        tier          = "jackpot",
                        forced_winner = player_seat,
                    }
                end
                -- Remove the missed schedule entry, add the new one.
                for i = #plan.bust_schedule, 1, -1 do
                    local entry = plan.bust_schedule[i]
                    if entry.seat == seat and entry.hand == just_completed then
                        table.remove(plan.bust_schedule, i)
                    end
                end
                plan.bust_schedule[#plan.bust_schedule + 1] = {
                    hand = next_hand, seat = seat,
                }
                table.sort(plan.bust_schedule,
                    function(a, b) return a.hand < b.hand end)
            end
        end
    end
end

-- ─── Settle / drain / reset ───────────────────────────────────────────

-- Resolve the payout for the given finish position (1 = won, 2 = 2nd
-- place, etc.). The mtt_payouts ladder is keyed by (n_seats - finish + 1)
-- so finish positions outside the top-3 yield no payout. Stashes
-- pending_payout for the controller to drain and clears state so the
-- next :begin starts a fresh run.
function MttSession:settle(buy_in, payouts_for_boost, finish_position, n_seats)
    local key  = (n_seats or 0) - (finish_position or 0) + 1
    local mult = (payouts_for_boost and payouts_for_boost[key]) or 0
    self.pending_payout = mult * (buy_in or 0)
    self.last_finish    = finish_position
    self.state          = nil
    self.plan           = nil
end

-- Pop the pending payout (or nil if none). Caller is the controller; it
-- applies the payout to bankroll, fires the chip burst, and resets the
-- per-tournament hand counter via :reset.
function MttSession:drainPayout()
    local p = self.pending_payout
    self.pending_payout = nil
    return p
end

function MttSession:reset()
    self.hands_won      = 0
    self.state          = nil
    self.pending_payout = nil
    self.last_finish    = nil
    self.plan           = nil
end

return MttSession
