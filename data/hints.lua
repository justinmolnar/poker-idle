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
--   done    STICKY ONLY. Completes the hint (the advance-on-action).
--           Never consulted for an info hint, which has no completion.
--   retire  condition table. If it ALREADY passes when the hint would first
--           fire, the hint is marked seen WITHOUT showing: how a save that
--           predates the hint system skips teaching it does not need.
--
--           These were one field, and the overload was a bug. A retire
--           predicate must be evidence the player is past THIS LESSON.
--           `shoves >= 1` was used for six hints and is evidence of
--           nothing: it reads shove_count, which resetRun bumps, and
--           quickReset routes through resetRun. So pressing the free
--           rescue button retired six of fifteen hints, including the one
--           that explains what SHOVE is. Reach for the counter that tracks
--           the concept (total_denied_stacks for the denial rule,
--           total_chips_banked for the first bounty), or for nothing at
--           all: hints_seen already stops a hint firing twice, so a hint
--           whose trigger is a live mistake wants no retire predicate.
--
--           Queued info hints are exempt: once in the queue, only clicking
--           the [i] clears them.
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
        retire  = { kind = "hands_played", min = 15 },
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
        retire  = { kind = "hands_played", min = 20 },
    },

    {
        id     = "help_exists",
        title  = "The help desk",
        anchor = "btn:help",
        text   = "Visit the help desk to view all previous hints.",
        trigger = { kind = "hands_played", min = 18 },
        retire  = { kind = "hands_played", min = 35 },
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
        retire  = { kind = "tables_open", min = 2 },
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
        -- No retire predicate. The trigger IS a live failure state (short on
        -- cash with money still on the tables), so a player meeting it for the
        -- first time in hour six needs the lesson exactly as much as one
        -- meeting it in minute six. hints_seen already stops a second showing.
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
        retire  = { kind = "any",
                    { kind = "stake_table_open", stake = "s002" },
                    -- Having sat at NL10 or above is the evidence; a shove
                    -- count is not.
                    { kind = "highest_stake_idx", min = 2 } },
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
        -- No retire predicate, same reasoning as tied_up: overloading is a
        -- correctable mistake and teaching it belongs at the first one,
        -- whenever that happens.
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
        -- The copy says "your first {chip}", so it must not greet a player
        -- who already has a bounty history. Lifetime and monotonic: a real
        -- first-timer cannot reach 3 before the trigger fires at 1.
        retire  = { kind = "total_chips_banked", min = 3 },
    },

    {
        id     = "chip_denied",
        title  = "{chip} denied",
        anchor = { "chip_badge:banked", "chip_badge:shove" },
        text   = "That table already paid its {chip} this run. Other stakes and types can still payout, this one cannot.",
        trigger = { kind = "total_denied_stacks", min = 1 },
        -- Legacy filter only: the trigger fires at the first denial, so
        -- reaching five unseen means a save that predates this hint.
        retire  = { kind = "total_denied_stacks", min = 5 },
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
        -- has_shoved, NOT shoves: quickReset bumps shove_count without the
        -- player ever shoving, and this is the hint that explains what
        -- SHOVE is. Retiring it for someone who pressed the rescue button
        -- is how the button ate the tutorial.
        retire  = { kind = "has_shoved" },
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
                    { kind = "has_shoved" },
                    { kind = "bankroll_tier", min = 3 } },
        retire  = { kind = "has_shoved" },
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
                    { kind = "has_shoved" },
                    { kind = "run_upgrades_owned", max = 0 } },
        retire  = { kind = "run_upgrades_owned", min = 1 },
    },

    -- ── Phase 6: Act 2 ─────────────────────────────────────────────────
    -- Everything from here down fires after the first gauntlet win. These
    -- are APPENDED, never inserted: list order is priority, and putting an
    -- Act 2 hint above an Act 1 hint would let it take the sticky slot from
    -- a player who still needs the basics.
    --
    -- Act 2 and Act 3 hints chain on hint_seen of their predecessor. Only
    -- one queued hint is previewable at a time (views/HintView), so an
    -- unstaggered burst buries the later ones behind a count badge.

    {
        id     = "deck_rack",
        title  = "The deck rack",
        anchor = "cell:deck",
        text   = {
            "Your deck sits in the rack. It levels as you play and its bonus applies every hand.",
            "Only the active deck earns XP. Every deck you have unlocked keeps paying.",
        },
        trigger = { kind = "deck_system_unlocked" },
    },

    {
        id     = "mid_stakes",
        title  = "Mid stakes",
        anchor = { "add_table:s004:six_max", "add_table:s005:six_max",
                   "add_table:s006:six_max" },
        text   = "NL1K and above are open. The buy-ins are brutal and so are the opponents.",
        trigger = { kind = "all",
                    { kind = "act2_unlocked" },
                    { kind = "hint_seen", hint = "deck_rack" } },
        retire  = { kind = "highest_stake_idx", min = 4 },
    },

    -- The R2 wall, named. The dealer's first cheat buries the catalog base,
    -- so the deck base is the only term left holding up runout 2 -- and it
    -- is zero until the master deck exists. Without this the player shoves
    -- into a mathematically impossible runout forever with no stated way out.
    {
        id     = "master_deck",
        title  = "Beating runout 2",
        anchor = { "cell:deck", "cell:shove" },
        text   = {
            "The second runout does not count your catalog. Only your decks.",
            "Max five decks and The Master joins the rack. That is the run that beats it.",
        },
        trigger = { kind = "all",
                    { kind = "act2_unlocked" },
                    { kind = "hint_seen", hint = "deck_rack" },
                    { kind = "decks_maxed_count", max = 4 } },
        retire  = { kind = "decks_maxed_count", min = 5 },
    },

    -- ── Phase 6: first contact with a system ───────────────────────────
    -- Specced in docs/tutorial-teaching-list.md and never built. Each fires
    -- the first time the player actually meets the thing, not on a timer.

    {
        id     = "rebuy",
        title  = "Rebuying a table",
        anchor = "rebuy:any",
        text   = "That table is empty, not gone. REBUY puts a fresh stack on it.",
        trigger = { kind = "any_table_busted" },
        retire  = { kind = "total_rebuys", min = 1 },
    },

    {
        id     = "gtype_hu",
        title  = "Heads-Up",
        anchor = "gtype:hu",
        text   = "Heads-Up is one opponent. You win fewer hands, and the pots run deep both ways.",
        trigger = { kind = "gtype_table_open", gtype = "hu" },
    },

    {
        id     = "gtype_zoom",
        title  = "Zoom",
        anchor = "gtype:zoom",
        text   = "Zoom deals fast against a new table every hand. You win more often, for less.",
        trigger = { kind = "gtype_table_open", gtype = "zoom" },
    },

    {
        id     = "gtype_mtt",
        title  = "Tournaments",
        anchor = "gtype:mtt",
        text   = {
            "A tournament is one buy-in and no rebuy. Eight seats, ten big blinds each, hands deal themselves.",
            "Seats bust at zero. Finish top three to cash, win it outright for the {chip}.",
        },
        trigger = { kind = "gtype_table_open", gtype = "mtt" },
    },

    -- The cursor swarm arrives as a whole interface: cursors on the felt,
    -- two new sidebar upgrades, and per-table D / R toggles. None of it was
    -- ever announced.
    {
        id     = "cursor_swarm",
        title  = "The cursors",
        anchor = { "buy_runup_box_of_mice", "buy_runup_cursor_speed" },
        text   = {
            "The cursors deal for you. Buy more of them, and make them faster, in the sidebar.",
            "The D toggle on a table stops them dealing there.",
        },
        trigger = { kind = "owns_item", id = "cursor_pool" },
    },

    -- ── Phase 6: Act 3 ─────────────────────────────────────────────────
    -- The act break itself (the multiplier is gone) is the prestige modal's
    -- job -- it is a rules change the player cannot discover. These four are
    -- the consequences, taught on first contact and chained on hint_seen so
    -- they arrive one at a time.

    -- The Act 1 rule inverted. {chip} come from winning a stack; {achip}
    -- come from LOSING one. Nothing else in the game pays you for a loss.
    {
        id     = "anti_chips",
        title  = "Losing pays",
        anchor = "cell:achips",
        text   = {
            "Losing a stack at the top tiers pays {achip}.",
            "Once per table type each run, same as the gold ones. The house calls it compensation.",
        },
        trigger = { kind = "anti_chips_this_run", min = 1 },
    },

    -- Without this the high band reads as broken difficulty rather than as
    -- the faucet it is: naked win chance at T7+ is a rounding error BY
    -- DESIGN, because the whole point is to lose there on purpose.
    {
        id     = "high_stakes_farm",
        title  = "The top tiers",
        anchor = { "add_table:s007:six_max", "add_table:s008:six_max",
                   "add_table:s009:six_max" },
        text   = {
            "You are not meant to beat these tables.",
            "Sit down, lose stacks, collect {achip}. That is the whole play now.",
        },
        trigger = { kind = "all",
                    { kind = "act3_unlocked" },
                    { kind = "stake_band_table_open", band = "high" } },
    },

    {
        id     = "corruption",
        title  = "Corrupting the catalog",
        anchor = "btn:catalog",
        text   = "Spend {achip} in the catalog to corrupt what you already own. Corrupted items do far worse things.",
        trigger = { kind = "all",
                    { kind = "anti_chips", min = 2 },
                    { kind = "hint_seen", hint = "anti_chips" } },
        retire  = { kind = "corrupted_count", min = 1 },
    },

    -- The way out. Bankroll cannot go negative before Act 3, so this can
    -- only fire once the Ultra stake is bleeding it.
    {
        id     = "underflow",
        title  = "Breaking the count",
        anchor = "cell:underflow",
        text   = {
            "Your multiplier is zero and money cannot raise it.",
            "But the house counts your bankroll in a box with a bottom. Lose enough and it falls out the other side.",
        },
        trigger = { kind = "all",
                    { kind = "act3_unlocked" },
                    { kind = "bankroll", max = -1 } },
    },

}
