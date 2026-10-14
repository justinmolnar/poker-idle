-- sim/cases/board.lua
--
-- What the controller reads off the board each frame, and the per-table
-- numbers that hang on it: empty cells (Yellow Sticky Note, Throw Pillow,
-- Comfort Bed), the held table (Lava Lamp), Zoom neighbours (Receipt
-- Printer), the Heads-Up count (Mirror), heaters burning (Desk Speakers),
-- stakes seated (Wall Hanger), hands per second (Framed Diploma), every
-- game open (Laminated Blueprint), and Focus capacity (the upgrade, the
-- Second Monitor, the Swarm deck).
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local OM = T.OutcomeMath
    local CAP = H.Constants.GAMEPLAY

    -- A 3x3 board with a hole: tables at every cell but (1,1) and (2,2);
    -- (1,1)'s neighbours all see one empty cell, (0,0) sees none.
    local function holed()
        local w = T.world()
        local t = {}
        t.a = w:open("s001", "hu",      { 0, 0 })
        t.b = w:open("s001", "hu",      { 0, 1 })
        t.c = w:open("s001", "hu",      { 0, 2 })
        t.d = w:open("s001", "six_max", { 1, 0 })
        t.f = w:open("s001", "hu",      { 1, 2 })
        t.g = w:open("s001", "hu",      { 2, 0 })
        t.h = w:open("s001", "hu",      { 2, 1 })
        w:tick(0.05)
        return w, t
    end

    -- ── empties, lonely, held ──────────────────────────────────────────
    if wanted("item:yellow_sticky_note") then
        local w, t = holed()
        w:own("yellow_sticky_note"); w:tick(0.05)
        local e_b, e_a, e_h = t.b._empty_adjacent, t.a._empty_adjacent, t.h._empty_adjacent
        check("item:yellow_sticky_note", "stamps", e_b == 1 and e_a == 1 and e_h == 2,
            ("empty cells beside a table: (0,1) sees 1 (the hole at (1,1)), the corner (0,0) sees 1 (the 6-Max below it counts as empty), (2,1) sees 2 (the hole and (2,2)); past the board's edge never counts"):format())
        -- the hand plays with the bonus: deal at (2,1) with the two empties and read the sampled win chance
        local r = T.stub(OM, "sampleOutcome", function(wc) t.h._seen_wc = wc; return false, "small" end)
        w.ctrl:dealHand(w:find(t.h)); r()
        local base = OM.resolvedOutcome(T.ctxOf({}), H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        local got = (t.h._seen_wc or 0) - base
        check("item:yellow_sticky_note", "odds", math.abs(got - 0.10) < 1e-6,
            ("+5%% odds per empty cell adjacent: the table with two saw +%.1f%% on its deal"):format(got * 100))
        -- ...and the felt says so before the deal: the readout prices the
        -- table where it sits (OutcomeMath.tableWinChanceBonus, shared).
        local shown = w.ctrl:tableStats(t.h)
        local shown_a = w.ctrl:tableStats(t.a)
        local d_h = shown and (shown.win_chance - base) or -1
        local d_a = shown_a and (shown_a.win_chance - base) or -1
        check("item:yellow_sticky_note", "readout", math.abs(d_h - 0.10) < 1e-6 and math.abs(d_a - 0.05) < 1e-6,
            ("the readout shows +%.1f%% at the table with two empties and +%.1f%% at the corner with one (the 6-Max)"):format(d_h * 100, d_a * 100))
    end

    -- Comfort Bed: odds per table under the focus cap, at every table.
    if wanted("item:comfort_bed") then
        local w = T.world()
        local a = w:open("s001", "hu", { 0, 0 })
        w:open("s001", "hu", { 0, 2 })
        w:own("comfort_bed"); w:tick(0.05)
        local base  = OM.resolvedOutcome(T.ctxOf({}), H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        local cap   = w.ctrl:currentFocusCapacity()
        local slack = cap - 2
        local want  = math.min(0.01 * slack, 0.10)
        local shown = w.ctrl:tableStats(a)
        local d = shown and (shown.win_chance - base) or -1
        check("item:comfort_bed", "odds", slack > 0 and math.abs(d - want) < 1e-6,
            ("2 tables under a cap of %d: the readout shows +%.1f%% (want +%.1f%%)"):format(cap, d * 100, want * 100))
        for i = 1, slack do w:open("s001", "hu", { 2, (i - 1) % 3 }) end
        w:tick(0.05)
        local full = w.ctrl:tableStats(a)
        local d2 = full and (full.win_chance - base) or -1
        check("item:comfort_bed", "at cap", math.abs(d2) < 1e-6,
            ("at the cap (%d of %d) it adds nothing: +%.1f%%"):format(w.ctrl.pool:count(), cap, d2 * 100))
    end

    if wanted("item:throw_pillow") then
        local w = T.world()
        local lone = w:open("s001", "hu", { 0, 0 })
        local pair1 = w:open("s001", "hu", { 0, 2 })
        local pair2 = w:open("s001", "hu", { 1, 2 })
        w:own("throw_pillow"); w:tick(0.05)
        check("item:throw_pillow", "stamps", lone._lonely == true and pair1._lonely == false,
            "a table with nothing on any side reads lonely; one with a neighbour does not")
        local r1 = T.playHand(w, lone, { won = true, tier = "medium", bb = 10 })
        local r2 = T.playHand(w, pair1, { won = true, tier = "medium", bb = 10 })
        local ratio = r1 and r2 and r2.delta > 0 and (r1.delta / r2.delta) or 0
        check("item:throw_pillow", "winnings", math.abs(ratio - 1.5) < 1e-6,
            ("the lonely table's win paid x%.2f the paired table's (same 10bb pot)"):format(ratio))
        -- The readout quotes the lonely table higher (tableEarningsMult in
        -- the payout multiplier), the paired one at the plain figure.
        local s_lone, s_pair = w.ctrl:tableStats(lone), w.ctrl:tableStats(pair1)
        local shown_ratio = (s_lone and s_pair and s_pair.ev_per_hand ~= 0)
                            and (s_lone.ev_per_hand / s_pair.ev_per_hand) or 0
        check("item:throw_pillow", "readout", shown_ratio > 1.0,
            ("the lonely table's readout reads x%.2f the paired table's"):format(shown_ratio))
    end

    -- A 6-Max counts as empty space for its neighbours, built in (it was the
    -- Comfort Bed's effect; the bed is retired).
    if wanted("item:yellow_sticky_note") then
        local w = T.world()
        local hu  = w:open("s001", "hu",      { 0, 0 })
        local six = w:open("s001", "six_max", { 0, 1 })
        w:tick(0.05)
        check("item:yellow_sticky_note", "6-max empty", hu._lonely == true and hu._empty_adjacent == 1,
            "beside a 6-Max the Heads-Up reads lonely with 1 empty side: a 6-Max counts as empty space, no item needed")
    end

    if wanted("item:lava_lamp") then
        local w = T.world()
        local a = w:open("s001", "hu", { 0, 0 })
        local b = w:open("s001", "hu", { 0, 1 })
        w:own("lava_lamp"); w:tick(0.05)
        a._held = true   -- what GrindView stamps while the panel is in hand
        local _, boost_a = a:paceParts(w.ctrl.ctx)
        local _, boost_b = b:paceParts(w.ctrl.ctx)
        check("item:lava_lamp", "pace", math.abs(boost_a - boost_b * 3) < 1e-6,
            ("the table in your hand deals at x%.2f the pace of one not held"):format(boost_a / boost_b))
        local seen
        local r = T.stub(OM, "sampleOutcome", function(wc) seen = wc; return false, "small" end)
        w.ctrl:dealHand(w:find(a)); r()
        local base = OM.resolvedOutcome(T.ctxOf({}), H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        local seen_b
        r = T.stub(OM, "sampleOutcome", function(wc) seen_b = wc; return false, "small" end)
        w.ctrl:dealHand(w:find(b)); r()
        check("item:lava_lamp", "odds", math.abs((seen or 0) - base - 0.10) < 1e-6 and math.abs((seen_b or 0) - base) < 1e-6,
            ("the held table dealt at +%.1f%% odds; the table not in hand at +%.1f%%"):format(((seen or 0) - base) * 100, ((seen_b or 0) - base) * 100))
    end

    -- ── zoom neighbours, pace ──────────────────────────────────────────
    if wanted("item:receipt_printer") then
        local w = T.world()
        local z0 = w:open("s001", "zoom", { 0, 0 })
        local z1 = w:open("s001", "zoom", { 0, 1 })
        local z2 = w:open("s001", "zoom", { 1, 0 })
        local lone = w:open("s001", "zoom", { 2, 2 })
        w:own("receipt_printer"); w:tick(0.05)
        check("item:receipt_printer", "stamps", z0._zoom_neighbours == 2 and z1._zoom_neighbours == 1 and lone._zoom_neighbours == 0,
            "Zoom neighbours: the corner Zoom with two Zooms beside it reads 2, its neighbour 1, the lone Zoom 0")
        -- the table publishes its script pace each frame (wall time per
        -- hand varies with the script, so the pace itself is what to read)
        local function paceOf(t)
            w.ctrl:dealHand(w:find(t)); w:tick(0.05)
            local p = t._script_pace
            T.untilHands(w, t, 1, 30)
            return p
        end
        local p_lone, p_z0, p_z1 = paceOf(lone), paceOf(z0), paceOf(z1)
        check("item:receipt_printer", "pace", math.abs(p_z0 / p_lone - 1.2) < 1e-6 and math.abs(p_z1 / p_lone - 1.1) < 1e-6,
            ("the Zoom with two Zoom neighbours deals at x%.2f the lone Zoom's pace, the one with one neighbour at x%.2f (x1.1 per neighbour)"):format(p_z0 / p_lone, p_z1 / p_lone))
    end

    -- ── the live counts the odds items read ───────────────────────────
    -- Mirror: a stack win bounces to a table beside it (proc mirror_bounce).
    if wanted("item:mirror") then
        local w = T.world()
        local a = w:open("s001", "hu",   { 0, 0 })
        local b = w:open("s001", "zoom", { 0, 1 })
        local far = w:open("s001", "zoom", { 1, 1 })
        w:own("mirror"); w:tick(0.05)
        w:announce("on_stack_win", { table = a, out = {} })
        check("item:mirror", "bounce", (b._next_win_tier_up ~= nil) and far._next_win_tier_up == nil and a._next_win_tier_up == nil,
            "a stack at the Heads-Up: the Zoom beside it gets its next win one size up; the diagonal one and the winner do not")
    end

    if wanted("item:desk_speakers") then
        local w = T.world()
        local a = w:open("s001", "hu"); local b = w:open("s001", "hu"); w:open("s001", "hu")
        w:own("desk_speakers")
        a:applyStatus("heater", { magnitude = 0.35, t = 6 }); b:applyStatus("heater", { magnitude = 0.35, t = 6 })
        w:tick(0.05)
        check("item:desk_speakers", "count", w.ctrl.ctx.heater_count == 2,
            ("the controller counts %d heaters burning (2 lit of 3 tables)"):format(w.ctrl.ctx.heater_count or -1))
    end

    if wanted("item:wall_hook") then
        local w = T.world()
        w:open("s001", "hu"); w:open("s001", "zoom"); w:open("s002", "hu"); w:open("s003", "six_max")
        w:own("wall_hook"); w:tick(0.05)
        local four = w.ctrl.ctx.lanes_seated
        -- A second table on a lane already in play is not a new lane.
        w:open("s001", "hu"); w:tick(0.05)
        check("item:wall_hook", "count", four == 4 and w.ctrl.ctx.lanes_seated == 4,
            ("the controller counts %d table types in play (NL2 Heads-Up, NL2 Zoom, NL10 Heads-Up, NL100 6-Max = 4), still %d with a second NL2 Heads-Up"):format(
                four or -1, w.ctrl.ctx.lanes_seated or -1))
    end

    if wanted("item:hybrid_console") then
        local w = T.world()
        local z = {}
        for i = 1, 4 do z[i] = w:open("s001", "zoom") end
        w:own("hybrid_console"); w:tick(0.05)
        -- Played continuously for ten seconds: the stamp is a rate (hands
        -- per second over the last few seconds), not a burst count.
        local peak = 0
        for _ = 1, 200 do
            for i = 1, 4 do
                if z[i].state == "idle" then w.ctrl:dealHand(w:find(z[i])) end
            end
            w:tick(0.05); peak = math.max(peak, w.ctrl.ctx.hands_per_second or 0)
        end
        check("item:hybrid_console", "count", peak >= 1 and peak < 20,
            ("four Zoom tables played for ten seconds: the board's hands-per-second rate peaked at %.1f"):format(peak))
        -- The live counter and the display revision: hands per second moves
        -- ~20 times a second on a busy board, and used to empty every EV
        -- cache and memo each time. Without an item that reads it the
        -- revision must not move while the counter does; with one (the
        -- Hybrid Console here) it folds at most once a second.
        local w2 = T.world()
        local z2 = {}
        for i = 1, 4 do z2[i] = w2:open("s001", "zoom") end
        w2:tick(0.05)
        local function busy(w, tables, secs)
            local rev0, moves, last = w.ctrl.display_rev, 0, w.ctrl.display_rev
            local t = 0
            while t < secs do
                for i = 1, #tables do
                    if tables[i].state == "idle" then w.ctrl:dealHand(w:find(tables[i])) end
                end
                w:tick(0.05); t = t + 0.05
                if w.ctrl.display_rev ~= last then moves = moves + 1; last = w.ctrl.display_rev end
            end
            return moves, w.ctrl.display_rev - rev0
        end
        local moves_off = busy(w2, z2, 4)
        local hps_moved = w2.ctrl.ctx.hands_per_second or 0
        w2:own("hybrid_console"); w2:tick(0.05)
        local moves_on = busy(w2, z2, 4)
        check("item:hybrid_console", "display", moves_off == 0 and moves_on <= 9 and moves_on >= 1,
            ("four seconds of Zoom hands: the display revision moved %d times with nothing reading hands per second (the counter read %.1f), %d times with the console (folded at most every %.1fs)"):format(
                moves_off, hps_moved, moves_on, w2.ctrl.LIVE_BUMP_SECS))
        -- And a cache hit on a table's stats allocates nothing: the key is
        -- compared field by field, the opts are built only on a miss.
        local t1 = z2[1]
        w2.ctrl:tableStats(t1)
        collectgarbage("collect")
        local kb0 = collectgarbage("count")
        for _ = 1, 500 do w2.ctrl:tableStats(t1) end
        local kb = collectgarbage("count") - kb0
        check("item:hybrid_console", "stats hit", kb < 2,
            ("500 hits on a table's stats cache allocated %.1f KB"):format(kb))
    end

    if wanted("item:laminated_blueprint") then
        local w = T.world()
        w:open("s001", "hu"); w:open("s001", "zoom"); w:open("s001", "six_max")
        w:tick(0.05)
        local three = w.ctrl:_allGamesOpen()
        w:open("s001", "ko"); w:tick(0.05)
        local four = w.ctrl:_allGamesOpen()
        check("item:laminated_blueprint", "all games", three == false and four == true,
            "with three game types seated the board is not full; with the tournament added, every game is open")
    end

    -- ── Focus ──────────────────────────────────────────────────────────
    local focus_max = 1
    for _, u in ipairs(H.RunUpgrades) do if u.id == "focus" then focus_max = u.max_level or 1 end end
    for L = 1, focus_max do
        local key = ("upgrade:focus:%d"):format(L)
        if wanted(key) then
            local w = T.world()
            w:upgrade("focus", L)
            local cap = w.ctrl:currentFocusCapacity()
            check(key, "capacity", cap == CAP.FOCUS_BASE_CAPACITY + L,
                ("Focus L%d: capacity %d tables (base %d + %d)"):format(L, cap, CAP.FOCUS_BASE_CAPACITY, L))
        end
    end
    if wanted("item:second_monitor") then
        local w = T.world()
        w:upgrade("focus", focus_max); w:own("second_monitor")
        check("item:second_monitor", "capacity", w.ctrl:currentFocusCapacity() == CAP.FOCUS_BASE_CAPACITY + focus_max + 2,
            ("+2 Focus: capacity %d at max Focus with the monitor"):format(w.ctrl:currentFocusCapacity()))
    end
    for L = 1, 5 do
        local key = ("deck:swarm:%d"):format(L)
        if wanted(key) then
            local w = T.world()
            w:upgrade("focus", focus_max); w:deck("swarm", L)
            local cap = w.ctrl:currentFocusCapacity()
            local want = CAP.FOCUS_BASE_CAPACITY + focus_max * (1 + L)
            check(key, "capacity", cap == want,
                ("Swarm L%d with max Focus: capacity %d (each of %d Focus levels worth %d)"):format(L, cap, focus_max, 1 + L))
        end
    end
    -- Swarm levels on every hand a cursor causes, not only the click: a
    -- hand chained on the house's clock off a cursor's hand (dealIdleTable
    -- with the cursor's mark: the Zoom chain, a spread, a clash's deal)
    -- earns the point the click does; the same chain off the player's own
    -- hand earns nothing, and so does a hand the player deals by hand.
    if wanted("deck:swarm:1") then
        local w = T.world()
        w:deck("swarm", 1)
        local t = w:open("s001", "zoom")
        local function xp() return w.state.deck_xp.swarm or 0 end
        local function settle() T.untilHands(w, t, 1, 30) end
        -- A player's hand: no point, and its chain carries no mark.
        local x0 = xp()
        w.ctrl:dealHand(w:find(t)); local d_player = xp() - x0
        local mark_player = t._swarm_deal
        settle()
        x0 = xp()
        w.ctrl:dealIdleTable(t, { by_cursor = t._swarm_deal }); local d_player_chain = xp() - x0
        settle()
        -- A cursor's hand: a point, and its chain carries the mark on.
        x0 = xp()
        w.ctrl._deal_by_cursor = true
        w.ctrl:onCursorDeal({ idx = w:find(t) }); w.ctrl:dealHand(w:find(t))
        w.ctrl._deal_by_cursor = nil
        local d_cursor = xp() - x0
        local mark_cursor = t._swarm_deal
        settle()
        x0 = xp()
        w.ctrl:dealIdleTable(t, { by_cursor = t._swarm_deal }); local d_cursor_chain = xp() - x0
        local mark_chain = t._swarm_deal
        check("deck:swarm:1", "chain",
            d_player == 0 and mark_player == false and d_player_chain == 0
            and d_cursor == 1 and mark_cursor == true and d_cursor_chain == 1 and mark_chain == true,
            ("player's hand %d XP, its chain %d; cursor's hand %d XP, its chain %d (the mark carries: %s)"):format(
                d_player, d_player_chain, d_cursor, d_cursor_chain, tostring(mark_chain)))
    end
    if wanted("deck:swarm:5") then
        local w = T.world()
        w:upgrade("focus", focus_max); w:deck("swarm", 5); w:own("second_monitor")
        check("deck:swarm:5", "the board", w.ctrl:currentFocusCapacity() == CAP.MAX_TABLES,
            ("Swarm L5 + max Focus + Second Monitor = %d = the whole %d-table board"):format(w.ctrl:currentFocusCapacity(), CAP.MAX_TABLES))
    end

    -- Focus penalty: over capacity every table plays slower, and each
    -- hand still pays in full.
    if wanted("upgrade:focus:1") then
        local w = T.world()
        -- One Zoom under the cap first: its pace is the reference.
        local lone = w:open("s001", "zoom", { 2, 2 })
        local function paceOf(t)
            w.ctrl:dealHand(w:find(t)); w:tick(0.05)
            local p = t._script_pace
            T.untilHands(w, t, 1, 30)
            return p
        end
        local p_under = paceOf(lone)
        for _ = 1, 5 do w:open("s001", "zoom") end
        local m = w.ctrl:currentFocusMult()
        check("upgrade:focus:1", "penalty", math.abs(m - (1 - CAP.FOCUS_BASE_PENALTY * 2)) < 1e-9,
            ("6 tables on a base capacity of %d: speed x%.2f (%d over, %.0f%% each)"):format(CAP.FOCUS_BASE_CAPACITY, m, 2, CAP.FOCUS_BASE_PENALTY * 100))
        -- The pace: the same table, now two over, plays at the factor.
        local p_over = paceOf(lone)
        check("upgrade:focus:1", "pace", math.abs(p_over / p_under - m) < 1e-6,
            ("the Zoom's pace over the cap is x%.2f its pace under it (focus x%.2f)"):format(p_over / p_under, m))
        -- The money: a won hand resolves for exactly what the table dealt
        -- it for, no factor. Read the resolution off on_hand_won.
        local r_out = T.stub(OM, "sampleOutcome", function() return true, "small" end)
        local orig, seen = w.ctrl._announce, nil
        local r_ann = T.stub(w.ctrl, "_announce", function(self, name, ev)
            if name == "on_hand_won" and ev.table == lone and ev.out and ev.out[1] then
                seen = ev.out[1].delta
            end
            return orig(self, name, ev)
        end)
        w.ctrl:dealHand(w:find(lone)); w:tick(0.05)
        local dealt = lone.outcome_delta
        T.untilHands(w, lone, 1, 30)
        r_ann(); r_out()
        check("upgrade:focus:1", "money", seen ~= nil and dealt and math.abs(seen - dealt) < 1e-6,
            ("over the cap a won hand dealt for $%.2f resolved for $%.2f (no factor on the money)"):format(dealt or 0, seen or 0))
        local s = w.ctrl:focusStrain()
        check("upgrade:focus:1", "strain", math.abs(s - (1 - m) / (1 - CAP.FOCUS_FLOOR)) < 1e-9,
            ("the audio strain reads %.3f: the shortfall over the distance to the floor"):format(s))
    end
end
