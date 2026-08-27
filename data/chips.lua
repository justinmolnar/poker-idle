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
--     { value = number, color = {r, g, b}, label = "string",
--       spot = {r, g, b}, spots = number }, ...
--   }
--
--   stake_palettes = {
--     [stake_id] = { idx, idx, idx, idx },   -- four denomination indices
--   }
--   tier_chip_target = { small = N, medium = N, large = N, jackpot = N }
--
-- ── On `spot` / `spots` ────────────────────────────────────────────────
-- The edge markings: contrasting blocks set into a chip's rim, the way a
-- real casino chip carries them.
--
-- COLOR is what separates the ladder, and it has to be, because a chip is
-- often seen too small for a rim pattern to resolve at all. The rule the
-- colors above are built to: no two rungs that can appear together — any
-- stake palette, and any four-in-a-row of the bankroll's full ladder — may
-- be close in color. That is what the 25c/$25 green collision violated.
--
-- The spots are the SECOND signal, not the first. They give each rung its
-- own face at a glance and they are what makes a stack read as separate
-- chips from the side, where all you see is a 4px crescent of rim.
--
-- Written per rung rather than computed so one can be hand-tuned without
-- silently breaking a neighbour. Counts stay small on purpose: at 26px a
-- 12-spot rim is 1.4px per spot, which costs an arc each and shows nothing.

-- The two edge-spot inks. A spot only reads if it fights its own body, so
-- every rung takes whichever of these its body color doesn't drown: PALE on
-- dark bodies, INK on light ones.
local PALE = { 0.97, 0.97, 0.95 }
local INK  = { 0.09, 0.09, 0.11 }

return {

    -- ── Denomination ladder ────────────────────────────────────────────
    -- Ordered from smallest to largest. Indices into this list are how
    -- the rest of the system refers to denominations.
    denominations = {
        -- ── Casino anchors ────────────────────────────────────────────
        -- The bottom of the ladder keeps the colors a poker player already
        -- knows: white 1, red 5, green 25, blue 1, black 100, purple 500,
        -- gold 1000. The two REPEATS of that cycle (5c/$5 red, 25c/$25
        -- green) are pulled apart by hue — crimson vs vermilion, leaf vs
        -- teal — because the bankroll pile draws the whole ladder at once
        -- and s003 puts 25c and $25 on the same table.
        { value = 0.01,       color = { 0.94, 0.93, 0.88 }, label = "1c",   spot = INK,  spots = 4  },
        { value = 0.05,       color = { 0.72, 0.14, 0.18 }, label = "5c",   spot = PALE, spots = 6  },
        { value = 0.25,       color = { 0.20, 0.58, 0.28 }, label = "25c",  spot = PALE, spots = 3  },
        { value = 1.00,       color = { 0.20, 0.42, 0.80 }, label = "1",    spot = PALE, spots = 8  },
        { value = 5.00,       color = { 0.88, 0.34, 0.16 }, label = "5",    spot = PALE, spots = 5  },
        { value = 25.00,      color = { 0.10, 0.60, 0.55 }, label = "25",   spot = PALE, spots = 8  },
        { value = 100.00,     color = { 0.11, 0.11, 0.14 }, label = "100",  spot = PALE, spots = 4  },
        { value = 500.00,     color = { 0.52, 0.26, 0.72 }, label = "500",  spot = PALE, spots = 6  },
        { value = 1000.00,    color = { 0.92, 0.78, 0.22 }, label = "1K",   spot = INK,  spots = 3  },
        { value = 5000.00,    color = { 0.48, 0.30, 0.16 }, label = "5K",   spot = PALE, spots = 8  },
        { value = 25000.00,   color = { 0.35, 0.76, 0.88 }, label = "25K",  spot = INK,  spots = 5  },
        { value = 100000.00,  color = { 0.94, 0.52, 0.72 }, label = "100K", spot = INK,  spots = 8  },
        { value = 500000.00,  color = { 0.95, 0.58, 0.12 }, label = "500K", spot = INK,  spots = 4  },
        { value = 1000000.00, color = { 0.97, 0.86, 0.55 }, label = "1M",   spot = INK,  spots = 6  },
        -- Beyond $1M. The ladder USED to stop here, which meant a late-game
        -- bankroll broke down into millions of $1M chips — the breakdown
        -- emits one token per unit of its primary denomination, so the
        -- table it built was the size of the bankroll divided by a million.
        -- Every rung added here is a rung the pile never has to count to.
        -- Suffixes match utils/format.formatBig (K / M / B / T / Q) so a
        -- chip's face and the readout above it agree.
        { value = 5e6,        color = { 0.40, 0.82, 0.52 }, label = "5M",   spot = INK,  spots = 3  },
        { value = 25e6,       color = { 0.24, 0.30, 0.68 }, label = "25M",  spot = PALE, spots = 8  },
        { value = 100e6,      color = { 0.62, 0.14, 0.34 }, label = "100M", spot = PALE, spots = 5  },
        { value = 500e6,      color = { 0.10, 0.48, 0.52 }, label = "500M", spot = PALE, spots = 8  },
        { value = 1e9,        color = { 0.74, 0.70, 0.94 }, label = "1B",   spot = INK,  spots = 4  },
        { value = 5e9,        color = { 0.62, 0.84, 0.20 }, label = "5B",   spot = INK,  spots = 6  },
        { value = 25e9,       color = { 0.34, 0.22, 0.56 }, label = "25B",  spot = PALE, spots = 3  },
        { value = 100e9,      color = { 0.92, 0.46, 0.38 }, label = "100B", spot = INK,  spots = 8  },
        { value = 500e9,      color = { 0.16, 0.72, 0.72 }, label = "500B", spot = INK,  spots = 5  },
        { value = 1e12,       color = { 0.96, 0.92, 0.78 }, label = "1T",   spot = INK,  spots = 8  },
        { value = 5e12,       color = { 0.68, 0.32, 0.12 }, label = "5T",   spot = PALE, spots = 4  },
        { value = 25e12,      color = { 0.46, 0.58, 0.90 }, label = "25T",  spot = INK,  spots = 6  },
        { value = 100e12,     color = { 0.80, 0.18, 0.58 }, label = "100T", spot = PALE, spots = 3  },
        { value = 500e12,     color = { 0.18, 0.48, 0.24 }, label = "500T", spot = PALE, spots = 8  },
        { value = 1e15,       color = { 0.88, 0.92, 0.97 }, label = "1Q",   spot = INK,  spots = 5  },
        { value = 5e15,       color = { 0.62, 0.42, 0.86 }, label = "5Q",   spot = PALE, spots = 8  },
        { value = 25e15,      color = { 0.95, 0.68, 0.14 }, label = "25Q",  spot = INK,  spots = 4  },
        { value = 100e15,     color = { 0.28, 0.36, 0.46 }, label = "100Q", spot = PALE, spots = 6  },
        { value = 500e15,     color = { 0.90, 0.90, 0.84 }, label = "500Q", spot = INK,  spots = 3  },
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

    -- A payout composed through a stake's four-chip window degrades to
    -- one top-denomination chip per unit; past this many top chips the
    -- composer falls back to full_palette. Render budget — data, not a
    -- code literal (services/DenominationBreakdown.paletteForAmount).
    palette_max_chips = 60,

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
