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
--          one place. A keyed line with empty text is a silent slot.
--
-- Beat:  id, screen (the screen whose box it draws in; it pauses on any
--        other), trigger (a condition, kinds in models/hint_rules.lua),
--        lines, and optionally
--          pause = true     the SIMULATION freezes while one of this
--                           beat's lines is up (the shove clock, the
--                           tables, the cursors, the status timers), so
--                           what he points at is still there when he says
--                           it. The click resumes it. A forced `wait` line
--                           never freezes: the action has to be able to
--                           happen. Most beats don't need this; the ones
--                           that narrate a moment in motion do.
--
-- LINES ARE MODAL. While any line is visible the PLAYER is paused: every
-- gameplay click and key is swallowed (main.lua), and a click ANYWHERE —
-- or SPACE — completes the typewriter, then advances. Without `pause` the
-- game keeps simulating underneath. Comms are cleared actively, never
-- ignored. The screen always dims under a line: full spotlight strength
-- with holes over the line's anchor marks when it points at something, a
-- quarter-strength wash when it doesn't. ESC still opens settings (which
-- pauses the beat).
--
-- Line:  a BLOCK of text: as many sentences as one click's worth of
--        reading, wrapped in the box. Fields: text ({chip} markers
--        render; {dyn:NAME} tokens resolve to live numbers through
--        models/story_dynamic — never hardcode a number the game
--        computes), anchor (name or list; pulsing mark + spotlight
--        holes), and ONE of:
--          hold = "click"   waits for a click anywhere / SPACE (default)
--          hold = <secs>    advances itself
--          wait = cond      after it is said, blocks until cond passes.
--                           HARD RULE: a `wait` line MUST also be `force`
--                           — everything else is input-blocked, so only a
--                           forced line's targets stay clickable and only
--                           they can satisfy the wait.
--        plus optionally:
--          force = true     with `wait`: clicks inside the line's fresh
--                           marks pass through to the game — the action
--                           IS the advance; everything else is swallowed.
--                           Only force what is certainly doable: free (a
--                           hover, a click), or guarded by a `show` that
--                           re-checks affordability. No fresh target = no
--                           lock, so a forced line never dead-locks.
--          show = cond      the block is not said until cond passes
--          wait_fresh = true  with `wait`: the condition must be seen
--                           FALSE once before it can pass, so a hover the
--                           mouse is already making when the line lands
--                           does not skip the line
--          delay = <secs>   pause before it is said
--          font = "sm"      smaller than the default md
--          grant = "loan"   the block HANDS OVER the starting bankroll as
--                           it lands (GameState:grantLoan; the readout
--                           climbs from 0). A fresh game has no money
--                           until this line.
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
-- cheat, a card count, or the second hand. The sixth card is the
-- Undertow, the seventh the Ferry; he names them only once each is on
-- the felt.

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
                { text = "Morning, princess. You must've had the best sleep of your life." },
                { text = "I know you've got questions. I've got answers. Not yet, though. Answers are for poker players, and so far all you've done is stand there." },
                { text = "Here's 2 dollars. Call it a loan. Put it on the felt.",
                  anchor = { "cell:bankroll", "add_table:s001:zoom" },
                  grant  = "loan",
                  force  = true,
                  wait   = { kind = "tables_open", min = 1 } },
                { text = "The 2 dollars is on the table. You want it back, you cash out. But we've got poker to play.",
                  anchor = { "stack:1", "cell:tied" } },
                { text = "Deal.",
                  anchor = "table:1",
                  force  = true,
                  wait   = { kind = "hands_played", min = 1 } },
            },
        },

        -- A1b. The first hand, one way or the other. Two beats because a
        -- line can be delayed but never skipped; the trigger reads the
        -- sign of the first resolved hand (state.first_hand_delta).
        {
            id      = "first_hand_lost",
            screen  = "grind",
            trigger = { kind = "first_hand", result = "lost" },
            lines = {
                { text = "Looks like you {c:lost:lost} that one. Luckily it was only a {dyn:first_hand_tier}.",
                  anchor = "stack:1" },
                { text = "{c:won:Wins} and {c:lost:losses} come at different sizes. {l:stack} {l:large} {l:medium} {l:small} {w:small} {w:medium} {w:large} {w:stack} Keep playing." },
            },
        },
        {
            id      = "first_hand_won",
            screen  = "grind",
            trigger = { kind = "first_hand", result = "won" },
            lines = {
                { text = "Looks like you {c:won:won} your first hand. We're going to get along just fine. You can see the size of the win here, it was a {dyn:first_hand_tier}",
                  anchor = "stack:1" },
                { text = "{c:won:Wins} and {c:lost:losses} come at different sizes. {l:stack} {l:large} {l:medium} {l:small} {w:small} {w:medium} {w:large} {w:stack} Keep playing." },
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
                { text = "See that. A table only holds its buy-in. {c:won:Win} past full and the rest ends up in the bankroll. Yours to spend how you see fit.",
                  anchor = { "stack:1", "cell:bankroll" } },
            },
        },

        -- A3. The upgrade rack, the first time a buy is affordable without
        -- bricking the run (the shop's own strand check). Forced: buying
        -- one teaches the rack better than a paragraph about it; then a
        -- forced hover on what was bought.
        {
            id      = "sharper_reads",
            screen  = "grind",
            trigger = { kind = "can_afford_run_upgrade", id = "sharper_reads", safe = true },
            lines = {
                { text = "You can afford {c:upgrade:Sharper_Reads}. Grab it.",
                  anchor = "buy_runup_sharper_reads",
                  show   = { kind = "can_afford_run_upgrade", id = "sharper_reads", safe = true },
                  force  = true,
                  wait   = { kind = "run_upgrades_owned", min = 1 } },
                { text = "That'll improve your odds of winning. Hover it to see what it can do for you at the next level.",
                  anchor = "buy_runup_sharper_reads",
                  force  = true,
                  wait_fresh = true,
                  wait   = { kind = "hovering", anchor = "buy_runup_sharper_reads" } },
                { text = "You'll want to keep an eye on the {c:upgrade:upgrade_rack}, you won't have a chance in hell at the higher stakes without it. The players get better at every stake.",
                  anchor = "buy_runup_sharper_reads" },
            },
        },

        -- A4. The duel opens (GrindController latches hu_unlocked the
        -- moment a second buy-in is in hand) and the player walks through
        -- the door themselves: swap to the tab, buy the seat.
        {
            id      = "second_table",
            screen  = "grind",
            trigger = { kind = "hu_unlocked" },
            lines = {
                { text = "Look at you, a second buy-in already. The duel just opened. Heads-Up. One opponent, whole stacks, both ways.",
                  anchor = "gtype:hu" },
                { text = "Sit down.",
                  anchor = { "gtype:hu", "add_table:s001:hu" },
                  show   = { kind = "can_afford_stake", stake = "s001" },
                  force  = true,
                  wait   = { kind = "gtype_table_open", gtype = "hu" } },
            },
        },

        -- A5. The first {chip}: one beat, the whole lesson, because the
        -- whole lesson is on screen at once. The stack, what it paid, the
        -- once-per-table rule, the readout that predicted it (forced
        -- hover), the zoom-vs-duel gap, the notes, the door.
        {
            id      = "first_chip",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = 1 },
            lines = {
                { text = "You rinsed him. got his whole stack {w:stack}.",
                  anchor = "stack:1" },
                -- CHECK: "Win a {w:stack} and the table and it pays one" reads
                -- like a word went missing.
                { text = "It came with a {chip}. Real gold, I weigh them myself. Win a {w:stack} and the table and it pays one.",
                  anchor = { "cell:chips", "chip_badge:banked" } },
                -- The border on the felt (the panel that paid), the border on
                -- its button, and the +{chip} badge on that button.
                { text = "Remember though, It's only the FIRST {w:stack} at a table that pays a {chip}. You can tell if a table's {c:chip:paid} by the border on the felt, or the button.",
                  anchor = { "table:banked", "add_table:banked", "chip_badge:banked" } },
                -- Every "+N {chip}" badge on the strip (the rows of the open tab).
                { text = "You can also see how many {chip} you'll earn for a {w:stack} here. Higher stakes, better {c:won:payouts}.",
                  anchor = { "add_table_chip:s001:zoom", "add_table_chip:s002:zoom", "add_table_chip:s003:zoom",
                             "add_table_chip:s001:hu",   "add_table_chip:s002:hu",   "add_table_chip:s003:hu" } },
                { text = "Get 3 {chip}, and you'll get your first answer.",
                  anchor = { "chip_badge:banked", "chip_badge:shove" } },
                { text = "While we're here, hover the readout under a table. Go on, don't keep me waiting.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" },
                  force  = true,
                  wait   = { kind = "hovering", anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } } },
                { text = "Everything a table does per hour, and its odds at all four pot sizes. The gold {w:stack} is the one that pays.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
                { text = "Now compare your rooms. Zoom's gold number sits at {dyn:stack_odds_zoom} a hand. The duel runs {dyn:stack_odds_hu}.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
                { text = "Zoom players rarely go all in. Until you get better at reeling them in at least.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
                { text = "In case you forget anything, I'm keeping notes.",
                  anchor = "btn:help" },
            },
        },

        -- A6. The pitch. Deliberately NOT forced: the shove is the one
        -- thing here that should feel like the player's own call.
        {
            id      = "the_pitch",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS },
            lines = {
                { text = "Three! Look at you. So here's your answer.", anchor = "chip_badge:shove" },
                { text = "There's only one way out of here. Straight through the {c:chip:door}.", anchor = "btn:shove" },
                { text = "But first, you gotta get past me. One hand, everything you have goes in. Winner takes all.",
                  anchor = "btn:shove" },
                { text = "{c:won:Win}, and you walk out with the lot. {c:lost:Lose}, and you keep the {chip}. I'll set you back up with the 2 dollar loan. No harm done.",
                  anchor = "btn:shove" },
                { text = "Whenever you're ready. No rush. I'm always here. If you feel like you've stalled out, then it's usually a good idea to SHOVE.",
                  anchor = "btn:shove" },
            },
        },

        -- A7. The shove, narrated as it happens, with the clock stopped
        -- under each line: the pile once it has landed, the readout once
        -- the hand is running, then the runout deals on the click.
        {
            id      = "shove_walkthrough",
            screen  = "shove",
            pause   = true,
            trigger = { kind = "shove_phase", phase = "buildup" },
            lines = {
                { text = "Everything you've got, in one pile. I'll match it if you win and you can walk right out. I love this part.",
                  anchor = "shove:pot",
                  show   = { kind = "shove_pot_landed" } },
                { text = "This bar is your odds at beating me. I'm pretty good though.",
                  anchor = "shove:readout",
                  show   = { kind = "shove_phase", phase = "running" } },
                { text = "...Am I reading that right? 0%? Bad luck.",
                  anchor = "shove:readout" },
            },
        },
        {
            id      = "shove_result",
            screen  = "shove",
            pause   = true,
            trigger = { kind = "shove_beat", id = "result" },
            lines = {
                { text = "Looks like you {c:chip:banked} {dyn:banked_chips} {chip}. Those are yours to keep, call it a consolation prize.",
                  anchor = "shove:summary" },
            },
        },
        -- NOT HIS. Corruption and {achip} get no tutorialization anywhere:
        -- he didn't put them in the book, he doesn't know what they do,
        -- and neither does the player. Weird text appears in the catalog;
        -- figure it out, or don't. All he does is NOTICE.

        -- Gated on the card being ON the felt, never a flag: nothing may
        -- name a cheat before the player has seen one.
        {
            id      = "house_cheats",
            screen  = "shove",
            pause   = true,
            trigger = { kind = "cheat_dealt", min = 1 },
            lines = {
                { text = "I forgot to tell you about the undertow card. Unfortunately it landed on your ITEMS and took them out of the count. The bar shows what's left. House rules. Nothing personal.",
                  anchor = "shove:cheat_6" },
            },
        },

        -- A8. The catalog, the first time it is open on the felt.
        {
            id      = "first_catalog",
            screen  = "shove",
            pause   = true,
            trigger = { kind = "catalog_open" },
            lines = {
                { text = "Before you head back, have a look at the catalog. Anything in here you keep. Buy it once, and it'll be delivered right to your room.",
                  anchor = "catalog:book" },
                { text = "That stamp's the price. Stickered ones aren't ready yet.",
                  anchor = { "catalog:price:first", "catalog:sticker:first" },
                  show   = { kind = "catalog_open" } },
                { text = "Close it when you're done and we'll set you back up. How fun.", anchor = "catalog:continue" },
            },
        },

        -- A9. Back on the grind after the first shove. "Run" is said for
        -- the first time here, when it is true. The last line sends the
        -- player to the room (forced); the_room picks up there.
        {
            id      = "the_loop",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "has_shoved" },
                        { kind = "tables_open", min = 1 } },
            lines = {
                { text = "Same loan, same terms. That's a run.",
                  anchor = "cell:bankroll" },
                { text = "Your {c:upgrade:upgrades} went with it. Those reset.",
                  anchor = "buy_runup_sharper_reads" },
                { text = "Let's take a look at your room.",
                  anchor = "btn:room",
                  force  = true,
                  wait   = { kind = "screen", name = "room" } },
            },
        },
        -- The room, the first time he sends the player there (the button
        -- only exists once the first shove is behind them).
        {
            id      = "the_room",
            screen  = "room",
            trigger = { kind = "all",
                        { kind = "has_shoved" },
                        { kind = "screen", name = "room" } },
            lines = {
                { text = "Everything you bought from the catalog, delivered as promised. These never reset.",
                  anchor = "room:items" },
                { text = "Your odds on the SHOVE: Items in your room, multiplied by your total bankroll." },
                { text = "So it's about {chip} now. Every table pays one. Collect, then shove. You'll get it. Next time.",
                  anchor = "room:play" },
            },
        },

        -- Heat is a mechanic, not an item: the beat fires the first time
        -- ANY table catches a heater, from whatever source (lifetime
        -- total_heaters, tallied in GrindController). The tables freeze
        -- so the fire is still on the felt while he says it.
        {
            id      = "first_heat",
            screen  = "grind",
            pause   = true,
            trigger = { kind = "total_heaters", min = 1 },
            lines = {
                { text = "This table's {c:heat:on_fire}, if it was already on a hand, that one {c:won:wins}, the next hand is dealt for you. Guaranteed win. Fire's your friend.",
                  anchor = "table:heater" },
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
                { text = "With so many players these take forever. Maybe you can speed them up somehow.",
                  anchor = "gtype:six_max" },
            },
        },
        {
            id      = "first_tournament",
            screen  = "grind",
            trigger = { kind = "gtype_table_open", gtype = "ko" },
            lines = {
                { text = "A tournament. One buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}. Great business, tournaments.",
                  anchor = "gtype:ko" },
                { text = "Not for you of course, cash games pay better. They do have their place though, they can improve your other tables.",
                  anchor = "gtype:ko" },
            },
        },
        -- The right-click controls this describes are not wired yet; the
        -- copy leads, the mechanic follows.
        {
            id      = "first_cursors",
            screen  = "grind",
            trigger = { kind = "owns_item", id = "box_of_mice" },
            lines = {
                { text = "Look at you, management. The {c:upgrade:cursors} can deal for you now. Buy them over here, and their {c:upgrade:upgrades}. Right click a table to stop them dealing there. You can also right click a table button to stop dealing to ALL of that type, or the {c:upgrade:cursor} button itself to COMPLETELY stop them from dealing. Right click again to enable.",
                  anchor = { "buy_runup_cursor", "buy_runup_cursor_speed" } },
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
                { text = "NL10's open. That's {dyn:stake_mult_s002} times the money, but the players are better. Worth an {c:upgrade:upgrade} or two first.",
                  anchor = "add_table:s002:zoom" },
                { text = "The number's {c:lost:red}. I wouldn't recommend playing here until you get a few more {c:upgrade:upgrades} first",
                  anchor = { "add_table_ev:s002:zoom", "add_table_ev:s002:hu" } },
            },
        },
        {
            id      = "first_bust",
            screen  = "grind",
            trigger = { kind = "any_table_busted" },
            lines = {
                { text = "So much for knowing what you're doing I guess, you {c:lost:lost} your whole stack at this table.",
                  anchor = "rebuy:any" },
                { text = "To keep playing you'll have to rebuy, don't let it happen again.",
                  anchor = "rebuy:any" },
            },
        },
        {
            id      = "chip_denied",
            screen  = "grind",
            trigger = { kind = "total_denied_stacks", min = 1 },
            lines = {
                { text = "You {c:won:won} another {w:stack} but no {chip}. This table type's already {c:chip:paid} its {chip}. Each stake and game pays once per run. Climb.",
                  anchor = "chip_badge:banked" },
            },
        },
        {
            id      = "focus_overload",
            screen  = "grind",
            trigger = { kind = "focus_overloaded" },
            lines = {
                { text = "Easy, tiger. You can't focus on that many tables at once. ALL your {c:won:wins} at ALL tables win {dyn:focus_penalty_pct} less for each table above your focus cap. Adds up fast.",
                  anchor = { "cell:focus", "buy_runup_focus" } },
            },
        },
        {
            id      = "first_corruption",
            screen  = "shove",
            trigger = { kind = "all",
                        { kind = "catalog_open" },
                        { kind = "corrupted_count", min = 1 } },
            lines = {
                { text = "Wait. What did you do to it?",
                  anchor = "catalog:corrupt:first" },
            },
        },

        -- Act 2, on the grind after the first R1 win. The flyer and the
        -- decks are taught on the felt (flyer_lands, act2_decks) before
        -- this can play.
        {
            id      = "act2",
            screen  = "grind",
            trigger = { kind = "act2_unlocked" },
            lines = {
                { text = "I hope the undertow didn't catch you off guard, I should've told you about it sooner. Oh well.",
                  anchor = "cell:shove" },
                -- Anchored on a zoom row: 6-max may still be behind its
                -- catalog key here, but zoom is always open and s004
                -- opens with this very beat.
                { text = "The mid stakes are open now. Bring money.", anchor = "add_table:s004:zoom" },
            },
        },

        -- Act 2, on the shove felt: the flyer lands beside the book and
        -- the player is sent to open it.
        {
            id      = "flyer_lands",
            screen  = "shove",
            trigger = { kind = "deck_flyer_landed" },
            lines = {
                { text = "I have a new flyer for you, check it out.",
                  anchor = "deck:flyer",
                  force  = true,
                  wait   = { kind = "deck_flyer_open" } },
            },
        },
        -- Act 2, the flyer open.
        {
            id      = "act2_decks",
            screen  = "shove",
            trigger = { kind = "deck_flyer_open" },
            lines = {
                { text = "You can only run one at a time, its bonus levels up as you play. Reach level 5 for the Capstone bonus effect.",
                  anchor = "deck:tile:1" },
                { text = "ALL your decks give you their bonus, whether they're active or not. So it's in your best interest to diversify.",
                  anchor = "deck:xp" },
            },
        },

        -- The top table opens (the Ultra key was bought).
        {
            id      = "the_top_table",
            screen  = "grind",
            trigger = { kind = "ultra_unlocked" },
            lines = {
                { text = "I didn't even know we had a table that big. Not that it matters for you, get as high as you want you're never getting a multiplier above zero again.",
                  anchor = "add_table:s010:zoom" },
            },
        },

        -- The underflow: the scripted Ultra loss breaks the count.
        {
            id      = "underflow",
            screen  = "grind",
            trigger = { kind = "bankroll", max = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD - 1 },
            lines = {
                { text = "You lost at the ULTRA stake. That must sting.", anchor = "cell:bankroll" },
                { text = "Wait...what happened to your multiplier?", anchor = "cell:shove" },
            },
        },
    },

    shove = {
        pushing        = { text = "Pushing all in." },
        arrive         = { text = "All of it. That's the spirit." },
        loss           = { text = "Ah. House {c:won:wins} that one. I'm sure you got the next one though." },
        -- The panic. Only reachable after a runout win; the one place the
        -- host's mask slips. Three slots on the timeline; the third is
        -- silent.
        panic_wait     = { text = "Wait...No no nono" },
        panic_won      = { text = "What just happened?" },
        panic_no       = { text = "" },
        panic_new_card = { text = "New card. Try again later." },
        -- Twice. The Undertow survived; the Ferry lands on BANK.
        panic_again    = { text = "You survived the undertow? How is that even possible." },
        panic_no_more  = { text = "Sadly though, no one crosses the ferry. Clumsy me dropped it on your bankroll, hope that doesn't change the..." },
        clear          = { text = "There is nothing left to take from you.", once = true },
        -- The ending. He does not see the count is broken. Another card has
        -- always worked. Not once-lines: a second clear replays it.
        deck_no        = { text = "No." },
        deck_again     = { text = "Again." },
        deck_doesnt    = { text = "That one doesn't count." },
        deck_deal      = { text = "Deal." },
        deck_all       = { text = "All of it, then." },
        deck_out       = { text = "There's nothing left to deal." },

        -- The room, before the felt: counting what you own. Skipped on a
        -- shove with nothing to count (the first one).
        room_count     = { text = "Let's see what you've got." },
        room_done      = { text = "That's your room. Not bad." },
        room_empty     = { text = "Nothing yet. That's fine. We'll fix that." },
    },
}
