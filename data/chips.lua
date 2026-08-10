-- data/chips.lua
--
-- Procedural-chip data: the denomination ladder + per-stake palette
-- mapping + tier-target chip counts for the breakdown algorithm.
--
-- The ladder spans 33 denominations from $0.01 to $500Q (5e17) — enough to
-- cover the $0.02 → $1k bb range across all six stakes, plus the bankroll
-- pile, which runs well into the trillions in late Act 3 and has no real
-- ceiling. A pile is only ever as many chips as its tier target, so extra
-- rungs cost nothing; running OUT of rungs is what hurts, because the
-- breakdown then counts in units of a denomination far too small.
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
--   tier_chip_target = { small = N, medium = N, large = N, jackpot = N }

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
        -- Beyond $1M. The ladder USED to stop here, which meant a late-game
        -- bankroll broke down into millions of $1M chips — the breakdown
        -- emits one token per unit of its primary denomination, so the
        -- table it built was the size of the bankroll divided by a million.
        -- Every rung added here is a rung the pile never has to count to.
        -- Suffixes match utils/format.formatBig (K / M / B / T / Q) so a
        -- chip's face and the readout above it agree.
        { value = 5e6,        color = { 0.45, 0.80, 0.55 }, label = "5M"   },
        { value = 25e6,       color = { 0.25, 0.45, 0.75 }, label = "25M"  },
        { value = 100e6,      color = { 0.72, 0.20, 0.45 }, label = "100M" },
        { value = 500e6,      color = { 0.15, 0.60, 0.62 }, label = "500M" },
        { value = 1e9,        color = { 0.85, 0.75, 0.95 }, label = "1B"   },
        { value = 5e9,        color = { 0.60, 0.85, 0.25 }, label = "5B"   },
        { value = 25e9,       color = { 0.35, 0.25, 0.60 }, label = "25B"  },
        { value = 100e9,      color = { 0.90, 0.45, 0.35 }, label = "100B" },
        { value = 500e9,      color = { 0.20, 0.75, 0.75 }, label = "500B" },
        { value = 1e12,       color = { 0.98, 0.92, 0.70 }, label = "1T"   },
        { value = 5e12,       color = { 0.70, 0.35, 0.15 }, label = "5T"   },
        { value = 25e12,      color = { 0.45, 0.60, 0.90 }, label = "25T"  },
        { value = 100e12,     color = { 0.80, 0.20, 0.60 }, label = "100T" },
        { value = 500e12,     color = { 0.30, 0.70, 0.30 }, label = "500T" },
        { value = 1e15,       color = { 0.90, 0.90, 0.98 }, label = "1Q"   },
        { value = 5e15,       color = { 0.75, 0.55, 0.90 }, label = "5Q"   },
        { value = 25e15,      color = { 0.95, 0.70, 0.15 }, label = "25Q"  },
        { value = 100e15,     color = { 0.25, 0.35, 0.45 }, label = "100Q" },
        { value = 500e15,     color = { 0.99, 0.97, 0.88 }, label = "500Q" },
    },

    -- ── Per-stake palettes (4 denominations each) ──────────────────────
    -- Indices into the denominations list above.
    --
    -- Each window brackets its stake: the smallest rung has to be small
    -- enough to post the small blind, the largest big enough that a full
    -- buy-in is a couple of dozen chips rather than thousands.
    --
    -- EVERY stake needs an entry. A stake that falls through to
    -- full_palette gets the whole ladder, and the breakdown then measures
    -- a nine-figure buy-in in whatever rung happens to score best across
    -- 33 of them — which is how the ultra tables ended up drawing piles
    -- of thousands of chips every frame.
    --
    --   T1  ($0.02 bb): $0.01 - $1
    --   T2  ($0.10 bb): $0.01 - $1 (same micro-stake ladder as T1)
    --   T3  ($1    bb): $0.25 - $25
    --   T4  ($10   bb): $1    - $100
    --   T5  ($100  bb): $25   - $1k
    --   T6  ($1k   bb): $500  - $25k
    --   T7  ($10k  bb): $5k   - $500k
    --   T8  ($100k bb): $25k  - $1M
    --   T9  ($1M   bb): $500k - $25M
    --   T10 ($10M  bb): $5M   - $100B, deliberately NOT contiguous. Its
    --       buy-in is 10,000bb rather than the 100bb every other stake
    --       uses, so no four adjacent rungs can both post its blinds and
    --       count its stack. The window skips instead.
    stake_palettes = {
        s001 = { 1, 2, 3, 4 },
        s002 = { 1, 2, 3, 4 },
        s003 = { 3, 4, 5, 6 },
        s004 = { 4, 5, 6, 7 },
        s005 = { 6, 7, 8, 9 },
        s006 = { 8, 9, 10, 11 },
        s007 = { 10, 11, 12, 13 },
        s008 = { 11, 12, 13, 14 },
        s009 = { 13, 14, 15, 16 },
        s010 = { 15, 18, 20, 22 },
    },

    -- The full ladder — used by the bankroll pile (no per-stake constraint).
    -- MUST list every denomination above: it's what stops a huge amount
    -- from bottoming out on a denomination far too small to represent it.
    full_palette = {
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
        15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33,
    },

    -- ── Tier chip-count targets (visual heft via chip count) ───────────
    -- Used by DenominationBreakdown.breakdown to pick the primary
    -- denomination — the goal isn't fewest-tokens, it's a pile whose token
    -- count signals magnitude at a glance. Small wins look like 3-4 chips;
    -- jackpots look like a pile of 30+.
    tier_chip_target = {
        small    = 4,
        medium   = 12,
        large  = 28,
        jackpot = 50,
    },

    -- Per-tier cap on the chip-burst fountain (services/FlightSystem.lua).
    -- Default MAX_PER_EVENT (7) bottlenecks high tiers — bump it for
    -- large and jackpot so the fountain actually shows the magnitude.
    -- Passed as options.max_per_event on emitBurst.
    --
    -- Applies to LOOSE bursts only. Pile-to-pile transfers
    -- (views/ChipFlight.transfer) are uncapped by design: a cap there
    -- would leave the destination short by every chip it declined to
    -- carry. tier_chip_target above is what sizes those.
    tier_burst_cap = {
        small    = 7,
        medium   = 8,
        large  = 12,
        jackpot = 18,
    },
}
