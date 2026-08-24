-- data/hints.lua
--
-- The "[i]" popups: the House explaining one small thing on its own
-- trigger. Pure data. Condition kinds are registered in
-- models/hint_rules.lua; the queue lives in controllers/HintController.lua;
-- rendering in views/HintView.lua. Copy is reviewed in docs/house-script.md
-- and transcribed here.
--
-- A popup is STATELESS. It never assumes where the story is: no trigger on
-- story progress (hint_seen, has_shoved, act unlocks, screen visits) and
-- nothing in the text about runs, resets or acts. Anything that needs the
-- player to have been told something first is a story beat
-- (data/story.lua), which has an order. The audit harness enforces this.
--
-- List order = priority: the first unseen hint whose `trigger` passes
-- becomes active; only one sticky hint shows at a time (queue hints
-- accumulate independently). While a story beat is running, nothing here
-- fires.
--
-- Fields:
--   id      unique slug; keys the persisted state.hints_seen set
--   title   short label for the help-desk list (views/HintLogPanel);
--           {icon} markers render there too
--   anchor  AnchorRegistry name to highlight, or a LIST of names (the
--           bubble hangs off the first one on screen). A hint with no
--           fresh anchor hides until a target widget draws again.
--   text    bubble copy; {icon} markers render live glyphs. A LIST of
--           strings renders as separate paragraphs.
--   trigger condition table.
--   done    STICKY ONLY. Completes the hint (the advance-on-action).
--   retire  condition table. If it ALREADY passes when the hint would first
--           fire, the hint is marked seen WITHOUT showing. Must be evidence
--           the player is past THIS LESSON (the counter that tracks the
--           concept), never a shove count: quickReset bumps shove_count.
--   sticky  instructions: highlight + bubble stay up until `done` or a
--           bubble click. One at a time. Non-sticky hints join the
--           hoverable [i] queue and never steal focus.
--
-- Copy rules: no em-dashes, {chip} never the word, cut filler.

return {

    -- ── First minutes ─────────────────────────────────────────────────

    -- ONE hint for the whole per-table readout. Per-table anchors list
    -- several indices; only the readouts of tables actually open light up.
    {
        id     = "table_stats",
        title  = "Table stats",
        anchor = { "ev:1", "ev:2", "ev:3", "ev:4" },
        text   = {
            "Hands come in four sizes.",
            "wins  {w:small} {w:medium} {w:large} {w:stack}",
            "losses  {l:small} {l:medium} {l:large} {l:stack}",
            "$/h is what a table makes you per hand. The gold {w:stack} % is your shot at a whole stack. Hover for the math.",
        },
        trigger = { kind = "hands_played", min = 5 },
        retire  = { kind = "hands_played", min = 20 },
    },

    {
        id     = "help_exists",
        title  = "The help desk",
        anchor = "btn:help",
        text   = "Missed something I said? It's all at the help desk, any time.",
        trigger = { kind = "hands_played", min = 18 },
        retire  = { kind = "hands_played", min = 35 },
    },

    -- ── The earning loop ──────────────────────────────────────────────

    {
        id     = "tied_up",
        title  = "Tied up money",
        anchor = { "cell:tied", "btn:cash_out",
                   "tied:1", "tied:2", "tied:3", "tied:4" },
        text   = "Short on cash? Most of it's sitting on your tables, still in play. CASH OUT or close one to get it back.",
        trigger = { kind = "all",
                    { kind = "tables_open", min = 1 },
                    { kind = "tied_up",     min = 0.01 },
                    { kind = "not", { kind = "can_afford_stake", stake = "s001" } } },
        -- No retire: the trigger IS a live failure state, and hints_seen
        -- already stops a second showing.
    },

    {
        id     = "stake_ladder",
        title  = "Higher stakes",
        anchor = "add_table:s002:six_max",
        text   = "NL10's open. Ten times the money, but the players are better. Worth an upgrade or two first.",
        trigger = { kind = "can_afford_stake", stake = "s002" },
        retire  = { kind = "any",
                    { kind = "stake_table_open", stake = "s002" },
                    { kind = "highest_stake_idx", min = 2 } },
    },

    -- ── Overload and failure ──────────────────────────────────────────

    {
        id     = "focus_overload",
        title  = "Focus",
        anchor = { "cell:focus", "buy_runup_focus" },
        text   = "That's a lot of tables. You're playing all of them a bit worse. Close one, or grab Focus.",
        trigger = { kind = "focus_overloaded" },
    },

    -- The only sticky left: an instruction with a button to press.
    {
        id     = "quick_reset",
        title  = "Quick reset",
        anchor = "btn:quick_reset",
        sticky = true,
        text   = "Stuck? Happens. Free reset to two dollars, and your {chip} come with you.",
        trigger = { kind = "can_quick_reset" },
        done    = { kind = "not", { kind = "can_quick_reset" } },
    },

    -- ── {chip} ────────────────────────────────────────────────────────

    {
        id     = "chip_denied",
        title  = "{chip} denied",
        anchor = "chip_badge:banked",
        text   = "That table's already paid its {chip}. Try a different stake or a different game.",
        trigger = { kind = "total_denied_stacks", min = 1 },
        -- Legacy filter only: the trigger fires at the first denial, so
        -- reaching five unseen means a save that predates this hint.
        retire  = { kind = "total_denied_stacks", min = 5 },
    },

    -- ── First contact with a system ───────────────────────────────────

    {
        id     = "rebuy",
        title  = "Rebuying a table",
        anchor = "rebuy:any",
        text   = "Empty, not gone. REBUY puts a fresh stack on it.",
        trigger = { kind = "any_table_busted" },
        retire  = { kind = "total_rebuys", min = 1 },
    },

    {
        id     = "gtype_hu",
        title  = "Heads-Up",
        anchor = "gtype:hu",
        text   = "Heads-up: one opponent. You'll win fewer hands, and the pots run deep both ways.",
        trigger = { kind = "gtype_table_open", gtype = "hu" },
    },

    {
        id     = "gtype_zoom",
        title  = "Zoom",
        anchor = "gtype:zoom",
        text   = "Zoom deals you a new table every hand. More wins, smaller ones.",
        trigger = { kind = "gtype_table_open", gtype = "zoom" },
    },

    {
        id     = "gtype_mtt",
        title  = "Tournaments",
        anchor = "gtype:mtt",
        text   = "A tournament: one buy-in, no rebuy, eight seats, ten blinds each, and it deals itself. Top three cash. Win it outright for the {chip}.",
        trigger = { kind = "gtype_table_open", gtype = "mtt" },
    },

    {
        id     = "cursor_swarm",
        title  = "The cursors",
        anchor = { "buy_runup_box_of_mice", "buy_runup_cursor_speed" },
        text   = "The cursors deal for you. More of them, and faster, in the sidebar. The D on a table stops them dealing there.",
        trigger = { kind = "owns_item", id = "cursor_pool" },
    },

    -- ── The shove felt ────────────────────────────────────────────────
    -- Reveal rule applies hardest here. Nothing may name a runout or a
    -- cheat before the player has seen one; the cheat hint gates on the
    -- card being ON the felt (cheat_dealt), not on any flag.

    {
        id     = "shove_pot_pile",
        title  = "The pot",
        anchor = "shove:pot",
        text   = "Everything you've got, in one pile. Here we go.",
        trigger = { kind = "all",
                    { kind = "screen", name = "shove" },
                    { kind = "shove_phase", phase = "buildup" } },
    },

    {
        id     = "shove_readout",
        title  = "Your odds",
        anchor = "shove:readout",
        text   = "BASE is your catalog. MULT is your money. The bar under them is your number. Keep an eye on it.",
        trigger = { kind = "all",
                    { kind = "screen", name = "shove" },
                    { kind = "shove_phase", phase = "running" } },
    },

    {
        id     = "shove_banked",
        title  = "What you keep",
        anchor = "shove:summary",
        text   = "BANKED is yours to keep. The all-in was everything else.",
        trigger = { kind = "shove_beat", id = "result" },
    },

    {
        id     = "shove_cheat_happened",
        title  = "The extra card",
        anchor = "shove:cheat_6",
        text   = "That card landed on your BASE and took it out of the count. The bar shows what's left. House rules. Plan around it.",
        trigger = { kind = "cheat_dealt", min = 1 },
    },

    -- ── The catalog ───────────────────────────────────────────────────

    {
        id     = "catalog_corruption",
        title  = "Corruption",
        anchor = "catalog:corrupt:first",
        text   = "Things you own can be corrupted for {achip}. Corrupted ones do far worse things.",
        trigger = { kind = "all",
                    { kind = "catalog_open" },
                    { kind = "anti_chips", min = 1 } },
    },

    -- ── Deck select ───────────────────────────────────────────────────

    {
        id     = "deck_xp",
        title  = "Deck XP",
        anchor = "deck:xp",
        text   = "The bar fills as the deck plays. Full bar, next level, better bonus.",
        trigger = { kind = "deck_select_open" },
    },

    -- ── The room ──────────────────────────────────────────────────────

    {
        id     = "room_what",
        title  = "Your room",
        anchor = "room:play",
        text   = "Everything you buy ends up in here. PLAY takes you back to the tables.",
        trigger = { kind = "screen", name = "room" },
    },

}
