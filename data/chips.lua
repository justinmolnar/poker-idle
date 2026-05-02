-- data/chips.lua
--
-- Procedural-chip data: the denomination ladder + per-stake palette
-- mapping + tier-target chip counts for the breakdown algorithm.
--
-- The ladder spans 14 denominations from $0.01 to $1M — enough to cover
-- the $0.02 → $1k bb range across all six stakes, plus the bankroll pile
-- which can reach 8-figure totals at endgame after multi-prestige stacking.
--
-- Each table renders only the four denominations in its stake's palette
-- (chip variety per surface stays bounded). The bankroll pile bottom-
-- middle uses the full ladder.
--
-- Pure data — no logic, no requires of engine modules.
--
-- Color tokens are {r, g, b} tables, valid arguments to Theme.setColor.
-- Theme.setColor is the rule-compliant entry point for love.graphics.setColor;
-- chip colors stored here flow through that dispatch in views/Chips.lua.
--
-- Schema:
--   denominations = {
--     { value = number, color = {r, g, b}, label = "string" }, ...
--   }
--   stake_palettes = {
--     [stake_id] = { idx, idx, idx, idx },   -- four denomination indices
--   }
--   tier_chip_target = { tiny = N, small = N, medium = N, jackpot = N }

return {

    -- ── Denomination ladder ────────────────────────────────────────────
    -- Ordered from smallest to largest. Indices into this list are how
    -- the rest of the system refers to denominations.
    denominations = {
        { value = 0.01,       color = { 0.95, 0.95, 0.92 }, label = "1c"   },
        { value = 0.05,       color = { 0.78, 0.22, 0.22 }, label = "5c"   },
        { value = 0.25,       color = { 0.30, 0.62, 0.32 }, label = "25c"  },
        { value = 1.00,       color = { 0.30, 0.55, 0.85 }, label = "1"    },
        { value = 5.00,       color = { 0.85, 0.30, 0.20 }, label = "5"    },
        { value = 25.00,      color = { 0.20, 0.65, 0.40 }, label = "25"   },
        { value = 100.00,     color = { 0.10, 0.10, 0.12 }, label = "100"  },
        { value = 500.00,     color = { 0.55, 0.30, 0.70 }, label = "500"  },
        { value = 1000.00,    color = { 0.92, 0.85, 0.30 }, label = "1K"   },
        { value = 5000.00,    color = { 0.55, 0.40, 0.25 }, label = "5K"   },
        { value = 25000.00,   color = { 0.40, 0.78, 0.85 }, label = "25K"  },
        { value = 100000.00,  color = { 0.95, 0.55, 0.78 }, label = "100K" },
        { value = 500000.00,  color = { 0.95, 0.55, 0.20 }, label = "500K" },
        { value = 1000000.00, color = { 0.98, 0.85, 0.45 }, label = "1M"   },
    },

    -- ── Per-stake palettes (4 denominations each) ──────────────────────
    -- Indices into the denominations list above.
    --
    --   T1 ($0.02 bb): $0.01 - $1
    --   T2 ($0.25 bb): $0.05 - $5
    --   T3 ($1   bb):  $0.25 - $25
    --   T4 ($10  bb):  $1   - $100
    --   T5 ($100 bb):  $25  - $1k
    --   T6 ($1k  bb):  $500 - $25k
    stake_palettes = {
        s001 = { 1, 2, 3, 4 },
        s002 = { 2, 3, 4, 5 },
        s003 = { 3, 4, 5, 6 },
        s004 = { 4, 5, 6, 7 },
        s005 = { 6, 7, 8, 9 },
        s006 = { 8, 9, 10, 11 },
    },

    -- The full ladder — used by the bankroll pile (no per-stake constraint).
    full_palette = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 },

    -- ── Tier chip-count targets (visual heft via chip count) ───────────
    -- Used by DenominationBreakdown.breakdown to pick the primary
    -- denomination — the goal isn't fewest-tokens, it's a pile whose token
    -- count signals magnitude at a glance. Tiny wins look like 3-4 chips;
    -- jackpots look like a pile of 30+.
    tier_chip_target = {
        tiny    = 4,
        small   = 12,
        medium  = 28,
        jackpot = 50,
    },

    -- Per-tier cap on the chip-burst fountain (services/FlightSystem.lua).
    -- Default MAX_PER_EVENT (7) bottlenecks high tiers — bump it for
    -- medium and jackpot so the fountain actually shows the magnitude.
    -- Read by GrindController:_emitResolutionChips, passed as
    -- options.max_per_event on emitBurst.
    tier_burst_cap = {
        tiny    = 7,
        small   = 8,
        medium  = 12,
        jackpot = 18,
    },
}
