-- data/rail.lua
--
-- The words on the rail (views/GrindView `_buildRailComponents`): the
-- chrome along the bottom of the grind and the room. Labels, the line a
-- locked button gives on hover (present from the first frame, dim until
-- earned, the way the locked stake rows are), and the tooltips. Copy
-- follows docs/the-house-voice.md: {chip} for the coin, never the word.
-- Tables only.

return {
    labels = {
        cash_out = "CASH OUT",
        tied_up  = "TIED UP",
        focus    = "FOCUS",
        over_focus = "OVER FOCUS",  -- the same cell, once the board is past the cap
        tables   = "TABLES",        -- after the focus bar: "1 / 4 TABLES"
        -- Live counters an owned item reads, shown only while it is owned:
        hands_s  = "HANDS/S",       -- the board's hands a second (Hybrid Console)
        heaters  = "HEATERS",       -- heaters burning now (Desk Speakers)
        next     = "NEXT",          -- after the anti-chip count: "+3 NEXT"
        shove    = "SHOVE",
        deck     = "DECK",          -- the deck button, open with no deck in play yet
        quick_reset = "Quick reset",
        play     = "PLAY",          -- the room button, on the room screen
        rate_unit = "/min",         -- after the earn rate: "+$1.20/min"
    },

    -- A locked button is blank and says nothing (the locked game-type
    -- keys' rule: nothing is spoiled). CASH OUT is the one exception: it
    -- is not locked, there is just nothing to cash out.
    locked = {
        cash_out = "Nothing on the tables.",
    },

    tooltips = {
        catalog  = "The catalog. Everything you can buy for your room.",
        cash_out = "Every table's stack back to your bankroll.",
        bankroll = "Your bankroll: the money you play with.",
        banked   = "Yours to keep. Spend them in the catalog, after a shove.",
        -- FOCUS: the first line, then the numbers the builder formats.
        focus    = "FOCUS is how many tables you can keep up with.",
        focus_ok = "Stays 100%% at or under %d tables.",
        focus_pen = "Each table over drops it %.0f%% (floor %.0f%%).",
        focus_cap = "Hard cap: %d tables.",
        -- SHOVE, unlocked: the lede, the run's take, then the rate breakdown.
        shove_lede = "One all-in hand at this rate. Win or lose, the catalog opens after and a new run starts.",
        shove_take = "+%d {chip} this run.",
        shove_lock = "Click to lock this rate.",
        quick_reset = { "Starts over at $2. No Shove." },
        deck_click  = "Click to see your decks",
        -- The earn rate over the bankroll: the lede, one line per table
        -- (the builder formats the numbers), the run's actual, the graph.
        rate_lede  = "What your tables should earn a minute, at the pace you're dealing them.",
        -- the table (its game pill and stake), its hands, its rate
        rate_table = "%s  %s a hand × %d a minute = %s/min",
        rate_focus = "FOCUS ×%.2f speed on all of it.",
        rate_run   = "This run: %s in %s, %s/min.",
        rate_last  = "Last run: %s/min.",
        rate_idle  = "Nothing dealt lately. Deal something.",
        rate_graph = "$/min over this run (%s)",
        rate_start = "start",
        rate_now   = "now",
    },

    -- The widest value each readout must hold: its slot is sized to this
    -- once, so the row never moves as the numbers change.
    reserve = {
        bankroll = "$999.99K",
        tied_up  = "$999.99",
        focus    = "100%",
        tables   = "99 / 99",
        hands_s  = "99.9",
        heaters  = "99",
        chips    = "999",
        next     = "+99",
        rate     = "999%",
        rate_min = "+$999.99/min",
    },

    -- The game-type keys' blurbs (the strip above the ADD TABLE rows).
    gtype = {
        six_max  = "6-Max. The long game: five opponents, slow hands, the fattest pots in the room.",
        hu       = "Heads-Up. One opponent, whole stacks, both ways. You win less often and it goes deeper.",
        zoom     = "Zoom. A new table every hand. More wins, smaller ones, and it never holds you up.",
        ko       = "A tournament. Eight seats, ten blinds each, no rebuy, and it deals itself. Top three cash.",
    },
}
