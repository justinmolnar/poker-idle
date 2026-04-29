-- data/catalog.lua
--
-- The PP-shop catalog. Each item:
--   • is bought ONCE with Poker Points (PP, the meta currency)
--   • applies one or more effects via the EffectsRegistry
--   • persists across prestiges forever
--
-- Items are unique — no buying seventeen Teddy Bears. Stacking-style
-- progression lives in data/run_upgrades.lua, where the same item can be
-- bought up to its max_level for compounding effect. Catalog items are
-- meta-progression *perks* — start with more money, read opponents
-- faster, cheaper buy-ins, free starter tables, harder pros punished
-- less. A few flat % nudges are mixed in (Calculator / Pot Odds Master
-- / Damage Control), but the slate is dominated by qualitatively
-- different effects so each new perk feels like it changes the game.
--
-- Item schema:
--   {
--     id          = "snake_case_unique",       -- referenced by GameState.owned_items
--     name        = "Display Name",
--     description = "Short blurb shown under name in catalog UI",
--     sprite      = "sprite_name",              -- looked up via SpriteLoader (room viz, deferred)
--     cost_pp     = number,
--     position    = { x = px, y = px },         -- room placement (deferred)
--     effects     = { { kind = "...", value = ... }, ... }  -- see data/effects.lua
--   }
--
-- Curve intent:
--   1-5 PP   — quick first-run buys; small but tangible boosts so the
--              meta-progression has a *foothold* on a fresh player's
--              first prestige cycle. Without these the cheapest item is
--              8 PP and a brand-new player gets nothing for runs 1-2.
--   6-15 PP  — the main mid-tier perks (start-bankroll, reveal-on-sit,
--              earnings/loss buffs, buy-in discount, shove rate).
--   20+ PP  — the run-changers: -20% run-upgrade costs, double PP
--              bounties, soft pros, halved HU penalty.

return {

    -- ── Cheap-tier (1-5 PP) ───────────────────────────────────────────────

    {
        id          = "coaster",
        name        = "Coaster",
        description = "Start each run with $1 extra.",
        sprite      = "coaster",
        cost_pp     = 2,
        position    = { x = 80,  y = 200 },
        effects     = { { kind = "start_bankroll_add", value = 1 } },
    },
    {
        id          = "sticky_note",
        name        = "Sticky Note",
        description = "Read opponents faster.",
        sprite      = "sticky_note",
        cost_pp     = 3,
        position    = { x = 130, y = 200 },
        effects     = { { kind = "reveal_chance_add", value = 0.10 } },
    },
    {
        id          = "calculator",
        name        = "Calculator",
        description = "Sharper reads, every hand.",
        sprite      = "calculator",
        cost_pp     = 4,
        position    = { x = 180, y = 200 },
        effects     = { { kind = "win_chance_shift", amount = 0.02 } },
    },
    {
        id          = "pen",
        name        = "Pen",
        description = "More PP from bounties.",
        sprite      = "pen",
        cost_pp     = 4,
        position    = { x = 230, y = 200 },
        effects     = { { kind = "pp_award_mult", value = 1.25 } },
    },
    {
        id          = "headphones",
        name        = "Headphones",
        description = "Soften your losses.",
        sprite      = "headphones",
        cost_pp     = 5,
        position    = { x = 280, y = 200 },
        effects     = { { kind = "loss_mult", value = 0.95 } },
    },
    {
        id          = "free_sit",
        name        = "Free Sit",
        description = "Start each run with a table seated.",
        sprite      = "free_sit",
        cost_pp     = 5,
        position    = { x = 330, y = 200 },
        effects     = { { kind = "start_table_count", value = 1 } },
    },

    -- ── Mid-tier (6-15 PP) ────────────────────────────────────────────────

    {
        id          = "pocket_cash",
        name        = "Pocket Cash",
        description = "Start each run with $5 extra.",
        sprite      = "pocket_cash",
        cost_pp     = 8,
        position    = { x = 100, y = 300 },
        effects     = { { kind = "start_bankroll_add", value = 5 } },
    },
    {
        id          = "eagle_eyes",
        name        = "Eagle Eyes",
        description = "Read opponents much faster.",
        sprite      = "eagle_eyes",
        cost_pp     = 10,
        position    = { x = 200, y = 300 },
        effects     = { { kind = "reveal_chance_add", value = 0.25 } },
    },
    {
        id          = "cold_read",
        name        = "Cold Read",
        description = "Spot one trait on every fresh opponent.",
        sprite      = "cold_read",
        cost_pp     = 12,
        position    = { x = 300, y = 300 },
        effects     = { { kind = "revealed_at_start_count", value = 1 } },
    },
    {
        id          = "pot_odds_master",
        name        = "Pot Odds Master",
        description = "Wins pay bigger.",
        sprite      = "pot_odds_master",
        cost_pp     = 12,
        position    = { x = 400, y = 300 },
        effects     = { { kind = "earnings_mult", value = 1.10 } },
    },
    {
        id          = "damage_control",
        name        = "Damage Control",
        description = "Losses cost less.",
        sprite      = "damage_control",
        cost_pp     = 12,
        position    = { x = 500, y = 300 },
        effects     = { { kind = "loss_mult", value = 0.90 } },
    },
    {
        id          = "discount_sits",
        name        = "Discount Sits",
        description = "Cheaper buy-ins.",
        sprite      = "discount_sits",
        cost_pp     = 14,
        position    = { x = 600, y = 300 },
        effects     = { { kind = "buy_in_mult", value = 0.85 } },
    },
    {
        id          = "lucky_charm",
        name        = "Lucky Charm",
        description = "Better shove odds.",
        sprite      = "lucky_charm",
        cost_pp     = 15,
        position    = { x = 700, y = 300 },
        effects     = { { kind = "shove_rate_add", value = 0.05 } },
    },

    -- ── Expensive-tier (20+ PP) ───────────────────────────────────────────

    {
        id          = "cheap_coaching",
        name        = "Cheap Coaching",
        description = "Cheaper run upgrades.",
        sprite      = "cheap_coaching",
        cost_pp     = 22,
        position    = { x = 100, y = 400 },
        effects     = { { kind = "run_upgrade_cost_mult", value = 0.80 } },
    },
    {
        id          = "endorsement_deal",
        name        = "Endorsement Deal",
        description = "Big PP boost from bounties.",
        sprite      = "endorsement_deal",
        cost_pp     = 25,
        position    = { x = 250, y = 400 },
        effects     = { { kind = "pp_award_mult", value = 2.0 } },
    },
    {
        id          = "calm_hands",
        name        = "Calm Hands",
        description = "Pros are less brutal.",
        sprite      = "calm_hands",
        cost_pp     = 30,
        position    = { x = 400, y = 400 },
        effects     = { { kind = "win_chance_shift", amount = 0.10, skill = "pro" } },
    },
    {
        id          = "hu_specialist",
        name        = "HU Specialist",
        description = "Heads-up plays smoother.",
        sprite      = "hu_specialist",
        cost_pp     = 30,
        position    = { x = 550, y = 400 },
        effects     = { { kind = "win_chance_shift", amount = 0.06, gtype = "hu" } },
    },

    -- ── Cursor swarm (idle layer) ───────────────────────────────────────
    -- The unlock and the first cursor are intentionally separate buys —
    -- owning the system without an assistant in it is fine; the player
    -- decides whether to spend the second PP block on a cursor or other
    -- mid-tier perks.
    {
        id          = "cursor_pool",
        name        = "Cursor Pool",
        description = "Hire assistants to click for you.",
        sprite      = "cursor_pool",
        cost_pp     = 20,
        position    = { x = 100, y = 500 },
        effects     = { { kind = "cursor_unlocked" } },
    },
    {
        id          = "first_cursor",
        name        = "Trained Cursor",
        description = "Your first assistant pointer.",
        sprite      = "first_cursor",
        cost_pp     = 15,
        position    = { x = 200, y = 500 },
        effects     = { { kind = "cursor_count_add", value = 1 } },
    },

}
