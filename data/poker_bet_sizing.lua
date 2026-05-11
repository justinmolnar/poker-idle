-- data/poker_bet_sizing.lua
--
-- Per-street bet-size distributions for the script writer. Pure data.
--
-- Preflop sizes are in BB units. Postflop sizes are pot-fractions for
-- bets and current-bet multiples for raises. The writer rolls a uniform
-- value within the [min, max] range when picking an amount, then
-- compatibility-filters against the destination target before
-- committing the event.
--
-- Tuning notes:
--   - Preflop opens are 2-4× BB; 3-bets are 2.5-4× the opener.
--   - Flop bets are roughly half-pot; raises are 2.5-3.5× the bet.
--   - Turn / river bets escalate slightly — bigger pots, more polarized
--     ranges.

return {
    preflop = {
        open_bb_min  = 2.0,
        open_bb_max  = 4.0,
        threebet_x_min = 2.5,
        threebet_x_max = 4.0,
    },

    flop = {
        bet_pot_frac_min  = 0.40,
        bet_pot_frac_max  = 0.80,
        raise_x_min       = 2.5,
        raise_x_max       = 3.5,
    },

    turn = {
        bet_pot_frac_min  = 0.50,
        bet_pot_frac_max  = 0.90,
        raise_x_min       = 2.5,
        raise_x_max       = 3.5,
    },

    river = {
        bet_pot_frac_min  = 0.50,
        bet_pot_frac_max  = 1.00,
        raise_x_min       = 2.5,
        raise_x_max       = 3.5,
    },
}
