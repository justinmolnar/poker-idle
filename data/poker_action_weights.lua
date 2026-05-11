-- data/poker_action_weights.lua
--
-- Weights for the script writer's action-kind picker. Pure data.
--
-- Indexed: weights[street][situation][kind] = weight
--   street    ∈ "preflop" | "flop" | "turn" | "river"
--   situation ∈ "to_open"            -- no bet to call yet (action opener)
--             | "to_call"            -- facing a bet
--             | "to_call_after_raise"-- facing a raise after we already called
--   kind      ∈ "fold" | "check" | "call" | "raise" | "all_in"
--
-- The writer reads the relevant entry, filters out kinds that aren't
-- legal in the current writer state, and samples weighted-random.
--
-- Numbers are rough first-pass — they encode "fold is the most common
-- preflop action," "raises are rare," "all-ins are very rare." Tune
-- with playtesting.

return {
    preflop = {
        to_open = {
            -- Most preflop hands open with a fold; raises happen but
            -- aren't typical. "call" here means open-limp, which is a
            -- weak-table behavior; keep it modest.
            fold   = 70,
            check  = 0,    -- can't check preflop unless BB and unraised
            call   = 18,
            raise  = 11,
            all_in = 1,
        },
        to_call = {
            -- Facing a preflop raise: usually fold, sometimes call,
            -- occasionally 3-bet.
            fold   = 70,
            check  = 0,
            call   = 22,
            raise  = 7,
            all_in = 1,
        },
        to_call_after_raise = {
            -- Facing a 3-bet: fold heavily, sometimes call, very rarely
            -- 4-bet or shove.
            fold   = 80,
            check  = 0,
            call   = 14,
            raise  = 5,
            all_in = 1,
        },
    },

    flop = {
        to_open = {
            -- C-bet often, check sometimes. Fold isn't a thing when
            -- you're the opener with no bet to call.
            fold   = 0,
            check  = 35,
            call   = 0,
            raise  = 60,
            all_in = 5,
        },
        to_call = {
            fold   = 50,
            check  = 0,
            call   = 35,
            raise  = 13,
            all_in = 2,
        },
        to_call_after_raise = {
            fold   = 65,
            check  = 0,
            call   = 25,
            raise  = 8,
            all_in = 2,
        },
    },

    turn = {
        to_open = {
            fold   = 0,
            check  = 30,
            call   = 0,
            raise  = 65,
            all_in = 5,
        },
        to_call = {
            fold   = 55,
            check  = 0,
            call   = 30,
            raise  = 12,
            all_in = 3,
        },
        to_call_after_raise = {
            fold   = 70,
            check  = 0,
            call   = 22,
            raise  = 5,
            all_in = 3,
        },
    },

    river = {
        to_open = {
            -- River often goes check/check; bets are bigger when they
            -- happen.
            fold   = 0,
            check  = 45,
            call   = 0,
            raise  = 50,
            all_in = 5,
        },
        to_call = {
            fold   = 55,
            check  = 0,
            call   = 35,
            raise  = 7,
            all_in = 3,
        },
        to_call_after_raise = {
            fold   = 70,
            check  = 0,
            call   = 25,
            raise  = 2,
            all_in = 3,
        },
    },
}
