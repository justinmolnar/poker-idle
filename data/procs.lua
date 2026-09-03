-- data/procs.lua
--
-- Every proc in the game: WHEN it fires, WHERE it lands, WHAT it does.
-- Pure data. A catalog item points at one of these by id
-- (`{ kind = "proc", proc = "ko_heater" }`) and the dispatch in
-- services/ProcRegistry does the rest, so adding a proc is an edit to
-- this file and the catalog — no controller code.
--
--   trigger  one of the keys GrindController fires:
--              on_jackpot_win, on_stack_loss, on_ko,
--              on_tournament_win, on_tournament_miss
--   target   { kind = "none" | "self" | "gtype" | "board_near" | "any_other",
--              radius, gtype, exclude_self, where, pick = "random", max }
--   payload  { kind = "apply_status" | "resolve_now" | "refund_buyin" | "ratchet", ... }
--   ghost    catalog item id whose sprite + sound plays when it fires
--   impact   false if this is not a blow. Procs land with the fist or the
--            shove by default, because most of them ARE one table doing
--            something to another. Set it false where the fiction is not
--            violence and you want only the ghost.
--
-- "Nearby" is the BOARD's geometry: Manhattan cell distance, so adjacent
-- means SHARING A SIDE — never diagonal, never "next in reading order
-- across a row break". The player aims these by dragging tables into
-- place. See models/table_procs (board_near).
--
-- ─── WHAT A HEATER OR A TILT IS ─────────────────────────────────────────
-- A punch, not a buff: the hand it lands in ends its way, and the next
-- hand goes the same way. That is the entire status (data/statuses.lua,
-- Table:interrupt). `magnitude` is inert on these two (tilt reads it for
-- the visual lean only) and `t` is just how long the glow/wash lingers —
-- so author heater/tilt sources as MOMENTS. A continuous source is a
-- design error: with interrupts it decides every hand, with
-- `no_interrupt` it does nothing.
--
-- ─── TUNING NOTE: KNOCKOUTS ARE FAST ────────────────────────────────────
-- A tournament runs ~18.3s a hand (sim/gtype_ev.lua, all scenarios) and
-- knocks out 2 seats naked, ~5 at full upgrades, 7 on a win: a knockout
-- every 30 to 60 seconds. Nothing may fire on all of them. Three KO items
-- owned at once would then buff three tables every few seconds, which is
-- not a proc, it is a permanent aura with a trigger drawn on it.
--
-- So every on_ko proc carries a `chance`, rolled once per event in
-- services/ProcRegistry before targeting. At ~45s between knockouts:
--   chance 0.20 -> something lands every ~4 min
--   chance 0.15 -> every ~5 min
--   chance 0.12 -> every ~6 min
-- Two tournaments overlapping shorten the gap but do not stack power
-- (statuses refresh, they don't add).
--
-- These rates were set when MTT ran ~3.4s a hand. It now runs ~18.3s.
-- Raise them here if the support kit needs to be felt more often; that is
-- one number per proc and nothing else.

return {

    -- Chunk 2's cascade, now expressed as data. A {stack} anywhere makes
    -- every Zoom table settle on the spot.
    zoom_cascade = {
        trigger = "on_jackpot_win",
        target  = { kind = "gtype", gtype = "zoom", exclude_self = true },
        payload = { kind = "resolve_now" },
        ghost   = "receipt_printer",
        -- Nobody is being hit. The printer runs and those hands finish;
        -- what you should see is the ghost and the tables settling.
        impact  = false,
    },

    -- The aura. A knockout heats a neighbouring table.
    ko_heater = {
        trigger = "on_ko",
        chance  = 0.20,
        target  = { kind = "board_near", radius = 2, pick = "random",
                    exclude_self = true },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 6,
                    -- Worth more the deeper the tournament runs: the last
                    -- knockout of a final table is the big one.
                    escalate = { field = "busted_total", per = 0.12 } },
        ghost   = "curved_monitor",
    },

    -- The enchant. Marks a neighbour's next pot for a tier bump.
    -- Tournaments are excluded: their hands come from a pre-rolled plan
    -- that deliberately caps filler pots, and bumping one busts seats the
    -- plan never scheduled.
    ko_bump = {
        trigger = "on_ko",
        chance  = 0.15,
        target  = { kind = "board_near", radius = 2, pick = "random",
                    exclude_self = true, where = { chip_stack_table = false } },
        payload = { kind = "apply_status", status = "marked",
                    magnitude = 1, charges = 1 },
        ghost   = "pc_tower",
    },

    -- The healer. A knockout sometimes buys back a neighbour's buy-in.
    ko_refund = {
        trigger = "on_ko",
        chance  = 0.12,
        target  = { kind = "board_near", radius = 1, pick = "random",
                    exclude_self = true, where = { chip_stack_table = false } },
        payload = { kind = "refund_buyin", chance = 1.0 },
        ghost   = "shredder",
    },

    -- The ratchet. Winning a tournament lifts every table for the rest of
    -- the run. Self-limiting: a tournament takes a while and costs a
    -- buy-in, so this needs no cap.
    tourney_ratchet = {
        trigger = "on_tournament_win",
        target  = { kind = "none" },
        payload = { kind = "ratchet", magnitude = 0.01,
                    effect = { kind = "win_chance_shift", mag_field = "amount" } },
        ghost   = "prize_vase",
    },

    -- ─── HU: the stacks ────────────────────────────────────────────────
    -- Nothing here says "Heads Up". It does not have to: a {stack} is a
    -- jackpot-tier hit, and HU reaches that tier several times more often
    -- than anything else, so an item that procs on stacks IS an HU item
    -- without ever naming one. Hang it on a 6-max and it is a lottery
    -- ticket; that is a real choice rather than a mistake.

    -- Dogs Playing Poker. Running hot after a big one, steaming after a
    -- cooler. Both halves are the same item because the swing is the point.
    stack_high = {
        trigger = "on_jackpot_win",
        chance  = 0.35,
        target  = { kind = "self" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "dogs_playing_poker",
        impact  = false,   -- it happens TO this table; nothing is thrown
    },
    stack_low = {
        trigger = "on_stack_loss",
        chance  = 0.35,
        target  = { kind = "self" },
        payload = { kind = "apply_status", status = "tilt",
                    magnitude = 0.35, t = 6 },
        ghost   = "dogs_playing_poker",
        impact  = false,
    },

    -- Gaming Chair. The good run spreads to the table beside it.
    stack_spread = {
        trigger = "on_jackpot_win",
        chance  = 0.30,
        target  = { kind = "board_near", radius = 1, pick = "random",
                    exclude_self = true },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "gaming_chair",
    },

    -- ─── Zoom: the count ───────────────────────────────────────────────
    -- Same trick. A counter says nothing about Zoom, but at roughly six
    -- times the hands per hour of anything else, Zoom is what fills one.
    -- `every` is checked against a running total carried on the event, so
    -- these survive a reload without storing a tally.

    -- Wall Clock.
    century = {
        trigger = "on_hand_won",
        every   = 100,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "wall_clock",
    },

    -- Framed Diploma. A thousand hands is a long haul, so it pays into the
    -- run rather than into a moment: the shift is permanent until reset,
    -- and it stacks with every thousand after it.
    millennium = {
        trigger = "on_hand_won",
        every   = 1000,
        target  = { kind = "gtype", gtype = "zoom" },
        payload = { kind = "apply_status", status = "sharp",
                    magnitude = 0.005 },
        ghost   = "diploma",
        impact  = false,
    },

    -- The Diploma's other half. "For the run" has to include zoom tables
    -- opened AFTER a firing, so each firing also banks its magnitude at
    -- run level; GrindController:addTable pays the bank out to every zoom
    -- table opened later. Same trigger and `every`, both counted off the
    -- event's own running total, so the two halves cannot drift apart.
    millennium_bank = {
        trigger = "on_hand_won",
        every   = 1000,
        target  = { kind = "none" },
        payload = { kind = "bank", field = "zoom_sharp_banked",
                    magnitude = 0.005 },
        ghost   = nil,     -- the visible half already pops the sprite
        impact  = false,
    },

    -- ─── Rung one: the first procs a player meets ───────────────────────
    -- Deliberately small vocabulary: one trigger, one landing, no
    -- conversions. These teach "items fire on moments" and "moments can
    -- land on OTHER tables" before any engine item builds on that.

    -- Energy Drink. THE ZOOM ITEM and the first heater in the game: every
    -- 250 hands dealt anywhere, a table catches a heater. A global
    -- counter (event.count = state.total_hands_played, lifetime, like
    -- century), so Zoom's volume is what makes it fire. `every` is the
    -- only tuning knob. (Heat itself is taught by story first_heat, which
    -- fires on the first heater from any source.)
    caffeine = {
        trigger = "on_hand_played",
        every   = 250,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "energy_drink",
    },
    caffeine_corrupt = {
        trigger = "on_hand_played",
        every   = 100,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "energy_drink",
    },

    -- House Cat. Every 50 hands won, a table's NEXT WIN reads a tier
    -- higher. Wins only: a plain one-shot flag on the table
    -- (Table._next_win_tier_up), consumed by its next winning hand — not
    -- a status, nothing to name. The gentlest possible cross-table proc.
    cat_nap = {
        trigger = "on_hand_won",
        every   = 50,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "next_win_tier_up" },
        ghost   = "house_cat",
        impact  = false,
    },
    cat_nap_corrupt = {
        trigger = "on_hand_won",
        every   = 25,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "next_win_tier_up" },
        ghost   = "house_cat",
        impact  = false,
    },

    -- Candle. A {stack} anywhere spreads the warmth: sometimes a random
    -- table catches a heater. First taste of "jackpots ripple outward".
    candle_flame = {
        trigger = "on_jackpot_win",
        chance  = 0.35,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 6 },
        ghost   = "candle",
    },

    -- ─── The mental game ────────────────────────────────────────────────

    -- Cool Towel. A {stack} settles the nerves: every tilt on the board
    -- wipes off. The active half of the tilt counterplay (Dish Soap's
    -- tilt_resist_chance is the passive half, and its prerequisite).
    towel_cleanse = {
        trigger = "on_jackpot_win",
        target  = { kind = "none" },
        payload = { kind = "cleanse" },
        ghost   = "cool_towel",
        impact  = false,
    },

    -- Waste Basket. Take the beat, throw it away: when a tilt's forced
    -- loss finishes running its course (on_tilt_spent, Table:_finalizeHand)
    -- the table heats — anger into focus. The conversion build's first
    -- rung, and the decision that makes owning the Cool Towel interesting:
    -- cleansing a tilt early forfeits this payoff.
    tilt_burnout = {
        trigger = "on_tilt_spent",
        target  = { kind = "self" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 4 },
        ghost   = "waste_basket",
        impact  = false,
    },

    -- ─── Automation crossover ───────────────────────────────────────────

    -- Cleaning Robot. A {stack} anywhere and the swarm goes into
    -- overdrive: cursors travel double speed for a while. Nobody knows
    -- why it speeds up. It knows.
    robot_overdrive = {
        trigger = "on_jackpot_win",
        target  = { kind = "none" },
        payload = { kind = "timed_buff", buff = "cursor_speed_mult",
                    value = 2.0, t = 10 },
        ghost   = "cleaning_robot",
        impact  = false,
    },

    -- ─── MTT: the sustain ──────────────────────────────────────────────

    -- First Aid Kit. A knockout occasionally hands back the price of the
    -- most expensive seat you are sitting in, which makes the tournament
    -- quietly pay for the rest of the board.
    ko_biggest = {
        trigger = "on_ko",
        chance  = 0.10,
        target  = { kind = "none" },
        payload = { kind = "pay_biggest_buyin" },
        ghost   = "first_aid_kit",
    },

    -- High Roller Pass is no longer a proc: heat became interrupt-only, so
    -- its continuous aura shape had nothing left to be. It is now the
    -- `tourney_backing` effect (data/effects.lua) — win chance per
    -- tournament finish, derived from the open tournament tables in
    -- GrindController:invalidateEffects.

    -- ─── 6-max: the tank ───────────────────────────────────────────────
    -- The only mode that wants a full inbox. These fire on things landing
    -- ON a six-max rather than on anything it does, which is why they all
    -- trigger on on_status_applied and gate the source to six_max.

    -- Microwave. It takes the hit and something else runs hot for it.
    tank_vent = {
        trigger = "on_status_applied",
        when    = { status = "tilt" },
        source  = { gtype = "six_max" },
        chance  = 0.50,
        target  = { kind = "any_other", pick = "random" },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 8 },
        ghost   = "microwave",
    },

    -- Fire Extinguisher. A tilt landing on a table that was ALREADY tilted
    -- marks a pot. `was_refresh` is exactly that fact and nothing else in
    -- the game knows it. Repeatable on purpose: the marks are charges, so
    -- ten of them means the next ten pots, and that is the engine.
    tank_compress = {
        trigger = "on_status_applied",
        when    = { status = "tilt", was_refresh = true },
        source  = { gtype = "six_max" },
        target  = { kind = "self" },
        payload = { kind = "apply_status", status = "stacked_mark",
                    magnitude = 1, charges = 1 },
        ghost   = "fire_extinguisher",
        impact  = false,
    },

    -- Blackout Curtains. Everything that lands teaches it something. Not
    -- win chance: this widens what a win is worth, which is the only way
    -- 6-max's enormous bands ever get reached.
    tank_read = {
        trigger = "on_status_applied",
        source  = { gtype = "six_max" },
        target  = { kind = "self" },
        payload = { kind = "apply_status", status = "sharp",
                    magnitude = 0.005 },
        ghost   = "blackout_curtains",
        impact  = false,
    },

    -- ─── Corrupted variants (Act 3) ────────────────────────────────────
    -- Corruption REPLACES an item's effects wholesale (GameState:689), so a
    -- corrupt block that doesn't carry the proc hands back a different item
    -- entirely. These keep each item's identity and push it: the targeted
    -- bump becomes the AOE slam, the coin flip becomes a certainty. The
    -- cost rides on the catalog entry beside the proc.

    ko_heater_corrupt = {
        trigger = "on_ko",
        chance  = 0.30,
        target  = { kind = "board_near", radius = 2, exclude_self = true },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.35, t = 6,
                    escalate = { field = "busted_total", per = 0.12 } },
        ghost   = "curved_monitor",
    },

    ko_bump_corrupt = {
        trigger = "on_ko",
        chance  = 0.25,
        target  = { kind = "board_near", radius = 2, exclude_self = true,
                    where = { chip_stack_table = false } },
        payload = { kind = "apply_status", status = "marked",
                    magnitude = 1, charges = 1 },
        ghost   = "pc_tower",
    },

    tourney_ratchet_corrupt = {
        trigger = "on_tournament_win",
        target  = { kind = "none" },
        payload = { kind = "ratchet", magnitude = 0.03,
                    effect = { kind = "win_chance_shift", mag_field = "amount" } },
        ghost   = "prize_vase",
    },

    ko_refund_corrupt = {
        trigger = "on_ko",
        chance  = 0.25,
        target  = { kind = "board_near", radius = 1, pick = "random",
                    exclude_self = true, where = { chip_stack_table = false } },
        payload = { kind = "refund_buyin", chance = 1.0 },
        ghost   = "shredder",
    },

    -- ─── Tilt: the diegetic bad beats ──────────────────────────────────
    -- These belong to nobody. They are granted at run start (see the
    -- hidden `the_tilt` catalog entry) so the mental game is part of the
    -- felt rather than something you buy into.

    -- Busting out of a tournament: the AOE slam. Every table in range
    -- catches it.
    miss_tilt = {
        trigger = "on_tournament_miss",
        target  = { kind = "board_near", radius = 1, exclude_self = true },
        payload = { kind = "apply_status", status = "tilt",
                    magnitude = 0.35, t = 5 },
        ghost   = nil,
    },

    -- SIX MAX ONLY. Losing a multiway cooler is the tank slot's own cost:
    -- the mode plays for rare huge pots, so dropping one is the most
    -- tilting thing in poker. Heads Up has no multiway cooler to lose and
    -- Zoom's bands are too small for it to mean anything, so neither
    -- should be paying a 6-max price.
    -- Single target, so it plays as the bump: this table shoves that
    -- table. The tournament bust above is the AOE slam; keeping the two
    -- distinct is the point.
    cooler_tilt = {
        trigger = "on_stack_loss",
        source  = { gtype = "six_max" },
        target  = { kind = "board_near", radius = 1, pick = "random",
                    exclude_self = true },
        payload = { kind = "apply_status", status = "tilt",
                    magnitude = 0.35, t = 5 },
        ghost   = nil,
    },
}
