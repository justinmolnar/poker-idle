-- models/HandScript.lua
--
-- The script writer. Pure module. One public entry point:
--
--   HandScript.write(outcome, table_ctx, registry, weights, sizing, timings)
--     -> { events = { ... }, total_duration = N }
--
-- Inputs:
--   outcome    = { won, magnitude_bb, tier, gtype_id, stake_bb,
--                  forced_winner_seat?, forced_bust_seats? }
--     forced_winner_seat — MTT plan: this alive seat wins the pot.
--     forced_bust_seats  — MTT plan: these alive seats stay in through a
--       forced showdown so stack caps drain them (their bust is the
--       point of the hand). Dead/winner seats are ignored.
--   table_ctx  = { n_seats, player_seat, button_seat,
--                  alive_seats = { [seat] = true } | nil,
--                  seat_stacks = { [seat] = $ } | nil }
--   registry   = services/PokerEventRegistry instance (for write-time
--                state mutation as events are appended)
--   weights    = data/poker_action_weights table (kept for future use)
--   sizing     = data/poker_bet_sizing table (kept for future use)
--   timings    = data/poker_event_timings table (per-kind beat duration)
--
-- alive_seats / seat_stacks (8-max KO tables):
--   * alive_seats — set of seats still in the tournament. Dead seats are
--     skipped everywhere (no blinds, no action, can't win pots). nil =
--     all seats alive (cash-game default).
--   * seat_stacks — per-seat $ remaining (independent of `outcome.stack`).
--     The writer caps any single seat's contribution at their stack;
--     contributions that would exceed are emitted as `all_in` events
--     with the capped amount. nil = no caps (cash-game default).
--
-- Output: a flat ordered list of events, each with absolute timestamp `t`
-- in seconds. The cinematic walks this list at play time; no decisions
-- happen during playback.
--
-- ─── Math contract ─────────────────────────────────────────────────────
--
-- Total pot = 2 × magnitude (= 2 × |outcome_delta|). Always. So:
--
--   * Player's total contribution = magnitude (across all streets they're in)
--   * Opponents' total contributions = magnitude (across all streets played)
--   * Pot push goes to winner — for wins, the player; for losses, an opp.
--   * Player's net = pot_won - player_contributed
--                  = (2×magnitude) - magnitude = magnitude   (on wins)
--                  = -magnitude                              (on losses, never won pot)
--
-- This guarantees the pot label always reads 2× the player's win — same
-- shape the old `pot = 2 × |outcome_delta|` heuristic gave.
--
-- ─── Algorithm ─────────────────────────────────────────────────────────
--
-- 1. PLAN. Decide structure upfront:
--    * showdown vs. fold-out (tier-biased)
--    * which streets are played (1 = preflop fold-out, 2 = flop, 3 = turn,
--      4 = river/showdown)
--    * which seat wins (player on a win; non-player on a loss)
--    * which opponents fold on which street (random; ensures the right
--      number of seats remain at each street's end)
--    * per-street pot split (sums to 2 × magnitude)
--
-- 2. EMIT. Walk the streets:
--    * Preflop: post blinds, then each in-turn seat acts ONCE (fold or
--      call the per-seat amount for the street).
--    * Flop / turn / river: each remaining seat acts once (fold or call).
--    * Showdown reveal if 2+ remain.
--    * Pot push to winner.
--
-- Bounded: ≤ N seats × 4 streets + blinds + deals + showdown + pot_push
-- ≤ ~30 events per hand. No raise / counter-raise loops.

local PokerEventTimings = require("data.poker_event_timings")

local HandScript = {}

-- ─── Small helpers ──────────────────────────────────────────────────────

local function urand(a, b) return a + love.math.random() * (b - a) end

local function pickWeighted(options, weights)
    local total = 0
    for _, w in ipairs(weights) do total = total + w end
    if total <= 0 then return options[1] end
    local r = love.math.random() * total
    local acc = 0
    for i, w in ipairs(weights) do
        acc = acc + w
        if r <= acc then return options[i] end
    end
    return options[#options]
end

-- Round to 2 decimal places ($-cents). Avoid float drift.
local function r2(x) return math.floor(x * 100 + 0.5) / 100 end

local STREETS    = { "preflop", "flop", "turn", "river" }
local STREET_IDX = { preflop = 1, flop = 2, turn = 3, river = 4 }

-- Tier-biased odds the hand reaches showdown rather than ending in a
-- fold-out. Tiny pots almost never reach showdown (real poker: small
-- pots are blind-steals and continuation-bet fold-outs). Bigger pots
-- nearly always reveal cards.
local SHOWDOWN_CHANCE_BY_TIER = {
    small   = 0.00,
    medium  = 0.50,
    large   = 0.85,
    jackpot = 1.00,
}

-- For fold-outs, weights for which street the hand ends on. Smaller
-- tiers fold preflop overwhelmingly; bigger tiers run a bit deeper
-- before someone bails.
local FOLDOUT_END_STREET_WEIGHTS = {
    -- weights match STREETS = preflop, flop, turn, river
    small   = { 80, 17, 2, 1 },
    medium  = { 5, 35, 45, 15 },
    large   = { 0, 10, 35, 55 },
    jackpot = { 0, 5, 25, 70 },
}

-- ─── Planning ──────────────────────────────────────────────────────────

-- Distribute total positively across N streets, weighted slightly toward
-- later streets so the pot grows naturally as the hand goes deeper.
-- Returns a list of N values rounded to cents that sum to total.
local function splitPot(total, n)
    if n <= 0 or total <= 0 then return {} end
    if n == 1 then return { r2(total) } end
    local weights = {}
    for i = 1, n do
        weights[i] = (0.7 + 0.4 * i) * (0.85 + love.math.random() * 0.30)
    end
    local wsum = 0
    for _, w in ipairs(weights) do wsum = wsum + w end
    local out = {}
    local accumulated = 0
    for i = 1, n - 1 do
        local v = r2(total * weights[i] / wsum)
        out[i] = v
        accumulated = accumulated + v
    end
    out[n] = r2(total - accumulated)
    if out[n] < 0 then
        out[n - 1] = r2(out[n - 1] + out[n])
        out[n] = 0
    end
    return out
end

-- Walk clockwise from `start` (exclusive) until we land on a seat where
-- alive[s] is truthy. Returns nil if nobody alive in the ring. `start`
-- itself is not considered — we always step at least once.
local function nextAlive(start, n, alive)
    local s = (start % n) + 1
    for _ = 1, n do
        if alive[s] then return s end
        s = (s % n) + 1
    end
    return nil
end

-- Same direction, but considers `start` itself first.
local function firstAliveAt(start, n, alive)
    local s = start
    for _ = 1, n do
        if alive[s] then return s end
        s = (s % n) + 1
    end
    return nil
end

-- Plan the hand. Pure combinatorics — no events emitted yet.
local function plan(outcome, table_ctx)
    local n         = table_ctx.n_seats
    local player    = table_ctx.player_seat
    local tier      = outcome.tier or "small"
    local target    = math.max(0, outcome.magnitude_bb * (outcome.stake_bb or 0))
    local pot_total = 2 * target

    -- alive_seats: default all seats alive (cash game / first MTT hand).
    local alive_seats = {}
    if table_ctx.alive_seats then
        for s, v in pairs(table_ctx.alive_seats) do
            if v then alive_seats[s] = true end
        end
    else
        for i = 1, n do alive_seats[i] = true end
    end
    local n_alive = 0
    for _ in pairs(alive_seats) do n_alive = n_alive + 1 end

    -- Button must be an alive seat. If the caller's button hint is dead,
    -- rotate forward to the next alive seat. Defensive — caller should
    -- already pass an alive button.
    local button_hint = table_ctx.button_seat or ((player + 1 - 1) % n + 1)
    local button = firstAliveAt(button_hint, n, alive_seats) or player

    -- SB and BB seats follow the button among ALIVE seats.
    local sb_seat = nextAlive(button, n, alive_seats) or button
    local bb_seat = nextAlive(sb_seat, n, alive_seats) or sb_seat

    -- Showdown decision.
    local showdown_p = SHOWDOWN_CHANCE_BY_TIER[tier] or 0.5
    local showdown = love.math.random() < showdown_p

    -- Pick the winner seat. outcome.forced_winner_seat (set by MTT plan
    -- generation in models/MttSession) overrides the random pick when
    -- the seat is alive; otherwise we fall back to player-on-win /
    -- random-alive-on-loss. The alive guard makes plan drift safe — if
    -- the plan named a seat that has since busted, the writer recovers
    -- cleanly and MttSession:reconcile patches the schedule on the next
    -- hand.
    local winner_seat
    if outcome.forced_winner_seat and alive_seats[outcome.forced_winner_seat] then
        winner_seat = outcome.forced_winner_seat
    elseif outcome.won then
        winner_seat = player
    else
        local picks = {}
        for i = 1, n do
            if i ~= player and alive_seats[i] then picks[#picks + 1] = i end
        end
        if #picks > 0 then
            winner_seat = picks[love.math.random(1, #picks)]
        else
            winner_seat = player    -- degenerate: no alive opps. Player wins.
        end
    end

    -- Scheduled bust targets (MTT plan, outcome.forced_bust_seats).
    -- Filtered to alive non-winner seats — same drift-safety as the
    -- forced-winner guard above. A hand with targets is forced to
    -- SHOWDOWN so they stay in through the later (biggest) streets: their
    -- calls hit capChips → genuine all_in events → per_seat_total drains
    -- their whole stack → Table:_reconcileChipFlow busts them on
    -- schedule. (With 2+ targets the even pot split can leave a target
    -- short — MttSession:reconcile re-attacks it next hand.)
    local bust_targets = {}
    if outcome.forced_bust_seats then
        for _, s in ipairs(outcome.forced_bust_seats) do
            if alive_seats[s] and s ~= winner_seat then
                bust_targets[#bust_targets + 1] = s
            end
        end
    end
    if #bust_targets > 0 then showdown = true end

    -- Decide how many streets play out. Showdowns always go river (4).
    -- Fold-outs end at a tier-biased random street.
    local n_streets_played
    if showdown then
        n_streets_played = 4
    else
        local w = FOLDOUT_END_STREET_WEIGHTS[tier] or { 25, 25, 25, 25 }
        n_streets_played = STREET_IDX[pickWeighted(STREETS, w)]
    end

    -- Per-street pot share (sums to 2 × magnitude). Each street has its
    -- own pot growth; the writer divides each share evenly across the
    -- seats still in for that street.
    local street_pots = splitPot(pot_total, n_streets_played)

    -- Forced stays: the winner never folds; the player follows the
    -- showdown/fold-out rule; scheduled bust targets ride to the end.
    -- Computed BEFORE K_at_end so the survivor floor counts them.
    local stays = { [winner_seat] = true }
    if showdown then
        stays[player] = true
    elseif outcome.won then
        stays[player] = true
    end
    for _, s in ipairs(bust_targets) do stays[s] = true end
    local n_stays = 0
    for _ in pairs(stays) do n_stays = n_stays + 1 end

    -- Plan the K_stay (seats still in) at the END of each street.
    -- Always start at K=n_alive. End at 1 (fold-out) or the showdown
    -- floor (2, or more when bust targets are forced to the end — the
    -- per-seat split math then sizes calls against the real headcount).
    local K_at_end = {}
    local last_K = showdown and math.max(2, n_stays) or 1
    for s = 1, n_streets_played do
        local frac = s / n_streets_played
        K_at_end[s] = math.max(last_K, math.floor(n_alive - (n_alive - last_K) * frac + 0.5))
    end
    -- Force last value exactly so monotone decrease lands cleanly.
    K_at_end[n_streets_played] = last_K

    -- Plan which seats fold on which street. After the forced stays,
    -- drop the rest in random street order so K_at_end is satisfied.
    local fold_streets = {}     -- [seat] = STREET_IDX or nil if stays to end
    -- Build a shuffled list of non-stay alive seats.
    local foldables = {}
    for i = 1, n do
        if alive_seats[i] and not stays[i] then
            foldables[#foldables + 1] = i
        end
    end
    -- Fisher-Yates shuffle.
    for i = #foldables, 2, -1 do
        local j = love.math.random(1, i)
        foldables[i], foldables[j] = foldables[j], foldables[i]
    end
    -- Walk K_at_end and assign fold-streets so stays-after-street equals K.
    local idx = 1
    local in_count = n_alive
    for s = 1, n_streets_played do
        local target_in = K_at_end[s]
        while in_count > target_in and idx <= #foldables do
            fold_streets[foldables[idx]] = s
            idx = idx + 1
            in_count = in_count - 1
        end
    end
    -- Anyone remaining in foldables (showdown losers, etc.) stays to end.

    return {
        n_seats         = n,
        n_alive         = n_alive,
        alive_seats     = alive_seats,
        seat_stacks     = table_ctx.seat_stacks,    -- nil for cash games
        player_seat     = player,
        button_seat     = button,
        sb_seat         = sb_seat,
        bb_seat         = bb_seat,
        winner_seat     = winner_seat,
        showdown        = showdown,
        n_streets       = n_streets_played,
        street_pots     = street_pots,
        K_at_end        = K_at_end,
        fold_streets    = fold_streets,
        stake_bb        = outcome.stake_bb,
        tier            = tier,
        won             = outcome.won,
        target          = target,
    }
end

-- ─── Emit ──────────────────────────────────────────────────────────────

local function beat(timings, kind)
    return (timings and timings[kind]) or 0.1
end

local function emit(events, ws, kind, payload, registry, timings)
    local ev = {
        kind   = kind,
        seat   = payload and payload.seat,
        amount = payload and payload.amount,
        bet_to = payload and payload.bet_to,
        meta   = payload and payload.meta,
        t      = ws.time_cursor,
    }
    events[#events + 1] = ev
    ws.time_cursor = ws.time_cursor + beat(timings, kind)
    if registry then registry:apply(ev, ws) end
    return ev
end

-- Cap the requested chip amount at the seat's stack_remaining. Decrements
-- stack_remaining. Returns (capped_amount, was_capped).
local function capChips(ws, seat, requested)
    if requested <= 0 then return 0, false end
    local remaining = ws.stack_remaining and ws.stack_remaining[seat]
    if remaining == nil then return requested, false end    -- no cap
    if requested >= remaining then
        ws.stack_remaining[seat] = 0
        return remaining, true
    end
    ws.stack_remaining[seat] = remaining - requested
    return requested, false
end

local function newWriterState(plan_)
    local in_seats = {}
    local n_in = 0
    for i = 1, plan_.n_seats do
        if plan_.alive_seats[i] then
            in_seats[i] = true
            n_in = n_in + 1
        end
    end
    -- stack_remaining[seat] = $ this seat can still commit. nil for seats
    -- without a stack record (cash games leave seat_stacks=nil → all
    -- entries default to huge, no caps trigger).
    local stack_remaining = nil
    if plan_.seat_stacks then
        stack_remaining = {}
        for seat, amt in pairs(plan_.seat_stacks) do
            stack_remaining[seat] = amt
        end
    end
    return {
        n_seats             = plan_.n_seats,
        player_seat         = plan_.player_seat,
        in_seats            = in_seats,
        n_in                = n_in,
        pot                 = 0,
        current_bet         = 0,
        per_seat_committed  = {},
        per_seat_total      = {},
        community_count     = 0,
        player_revealed     = false,
        opp_revealed        = false,
        winner              = nil,
        time_cursor         = 0,
        stack_remaining     = stack_remaining,
    }
end

-- Action order for a betting round. Preflop opens UTG (left of BB);
-- postflop opens left of button (SB if still in, else next clockwise).
local function actionOrder(plan_, street_idx)
    local n = plan_.n_seats
    local first
    if street_idx == 1 then
        first = (plan_.bb_seat % n) + 1
    else
        first = (plan_.button_seat % n) + 1
    end
    local order = {}
    for k = 0, n - 1 do
        order[k + 1] = ((first - 1 + k) % n) + 1
    end
    return order
end

-- Emit forced blind posts. Done before preflop action. Each blind is
-- capped at the poster's stack — if they have less than the blind, they
-- post all-in for whatever they have left.
local function emitBlinds(events, ws, plan_, registry, timings)
    local sb = plan_.stake_bb / 2
    local bb = plan_.stake_bb
    local sb_amt = r2(capChips(ws, plan_.sb_seat, sb))
    if sb_amt > 0 then
        emit(events, ws, "post_blind",
             { seat = plan_.sb_seat, amount = sb_amt }, registry, timings)
    end
    local bb_amt = r2(capChips(ws, plan_.bb_seat, bb))
    if bb_amt > 0 then
        emit(events, ws, "post_blind",
             { seat = plan_.bb_seat, amount = bb_amt }, registry, timings)
    end
end

-- Run a single street. K_stay = number of seats expected to still be in
-- at end of this street (per the plan's K_at_end). street_pot = $ that
-- should land in the pot during this street, INCLUDING any blinds
-- already posted (preflop).
local function runStreet(events, ws, plan_, street_idx, street_pot, registry, timings)
    local order      = actionOrder(plan_, street_idx)
    local K_at_start = ws.n_in
    local K_at_end   = plan_.K_at_end[street_idx]
    local n_folding  = math.max(0, K_at_start - K_at_end)
    local K_remain   = K_at_end

    -- $ that must land in the pot from non-blind contributions this street.
    local already_posted = 0
    if street_idx == 1 then
        already_posted = (ws.per_seat_committed[plan_.sb_seat] or 0)
                       + (ws.per_seat_committed[plan_.bb_seat] or 0)
    end
    local remaining_to_collect = math.max(0, street_pot - already_posted)
    local per_seat_call = (K_remain > 0) and r2(remaining_to_collect / K_remain) or 0

    -- Walk seats in turn order. Each seat acts exactly once.
    for _, seat in ipairs(order) do
        if ws.in_seats[seat] then
            local remaining = ws.stack_remaining and ws.stack_remaining[seat]
            if remaining == 0 then
                -- All-in from a previous street: nothing left to commit
                -- and can't fold (already committed to showdown). Skip.
            else
                local fold_at = plan_.fold_streets[seat]
                if fold_at == street_idx then
                    emit(events, ws, "fold", { seat = seat }, registry, timings)
                else
                    -- Staying seat: contribute the per-seat call, capped
                    -- at their stack. If short, emit all_in instead.
                    local already = ws.per_seat_committed[seat] or 0
                    local delta_needed = math.max(0, r2(per_seat_call - already))
                    if delta_needed <= 0 then
                        emit(events, ws, "check", { seat = seat }, registry, timings)
                    else
                        local amt, capped = capChips(ws, seat, delta_needed)
                        amt = r2(amt)
                        if amt <= 0 then
                            -- Defensive: stack already at 0 (shouldn't reach here).
                        elseif capped then
                            emit(events, ws, "all_in",
                                 { seat = seat, amount = amt }, registry, timings)
                        else
                            emit(events, ws, "call",
                                 { seat = seat, amount = amt }, registry, timings)
                        end
                    end
                end
            end
            -- Early-out: if the fold reduced n_in to 1, the round is done.
            if ws.n_in <= 1 then break end
        end
    end
end

local function emitDeal(events, ws, street_idx, registry, timings)
    local kind
    if street_idx == 2 then kind = "deal_flop"
    elseif street_idx == 3 then kind = "deal_turn"
    elseif street_idx == 4 then kind = "deal_river"
    else return
    end
    emit(events, ws, kind, {}, registry, timings)
end

-- ─── Public entry ──────────────────────────────────────────────────────

function HandScript.write(outcome, table_ctx, registry, _weights, _sizing, timings_data)
    timings_data = timings_data or PokerEventTimings
    local plan_  = plan(outcome, table_ctx)
    local ws     = newWriterState(plan_)
    local events = {}

    -- Preflop: blinds first, then street action.
    emitBlinds(events, ws, plan_, registry, timings_data)
    runStreet(events, ws, plan_, 1, plan_.street_pots[1] or 0, registry, timings_data)

    -- Subsequent streets only if planned and 2+ remain.
    for s = 2, plan_.n_streets do
        if ws.n_in < 2 then break end
        ws.time_cursor = ws.time_cursor + (timings_data.street_gap or 0.2)
        emitDeal(events, ws, s, registry, timings_data)
        runStreet(events, ws, plan_, s, plan_.street_pots[s] or 0, registry, timings_data)
    end

    -- Showdown reveal if 2+ remain at the end.
    if ws.n_in >= 2 then
        emit(events, ws, "showdown_reveal", {}, registry, timings_data)
    end

    -- Pot push. Prefer the planned winner; fall back to any in-seat.
    -- We snapshot ws.pot BEFORE emit() runs (which applies the
    -- pot_push applicator, zeroing ws.pot) so the event carries the
    -- final pot amount as `amount`. The view's pot_push anim handler
    -- reads ev.amount to size the chip burst.
    local winner = plan_.winner_seat
    if not ws.in_seats[winner] then
        for s, _ in pairs(ws.in_seats) do winner = s; break end
    end
    local final_pot = ws.pot
    emit(events, ws, "pot_push", { seat = winner, amount = final_pot }, registry, timings_data)

    -- Pick a non-player opp to showcase visually (cards flip face-up at
    -- showdown, animation focus). Default: the winner if it's an opp.
    -- Otherwise (player wins): any non-player surviving seat at showdown.
    local showcase_opp = (winner ~= plan_.player_seat) and winner or nil
    if not showcase_opp then
        for s, _ in pairs(ws.in_seats) do
            if s ~= plan_.player_seat then
                showcase_opp = s
                break
            end
        end
    end

    return {
        events           = events,
        total_duration   = ws.time_cursor,
        winner_seat      = winner,
        showcase_opp_seat = showcase_opp,
        showdown         = plan_.showdown,
    }
end

return HandScript
