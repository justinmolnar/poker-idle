-- sim/cases/odds.lua
--
-- The numbers: odds, distributions and multipliers, measured through the
-- outcome model (OutcomeMath.resolvedOutcome) with the item's ctx against
-- an empty one, at the game type the copy names and at one it does not.
-- Board-count kinds (the Mirror, the Speakers, the Hanger, the Diploma)
-- get their live count set on the ctx by hand here; sim/cases/board.lua
-- proves the controller stamps those counts.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local OM = T.OutcomeMath
    local S, G = H.Stakes, H.GameTypes
    local function stake(id) return H.Lookups.findById(S, id) end
    local function gtype(id) return H.Lookups.findById(G, id) end
    local function pct(x) return ("%+.2f%%"):format(x * 100) end

    -- wc / stack share of the win dist for a ctx at (gtype, stake)
    local function odds(ctx, g, s)
        local wc, wd = OM.resolvedOutcome(ctx, gtype(g), stake(s))
        return wc, wd.stack or 0, wd
    end
    local function withOnly(items, transient, extra)
        local ctx = T.ctxOf({ items = items, transient = transient })
        for k, v in pairs(extra or {}) do ctx[k] = v end
        return ctx
    end
    local base = withOnly({})

    -- ── win chance shifts ──────────────────────────────────────────────
    if wanted("item:corkboard") then
        local c = withOnly({ "corkboard" })
        local d1 = odds(c, "hu", "s001") - odds(base, "hu", "s001")
        local d2 = odds(c, "six_max", "s002") - odds(base, "six_max", "s002")
        local d3 = odds(c, "six_max", "s004") - odds(base, "six_max", "s004")
        check("item:corkboard", "odds", math.abs(d1 - 0.05) < 1e-9 and math.abs(d2 - 0.05) < 1e-9,
            ("+5%% odds at every table: measured %s at NL2 Heads-Up, %s at NL10 6-Max; at a naked NL10K 6-Max only %s shows, because its win chance sits clamped at 0 (5%% - the 6-Max's 8%%) before the item"):format(pct(d1), pct(d2), pct(d3)))
    end

    if wanted("item:wall_hook") then
        local c3 = withOnly({ "wall_hook" }, nil, { lanes_seated = 3 })
        local c0 = withOnly({ "wall_hook" }, nil, { lanes_seated = 0 })
        local d3 = odds(c3, "zoom", "s002") - odds(base, "zoom", "s002")
        local d0 = odds(c0, "zoom", "s002") - odds(base, "zoom", "s002")
        check("item:wall_hook", "odds", math.abs(d3 - 0.03) < 1e-9 and math.abs(d0) < 1e-9,
            ("+1%% odds per table type in play: 3 lanes = %s everywhere, 0 lanes = %s"):format(pct(d3), pct(d0)))
    end

    if wanted("item:mirror") then
        local c = withOnly({ "mirror" }, nil, { hu_table_count = 3 })
        local _, s_hu = odds(c, "hu", "s001")
        local _, s0   = odds(base, "hu", "s001")
        local _, s_six = odds(c, "six_max", "s001")
        local _, s_six0 = odds(base, "six_max", "s001")
        -- the cell is added then the dist renormalised, so the share moves
        -- by a little less than 3 x 2%; it must move up at HU and not at all at 6-Max
        check("item:mirror", "stack odds", s_hu > s0 + 0.04 and math.abs(s_six - s_six0) < 1e-9,
            ("+2%% stack share per Heads-Up table open, at Heads-Up only: 3 tables took the NL2 HU stack share from %.3f to %.3f; 6-Max unchanged (%.3f)"):format(s0, s_hu, s_six))
    end

    if wanted("item:desk_speakers") then
        local c = withOnly({ "desk_speakers" }, nil, { heater_count = 4 })
        local d = odds(c, "six_max", "s003") - odds(base, "six_max", "s003")
        local c0 = withOnly({ "desk_speakers" }, nil, { heater_count = 0 })
        local d0 = odds(c0, "six_max", "s003") - odds(base, "six_max", "s003")
        check("item:desk_speakers", "odds", math.abs(d - 0.04) < 1e-9 and math.abs(d0) < 1e-9,
            ("+1%% odds everywhere per heater burning: 4 heaters = %s at NL100 6-Max, none = %s"):format(pct(d), pct(d0)))
    end

    if wanted("item:hybrid_console") then
        local c = withOnly({ "hybrid_console" }, nil, { hands_per_second = 2.5 })
        local dz = odds(c, "zoom", "s002") - odds(base, "zoom", "s002")
        local dh = odds(c, "hu", "s002") - odds(base, "hu", "s002")
        check("item:hybrid_console", "odds", math.abs(dz - 0.05) < 1e-9 and math.abs(dh) < 1e-9,
            ("+2%% odds at Zoom per hand per second: 2.5 hands/s = %s at Zoom, %s at Heads-Up"):format(pct(dz), pct(dh)))
    end

    -- ── tier shifts (analytic on the resolved dist) ────────────────────
    if wanted("item:red_rug") then
        local c = withOnly({ "red_rug" })
        local _, _, wd0 = odds(base, "six_max", "s003")
        local _, _, wd1 = odds(c, "six_max", "s003")
        local _, _, wz0 = odds(base, "zoom", "s003")
        local _, _, wz1 = odds(c, "zoom", "s003")
        local moved = wd0.large / 3
        check("item:red_rug", "shift", math.abs((wd1.stack - wd0.stack) - moved) < 1e-9 and math.abs(wz1.stack - wz0.stack) < 1e-9,
            ("1 in 3 of large 6-Max wins become stacks: stack share %.3f -> %.3f (a third of the large share, %.3f); Zoom untouched"):format(wd0.stack, wd1.stack, wd0.large))
    end

    if wanted("item:nightstand") then
        local c = withOnly({ "nightstand" })
        local _, _, wd0 = odds(base, "hu", "s002")
        local _, _, wd1 = odds(c, "hu", "s002")
        -- one size up with p = 1/12: the small share loses a twelfth, the stack share can only gain
        check("item:nightstand", "bump", math.abs(wd1.small - wd0.small * (1 - 1 / 12)) < 1e-9 and wd1.stack > wd0.stack,
            ("1 in 12 of wins land one size up: small share %.3f -> %.3f (x 11/12), stack share %.3f -> %.3f"):format(wd0.small, wd1.small, wd0.stack, wd1.stack))
    end

    -- ── decks: odds and dists ─────────────────────────────────────────
    local function deckCtx(id, L, extra)
        local ctx = T.ctxOf({ decks = { [id] = L } })
        for k, v in pairs(extra or {}) do ctx[k] = v end
        return ctx
    end

    for L = 1, 4 do
        local key = ("deck:closer:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("closer", L)
            local dh = odds(c, "hu", "s002") - odds(base, "hu", "s002")
            local dz = odds(c, "zoom", "s002") - odds(base, "zoom", "s002")
            check(key, "odds", math.abs(dh - 0.03 * L) < 1e-9 and math.abs(dz) < 1e-9,
                ("Closer L%d: %s odds at Heads-Up, %s at Zoom"):format(L, pct(dh), pct(dz)))
        end
    end
    if wanted("deck:closer:5") then
        local c = deckCtx("closer", 5)
        local dh = odds(c, "hu", "s002") - odds(base, "hu", "s002")
        check("deck:closer:5", "odds", math.abs(dh - 0.12) < 1e-9, ("Closer L5 keeps L4's +12%% at Heads-Up (%s)"):format(pct(dh)))
    end

    for L = 1, 4 do
        local key = ("deck:maniac:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("maniac", L)
            local _, _, w0 = odds(base, "six_max", "s002")
            local _, _, w1 = odds(c, "six_max", "s002")
            check(key, "dist", w1.stack > w0.stack and w1.large > w0.large and w1.small < w0.small,
                ("Maniac L%d: wins lean large and stack: small %.3f->%.3f, large %.3f->%.3f, stack %.3f->%.3f"):format(L, w0.small, w1.small, w0.large, w1.large, w0.stack, w1.stack))
        end
    end

    for L = 1, 4 do
        local key = ("deck:bounty_hunter:%d"):format(L)
        if wanted(key) then
            local unbanked = { ["s002:hu"] = true }
            local c = deckCtx("bounty_hunter", L, { unbanked = unbanked })
            local b = T.ctxOf({}); b.unbanked = unbanked
            local _, s1 = odds(c, "hu", "s002")
            local _, s0 = odds(b, "hu", "s002")
            local _, s1p = odds(c, "hu", "s003")   -- s003:hu is not in the unbanked set
            local _, s0p = odds(b, "hu", "s003")
            check(key, "stack odds", s1 > s0 and math.abs(s1p - s0p) < 1e-9,
                ("Bounty Hunter L%d: stack share at the unpaid NL10 Heads-Up lane %.3f -> %.3f; a paid lane unchanged"):format(L, s0, s1))
        end
    end

    for L = 1, 4 do
        local key = ("deck:anchor:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("anchor", L)
            local m6 = OM.tiltedLossMult(c, "six_max")
            local mh = OM.tiltedLossMult(c, "hu")
            check(key, "tilted losses", math.abs(m6 - 0.8 ^ L) < 1e-9 and mh == 1,
                ("Anchor L%d: a tilted 6-Max's forced losses x%.3f (0.8^%d); Heads-Up x1"):format(L, m6, L))
        end
    end

    -- Specialist: the pure board
    for L = 1, 4 do
        local key = ("deck:specialist:%d"):format(L)
        if wanted(key) then
            local pure = T.ctxOf({ decks = { specialist = L }, transient = { active_tables_count = 3, board_pure_gtype = "zoom" } })
            local mixed = T.ctxOf({ decks = { specialist = L }, transient = { active_tables_count = 3 } })
            check(key, "winnings", math.abs((pure.earnings_mult or 1) - 1.2 ^ L) < 1e-9 and (mixed.earnings_mult or 1) == 1,
                ("Specialist L%d: winnings x%.3f when every table is one game; x1 on a mixed board"):format(L, pure.earnings_mult or 1))
        end
    end
    if wanted("deck:specialist:capstone") then
        local pure = T.ctxOf({ decks = { specialist = 5 }, transient = { active_tables_count = 3, board_pure_gtype = "zoom" } })
        local mixed = T.ctxOf({ decks = { specialist = 5 }, transient = { active_tables_count = 3 } })
        check("deck:specialist:capstone", "pace", math.abs((pure.hand_pace_mult or 1) - 1.25) < 1e-9 and (mixed.hand_pace_mult or 1) == 1,
            ("Specialist capstone: deal speed x%.2f on a pure board, x1 mixed"):format(pure.hand_pace_mult or 1))
    end

    -- Bank: winnings per stake, and the capstone's bankroll scaling
    for L = 1, 4 do
        local key = ("deck:bank:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("bank", L)
            local per = c.earnings_per_tier or 0
            local want = 0.075 * L
            check(key, "per stake", math.abs(per - want) < 1e-9,
                ("The Bank L%d: +%.1f%% winnings per stake index (NL100 = x%.3f)"):format(L, per * 100, 1 + per * 3))
        end
    end

    -- Firehose: Zoom pace per level, and the capstone is a proc (procs.lua)
    for L = 1, 4 do
        local key = ("deck:firehose:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("firehose", L)
            local z = c.hand_pace_mult_by_gtype and c.hand_pace_mult_by_gtype.zoom or 1
            check(key, "pace", math.abs(z - 1.15 ^ L) < 1e-9 and (c.hand_pace_mult or 1) == 1,
                ("Firehose L%d: Zoom deal speed x%.3f (1.15^%d); other games x1"):format(L, z, L))
        end
    end

    -- Hot Hand: the heater's forced hand pays more, per level
    for L = 1, 4 do
        local key = ("deck:hot_hand:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("hot_hand", L)
            check(key, "heater mult", math.abs((c.heater_win_mult or 1) - 1.25 ^ L) < 1e-9,
                ("Hot Hand L%d: a heater's forced win pays x%.3f (1.25^%d)"):format(L, c.heater_win_mult or 1, L))
        end
    end

    -- Circuit Pro: reach per level (procs.lua proves the selector honours it)
    for L = 2, 4 do
        local key = ("deck:circuit_pro:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("circuit_pro", L)
            check(key, "reach", (c.ko_targets_add or 0) == L,
                ("Circuit Pro L%d: each knockout reaches +%d tables"):format(L, c.ko_targets_add or 0))
        end
    end

    -- The Master: shove base per deck level held
    for L = 1, 4 do
        local key = ("deck:master:%d"):format(L)
        if wanted(key) then
            local c = T.ctxOf({ decks = { master = L, standard = 5, closer = 3 } })
            local held = 5 + 3 + L
            check(key, "shove base", (c.shove_base or 0) > 0,
                ("The Master L%d with %d deck levels held: shove base %.3f"):format(L, held, c.shove_base or 0))
        end
    end

    -- Swarm: focus worth per level (board.lua proves the capacity)
    for L = 1, 4 do
        local key = ("deck:swarm:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("swarm", L)
            check(key, "focus worth", (c.focus_level_worth or 0) == L,
                ("Swarm L%d: each Focus level is worth +%d more"):format(L, c.focus_level_worth or 0))
        end
    end
    if wanted("deck:swarm:capstone") then
        local c = deckCtx("swarm", 5)
        check("deck:swarm:capstone", "speed", math.abs((c.cursor_speed_mult or 1) - 2) < 1e-9,
            ("Swarm capstone: cursor speed x%.1f"):format(c.cursor_speed_mult or 1))
    end

    -- Standard's per-level rerolls (rolls.lua measures them)
    for L = 1, 4 do
        local key = ("deck:standard:%d"):format(L)
        if wanted(key) then
            local c = deckCtx("standard", L)
            check(key, "rerolls", (c.stack_loss_rerolls or 0) == L,
                ("Standard L%d: a stack loss rerolls %d time(s)"):format(L, c.stack_loss_rerolls or 0))
        end
    end
    -- The readout prices the reroll (OutcomeMath.rerollAdjusted): with
    -- Standard L4 at a filled NL1M six-max the stack-loss share of a hand
    -- is q·s^5 (sim/standard_reroll's formula), the win chance is
    -- untouched below the capstone, and the table the felt says loses
    -- $150K a hand without the deck reads as a winner with it.
    if wanted("deck:standard:4") then
        local OM  = T.OutcomeMath
        local s5, g6 = stake("s005"), gtype("six_max")
        local fill = s5.fill_window.complete
        local base = T.ctxOf({ upgrades = { sharper_reads = fill, pot_control = fill } })
        local with = T.ctxOf({ upgrades = { sharper_reads = fill, pot_control = fill }, decks = { standard = 4 } })
        local wc, wd, ld = OM.resolvedOutcome(base, g6, s5)
        local wc2, _, ld2 = OM.rerollAdjusted(wc, wd, ld, with)
        local want_stack = (1 - wc) * (ld.stack ^ 5)
        local got_stack  = (1 - wc2) * ld2.stack
        local ev0 = OM.evStats(base, g6, s5).pool.ev_per_hand
        local ev4 = OM.evStats(with, g6, s5).pool.ev_per_hand
        check("deck:standard:4", "readout",
            math.abs(got_stack - want_stack) < 1e-9 and math.abs(wc2 - wc) < 1e-12 and ev0 < 0 and ev4 > 0,
            ("filled NL1M six-max: a hand is a stack loss %.4f%% of the time with four rerolls (q·s^5 = %.4f%%); EV $%.0f/hand without the deck, $%.0f with it"):format(
                got_stack * 100, want_stack * 100, ev0, ev4))
    end

    -- ── the run upgrades through the fill model ────────────────────────
    -- Sharper Reads raises win chance toward the stake's cap; Pot Control
    -- moves the win dist; each level fills a stake's window one unit.
    local function fillWc(id, L, g, s)
        local ctx = T.ctxOf({ upgrades = { [id] = L } })
        return odds(ctx, g, s)
    end
    local up_ids = {}
    for _, u in ipairs(H.RunUpgrades) do up_ids[u.id] = u end
    if up_ids.sharper_reads then
        local prev = odds(base, "six_max", "s001")
        for L = 1, (up_ids.sharper_reads.max_level or 1) do
            local key = ("upgrade:sharper_reads:%d"):format(L)
            if wanted(key) then
                local wc = fillWc("sharper_reads", L, "six_max", "s001")
                local wc2 = fillWc("sharper_reads", L, "six_max", "s002")
                check(key, "odds", wc >= prev,
                    ("Sharper Reads L%d: NL2 6-Max win chance %.3f (was %.3f at L%d); NL10 %.3f"):format(L, wc, prev, L - 1, wc2))
                prev = wc
            end
        end
    end
    if up_ids.pot_control then
        local _, prev = odds(base, "six_max", "s001")
        for L = 1, (up_ids.pot_control.max_level or 1) do
            local key = ("upgrade:pot_control:%d"):format(L)
            if wanted(key) then
                local _, st = fillWc("pot_control", L, "six_max", "s001")
                check(key, "stack share", st >= prev,
                    ("Pot Control L%d: NL2 6-Max stack share %.3f (was %.3f at L%d)"):format(L, st, prev, L - 1))
                prev = st
            end
        end
    end

    -- Calculator: the strength multiplier scales the gain, not the level count
    if wanted("item:calculator") then
        local lvl = 3
        local c0 = T.ctxOf({ upgrades = { sharper_reads = lvl } })
        local c1 = T.ctxOf({ items = { "calculator" }, upgrades = { sharper_reads = lvl } })
        local wc0 = odds(c0, "six_max", "s001")
        local wc1 = odds(c1, "six_max", "s001")
        local naked = odds(base, "six_max", "s001")
        check("item:calculator", "strength", math.abs((c1.run_upgrade_strength_mult or 1) - 1.15) < 1e-9 and (wc1 - naked) > (wc0 - naked) * 1.1,
            ("Sharper Reads L%d gains %.4f win chance naked, %.4f with the Calculator (x1.15 strength)"):format(lvl, wc0 - naked, wc1 - naked))
    end

    -- Bookshelf: one more effective level at every stake (the window's ceiling)
    if wanted("item:bookshelf") then
        local window = stake("s001").fill_window
        local r_plain = OM.fillRatio(window.complete + 1, window, {})
        local r_shelf = OM.fillRatio(window.complete + 1, window, { run_upgrade_bonus_levels = 1 })
        check("item:bookshelf", "ceiling", r_plain == 1 and r_shelf > 1,
            ("one level past NL2's window fills %.2f without the Bookshelf, %.2f with it (the ceiling rose one level)"):format(r_plain, r_shelf))
    end

    -- High Roller Pass: finished tournaments back the cash tables at their stake
    if wanted("item:shower_head") then
        local w = T.world()
        local ko = w:open("s002", "ko")
        local hu = w:open("s002", "hu")
        local far = w:open("s001", "hu")
        w:own({ "prize_vase", "shower_head" })
        ko.ko.finish_count = 3
        w:invalidate()
        local ctx = w.ctrl.ctx
        local d2 = odds(ctx, "hu", "s002") - odds(base, "hu", "s002")
        local d1 = odds(ctx, "hu", "s001") - odds(base, "hu", "s001")
        check("item:shower_head", "backing", math.abs(d2 - 0.03) < 1e-9 and math.abs(d1) < 1e-9,
            ("3 tournaments finished at NL10: %s odds at NL10 cash tables, %s at NL2"):format(pct(d2), pct(d1)))
    end
end
