-- sim/ko_finish.lua
--
-- Tournaments played through the real engine (GrindController, Table,
-- HandScript, KoModel.settleHand): a KO table dealt, played to the end,
-- re-entered, many times.
--
-- Asserts (default):
--   chips     the stacks on the table always add up to 8 x 10 big blinds
--   ends      every tournament ends, the longest under 40 hands; finishes
--             are 1..8
--   readout   evStats' chance of 1st is within 4 points of the rate the
--             table reaches (NL2 bare, NL10 with Sharper Reads + Pot
--             Control 5)
--   reach     the readout's 1st place rises with Sharper Reads, Pot
--             Control, a winnings multiplier and a position bonus
--   punches   a heater at the start of every tournament raises the real
--             1st-place rate; a tilt lowers it
--   size-up   a pending "next win one size up" lifts a tournament win
--   void      The Fridge voids a tournament stack loss: the seats go back
--
-- Report: `lua sim/ko_finish.lua report [n=2000] [stake=s001]` prints the
-- finish spread and hand counts per case instead. KO_UP=<level> limits it
-- to Sharper Reads and Pot Control both at that level.

package.path = "./?.lua;" .. package.path
math.log10 = math.log10 or function(x) return math.log(x, 10) end   -- LuaJIT has it
local H = require("sim.harness")
local OutcomeMath = require("models.outcome_math")
local Stub = require("sim.love_stub")
local c = Stub.checker()

-- Play `n` tournaments at `stake`. setup: upgrades = { id = level },
-- items = { ids }, each_tournament(w, t) at its first hand, each_tick(w, t).
-- Returns finishes[1..8], hands list, readout 1st, and the max chip error.
local function play(n, stake_id, setup)
    setup = setup or {}
    math.randomseed(12345)
    local w = H.world({ bankroll = 1e12 })
    local ctrl = w.ctrl
    ctrl.gtypeAvailable = function() return true end
    for id, lvl in pairs(setup.upgrades or {}) do w:upgrade(id, lvl) end
    if setup.items then w:own(setup.items) end
    w:open(stake_id, "ko")
    local t = w:tables()[1]
    local stake = H.Lookups.findById(H.Stakes, stake_id)
    local gtype = H.Lookups.findById(H.GameTypes, "ko")
    local ev = OutcomeMath.evStats(t:effectiveCtx(ctrl.ctx), gtype, stake, { table = t })
    local pool_chips = 8 * (gtype.starting_stack_bb or 10) * stake.bb

    local finishes, hands, done, max_err = {}, {}, 0, 0
    local seen = t.ko.finish_count or 0
    local start_hands, fresh = t.hands_played or 0, true
    ctrl:dealHand(1)
    local guard = 0
    while done < n and guard < n * 4000 do
        guard = guard + 1
        if fresh and t.ko:isPlaying() then
            fresh = false
            if setup.each_tournament then setup.each_tournament(w, t) end
        end
        w:tick(0.5, 0.5)
        if setup.each_tick then setup.each_tick(w, t) end
        if t.seat_stacks and t.ko:isPlaying() then
            local sum = 0
            for _, v in pairs(t.seat_stacks) do sum = sum + v end
            max_err = math.max(max_err, math.abs(sum - pool_chips))
        end
        if (t.ko.finish_count or 0) > seen then
            seen = t.ko.finish_count
            done = done + 1
            local f = t.last_finish or 0
            finishes[f] = (finishes[f] or 0) + 1
            hands[#hands + 1] = (t.hands_played or 0) - start_hands
            start_hands = t.hands_played or 0
            t.ko:drainPayout()
            ctrl:rebuyTable(1)
            ctrl:dealHand(1)
            fresh = true
        end
    end
    return { finishes = finishes, hands = hands, n = done, max_err = max_err,
             readout = ev and ev.pool.pos_probs[1] or 0, first = (finishes[1] or 0) / math.max(1, done) }
end

local function line(label, r)
    table.sort(r.hands)
    local sum = 0
    for _, h in ipairs(r.hands) do sum = sum + h end
    local spread = {}
    for f = 1, 8 do spread[#spread + 1] = ("%d:%4.1f"):format(f, 100 * (r.finishes[f] or 0) / math.max(1, r.n)) end
    print(("%-22s n=%d  1st %5.1f%% (readout %5.1f%%)  hands avg %.1f med %d max %d"):format(
        label, r.n, 100 * r.first, 100 * r.readout, sum / math.max(1, #r.hands),
        r.hands[math.max(1, math.floor(#r.hands / 2))] or 0, r.hands[#r.hands] or 0))
    print("    " .. table.concat(spread, "  "))
end

-- ── report ──────────────────────────────────────────────────────────────
if arg and arg[1] == "report" then
    local N, STAKE = tonumber(arg[2]) or 2000, arg[3] or "s001"
    print(("KO at %s, %d tournaments per case"):format(STAKE, N))
    if os.getenv("KO_UP") then
        local lv = tonumber(os.getenv("KO_UP"))
        line("SR+PC " .. lv, play(N, STAKE, { upgrades = { sharper_reads = lv, pot_control = lv } }))
        return
    end
    line("naked",           play(N, STAKE))
    line("Sharper Reads 5", play(N, STAKE, { upgrades = { sharper_reads = 5 } }))
    line("Pot Control 5",   play(N, STAKE, { upgrades = { pot_control = 5 } }))
    return
end

-- ── chips, ends, readout ─────────────────────────────────────────────────
local bare = play(500, "s001")
c.ok(bare.max_err < 1e-4, ("the chips on the table always add up (max error %.6f)"):format(bare.max_err))
c.eq(bare.n, 500, "every tournament ends")
table.sort(bare.hands)
c.ok((bare.hands[#bare.hands] or 99) < 40, "the longest tournament is under 40 hands (" .. tostring(bare.hands[#bare.hands]) .. ")")
local in_range = true
for f in pairs(bare.finishes) do if f < 1 or f > 8 then in_range = false end end
c.ok(in_range, "finishes are 1..8")
c.ok(math.abs(bare.first - bare.readout) <= 0.04,
     ("NL2 bare: the readout's 1st (%.1f%%) is what the table reaches (%.1f%%)"):format(bare.readout * 100, bare.first * 100))
local up = play(500, "s002", { upgrades = { sharper_reads = 5, pot_control = 5 } })
c.ok(math.abs(up.first - up.readout) <= 0.04,
     ("NL10 SR+PC 5: the readout's 1st (%.1f%%) is what the table reaches (%.1f%%)"):format(up.readout * 100, up.first * 100))

-- ── reach: the readout moves with the build ─────────────────────────────
do
    local gtype = H.Lookups.findById(H.GameTypes, "ko")
    local stake = H.Lookups.findById(H.Stakes, "s002")
    local function first(spec, opts)
        local ctx = H.ctxOf(spec)
        for k, v in pairs(spec.raw or {}) do ctx[k] = v end
        return OutcomeMath.evStats(ctx, gtype, stake, opts).pool.pos_probs[1]
    end
    local base = first({ upgrades = { sharper_reads = 5 } })
    c.ok(first({ upgrades = { sharper_reads = 6 } }) > base, "Sharper Reads raises a tournament's 1st place")
    c.ok(first({ upgrades = { sharper_reads = 5, pot_control = 5 } }) > base, "Pot Control raises it")
    c.ok(first({ upgrades = { sharper_reads = 5 }, raw = { earnings_mult = 1.5 } }) > base, "a winnings multiplier raises it")
    c.ok(first({ upgrades = { sharper_reads = 5 }, raw = { corner_win_chance = 0.05 } }, { table = { slot = 0 } }) > base,
         "a position bonus on the table raises it")
end

-- ── punches ─────────────────────────────────────────────────────────────
do
    local base   = play(300, "s002", { upgrades = { sharper_reads = 5, pot_control = 5 } })
    local heated = play(300, "s002", { upgrades = { sharper_reads = 5, pot_control = 5 },
        each_tournament = function(_, t) t:applyStatus("heater", { magnitude = 0.35, t = 6 }) end })
    local tilted = play(300, "s002", { upgrades = { sharper_reads = 5, pot_control = 5 },
        each_tournament = function(_, t) t:applyStatus("tilt", { magnitude = 0.35, t = 6 }) end })
    c.ok(heated.first > base.first, ("a heater raises 1st place (%.1f%% -> %.1f%%)"):format(base.first * 100, heated.first * 100))
    c.ok(tilted.first < base.first, ("a tilt lowers it (%.1f%% -> %.1f%%)"):format(base.first * 100, tilted.first * 100))
end

-- ── size-up: a pending bump lifts a tournament win ──────────────────────
do
    local Table = require("models.Table")
    local w = H.world({ bankroll = 1e12 })
    w.ctrl.gtypeAvailable = function() return true end
    w:open("s001", "ko")
    local t = w:tables()[1]
    local lifted = 0
    for _ = 1, 40 do
        if t.state == "idle" then
            t._forced_next_won = true
            t._next_win_tier_up = 1
            if t:deal(w.ctrl.ctx) and t.outcome_won and Table.tierUpCount(t) == 0 then
                lifted = lifted + 1
            end
        end
        w:tick(5, 0.5)
        if not t.ko:isPlaying() then t.ko:drainPayout(); w.ctrl:rebuyTable(1) end
    end
    c.ok(lifted > 0, "a tournament win spends a pending size-up (" .. lifted .. ")")
end

-- ── void: The Fridge pushes a tournament stack loss ─────────────────────
do
    local Table = require("models.Table")
    local undone, matched = 0, true
    local orig = Table.undoChipFlow
    Table.undoChipFlow = function(self)
        local ok = orig(self)
        if ok then
            undone = undone + 1
            for k, v in pairs(self._pre_flow.stacks) do
                if self.seat_stacks[k] ~= v then matched = false end
            end
        end
        return ok
    end
    play(200, "s001", { items = { "compact_fridge" },
        each_tick = function(w) w.state.first_stack_loss_voided_this_run = nil end })
    Table.undoChipFlow = orig
    c.ok(undone > 0 and matched, "The Fridge voids a tournament stack loss: every seat goes back (" .. undone .. ")")
end

if c.report("ko_finish") > 0 then os.exit(1) end
