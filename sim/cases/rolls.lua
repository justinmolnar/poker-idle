-- sim/cases/rolls.lua
--
-- The dice: kinds that roll per hand, measured by Monte Carlo over the
-- live sampleOutcome / the live payout path, with the rate compared to the
-- copy's number. 40k draws puts the noise around ±0.5% at these rates.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local OM = T.OutcomeMath
    local N = 40000
    local function stake(id) return H.Lookups.findById(H.Stakes, id) end
    local function gtype(id) return H.Lookups.findById(H.GameTypes, id) end

    -- Stack of Books: a loss rolls again 1 in 6, keep the better.
    if wanted("item:stack_of_books") then
        local ctx = T.ctxOf({ items = { "stack_of_books" } })
        local g, s = gtype("six_max"), stake("s002")
        local wc, wd, ld = OM.buildOutcome(nil, g, s)
        local function stackLoss(c)
            local won, tier = OM.sampleOutcome(wc, wd, ld, c, g)
            return (not won) and tier == "stack"
        end
        local p0 = (1 - wc) * ld.stack
        -- a stack loss survives the reroll only when the d6 misses (5/6) or the reroll is also a stack loss
        local p1 = p0 * (5 / 6 + (1 / 6) * (1 - wc) * ld.stack)
        local got0 = E.rate(function() return stackLoss({}) end, N, p0, 0.006, "stack-loss rate without the Books")
        local got1 = E.rate(function() return stackLoss(ctx) end, N, p1, 0.006, "stack-loss rate with the Books")
        check("item:stack_of_books", "d6", math.abs(got1 - p1) <= 0.006,
            ("NL10 6-Max stack-loss rate per hand: %.2f%% without, %.2f%% with (expected %.2f%%: a sixth of losses reroll and keep the better)"):format(got0 * 100, got1 * 100, p1 * 100))
    end

    -- Standard: reroll a stack loss once per level, keep the smallest; the
    -- capstone lets the reroll win.
    do
        -- NL10 Heads-Up naked: win chance 0.20 and a 0.20 stack share, so
        -- both the reroll and the capstone's wins are visible in 40k hands
        -- (a naked NL100M 6-Max sits at 0 win chance and cannot show wins).
        local g, s = gtype("hu"), stake("s002")
        local wc, wd, ld = OM.buildOutcome(nil, g, s)
        for L = 1, 5 do
            local key = ("deck:standard:%d"):format(L)
            if wanted(key) then
                local ctx = T.ctxOf({ decks = { standard = L } })
                local rerolls = ctx.stack_loss_rerolls or 0
                local p = (1 - wc) * (ld.stack ^ (rerolls + 1))
                if ctx.stack_loss_reroll_wins then p = (1 - wc) * ld.stack * (((1 - wc) * ld.stack) ^ rerolls) end
                local got = E.rate(function()
                    local won, tier = OM.sampleOutcome(wc, wd, ld, ctx, g)
                    return (not won) and tier == "stack"
                end, N, p, 0.006, "Standard L" .. L .. " stack-loss rate")
                check(key, "reroll", math.abs(got - p) <= 0.006,
                    ("NL10 Heads-Up naked: stack losses %.2f%% of hands with %d reroll(s)%s (expected %.2f%%; %.2f%% with no deck)"):format(
                        got * 100, rerolls, ctx.stack_loss_reroll_wins and " and rerolls may win" or "", p * 100, (1 - wc) * ld.stack * 100))
            end
        end
        if wanted("deck:standard:capstone") then
            local c4 = T.ctxOf({ decks = { standard = 4 } })
            local c5 = T.ctxOf({ decks = { standard = 5 } })
            local function winRate(c)
                return E.rate(function() local won = OM.sampleOutcome(wc, wd, ld, c, g) return won end, N, 0, 1, "win rate probe")
            end
            local r4, r5 = winRate(c4), winRate(c5)
            check("deck:standard:capstone", "wins", r5 > r4 + 0.003,
                ("with the capstone a stack loss can reroll into a win: win rate %.2f%% at L4, %.2f%% at L5 (NL10 Heads-Up naked)"):format(r4 * 100, r5 * 100))
        end
    end

    -- Closer's capstone: a stack loss at Heads-Up shrinks to large 1 in 2.
    if wanted("deck:closer:capstone") then
        local ctx = T.ctxOf({ decks = { closer = 5 } })
        local g, s = gtype("hu"), stake("s006")
        local wc, wd, ld = OM.buildOutcome(nil, g, s)
        local p = (1 - wc) * ld.stack * 0.5
        local got = E.rate(function()
            local won, tier = OM.sampleOutcome(wc, wd, ld, ctx, g)
            if won then return false end
            tier = OM.applyTierShift(tier, ctx.loss_tier_shifts, g)
            return tier == "stack"
        end, N, p, 0.006, "Closer capstone stack-loss rate")
        local gz = gtype("zoom")
        local wcz, wdz, ldz = OM.buildOutcome(nil, gz, s)
        local pz = (1 - wcz) * ldz.stack
        local gotz = E.rate(function()
            local won, tier = OM.sampleOutcome(wcz, wdz, ldz, ctx, gz)
            if won then return false end
            tier = OM.applyTierShift(tier, ctx.loss_tier_shifts, gz)
            return tier == "stack"
        end, N, pz, 0.006, "Closer capstone at Zoom")
        check("deck:closer:capstone", "shift", math.abs(got - p) <= 0.006 and math.abs(gotz - pz) <= 0.006,
            ("Heads-Up stack losses %.2f%% -> %.2f%% (half); Zoom untouched at %.2f%%"):format((1 - wc) * ld.stack * 100, got * 100, gotz * 100))
    end

    -- Maniac's capstone: each win rolls 1 in 2 for one size up and 1 in 2 for x2.
    if wanted("deck:maniac:capstone") then
        local ctx = T.ctxOf({ decks = { maniac = 5 } })
        check("deck:maniac:capstone", "kinds", math.abs((ctx.win_tier_bump_chance or 0) - 0.5) < 1e-9 and math.abs((ctx.win_payout_double_chance or 0) - 0.5) < 1e-9,
            ("bump chance %.2f, double chance %.2f on the ctx"):format(ctx.win_tier_bump_chance or 0, ctx.win_payout_double_chance or 0))
        -- the payout path: a won medium hand at NL2 Heads-Up pays 10bb x (2 half the time)
        local w = T.world(); local t = w:open("s001", "hu"); w:deck("maniac", 5)
        local doubles, n = 0, 60
        local base_delta
        for _ = 1, n do
            local r = T.playHand(w, t, { won = true, tier = "small", bb = 10 })
            if r then
                base_delta = base_delta or r.delta
                if r.delta > base_delta * 1.9 then doubles = doubles + 1 end
                if r.delta < base_delta then base_delta = r.delta end
            end
        end
        check("deck:maniac:capstone", "double", doubles >= n * 0.3 and doubles <= n * 0.7,
            ("%d of %d won hands paid double (expected about half)"):format(doubles, n))
    end

    -- Chrome Toaster's bump in play: the win tier lands one up 1 in 12
    -- (the resolved dist is checked in odds.lua; this is the live roll).
    if wanted("item:nightstand") then
        local ctx = T.ctxOf({ items = { "nightstand" } })
        local hits = E.rate(function() return love.math.random() < (ctx.win_tier_bump_chance or 0) end, N, 1 / 12, 0.006, "Toaster bump chance")
        check("item:nightstand", "roll", math.abs(hits - 1 / 12) <= 0.006,
            ("bump chance on the ctx rolls true %.2f%% of the time (1 in 12 = 8.33%%)"):format(hits * 100))
    end

    -- Trophy Shelf: a bounty pays double 1 in 4 (the live bountyAward).
    if wanted("item:trophy_shelf") then
        local w = T.world(); w:own("trophy_shelf")
        local single = H.Lookups.findById(H.Stakes, "s001").chip_award or 1
        local hits = E.rate(function() return w.ctrl:bountyAward("s001", "hu", { roll = true }) >= single * 2 end, 20000, 0.25, 0.01, "bounty doubles")
        local shown = 0
        for _ = 1, 2000 do if w.ctrl:bountyAward("s001", "hu") >= single * 2 then shown = shown + 1 end end
        check("item:trophy_shelf", "double", math.abs(hits - 0.25) <= 0.01 and shown == 0,
            ("a NL2 Heads-Up bounty (%d) paid x2 on %.1f%% of awards (1 in 4); the sidebar's display read never doubles (%d of 2000)"):format(single, hits * 100, shown))
    end
end
