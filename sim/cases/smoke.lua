-- sim/cases/smoke.lua
--
-- Everything at once: every live item owned, every upgrade maxed, every
-- deck at 5, a full 36-table board of every game type, the swarm at 13,
-- two minutes of fake clock. Nothing may throw; the money stays finite;
-- only the two authorized statuses appear; the counters climb.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    if not wanted("smoke:full_board") then return end
    local CursorPool = require("services.CursorPool")
    local Decks = require("models.Decks")
    local CAP = H.Constants.GAMEPLAY

    local w = T.world({ bankroll = 1e15 })
    local ids = {}
    for _, it in ipairs(T.liveItems()) do ids[#ids + 1] = it.id end
    w:own(ids)
    for _, u in ipairs(H.RunUpgrades) do
        w:upgrade(u.id, w.ctrl:getRunUpgradeMaxLevel(u))
    end
    for _, spec in ipairs(Decks.all()) do w:deck(spec.id, spec.max_level or 5) end
    w.state.active_deck_id = "standard"; w:invalidate()

    local gtypes = { "hu", "zoom", "six_max", "ko" }
    local stakes = { "s001", "s002", "s003", "s004" }
    local n = 0
    for r = 0, 5 do
        for c = 0, 5 do
            n = n + 1
            local ok = pcall(function() w:open(stakes[(n % #stakes) + 1], gtypes[((r + c) % #gtypes) + 1], { r, c }) end)
            if not ok then break end
        end
    end
    local opened = #w:tables()
    local cap = w.ctrl:currentFocusCapacity()

    -- the swarm over a 6x6 board of 260x140 panels
    local hbs, panels = {}, {}
    local function rebuild()
        hbs, panels = {}, {}
        for i, t in ipairs(w:tables()) do
            local TableGrid = require("models.table_grid")
            local r, c = TableGrid.unpack(t.slot or 0)
            local x, y, pw, ph = 20 + c * 262, 20 + r * 145, 255, 138
            panels[#panels + 1] = { x = x, y = y, w = pw, h = ph, idx = i, table_id = t._id, heater = t:hasStatus("heater") }
            local busted = (t.stack or 0) <= 0
            hbs[#hbs + 1] = { x = x, y = y, w = pw, h = ph, action = busted and "rebuy" or "deal", idx = i, table_id = t._id }
        end
    end
    local ctrl = w.ctrl
    local dispatcher = function(hb)
        if hb.action == "deal" then ctrl:onCursorDeal(hb) end
        ctrl._deal_by_cursor = true
        if hb.action == "deal" then ctrl:dealHand(hb.idx) elseif hb.action == "rebuy" then ctrl:rebuyTable(hb.idx) end
        ctrl._deal_by_cursor = nil
    end
    local hooks = {
        on_clash    = function(panel) ctrl:onCursorClash(panel) end,
        on_lit_deal = function(hb) ctrl:onLitCursorDeal(hb) end,
    }
    CursorPool.reset()

    local STEP = 1 / 30
    local peak_hps, bad_status, counters_fell = 0, nil, nil
    local last_hands = 0
    local ok, err = pcall(function()
        for i = 1, math.floor(120 / STEP) do
            rebuild()
            CursorPool.update(STEP, hbs, ctrl.ctx, dispatcher, panels, hooks)
            w:tick(STEP, STEP)
            peak_hps = math.max(peak_hps, ctrl.ctx.hands_per_second or 0)
            local hands = w.state.total_hands_played or 0
            if hands < last_hands then counters_fell = ("total_hands_played fell from %d to %d"):format(last_hands, hands) end
            last_hands = hands
            if i % 30 == 0 then
                for _, t in ipairs(w:tables()) do
                    for _, s in ipairs(t.statuses or {}) do
                        if s.kind ~= "tilt" and s.kind ~= "heater" then bad_status = s.kind end
                    end
                end
            end
        end
    end)
    local b = w.state.bankroll
    local finite = type(b) == "number" and b == b and b < math.huge and b > -math.huge
    local dealt, cursors = 0, #CursorPool.cursors()
    for _, t in ipairs(w:tables()) do dealt = dealt + t.hands_played end

    check("smoke:full_board", "runs", ok == true, ok and "two minutes of a full board threw nothing" or ("THREW: " .. tostring(err)))
    check("smoke:full_board", "board", opened == CAP.MAX_TABLES and cap == CAP.MAX_TABLES,
        ("%d tables open (the whole %d-table board) with Focus capacity %d"):format(opened, CAP.MAX_TABLES, cap))
    check("smoke:full_board", "swarm", cursors == 6, ("%d cursors on the felt (Cursor L5 + the Laptop)"):format(cursors))
    check("smoke:full_board", "money", finite, ("bankroll after two minutes: %s"):format(tostring(b)))
    check("smoke:full_board", "hands", dealt > 200 and (w.state.total_hands_played or 0) >= dealt and not counters_fell,
        ("%d hands played across the board, hands-played counter at %d%s"):format(dealt, w.state.total_hands_played or 0, counters_fell and ("; " .. counters_fell) or ""))
    check("smoke:full_board", "statuses", bad_status == nil, bad_status and ("an unauthorized status appeared: " .. bad_status) or "only tilt and heater ever sat on a table")
    check("smoke:full_board", "pace", peak_hps >= 1, ("the board's hands-per-second stamp peaked at %.1f"):format(peak_hps))

    -- Two minutes of a full board leave the event bus's recycle pool at
    -- its bound: every announcement passes a fresh table and only :event()
    -- ever borrows, so an unbounded pool kept every event ever published.
    local pool_n = w.bus and w.bus.pool and #w.bus.pool or 0
    check("smoke:full_board", "bus pool", pool_n <= 64,
        ("the event bus holds %d recycled tables after two minutes (bound 64)"):format(pool_n))

    -- Closing a table cleans up everything keyed on its id: its rolled
    -- numbers and pops, its anchors, its cached stats, and its piles are
    -- queued for the view to forget. Roll and anchor a few of its keys
    -- first so there is something to clean.
    do
        local RollingValue = require("services.RollingValue")
        local Pop          = require("services.Pop")
        local Anchors      = require("services.AnchorRegistry")
        local TableModel   = require("models.Table")
        local t = w:tables()[1]
        local id = t._id
        local rk, ak = TableModel.rollingKey(t, "table_ev"), TableModel.anchorKey(t, "pot")
        RollingValue.get(rk, 1); Pop.onChange(rk, 1); Pop.onChange(rk, 2)
        Anchors.set(ak, 1, 2, 3, 4)
        w.ctrl:tableStats(t)
        local had = RollingValue.count() > 0 and Anchors.get(ak) ~= nil
            and w.ctrl._tbl_stats and w.ctrl._tbl_stats[id] ~= nil
        w.ctrl:_finalizeRemove(w:find(t), true)
        local rv_before, pop_before, an_before = RollingValue.count(), Pop.count(), Anchors.count()
        RollingValue.forgetAll(t._rolling_keys); Pop.forgetAll(t._rolling_keys); Anchors.forgetAll(t._anchor_keys)
        local stats_gone = not (w.ctrl._tbl_stats and w.ctrl._tbl_stats[id])
        local anchor_gone = Anchors.get(ak) == nil
        local fp = w.ctrl.forget_piles or {}
        local queued = 0
        for _, k in ipairs(fp) do if k == ak or k == TableModel.anchorKey(t, "you") then queued = queued + 1 end end
        check("smoke:full_board", "close cleans", had and stats_gone and anchor_gone and queued == 2
            and RollingValue.count() == rv_before and Pop.count() == pop_before and Anchors.count() == an_before,
            ("closing table %d dropped its stats slot, its anchors (%s) and queued its %d piles; a second forget found nothing left (rolled %d, pops %d, anchors %d)"):format(
                id, tostring(anchor_gone), queued, rv_before, pop_before, an_before))
    end
end
