-- models/table_procs.lua
--
-- The poker half of the proc system: which tables a proc can reach
-- (selectors) and what it does to them (payloads). Registers into
-- services/ProcRegistry, mirroring how models/poker_effects.lua registers
-- into EffectsRegistry and models/poker_action_apply.lua into
-- PokerEventRegistry.
--
-- ─── RANGE IS TABLE ORDER ───────────────────────────────────────────────
-- "Nearby" means distance in the pool's order — which is reading order of
-- the board (models/TablePool keeps it sorted by cell), and which the
-- player controls directly by dragging tables around. Deliberately NOT
-- 2-D grid distance: the board's shape is stable now, but order is the
-- simpler relation to reason about and to explain, and it can be upgraded
-- to true adjacency later without re-tuning anything, because a table's
-- position no longer moves on its own.
--
-- `same_line` is the one selector exception, and it is deliberate: a row
-- and a column are things the player can SEE, so an item that speaks about
-- them has to mean the board's rows and columns rather than a rank distance
-- that happens to wrap at the edge. It reads (row, col) off the packed
-- slot. The `steal_nearby` router is the other: "the table beside it" is a
-- placement claim, so it measures the board's beside, not the pool's.
--
-- Nothing here caches an index. Distance is computed from the live pool at
-- fire time, which is what makes the whole system immune to the
-- index-shift bug class that has bitten this codebase before (a table
-- closing mid-frame, a drag reordering the pool, a rebuild after
-- prestige). There is no cache to invalidate.
--
-- ─── PAYLOAD CAPABILITY ─────────────────────────────────────────────────
-- Payloads receive `event.ctrl`, which is the widest reach any data-driven
-- thing has in this codebase. Keep it that way ON PURPOSE narrow: a
-- payload may call only _queueBurst, procFired and invalidateEffects.
-- Anything beyond that should become a named controller method first, so
-- the surface stays reviewable.
--
-- The list got shorter, which is the direction it should move: the sound
-- poke a swept table needed is gone, because the table now announces its
-- own move to "settling" and whoever wants to make a noise is listening.

local Lookups    = require("utils.lookups")
local Stakes     = require("data.stakes")
local GameTypes  = require("data.game_types")
local TableGrid  = require("models.table_grid")
local StatusData = require("data.statuses")

local TableProcs = {}

-- ─── Helpers ───────────────────────────────────────────────────────────

local function indexOf(pool, tbl)
    if not (pool and tbl) then return nil end
    for i, t in ipairs(pool.tables) do
        if t == tbl then return i end
    end
    return nil
end

-- Does this table match a flat { key = value } filter? Keys are checked
-- against the table first, then its game-type definition, so a spec can
-- say `chip_stack_table = false` and mean "not a tournament".
local function matches(tbl, where)
    if not where then return true end
    local gt = Lookups.findById(GameTypes, tbl.game_type_id)
    for k, v in pairs(where) do
        local actual = tbl[k]
        if actual == nil and gt then actual = gt[k] end
        if actual == nil then actual = false end
        if actual ~= v then return false end
    end
    return true
end

-- Trim a candidate list by `pick` and `max`. `rng` is the registry's
-- injected 0..1 roll — never love.math directly, so a seeded sim or test
-- harness stays deterministic.
local function narrow(list, spec, rng, event)
    if spec.pick == "random" and #list > 0 then
        -- `pick_n_field` names a ctx field that adds targets to the one
        -- random pick (Circuit Pro's ko_targets_add): sample that many
        -- distinct tables.
        local n = 1
        local field = spec.pick_n_field
        if field and event and event.ctx then n = n + (event.ctx[field] or 0) end
        if n <= 1 then
            return { list[math.floor(rng() * #list) + 1] }
        end
        local pool = {}
        for i, t in ipairs(list) do pool[i] = t end
        local out = {}
        while #out < n and #pool > 0 do
            local i = math.floor(rng() * #pool) + 1
            out[#out + 1] = table.remove(pool, i)
        end
        return out
    end
    local cap = spec.max
    if cap and #list > cap then
        local out = {}
        for i = 1, cap do out[i] = list[i] end
        return out
    end
    return list
end

-- ─── Registration ──────────────────────────────────────────────────────

function TableProcs.registerAll(reg)

    -- ── Selectors ──────────────────────────────────────────────────────

    -- No table at all: the payload acts on the run, not on a felt.
    reg:registerSelector("none", function() return {} end)

    -- The table the event happened at. Verified to still be in the pool —
    -- a resolution can name a table the pending-close sweep just removed.
    reg:registerSelector("self", function(spec, event)
        local src = event.source
        if not src or not indexOf(event.pool, src) then return {} end
        if not matches(src, spec.where) then return {} end
        return { src }
    end)

    -- Every table of one game type. This is the zoom cascade's shape.
    reg:registerSelector("gtype", function(spec, event)
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            local skip = spec.exclude_self and t == event.source
            if not skip and t.game_type_id == spec.gtype and matches(t, spec.where) then
                out[#out + 1] = t
            end
        end
        return narrow(out, spec, reg.rng, event)
    end)

    -- Tables within `radius` cells of the source ON THE BOARD, by
    -- MANHATTAN distance: "adjacent" means SHARING A SIDE — never
    -- diagonal, and never pool-order (which calls the end of one row
    -- adjacent to the start of the next). radius 1 = the four side
    -- neighbours; radius 2 adds their side neighbours (the diamond).
    -- Replaced the old pool-order "order_near" wholesale.
    reg:registerSelector("board_near", function(spec, event)
        local src = event.source
        if not src then return {} end
        local sr, sc = TableGrid.unpack(src.slot or 0)
        local r = spec.radius or 1
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            local tr, tc = TableGrid.unpack(t.slot or 0)
            local dist = math.abs(tr - sr) + math.abs(tc - sc)
            local skip = (spec.exclude_self ~= false) and t == event.source
            if dist <= r and not skip and matches(t, spec.where) then
                out[#out + 1] = t
            end
        end
        return narrow(out, spec, reg.rng, event)
    end)

    -- Any other table, ignoring position.
    -- Every table sitting at the same stake as the source. Tiers are the
    -- ladder the player climbs, so "the tables at this level" is a thing
    -- they already think in. `where` cannot express "same as the source",
    -- which is why this is a selector rather than a filter.
    reg:registerSelector("same_stake", function(spec, event)
        local src = event.source
        if not src then return {} end
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            local skip = (spec.exclude_self ~= false) and t == src
            if not skip and t.stake_id == src.stake_id
               and matches(t, spec.where) then
                out[#out + 1] = t
            end
        end
        return narrow(out, spec, reg.rng, event)
    end)

    -- The source's row or column on the board. `axis = "col"` for the
    -- column, anything else for the row. Holes are legal, so this walks
    -- the pool rather than assuming a dense rectangle.
    reg:registerSelector("same_line", function(spec, event)
        local src = event.source
        if not src then return {} end
        local sr, sc = TableGrid.unpack(src.slot or 0)
        local want_col = (spec.axis == "col")
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            local r, c = TableGrid.unpack(t.slot or 0)
            local on_line = want_col and (c == sc) or (not want_col and r == sr)
            local skip = (spec.exclude_self ~= false) and t == src
            if on_line and not skip and matches(t, spec.where) then
                out[#out + 1] = t
            end
        end
        return narrow(out, spec, reg.rng, event)
    end)

    reg:registerSelector("any_other", function(spec, event)
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            if t ~= event.source and matches(t, spec.where) then out[#out + 1] = t end
        end
        return narrow(out, spec, reg.rng, event)
    end)

    -- ── Payloads ───────────────────────────────────────────────────────

    -- The target's NEXT WINNING hand reads one tier higher (House Cat). A
    -- plain flag on the table, consumed in Table:deal after the win-side
    -- tier shifts; losses never see it. Not a status: nothing to name,
    -- show, or announce, and a refresh is a no-op.
    reg:registerPayload("next_win_tier_up", function(_spec, target, _event)
        if not target then return false end
        target._next_win_tier_up = true
        return true
    end)

    -- Put a status on the target. `escalate` scales the magnitude by
    -- something the event knows — the doc's "value scales with seats
    -- remaining" drama pass, e.g. { field = "busted_total", per = 0.15 }.
    reg:registerPayload("apply_status", function(spec, target, event)
        if not target then return false end
        -- A punch (heater/tilt) needs a table that can PLAY its forced
        -- hand. A busted target — stack 0, sitting on the REBUY screen —
        -- can't, so retarget to a random table that can rather than
        -- parking fire on a table with nothing to deal. No live table
        -- anywhere = the punch fizzles unlanded.
        local sdef = StatusData[spec.status]
        if sdef and sdef.lifetime == "punch" and (target.stack or 0) <= 0 then
            local live = {}
            for _, t in ipairs(((event.pool or {}).tables) or {}) do
                if (t.stack or 0) > 0 then live[#live + 1] = t end
            end
            if #live == 0 then return false end
            target = live[math.floor(reg.rng() * #live) + 1]
        end
        local mag = spec.magnitude or 0
        local esc = spec.escalate
        if esc and esc.field then
            mag = mag * (1 + (esc.per or 0) * (event[esc.field] or 0))
        end
        return target:applyStatus(spec.status, {
            magnitude = mag,
            t         = spec.t,
            charges   = spec.charges,
            source    = event.ghost,
            -- Ambient sources do not end hands; see Table:_maybeInterrupt.
            no_interrupt = spec.no_interrupt,
            -- Nor do their refreshes count as events; see _announceStatus.
            silent_refresh = spec.silent_refresh,
        })
    end)

    -- The mental game's active half (Cool Towel). A tilt is a PUNCH: it
    -- ends the hand it lands in and queues a forced loss on the next one
    -- (Table:interrupt). The damage still owed lives in
    -- `_forced_next_won == false`, so THAT is what cleansing cancels; the
    -- lingering wash comes off with it so the felt agrees.
    reg:registerPayload("cleanse", function(_spec, _target, event)
        if not event.pool then return false end
        local wiped = false
        for _, t in ipairs(event.pool.tables) do
            if t._forced_next_won == false then
                t._forced_next_won = nil
                wiped = true
            end
            local list = t.statuses
            if list then
                for i = #list, 1, -1 do
                    local def = StatusData[list[i].kind]
                    if def and def.polarity == "bad" then
                        table.remove(list, i)
                        t._status_rev = (t._status_rev or 0) + 1
                        wiped = true
                    end
                end
            end
        end
        return wiped
    end)

    -- Push a timed global buff (Cleaning Robot: cursors go into overdrive
    -- after a {stack}). The controller owns the clock and folds live buffs
    -- into every effects rollup; see GrindController.timed_buffs.
    reg:registerPayload("timed_buff", function(spec, _target, event)
        local ctrl = event.ctrl
        if not (ctrl and ctrl.addTimedBuff and spec.buff) then return false end
        ctrl:addTimedBuff(spec.buff, spec.value or 1, spec.t or 5)
        return true
    end)

    -- Settle the target's hand right now. The cascade. Appends the
    -- resulting resolution to the list the controller is iterating, so a
    -- forced hand gets bounties, counters, floaters and analytics through
    -- exactly the same code an ordinary hand does.
    --
    -- With the Copy Machine owned (ctx.cascade_deals_empty), a table the
    -- sweep finds EMPTY is put back to work instead of skipped: the sweep
    -- deals it. That is the cascade's one upgrade — more live hands for
    -- the next stack to find.
    reg:registerPayload("resolve_now", function(_spec, target, event)
        if not (target and event.out) then return false end
        local r = target:forceResolve(event.ctx)
        if not r then
            if event.ctx and event.ctx.cascade_deals_empty
               and event.ctrl and event.ctrl.dealIdleTable then
                return event.ctrl:dealIdleTable(target)
            end
            return false
        end
        r.table = target
        event.out[#event.out + 1] = r
        -- No sound poke here any more: the table announces its own move to
        -- "settling" and the controller is listening. This used to be a
        -- patch for the controller's snapshot diff, which ran before the
        -- sweep and so never saw it.
        return true
    end)

    -- Hand a table's buy-in back. Rolls once, or once per event unit when
    -- `per_n` is set (a hand that knocks two seats out rolls twice).
    reg:registerPayload("refund_buyin", function(spec, target, event)
        if not (target and event.state) then return false end
        local stake = Lookups.findById(Stakes, target.stake_id)
        local amount = stake and stake.buy_in or 0
        if amount <= 0 then return false end
        local rolls = (spec.per_n and (event.n or 1)) or 1
        local hits = 0
        for _ = 1, rolls do
            if reg.rng() < (spec.chance or 0) then hits = hits + 1 end
        end
        if hits == 0 then return false end
        event.state.bankroll = (event.state.bankroll or 0) + amount * hits
        return true
    end)

    -- Hand back the price of the most expensive seat you are sitting in.
    -- Reads the RAW buy-in, matching refund_buyin: discounts are applied
    -- where a seat is CHARGED for, never where one is paid out.
    reg:registerPayload("pay_biggest_buyin", function(spec, _target, event)
        if not (event.state and event.pool) then return false end
        local best = 0
        for _, t in ipairs(event.pool.tables) do
            local stake = Lookups.findById(Stakes, t.stake_id)
            local bi = (stake and stake.buy_in) or 0
            if bi > best then best = bi end
        end
        if best <= 0 then return false end
        event.state.bankroll = (event.state.bankroll or 0)
                               + best * (spec.mult or 1)
        return true
    end)

    -- ── Routers ────────────────────────────────────────────────────────
    -- A router sees a delivery before it lands: `d.to` is where it is
    -- headed, `d.status` is what will arrive. Change either. Returning
    -- nothing leaves it alone, which is what a router that does not apply
    -- must do — these run on EVERY delivery.

    -- The tank reaches over and takes what was meant for the table beside
    -- it. Good and bad alike: a table that eats everything near it is a
    -- placement decision, not a filter.
    --
    -- Statuses only. A delivery with no status is a settle (the cascade's
    -- resolve_now), and stealing one of those force-resolves the tank's
    -- slow hand while the table the cascade meant to pay never settles.
    --
    -- "Beside" is the board's own geometry, like board_near: within
    -- `radius` cells by MANHATTAN distance (side-sharing, no diagonals),
    -- nearest first (ties go to reading order). Pool-order distance
    -- would call the end of one row adjacent to the start of the next,
    -- and a placement mechanic has to mean what the player sees.
    reg:registerRouter("steal_nearby", function(spec, d)
        local pool = d.event and d.event.pool
        local target = d.to
        if not (pool and target and d.status) then return end
        if target.game_type_id == spec.gtype then return end   -- already there
        local tr, tc = TableGrid.unpack(target.slot or 0)
        local radius = spec.radius or 1
        local best, best_dist
        for _, t in ipairs(pool.tables) do
            if t ~= target and t.game_type_id == spec.gtype then
                local r, c = TableGrid.unpack(t.slot or 0)
                local dist = math.abs(r - tr) + math.abs(c - tc)
                if dist <= radius and (not best_dist or dist < best_dist) then
                    best, best_dist = t, dist
                end
            end
        end
        if best then
            d.to = best
            return best
        end
    end)

    -- A running tournament bends what arrives around it. Along its row
    -- things land warmer, down its column colder. Checked against live
    -- tournaments rather than a cached flag, because a tournament ending
    -- has to stop bending immediately.
    -- The tank takes the tilt aimed beside it (Anchor). A tilt headed for
    -- a table that is not a six-max lands on the nearest live six-max
    -- within `radius` instead, and that absorption is what the deck
    -- levels on. Tilts only: heat is welcome where it lands.
    reg:registerRouter("taunt_tilt", function(spec, d)
        local pool = d.event and d.event.pool
        local target = d.to
        if not (pool and target and d.status == "tilt") then return end
        if target.game_type_id == spec.gtype then return end
        local tr, tc = TableGrid.unpack(target.slot or 0)
        local radius = spec.radius or 1
        local best, best_dist
        for _, t in ipairs(pool.tables) do
            if t ~= target and t.game_type_id == spec.gtype and (t.stack or 0) > 0 then
                local r, c = TableGrid.unpack(t.slot or 0)
                local dist = math.abs(r - tr) + math.abs(c - tc)
                if dist <= radius and (not best_dist or dist < best_dist) then
                    best, best_dist = t, dist
                end
            end
        end
        if best then
            d.to = best
            local st = d.event.state
            if st then st.total_tilts_absorbed = (st.total_tilts_absorbed or 0) + 1 end
            local ctrl = d.event.ctrl
            if ctrl and ctrl._grantDeckXp then
                ctrl:_grantDeckXp({ type = "tilt_absorbed", n = 1 })
            end
            return best
        end
    end)

    reg:registerRouter("tournament_lines", function(spec, d)
        local pool = d.event and d.event.pool
        local target = d.to
        if not (pool and target and d.status) then return end
        local tr, tc = TableGrid.unpack(target.slot or 0)
        for _, t in ipairs(pool.tables) do
            if t ~= target and t.ko and t.ko:isPlaying() then
                local r, c = TableGrid.unpack(t.slot or 0)
                local map = (r == tr and spec.row)
                         or (c == tc and spec.col)
                if map and map[d.status] then
                    d.status = map[d.status]
                    return
                end
            end
        end
    end)

    -- A permanent-for-this-run effect. Stored as a plain effect entry, so
    -- GameState:computeEffects applies it through the same registry as
    -- everything else. Cleared by resetRun with the rest of the run.
    -- Pay into a run-scoped bank on the GameState. The bank is what makes
    -- a "for the run" status proc retroactive: tables opened after a firing
    -- collect the banked total at open (GrindController:addTable), instead
    -- of only the tables that happened to be sitting there when it fired.
    reg:registerPayload("bank", function(spec, _target, event)
        local state = event.state
        if not (state and spec.field) then return false end
        state[spec.field] = (state[spec.field] or 0) + (spec.magnitude or 0)
        return true
    end)

    reg:registerPayload("ratchet", function(spec, _target, event)
        local state = event.state
        if not (state and spec.effect) then return false end
        state.run_ratchets = state.run_ratchets or {}
        local field = spec.effect.mag_field or "value"
        -- The Whiteboard: ratchets land harder while it's owned.
        local mag = (spec.magnitude or 0)
                    * ((event.ctx and event.ctx.ratchet_gain_mult) or 1)
        for _, entry in ipairs(state.run_ratchets) do
            if entry.kind == spec.effect.kind then
                entry[field] = (entry[field] or 0) + mag
                if event.ctrl then event.ctrl:invalidateEffects() end
                return true
            end
        end
        local entry = { kind = spec.effect.kind }
        entry[field] = mag
        state.run_ratchets[#state.run_ratchets + 1] = entry
        if event.ctrl then event.ctrl:invalidateEffects() end
        return true
    end)
end

return TableProcs
