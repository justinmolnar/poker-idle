-- data/cinematic_timelines.lua
--
-- Per-(gtype, tier) cinematic shape. Each timeline is an ordered list of
-- { state_name, duration_seconds } entries. The Table state machine in
-- models/Table.lua walks the list by index, advancing when its
-- pace_mult-scaled timer crosses each duration. Phases not present in a
-- timeline are simply skipped — e.g. a "dealing → settling" timeline
-- never visits flop/turn/river/showdown.
--
-- The state names are load-bearing: views/TablePanel.lua keys community-
-- card visibility on the state name (`"flop"` → 3 cards, etc.), and the
-- resolution dict gets pushed when entering `"settling"`. Don't rename
-- without auditing TablePanel.communityCardCount + Table:update.
--
-- Pure data — no logic.

return {

    -- Default 6-max baseline. Sums to 2.20s — same total as the old
    -- PHASE_*_END constants. pace_mult applies on top of these durations
    -- (6-max's 0.5 pace stretches the cinematic to 4.4s/hand).
    default = {
        { "dealing",  0.40 },
        { "flop",     0.40 },
        { "turn",     0.30 },
        { "river",    0.30 },
        { "showdown", 0.40 },
        { "settling", 0.40 },
    },

    -- Per-gtype / per-(gtype, tier) overrides. Lookup precedence:
    --   1. overrides[gtype_id .. ":" .. tier]   (most specific)
    --   2. overrides[gtype_id]
    --   3. default
    overrides = {

        -- Zoom + tiny outcome: the bulk of Zoom hands. Compresses to
        -- ~0.8s total — deal animation, then snap to settle. No flop
        -- reveal beat. Combined with Zoom's 1.4 pace_mult, this lands at
        -- ~0.57s per hand for the common case.
        ["zoom:tiny"] = {
            { "dealing",  0.40 },
            { "settling", 0.40 },
        },

        -- HU: the duel framing. Showdown phase doubled (0.40 → 0.80) so
        -- the player can clearly read both hands when they meet at the
        -- river. Total 2.60s pre-pace_mult; HU's pace_mult=1.0 keeps it
        -- close to that on screen.
        hu = {
            { "dealing",  0.40 },
            { "flop",     0.40 },
            { "turn",     0.30 },
            { "river",    0.30 },
            { "showdown", 0.80 },
            { "settling", 0.40 },
        },

    },

}
