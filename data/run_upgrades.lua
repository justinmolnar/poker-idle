-- data/run_upgrades.lua
--
-- Bankroll-purchased upgrades, lost on prestige. Stacking — each entry can
-- be bought up to `max_level` times. Level N's effect block is applied N
-- times via EffectsRegistry:applyN, so additive applicators (`win_rate_add`)
-- sum to N×value and multiplicative ones (`earnings_mult`) compound to
-- value^N. The applicator never has to know it's being stacked.
--
-- Item schema:
--   {
--     id          = "snake_case_unique",
--     name        = "Display Name",
--     description = "Short blurb shown under the name (no level mention here)",
--     max_level   = integer,                       -- 1+, ceiling on owned levels
--     costs       = { $L1, $L2, $L3, ... },        -- 1-indexed, length = max_level
--     effects     = { { kind = "...", value = ... }, ... }  -- applied PER level
--   }
--
-- NOTE: shove_rate_add is reserved for catalog items only — run upgrades
-- that include it would violate the meta-progression north-star.
--
-- Cost curves use a ~2× per level growth so each next level feels like a
-- meaningful grind. Numbers tuned to the $2 starting bankroll (Sharper
-- Reads L1 at $0.50 = a quarter of starting cash) — feel free to retune.

return {

    {
        id          = "sharper_reads",
        name        = "Sharper Reads",
        description = "+1.5% win rate per level",
        max_level   = 8,
        costs       = { 0.50, 1.00, 2.00, 4.00, 8.00, 16.00, 32.00, 64.00 },
        effects     = { { kind = "win_rate_add", value = 0.015 } },
    },

    {
        id          = "big_pots",
        name        = "Big Pots",
        description = "+6% earnings on wins per level",
        max_level   = 5,
        costs       = { 1.00, 3.00, 9.00, 27.00, 81.00 },
        effects     = { { kind = "earnings_mult", value = 1.06 } },
    },

    {
        id          = "patience",
        name        = "Patience",
        description = "+5% vs every playstyle (per level, multiplicative)",
        max_level   = 5,
        costs       = { 0.75, 2.00, 5.50, 14.00, 35.00 },
        effects = {
            { kind = "vs_fish_mult", value = 1.05 },
            { kind = "vs_tag_mult",  value = 1.05 },
            { kind = "vs_lag_mult",  value = 1.05 },
            { kind = "vs_nit_mult",  value = 1.05 },
        },
    },

    {
        id          = "coffee",
        name        = "Coffee",
        description = "+1 focus capacity per level",
        max_level   = 4,
        costs       = { 1.50, 4.00, 10.00, 25.00 },
        effects     = { { kind = "focus_capacity_add", value = 1 } },
    },

}
