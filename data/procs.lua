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
--   target   { kind = "none" | "self" | "gtype" | "order_near" | "any_other",
--              radius, gtype, exclude_self, where, pick = "random", max }
--   payload  { kind = "apply_status" | "resolve_now" | "refund_buyin" | "ratchet", ... }
--   ghost    catalog item id whose sprite + sound plays when it fires
--   impact   false if this is not a blow. Procs land with the fist or the
--            shove by default, because most of them ARE one table doing
--            something to another. Set it false where the fiction is not
--            violence and you want only the ghost.
--
-- "Nearby" is distance in table order, which is reading order of the board
-- and is what the player rearranges by dragging. See models/table_procs.
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
        target  = { kind = "order_near", radius = 2, pick = "random",
                    exclude_self = true },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.06, t = 6,
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
        target  = { kind = "order_near", radius = 2, pick = "random",
                    exclude_self = true, where = { chip_stack_table = false } },
        payload = { kind = "apply_status", status = "marked",
                    magnitude = 1, charges = 1 },
        ghost   = "pc_tower",
    },

    -- The healer. A knockout sometimes buys back a neighbour's buy-in.
    ko_refund = {
        trigger = "on_ko",
        chance  = 0.12,
        target  = { kind = "order_near", radius = 1, pick = "random",
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

    -- ─── Corrupted variants (Act 3) ────────────────────────────────────
    -- Corruption REPLACES an item's effects wholesale (GameState:689), so a
    -- corrupt block that doesn't carry the proc hands back a different item
    -- entirely. These keep each item's identity and push it: the targeted
    -- bump becomes the AOE slam, the coin flip becomes a certainty. The
    -- cost rides on the catalog entry beside the proc.

    ko_heater_corrupt = {
        trigger = "on_ko",
        chance  = 0.30,
        target  = { kind = "order_near", radius = 2, exclude_self = true },
        payload = { kind = "apply_status", status = "heater",
                    magnitude = 0.06, t = 6,
                    escalate = { field = "busted_total", per = 0.12 } },
        ghost   = "curved_monitor",
    },

    ko_bump_corrupt = {
        trigger = "on_ko",
        chance  = 0.25,
        target  = { kind = "order_near", radius = 2, exclude_self = true,
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
        target  = { kind = "order_near", radius = 1, pick = "random",
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
        target  = { kind = "order_near", radius = 1, exclude_self = true },
        payload = { kind = "apply_status", status = "tilt",
                    magnitude = 0.05, t = 5 },
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
        target  = { kind = "order_near", radius = 1, pick = "random",
                    exclude_self = true },
        payload = { kind = "apply_status", status = "tilt",
                    magnitude = 0.05, t = 5 },
        ghost   = nil,
    },
}
