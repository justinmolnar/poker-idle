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
        check("item:yellow_sticky_note", "stamps", e_b == 1 and e_a == 0 and e_h == 2,
            ("empty cells beside a table: (0,1) sees 1 (the hole at (1,1)), the corner (0,0) sees 0, (2,1) sees 2 (the hole and (2,2)); past the board's edge never counts"):format())
        -- the hand plays with the bonus: deal at (2,1) with the two empties and read the sampled win chance
        local r = T.stub(OM, "sampleOutcome", function(wc) t.h._seen_wc = wc; return false, "small" end)
        w.ctrl:dealHand(w:find(t.h)); r()
        local base = OM.resolvedOutcome(T.ctxOf({}), H.Lookups.findById(H.GameTypes, "hu"), H.Lookups.findById(H.Stakes, "s001"))
        local got = (t.h._seen_wc or 0) - base
        check("item:yellow_sticky_note", "odds", math.abs(got - 0.10) < 1e-6,
            ("+5%% odds per empty cell adjacent: the table with two saw +%.1f%% on its deal"):format(got * 100))
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
    end

    if wanted("item:comfort_bed") then
        local w = T.world()
        local hu  = w:open("s001", "hu",      { 0, 0 })
        local six = w:open("s001", "six_max", { 0, 1 })
        w:tick(0.05)
        local before_lonely, before_empty = hu._lonely, hu._empty_adjacent
        w:own("comfort_bed"); w:tick(0.05)
        check("item:comfort_bed", "counts", before_lonely == false and before_empty == 0 and hu._lonely == true and hu._empty_adjacent == 1,
            "beside a 6-Max: without the bed the Heads-Up has a neighbour and no empties; with it the 6-Max reads as an empty cell (lonely, 1 empty adjacent)")
    end

    if wanted("item:lava_lamp") then
        local w = T.world()
        local a = w:open("s001", "hu", { 0, 0 })
        local b = w:open("s001", "hu", { 0, 1 })
        w:own("lava_lamp"); w:tick(0.05)
        a._held = true   -- what GrindView stamps while the panel is in hand
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
    if wanted("item:mirror") then
        local w = T.world()
        w:open("s001", "hu"); w:open("s001", "hu"); w:open("s002", "hu"); w:open("s001", "zoom")
        w:own("mirror"); w:tick(0.05)
        check("item:mirror", "count", w.ctrl.ctx.hu_table_count == 3,
            ("the controller counts %d Heads-Up tables open (3 opened, plus a Zoom that does not count)"):format(w.ctrl.ctx.hu_table_count or -1))
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

    if wanted("item:wall_hanger") then
        local w = T.world()
        w:open("s001", "hu"); w:open("s001", "zoom"); w:open("s002", "hu"); w:open("s003", "six_max")
        w:own("wall_hanger"); w:tick(0.05)
        check("item:wall_hanger", "count", w.ctrl.ctx.stakes_seated == 3,
            ("the controller counts %d stakes seated (NL2 twice, NL10, NL100 = 3)"):format(w.ctrl.ctx.stakes_seated or -1))
    end

    if wanted("item:framed_diploma") then
        local w = T.world()
        local z = {}
        for i = 1, 4 do z[i] = w:open("s001", "zoom") end
        w:own("framed_diploma"); w:tick(0.05)
        for i = 1, 4 do w.ctrl:dealHand(w:find(z[i])) end
        local peak = 0
        for _ = 1, 200 do w:tick(0.05); peak = math.max(peak, w.ctrl.ctx.hands_per_second or 0) end
        check("item:framed_diploma", "count", peak >= 2,
            ("four Zoom tables dealt together: the board's hands-per-second stamp peaked at %d in the next ten seconds"):format(peak))
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
    if wanted("deck:swarm:5") then
        local w = T.world()
        w:upgrade("focus", focus_max); w:deck("swarm", 5); w:own("second_monitor")
        check("deck:swarm:5", "the board", w.ctrl:currentFocusCapacity() == CAP.MAX_TABLES,
            ("Swarm L5 + max Focus + Second Monitor = %d = the whole %d-table board"):format(w.ctrl:currentFocusCapacity(), CAP.MAX_TABLES))
    end

    -- Focus penalty: over capacity every hand's money shrinks
    if wanted("upgrade:focus:1") then
        local w = T.world()
        for _ = 1, 6 do w:open("s001", "zoom") end
        local m = w.ctrl:currentFocusMult()
        check("upgrade:focus:1", "penalty", math.abs(m - (1 - CAP.FOCUS_BASE_PENALTY * 2)) < 1e-9,
            ("6 tables on a base capacity of %d: winnings x%.2f (%d over, %.0f%% each)"):format(CAP.FOCUS_BASE_CAPACITY, m, 2, CAP.FOCUS_BASE_PENALTY * 100))
    end
end
