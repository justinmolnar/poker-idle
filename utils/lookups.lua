-- utils/lookups.lua
-- Generic id-keyed lookups over data tables. Engine-agnostic.

local Lookups = {}

-- Linear scan; returns the first item whose `.id` field equals `id`, or nil.
-- Data tables in this project (data/stakes.lua, data/game_types.lua, etc.)
-- are short ordered lists, so a linear scan is the right shape and avoids
-- maintaining a parallel index.
function Lookups.findById(list, id)
    if not list or id == nil then return nil end
    for _, item in ipairs(list) do
        if item.id == id then return item end
    end
    return nil
end

return Lookups
