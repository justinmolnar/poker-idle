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
        tables   = "TABLES",        -- after the focus bar: "1 / 4 TABLES"
        next     = "NEXT",          -- after the count: "+3 NEXT"
        shove    = "SHOVE",
        deck     = "DECK",          -- the deck button, open with no deck in play yet
        quick_reset = "Quick reset",
        play     = "PLAY",          -- the room button, on the room screen
    },

    -- A locked button is blank and says nothing (the locked game-type
    -- keys' rule: nothing is spoiled). CASH OUT is the one exception: it
    -- is not locked, there is just nothing to cash out.
    locked = {
        cash_out = "Nothing on the tables.",
    },

    tooltips = {
        settings = "Settings.",
        catalog  = "The catalog. Everything you can buy for your room.",
        room     = "Your room.",
        cash_out = "Cash out every table: each one's stack comes back to your bankroll.",
        tied_up  = "Money sitting at your tables. CASH OUT brings it back.",
        bankroll = "Your bankroll: the money you play with.",
        banked   = "Yours. Spend them in the catalog.",
        next     = "{c:chip:Banked} when you shove.",
        -- FOCUS: the first line, then the numbers the builder formats.
        focus    = "FOCUS multiplies every dollar you win or lose.",
        focus_ok = "Stays 100%% at or under %d tables.",
        focus_pen = "Each table over drops it %.0f%% (floor %.0f%%).",
        focus_cap = "Hard cap: %d tables.",
        -- SHOVE, unlocked: the lede, the run's take, then the rate breakdown.
        shove_lede = "Bet everything on one all-in hand at the rate below. Winning beats the prototype (you can keep playing after). Either way you bank this run's {chip} to spend in the catalog on permanent {c:upgrade:upgrades}, then a new run starts.",
        shove_take = "Banks +%d {chip} for the catalog.",
        shove_lock = "Click to lock this rate.",
        quick_reset = { "Banks your {chip} and starts a fresh $2 stake.",
                        "No Shove, for when you're broke and stuck." },
        deck_click  = "Click to see your decks",
    },

    -- The widest value each readout must hold: its slot is sized to this
    -- once, so the row never moves as the numbers change.
    reserve = {
        bankroll = "$999.99K",
        tied_up  = "$999.99",
        focus    = "100%",
        tables   = "99 / 99",
        chips    = "999",
        next     = "+99",
        rate     = "999%",
    },

    -- The game-type keys' blurbs (the strip above the ADD TABLE rows).
    gtype = {
        six_max  = "6-Max. The long game: five opponents, slow hands, the fattest pots in the room.",
        hu       = "Heads-Up. One opponent, whole stacks, both ways. You win less often and it goes deeper.",
        zoom     = "Zoom. A new table every hand. More wins, smaller ones, and it never holds you up.",
        ko       = "A tournament. Eight seats, ten blinds each, no rebuy, and it deals itself. Top three cash.",
    },
}
