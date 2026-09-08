-- sim/harness.lua
--
-- The headless game, for sim/test_everything.lua. Builds the REAL game
-- object the way main.lua does (registries, state, the grind controller,
-- the table pool) with LÖVE shimmed away, so a test can own an item, open
-- a table in a chosen cell, tick real hands, announce a trigger, and read
-- what the engine did. Nothing here is outcome math or game logic: it is
-- wiring, a fake clock, an assertion set that collects instead of
-- throwing, and the audit file writer.
--
-- Standalone: `lua sim/test_everything.lua` from the repo root.

local H = {}

-- ─── LÖVE shim ──────────────────────────────────────────────────────────
H.clock = 0
local function rnd(a, b)
    if a and b then return math.random(a, b) end
    if a then return math.random(a) end
    return math.random()
end
love = love or {}
love.math = love.math or {}
love.math.random = rnd
love.math.triangulate = function(p) return { p } end
love.timer = { getTime = function() return H.clock end }
love.graphics = setmetatable({
    getDimensions = function() return 1600, 900 end,
    getColor      = function() return 1, 1, 1, 1 end,
}, { __index = function() return function() end end })
love.filesystem = {
    getInfo = function() return nil end,
    read    = function() return nil end,
    write   = function() return true end,
    remove  = function() return true end,
    getWorkingDirectory = function() return "." end,
}
love.mouse = { getPosition = function() return -1, -1 end, isDown = function() return false end }
-- No sound card: every source is a mute object (the swarm taps on each
-- click and clash through services/SoundService).
local function muteSource()
    local src
    src = setmetatable({}, { __index = function(_, k)
        if k == "clone" then return function() return muteSource() end end
        if k == "isPlaying" then return function() return false end end
        if k == "getDuration" then return function() return 0.1 end end
        return function() end
    end })
    return src
end
love.audio = setmetatable({ newSource = function() return muteSource() end },
                          { __index = function() return function() end end })
love.keyboard = { isDown = function() return false end }

package.path = package.path .. ";./?.lua"

local Constants = require("data.constants")
Constants.FEATURES.DEMO_CUT   = false   -- the full catalog, like the designer tool
Constants.DEBUG.HAND_ANALYTICS = false  -- no analytics files

local Catalog        = require("data.catalog")
require("models.catalog_loader").deriveAll(Catalog)
local RunUpgrades    = require("data.run_upgrades")
local DeckSpecs      = require("data.decks")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local EffectKinds    = require("data.effects").kinds
local Procs          = require("data.procs")
local Routers        = require("data.routers")

local EventBus           = require("services.EventBus")
local EffectsRegistry    = require("services.EffectsRegistry")
local ProcRegistry       = require("services.ProcRegistry")
local XpRuleRegistry     = require("services.XpRuleRegistry")
local UnlockRegistry     = require("services.UnlockRegistry")
local PokerEventRegistry = require("services.PokerEventRegistry")
local GameState          = require("models.GameState")
local PokerEffects       = require("models.poker_effects")
local TableProcs         = require("models.table_procs")
local DeckXpRules        = require("models.deck_xp_rules")
local DeckUnlockRules    = require("models.deck_unlock_rules")
local CatalogUnlockRules = require("models.catalog_unlock_rules")
local PokerActionApply   = require("models.poker_action_apply")
local UpgradePricing     = require("models.UpgradePricing")
local Decks              = require("models.Decks")
local GrindController    = require("controllers.GrindController")
local Lookups            = require("utils.lookups")

H.Catalog, H.RunUpgrades, H.DeckSpecs = Catalog, RunUpgrades, DeckSpecs
H.Stakes, H.GameTypes, H.EffectKinds  = Stakes, GameTypes, EffectKinds
H.Procs, H.Routers, H.Constants       = Procs, Routers, Constants
H.Decks, H.Lookups                    = Decks, Lookups

-- One effects registry for the process (UpgradePricing derives the
-- upgrade ladders through it, once).
local effects = EffectsRegistry:new()
PokerEffects.registerAll(effects)
UpgradePricing.apply(RunUpgrades, effects)
H.effects = effects

function H.seed(n)
    H.seed_value = n or 12345
    math.randomseed(H.seed_value)
end
H.seed(12345)

-- ─── The game object ────────────────────────────────────────────────────
local function stubFont(h)
    return { getHeight = function() return h end, getWidth = function(_, s) return #tostring(s) * h * 0.5 end }
end

-- opts: bankroll (default 1e12), act2 (default true: shove_r1_won, decks
-- exist), gates (default true: every game type open)
function H.newGame(opts)
    opts = opts or {}
    local g = {}
    g.event_bus    = EventBus:new()
    g.state        = GameState:new()
    g.effects      = effects
    g.procs        = ProcRegistry:new(love.math.random, g.event_bus)
    TableProcs.registerAll(g.procs)
    g.xp_rules     = XpRuleRegistry:new()
    DeckXpRules.registerAll(g.xp_rules)
    g.unlock_rules = UnlockRegistry:new()
    DeckUnlockRules.registerAll(g.unlock_rules)
    CatalogUnlockRules.registerAll(g.unlock_rules)
    g.poker_events = PokerEventRegistry:new()
    PokerActionApply.registerAll(g.poker_events)
    g.floating_text = { emit = function() end }
    g.fonts = { lg = stubFont(24), md = stubFont(16), sm = stubFont(16), xs = stubFont(8), micro = stubFont(8) }
    g.ui_scale = 1
    g.sim_frozen = false
    local st = g.state
    st.bankroll = opts.bankroll or 1e12
    if opts.act2 ~= false then st.shove_r1_won = true; st.has_shoved = true end
    if opts.gates ~= false then st.hu_unlocked = true; st.six_max_unlocked = true end
    return g
end

-- ─── A world: game + controller + helpers ───────────────────────────────
local World = {}
World.__index = World

function H.world(opts)
    local g = H.newGame(opts)
    local w = setmetatable({ game = g, state = g.state, bus = g.event_bus }, World)
    w.ctrl = GrindController:new(g)
    return w
end

function World:invalidate() self.ctrl:invalidateEffects() return self.ctrl.ctx end

function World:own(ids)
    if type(ids) == "string" then ids = { ids } end
    for _, id in ipairs(ids) do
        local have = false
        for _, o in ipairs(self.state.owned_items) do if o == id then have = true end end
        if not have then self.state.owned_items[#self.state.owned_items + 1] = id end
    end
    return self:invalidate()
end

function World:upgrade(id, level)
    self.state.run_upgrade_levels[id] = level
    return self:invalidate()
end

-- Deck `id` at `level`, unlocked and active (XP tests read the active deck).
function World:deck(id, level)
    self.state.unlocked_decks = self.state.unlocked_decks or {}
    local have = false
    for _, d in ipairs(self.state.unlocked_decks) do if d == id then have = true end end
    if not have then self.state.unlocked_decks[#self.state.unlocked_decks + 1] = id end
    self.state.deck_levels = self.state.deck_levels or {}
    self.state.deck_xp     = self.state.deck_xp or {}
    self.state.deck_levels[id] = level or 0
    self.state.deck_xp[id]     = self.state.deck_xp[id] or 0
    self.state.active_deck_id  = id
    return self:invalidate()
end

-- Open a table; `slot` = { row, col } puts it in that cell (swapping
-- whoever was there). Returns the table.
function World:open(stake_id, gtype_id, slot)
    local ctrl = self.ctrl
    local before = ctrl.pool:count()
    assert(ctrl:addTable(stake_id, gtype_id), ("open: addTable(%s, %s) refused"):format(stake_id, gtype_id))
    assert(ctrl.pool:count() == before + 1, "open: pool did not grow")
    local newest
    for _, t in ipairs(ctrl.pool.tables) do
        if not newest or t._id > newest._id then newest = t end
    end
    if slot then
        local TableGrid = require("models.table_grid")
        local idx
        for i, t in ipairs(ctrl.pool.tables) do if t == newest then idx = i end end
        ctrl.pool:moveToSlot(idx, TableGrid.pack(slot[1], slot[2]))
    end
    self:invalidate()
    return newest
end

function World:tables() return self.ctrl.pool.tables end

function World:find(tbl)
    for i, t in ipairs(self.ctrl.pool.tables) do if t == tbl then return i end end
    return nil
end

-- Advance the world `secs` of wall time in `step` slices (default 1/60).
function World:tick(secs, step)
    step = step or (1 / 60)
    local t = 0
    while t < secs - 1e-9 do
        local dt = math.min(step, secs - t)
        H.clock = H.clock + dt
        self.bus:beginFrame()
        self.ctrl:update(dt)
        self.bus:drain()   -- main.lua drains once per frame; the tables publish, the drain delivers
        t = t + dt
    end
end

-- Say something happened (procs fire and the bus drains, like the game).
function World:announce(name, event)
    self.ctrl:_announce(name, event)
end

-- Aim a status at a table through the routers, the way a proc's delivery
-- is negotiated. Returns where it landed and what it became.
function World:deliver(status, target, source)
    local d = {
        to = target, aimed_at = target, status = status,
        spec  = { kind = "apply_status", status = status, magnitude = 0.35, t = 6 },
        event = { pool = self.ctrl.pool, ctrl = self.ctrl, state = self.state,
                  ctx = self.ctrl.ctx, source = source },
    }
    self.ctrl:_route(d)
    return d.to, d.status
end

-- The pure rollup for a set of things, no controller: { items = {...},
-- upgrades = { id = level }, decks = { id = level }, transient = {...} }.
function H.ctxOf(spec)
    spec = spec or {}
    local st = GameState:new()
    st.shove_r1_won = true
    for _, id in ipairs(spec.items or {}) do st.owned_items[#st.owned_items + 1] = id end
    for id, lvl in pairs(spec.upgrades or {}) do st.run_upgrade_levels[id] = lvl end
    if spec.decks then
        st.unlocked_decks, st.deck_levels, st.deck_xp = {}, {}, {}
        for id, lvl in pairs(spec.decks) do
            st.unlocked_decks[#st.unlocked_decks + 1] = id
            st.deck_levels[id] = lvl
            st.deck_xp[id] = 0
        end
    end
    local transient = spec.transient or { active_tables_count = 1 }
    return st:computeEffects(effects, Catalog, RunUpgrades, transient)
end

-- ─── Expectations (collect, never throw) ────────────────────────────────
local E = { failures = {}, passes = 0 }
H.expect = E

local function fail(msg)
    E.failures[#E.failures + 1] = msg
    print("FAIL " .. msg)
    return false
end
function E.ok(cond, msg)
    if cond then E.passes = E.passes + 1 return true end
    return fail(msg)
end
function E.eq(got, want, msg)
    if got == want then E.passes = E.passes + 1 return true end
    return fail(("%s: got %s, want %s"):format(msg, tostring(got), tostring(want)))
end
function E.near(got, want, tol, msg)
    if type(got) == "number" and math.abs(got - want) <= tol then E.passes = E.passes + 1 return true end
    return fail(("%s: got %s, want %s ±%s"):format(msg, tostring(got), tostring(want), tostring(tol)))
end
function E.gt(got, floor, msg)
    if type(got) == "number" and got > floor then E.passes = E.passes + 1 return true end
    return fail(("%s: got %s, want > %s"):format(msg, tostring(got), tostring(floor)))
end
-- Monte Carlo: run fn n times, the fraction of true results must be
-- within tol of p. Returns the measured rate.
function E.rate(fn, n, p, tol, msg)
    local hits = 0
    for _ = 1, n do if fn() then hits = hits + 1 end end
    local r = hits / n
    E.near(r, p, tol, msg .. (" (n=%d)"):format(n))
    return r
end

-- ─── The audit file ─────────────────────────────────────────────────────
-- docs/sim-audit.md: one entry per key, upserted the moment a case runs
-- and flushed at once, so a run that dies halfway still leaves what it
-- confirmed. Entries from earlier runs survive until their key runs again.
local A = { path = "docs/sim-audit.md", entries = {}, order = {} }
H.audit = A

local SECTION_OF = {}   -- key prefix → section title, filled by the test file
function A.section(prefix, title) SECTION_OF[prefix] = title end

function A.load()
    local f = io.open(A.path, "r")
    if not f then return end
    local text = f:read("*a"); f:close()
    for block in text:gmatch("\n### ([^\n]*)\n(.-)\n\n") do end   -- (keeps the parser below simple)
    local pos = 1
    while true do
        local s, e, key, verdict = text:find("\n### ([%w_:%-%.]+) — (%u+)\n", pos)
        if not s then break end
        local nxt = text:find("\n### ", e) or (#text + 1)
        local body = text:sub(e + 1, nxt - 1)
        local entry = { key = key, pass = (verdict == "PASS"), lines = {}, labels = {} }
        for line in body:gmatch("[^\n]+") do
            local label, rest = line:match("^%- ([^:]+): (.*)$")
            if label then entry.lines[#entry.lines + 1] = { label = label, text = rest }; entry.labels[label] = #entry.lines end
        end
        if not A.entries[key] then A.order[#A.order + 1] = key end
        A.entries[key] = entry
        pos = nxt
    end
end

-- Record one check on a key. `text` is what was measured, in words with
-- the numbers in them. A key's verdict is the AND of its checks this run.
function A.check(key, label, pass, text)
    local entry = A.entries[key]
    if not entry or entry.run ~= H.run_id then
        entry = { key = key, pass = true, lines = {}, labels = {}, run = H.run_id }
        if not A.entries[key] then A.order[#A.order + 1] = key end
        A.entries[key] = entry
    end
    entry.pass = entry.pass and pass
    local i = entry.labels[label]
    local line = { label = label, text = (pass and "" or "FAIL: ") .. text }
    if i then entry.lines[i] = line else entry.lines[#entry.lines + 1] = line; entry.labels[label] = #entry.lines end
    A.dirty = true
end

function A.uncovered(keys) A.uncovered_keys = keys end

function A.flush()
    if not A.dirty and A.flushed_once then return end
    local out = {}
    out[#out + 1] = "# Sim audit"
    out[#out + 1] = ""
    out[#out + 1] = ("> Generated by `lua sim/test_everything.lua` (seed %s, %s). Do not hand-edit: rerun the script, or `--only <key>` for one entry. An entry is replaced only when its key runs again, so a run that stops early keeps what it confirmed."):format(tostring(H.seed_value), os.date("%Y-%m-%d"))
    out[#out + 1] = ""
    -- group by section (prefix before the first ":")
    local by_section, sections = {}, {}
    for _, key in ipairs(A.order) do
        local prefix = key:match("^([^:]+)")
        local title = SECTION_OF[prefix] or prefix
        if not by_section[title] then by_section[title] = {}; sections[#sections + 1] = title end
        local list = by_section[title]
        list[#list + 1] = key
    end
    for _, title in ipairs(sections) do
        out[#out + 1] = "## " .. title
        out[#out + 1] = ""
        for _, key in ipairs(by_section[title]) do
            local e = A.entries[key]
            out[#out + 1] = ("### %s — %s"):format(key, e.pass and "PASS" or "FAIL")
            for _, l in ipairs(e.lines) do out[#out + 1] = ("- %s: %s"):format(l.label, l.text) end
            out[#out + 1] = ""
        end
    end
    out[#out + 1] = "## Uncovered"
    out[#out + 1] = ""
    if A.uncovered_keys and #A.uncovered_keys > 0 then
        for _, k in ipairs(A.uncovered_keys) do out[#out + 1] = "- " .. k end
    else
        out[#out + 1] = "(none: every item, upgrade level, deck level, capstone, proc and router has a case)"
    end
    out[#out + 1] = ""
    local f = assert(io.open(A.path, "w"))
    f:write(table.concat(out, "\n")); f:close()
    A.dirty, A.flushed_once = false, true
end

return H
