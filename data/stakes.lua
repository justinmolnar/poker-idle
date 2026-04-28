-- data/stakes.lua
--
-- Stake tier definitions. Player climbs these as bankroll grows; each tier
-- multiplies per-hand earnings and gates the next tier behind a bankroll
-- threshold.
--
-- Tier schema:
--   {
--     id              = "snake_case",
--     name            = "Long Display Name (used in pickers)",
--     display_name    = "Short label (used on table panels)",
--     blind           = number,    -- big blind in $ (cosmetic — for the long name)
--     buy_in          = number,    -- buy-in to sit at this stake
--     unlock_bankroll = number,    -- bankroll required before this stake unlocks
--     bet_size        = number,    -- $ deducted from bankroll on a losing hand
--     pot_size        = number,    -- $ added to bankroll on a winning hand
--     win_rate        = number,    -- 0..1 base probability of winning a hand
--     hands_per_min   = number,    -- base tick rate (hands/minute) for this stake
--   }
--
-- EV per stake (initial values, will be tuned in playtest):
--   NL2  ≈ $5.70 / min   (slow, safe)
--   NL10 ≈ $35.4 / min   (mid)
--   NL50 ≈ $79.5 / min   (high — scales bigger losses too)

return {

    {
        id              = "nl2",
        name            = "NL2 ($0.01 / $0.02)",
        display_name    = "Cash NL2",
        blind           = 0.02,
        buy_in          = 2,
        unlock_bankroll = 0,
        bet_size        = 0.40,
        pot_size        = 0.50,
        win_rate        = 0.55,
        hands_per_min   = 60,
    },
    {
        id              = "nl10",
        name            = "NL10 ($0.05 / $0.10)",
        display_name    = "Cash NL10",
        blind           = 0.10,
        buy_in          = 10,
        unlock_bankroll = 50,
        bet_size        = 2.00,
        pot_size        = 4.00,
        win_rate        = 0.53,
        hands_per_min   = 30,
    },
    {
        id              = "nl50",
        name            = "NL50 ($0.25 / $0.50)",
        display_name    = "Cash NL50",
        blind           = 0.50,
        buy_in          = 50,
        unlock_bankroll = 250,
        bet_size        = 10.00,
        pot_size        = 20.00,
        win_rate        = 0.51,
        hands_per_min   = 15,
    },

}
