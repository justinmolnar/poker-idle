-- data/game_types.lua
--
-- Game type definitions. Each layers on top of a stake's base outcome model:
--
--   • seats              — number of opponents at the felt
--   • pace_mult          — multiplier on the per-hand cinematic. >1 = faster.
--                          A hand's length is the sum of its event beats
--                          (data/poker_event_timings.lua, optionally
--                          overridden per gtype) divided by this; see
--                          models/Table.lua's script walker. So seat
--                          count moves duration too — more seats, more
--                          fold/call events. Run sim/gtype_ev.lua for
--                          the derived seconds-per-hand; don't trust a
--                          number written in a comment.
--                          6-max is intentionally below 1 to anchor the
--                          baseline so multi-tabling is the way to scale
--                          throughput, not single-table click-spam.
--                          ─── 2026-08-27 GLOBAL SLOWDOWN ───
--                          Every mode was too fast to watch. Zoom in
--                          particular finished a hand in ~1.4s, so a table
--                          was almost never mid-hand when something tried
--                          to reach it (the Receipt Printer cascade can
--                          only settle a LIVE hand, and so it whiffed
--                          nearly every time). Old values: six_max 0.35,
--                          hu 1.0, zoom 2.2, ko 1.0.
--                          Hand length follows the felt: 8-max and 6-max
--                          are the long ones, the duel is quicker, and Zoom
--                          is the only fast mode at ~3s. Re-run
--                          sim/gtype_ev.lua after touching any of these;
--                          never trust a number written in a comment.
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

local ko_entry = {
        id   = "ko",
        name = "Tournament",
        short = "KO",
        seats = 7,              -- 7 opponents + player = 8 seated total
        -- Eight seated is the most crowded felt in the game, so its hands
        -- run as long as 6-max's. It is never the quick one.
        pace_mult = 0.18,
        rerolls_opponents = false,
        -- 8-max knockout: a cash table whose money is the chips on it.
        -- Each seat sits down with starting_stack_bb; every hand plays
        -- through the cash pipeline (Table:deal) in the tournament's big
        -- blind, which grows as seats bust (Table:koBigBlind). Seats bust
        -- at 0 chips. Ends when the player busts OR is the last seat
        -- standing. Payout from data/ko_payouts.lua by finish position.
        chip_stack_table    = true,
        -- Turbo stacks: ten big blinds, so a big pot is an all-in and a
        -- tournament plays out in a handful of hands. Pot sizes for these
        -- stacks: data/pot_tiers.lua by_gtype.ko.
        starting_stack_bb   = 10,
        -- The blind clock: the tournament's big blind doubles every this
        -- many hands (on top of growing with the average stack as seats
        -- bust), so a tournament closes out in a handful of hands however
        -- the chips move. Table:koBigBlind.
        blind_level_hands   = 2,
        auto_deal           = true,
    }

return {

    {
        id   = "six_max",
        name = "6-max",
        short = "6-MAX",
        seats = 5,
        pace_mult = 0.24,       -- THE TANK: slowest hands in the game.
                                -- Anchors all multi-tabling math.
        -- 6-max is where the money is, and it pays for that with time and
        -- variance rather than with a better win rate: five opponents
        -- means five stacks can go into one pot (data/pot_tiers.lua gives
        -- it a 380-500bb stack against everyone else's ~100), so the WC
        -- comes down to keep the mode honest. You win less often; when you
        -- win big, it is enormous.
        win_chance_shift = -0.08,
        dist_shifts = nil,      -- baseline shape; the bands do the work
        rerolls_opponents = false,
    },
    {
        id   = "hu",
        name = "Heads-Up",
        short = "HU",
        seats = 1,
        pace_mult = 0.50,       -- The duel is still the quickest hand in
                                -- the game by event count (only two seats
                                -- act), so it needs no help being fast.
        -- HU = the duel, and THE {chip} ENGINE. One opponent means one
        -- stack, so its pots are the smallest ceiling in the game — but
        -- both dists skew hard toward large/stack, so it reaches that
        -- ceiling constantly. Since a {stack} is a stack-tier hit, not
        -- a dollar amount, banking chips here is far faster than anywhere
        -- else while the money stays modest. Identity: "small pots, but
        -- you hit the top tier over and over."
        win_chance_shift = -0.10,
        dist_shifts = {
            win_dist  = { small = -0.20, medium = -0.10, large = 0.10, stack = 0.20 },
            loss_dist = { small = -0.20, medium = -0.05, large = 0.10, stack = 0.15 },
        },
        rerolls_opponents = false,
    },
    {
        id   = "zoom",
        name = "Zoom",
        short = "ZOOM",
        seats = 5,
        pace_mult = 0.85,       -- THE FIREHOSE. Zoom also carries beat
                                -- overrides (data/poker_event_timings.lua)
                                -- and a fold-heavy hand shape
                                -- (data/hand_structure.lua), so its hands
                                -- are structurally shorter as well as
                                -- faster: ~6x 6-max's hands per hour.
        -- Zoom = fold-spam firehose. High WC (+0.05) — most hands are
        -- preflop spats you're ahead in. Low pot sizes — heavy small
        -- mass. Stacks are reachable but rare: `stack_scale` sets the
        -- target Stack rate as a FRACTION of the stake's capped stack
        -- share (0.20 → ~10% at T1-T3, 9% T4, 8% T5, 7% T6+), so every
        -- stake can bank a {chip} and the strength multiplier lifts it like
        -- the rest. It used to be a flat -0.40 shift, which crossed zero at
        -- T5 and left the top half of the ladder with no Stack chance at
        -- all. `stack_emerge` ramps the target in gradually from the
        -- halfway fill point instead of dumping it all into the final Pot
        -- Control level (see OutcomeMath step 7).
        win_chance_shift = 0.05,
        stack_emerge = 0.5,
        -- Lowered with the band rework: zoom shares 6-max's five-seat
        -- stack ceiling, so a zoom Stack is now a genuinely huge pot.
        -- It should stay a once-a-session event, not an income stream —
        -- zoom earns through volume, and HU is the chip engine.
        stack_scale  = 0.08,
        dist_shifts = {
            win_dist  = { small = 0.40, medium =  0.05, large = -0.05, stack = -0.40 },
            loss_dist = { small = 0.10, medium = -0.02, large = -0.03, stack = -0.05 },
        },
        -- Shows real opponent names that reroll every deal (rerolls_opponents),
        -- rather than anonymous "Seat N" placeholders.
        rerolls_opponents = true,
    },
    ko_entry,

}
