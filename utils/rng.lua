-- utils/rng.lua
-- Random helpers. Wraps love.math.random so a deterministic seed can be
-- swapped in for tests / replays without touching call sites.

local RNG = {}

-- Pick one entry from a list, weighted by `weight_fn(entry)` (defaults to a
-- constant 1 for uniform). Returns the entry, or nil if total weight is 0.
-- Pattern lifted from cosmic courier's services/TripGenerator.lua rollScope.
function RNG.weightedPick(list, weight_fn)
    weight_fn = weight_fn or function() return 1 end
    local total = 0
    for _, entry in ipairs(list) do total = total + (weight_fn(entry) or 0) end
    if total <= 0 then return nil end
    local r = love.math.random() * total
    local acc = 0
    for _, entry in ipairs(list) do
        acc = acc + (weight_fn(entry) or 0)
        if r <= acc then return entry end
    end
    return list[#list]
end

-- Random integer in [lo, hi] inclusive.
function RNG.intInRange(lo, hi)
    return love.math.random(lo, hi)
end

-- Random float in [0, 1).
function RNG.float()
    return love.math.random()
end

-- Coin flip with optional bias (default 0.5 = fair).
function RNG.chance(p)
    return love.math.random() < (p or 0.5)
end

return RNG
