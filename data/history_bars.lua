-- data/history_bars.lua
--
-- Per-tier visual height for the history-bar mini-graph rendered in each
-- table-panel header. Each bar's height is `height_frac × graph_zone_height`,
-- letting jackpots tower over tinies at a glance.
--
-- Single source of truth — adding a new tier or rebalancing the visual
-- weight is a one-data-file edit. Views read this table by tier name; no
-- `if tier == "jackpot"` branches.

return {
    -- Visual layout knobs. Live here (not view-side constants) so the bar
    -- look-and-feel is tunable from data without touching code.
    layout = {
        max_bars        = 10,    -- target slot count if there's room
        bar_w           = 3,     -- pixels per bar
        bar_gap         = 2,     -- pixels between bars
        min_bar_w       = 2,     -- shrink to this when crowded
        min_bar_gap     = 1,     -- shrink gap to this when crowded
        graph_h         = 14,    -- vertical pixels reserved for bars
        baseline_alpha  = 0.18,  -- background-track tint behind unfilled slots
    },

    -- Tier → height fraction (0..1 of graph_h). Tinies stay short so the
    -- common case is a quiet baseline; jackpots punch up to full height.
    height = {
        small    = 0.30,
        medium   = 0.55,
        large  = 0.80,
        jackpot = 1.00,
    },
}
