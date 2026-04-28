-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Stacking — each entry can
-- be bought up to `max_level` times. Level N's effect block is applied N
-- times via EffectsRegistry:applyN, so each level is one more shift pushed
-- onto ctx.grid_shifts (or one more level of focus_capacity / earnings, etc).
--
-- Item schema:
--   {
--     id          = "snake_case_unique",
--     name        = "Display Name",
--     description = "Short blurb shown under the name (no level mention here)",
--     max_level   = integer,
--     costs       = { $L1, $L2, $L3, ... },        -- 1-indexed, length = max_level
--     effects     = { { kind = "...", value = ... }, ... }  -- applied PER level
--   }

return {

    -- General-purpose lose-to-win shift across all 4 tiers. The all-rounder
    -- upgrade — works against every opponent type, every game type.
    {
        id          = "sharper_reads",
        name        = "Sharper Reads",
        description = "Read opponents better.",
        max_level   = 8,
        costs       = { 0.50, 1.00, 2.00, 4.00, 8.00, 16.00, 32.00, 64.00 },
        effects     = {
            { kind = "grid_shift", op = "lose_to_win", amount = 0.04 },
        },
    },

    -- Cascade probability mass downward through the pot tiers. This is the
    -- engine for the headline jackpot-win % climbing toward 80% — bigger
    -- pots both ways, but Sharper Reads keeps the W:L ratio in your favor.
    {
        id          = "big_pots",
        name        = "Big Pots",
        description = "Pots run bigger.",
        max_level   = 5,
        costs       = { 1.00, 3.00, 9.00, 27.00, 81.00 },
        effects     = {
            { kind = "grid_shift", op = "shift_downward", amount = 0.06 },
        },
    },

    -- Specialist against predictable styles. Strong vs fish (loose-passive
    -- callers) and nit (ultra-tight folders) — both styles whose ranges
    -- you can read clearly. Useless against TAG / LAG.
    {
        id          = "patience",
        name        = "Patience",
        description = "Patient against passive players.",
        max_level   = 5,
        costs       = { 0.75, 2.00, 5.50, 14.00, 35.00 },
        effects     = {
            { kind = "grid_shift", op = "lose_to_win", amount = 0.12, style = "fish" },
            { kind = "grid_shift", op = "lose_to_win", amount = 0.12, style = "nit"  },
        },
    },

    -- Focus capacity — orthogonal mechanic, not a grid shift.
    {
        id          = "coffee",
        name        = "Coffee",
        description = "+1 focus capacity per level",
        max_level   = 4,
        costs       = { 1.50, 4.00, 10.00, 25.00 },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
    },

}
