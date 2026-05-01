-- data/catalog.lua
--
-- The PP-shop catalog. Each item:
--   • is bought ONCE with Poker Points (PP, the meta currency)
--   • applies one or more effects via the EffectsRegistry
--   • persists across prestiges forever
--
-- Items are unique — no buying seventeen Teddy Bears. Stacking-style
-- progression lives in data/run_upgrades.lua, where the same item can be
-- bought up to its max_level for compounding effect.
--
-- ─── Item schema ────────────────────────────────────────────────────────
--   {
--     id          = "snake_case_unique",   -- key in GameState.owned_items
--     name        = "Display Name",
--     effect_text = "Explicit mechanical effect, e.g. '+5% win chance'",
--     description = "Italic flavor blurb under the effect line",
--     sprite      = "sprite_name",          -- looked up via SpriteLoader
--     cost_pp     = number,
--     phase       = "demo" | "mid" | "late" | "system",
--     position    = { x = px, y = px },     -- room placement (deferred)
--     effects     = { { kind = "...", value = ... }, ... }
--     -- optional flags:
--     hidden           = bool,    -- never shown in catalog UI
--     granted_at_start = bool,    -- auto-granted at game start
--     removed_by       = "<id>",  -- entry's effects suppressed when remover is owned
--     requires         = "<id>",  -- gate: prerequisite item id
--     requires_hide    = bool,    -- hide from UI until prerequisite owned
--   }
--
-- ─── Phase ladder ───────────────────────────────────────────────────────
-- Items are tagged by demo phase per docs/math.md and docs/demo-balance.md:
--
--   demo  — reachable in the first ~12 PP. The 11-item starter set
--           (Poster + 10 paid totaling 29 PP, ~46% base shove available).
--   mid   — phase 2 / T4-T5. Higher-cost utility perks.
--   late  — phase 3 / T6 unlock. Cursor swarm, MTT advanced cash tiers.
--   system — phantom entries that drive game-wide mechanisms (handicap).
--
-- A future UI can filter by phase to show only demo items during demo
-- play; the data is tagged here so that filter is one line elsewhere.

return {

    -- ─── System: phantom handicap entry ─────────────────────────────────
    -- Auto-granted at game start, neutralized when the Poker Poster is
    -- owned. The diegetic "you don't know how to play poker" Run-0
    -- experience: T1's naked 50% WC is multiplied to ~20% and losses
    -- skew Medium+. Once Poster lands, this entry stops applying — Run 1
    -- onward plays at normal poker math. Hidden from all UI.
    {
        id              = "no_poster_handicap",
        name            = "(handicap)",
        description     = "Active until you receive the Poker Poster.",
        phase           = "system",
        hidden          = true,
        granted_at_start = true,
        removed_by      = "poker_poster",
        cost_pp         = 0,
        effects         = {
            -- 0.40× knocks T1's naked 0.50 WC down to ~0.20 — "you don't
            -- know how to play" territory.
            { kind = "wc_mult", value = 0.4 },
            -- 4-tier loss skew: knock mass off Tiny/Small, push it onto
            -- Medium and Jackpot. Renormalized in buildOutcome.
            { kind = "loss_dist_shift",
              shift = { tiny = -0.50, small = -0.30,
                        medium = 0.50, jackpot = 0.30 } },
        },
    },

    -- ─── Demo phase: free tutorial item ─────────────────────────────────
    -- The only catalog item that names poker directly. The player buys it
    -- for 0 PP from the post-bust catalog modal — buying it is what lifts
    -- the no-poster handicap (via the `removed_by` hook above). Mechanism
    -- is purely the ownership flag; the entry has no direct effects.
    {
        id            = "poker_poster",
        name          = "Poker Poster",
        effect_text   = "Learn the fundamentals.",
        description   = "Do you not even know how to play poker?",
        sprite        = "poker_poster",
        phase         = "demo",
        cost_pp       = 0,
        position      = { x = 80, y = 200 },
        effects       = {},
    },

    -- ─── Demo phase: 10 paid items totaling 29 PP ───────────────────────
    -- Each item carries both a `shove_rate_add` (catalog base contributor)
    -- and a felt-side mechanical effect. Build archetypes laid out in
    -- docs/demo-balance.md §Lever Coverage.

    {
        id          = "branded_hat",
        name        = "Branded Hat",
        effect_text = "+5% shove rate. Jackpot wins pay 1.2×.",
        description = "Snug fit. Logo's barely noticeable.",
        sprite      = "branded_hat",
        phase       = "demo",
        cost_pp     = 1,
        position    = { x = 120, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.05 },
            { kind = "jackpot_mult",   value = 1.20 },
        },
    },
    {
        id          = "mirror",
        name        = "Mirror",
        effect_text = "+4% shove rate. +10% win chance at HU tables.",
        description = "A nice big one. You should see yourself sometimes.",
        sprite      = "mirror",
        phase       = "demo",
        cost_pp     = 2,
        position    = { x = 160, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.04 },
            { kind = "win_chance_shift", amount = 0.10, gtype = "hu" },
        },
    },
    {
        id          = "energy_drink",
        name        = "Energy Drink",
        effect_text = "+3% shove rate. Hands resolve 25% faster.",
        description = "Tastes terrible. Works fine.",
        sprite      = "energy_drink",
        phase       = "demo",
        cost_pp     = 2,
        position    = { x = 200, y = 220 },
        effects     = {
            { kind = "shove_rate_add",  value = 0.03 },
            { kind = "hand_pace_mult",  value = 1.25 },
        },
    },
    {
        id          = "whiteboard",
        name        = "Whiteboard",
        effect_text = "+4% shove rate. +5% win chance at all tables.",
        description = "Every room could use a whiteboard.",
        sprite      = "whiteboard",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 240, y = 220 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.04 },
            { kind = "win_chance_shift", amount = 0.05 },
        },
    },
    {
        id          = "self_help_book",
        name        = "Self-Help Book",
        effect_text = "+5% shove rate. 25% chance: Tiny win → Small win.",
        description = "Bestseller. Life-changing, they say.",
        sprite      = "self_help_book",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 280, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.05 },
            { kind = "win_tier_shift",
              from = "tiny", to = "small", chance = 0.25 },
        },
    },
    {
        id          = "stress_ball",
        name        = "Stress Ball",
        effect_text = "+6% shove rate. 25% chance: Medium loss → Small loss.",
        description = "For when things get tense.",
        sprite      = "stress_ball",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 320, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.06 },
            { kind = "loss_tier_shift",
              from = "medium", to = "small", chance = 0.25 },
        },
    },
    {
        id          = "lucky_coin",
        name        = "Lucky Coin",
        effect_text = "+4% shove rate. +50% starting bankroll.",
        description = "Heavy. Older than it looks.",
        sprite      = "lucky_coin",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 360, y = 220 },
        effects     = {
            { kind = "shove_rate_add",     value = 0.04 },
            { kind = "start_bankroll_pct", value = 0.50 },
        },
    },
    {
        id          = "lava_lamp",
        name        = "Lava Lamp",
        effect_text = "+5% shove rate. 15% chance: Small win → Medium win.",
        description = "Soothing to watch. Hypnotic, almost.",
        sprite      = "lava_lamp",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 400, y = 220 },
        effects     = {
            { kind = "shove_rate_add", value = 0.05 },
            { kind = "win_tier_shift",
              from = "small", to = "medium", chance = 0.15 },
        },
    },
    {
        id          = "worry_stone",
        name        = "Worry Stone",
        effect_text = "+6% shove rate. 15% chance: Jackpot loss → Medium loss.",
        description = "Worn smooth by someone.",
        sprite      = "worry_stone",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 440, y = 220 },
        -- 4-tier note: demo-balance.md spec says "15% Big loss → Medium",
        -- but the code's outcome model has 4 tiers (tiny/small/medium/
        -- jackpot — no Big). Repointed to Jackpot loss → Medium so the
        -- catastrophic-loss-insurance reading is preserved. Pairs with
        -- Stress Ball's medium-loss cushion.
        effects     = {
            { kind = "shove_rate_add", value = 0.06 },
            { kind = "loss_tier_shift",
              from = "jackpot", to = "medium", chance = 0.15 },
        },
    },
    {
        id          = "plastic_trophy",
        name        = "Plastic Trophy",
        effect_text = "+4% shove rate. MTT cashes pay 4× / 8× / 20×.",
        description = "Participation award. Handsome on a shelf.",
        sprite      = "plastic_trophy",
        phase       = "demo",
        cost_pp     = 3,
        position    = { x = 350, y = 300 },
        effects     = {
            { kind = "shove_rate_add",   value = 0.04 },
            { kind = "mtt_payout_boost", value = 1 },
        },
    },

    -- ─── Mid phase: T4–T5 perks (priced 4–14 PP) ────────────────────────

    {
        id          = "calculator",
        name        = "Calculator",
        effect_text = "+2% win chance at all tables.",
        description = "Sharper reads, every hand.",
        sprite      = "calculator",
        phase       = "mid",
        cost_pp     = 4,
        position    = { x = 180, y = 200 },
        effects     = { { kind = "win_chance_shift", amount = 0.02 } },
    },
    {
        id          = "pen",
        name        = "Pen",
        effect_text = "+25% PP from bounties.",
        description = "More PP from bounties.",
        sprite      = "pen",
        phase       = "mid",
        cost_pp     = 4,
        position    = { x = 230, y = 200 },
        effects     = { { kind = "pp_award_mult", value = 1.25 } },
    },
    {
        id          = "headphones",
        name        = "Headphones",
        effect_text = "Losses 5% softer.",
        description = "Soften your losses.",
        sprite      = "headphones",
        phase       = "mid",
        cost_pp     = 5,
        position    = { x = 280, y = 200 },
        effects     = { { kind = "loss_mult", value = 0.95 } },
    },
    {
        id          = "free_sit",
        name        = "Free Sit",
        effect_text = "Start each run with 1 free table.",
        description = "Start each run with a table seated.",
        sprite      = "free_sit",
        phase       = "mid",
        cost_pp     = 5,
        position    = { x = 330, y = 200 },
        effects     = { { kind = "start_table_count", value = 1 } },
    },
    {
        id          = "pocket_cash",
        name        = "Pocket Cash",
        effect_text = "+$5 starting bankroll.",
        description = "Start each run with $5 extra.",
        sprite      = "pocket_cash",
        phase       = "mid",
        cost_pp     = 8,
        position    = { x = 100, y = 300 },
        effects     = { { kind = "start_bankroll_add", value = 5 } },
    },
    {
        id          = "discount_sits",
        name        = "Discount Sits",
        effect_text = "Buy-ins cost 15% less.",
        description = "Cheaper buy-ins.",
        sprite      = "discount_sits",
        phase       = "mid",
        cost_pp     = 14,
        position    = { x = 600, y = 300 },
        effects     = { { kind = "buy_in_mult", value = 0.85 } },
    },

    -- ─── Late phase: T6 unlock content ──────────────────────────────────

    {
        id          = "cursor_pool",
        name        = "Cursor Pool",
        effect_text = "Unlocks the cursor swarm.",
        description = "Hire assistants to click for you.",
        sprite      = "cursor_pool",
        phase       = "late",
        cost_pp     = 20,
        position    = { x = 100, y = 500 },
        effects     = { { kind = "cursor_unlocked" } },
    },
    {
        id            = "first_cursor",
        name          = "Trained Cursor",
        effect_text   = "+1 cursor.",
        description   = "Your first assistant pointer.",
        sprite        = "first_cursor",
        phase         = "late",
        cost_pp       = 15,
        requires      = "cursor_pool",
        requires_hide = true,
        position      = { x = 200, y = 500 },
        effects       = { { kind = "cursor_count_add", value = 1 } },
    },
    {
        id          = "engraved_plaque",
        name        = "Engraved Plaque",
        effect_text = "MTT cashes pay 5× / 10× / 20×.",
        description = "Maxed tournament cashes.",
        sprite      = "engraved_plaque",
        phase       = "late",
        cost_pp     = 25,
        requires    = "plastic_trophy",
        position    = { x = 450, y = 400 },
        effects     = { { kind = "mtt_payout_boost", value = 2 } },
    },

}
