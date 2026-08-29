-- data/story.lua
--
-- Every line the House says. Pure data; the copy is reviewed in
-- docs/house-script.md and transcribed here. Two parts:
--
--   beats  ORDERED list. controllers/StoryDirector ARMS every beat the
--          moment its trigger passes (wherever the player is, whatever
--          else is happening) and plays armed beats one at a time, first
--          in this list first, on the beat's own screen. A beat plays for
--          every save the first time its trigger passes, however far
--          along that save is, and never again (story_seen). There are no
--          skip conditions.
--   shove  Keyed lines scheduled by views/ShoveView's own timeline during
--          the shove. Same voice, same file, so everything he says is in
--          one place.
--
-- Beat:  id, screen (the screen whose box it draws in; it pauses on any
--        other), trigger (a condition, kinds in models/hint_rules.lua),
--        lines.
-- Line:  a BLOCK of text: as many sentences as one click's worth of
--        reading, wrapped in the box. Fields: text ({chip} markers
--        render), anchor (name or list; gets the pulsing mark), and ONE of:
--          hold = "click"   waits for a click on the box or SPACE (default)
--          hold = <secs>    advances itself
--          wait = cond      after it is said, blocks until cond passes
--        plus optionally:
--          force = true     with `wait`: the screen dims to the line's
--                           targets and clicks anywhere else are swallowed
--                           until the wait passes. The action IS the
--                           advance. Only force what is certainly doable:
--                           free (a hover, a click), or guarded by a
--                           `show` that re-checks affordability.
--          show = cond      the block is not said until cond passes
--          delay = <secs>   pause before it is said
--          font = "sm"      smaller than the default md
--
-- BEAT DESIGN RULES. A beat is a MOMENT, and it teaches everything that
-- moment shows: the first chip teaches the chip, the readout that
-- predicted it, and the zoom-vs-duel gap, because they are all on screen
-- at once. Never split one moment across beats. Never narrate what the
-- player has no alternative to (the only open tab needs no sales pitch).
-- Prefer making the player DO the thing (force) over telling them about
-- it.
--
-- Copy rules: no em-dashes, {chip} never the word, cut filler. Reveal
-- rule: nothing that can play before a runout win names a runout, a
-- cheat, a card count, or the second hand.

local Constants = require("data.constants")

return {
    beats = {
        -- A1. Arrival: the premise, then the player does everything once.
        -- Open the table (forced; it costs exactly the starting two
        -- dollars), learn where the money went (tied up), deal (forced).
        {
            id      = "arrival",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "hands_played", max = 0 },
                        { kind = "tables_open",  max = 0 } },
            lines = {
                { text = "Welcome in. Have a seat. You play, I run the room. Easy." },
                { text = "Two dollars to start. It's yours. Win one big hand and you walk out of here.",
                  anchor = "cell:bankroll" },
                { text = "Open a table.",
                  anchor = "add_table:s001:zoom",
                  force  = true,
                  wait   = { kind = "tables_open", min = 1 } },
                { text = "There go your two dollars, onto the felt. Money on a table is tied up, not gone. Close the table, or CASH OUT, and it comes back.",
                  anchor = { "cell:tied", "btn:cash_out" } },
                { text = "Click anywhere on the felt to deal a hand.",
                  anchor = "felt",
                  force  = true,
                  wait   = { kind = "hands_played", min = 1 } },
            },
        },

        -- A2. The first spill: the other half of the tied-up lesson. Wins
        -- refill the table's stack up to the buy-in; only the surplus
        -- reaches the bankroll — and the trigger IS that first surplus
        -- (bankroll moves off zero), so he speaks as it happens.
        {
            id      = "first_payout",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "hands_played", min = 1 },
                        { kind = "bankroll",     min = 0.001 } },
            lines = {
                { text = "See that? A table only holds its buy-in. Win past full and the rest spills straight into your pocket.",
                  anchor = "cell:bankroll" },
            },
        },

        -- A3. The upgrade rack, the first time a buy is affordable without
        -- bricking the run (the shop's own strand check). Forced: buying
        -- one teaches the rack better than a paragraph about it.
        {
            id      = "sharper_reads",
            screen  = "grind",
            trigger = { kind = "can_afford_run_upgrade", id = "sharper_reads", safe = true },
            lines = {
                { text = "The rack on the right makes you better at every table. You can afford Sharper Reads. Grab it.",
                  anchor = "buy_runup_sharper_reads",
                  show   = { kind = "can_afford_run_upgrade", id = "sharper_reads", safe = true },
                  force  = true,
                  wait   = { kind = "run_upgrades_owned", min = 1 } },
            },
        },

        -- A4. The duel opens (GrindController latches hu_unlocked the
        -- moment a second buy-in is in hand) and the player walks through
        -- the door themselves: swap to the tab, buy the seat. This is the
        -- {chip} economy's front door — naked Heads-Up wins whole stacks
        -- often enough that the first bounty lands minutes after sitting.
        {
            id      = "second_table",
            screen  = "grind",
            trigger = { kind = "hu_unlocked" },
            lines = {
                { text = "You can afford another seat, and the duel just opened. Heads-Up. One opponent, whole stacks, both ways. It's where I pay. It's also where you get taken.",
                  anchor = "gtype:hu" },
                { text = "Sit down.",
                  anchor = { "gtype:hu", "add_table:s001:hu" },
                  show   = { kind = "can_afford_stake", stake = "s001" },
                  force  = true,
                  wait   = { kind = "gtype_table_open", gtype = "hu" } },
            },
        },

        -- A5. The first {chip}: one beat, the whole lesson, because the
        -- whole lesson is on screen at once. What banked, the readout
        -- that predicted it (forced hover: the tooltip is the teacher),
        -- the zoom-vs-duel gap in two numbers, the desk, the door.
        {
            id      = "first_chip",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = 1 },
            lines = {
                { text = "Oh, nice. That's a {chip}. Take a whole stack off a table and it pays one. Once per table per run, so spread out.",
                  anchor = "chip_badge:banked" },
                { text = "You could've seen it coming. Hover the readout under a table. Go on.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" },
                  force  = true,
                  wait   = { kind = "hovering", anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } } },
                { text = "Everything a table does per hour, and its odds at all four pot sizes. The gold {w:stack} is the one that pays: its shot at a whole stack.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
                { text = "Now compare your rooms. Zoom sits under a percent. The duel runs a third. Different tables, different jobs.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
                { text = "Anything I teach you gets written down. The desk under my poster keeps the glossary.",
                  anchor = "btn:help" },
                { text = "Get three of those and we'll talk about the door.",
                  anchor = "chip_badge:shove" },
            },
        },

        -- A6. The pitch. Deliberately NOT forced: the shove is the one
        -- thing here that should feel like the player's own call.
        {
            id      = "the_pitch",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS },
            lines = {
                { text = "Three! Look at you. So here's how you get out of here.", anchor = "chip_badge:shove" },
                { text = "One hand, everything you've got on it. Win, and you walk out with the lot. Lose, and you keep the {chip}. No harm done.",
                  anchor = "btn:shove" },
                { text = "Whenever you're ready. No rush.", anchor = "btn:shove" },
            },
        },

        -- A7. The shove, narrated as it happens: the pile at buildup, the
        -- readout once the hand is running.
        {
            id      = "shove_walkthrough",
            screen  = "shove",
            trigger = { kind = "shove_phase", phase = "buildup" },
            lines = {
                { text = "Everything you've got, in one pile. Here we go.",
                  anchor = "shove:pot" },
                { text = "ITEMS is how many things you own. BANK is your money. The bar under them is your number. Keep an eye on it.",
                  anchor = "shove:readout",
                  show = { kind = "shove_phase", phase = "running" } },
            },
        },
        {
            id      = "shove_result",
            screen  = "shove",
            trigger = { kind = "shove_beat", id = "result" },
            lines = {
                { text = "BANKED is yours to keep. The all-in was everything else.",
                  anchor = "shove:summary" },
            },
        },
        -- Gated on the card being ON the felt, never a flag: nothing may
        -- name a cheat before the player has seen one.
        {
            id      = "house_cheats",
            screen  = "shove",
            trigger = { kind = "cheat_dealt", min = 1 },
            lines = {
                { text = "That card landed on your ITEMS and took them out of the count. The bar shows what's left. House rules. Plan around it.",
                  anchor = "shove:cheat_6" },
            },
        },

        -- A8. The catalog, the first time it is open on the felt.
        {
            id      = "first_catalog",
            screen  = "shove",
            trigger = { kind = "catalog_open" },
            lines = {
                { text = "Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, it's yours.",
                  anchor = "catalog:book" },
                { text = "That stamp's the price. Stickered ones aren't ready yet. The count says how close.",
                  anchor = { "catalog:price:first", "catalog:sticker:first" } },
                { text = "Close it when you're done and we'll set you back up.", anchor = "catalog:continue" },
            },
        },

        -- A9. Back on the grind after the first shove. "Run" is said for
        -- the first time here, when it is true.
        {
            id      = "the_loop",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "has_shoved" },
                        { kind = "tables_open", min = 1 } },
            lines = {
                { text = "And we're back to two dollars. That's a run. Sharper Reads went with it. Those reset. The catalog doesn't.",
                  anchor = { "cell:bankroll", "buy_runup_sharper_reads" } },
                { text = "Your odds on the big hand: what you own, times what you hold. So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time.",
                  anchor = { "cell:shove", "chip_badge:shove" } },
                { text = "One more thing. The catalog's got the key to the 6-Max room now. The long game. Slow, deep, worth it.",
                  anchor = "gtype:six_max" },
            },
        },

        -- The rooms and tools that open later, each introduced the first
        -- time it exists on the felt.
        {
            id      = "six_max_open",
            screen  = "grind",
            trigger = { kind = "gtype_table_open", gtype = "six_max" },
            lines = {
                { text = "The long game. Slow hands, five stacks on the table, and the fattest pots in the room when one finally lands.",
                  anchor = "gtype:six_max" },
            },
        },
        {
            id      = "first_tournament",
            screen  = "grind",
            trigger = { kind = "gtype_table_open", gtype = "mtt" },
            lines = {
                { text = "A tournament. One buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}.",
                  anchor = "gtype:mtt" },
            },
        },
        {
            id      = "first_cursors",
            screen  = "grind",
            trigger = { kind = "owns_item", id = "box_of_mice" },
            lines = {
                { text = "The cursors deal for you now. More of them, and faster, in the sidebar. The D on a table stops them dealing there.",
                  anchor = { "buy_runup_box_of_mice", "buy_runup_cursor_speed" } },
            },
        },

        -- Reactive lessons: each fires the first time its situation
        -- actually exists. Order here is priority when several arm at
        -- once, nothing more.
        {
            id      = "stake_ladder",
            screen  = "grind",
            trigger = { kind = "can_afford_stake", stake = "s002" },
            lines = {
                { text = "NL10's open. Ten times the money, but the players are better. Worth an upgrade or two first.",
                  anchor = "add_table:s002:zoom" },
            },
        },
        {
            id      = "first_bust",
            screen  = "grind",
            trigger = { kind = "any_table_busted" },
            lines = {
                { text = "Empty, not gone. REBUY puts a fresh stack on it.",
                  anchor = "rebuy:any" },
            },
        },
        {
            id      = "chip_denied",
            screen  = "grind",
            trigger = { kind = "total_denied_stacks", min = 1 },
            lines = {
                { text = "That table's already paid its {chip}. Each stake and game pays once per run. Climb, or come back next run.",
                  anchor = "chip_badge:banked" },
            },
        },
        {
            id      = "focus_overload",
            screen  = "grind",
            trigger = { kind = "focus_overloaded" },
            lines = {
                { text = "That's a lot of tables. You're playing all of them a bit worse. Close one, or grab Focus.",
                  anchor = { "cell:focus", "buy_runup_focus" } },
            },
        },
        {
            id      = "the_room",
            screen  = "room",
            trigger = { kind = "screen", name = "room" },
            lines = {
                { text = "Everything you buy ends up in here. PLAY takes you back to the tables.",
                  anchor = "room:play" },
            },
        },
        {
            id      = "first_corruption",
            screen  = "shove",
            trigger = { kind = "all",
                        { kind = "catalog_open" },
                        { kind = "anti_chips", min = 1 } },
            lines = {
                { text = "Things you own can be corrupted for {achip}. Corrupted ones do far worse things.",
                  anchor = "catalog:corrupt:first" },
            },
        },

        -- Act 2, on the grind after the first R1 win.
        {
            id      = "act2",
            screen  = "grind",
            trigger = { kind = "act2_unlocked" },
            lines = {
                { text = "You actually won that. Good for you. The next hand doesn't count your catalog. Just your deck.",
                  anchor = "cell:deck" },
                { text = "It levels up as it plays, and its bonus is on every hand. Max out five and something new joins the rack.",
                  anchor = "cell:deck" },
                -- Anchored on a zoom row: 6-max may still be behind its
                -- catalog key here, but zoom is always open and s004
                -- opens with this very beat.
                { text = "The big tables are open now. Bring money.", anchor = "add_table:s004:zoom" },
                { text = "And the tournament room. Eight seats, one winner. It pays the tables around it more than it pays you.",
                  anchor = "gtype:mtt" },
            },
        },

        -- Act 2, in the deck-select modal. A separate beat: the modal
        -- opens on the shove screen, before act2 can play on the grind.
        {
            id      = "act2_decks",
            screen  = "shove",
            trigger = { kind = "deck_select_open" },
            lines = {
                { text = "Pick one. It plays the next run. The locked ones tell you what opens them.",
                  anchor = "deck:tile:1" },
                { text = "The bar on each fills as the deck plays. Full bar, next level, better bonus.",
                  anchor = "deck:xp" },
            },
        },

        -- Act 3.
        {
            id      = "act3",
            screen  = "grind",
            trigger = { kind = "act3_unlocked" },
            lines = {
                { text = "Twice. Honestly, that's a first. Bad news: the last card covers your multiplier, so the final hand is a zero however rich you are.",
                  anchor = "cell:shove" },
                { text = "Good news: lose a whole stack anywhere and I'll pay you for it. The cheaper the table, the more. Spend those in the catalog on things you already own.",
                  anchor = { "cell:achips", "btn:catalog" } },
                { text = "And your money sits in a box with a bottom. Lose a whole stack at the top table and it falls out.", anchor = "cell:bankroll" },
            },
        },

        -- The underflow. The count is broken; he says so.
        {
            id      = "underflow",
            screen  = "grind",
            trigger = { kind = "bankroll", max = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD - 1 },
            lines = {
                { text = "That's... not a number.", anchor = "cell:bankroll" },
                { text = "I don't have a card that covers that. Go on. Shove.", anchor = "btn:shove" },
            },
        },

        -- He gets the last word.
        {
            id      = "credits",
            screen  = "credits",
            trigger = { kind = "screen", name = "credits" },
            lines = {
                { text = "See you tomorrow.", delay = 1.5 },
            },
        },
    },

    shove = {
        pushing        = { text = "Pushing all in." },
        arrive         = { text = "All of it. Here we go." },
        loss           = { text = "Ah. House wins that one. Next time." },
        -- The panic. Only reachable after a runout win; the one place the
        -- host's mask slips.
        panic_wait     = { text = "Wait." },
        panic_won      = { text = "You... won? Already?" },
        panic_no       = { text = "No." },
        panic_new_card = { text = "New card. Try again later." },
        panic_again    = { text = "Twice. Nobody does this twice." },
        panic_no_more  = { text = "You get nothing. Ever." },
        clear          = { text = "There is nothing left to take from you.", once = true },
        -- The ending. He does not see the count is broken. Another card has
        -- always worked. Not once-lines: a second clear replays it.
        deck_no        = { text = "No." },
        deck_again     = { text = "Again." },
        deck_doesnt    = { text = "That one doesn't count." },
        deck_deal      = { text = "Deal." },
        deck_all       = { text = "All of it, then." },
        deck_out       = { text = "There's nothing left to deal." },

        -- The room, before the felt: counting what you own.
        room_count     = { text = "Let's see what you've got." },
        room_done      = { text = "That's your room." },
        room_empty     = { text = "Nothing yet. That's fine." },
    },
}
