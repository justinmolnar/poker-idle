-- services/ProcRegistry.lua
--
-- Dispatch for procs: "when X happens, do Y to Z". Engine-agnostic and
-- domain-free — it knows nothing about poker, tables, or statuses. The
-- poker-specific selectors and payloads register from
-- models/table_procs.lua, exactly as models/poker_effects.lua registers
-- into services/EffectsRegistry and models/poker_action_apply.lua
-- registers into services/PokerEventRegistry.
--
-- ─── WHY THIS EXISTS SEPARATELY FROM EffectsRegistry ────────────────────
-- An EffectsRegistry applicator is `(effect, ctx) -> mutate ctx`, full
-- stop. It cannot reach a table, the pool, or the controller, so it cannot
-- express "on a knockout, buff the table next door". The first proc in the
-- game (the zoom cascade) was therefore a ctx flag plus a block of bespoke
-- controller code. A second proc written that way would be a second block,
-- and the catalog is meant to fill up with them.
--
-- So a proc is three orthogonal declarations, all data:
--   WHEN   a trigger key ("on_ko") — just an index, needs no registry
--   IF     an optional `chance` 0..1, rolled once per event
--   WHERE  a selector  (spec, event) -> array of targets
--   WHAT   a payload   (spec, target, event)
-- and adding a proc becomes an edit to data/procs.lua.
--
-- Unregistered kinds ERROR rather than no-op, matching EffectsRegistry and
-- PokerEventRegistry: a typo in the data file should be loud.

local ProcRegistry = {}
ProcRegistry.__index = ProcRegistry

-- Per-frame ceiling on how many procs may fire, across every trigger.
-- Not the real throttle — procs are naturally limited by how often their
-- trigger happens, and a resolve-style payload can only touch tables that
-- have a live hand. This is the runaway stop for a pathological chain.
local MAX_FIRES_PER_FRAME = 24

-- `rng` is a function returning 0..1, injected so this file stays free of
-- love.* (main.lua passes love.math.random).
function ProcRegistry:new(rng)
    return setmetatable({
        selectors = {},
        payloads  = {},
        fires     = 0,
        rng       = rng or math.random,
    }, ProcRegistry)
end

function ProcRegistry:registerSelector(kind, fn) self.selectors[kind] = fn end
function ProcRegistry:registerPayload(kind, fn)  self.payloads[kind]  = fn end

function ProcRegistry:hasSelector(kind) return self.selectors[kind] ~= nil end
function ProcRegistry:hasPayload(kind)  return self.payloads[kind]  ~= nil end

-- Called once per frame by the controller before any proc can fire.
function ProcRegistry:beginFrame() self.fires = 0 end

-- Run one proc for one event. Returns how many targets it touched, so the
-- caller can decide whether to play the item's ghost/sound.
function ProcRegistry:fire(proc, event)
    if not proc then return 0 end
    if self.fires >= MAX_FIRES_PER_FRAME then return 0 end

    -- THE THROTTLE THAT MATTERS. A tournament knocks a seat out every 5 to
    -- 11 seconds, so a proc that fires on every one of them is not a proc,
    -- it is a permanent aura with a trigger drawn on it. `chance` is rolled
    -- ONCE per event, before targeting, so a knockout usually does nothing
    -- and occasionally does something you notice.
    local chance = proc.chance
    if chance and self.rng() >= chance then return 0 end

    self.fires = self.fires + 1

    local sel_spec = proc.target or { kind = "none" }
    local sel = self.selectors[sel_spec.kind]
    if not sel then
        error("ProcRegistry: no selector for kind '" .. tostring(sel_spec.kind) .. "'")
    end
    local pay_spec = proc.payload
    local pay = pay_spec and self.payloads[pay_spec.kind]
    if not pay then
        error("ProcRegistry: no payload for kind '"
              .. tostring(pay_spec and pay_spec.kind) .. "'")
    end

    local targets = sel(sel_spec, event) or {}
    local touched = 0
    local hit = {}
    for _, t in ipairs(targets) do
        if pay(pay_spec, t, event) ~= false then
            touched = touched + 1
            hit[#hit + 1] = t
        end
    end
    -- A targetless proc (a run-wide ratchet) still runs its payload once.
    if #targets == 0 and sel_spec.kind == "none" then
        if pay(pay_spec, nil, event) ~= false then touched = 1 end
    end
    -- The tables actually affected come back so the caller can show the
    -- hit landing (GrindController bumps them).
    return touched, hit
end

return ProcRegistry
