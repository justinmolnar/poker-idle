-- sim/cases/board_rate.lua
--
-- The rail's earn rate (GrindController:boardRate): a table's measured
-- pace agrees with how many hands it actually played, the total is the
-- focus-scaled sum of $/hand x hands/min, the run's winnings and clock
-- accumulate on the board's own time, a board nobody deals falls to zero,
-- and resetRun freezes the run's $/min for the next run's tooltip.
return function(T)
    local H, check, wanted = T.H, T.check, T.wanted
    if not wanted("smoke:board_rate") then return end

    local w = T.world({ bankroll = 1e6 })
    w:open("s001", "zoom")
    w:open("s001", "hu")
    local ctrl = w.ctrl

    -- Deal every idle table the way a player clicking does (sim/act1.lua),
    -- rebuying a bust so the pace never stalls on an empty seat.
    local function dealBoard()
        for i = 1, ctrl.pool:count() do
            local t = ctrl.pool:get(i)
            if t and (t.stack or 0) <= 0 then ctrl:rebuyTable(i) end
            if t and t.state == "idle" and (t.stack or 0) > 0 then ctrl:dealHand(i) end
        end
    end
    local function worth() return (w.state.bankroll or 0) + ctrl:tiedUp() end

    local secs   = 90
    local before = worth()
    for _ = 1, secs * 60 do
        dealBoard()
        w:tick(1 / 60, 1 / 60)
    end
    local br = ctrl:boardRate()

    -- 1. The clock and the run's winnings.
    check("smoke:board_rate", "clock", math.abs((w.state.run_elapsed or 0) - secs) < 0.5,
        ("run_elapsed %.1fs after %ds of board time"):format(w.state.run_elapsed or 0, secs))
    local net = worth() - before
    check("smoke:board_rate", "net", math.abs((w.state.run_hand_net or 0) - net) < 0.05,
        ("run_hand_net %+.2f vs the board's worth moving %+.2f (rebuys are transfers)"):format(
            w.state.run_hand_net or 0, net))

    -- 2. Each table's pace is what it actually dealt: the last minute's
    --    count against the whole run's average, which at steady state agree.
    local pace_ok, pace_note = true, {}
    for _, e in ipairs(br.tables) do
        local avg = (e.tbl.hands_played or 0) / (secs / 60)
        local off = (avg > 0) and math.abs(e.hpm - avg) / avg or 1
        pace_note[#pace_note + 1] = ("%s %.0f/min (run avg %.0f)"):format(e.tbl.game_type_id, e.hpm, avg)
        if off > 0.30 or e.hpm <= 0 then pace_ok = false end
    end
    check("smoke:board_rate", "pace", pace_ok, table.concat(pace_note, ", "))

    -- 3. The total is the sum of $/hand x pace, from the same stats the
    --    felt readouts use (which already carry the focus multiplier).
    local sum = 0
    for _, e in ipairs(br.tables) do
        local st = ctrl:tableStats(e.tbl)
        sum = sum + ((st and st.ev_per_hand) or 0) * e.hpm
    end
    local want = sum
    check("smoke:board_rate", "total", math.abs(br.total - want) < 1e-6 and br.total ~= 0,
        ("board rate %+.3f/min = sum(ev x pace) %+.3f"):format(br.total, want))

    -- 4. Stop dealing: once the hands in flight have finished and fallen
    --    out of the window, the rate reads zero.
    local resting = ctrl.pool:count()
    w:tick(80, 1 / 60)
    local idle = ctrl:boardRate()
    check("smoke:board_rate", "idle", idle.total == 0 and #idle.tables == resting,
        ("%.3f/min after 80s with no deals on %d tables"):format(idle.total, #idle.tables))

    -- 5. The run ends: its $/min is frozen for the tooltip's "last run".
    local frozen = (w.state.run_hand_net or 0) / ((w.state.run_elapsed or 1) / 60)
    w.state:resetRun()
    check("smoke:board_rate", "freeze",
        math.abs((w.state.last_run_rate or 0) - frozen) < 1e-6
        and (w.state.run_hand_net or 0) == 0 and (w.state.run_elapsed or 0) == 0,
        ("last_run_rate %+.3f/min, run fields back to 0"):format(w.state.last_run_rate or 0))
end
