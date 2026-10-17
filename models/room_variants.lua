-- models/room_variants.lua
--
-- The room's CASES: every place a homed thing can land, one case each,
-- in a fixed order the designer walks with N. A placed entry homes on
-- ANCHORS (its parents, in order of preference); the first owned one
-- wins, and its own spot is the fallback. So for a thing with homes
-- { desk, PC } the cases are: on the desk (everything owned); on the PC
-- (desk not owned); on its own spot (neither owned). Case 1 is the room
-- with everything owned.
--
-- Cases nobody can reach are left out: a state needs some parent NOT
-- owned, and that is impossible when the thing itself (transitively)
-- requires that parent in the catalog, or when that parent is flavour
-- (the room's own furniture, always there).
--
-- Pure. `catalog_by_id` says what is a catalog item and what requires
-- what. A case: { label, item (id or nil), home (index or 0), off (set of
-- anchor ids not owned) }.

local RoomVariants = {}

-- Everything `id` requires, transitively (its catalog chain).
local function requiresOf(catalog_by_id, id)
    local out, cur, guard = {}, catalog_by_id[id], 0
    while cur and cur.requires and guard < 32 do
        out[cur.requires] = true
        cur = catalog_by_id[cur.requires]
        guard = guard + 1
    end
    return out
end

function RoomVariants.cases(placed, catalog_by_id)
    local by_id = {}
    for _, o in ipairs(placed) do by_id[o.id] = by_id[o.id] or o end
    local ids = {}
    for _, o in ipairs(placed) do ids[#ids + 1] = o.id end
    table.sort(ids)
    local cases = { { label = "everything owned", item = nil, home = 0, off = {} } }
    for _, id in ipairs(ids) do
        local o = by_id[id]
        local homes = o.homes or {}
        if #homes > 0 then
            local needs = requiresOf(catalog_by_id, id)
            local before = {}      -- the placed parents of the homes above this one, which must be absent
            local reachable = true
            for j, h in ipairs(homes) do
                local parent = h.on and by_id[h.on]
                if parent then
                    if reachable then
                        local off = {}
                        for pid in pairs(before) do off[pid] = true end
                        cases[#cases + 1] = { label = string.format("%s on %s (home %d of %d)", id, parent.id, j, #homes),
                                              item = id, home = j, off = off }
                    end
                    -- states past this one need this parent absent
                    if not catalog_by_id[parent.id] then reachable = false      -- flavour: always there
                    elseif needs[parent.id] then reachable = false              -- the thing cannot exist without it
                    else before[parent.id] = true end
                end
            end
            if reachable then
                local off = {}
                for pid in pairs(before) do off[pid] = true end
                cases[#cases + 1] = { label = string.format("%s on its own spot (no parent owned)", id),
                                      item = id, home = 0, off = off }
            end
        end
    end
    return cases
end

-- The anchors a case leaves out, as words.
function RoomVariants.offWords(case)
    local list = {}
    for id in pairs(case.off) do list[#list + 1] = id end
    table.sort(list)
    return #list > 0 and table.concat(list, ", ") or "nothing"
end

return RoomVariants
