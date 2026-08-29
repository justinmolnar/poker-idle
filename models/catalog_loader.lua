-- models/catalog_loader.lua
--
-- Turns the authored catalog into the priced one. Two derivations, both of
-- which used to run inside data/catalog.lua at require time:
--
--   cost_chip        scaled from the hand-authored figure by run length
--   shove_rate_add   the flat "you own a thing" contribution, forced onto
--                    every item and every corrupt block
--
-- ─── WHY IT MOVED OUT OF data/ ──────────────────────────────────────────
-- data/ holds tables and nothing else: no functions, no loops, no requires
-- of a code layer. data/catalog.lua was breaking that at the bottom of the
-- file, mutating every item the moment anything required it, and reaching
-- into data/balance.lua for three functions that had no business living in
-- data/ either. An item is data. What an item COSTS is arithmetic, and
-- arithmetic belongs here.
--
-- ─── WHAT IS AND IS NOT AUTHORED ────────────────────────────────────────
-- `authored_cost_chip` is the number a human chose and the one to edit.
-- `cost_chip` is derived and is overwritten on every load, so editing it
-- does nothing. Same for the shove_rate_add entry: its VALUE is derived,
-- and authoring one by hand only decides where in the effects list it sits.
--
-- Idempotent on purpose. It is called once at boot, but the sim harnesses
-- call it too, and running it twice must not double anything.

local Balance    = require("data.balance")
local ProcData   = require("data.procs")
local RouterData = require("data.routers")

local CatalogLoader = {}

-- Scale a hand-authored cost by run length, relative to the 20-minute
-- baseline the pacing model is written against.
function CatalogLoader.itemCost(authored_cost)
    if not authored_cost or authored_cost <= 0 then return 0 end
    local time_scale = (Balance.RUN_MINUTES or 20) / 20.0
    return math.max(1, math.floor(authored_cost * time_scale + 0.5))
end

-- Every catalog item contributes the same flat shove rate: one item, one
-- point of shove. An item authored as a `gate` is not a thing you own, so
-- it contributes nothing and is not priced.
function CatalogLoader.isOwnable(item)
    return item ~= nil and item.phase ~= "system" and not item.gate
end

function CatalogLoader.itemShoveRate(item)
    if not CatalogLoader.isOwnable(item) then return 0 end
    return Balance.K_SHOVE_PER_ITEM
end

-- Chips a run has to produce to stay on the Act 1 pacing curve. Used by
-- the sims rather than the game.
function CatalogLoader.chipsPerRun(act1_spend)
    local total_spend = act1_spend or 111
    return math.ceil((total_spend * ((Balance.RUN_MINUTES or 20) / 20.0))
                     / Balance.ACT1_RUNS_TO_CLEAR)
end

-- On the base block the derived rate WINS: the value is not authored, only
-- its position in the list is.
local function forceShoveRate(effects, item)
    for _, eff in ipairs(effects) do
        if eff.kind == "shove_rate_add" then
            eff.value = CatalogLoader.itemShoveRate(item)
            return
        end
    end
    table.insert(effects, 1,
        { kind = "shove_rate_add", value = CatalogLoader.itemShoveRate(item) })
end

-- On a corrupt block an authored value STANDS. Corruption is allowed to
-- change what owning the thing is worth, so this only fills the gap.
local function ensureShoveRate(effects, item)
    for _, eff in ipairs(effects) do
        if eff.kind == "shove_rate_add" then return end
    end
    table.insert(effects, 1,
        { kind = "shove_rate_add", value = CatalogLoader.itemShoveRate(item) })
end

-- A proc or router entry naming an id that no data file defines is a typo,
-- and a typo in the data file should be loud (the same rule ProcRegistry
-- applies to selector/payload kinds). Silent skips are how four items
-- shipped inert: the rollup and the proc index both drop unknown ids
-- without a sound, so this is the one place the whole chain gets checked.
local function validateEffectRefs(item, effects, where)
    for _, eff in ipairs(effects or {}) do
        if eff.kind == "proc" and not ProcData[eff.proc] then
            error(("catalog item '%s' (%s): unknown proc '%s'")
                  :format(item.id or "?", where, tostring(eff.proc)))
        end
        if eff.kind == "router" and not RouterData[eff.router] then
            error(("catalog item '%s' (%s): unknown router '%s'")
                  :format(item.id or "?", where, tostring(eff.router)))
        end
    end
end

-- Price and rate every item in place. Returns the same list, so callers can
-- write `local Catalog = CatalogLoader.deriveAll(require("data.catalog"))`.
function CatalogLoader.deriveAll(items)
    for _, item in ipairs(items) do
        if CatalogLoader.isOwnable(item) then
            item.authored_cost_chip = item.authored_cost_chip or item.cost_chip
            item.cost_chip = CatalogLoader.itemCost(item.authored_cost_chip)

            item.effects = item.effects or {}
            forceShoveRate(item.effects, item)
            validateEffectRefs(item, item.effects, "effects")

            -- A corrupt block REPLACES the item's effects
            -- (GameState:computeEffects), so one without a shove_rate_add
            -- would strip the item's shove base the moment it corrupted.
            if item.corrupt and item.corrupt.effects then
                ensureShoveRate(item.corrupt.effects, item)
                validateEffectRefs(item, item.corrupt.effects, "corrupt")
            end
        end
    end
    return items
end

return CatalogLoader
