-- models/item_readouts.lua
--
-- A catalog item's LIVE value, for its hover card: what an accumulating
-- item is worth right now, or how far off its next firing is. Balatro
-- prints "(Currently +X Mult)" under every scaler; this is that row.
--
-- Data-driven: an item declares `readout = { kind = "...", ... }` in
-- data/catalog.lua and this file maps the kind to a string. No functions in
-- data. Returns nil when there is nothing to say (the row is skipped).
--
-- Kinds:
--   run_ratchet    { effect = "<effect kind>" }
--                  Sum of this run's ratchet entries of that kind (the
--                  Prize Vase): "+3% win chance this run so far".
--   tourney_backing {}  The High Roller Pass: tournament seats finished at
--                  each stake, from the live pool, times the per-seat value.


local ItemReadouts = {}

local function trim(n)
    local s = ("%.2f"):format(n):gsub("0+$", ""):gsub("%.$", "")
    return s
end


local KINDS = {}

KINDS.run_ratchet = function(spec, game, item)
    local state = game.state
    local total = 0
    for _, entry in ipairs(state.run_ratchets or {}) do
        if entry.kind == spec.effect then
            total = total + (entry[spec.field or "amount"] or 0)
        end
    end
    if total <= 0 then return "Nothing banked this run yet" end
    return ("+%s%% win chance this run so far"):format(trim(total * 100))
end

KINDS.tourney_backing = function(_spec, game, _item)
    local grind = game.grind
    local per = grind and grind.ctx and grind.ctx.tourney_backing
    local pool = grind and grind.pool
    if not (per and per > 0 and pool) then return nil end
    local seats = 0
    for _, t in ipairs(pool.tables) do
        seats = seats + ((t.ko and t.ko.finish_count) or 0)
    end
    if seats == 0 then return "No tournament seats finished yet" end
    return ("+%s%% win chance from %d finished seat%s"):format(
        trim(per * seats * 100), seats, seats == 1 and "" or "s")
end

-- The row's text for an item, or nil.
function ItemReadouts.text(game, item)
    local spec = item and item.readout
    if not (spec and spec.kind and game and game.state) then return nil end
    local fn = KINDS[spec.kind]
    if not fn then return nil end
    return fn(spec, game, item)
end

return ItemReadouts
