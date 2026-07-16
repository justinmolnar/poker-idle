-- data/hints.lua
--
-- Contextual tutorial hints (the captor teaching you to play). Pure data —
-- condition kinds are registered in models/hint_rules.lua; the queue lives
-- in controllers/HintController.lua; rendering in views/HintView.lua.
-- Full teaching plan: docs/tutorial-teaching-list.md; per-hint reference
-- with review notes: docs/hints-reference.md.
--
-- List order = priority: the first unseen hint whose `trigger` passes
-- becomes active; only one sticky hint shows at a time (queue hints
-- accumulate independently).
--
-- Fields:
--   id      unique slug; keys the persisted state.hints_seen set
--   title   short label for the help-desk list (views/HintLogPanel);
--           {icon} markers render there too
--   anchor  AnchorRegistry name to highlight — or a LIST of names to
--           highlight several widgets at once (the bubble hangs off the
--           first one that's on screen). Views register these rects
--           during draw; a hint with no fresh anchor hides until a
--           target widget draws again.
--   text    bubble copy, captor voice; {icon} markers render live glyphs.
--           A LIST of strings renders as separate paragraphs — use it to
--           keep glyph legend rows off the prose lines
--   trigger condition table — hint fires when this passes
--   done    condition table. For a sticky hint: completes it (that's the
--           advance-on-action). For any hint that hasn't fired yet: if it
--           ALREADY passes at scan time the hint retires silently — how
--           old saves and post-shove veterans skip the early teaching
--           without a migration. Queued info hints are exempt: once in
--           the queue, only clicking the [i] clears them.
--   sticky  instructions ("open a table"): highlight + bubble stay up until
--           the done-condition or a bubble click. One at a time.
--           Non-sticky hints are FYIs: they join the hoverable [i] queue
--           instead and never steal focus.
--
-- Conditions: { kind = "...", ... } — kinds live in models/hint_rules.lua.
-- Numeric kinds compare with inclusive `min` / `max`. `all` / `any` /
-- `not` compose sub-conditions from their array part.

local Constants = require("data.constants")

return {

    -- ── Phase 1: first minutes (empty room → first money) ─────────────

    {
        id     = "first_table",
        title  = "Open a table",
        anchor = "add_table:s001:six_max",
        sticky = true,
        text   = "Thanks for your participation, open a table.",
        trigger = { kind = "all",
                    { kind = "tables_open",  max = 0 },
                    { kind = "shoves",       max = 0 },
                    { kind = "hands_played", max = 0 } },
        done    = { kind = "tables_open", min = 1 },
    },

    -- Hovering is the game's whole self-documentation layer — teach the
    -- gesture itself, early, by lighting hoverable surfaces in all four
    -- screen regions at once (table readout, top bar, both sidebars).
    {
        id     = "hover_things",
        title  = "Hover for details",
        anchor = { "ev:1", "cell:tied", "add_table:s001:six_max",
                   "buy_runup_sharper_reads" },
        text   = "Hover anything for details. Stats, buttons, upgrades: everything explains itself.",
        trigger = { kind = "hands_played", min = 2 },
        done    = { kind = "hands_played", min = 15 },
    },

    -- ONE hint for the whole per-table readout: outcome sizes, the $/h
    -- average, and the gold {w:stack} % — split across three hints these
    -- stacked up around hand 8 all pointing at the same row. Per-table
    -- anchors list several indices; only the readouts of tables actually
    -- open (and roomy enough to show one) light up.
    {
        id     = "table_stats",
        title  = "Table stats",
        anchor = { "ev:1", "ev:2", "ev:3", "ev:4" },
        text   = {
            "Hands land in four sizes:",
            "wins  {w:small} {w:medium} {w:large} {w:stack}",
            "losses  {l:small} {l:medium} {l:large} {l:stack}",
            "$/h is the table's average per hand. The gold {w:stack} % is your chance at a {w:stack} per hand.",
            "Hover for the math.",
        },
        trigger = { kind = "hands_played", min = 5 },
        done    = { kind = "hands_played", min = 20 },
    },

    {
        id     = "help_exists",
        title  = "The help desk",
        anchor = "btn:help",
        text   = "Visit the help desk to view all previous hints.",
        trigger = { kind = "hands_played", min = 18 },
        done    = { kind = "hands_played", min = 35 },
    },

    -- ── Phase 2: the earning loop ──────────────────────────────────────

    {
        id     = "run_upgrades",
        title  = "Run upgrades",
        anchor = "buy_runup_sharper_reads",
        sticky = true,
        text   = "You can afford an upgrade. They reset every run, and pay for themselves.",
        trigger = { kind = "all",
                    { kind = "run_upgrades_owned",     max = 0 },
                    { kind = "can_afford_run_upgrade", id = "sharper_reads" } },
        done    = { kind = "run_upgrades_owned", min = 1 },
    },

    {
        id     = "multi_table",
        title  = "Multi-tabling",
        anchor = "add_table:s001:six_max",
        text   = "Open another table to double the speed you can play hands.",
        -- If they can afford it, tell them — no hand-count floor.
        trigger = { kind = "all",
                    { kind = "tables_open",      min = 1, max = 1 },
                    { kind = "can_afford_stake", stake = "s001" } },
        done    = { kind = "tables_open", min = 2 },
    },

    {
        id     = "tied_up",
        title  = "Tied up money",
        anchor = { "cell:tied", "btn:cash_out",
                   "tied:1", "tied:2", "tied:3", "tied:4" },
        text   = {
            "Short on cash? Most of it is TIED UP in your tables, still in play.",
            "CASH OUT or close a table to take it back.",
        },
        trigger = { kind = "all",
                    { kind = "tables_open", min = 1 },
                    { kind = "tied_up",     min = 0.01 },
                    { kind = "not", { kind = "can_afford_stake", stake = "s001" } } },
        done    = { kind = "shoves", min = 1 },
    },

    {
        id     = "stake_ladder",
        title  = "Higher stakes",
        anchor = "add_table:s002:six_max",
        text   = {
            "NL10 is open. 10x the potential winnings but be warned, the opponents only get harder to beat.",
            "Upgrade to increase your edge.",
        },
        trigger = { kind = "can_afford_stake", stake = "s002" },
        done    = { kind = "any",
                    { kind = "stake_table_open", stake = "s002" },
                    { kind = "shoves", min = 1 } },
    },

    -- ── Phase 3: overload and failure ──────────────────────────────────

    {
        id     = "focus_overload",
        title  = "Focus",
        anchor = { "cell:focus", "buy_runup_focus" },
        text   = {
            "You can't focus on this many tables.",
            "Close one, buy the Focus upgrade, or suffer a penalty to ALL tables.",
        },
        trigger = { kind = "focus_overloaded" },
        done    = { kind = "shoves", min = 1 },
    },

    {
        id     = "quick_reset",
        title  = "Quick reset",
        anchor = "btn:quick_reset",
        sticky = true,
        text   = "Bricked? The house is merciful. Free reset to $2; your {chip} ride along.",
        trigger = { kind = "can_quick_reset" },
        done    = { kind = "not", { kind = "can_quick_reset" } },
    },

    -- ── Phase 4: gold chips and the shove ──────────────────────────────

    -- The chip hints point at the "+N {chip}" badges: the banked
    -- add-table button's badge (gold trim marks it) and the running
    -- pile on the (still locked) SHOVE button. The top-bar chip count
    -- is banked-meta currency and stays hidden until the first shove.
    {
        id     = "first_chip",
        title  = "Banking {chip}",
        anchor = { "chip_badge:banked", "chip_badge:shove" },
        text   = {
            "A {w:stack} win banked your first {chip}.",
            "Once per table type each run (DIVERSIFY); gold trim marks the ones that paid.",
        },
        trigger = { kind = "chips_this_run", min = 1 },
        done    = { kind = "shoves", min = 1 },
    },

    {
        id     = "chip_denied",
        title  = "{chip} denied",
        anchor = { "chip_badge:banked", "chip_badge:shove" },
        text   = "That table already paid its {chip} this run. Other stakes and types can still payout, this one cannot.",
        trigger = { kind = "total_denied_stacks", min = 1 },
        done    = { kind = "shoves", min = 1 },
    },

    -- Fires the moment the SHOVE button first enables — the same
    -- threshold gates the button (GrindController:shoveUnlocked reads
    -- GAMEPLAY.SHOVE_UNLOCK_CHIPS), so trigger and reveal stay in sync.
    -- Deliberately a queue hint with no-pressure copy: unlocking the
    -- shove must not read as an instruction to use it.
    {
        id     = "shove_ready",
        title  = "The SHOVE",
        anchor = "btn:shove",
        text   = {
            "SHOVE has unlocked.",
            "It bets everything on one hand and ends the run. Win or lose, your {chip} stay yours to spend.",
            "No rush.",
        },
        trigger = { kind = "chips_this_run",
                    min = Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS },
        done    = { kind = "shoves", min = 1 },
    },

    {
        id     = "shove_pct",
        title  = "SHOVE %",
        anchor = "cell:shove",
        text   = {
            "Your SHOVE % has two parts: catalog upgrades set the base, your total money multiplies it.",
            "Hover for the math.",
        },
        trigger = { kind = "all",
                    { kind = "shoves",        min = 1 },
                    { kind = "bankroll_tier", min = 3 } },
        done    = { kind = "shoves", min = 2 },
    },

    -- ── Phase 5: post-shove meta ───────────────────────────────────────
    -- (The catalog first-visit callout lives inside CatalogModal;
    -- seen-flag hints_seen["catalog_intro"], set by ShoveState.)

    {
        id     = "two_currencies",
        title  = "Two currencies",
        anchor = { "buy_runup_sharper_reads", "btn:catalog" },
        text   = "Sidebar upgrades reset each run, items from the catalog don't (view them with the catalog button).",
        trigger = { kind = "all",
                    { kind = "shoves",             min = 1 },
                    { kind = "run_upgrades_owned", max = 0 } },
        done    = { kind = "run_upgrades_owned", min = 1 },
    },

}
