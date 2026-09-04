-- data/showdown_realism.lua
--
-- Plausibility policy for the CARDS shown at showdowns. Money outcomes are
-- decided before any card exists (won + tier for tables, the rolled runout
-- triple for the shove gauntlet); cards are theater. This file is the knob
-- box for making that theater read as real poker: which preflop matchups a
-- given outcome samples, what the winner has to show for a pot that size,
-- and how many live outs the House holds before a gauntlet runner lands.
--
-- Everything here is presentation-side tuning. Nothing in this file moves
-- a single dollar — change any number freely and the economy is identical.
--
-- ─── gauntlet ───────────────────────────────────────────────────────────
-- Consumed by models/Gauntlet. The gauntlet needs no equity table: after
-- the 5-card board, both hands are known and every remaining deck card can
-- be classified as a card that keeps the player ahead ("safe") or flips
-- the hand to the dealer ("rob"). The rob-count over the remaining deck IS
-- the exact conditional equity of the coming runner.
--
--   rob_outs        {min,max} — when a runout is a scripted robbery, the
--                   dealer's rob-cards among the candidates (43 at c6, 42
--                   at c7) must land in this band. 3..12 of 43 is a 7-28%
--                   beat: a real sweat, never a repeated one-outer, never
--                   a coin flip dressed as a lock.
--   max_sweat_outs  when the player SURVIVES a runner, the dealer may hold
--                   at most this many rob-cards. 0 outs (drawing dead) is
--                   allowed — a locked-up win is real poker.
--   r1_win_cat_floor / r1_loss_cat_floor
--                   HandEval category floor (2 = pair) the runout-1 winner
--                   must show. Kills 9-high-beats-8-high showdowns.
--   strict_attempts of the construction retry cap, how many attempts hold
--                   the strict bands before `relaxed` widens the funnel.
--                   The cap-exhausted fallback in models/Gauntlet is the
--                   final backstop either way.
--
-- ─── cash ───────────────────────────────────────────────────────────────
-- Consumed by models/HandRealism for table showdowns. Bands are PLAYER
-- preflop equity (tie-split, 0..1) against the shown opponent, sampled
-- from data/preflop_equity.lua. Each tier lists weighted shapes; `w` picks
-- between them. Bounds must be multiples of 0.025 (the sampler's bucket
-- width). `opp_min_eqvr` additionally requires the opponent's own
-- hand-vs-random equity — "they had a stack-off hand too" (coolers).
--
-- Small tier has no bands on purpose: small pots never reach showdown
-- (data/hand_structure.lua), so only the player's always-visible hole
-- matters there — handled by the exponents below, not by matchups.
--
--   showdown_exp     weight exponent (eq-vs-random ^ exp) applied to BOTH
--                    hands inside band sampling: showdown hands look like
--                    hands people play. 4 ⇒ AA outweighs 72o ~35:1/combo.
--   foldout_win_exp  mild playability lean on the player's hole for
--                    small-tier WINS (losses stay fully random — folding
--                    out a loser with junk is correct realism).
--   cat_floors       category floors on the final 7-card hands, enforced
--                    softly (first floor_attempts matchup tries, then
--                    dropped rather than fought). `winner` is what the
--                    pot was won with; `loser` is what the beaten player
--                    was willing to put a pot that size in with.
--   distinct_labels  reject showdowns where both sides' hand NAMES come
--                    out identical ("two pair, 4s and 3s" against "two
--                    pair, 4s and 3s", separated only by a kicker the
--                    label never shows). It is legal poker and it reads
--                    on the felt as a bug, because the two labels the
--                    view prints are the player's whole explanation of
--                    who won.
--
-- Shape mirrors data/hand_structure.lua: `default` + optional per-gtype
-- override merged over it PER KEY.

return {
    gauntlet = {
        rob_outs          = { 3, 12 },
        max_sweat_outs    = 16,
        r1_win_cat_floor  = 2,   -- HandEval.PAIR
        r1_loss_cat_floor = 2,
        strict_attempts   = 350,
        survive_c6_tries  = 5,   -- safe c6 candidates probed for a valid c7
                                 -- before rejecting the deal (a fresh deal
                                 -- is cheaper than exhausting all ~25)
        relaxed = {
            rob_outs       = { 1, 20 },
            max_sweat_outs = 24,
            cat_floor      = 1,
        },
    },

    default = {
        matchup_attempts = 16,
        board_attempts   = 12,
        floor_attempts   = 10,
        showdown_exp     = 4,
        foldout_win_exp  = 1,
        bands = {
            win = {
                -- small: nil — no showdown, no matchup machinery
                medium  = { { lo = 0.550, hi = 0.750, w = 1.0 } },
                large   = {
                    { lo = 0.600, hi = 0.825, w = 0.8 },  -- big favorite got paid
                    { lo = 0.450, hi = 0.550, w = 0.2 },  -- won a flip
                },
                stack = {
                    { lo = 0.500, hi = 0.700, w = 0.7, opp_min_eqvr = 0.55 },  -- cooler paid off
                    { lo = 0.650, hi = 0.850, w = 0.3 },  -- monster got paid anyway
                },
            },
            loss = {
                medium  = {
                    { lo = 0.300, hi = 0.475, w = 0.6 },  -- you were behind
                    { lo = 0.450, hi = 0.550, w = 0.4 },  -- lost a flip
                },
                large   = {
                    { lo = 0.550, hi = 0.750, w = 0.5 },                       -- bad beat
                    { lo = 0.350, hi = 0.500, w = 0.5, opp_min_eqvr = 0.55 },  -- cooler
                },
                stack = {
                    { lo = 0.600, hi = 0.800, w = 0.7 },                       -- sucked out on
                    { lo = 0.425, hi = 0.550, w = 0.3, opp_min_eqvr = 0.60 },  -- premium cooler
                },
            },
        },
        distinct_labels = true,
        cat_floors = {
            medium  = { winner = 2 },              -- ≥ pair
            -- Nobody loses a big pot holding nothing: the beaten hand
            -- needs to be something you could talk yourself into.
            large   = { winner = 3, loser = 2 },   -- ≥ two pair / ≥ pair
            stack = { winner = 3, loser = 2 },   -- AA-vs-KK canon: loser shows a pair
        },
    },

    by_gtype = {},
}
