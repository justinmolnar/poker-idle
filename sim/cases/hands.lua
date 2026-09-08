-- sim/cases/hands.lua
--
-- Things that happen across real hands: the punches (Gas Stove, Cast Iron
-- Pan, Headset), fast fold, the Zoom combo, the player's streak, the Copy
-- Machine's double count, the Desk Plant's tilted hands, Hot Hand's
-- forced-hand multiplier, the tilt-cooler's cost, and the money kinds that
-- only show on a resolved hand (Dusty Console, Compact Fridge, the Bank).
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local OM = T.OutcomeMath
    local PUNCH = { magnitude = 0.35, t = 6 }

    -- Tick until `t` carries no punch status and no latch, counting hands.
    local function burnOut(w, t, max_s)
        local before = t.hands_played
        local t0 = H.clock
        repeat w:tick(0.05) until (not t:hasStatus("heater") and not t:hasStatus("tilt") and t._forced_next_won == nil and t.state == "idle") or H.clock - t0 > (max_s or 120)
        return t.hands_played - before
    end

    -- ── Gas Stove: a heater wins one more hand ─────────────────────────
    if wanted("item:gas_stove") then
        local w = T.world(); local t = w:open("s001", "hu"); w:tick(0.05)
        t:applyStatus("heater", PUNCH)
        local plain = burnOut(w, t)
        local w2 = T.world(); local t2 = w2:open("s001", "hu"); w2:own("gas_stove"); w2:tick(0.05)
        local spent = 0
        w2.bus:subscribe("on_heat_spent", function() spent = spent + 1 end)
        t2:applyStatus("heater", PUNCH)
        local stove = burnOut(w2, t2)
        check("item:gas_stove", "hands", plain == 1 and stove == 2,
            ("a heater on an idle table plays %d forced hand without the stove, %d with it"):format(plain, stove))
        check("item:gas_stove", "spent once", spent == 1,
            ("the heater's spent beat fired %d time(s) across the two hands (once, when the fire went out)"):format(spent))
        local wins = t2.last_results[1].won and t2.last_results[2].won
        check("item:gas_stove", "both won", wins == true, "both forced hands were wins")
    end

    -- ── Cast Iron Pan: a tilt lands on a heater, the heater keeps its hand ─
    if wanted("item:cast_iron_pan") then
        local w = T.world(); local t = w:open("s001", "hu"); w:own("cast_iron_pan"); w:tick(0.05)
        local seen = 0
        w.bus:subscribe("on_status_applied", function(e) if e.status == "tilt" then seen = seen + 1 end end)
        t:applyStatus("heater", PUNCH)
        local before = w.state.total_tilts or 0
        local landed = t:applyStatus("tilt", { magnitude = 0.35, t = 5 })
        w.bus:drain()
        check("item:cast_iron_pan", "shrug", landed == true and t:hasStatus("heater") and not t:hasStatus("tilt") and seen == 1 and (w.state.total_tilts or 0) == before + 1,
            "the tilt counted (announced, total_tilts +1) but never became the table's status; the heater is still on it")
        check("item:cast_iron_pan", "latch", t._forced_next_won == true,
            "the heater still owns the next hand (latched to win)")
        local w2 = T.world(); local t2 = w2:open("s001", "hu"); w2:tick(0.05)
        t2:applyStatus("heater", PUNCH); t2:applyStatus("tilt", { magnitude = 0.35, t = 5 })
        check("item:cast_iron_pan", "without", t2:hasStatus("tilt") and t2._forced_next_won == false,
            "without the pan the later punch wins: the tilt landed and took the next hand (latched to lose)")
    end

    -- ── Headset: a tilt at Zoom does not follow to the next hand ───────
    if wanted("item:headset") then
        local function run(own)
            local w = T.world(); local t = w:open("s001", "zoom"); if own then w:own("headset") end; w:tick(0.05)
            w.ctrl:dealHand(w:find(t))
            local guard = 0
            repeat w:tick(0.05); guard = guard + 1 until (t.script and t.script_idx < #t.script and t.state ~= "idle" and t.state ~= "settling") or guard > 100
            t:applyStatus("tilt", { magnitude = 0.35, t = 5 })   -- mid-hand: ends this hand as a loss
            T.untilHands(w, t, 1, 30)
            -- the interrupted hand's successor is dealt inside _finalizeHand, so
            -- "the tilt follows" reads as the forced hand already live (_punch_live)
            local follows = (t._forced_next_won ~= nil) or (t._punch_live == true)
            return follows, t:hasStatus("tilt"), t.last_results[#t.last_results].won
        end
        local follows0, tilt0, won0 = run(false)
        local follows1, tilt1, won1 = run(true)
        check("item:headset", "one hand", follows0 == true and tilt0 and follows1 == false and not tilt1 and won0 == false and won1 == false,
            ("a tilt mid-hand at Zoom ends that hand as a loss either way (won %s / %s); without the Headset the next hand plays as the tilt's forced loss (%s) and the tilt stays (%s), with it nothing follows (%s, tilt %s)"):format(
                tostring(won0), tostring(won1), tostring(follows0), tostring(tilt0), tostring(follows1), tostring(tilt1)))
    end

    -- ── Handheld: a loss at Zoom deals the next hand now ───────────────
    if wanted("item:handheld") then
        local w = T.world(); local t = w:open("s001", "zoom"); w:tick(0.05)
        T.playHand(w, t, { won = false, tier = "small" })
        local idle_without = t.state
        local w2 = T.world(); local t2 = w2:open("s001", "zoom"); w2:own("handheld"); w2:tick(0.05)
        T.playHand(w2, t2, { won = false, tier = "small" })
        local state_with = t2.state
        local w3 = T.world(); local t3 = w3:open("s001", "hu"); w3:own("handheld"); w3:tick(0.05)
        T.playHand(w3, t3, { won = false, tier = "small" })
        check("item:handheld", "fast fold", idle_without == "idle" and state_with ~= "idle" and t3.state == "idle",
            ("after a Zoom loss the table is %s without the Handheld and %s with it; a Heads-Up loss with it stays %s"):format(idle_without, state_with, t3.state))
    end

    -- ── Washing Machine: wins in a row deal faster ─────────────────────
    if wanted("item:washing_machine") then
        local w = T.world(); local t = w:open("s001", "zoom"); w:own("washing_machine"); w:tick(0.05)
        -- the table publishes its script pace each frame: read it one frame into a hand
        local function paceOf()
            w.ctrl:dealHand(w:find(t)); w:tick(0.05)
            local p = t._script_pace
            T.untilHands(w, t, 1, 30)
            return p
        end
        local r = T.stub(OM, "sampleOutcome", function() return false, "small" end)
        local p_first = paceOf()   -- a loss: combo 0
        r()
        r = T.stub(OM, "sampleOutcome", function() return true, "small" end)
        for _ = 1, 10 do paceOf() end
        local combo = t._combo
        local p_combo = paceOf()
        r()
        r = T.stub(OM, "sampleOutcome", function() return false, "small" end)
        paceOf(); r()
        check("item:washing_machine", "combo", combo == 10 and t._combo == 0,
            ("ten wins in a row read combo %d; a loss reset it to %d"):format(combo, t._combo))
        check("item:washing_machine", "pace", math.abs(p_combo / p_first - 1.5) < 1e-6,
            ("the hand dealt at combo 10 ran at x%.3f the pace of the first (1 + 0.05 x 10, capped x1.5)"):format(p_combo / p_first))
    end

    -- ── Cutting Board: the player's own streak ────────────────────────
    if wanted("item:cutting_board") then
        local w = T.world(); local t = w:open("s001", "hu"); w:own("cutting_board"); w:tick(0.05)
        local r1 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        local r2 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        local r3 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        local streak = w.ctrl.manual_combo
        local ratio = r3.delta / r1.delta
        T.playHand(w, t, { won = true, tier = "medium", bb = 10, cursor = true })
        local after_cursor = w.ctrl.manual_combo
        T.playHand(w, t, { won = false, tier = "small", bb = 10 })
        local after_loss = w.ctrl.manual_combo
        check("item:cutting_board", "streak", streak == 3 and math.abs(ratio - 1.2) < 1e-6,
            ("three wins dealt by hand: streak %d, the third paid x%.2f the first (1 + 0.1 x 2)"):format(streak, ratio))
        check("item:cutting_board", "cursor", after_cursor == 3 and after_loss == 0,
            ("a cursor's win left the streak at %d; a loss dealt by hand reset it to %d"):format(after_cursor, after_loss))
    end

    -- ── Copy Machine: a Zoom hand counts as two ────────────────────────
    if wanted("item:copy_machine") then
        local w = T.world(); local z = w:open("s001", "zoom"); local h = w:open("s001", "hu")
        w:own({ "receipt_printer", "copy_machine" }); w:tick(0.05)
        local before = w.state.total_hands_played or 0
        local byg = (w.state.total_hands_by_gtype and w.state.total_hands_by_gtype.zoom) or 0
        T.playHand(w, z, { won = true, tier = "small" })
        local after_zoom = w.state.total_hands_played - before
        local byg_after = w.state.total_hands_by_gtype.zoom - byg
        T.playHand(w, h, { won = true, tier = "small" })
        local after_hu = w.state.total_hands_played - before - after_zoom
        check("item:copy_machine", "counts", after_zoom == 2 and byg_after == 2 and after_hu == 1,
            ("a Zoom hand moved hands played by %d (and Zoom hands by %d); a Heads-Up hand by %d"):format(after_zoom, byg_after, after_hu))
        -- and the hand-based deck XP rule weighs it twice
        local w2 = T.world(); local z2 = w2:open("s001", "zoom"); w2:own({ "receipt_printer", "copy_machine" }); w2:deck("firehose", 0); w2:tick(0.05)
        local seen
        local r = T.stub(w2.ctrl, "_grantDeckXp", function(_, ev) if ev.stake_buy_in then seen = ev end end)
        T.playHand(w2, z2, { won = true, tier = "small" }); r()
        check("item:copy_machine", "xp", seen and seen.hand_units == 2,
            ("the hand's deck XP event carried hand_units = %s"):format(tostring(seen and seen.hand_units)))
    end

    -- ── Desk Plant: a tilt's hands at 6-Max lose smaller ──────────────
    if wanted("item:desk_plant") then
        local function tiltedLossDist(own)
            local w = T.world(); local t = w:open("s001", "six_max"); if own then w:own({ "bonsai", "desk_plant" }) end; w:tick(0.05)
            local captured
            local r = T.stub(OM, "sampleOutcome", function(wc, wd, ld, ctx, g, forced) if forced == false then captured = ld end return false, "small" end)
            t:applyStatus("tilt", { magnitude = 0.35, t = 5 })
            T.untilHands(w, t, 1, 60)
            r()
            return captured
        end
        local ld0, ld1 = tiltedLossDist(false), tiltedLossDist(true)
        check("item:desk_plant", "shape", ld0 and ld1 and ld1.small > ld0.small and ld1.stack < ld0.stack,
            ("the tilt's forced hand at 6-Max sampled losses small %.3f -> %.3f, stack %.3f -> %.3f"):format(ld0 and ld0.small or 0, ld1 and ld1.small or 0, ld0 and ld0.stack or 0, ld1 and ld1.stack or 0))
    end

    -- ── Hot Hand: the heater's forced hand pays more ──────────────────
    if wanted("deck:hot_hand:2") then
        local function heaterDelta(level)
            local w = T.world(); local t = w:open("s001", "hu"); if level > 0 then w:deck("hot_hand", level) end; w:tick(0.05)
            local r = T.stub(OM, "rollTierMagnitude", function() return 10 end)
            local r2 = T.stub(OM, "sampleOutcome", function(wc, wd, ld, ctx, g, forced) return forced ~= false, "medium" end)
            t:applyStatus("heater", PUNCH)
            T.untilHands(w, t, 1, 60)
            r(); r2()
            return t.last_results[#t.last_results].delta
        end
        local d0, d2 = heaterDelta(0), heaterDelta(2)
        check("deck:hot_hand:2", "forced hand", math.abs(d2 / d0 - 1.25 ^ 2) < 1e-6,
            ("the heater's forced win paid $%.2f with no deck, $%.2f at Hot Hand L2 (x%.4f)"):format(d0, d2, d2 / d0))
    end

    -- ── Dusty Console: stack winnings x1.5 ───────────────────────────
    if wanted("item:dusty_console") then
        local w = T.world(); local t = w:open("s001", "hu"); w:tick(0.05)
        local r0 = T.playHand(w, t, { won = true, tier = "stack", bb = 100 })
        local m0 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        w:own("dusty_console")
        local r1 = T.playHand(w, t, { won = true, tier = "stack", bb = 100 })
        local m1 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        check("item:dusty_console", "stacks", math.abs(r1.delta / r0.delta - 1.5) < 1e-6 and math.abs(m1.delta / m0.delta - 1) < 1e-6,
            ("a stack win paid x%.2f with the console; a medium win x%.2f"):format(r1.delta / r0.delta, m1.delta / m0.delta))
    end

    -- ── Compact Fridge: the run's first stack loss costs nothing ───────
    if wanted("item:compact_fridge") then
        local w = T.world(); local t = w:open("s001", "hu"); w:own("compact_fridge"); w:tick(0.05)
        -- the void zeroes the loss before it reaches the table's stack (the
        -- hand's own record still shows the loss it rolled)
        local s0 = t.stack
        T.playHand(w, t, { won = false, tier = "stack", bb = 50 })
        local s1 = t.stack
        T.playHand(w, t, { won = false, tier = "stack", bb = 50 })
        local s2 = t.stack
        check("item:compact_fridge", "void", s1 == s0 and s2 < s1,
            ("the run's first stack loss left the table's stack at $%.2f; the second took it to $%.2f"):format(s1, s2))
    end

    -- ── The Bank: winnings per stake ──────────────────────────────────
    if wanted("deck:bank:2") then
        local w = T.world(); local t = w:open("s003", "hu"); w:tick(0.05)
        local r0 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        w:deck("bank", 2)
        local r1 = T.playHand(w, t, { won = true, tier = "medium", bb = 10 })
        local idx = H.Lookups.indexById(H.Stakes, "s003")
        local want = 1 + 0.075 * 2 * idx
        check("deck:bank:2", "per stake", math.abs(r1.delta / r0.delta - want) < 1e-6,
            ("at NL100 (stake %d) a win pays x%.3f at The Bank L2 (1 + 0.15 x %d)"):format(idx, r1.delta / r0.delta, idx))
    end

    -- ── Firehose: Zoom hands are faster per level ──────────────────────
    if wanted("deck:firehose:3") then
        local w = T.world(); local z = w:open("s001", "zoom"); w:tick(0.05)
        local _, s0 = T.playHand(w, z, { won = true, tier = "small" })
        w:deck("firehose", 3)
        local _, s3 = T.playHand(w, z, { won = true, tier = "small" })
        check("deck:firehose:3", "pace", s3 < s0 / 1.3,
            ("a Zoom hand took %.2fs with no deck, %.2fs at Firehose L3 (1.15^3 = x1.52)"):format(s0, s3))
    end

    -- ── the base rule: a stack loss at 6-Max tilts a neighbour (in play) ─
    if wanted("proc:tilt_cooler") then
        local w = T.world(); local six = w:open("s001", "six_max", { 0, 0 }); local hu = w:open("s001", "hu", { 0, 1 }); w:tick(0.05)
        T.playHand(w, six, { won = false, tier = "stack", bb = 100 })
        check("proc:tilt_cooler", "in play", hu:hasStatus("tilt") or hu._forced_next_won == false,
            "a real stack loss at the 6-Max left the adjacent Heads-Up tilted")
    end
end
