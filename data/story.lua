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
--          recheck = true   the trigger must STILL pass when the beat
--                           starts. It arms like any other and is never
--                           lost, but while it waits its turn behind
--                           another beat the state it speaks to can
--                           change, and a beat that opens with a
--                           present-tense fact ("NL10's open", i.e. you
--                           can afford it) must not say it once the fact
--                           has gone. Stays armed; starts the next tick
--                           the trigger holds. For transient money
--                           triggers; a counter that only climbs never
--                           needs it.
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
--          cue = "Deal"     with `force`+`wait`: what the box's bottom row
--                           says the line waits for ("Your move" without)
--        Text: a newline ("\n") always starts a line; "{page}" ends a
--        page (the box holds three lines; the rest comes on the click).
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
                { text = "I know you've got questions. I've got answers. Not yet, though.{page}Answers are for poker players, and so far all you've done is stand there." },
                { text = "Here's 2 dollars. Call it a loan. Put it on the felt.",
                  anchor = { "cell:bankroll", "add_table:s001:zoom" },
                  grant  = "loan",
                  force  = true,
                  cue    = "Open a table",
                  wait   = { kind = "tables_open", min = 1 } },
                { text = "The 2 dollars is on the table. You want it back, you cash out. But we've got poker to play.",
                  anchor = { "stack:1", "cell:tied" } },
                { text = "Click on the table to deal.",
                  anchor = "table:1",
                  force  = true,
                  cue    = "Deal",
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
                { text = "Looks like you {c:lost:lost} that one.\nLuckily it was only {dyn:first_hand_amount} {dyn:first_hand_tier}.",
                  anchor = "stack:1" },
            },
        },
        {
            id      = "first_hand_won",
            screen  = "grind",
            trigger = { kind = "first_hand", result = "won" },
            lines = {
                { text = "Looks like you {c:won:won} your first hand. We're going to get along just fine.{page}You can see the size of the win here. It was {dyn:first_hand_amount} {dyn:first_hand_tier}.",
                  anchor = "stack:1" },
            },
        },

        -- A1c. The sizes, after either first hand: arms with them (a hand
        -- has resolved) and plays after whichever of the two fired, in
        -- script order.
        {
            id      = "payout_sizes",
            screen  = "grind",
            trigger = { kind = "hands_played", min = 1 },
            lines = {
                { text = "Payouts come in many sizes.\nLosses: {l:small} {l:medium} {l:large} {l:stack}\nWins: {w:small} {w:medium} {w:large} {w:stack}" },
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
                { text = "A table only holds its buy-in. {c:won:Win} past full and the rest ends up in the bankroll. Yours to spend how you see fit.",
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
                  cue    = "Buy Sharper Reads",
                  wait   = { kind = "run_upgrades_owned", min = 1 } },
                { text = "That'll improve your {c:chance:odds} of winning. Hover {c:upgrade:Pot_Control}.",
                  anchor = "buy_runup_pot_control",
                  force  = true,
                  cue    = "Hover Pot Control",
                  wait_fresh = true,
                  wait   = { kind = "hovering", anchor = "buy_runup_pot_control" } },
                -- Said with the hover's tooltip held up (StoryDirector).
                { text = "Hovering lets you know what things do. Use it if you're lost.",
                  anchor = "buy_runup_pot_control" },
                { text = "I'm keeping notes. If you forget what anything does, use this button to see them.",
                  anchor = "btn:help" },
                { text = "You'll want to keep an eye on the {c:upgrade:upgrade_rack}, you won't have a chance in hell at the higher stakes without it.{page}The players get better at every stake.",
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
                { text = "Look at you, a second buy-in already. Heads-Up just opened. One opponent, whole stacks, both ways.{page}Sit down.",
                  anchor = { "gtype:hu", "add_table:s001:hu" },
                  show   = { kind = "can_afford_stake", stake = "s001" },
                  force  = true,
                  cue    = "Open a Heads-Up table",
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
                  anchor = "stack:banked" },
                { text = "It came with a {chip}. Real gold, I weigh them myself. Win a {w:stack} at a table and it pays one.",
                  anchor = { "cell:chips", "chip_badge:banked", "stack:banked" } },
                -- The border on the felt (the panel that paid), the border on
                -- its button, and the +{chip} badge on that button. A {chip}
                -- pays once per stake and game per run (chip_denied agrees).
                { text = "Only the FIRST {w:stack} at each stake and game pays a {chip}, once a run.{page}You can tell a table's {c:chip:paid} by the border on the felt, or on its button.",
                  anchor = { "table:banked", "add_table:banked", "chip_badge:banked" } },
                -- Every "+N {chip}" badge on the strip (the rows of the open tab).
                { text = "You can also see how many {chip} you'll earn for a {w:stack} here. Higher stakes, better {c:won:payouts}.",
                  anchor = { "add_table_chip:s001:zoom", "add_table_chip:s002:zoom", "add_table_chip:s003:zoom",
                             "add_table_chip:s001:hu",   "add_table_chip:s002:hu",   "add_table_chip:s003:hu" } },
                { text = "Get 3 {chip}, and you'll get your first answer.",
                  anchor = { "cell:chips", "chip_badge:banked" } },
                { text = "While we're here, hover the readout under a table. Go on, don't keep me waiting.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" },
                  force  = true,
                  cue    = "Hover a readout",
                  wait   = { kind = "hovering", anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } } },
                -- The readout under every table, and the same readout on
                -- every add-table row that shows one (a table you can open,
                -- or have open).
                { text = "What a table makes an hour, and its {c:chance:odds} at every pot size. The gold {w:stack} is the one that pays.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4",
                             "add_table_ev:s001:zoom", "add_table_ev:s002:zoom", "add_table_ev:s003:zoom",
                             "add_table_ev:s001:hu",   "add_table_ev:s002:hu",   "add_table_ev:s003:hu" } },
                { text = "Zoom's gold number currently sits at {dyn:stack_odds_zoom} a hand. Heads-Up runs {dyn:stack_odds_hu}.",
                  anchor = { "stack_pct:1", "stack_pct:2", "stack_pct:3", "stack_pct:4" } },
                { text = "Zoom players rarely go all in. Until you get better at reeling them in at least.",
                  anchor = { "ev:1", "ev:2", "ev:3", "ev:4" } },
            },
        },

        -- A6. The pitch. Deliberately NOT forced: the shove is the one
        -- thing here that should feel like the player's own call.
        {
            id      = "the_pitch",
            screen  = "grind",
            trigger = { kind = "chips_this_run", min = Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS },
            lines = {
                { text = "Three! Look at you. So here's your answer.", anchor = "cell:chips" },
                { text = "There's only one way out of here. Straight through the {c:chip:door}.", anchor = "btn:shove" },
                { text = "But first, you gotta get past me. One hand, everything you have goes in.{page}No need to cash out your tables, I'll do it for you. Winner takes all.",
                  anchor = "btn:shove" },
                { text = "{c:won:Win}, and you walk out with the lot. {c:lost:Lose}, and you keep the {chip}. I'll set you back up with the 2 dollar loan. No harm done.",
                  anchor = "btn:shove" },
                { text = "Whenever you're ready. No rush. I'm always here. If you feel like you've stalled out, it's usually a good idea to hold SHOVE.",
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
                  show   = { kind = "shove_pot_landed" } },
                { text = "That equation's your shot at beating me. Don't worry about the numbers yet, I'll walk you through them later.",
                  anchor = "shove:readout",
                  show   = { kind = "shove_phase", phase = "running" } },
                { text = "I'm pretty good though. ...Am I reading that right? 0%? Bad luck.",
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
                { text = "I forgot to tell you about the undertow card. Unfortunately it landed on your ITEMS and took them out of the count.{page}The bar shows what's left. House rules. Nothing personal.",
                  anchor = "shove:cheat_6" },
            },
        },

        -- A8. The catalog, the first time it is open on the felt.
        {
            id      = "first_catalog",
            screen  = "shove",
            pause   = true,
            -- The book has landed, shut: the player is sent to open it
            -- (forced, so the click on the book is the book's), and the
            -- pages are explained once it is open.
            trigger = { kind = "catalog_landed" },
            lines = {
                { text = "Before you head back, have a look at the catalog. Anything in here you keep.",
                  anchor = "catalog:book",
                  force  = true,
                  cue    = "Open the catalog",
                  wait   = { kind = "catalog_open" } },
                { text = "Buy it, and it'll be delivered right to your room.",
                  anchor = "catalog:book" },
                { text = "The stamp's the price, in {chip}. Stickered ones aren't ready yet. But they usually tell you why.",
                  anchor = { "catalog:price:first", "catalog:sticker:first" },
                  show   = { kind = "catalog_open" } },
                { text = "Close it when you're done and we'll set you back up. How fun.", anchor = "catalog:book" },
            },
        },

        -- The first thing bought went on the manifest, the receipt
        -- tucked behind the book's left page. One line, pointed at it.
        {
            id      = "first_purchase",
            screen  = "shove",
            trigger = { kind = "items_owned", min = 1 },
            lines = {
                { text = "Added to the manifest.", anchor = "catalog:manifest" },
            },
        },

        -- A9. Back on the grind after the first shove, the moment the felt
        -- is back (no table needs to be open). "Run" is said for the first
        -- time here, when it is true. The last line sends the player to the
        -- room (forced); the_room picks up there.
        {
            id      = "the_loop",
            screen  = "grind",
            trigger = { kind = "has_shoved" },
            lines = {
                { text = "Same loan, same terms. Run it back.",
                  anchor = "cell:bankroll" },
                { text = "Your {c:upgrade:upgrades} went with it. Those reset.",
                  -- Every row on the rack, whichever the player has bought.
                  anchor = { "buy_runup_sharper_reads", "buy_runup_pot_control", "buy_runup_focus",
                             "buy_runup_cursor", "buy_runup_cursor_speed" } },
                { text = "Let's take a look at your room.",
                  anchor = "btn:room",
                  force  = true,
                  cue    = "Open your room",
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
                { text = "Cozy. Everything you bought from the catalog, delivered as promised. These never reset.",
                  anchor = "room:items" },
                { text = "Remember the SHOVE equation? It's ITEMS in your room, multiplied by your BANKROLL, tables included.{page}That's why it was 0%. You didn't own anything yet." },
                { text = "So it's about {chip} now. Every table pays at least one. Higher stakes pay more. Collect, then shove. You'll get it. Next time.",
                  anchor = "room:play" },
            },
        },

        -- A11. The book from the desk: the grind's catalog button opens it
        -- read-only. Looking is free; the order desk is the shove's.
        {
            id      = "catalog_browse",
            screen  = "grind",
            pause   = true,
            -- The book open ON THE GRIND: a trigger arms wherever it is
            -- true, and the post-shove book is open on the felt too, so
            -- without the screen the beat armed there and played on the
            -- first click back on the grind.
            trigger = { kind = "all",
                        { kind = "screen", name = "grind" },
                        { kind = "catalog_open" } },
            -- No anchor: the book is the whole screen.
            lines = {
                { text = "The Catalog. Browse all you like, but you can only make purchases after a SHOVE." },
            },
        },

        -- Tables move. Said the first time it matters: a board item is
        -- owned (one whose rule reads neighbours, empties or the hand) and
        -- there are two tables to arrange. The first line is forced on the
        -- header strips and waits for a whole pick-up-and-put-down (the
        -- counter ticks on the drop), so no line sits under the hold.
        {
            id      = "move_tables",
            screen  = "grind",
            trigger = { kind = "all",
                        { kind = "screen", name = "grind" },
                        { kind = "owns_board_item" },
                        { kind = "tables_open", min = 2 } },
            lines = {
                { text = "Some tables and items benefit from where they are on the grid, you can pick them up by holding over the chrome bar.",
                  anchor = { "table_bar:1", "table_bar:2", "table_bar:3", "table_bar:4" },
                  force  = true,
                  cue    = "Pick up a table",
                  wait   = { kind = "total_table_moves", min = 1 } },
                { text = "Held tables still deal and can be placed in any grid spot available.",
                  anchor = { "table:1", "table:2", "table:3", "table:4" } },
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
                { text = "That table's on a {c:heat:heater}. If it's mid-hand, that hand {c:won:wins} now. The next hand is dealt for you, and it {c:won:wins} too.{page}Fire's your friend.",
                  anchor = "table:heater" },
            },
        },
        -- The other punch. Tilt is granted at run start (the hidden Tilt
        -- catalog entry), so the first one lands on its own; he names it
        -- once, the way he named the heater, and the glossary card opens.
        {
            id      = "first_tilt",
            screen  = "grind",
            pause   = true,
            trigger = { kind = "total_tilts", min = 1 },
            lines = {
                { text = "That table's on {c:tilt:tilt}. If it's mid-hand, that hand's {c:lost:lost}. The next hand is dealt for you, and it's {c:lost:lost} too.{page}Happens at every table sooner or later. Ride it out.",
                  anchor = "table:tilt" },
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
                { text = "This one's big and slow, like a tank. It drips between the big ones, so leave it running.{page}MOST things that help a table help this one the most. Hell, even things that hurt most tables can help at 6-Max.",
                  anchor = "gtype:six_max" },
            },
        },
        {
            id      = "first_tournament",
            screen  = "grind",
            trigger = { kind = "gtype_table_open", gtype = "ko" },
            lines = {
                { text = "A tournament. One buy-in, no rebuy. Eight seats, ten blinds each, and it deals itself.",
                  anchor = "gtype:ko" },
                { text = "The blinds climb as it goes, and you sit some hands out while the rest of them play. Your {c:upgrade:upgrades} set your odds in it.",
                  anchor = "gtype:ko" },
                { text = "Each player it knocks out is a {ko}. Top three cash. Win it outright for the {chip}.{page}They have their place. A {ko} can improve your other tables.",
                  anchor = "gtype:ko" },
            },
        },
        -- The right-click controls these describe: views/GrindView:_rightClick.
        -- Each block lights what it teaches: the rack, a table, a table
        -- button with open tables (add_table:open), the Cursor upgrade.
        {
            id      = "first_cursors",
            screen  = "grind",
            trigger = { kind = "owns_item", id = "box_of_mice" },
            lines = {
                { text = "Ah, you got the box of mice, excellent. The cursors can deal for you if you're tired of doing it yourself.",
                  anchor = { "buy_runup_cursor", "buy_runup_cursor_speed" } },
                { text = "Right click a table, a table button, or the {c:upgrade:Cursor} upgrade to stop them dealing at that table, those tables, or all tables.{page}Right click again to start them.",
                  anchor = { "table:1", "add_table:open", "buy_runup_cursor" } },
            },
        },

        -- Reactive lessons: each fires the first time its situation
        -- actually exists. Order here is priority when several arm at
        -- once, nothing more.
        {
            id      = "stake_ladder",
            screen  = "grind",
            trigger = { kind = "can_afford_stake", stake = "s002" },
            -- A stack win can clear $10 for a few seconds and a queued
            -- beat (first_bust, first_chip) can hold this one back while
            -- the money goes into an upgrade; without the recheck it once
            -- opened with "NL10's open" to a player holding $4.
            recheck = true,
            lines = {
                { text = "NL10's open. That's {dyn:stake_mult_s002} times the money, but the players are better.{page}The number's {c:lost:red}. I wouldn't recommend playing here until you get a few more {c:upgrade:upgrades} first, unless you know what you're doing.",
                  anchor = { "add_table:s002:zoom", "add_table_ev:s002:zoom", "add_table_ev:s002:hu" } },
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
                -- The focus cell, and every X that closes a table (the
                -- panels' and the rows'): closing one is the other way out.
                { text = "Easy, tiger. FOCUS is how many tables you can keep up with. Right now that's {dyn:focus_cap}. Past it, every table slows all of them. More FOCUS, more tables.{page}Each one over costs {dyn:focus_penalty_pct}. Adds up fast. Raise it with {c:upgrade:Focus} on the rack, or close a table.",
                  anchor = { "cell:focus",
                             "table_close:1", "table_close:2", "table_close:3", "table_close:4",
                             "table_close:5", "table_close:6", "table_close:7", "table_close:8",
                             "cash_out_type:s001:zoom", "cash_out_type:s001:hu",
                             "cash_out_type:s002:zoom", "cash_out_type:s002:hu",
                             "cash_out_type:s003:zoom", "cash_out_type:s003:hu" } },
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
            sound   = "house_stinger",
            trigger = { kind = "act2_unlocked" },
            lines = {
                { text = "I hope the undertow didn't catch you off guard.{page}I forgot, we have a couple house rules in play. I can't remember if there are others." },
                -- The three Act 2 stakes, on the zoom rows: 6-max may still
                -- be behind its catalog key here, but zoom is always open
                -- and these rows open with this very beat.
                { text = "The mid stakes are open now. Bring money.",
                  anchor = { "add_table:s004:zoom", "add_table:s005:zoom", "add_table:s006:zoom" } },
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
                  cue    = "Open the flyer",
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
                { text = "I didn't even know we had a table that big.{page}Not that it matters for you. Get as high as you want, you're never getting a multiplier above zero again.",
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

    -- Asides (controllers/StoryDirector):
    --   gift   the music is his to give. The intercom is silent until the
    --          first time he has NOTHING QUEUED after a beat ends (the
    --          opening's run of beats is over, the player is about to
    --          get the floor): he goes straight on into this line, and the
    --          click through it is the release — the jazz starts.
    --   music  the first beat he speaks after that opens with this line,
    --          once: the music has just cut under him.
    asides = {
        gift  = { text = "Play nice and I'll put something on for you. It seems to settle the others when they first get here.{page}Jazz." },
        music = { text = "One thing. I can't play the music and talk at the same time. One speaker.{page}Buy your own if you don't like it." },
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
