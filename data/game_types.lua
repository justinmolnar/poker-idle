-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake's base outcome model:
--
--   • seats              — number of opponents at the felt
--   • pace_mult          — multiplier on the per-hand cinematic. >1 = faster.
--                          The base timeline (PHASE_*_END constants in
--                          models/Table.lua) is what plays at pace_mult=1;
--                          6-max is intentionally below 1 to anchor the
--                          baseline so multi-tabling is the way to scale
--                          throughput, not single-table click-spam.
--   • dist_shifts        — additive deltas on win_dist / loss_dist (see
--                          models/Table.lua:buildOutcome). Same shape as
--                          opponent_types.style_dist_shifts: an entry with
--                          optional `win_dist` and `loss_dist` 4-tier delta
--                          tables. Each gtype here applies to BOTH dists
--                          (depth/pace texture, not W/L bias). nil = no
--                          shift (6-max baseline).
--   • rerolls_opponents  — true for Zoom; opponents reroll per hand and
--                          their revealed-skill / revealed-style flags reset
--                          (you never learn a Zoom pool).
--
-- The post-refactor model deliberately drops per-gtype skill_modifier and
-- playstyle_modifier — pool reweighting through game type is what caused HU
-- to become a pro-only nightmare at any stake. Per-gtype texture now lives
-- ONLY in dist_shifts (shaping tier variance, not win_chance) and pace_mult
-- (throughput, not per-hand EV).
--
-- Pure data — no logic.

local mtt_entry = {
        id   = "mtt",
        name = "Tournament",
        short = "8-MAX KO",
        seats = 7,              -- 7 opponents + player = 8 seated total
        pace_mult = 1.0,
        rerolls_opponents = false,
        -- 8-max knockout: each seat sits down with starting_stack_bb at
        -- table init. Hands play normally (no binary_outcome), with real
        -- chip flow into the pot. Seats bust at 0 chips. Tournament ends
        -- when the player busts OR is the last seat standing. Payout
        -- read from data/mtt_payouts.lua keyed by finish position
        -- (1st=8, 2nd=7, 3rd=6, 4th-8th=0).
        chip_stack_table    = true,
        -- Turbo stacks: shallow enough that any big pot a seat stays deep
        -- in is a genuine all-in (the writer's capChips path), which is
        -- what makes the plan's scheduled busts actually land. At 100bb
        -- busts almost never materialized and tournaments dragged 50+
        -- hands in the fallback regime.
        starting_stack_bb   = 10,
        auto_deal           = true,
        -- No per-gtype dist_shifts: tournament difficulty + length is
        -- driven by the two-level outcome model in models/MttSession
        -- (data/mtt_finish_dist.lua + data/mtt_hand_count.lua). The
        -- planner picks finish_position + n_hands once per tournament
        -- and pre-rolls per-hand outcomes; per-hand tier mass doesn't
        -- need a separate crush on top.
    }

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pace_mult = 0.5,        -- baseline slow — 4.4s/hand. Anchors all multi-tabling math.
        dist_shifts = nil,      -- baseline; no shift
        rerolls_opponents = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 1.0,        -- fast — 2.6s/hand (longer showdown beat)
        -- HU = the duel. Low win rate (-0.10 WC vs other modes), but
        -- when pots happen they're DEEP — both wins AND losses skew
        -- away from small/medium toward large/jackpot. Identity: "lose
        -- often, but pots are big both ways."
        win_chance_shift = -0.10,
        dist_shifts = {
            win_dist  = { small = -0.20, medium = -0.10, large = 0.10, jackpot = 0.20 },
            loss_dist = { small = -0.20, medium = -0.05, large = 0.10, jackpot = 0.15 },
        },
        rerolls_opponents = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pace_mult = 1.4,        -- very fast — most hands ~0.57s with the
                                -- zoom:small cinematic-skip in cinematic_timelines.
        -- Zoom = fold-spam firehose. High WC (+0.05) — most hands are
        -- preflop spats you're ahead in. Low pot sizes — heavy small
        -- mass. Jackpots are reachable but rare: `jackpot_scale` sets the
        -- target Stack rate as a FRACTION of the stake's capped jackpot
        -- share (0.20 → ~10% at T1-T3, 9% T4, 8% T5, 7% T6+), so every
        -- stake can bank a {chip} and the strength multiplier lifts it like
        -- the rest. It used to be a flat -0.40 shift, which crossed zero at
        -- T5 and left the top half of the ladder with no Stack chance at
        -- all. `jackpot_emerge` ramps the target in gradually from the
        -- halfway fill point instead of dumping it all into the final Pot
        -- Control level (see OutcomeMath step 7). The cinematic-skip on
        -- small outcomes (data/cinematic_timelines.lua) resolves most hands <1s.
        win_chance_shift = 0.05,
        jackpot_emerge = 0.5,
        jackpot_scale  = 0.20,
        dist_shifts = {
            win_dist  = { small = 0.40, medium =  0.05, large = -0.05, jackpot = -0.40 },
            loss_dist = { small = 0.10, medium = -0.02, large = -0.03, jackpot = -0.05 },
        },
        -- Shows real opponent names that reroll every deal (rerolls_opponents),
        -- rather than anonymous "Seat N" placeholders.
        rerolls_opponents = true,
    },
    mtt_entry,

}
