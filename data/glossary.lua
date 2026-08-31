-- data/glossary.lua
--
-- The glossary behind THE HOUSE poster: reference cards for everything
-- the House has taught. Pure data.
--
-- EXPOSURE IS THE STORY. An entry appears once its `beat` has played
-- (state.story_seen) — the beats teach, the glossary remembers. There is
-- no other unlock path: no triggers, no counters, no queue. A term the
-- player hasn't been taught shows as a "???" row (the same
-- visible-but-blank promise the locked game-type tabs make).
--
-- Fields:
--   id    unique slug
--   term  the row label; {icon} markers render
--   beat  data/story.lua beat id whose playing exposes this entry
--   text  reference copy; a LIST renders as separate paragraphs. Fuller
--         than the beat's spoken line is fine — this is the written-down
--         version. Copy rules as everywhere: no em-dashes, {chip} never
--         the word, cut filler.
--
-- List order = display order.

return {

    -- ── The felt ─────────────────────────────────────────────────────
    {
        id   = "zoom",
        term = "Zoom",
        beat = "arrival",
        text = "Deals you a new table every hand. More wins, smaller ones, and it never holds you up. My busiest room.",
    },
    {
        id   = "pot_sizes",
        term = "Pot sizes",
        beat = "first_chip",
        text = {
            "Hands come in four sizes, both ways.",
            "wins  {w:small} {w:medium} {w:large} {w:stack}",
            "losses  {l:small} {l:medium} {l:large} {l:stack}",
            "The readout under a table shows what it makes per hour and its odds per size. Hover it for the math.",
        },
    },
    {
        id   = "run_upgrades",
        term = "Run upgrades",
        beat = "sharper_reads",
        text = "The rack on the right. They make you better at the tables, and they only last the run.",
    },
    {
        id   = "heads_up",
        term = "Heads-Up",
        beat = "second_table",
        text = "One opponent. You win fewer hands, and the pots run deep both ways: whole stacks move, in and out. It's where the {chip} come from.",
    },
    {
        id   = "six_max",
        term = "6-Max",
        beat = "six_max_open",
        text = "The long game. Five stacks on the table, slow hands, and the fattest pots in the room when one finally lands. Opened by the Bonsai in the catalog.",
    },
    {
        id   = "tournaments",
        term = "Tournaments",
        beat = "first_tournament",
        text = "One buy-in, no rebuy. Eight seats sit down with ten blinds each and it deals itself. Top three cash; win it outright for the {chip}.",
    },
    {
        id   = "stakes",
        term = "Stakes",
        beat = "stake_ladder",
        text = "Each rung is ten times the money of the last, against better players. Higher rungs open as you prove out. I set the rungs myself.",
    },

    -- ── The money ────────────────────────────────────────────────────
    {
        id   = "chips",
        term = "{chip}",
        beat = "first_chip",
        text = "The gold one. A table pays one the first time it wins a whole stack each run. They survive everything: resets, shoves, all of it. Spend them in the catalog. Weighed and counted.",
    },
    {
        id   = "stack_odds",
        term = "Stack odds",
        beat = "first_chip",
        text = "The gold {w:stack} number under a table is its shot at winning a whole stack on any hand. Heads-Up runs high. Zoom runs low.",
    },
    {
        id   = "bounty_rule",
        term = "One bounty per table",
        beat = "chip_denied",
        text = "Each stake and game pays its {chip} once per run. After that the table still makes money, just no more gold. Climb, or reset. It's all in the ledger.",
    },
    {
        id   = "tied_up",
        term = "Tied up money",
        beat = "arrival",
        text = "Buy-ins go onto the felt. Money on your tables is still yours, just in play. CASH OUT or close a table to pull it back.",
    },
    {
        id   = "payouts",
        term = "Payouts",
        beat = "first_payout",
        text = "Wins land on the table's stack first, up to its buy-in. Anything past full spills into your bankroll. Losses come off the stack the same way. I don't touch the spill.",
    },
    {
        id   = "rebuy",
        term = "Rebuy",
        beat = "first_bust",
        text = "An empty table isn't gone. REBUY puts a fresh stack on it for the buy-in. The seat stays warm.",
    },
    {
        id   = "focus",
        term = "Focus",
        beat = "focus_overload",
        text = "Run more tables than you can watch and you play all of them a bit worse. Close one, or raise your Focus in the sidebar. I count your tables too.",
    },

    -- ── The door ─────────────────────────────────────────────────────
    {
        id   = "the_shove",
        term = "The shove",
        beat = "the_pitch",
        text = "One hand, everything you've got on it. Win and you walk out with the lot. Lose and you keep your {chip}. Either way the tables reset to two dollars. I never miss one.",
    },
    {
        id   = "shove_readout",
        term = "The shove readout",
        beat = "shove_walkthrough",
        text = "ITEMS is how many things you own. BANK is your money. The bar under them is your number on the big hand.",
    },
    {
        id   = "banked",
        term = "Banked",
        beat = "shove_result",
        text = "What the shove can't touch. BANKED is yours to keep; the all-in was everything else. That column is yours.",
    },
    {
        id   = "house_rules",
        term = "The extra card",
        beat = "house_cheats",
        text = "Sometimes the House deals a card onto your ITEMS and takes them out of the count. The bar shows what's left. Plan around it.",
    },
    {
        id   = "runs",
        term = "Runs",
        beat = "the_loop",
        text = "Shove, reset to two dollars, go again. Run upgrades reset with it. The catalog and your {chip} don't. I reset the felt myself.",
    },

    -- ── The shop and the room ────────────────────────────────────────
    {
        id   = "the_catalog",
        term = "The catalog",
        beat = "first_catalog",
        text = "Everything in it is bought once with {chip} and kept forever. Stickered items aren't ready yet; the count says how close. Prices are final.",
    },
    {
        id   = "the_room",
        term = "Your room",
        beat = "the_room",
        text = "Everything you buy ends up in the room. PLAY takes you back to the tables. I dust.",
    },
    {
        id   = "cursors",
        term = "The cursors",
        beat = "first_cursors",
        text = "They deal for you. Buy more of them, and faster, in the sidebar. The D on a table's header stops them dealing there; R controls rebuys. Good workers.",
    },

    -- ── Act 2 and beyond ─────────────────────────────────────────────
    {
        id   = "decks",
        term = "Decks",
        beat = "act2_decks",
        text = "Picked before each run; only the deck counts on the second big hand. A deck levels as it plays. Full bar, next level, better bonus. I supply the cards.",
    },

    -- Corruption and {achip} have NO entries, deliberately: they are not
    -- his. He didn't put them in the book, he doesn't know what they do,
    -- and his records don't contain what isn't his. The weird text in the
    -- catalog is the only surface. Figure it out, or don't.
}
