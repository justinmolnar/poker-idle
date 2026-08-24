-- data/story.lua
--
-- Every line the House says. Pure data; the copy is reviewed in
-- docs/house-script.md and transcribed here. Two parts:
--
--   beats  ORDERED list. controllers/StoryDirector takes the first unseen
--          beat whose trigger passes and plays its blocks in sequence in
--          the screen's story box (views/StoryView). One at a time. A
--          beat plays for every save the first time its trigger passes,
--          however far along that save is, and never again (story_seen).
--          There are no skip conditions.
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
--          show = cond      the block is not said until cond passes
--          delay = <secs>   pause before it is said
--          font = "sm"      smaller than the default md
--
-- Copy rules: no em-dashes, {chip} never the word, cut filler. Reveal
-- rule: nothing that can play before a runout win names a runout, a
-- cheat, a card count, or the second hand.

local Constants = require("data.constants")

return {
    beats = {
        -- S1. The premise, in the first thirty seconds.
        {
            id      = "arrival",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "screen",       name = "grind" },
                        { kind = "hands_played", max = 0 },
                        { kind = "tables_open",  max = 0 } },
            lines = {
                { text = "Welcome in. Have a seat. You play, I run the room. Easy." },
                { text = "Two dollars to start. It's yours. Win one big hand and you walk out of here.",
                  anchor = "cell:bankroll" },
                { text = "Go on, open a table.", anchor = "add_table:s001:six_max",
                  wait = { kind = "tables_open", min = 1 } },
            },
        },

        -- S2. Hover, the run upgrades, and the nudge that waits until it
        -- is affordable. Never says "reset": there has been no run yet.
        {
            id      = "look_around",
            screen  = "grind",
            trigger = { kind = "hands_played", min = 2 },
            lines = {
                { text = "Everything here explains itself. Hover anything. The upgrades on the right make you better at the tables.",
                  anchor = { "ev:1", "buy_runup_sharper_reads" } },
                { text = "You can afford Sharper Reads now. I'd grab it.",
                  anchor = "buy_runup_sharper_reads",
                  show = { kind = "can_afford_run_upgrade", id = "sharper_reads" },
                  wait = { kind = "run_upgrades_owned", min = 1 } },
            },
        },

        -- S3.
        {
            id      = "second_table",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "tables_open",      min = 1, max = 1 },
                        { kind = "can_afford_stake", stake = "s001" } },
            lines = {
                { text = "One table's a bit slow. Open another.", anchor = "add_table:s001:six_max",
                  wait = { kind = "tables_open", min = 2 } },
            },
        },

        -- S4.
        {
            id      = "first_chip",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = 1 },
            lines = {
                { text = "Oh, nice. That's a {chip}. Take a whole stack and a table pays one. One per table, so spread out.",
                  anchor = "chip_badge:banked" },
                { text = "Get three and we'll talk about the door.", anchor = "chip_badge:shove" },
            },
        },

        -- S5. The pitch.
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

        -- S7. The catalog, the first time it is open on the felt.
        {
            id      = "first_catalog",
            screen  = "shove",
            trigger = { kind = "all",
                        { kind = "screen", name = "shove" },
                        { kind = "catalog_open" } },
            lines = {
                { text = "Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, it's yours.",
                  anchor = "catalog:book" },
                { text = "That stamp's the price. Stickered ones aren't ready yet. The count says how close.",
                  anchor = { "catalog:price:first", "catalog:sticker:first" } },
                { text = "Close it when you're done and we'll set you back up.", anchor = "catalog:continue" },
            },
        },

        -- S8. Back on the grind after the first shove. "Run" is said for
        -- the first time here, when it is true.
        {
            id      = "the_loop",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "screen",      name = "grind" },
                        { kind = "has_shoved" },
                        { kind = "tables_open", min = 1 } },
            lines = {
                { text = "And we're back to two dollars. That's a run. Sharper Reads went with it. Those reset. The catalog doesn't.",
                  anchor = { "cell:bankroll", "buy_runup_sharper_reads" } },
                { text = "Your odds on the big hand: what you own, times what you hold. So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time.",
                  anchor = { "cell:shove", "chip_badge:shove" } },
            },
        },

        -- S9. Act 2, on the grind after the first R1 win.
        {
            id      = "act2",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "screen", name = "grind" },
                        { kind = "act2_unlocked" } },
            lines = {
                { text = "You actually won that. Good for you. The next hand doesn't count your catalog. Just your deck.",
                  anchor = "cell:deck" },
                { text = "It levels up as it plays, and its bonus is on every hand. Max out five and something new joins the rack.",
                  anchor = "cell:deck" },
                { text = "The big tables are open now. Bring money.", anchor = "add_table:s004:six_max" },
            },
        },

        -- S9, in the deck-select modal. A separate beat: the modal opens on
        -- the shove screen, before act2 can play on the grind.
        {
            id      = "act2_decks",
            screen  = "shove",
            trigger = { kind = "all",
                        { kind = "screen", name = "shove" },
                        { kind = "deck_select_open" } },
            lines = {
                { text = "Pick one. It plays the next run. The locked ones tell you what opens them.",
                  anchor = "deck:tile:1" },
            },
        },

        -- S10. Act 3.
        {
            id      = "act3",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "screen", name = "grind" },
                        { kind = "act3_unlocked" } },
            lines = {
                { text = "Twice. Honestly, that's a first. Bad news: your multiplier's zero now. Money won't fix it.",
                  anchor = "cell:shove" },
                { text = "Good news: lose a stack up top and I'll pay you for it. Spend those in the catalog on things you already own.",
                  anchor = { "cell:achips", "btn:catalog" } },
                { text = "And your money sits in a box with a bottom. Worth knowing.", anchor = "cell:underflow" },
            },
        },

        -- S11. He gets the last word.
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
    },
}
