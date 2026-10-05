-- sim/cases/procs.lua
--
-- Every proc and router in data/procs.lua and data/routers.lua: arrange a
-- board, own the thing that grants it, say the trigger happened, and read
-- where the payload landed. A chance proc runs with its chance forced to
-- 1 (the def is restored after). Corrupt-only procs are skipped by
-- design and say so in the audit.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local Procs, Routers = H.Procs, H.Routers

    local PUNCH = { magnitude = 0.35, t = 6 }

    -- Who grants each proc / router (item, deck level, capstone, corrupt).
    local grant = {}
    local function note(id, how) grant[id] = grant[id] or {}; table.insert(grant[id], how) end
    for _, it in ipairs(H.Catalog) do
        for _, e in ipairs(it.effects or {}) do
            if e.proc then note(e.proc, { item = it.id }) end
            if e.router then note(e.router, { item = it.id }) end
        end
        for _, e in ipairs((it.corrupt or {}).effects or {}) do
            if e.proc then note(e.proc, { corrupt = it.id }) end
            if e.router then note(e.router, { corrupt = it.id }) end
        end
    end
    for _, d in ipairs(H.DeckSpecs) do
        for _, e in ipairs(d.effects or {}) do
            if e.proc then note(e.proc, { deck = d.id, level = 1 }) end
            if e.router then note(e.router, { deck = d.id, level = 1 }) end
        end
        for _, e in ipairs((d.capstone or {}).effects or {}) do
            if e.proc then note(e.proc, { deck = d.id, level = 5 }) end
            if e.router then note(e.router, { deck = d.id, level = 5 }) end
        end
    end
    local function grantTo(w, id)
        local g = grant[id] or {}
        for _, how in ipairs(g) do
            if how.item then w:own(how.item) return true end
            if how.deck then w:deck(how.deck, how.level) return true end
        end
        return false
    end
    local function corruptOnly(id)
        local g = grant[id]
        if not g or #g == 0 then return false end
        for _, how in ipairs(g) do if not how.corrupt then return false end end
        return true
    end

    -- A fresh world with the standard test board: a 6-Max in the top-left
    -- corner, a Heads-Up beside it, a Zoom below it, and a tournament at
    -- (1,1). Every game type, every adjacency a case wants.
    local function board(opts)
        local w = T.world(opts)
        local six  = w:open("s001", "six_max", { 0, 0 })
        local hu   = w:open("s001", "hu",      { 0, 1 })
        local zoom = w:open("s001", "zoom",    { 1, 0 })
        local ko   = w:open("s001", "ko",      { 1, 1 })
        w:tick(0.05)
        return w, six, hu, zoom, ko
    end
    local function has(t, status) return t:hasStatus(status) end
    local function key(id) return "proc:" .. id end

    -- Case wrapper: skips corrupt-only procs, forces the chance, reports
    -- a thrown error as a failure instead of stopping the run.
    local function case(id, fn)
        local k = key(id)
        if not wanted(k) then return end
        if corruptOnly(id) then
            check(k, "skipped", true, "corrupt-only proc; corrupt lines are out of scope")
            return
        end
        local ok, err = pcall(function() T.forceChance(id, fn) end)
        if not ok then check(k, "error", false, tostring(err)) end
    end
    local CHANCE = {}
    for id, p in pairs(Procs) do CHANCE[id] = p.chance end
    for id, r in pairs(Routers) do CHANCE["router:" .. id] = r.chance end
    local function chanceText(id)
        local c = CHANCE[id]
        return c and ("chance 1 in %d forced to 1 for the case"):format(math.floor(1 / c + 0.5)) or "no chance on the proc"
    end

    -- ── heat and tilt payloads ─────────────────────────────────────────
    case("anchor_convert", function()
        local w, six, hu, zoom, ko = board()
        w:deck("anchor", 5)
        w:announce("on_tilt_spent", { table = six })
        check(key("anchor_convert"), "lands", (has(hu, "heater") or has(zoom, "heater")) and not has(six, "heater") and not has(ko, "heater"),
            "Anchor capstone: a 6-Max's tilt ends, one adjacent table (the Heads-Up or the Zoom beside it, at random) catches a heater; never itself or the tournament across the diagonal; " .. chanceText("anchor_convert"))
    end)

    case("blackout_curtains_read", function()
        local w, six, hu, zoom, ko = board()
        w:own("blackout_curtains")
        six:applyStatus("heater", PUNCH); w.bus:drain()
        check(key("blackout_curtains_read"), "lands", (has(hu, "heater") or has(zoom, "heater")) and not has(ko, "heater"),
            "a fresh heater on the 6-Max: one adjacent table (the Heads-Up or the Zoom, at random) catches one, never the tournament across the diagonal; " .. chanceText("blackout_curtains_read"))
    end)

    case("candle_flame", function()
        local w, six, hu, zoom, ko = board()
        w:own("candle")
        w:announce("on_stack_win", { table = hu, out = {} })
        local other = has(six, "heater") or has(zoom, "heater") or has(ko, "heater")
        check(key("candle_flame"), "lands", other and not has(hu, "heater"),
            "a stack at Heads-Up lights a random OTHER table, never itself; " .. chanceText("candle_flame"))
    end)

    case("circuit_pro_final", function()
        local w, six, hu, zoom, ko = board()
        w:deck("circuit_pro", 5)
        w:announce("on_tournament_win", { table = ko, n = 1 })
        check(key("circuit_pro_final"), "lands", has(six, "heater") and has(hu, "heater") and has(zoom, "heater"),
            "Circuit Pro capstone: first place lights every other table (3 of 3)")
    end)

    case("cool_towel_burnout", function()
        local w, six = board()
        w:own("electric_kettle")
        w:announce("on_tilt_spent", { table = six })
        check(key("cool_towel_burnout"), "lands", has(six, "heater"),
            "a tilt ending on a table lights that table; " .. chanceText("cool_towel_burnout"))
    end)

    case("curved_monitor_heater", function()
        local w, six, hu, zoom, ko = board()
        w:own("hot_bath")
        w:announce("on_ko", { table = ko, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local n = (has(hu, "heater") and 1 or 0) + (has(zoom, "heater") and 1 or 0)
        check(key("curved_monitor_heater"), "lands", n == 1,
            ("a knockout lights ONE table adjacent to the tournament (%d of the 2 neighbours lit); "):format(n) .. chanceText("curved_monitor_heater"))
        -- Circuit Pro's reach: +1 target per deck level on top of the pick
        local w2, s2, h2, z2, k2 = board()
        w2:own("hot_bath"); w2:deck("circuit_pro", 1)
        w2:announce("on_ko", { table = k2, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local n2 = (has(h2, "heater") and 1 or 0) + (has(z2, "heater") and 1 or 0)
        check("deck:circuit_pro:1", "reach", n2 == 2,
            ("Circuit Pro L1 (+1 table per knockout): the same knockout lights both neighbours (%d of 2)"):format(n2))
    end)

    case("dogs_playing_poker_high", function()
        local w, six, hu = board()
        w:own("dogs_playing_poker")
        w:announce("on_stack_win", { table = hu, out = {} })
        check(key("dogs_playing_poker_high"), "lands", has(hu, "heater") and not has(six, "heater"),
            "a stack at a table lights THAT table; " .. chanceText("dogs_playing_poker_high"))
    end)

    case("energy_drink_deal_spread", function()
        local w = T.world()
        local z0 = w:open("s001", "zoom", { 0, 0 })
        local z1 = w:open("s001", "zoom", { 0, 1 })   -- adjacent, same stake
        local z2 = w:open("s002", "zoom", { 1, 0 })   -- adjacent, other stake
        local h  = w:open("s001", "hu",   { 1, 1 })   -- not zoom
        local z3 = w:open("s001", "zoom", { 0, 2 })   -- same stake, two cells away (adjacent to z1, not z0)
        local zd = w:open("s001", "zoom", { 2, 2 })   -- same stake, on a diagonal of nothing dealt
        w:own("energy_drink"); w:tick(0.05)
        w.ctrl:dealHand(w:find(z0))
        check(key("energy_drink_deal_spread"), "lands",
            z1.state ~= "idle" and z2.state == "idle" and h.state == "idle",
            "dealing a Zoom table deals the adjacent same-stake Zoom (dealt), not the other-stake Zoom (idle) nor the Heads-Up (idle)")
        check(key("energy_drink_deal_spread"), "no chain",
            z3.state == "idle" and zd.state == "idle",
            "the spread stops at the neighbours: the Zoom two cells along (adjacent only to the one the spread dealt) stays idle, and so does the one across a diagonal")
    end)

    case("fire_extinguisher_compress", function()
        local w, six, hu, zoom, ko = board()
        w:own("fire_extinguisher")
        six:applyStatus("tilt", { magnitude = 0.35, t = 5 }); w.bus:drain()
        local after_first = has(hu, "heater") or has(zoom, "heater")
        six:applyStatus("tilt", { magnitude = 0.35, t = 5 }); w.bus:drain()
        check(key("fire_extinguisher_compress"), "lands", (not after_first) and (has(hu, "heater") or has(zoom, "heater")) and not has(ko, "heater"),
            "the FIRST tilt on a 6-Max does nothing next door; the second (a refresh) lights one adjacent table (the Heads-Up or the Zoom, at random), never the tournament across the diagonal")
    end)

    case("firehose_cascade", function()
        local w = T.world()
        local z0 = w:open("s001", "zoom", { 0, 0 })
        local z1 = w:open("s002", "zoom", { 0, 1 })
        local h  = w:open("s001", "hu",   { 1, 0 })
        w:deck("firehose", 5); w:tick(0.05)
        w:announce("on_stack_win", { table = z0, out = {} })
        check(key("firehose_cascade"), "lands", has(z0, "heater") and has(z1, "heater") and not has(h, "heater"),
            "Firehose capstone: a Zoom stack lights EVERY Zoom table (itself included), not the Heads-Up")
    end)

    case("first_aid_kit_biggest", function()
        local w = T.world()
        local a  = w:open("s001", "hu",  { 0, 0 })
        local b  = w:open("s003", "hu",  { 0, 1 })
        local ko = w:open("s001", "ko",  { 1, 0 })
        w:own("first_aid_kit"); w:tick(0.05)
        local before = w.state.bankroll
        w:announce("on_ko", { table = ko, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local got = w.state.bankroll - before
        local want = H.Lookups.findById(H.Stakes, "s003").buy_in
        check(key("first_aid_kit_biggest"), "pays", got == want,
            ("a knockout pays the biggest buy-in on the board: +$%s (the NL100 seat); "):format(tostring(got)) .. chanceText("first_aid_kit_biggest"))
    end)

    case("floor_plant_spill", function()
        local w = T.world()
        local six = w:open("s001", "six_max", { 1, 1 })
        local n1  = w:open("s001", "hu",   { 0, 1 })
        local n2  = w:open("s001", "zoom", { 1, 0 })
        local n3  = w:open("s001", "hu",   { 1, 2 })
        local far = w:open("s001", "hu",   { 0, 0 })
        w:own("floor_plant"); w:tick(0.05)
        w:announce("on_stack_win", { table = six, out = {} })
        check(key("floor_plant_spill"), "lands",
            n1._next_win_tier_up and n2._next_win_tier_up and n3._next_win_tier_up and not far._next_win_tier_up and not six._next_win_tier_up,
            "a 6-Max stack: each of the 3 adjacent tables' next win reads one size up; the diagonal one and the 6-Max itself do not")
    end)

    case("gaming_chair_spread", function()
        local w, six, hu, zoom = board()
        w:own("gaming_chair")
        w:announce("on_stack_win", { table = six, out = {} })
        local n = (has(hu, "heater") and 1 or 0) + (has(zoom, "heater") and 1 or 0)
        check(key("gaming_chair_spread"), "lands", n == 1 and not has(six, "heater"),
            ("a stack: ONE adjacent table catches a heater (%d of 2 neighbours), not the winner; "):format(n) .. chanceText("gaming_chair_spread"))
    end)

    case("hot_hand_spread", function()
        local w, six, hu, zoom = board()
        w:deck("hot_hand", 5)
        w:announce("on_heat_spent", { table = six, won = true })
        local n = (has(hu, "heater") and 1 or 0) + (has(zoom, "heater") and 1 or 0)
        check(key("hot_hand_spread"), "lands", n == 1,
            ("Hot Hand capstone: a heater ending jumps to one adjacent table (%d of 2); "):format(n) .. chanceText("hot_hand_spread"))
    end)

    case("house_cat_nap", function()
        local w, six, hu, zoom, ko = board()
        w:own("house_cat")
        w:announce("on_hand_won", { table = hu, count = 1, out = {} })
        local other = six._next_win_tier_up or zoom._next_win_tier_up or ko._next_win_tier_up
        check(key("house_cat_nap"), "lands", other and not hu._next_win_tier_up,
            "a hand won: a random OTHER table's next win reads one size up; " .. chanceText("house_cat_nap"))
    end)

    case("laminated_blueprint_full_house", function()
        local w, six, hu, zoom, ko = board()
        w:own("laminated_blueprint")
        w:announce("on_hand_won", { table = six, count = 1, out = {}, all_games = false })
        local none = not (has(hu, "heater") or has(zoom, "heater") or has(ko, "heater"))
        w:announce("on_hand_won", { table = six, count = 2, out = {}, all_games = true })
        local some = has(hu, "heater") or has(zoom, "heater") or has(ko, "heater")
        check(key("laminated_blueprint_full_house"), "lands", none and some,
            "a 6-Max win with all games open lights a random other table; without all games open, nothing")
        check(key("laminated_blueprint_full_house"), "all_games", w.ctrl:_allGamesOpen() == true,
            "the controller reports every game type seated on this board (6-Max, Heads-Up, Zoom, tournament)")
    end)

    case("medical_poster_revive", function()
        local w, six, hu, zoom, ko = board()
        w:own("medical_poster")
        hu.stack = 0
        local before = w.state.bankroll
        w:announce("on_ko", { table = ko, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local buy_in = H.Lookups.findById(H.Stakes, "s001").buy_in
        check(key("medical_poster_revive"), "lands", hu.stack == buy_in and w.state.bankroll == before,
            ("a knockout rebuys the busted adjacent Heads-Up (stack $%s) for free (bankroll unchanged)"):format(tostring(hu.stack)))
    end)

    case("microwave_oven_vent", function()
        local w, six, hu, zoom, ko = board()
        w:own("microwave_oven")
        six:applyStatus("tilt", { magnitude = 0.35, t = 5 }); w.bus:drain()
        local other = has(hu, "heater") or has(zoom, "heater") or has(ko, "heater")
        check(key("microwave_oven_vent"), "lands", other and not has(six, "heater"),
            "a tilt on a 6-Max: a random OTHER table catches a heater; " .. chanceText("microwave_oven_vent"))
    end)

    case("nightstand_rested", function()
        local w, six, hu = board()
        w:own("chrome_toaster")
        hu.stack = 0
        assert(w.ctrl:rebuyTable(w:find(hu)))
        check(key("nightstand_rested"), "lands", has(hu, "heater"),
            "a rebuy: that table catches a heater; " .. chanceText("nightstand_rested"))
    end)

    case("prize_vase_ratchet", function()
        local w, six, hu, zoom, ko = board()
        w:own("prize_vase")
        local wc0 = T.OutcomeMath.resolvedOutcome(w.ctrl.ctx, H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        w:announce("on_tournament_win", { table = ko, n = 1 })
        local r = w.state.run_ratchets and w.state.run_ratchets[1]
        local wc1 = T.OutcomeMath.resolvedOutcome(w.ctrl.ctx, H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        check(key("prize_vase_ratchet"), "ratchet", r and math.abs((r.amount or 0) - 0.01) < 1e-9,
            ("a tournament win banks +%s odds for the run (state.run_ratchets)"):format(tostring(r and r.amount)))
        check(key("prize_vase_ratchet"), "odds", math.abs((wc1 - wc0) - 0.01) < 1e-6,
            ("resolved odds at a Heads-Up table rose by %.4f after one win"):format(wc1 - wc0))
        -- the Whiteboard doubles what a win banks
        local w2, _, _, _, k2 = board()
        w2:own({ "prize_vase", "rubber_duck" })
        w2:announce("on_tournament_win", { table = k2, n = 1 })
        local r2 = w2.state.run_ratchets and w2.state.run_ratchets[1]
        check("item:rubber_duck", "ratchet x2", r2 and math.abs((r2.amount or 0) - 0.02) < 1e-9,
            ("with the Whiteboard a tournament win banks +%s odds (double the vase's 1%%)"):format(tostring(r2 and r2.amount)))
    end)

    case("rolled_vouchers_arrival", function()
        local w = T.world()
        w:own("bottle_of_wine")
        local a = w:open("s001", "hu")
        local b = w:open("s001", "zoom")
        local c = w:open("s002", "hu")
        check(key("rolled_vouchers_arrival"), "lands", has(a, "heater") and not has(b, "heater") and has(c, "heater"),
            "the first table opened at a stake catches a heater (NL2 yes, second NL2 no, first NL10 yes)")
    end)

    case("shredder_refund", function()
        local w, six, hu, zoom, ko = board()
        w:own("box_of_tissues")
        local before = w.state.bankroll
        w:announce("on_ko", { table = ko, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local got = w.state.bankroll - before
        local buy_in = H.Lookups.findById(H.Stakes, "s001").buy_in
        check(key("shredder_refund"), "pays", got == buy_in,
            ("a knockout hands one adjacent cash table its buy-in back: +$%s; "):format(tostring(got)) .. chanceText("shredder_refund"))
    end)

    case("tilt_cooler", function()
        local w, six, hu, zoom = board()
        w:announce("on_stack_loss", { table = six, out = {} })
        local n = (has(hu, "tilt") and 1 or 0) + (has(zoom, "tilt") and 1 or 0)
        check(key("tilt_cooler"), "lands", n >= 1 and not has(six, "tilt"),
            ("base rule: losing a stack at 6-Max tilts a table adjacent to it (%d neighbour(s) tilted), not the 6-Max"):format(n))
    end)

    case("tilt_miss", function()
        local w, six, hu, zoom, ko = board()
        w:announce("on_tournament_miss", { table = ko, n = 1 })
        local n = (has(hu, "tilt") and 1 or 0) + (has(zoom, "tilt") and 1 or 0)
        check(key("tilt_miss"), "lands", n >= 1,
            ("base rule: missing the money in a tournament tilts a table adjacent to it (%d neighbour(s) tilted)"):format(n))
    end)

    case("tower_upgrade_bump", function()
        local w, six, hu, zoom, ko = board()
        w:own("fresh_towel")
        w:announce("on_ko", { table = ko, n = 1, out = {}, busted_total = 1, seats = { 1 } })
        local n = (hu._next_win_tier_up and 1 or 0) + (zoom._next_win_tier_up and 1 or 0)
        check(key("tower_upgrade_bump"), "lands", n == 1 and not ko._next_win_tier_up,
            ("a knockout: one adjacent cash table's next win reads one size up (%d of 2); "):format(n) .. chanceText("tower_upgrade_bump"))
    end)

    case("wall_clock_century", function()
        local w, six, hu, zoom, ko = board()
        w:own("wall_clock")
        w:announce("on_hand_won", { table = hu, count = 1, out = {} })
        local other = has(six, "heater") or has(zoom, "heater") or has(ko, "heater")
        check(key("wall_clock_century"), "lands", other and not has(hu, "heater"),
            "a hand won: a random OTHER table catches a heater; " .. chanceText("wall_clock_century"))
    end)

    -- corrupt-only procs: named, skipped
    for id in pairs(Procs) do
        if corruptOnly(id) and wanted(key(id)) then
            check(key(id), "skipped", true, "corrupt-only proc; corrupt lines are out of scope")
        end
    end

    -- ── routers ──────────────────────────────────────────────────────
    local function rcase(id, fn)
        local k = "router:" .. id
        if not wanted(k) then return end
        if corruptOnly(id) then
            check(k, "skipped", true, "corrupt-only router; corrupt lines are out of scope")
            return
        end
        local def = Routers[id]
        local old = def and def.chance
        if def then def.chance = nil end
        local ok, err = pcall(fn)
        if def then def.chance = old end
        if not ok then check(k, "error", false, tostring(err)) end
    end
    local function rtext(id)
        local c = CHANCE["router:" .. id]
        return c and ("chance 1 in %d forced to 1 for the case"):format(math.floor(1 / c + 0.5)) or "no chance on the router"
    end

    rcase("console_television_intercept", function()
        local w, six, hu = board()
        w:own({ "blackout_curtains", "fire_extinguisher", "microwave_oven", "console_television" })
        local to = w:deliver("heater", hu)
        local to2 = w:deliver("tilt", hu)
        check("router:console_television_intercept", "steals", to == six and to2 == six,
            "a heater and a tilt aimed at the Heads-Up beside a 6-Max both land on the 6-Max; " .. rtext("console_television_intercept"))
    end)

    rcase("anchor_taunt", function()
        local w, six, hu = board()
        w:deck("anchor", 1)
        local to = w:deliver("tilt", hu)
        local to2 = w:deliver("heater", hu)
        check("router:anchor_taunt", "taunts", to == six and to2 == hu,
            "Anchor: a tilt aimed beside a 6-Max lands on the 6-Max; a heater stays where it was aimed")
        check("deck:anchor:1", "taunt", to == six, "the taunt router is live from Anchor level 1")
        -- and Space Heater pays the table the tank took it for
        local w2, s2, h2 = board()
        w2:deck("anchor", 1); w2:own("space_heater")
        w2:deliver("tilt", h2)
        check("item:space_heater", "bump", (tonumber(h2._next_win_tier_up) or 0) >= 1,
            "the Heads-Up the 6-Max took a tilt for gets its next win one size up")
    end)

    rcase("window_bend", function()
        local w, six, hu, zoom, ko = board()
        w:own({ "prize_vase", "shower_head", "window" })
        ko.ko.state = "playing"
        local _, status = w:deliver("tilt", hu)
        ko.ko.state = "idle"
        local _, status2 = w:deliver("tilt", hu)
        check("router:window_bend", "bends", status == "heater" and status2 == "tilt",
            "while a tournament runs at the stake, a tilt aimed at its stake arrives as a heater; with none running it stays a tilt; " .. rtext("window_bend"))
    end)

    rcase("basket_corner", function()
        local w, six, hu, zoom = board()
        w:own({ "dish_soap", "kitchen_bin" })
        local to = w:deliver("tilt", zoom)
        check("router:basket_corner", "corner", to == six,
            "a tilt aimed anywhere lands on the top-left table instead; " .. rtext("basket_corner"))
    end)

    rcase("dish_soap_deflect", function()
        local w, six, hu, zoom = board()
        w:own("dish_soap")
        local to = w:deliver("tilt", six)
        check("router:dish_soap_deflect", "deflects", to ~= six and (to == hu or to == zoom),
            "a tilt aimed at the 6-Max lands on a table adjacent to it instead; " .. rtext("dish_soap_deflect"))
    end)

    for id in pairs(Routers) do
        if corruptOnly(id) and wanted("router:" .. id) then
            check("router:" .. id, "skipped", true, "corrupt-only router; corrupt lines are out of scope")
        end
    end
end
