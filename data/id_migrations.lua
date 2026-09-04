-- data/id_migrations.lua
--
-- Identifiers renamed after saves went public, by NAMESPACE. Sibling of
-- data/catalog_id_migrations.lua (which covers catalog item ids only).
-- GameState:applySaved walks every serialized place each kind of id can
-- sit and rewrites old → new, so an existing player keeps their tables,
-- bounties, decks, upgrade levels and counters across a rename.
--
-- Add a line per rename; never remove one. A map entry is only applied
-- when the OLD id is no longer live in its data file, so an id that is
-- retired and later reused is safe.
--
-- Namespaces and where each is applied:
--   gtype        game-type ids (data/game_types.lua): active_table_specs
--                ("<stake>:<gtype>"), stakes_won_this_run /
--                anti_stakes_won_this_run keys (same shape),
--                total_hands_by_gtype keys, gtype_announced keys
--   run_upgrade  run-upgrade ids (data/run_upgrades.lua): run_upgrade_levels keys
--   deck         deck ids (data/decks.lua): unlocked_decks values,
--                deck_levels / deck_xp keys, active_deck_id
--   tier         outcome-tier keys (OutcomeMath.TIER_KEYS): `tier` strings
--                inside saved tournament plans and pending shove outcomes
--   field        serialized GameState field names (meta or run): old key's
--                value is moved to the new key, then the old key is dropped
--
-- Pure data — no logic.

return {
    gtype       = {
        mtt = "ko",                                     -- 2026-09: the tournament mode is the KO
    },
    run_upgrade = {
        box_of_mice = "cursor",                         -- 2026-09: the upgrade is the Cursor; box_of_mice stays the catalog item
    },
    deck        = {
        cursor = "swarm",                               -- 2026-09: the deck is the Swarm
    },
    tier        = {
        jackpot = "stack",                              -- 2026-09: the win tier is the Stack
    },
    field       = {
        total_jackpots               = "total_stacks",               -- 2026-09
        lifetime_jackpot_count       = "lifetime_stack_count",       -- 2026-09
        total_mtt_wins               = "total_ko_wins",              -- 2026-09
        lifetime_mtt_hands_won       = "lifetime_ko_hands_won",      -- 2026-09
        active_table_mtt_hands_won   = "active_table_ko_hands_won",  -- 2026-09
        active_table_mtt_finishes    = "active_table_ko_finishes",   -- 2026-09
        active_table_mtt_state       = "active_table_ko_state",      -- 2026-09
        active_table_mtt_plans       = "active_table_ko_plans",      -- 2026-09
    },
}
