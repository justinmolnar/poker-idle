-- models/poker_action_apply.lua
--
-- Per-kind state mutators for the poker event registry. Mirrors
-- models/poker_effects.lua's relationship with EffectsRegistry — the
-- registry mechanism stays engine-agnostic; the poker-specific kind
-- names + state mutations live here.
--
-- Used at TWO points in the lifecycle:
--   1. WRITE-TIME (models/HandScript.lua) — the writer mutates its
--      working state as it appends each event, so candidate-filtering
--      + destination-checking can read accurate state.
--   2. PLAY-TIME (models/Table.lua) — the cinematic walker mutates the
--      table's playback state as each event's timestamp comes due, so
--      the view (views/TablePanel.lua) can read fresh values like
--      community_count, pot_visible, in_seats per frame.
--
-- Same applicator runs at both points. The state shape is the same —
-- writer state + playback state both carry { pot, current_bet,
-- in_seats, per_seat_committed, per_seat_total, community_count,
-- player_revealed, opp_revealed, winner }.
--
-- THERE IS NO if/elseif chain on event.kind anywhere. If you find
-- yourself writing one, register a function instead.

local PokerActionApply = {}

-- Helper: track a chip contribution per seat across the hand.
local function commit(state, seat, amount)
    if not amount or amount <= 0 then return end
    state.pot = (state.pot or 0) + amount
    state.per_seat_committed = state.per_seat_committed or {}
    state.per_seat_total     = state.per_seat_total     or {}
    state.per_seat_committed[seat] = (state.per_seat_committed[seat] or 0) + amount
    state.per_seat_total[seat]     = (state.per_seat_total[seat]     or 0) + amount
end

function PokerActionApply.registerAll(reg)
    -- Blind posting (SB / BB at hand start). Pushes the blind amount
    -- into the pot and updates current_bet to the highest blind so
    -- preflop callers know what to call.
    reg:register("post_blind", function(e, s)
        commit(s, e.seat, e.amount)
        if (e.amount or 0) > (s.current_bet or 0) then
            s.current_bet = e.amount
        end
    end)

    -- Fold: remove seat from in_seats. Their per-seat-committed chips
    -- stay in the pot.
    reg:register("fold", function(e, s)
        s.in_seats = s.in_seats or {}
        if s.in_seats[e.seat] then
            s.in_seats[e.seat] = nil
            s.n_in = (s.n_in or 0) - 1
        end
    end)

    -- Check: no chip movement, no in/out change. The writer fires this
    -- to advance to-act; the view fires a small chip-tap animation.
    reg:register("check", function(_e, _s)
        -- nothing to mutate
    end)

    -- Call: match the current bet. event.amount is the DELTA (chips
    -- this seat puts in to call), not the total bet. Writer pre-computes
    -- the delta as (current_bet - per_seat_committed[seat]).
    reg:register("call", function(e, s)
        commit(s, e.seat, e.amount)
    end)

    -- Raise: event.amount is the chips this seat is putting in (the
    -- delta), and event.bet_to is the new total bet level. Writer
    -- supplies both; the registry trusts the values.
    reg:register("raise", function(e, s)
        commit(s, e.seat, e.amount)
        if e.bet_to then s.current_bet = e.bet_to end
    end)

    -- All-in: like raise/call but caps at seat stack. The writer treats
    -- it as a raise with an amount equal to the seat's remaining stack.
    reg:register("all_in", function(e, s)
        commit(s, e.seat, e.amount)
        if e.bet_to and e.bet_to > (s.current_bet or 0) then
            s.current_bet = e.bet_to
        end
    end)

    -- Deal events: bump community_count. The actual cards are stored on
    -- the table model already (board[1..5]) — the count is what the
    -- view reads to decide how many community slots are revealed.
    reg:register("deal_flop", function(_e, s)
        s.community_count = 3
        -- New street resets per-seat-committed (this-street chips) and
        -- the current bet. Total contributions stay; bet level resets.
        s.per_seat_committed = {}
        s.current_bet        = 0
    end)
    reg:register("deal_turn", function(_e, s)
        s.community_count = 4
        s.per_seat_committed = {}
        s.current_bet        = 0
    end)
    reg:register("deal_river", function(_e, s)
        s.community_count = 5
        s.per_seat_committed = {}
        s.current_bet        = 0
    end)

    -- Showdown reveal: flip surviving seats' hole cards face-up. The
    -- view reads s.player_revealed / s.opp_revealed to flip cards.
    reg:register("showdown_reveal", function(_e, s)
        s.player_revealed = true
        s.opp_revealed    = true
    end)

    -- Pot push: the winner takes the pot. Resets pot to 0; the view
    -- fires a chip-flight from the pot center to the winner's anchor.
    reg:register("pot_push", function(e, s)
        s.winner = e.seat
        s.pot    = 0
    end)
end

return PokerActionApply
