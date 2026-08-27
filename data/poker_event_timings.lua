-- data/poker_event_timings.lua
--
-- Per-event-kind beat duration in seconds (pre-pace_mult). Pure data —
-- the cinematic state-machine in models/Table.lua scales these by the
-- gtype's pace_mult and any ctx.hand_pace_mult before advancing the
-- script index.
--
-- The script writer in models/HandScript.lua uses these durations at
-- write-time to compute each event's absolute timestamp `t`. The
-- playback walker then advances through the script comparing its
-- elapsed timer against each event's `t`.
--
-- Tuning notes:
--   - Folds are quick — the muck animation is brief, and folds happen
--     a lot (4-5 seats fold preflop most hands).
--   - Deals breathe a beat longer — the player needs time to read the
--     new board.
--   - Pot push is the longest non-deal beat — chips fly to the winner
--     and the floater fires here.
--   - street_gap is silence between the last betting beat and the next
--     deal — gives the eye a rest before new community cards drop.
--
-- Per-game-type overrides live under `by_gtype`, resolved (and memoized)
-- by HandScript.timingsFor: a gtype's table is merged OVER `default`, so
-- it only names the beats it changes. This is the lever that makes a
-- mode feel fast beyond raw pace_mult — pace_mult scales the whole hand
-- uniformly, while these compress the specific beats that drag.
--
-- Pure data; no logic.

return {
    default = {
        post_blind       = 0.05,
        fold             = 0.08,
        check            = 0.10,
        call             = 0.15,
        raise            = 0.20,
        all_in           = 0.30,
        deal_flop        = 0.40,
        deal_turn        = 0.30,
        deal_river       = 0.30,
        showdown_reveal  = 0.50,
        pot_push         = 0.40,
        street_gap       = 0.20,
    },

    by_gtype = {
        -- Filled by the identity retune (phase E), from sim/gtype_ev.lua.
    },
}
