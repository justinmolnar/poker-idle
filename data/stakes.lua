-- data/stakes.lua
--
-- Stake tier definitions. Player climbs these as bankroll grows; each tier
-- multiplies per-hand earnings and gates the next tier behind a bankroll
-- threshold.
--
-- Tier schema:
--   {
--     id              = "snake_case",
--     name            = "Display Name",
--     blind           = number,         -- big blind in $
--     buy_in          = number,         -- buy-in to sit at this stake
--     unlock_bankroll = number,         -- bankroll required to unlock
--   }
--
-- The MVP plan calls for three tiers. More can be added by appending here.

return {

    {
        id              = "nl2",
        name            = "NL2 ($0.01 / $0.02)",
        blind           = 0.02,
        buy_in          = 2,
        unlock_bankroll = 0,
    },
    {
        id              = "nl10",
        name            = "NL10 ($0.05 / $0.10)",
        blind           = 0.10,
        buy_in          = 10,
        unlock_bankroll = 50,
    },
    {
        id              = "nl50",
        name            = "NL50 ($0.25 / $0.50)",
        blind           = 0.50,
        buy_in          = 50,
        unlock_bankroll = 250,
    },

}
