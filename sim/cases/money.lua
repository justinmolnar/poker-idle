-- sim/cases/money.lua
--
-- Money that is not a hand: bounties (Gaming Poster, Pencil Holder, Tip
-- Jar), the run's opening (Starter Gift Box, Desk, Cereal Shelf), prices
-- (Rebuy Sticky Note, Ring Binder), and the two keys (Bonsai, Ultra).
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local UpgradePricing = require("models.UpgradePricing")
    local function stake(id) return H.Lookups.findById(H.Stakes, id) end

    -- ── bounties ──────────────────────────────────────────────────────
    if wanted("item:gaming_poster") then
        local w = T.world()
        local base_hu, base_zoom = w.ctrl:bountyAward("s001", "hu"), w.ctrl:bountyAward("s001", "zoom")
        w:own("gaming_poster")
        local hu, zoom = w.ctrl:bountyAward("s001", "hu"), w.ctrl:bountyAward("s001", "zoom")
        check("item:gaming_poster", "bounty", hu == base_hu * 2 and zoom == base_zoom,
            ("a NL2 Heads-Up bounty pays %d with the poster (%d without); Zoom's stays %d"):format(hu, base_hu, zoom))
    end
    if wanted("item:pencil_holder") then
        local w = T.world()
        local base = w.ctrl:bountyAward("s001", "hu")
        w:own("pencil_holder")
        local got = w.ctrl:bountyAward("s001", "hu")
        check("item:pencil_holder", "bounty", got == base + 1,
            ("a NL2 bounty pays %d with the holder (%d + 1)"):format(got, base))
    end
    if wanted("item:tip_jar") then
        local w = T.world()
        local s = stake("s003")
        local base = w.ctrl:bountyAward("s003", "hu")
        w:own("tip_jar")
        local got = w.ctrl:bountyAward("s003", "hu")
        local want = math.floor((s.chip_award or 0) * 1.5 + 0.5)
        check("item:tip_jar", "bounty", got == want and base == (s.chip_award or 0),
            ("a NL100 bounty pays %d with the jar (%d x 1.5, rounded)"):format(got, base))
    end

    -- ── the run's opening ─────────────────────────────────────────────
    if wanted("item:starter_gift_box") then
        local w = T.world({ bankroll = 100 }); w:own("starter_gift_box")
        w.state:applyStartingPerks(w.ctrl.ctx)
        check("item:starter_gift_box", "start", w.state.bankroll == 150,
            ("a run opening at $100 opens at $%.0f with the box (+50%%)"):format(w.state.bankroll))
    end
    if wanted("item:desk") then
        local w = T.world(); w:own("desk")
        local before = #w.state.tables
        w.state:applyStartingPerks(w.ctrl.ctx)
        local seeded = w.state.tables[#w.state.tables]
        check("item:desk", "start", #w.state.tables == before + 1 and seeded and seeded.stake_id == "s001",
            ("the run opens with one more table seated: %s (a NL2 cash game)"):format(
                seeded and (seeded.stake_id .. ":" .. tostring(seeded.game_type_id)) or "none"))
    end
    if wanted("item:calculator") then
        local w = T.world(); w:own("calculator")
        w.state:applyStartingPerks(w.ctrl.ctx)
        local lv = w.state.run_upgrade_levels
        check("item:calculator", "start", (lv.sharper_reads or 0) == 1 and (lv.pot_control or 0) == 1 and (lv.focus or 0) == 0,
            ("the run opens with Sharper Reads %d, Pot Control %d, Focus %d (want 1, 1, 0)"):format(
                lv.sharper_reads or 0, lv.pot_control or 0, lv.focus or 0))
        -- Through the reset itself: the levels are on the rack AND in the
        -- rollup (the controller folds them in after the perks land).
        local w2 = T.world(); w2:own("calculator")
        w2.ctrl:quickReset()
        local l2 = w2.ctrl:getRunUpgradeLevel("sharper_reads")
        local rev_ok = (w2.ctrl.ctx ~= nil)
        check("item:calculator", "reset", l2 == 1 and rev_ok,
            ("after a reset the controller reads Sharper Reads at level %d (want 1)"):format(l2))
    end
    if wanted("item:cereal_shelf") then
        local w = T.world({ bankroll = 100 }); w:own("cereal_shelf")
        w.state.last_run_biggest_pot_t1 = 42
        w.state.last_run_biggest_pot = 999
        w.state:applyStartingPerks(w.ctrl.ctx)
        check("item:cereal_shelf", "start", w.state.bankroll == 142,
            ("last run's biggest NL2 pot ($42) opens the run: $100 -> $%.0f (the $999 pot at a higher stake does not)"):format(w.state.bankroll))
    end

    -- ── prices ────────────────────────────────────────────────────────
    if wanted("item:rebuy_sticky_note") then
        local w = T.world(); local t = w:open("s002", "hu")
        local idx = w:find(t)
        local full = w.ctrl:rebuyCostFor(idx)
        w:own("rebuy_sticky_note")
        local cut = w.ctrl:rebuyCostFor(idx)
        check("item:rebuy_sticky_note", "price", math.abs(cut - full * 0.75) < 1e-9 and full == stake("s002").buy_in,
            ("a NL10 rebuy costs $%.2f with the note ($%.2f x 0.75)"):format(cut, full))
    end
    if wanted("item:ring_binder") then
        local w = T.world()
        local focus
        for _, u in ipairs(H.RunUpgrades) do if u.id == "focus" then focus = u end end
        local full = w.ctrl:getRunUpgradeNextCost(focus)
        w:own("ring_binder")
        local cut = w.ctrl:getRunUpgradeNextCost(focus)
        local want = UpgradePricing.roundPrice(focus.costs[1] * 0.85)
        check("item:ring_binder", "price", cut == want and full == UpgradePricing.roundPrice(focus.costs[1]),
            ("Focus L1 costs $%s with the binder ($%s x 0.85, rounded to the price grid)"):format(tostring(cut), tostring(full)))
    end

    -- ── keys ──────────────────────────────────────────────────────────
    if wanted("item:bonsai") then
        local w = T.world({ gates = false })
        local before = w.ctrl:gtypeAvailable("six_max")
        w:own("bonsai")
        check("item:bonsai", "key", before == false and w.ctrl:gtypeAvailable("six_max") == true and w.state.six_max_unlocked == true,
            "6-Max is closed until the Bonsai is owned; owning it latches the state's 6-Max key")
    end
    if wanted("item:ultra_stake") then
        -- The pass is a gate, not a thing you own: its base line carries no
        -- effect, and the Ultra key itself sits on the Act 3 (corrupt) line,
        -- which is outside this audit by the designer's rule. What the base
        -- line promises is only that it is a gate outside the shelves.
        local it
        for _, c in ipairs(H.Catalog) do if c.id == "ultra_stake" then it = c end end
        local w = T.world()
        local before = w.state.ultra_unlocked
        w:own("ultra_stake")
        check("item:ultra_stake", "gate", it and it.gate == true and #(it.effects or {}) == 0 and it.requires_act3 == true and before == false and w.state.ultra_unlocked == false,
            "a gate item (Act 3 only, no shelf, no base effect): owning the base line changes nothing; the Ultra key is on its Act 3 line, outside this audit")
    end
end
