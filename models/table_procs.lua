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

local Lookups   = require("utils.lookups")
local Stakes    = require("data.stakes")
local GameTypes = require("data.game_types")

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

-- Trim a candidate list by `pick` and `max`.
local function narrow(list, spec)
    if spec.pick == "random" and #list > 0 then
        local one = list[love.math.random(1, #list)]
        return { one }
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
        return narrow(out, spec)
    end)

    -- Tables within `radius` places of the source in pool order.
    reg:registerSelector("order_near", function(spec, event)
        local pool = event.pool
        local i = indexOf(pool, event.source)
        if not i then return {} end
        local r = spec.radius or 1
        local out = {}
        for j = math.max(1, i - r), math.min(#pool.tables, i + r) do
            local t = pool.tables[j]
            local skip = (spec.exclude_self ~= false) and t == event.source
            if not skip and matches(t, spec.where) then out[#out + 1] = t end
        end
        return narrow(out, spec)
    end)

    -- Any other table, ignoring position.
    reg:registerSelector("any_other", function(spec, event)
        local out = {}
        for _, t in ipairs(event.pool.tables) do
            if t ~= event.source and matches(t, spec.where) then out[#out + 1] = t end
        end
        return narrow(out, spec)
    end)

    -- ── Payloads ───────────────────────────────────────────────────────

    -- Put a status on the target. `escalate` scales the magnitude by
    -- something the event knows — the doc's "value scales with seats
    -- remaining" drama pass, e.g. { field = "busted_total", per = 0.15 }.
    reg:registerPayload("apply_status", function(spec, target, event)
        if not target then return false end
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
        })
    end)

    -- Settle the target's hand right now. The cascade. Appends the
    -- resulting resolution to the list the controller is iterating, so a
    -- forced hand gets bounties, counters, floaters and analytics through
    -- exactly the same code an ordinary hand does.
    reg:registerPayload("resolve_now", function(_spec, target, event)
        if not (target and event.out) then return false end
        local r = target:forceResolve(event.ctx)
        if not r then return false end
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
            if love.math.random() < (spec.chance or 0) then hits = hits + 1 end
        end
        if hits == 0 then return false end
        event.state.bankroll = (event.state.bankroll or 0) + amount * hits
        return true
    end)

    -- A permanent-for-this-run effect. Stored as a plain effect entry, so
    -- GameState:computeEffects applies it through the same registry as
    -- everything else. Cleared by resetRun with the rest of the run.
    reg:registerPayload("ratchet", function(spec, _target, event)
        local state = event.state
        if not (state and spec.effect) then return false end
        state.run_ratchets = state.run_ratchets or {}
        local field = spec.effect.mag_field or "value"
        for _, entry in ipairs(state.run_ratchets) do
            if entry.kind == spec.effect.kind then
                entry[field] = (entry[field] or 0) + (spec.magnitude or 0)
                if event.ctrl then event.ctrl:invalidateEffects() end
                return true
            end
        end
        local entry = { kind = spec.effect.kind }
        entry[field] = spec.magnitude or 0
        state.run_ratchets[#state.run_ratchets + 1] = entry
        if event.ctrl then event.ctrl:invalidateEffects() end
        return true
    end)
end

return TableProcs
