-- sim/cases/cursors.lua
--
-- The swarm, driven headlessly: services/CursorPool with hand-built hit
-- boxes and panels, the dispatcher and hooks wired the way
-- states/GrindState wires them. Covers the Cursor and Cursor Speed
-- upgrades, Box of Mice, Laptop, Gaming Keyboard, Wacom Tablet, Telephone,
-- Desk Lamp, Glass Partition, Old Keyboard, Cleaning Robot, the base clash,
-- and the Swarm capstone.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local CursorPool = require("services.CursorPool")
    local Balance    = require("data.balance")
    local STEP = 1 / 60

    -- A board of panels: table i sits at a 300x250 cell on a 1600x900
    -- screen. Returns the hit boxes (deal, or rebuy when busted) and the
    -- panels the view would have noted, plus a step() that runs one frame
    -- of the pool with GrindState's dispatcher and hooks.
    local function swarm(w, opts)
        opts = opts or {}
        local S = { hbs = {}, panels = {}, deals = {}, clashes = {}, lit_deals = {} }
        function S.rebuild()
            S.hbs, S.panels = {}, {}
            for i, t in ipairs(w:tables()) do
                local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
                local x, y, pw, ph = 40 + col * 300, 40 + row * 250, 260, 200
                S.panels[#S.panels + 1] = { x = x, y = y, w = pw, h = ph, idx = i, table_id = t._id,
                                            heater = t:hasStatus("heater") }
                local busted = (t.stack or 0) <= 0
                if not opts.no_hbs then
                    S.hbs[#S.hbs + 1] = { x = x, y = y, w = pw, h = ph, action = busted and "rebuy" or "deal",
                                          idx = i, table_id = t._id }
                end
            end
        end
        local ctrl = w.ctrl
        S.dispatcher = function(hb)
            S.deals[#S.deals + 1] = hb
            if hb.action == "deal" then ctrl:onCursorDeal(hb) end
            ctrl._deal_by_cursor = true
            if hb.action == "deal" then ctrl:dealHand(hb.idx) elseif hb.action == "rebuy" then ctrl:rebuyTable(hb.idx) end
            ctrl._deal_by_cursor = nil
        end
        S.hooks = {
            on_clash    = function(panel) S.clashes[#S.clashes + 1] = panel; ctrl:onCursorClash(panel) end,
            on_lit_deal = function(hb) S.lit_deals[#S.lit_deals + 1] = hb; ctrl:onLitCursorDeal(hb) end,
        }
        function S.step(dt)
            S.rebuild()
            CursorPool.update(dt or STEP, S.hbs, ctrl.ctx, S.dispatcher, S.panels, S.hooks)
        end
        function S.center(i)
            local p = S.panels[i]
            return p.x + p.w * 0.5, p.y + p.h * 0.5
        end
        S.rebuild()
        return S
    end

    -- Put cursor c on a straight seek toward hit box i's centre from `dist` px to the left.
    local function aim(S, c, i, dist)
        local cx, cy = S.center(i)
        c.state, c.target_idx = "seeking", i
        c.target_offset_x, c.target_offset_y = S.hbs[i].w * 0.5, S.hbs[i].h * 0.5
        c.x, c.y = cx - (dist or 0), cy
        c.start_x, c.start_y, c.total_dist = c.x, c.y, math.max(1, dist or 1)
        c.vx, c.vy, c.arc_scale, c._hold = 0, 0, 0, nil
    end

    -- A world with the swarm open and n cursors.
    local function swarmWorld(n, extra)
        local w = T.world(); w:own("box_of_mice"); if extra then w:own(extra) end
        w:upgrade("cursor", n)
        CursorPool.reset()
        return w
    end

    -- ── Box of Mice, the Cursor upgrade, the Laptop: how many ──────────
    do
        local w = T.world(); w:upgrade("cursor", 3); w:open("s001", "hu"); CursorPool.reset()
        local S = swarm(w); S.step()
        local without = #CursorPool.cursors()
        w:own("box_of_mice"); S.step()
        local with = #CursorPool.cursors()
        check("item:box_of_mice", "opens", without == 0 and with == 3,
            ("three Cursor levels put %d cursors on the felt without the box, %d with it"):format(without, with))
    end
    -- Every level the upgrade has (five since 2026-09-28): the count follows it.
    local cursor_max = 1
    for _, u in ipairs(H.RunUpgrades) do if u.id == "cursor" then cursor_max = u.max_level or 1 end end
    for L = 1, cursor_max do
        local key = ("upgrade:cursor:%d"):format(L)
        if wanted(key) then
            local w = swarmWorld(L); w:open("s001", "hu")
            local S = swarm(w); S.step()
            check(key, "count", #CursorPool.cursors() == L,
                ("Cursor L%d: %d cursors in the pool"):format(L, #CursorPool.cursors()))
        end
    end
    if wanted("item:laptop_terminal") then
        local w = swarmWorld(2, "laptop_terminal"); w:open("s001", "hu")
        local S = swarm(w); S.step()
        check("item:laptop_terminal", "count", #CursorPool.cursors() == 3,
            ("Cursor L2 + the Laptop: %d cursors (2 + 1)"):format(#CursorPool.cursors()))
    end

    -- ── speed: px travelled on a straight seek in 0.4 s ───────────────
    local function travel(w)
        w:open("s001", "hu"); CursorPool.reset()
        local S = swarm(w, { no_hbs = false }); S.step()
        local c = CursorPool.cursors()[1]
        aim(S, c, 1, 1400)
        local x0 = c.x
        for _ = 1, 24 do S.step(STEP) end
        return c.x - x0
    end
    local base_travel = travel(swarmWorld(1))
    for L = 1, 8 do
        local key = ("upgrade:cursor_speed:%d"):format(L)
        if wanted(key) then
            local w = swarmWorld(1); w:upgrade("cursor_speed", L)
            local d = travel(w)
            local want = 1.25 ^ L
            check(key, "speed", math.abs(d / base_travel - want) < 0.02 * want,
                ("Cursor Speed L%d: a straight seek covers x%.3f the base distance in 0.4 s (1.25^%d = x%.3f)"):format(L, d / base_travel, L, want))
        end
    end
    if wanted("item:gaming_keyboard") then
        local d = travel(swarmWorld(1, "gaming_keyboard"))
        check("item:gaming_keyboard", "speed", math.abs(d / base_travel - 1.3) < 0.03,
            ("with the keyboard a cursor covers x%.3f the base distance (x1.3)"):format(d / base_travel))
    end
    if wanted("deck:swarm:capstone") then
        local w = swarmWorld(1); w:deck("swarm", 5)
        local d = travel(w)
        check("deck:swarm:capstone", "speed", math.abs(d / base_travel - 2) < 0.04,
            ("Swarm capstone: a cursor covers x%.3f the base distance (x2)"):format(d / base_travel))
    end

    -- ── Wacom Tablet: cursors click REBUY ──────────────────────────────
    if wanted("item:wacom_tablet") then
        local function tryRebuy(own)
            local w = swarmWorld(1, own and "wacom_tablet" or nil)
            local t = w:open("s001", "hu"); t.stack = 0
            local S = swarm(w); S.step()
            local c = CursorPool.cursors()[1]
            aim(S, c, 1, 0)
            S.step()
            return t.stack > 0, c.state
        end
        local r0, s0 = tryRebuy(false)
        local r1 = tryRebuy(true)
        check("item:wacom_tablet", "rebuy", r0 == false and s0 == "wandering" and r1 == true,
            "a cursor sent at a busted table's REBUY lets go of it without the tablet (rebuy box not claimable) and rebuys it with the tablet")
    end

    -- ── Telephone: no two cursors head for the same table ─────────────
    if wanted("item:telephone") then
        local function duplicates(own, trials)
            local w = swarmWorld(2, own and "telephone" or nil)
            w:open("s001", "hu"); w:open("s001", "hu")
            local S = swarm(w)
            local dup = 0
            for _ = 1, trials do
                CursorPool.reset(); S.step()
                local a, b = CursorPool.cursors()[1], CursorPool.cursors()[2]
                if a.target_idx and a.target_idx == b.target_idx then dup = dup + 1 end
            end
            return dup
        end
        local d0, d1 = duplicates(false, 200), duplicates(true, 200)
        check("item:telephone", "sync", d0 > 0 and d1 == 0,
            ("two cursors, two tables, 200 fresh spawns: both chose the same table %d times without the phone, %d with it"):format(d0, d1))
    end

    -- ── Desk Lamp: crossing a heater, 1 in 4; the lit deal lights the table ─
    if wanted("item:desk_lamp") then
        local w = swarmWorld(1, "desk_lamp")
        local t = w:open("s001", "hu")
        t:applyStatus("heater", { magnitude = 0.35, t = 600 })
        local S = swarm(w, { no_hbs = true }); S.step()
        local c = CursorPool.cursors()[1]
        local cx, cy = S.center(1)
        local rate = E.rate(function()
            c.lit, c.over_id, c.state = false, nil, "wandering"
            c.x, c.y, c.target_x, c.target_y, c.wander_timer = cx, cy, cx, cy, 5
            S.step()
            return c.lit == true
        end, 4000, 0.25, 0.02, "Desk Lamp ignite rate")
        check("item:desk_lamp", "ignite", math.abs(rate - 0.25) <= 0.02,
            ("a cursor entering a heater's panel caught fire %.1f%% of the time (1 in 4)"):format(rate * 100))
        -- the lit deal
        local w2 = swarmWorld(1, "desk_lamp"); local t2 = w2:open("s001", "hu")
        local S2 = swarm(w2); S2.step()
        local c2 = CursorPool.cursors()[1]
        c2.lit = true
        aim(S2, c2, 1, 0); S2.step()
        check("item:desk_lamp", "lit deal", #S2.lit_deals == 1 and t2:hasStatus("heater") and c2.lit == false,
            ("a lit cursor's deal lit the table (heater %s) and spent the fire (lit %s)"):format(tostring(t2:hasStatus("heater")), tostring(c2.lit)))
    end

    -- ── Glass Partition: fire passes on a clash ───────────────────────
    if wanted("item:beige_tower") then
        local function spread(own)
            local w = swarmWorld(2, own and "beige_tower" or nil)
            w:open("s001", "hu")
            local S = swarm(w, { no_hbs = true }); S.step()
            local a, b = CursorPool.cursors()[1], CursorPool.cursors()[2]
            local cx, cy = S.center(1)
            a.x, a.y, b.x, b.y = cx - 4, cy, cx + 4, cy
            a.lit, b.lit = true, false
            S.step()
            return b.lit, #S.clashes
        end
        local lit0, n0 = spread(false)
        local lit1 = spread(true)
        check("item:beige_tower", "spread", lit0 == false and lit1 == true and n0 == 1,
            "a lit cursor clashing with a dark one: the dark one stays dark without the partition and lights with it (one clash reported each time)")
    end

    -- ── the clash itself: the panel under the spark; tilt 1 in 4; the robot's heater ─
    local function clashRate(own)
        local w = swarmWorld(2, own); local t = w:open("s001", "hu")
        local S = swarm(w); S.step()
        local kinds = {}
        local restore = T.stub(t, "applyStatus", function(_, kind) kinds[kind] = (kinds[kind] or 0) + 1; return true end)
        local n = 4000
        for _ = 1, n do w.ctrl:onCursorClash(S.panels[1]) end
        restore()
        return kinds, n
    end
    if wanted("item:cleaning_robot") then
        local k0, n = clashRate(nil)
        local k1 = clashRate("cleaning_robot")
        local base = Balance.CURSOR_CLASH.chance
        local r0, r1 = (k0.tilt or 0) / n, (k1.heater or 0) / n
        check("item:cleaning_robot", "clash", math.abs(r0 - base) <= 0.02 and (k0.heater or 0) == 0 and math.abs(r1 - base) <= 0.02 and (k1.tilt or 0) == 0,
            ("a clash lands a tilt %.1f%% of the time bare (1 in %d) and a heater %.1f%% with the robot, never a tilt"):format(r0 * 100, math.floor(1 / base + 0.5), r1 * 100))
        -- the pool reports the panel under two touching cursors
        local w = swarmWorld(2); w:open("s001", "hu"); w:open("s001", "hu")
        local S = swarm(w, { no_hbs = true }); S.step()
        local a, b = CursorPool.cursors()[1], CursorPool.cursors()[2]
        local cx, cy = S.center(2)
        a.x, a.y, b.x, b.y = cx - 5, cy, cx + 5, cy
        S.step()
        check("item:cleaning_robot", "panel", #S.clashes == 1 and S.clashes[1].idx == 2 and a.state == "stunned" and b.state == "stunned",
            "two cursors touching over the second table: one clash, reported with that table's panel, both cursors stunned")
    end

    -- ── Old Keyboard: the clash deals an idle table ───────────────────
    if wanted("item:old_keyboard") then
        local function clashDeals(own)
            local w = swarmWorld(2, own and "old_keyboard" or nil); local t = w:open("s001", "hu")
            w.ctrl.ctx.cursor_clash_chance = 0     -- no punch, so only the keystroke can move the table
            local S = swarm(w, { no_hbs = true }); S.step()
            local a, b = CursorPool.cursors()[1], CursorPool.cursors()[2]
            local cx, cy = S.center(1)
            a.x, a.y, b.x, b.y = cx - 5, cy, cx + 5, cy
            S.step()
            return t.state, #S.clashes
        end
        local s0, n0 = clashDeals(false)
        local s1, n1 = clashDeals(true)
        check("item:old_keyboard", "deals", s0 == "idle" and s1 ~= "idle" and n0 == 1 and n1 == 1,
            ("a clash over an idle table leaves it %s without the keyboard and %s with it"):format(s0, s1))
    end
end
