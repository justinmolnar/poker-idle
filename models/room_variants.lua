-- models/room_variants.lua
--
-- The room's VARIANTS: every way the player can own or not own the
-- things other things sit on. A placed entry homes on an ANCHOR (its
-- parent: the desk, the fridge, the book stack); which anchors are owned
-- decides where everything lands, so a layout is only right if every
-- item has a sane place under every combination of owned anchors.
--
-- Pure. Anchors are the parents named by homes that are CATALOG items
-- (a flavour anchor is the room itself and is always there). Variant i
-- (0-based, of 2^n) follows a Gray code, so stepping to the next one
-- flips exactly one anchor — the designer can watch a single thing come
-- or go, and look at it.

local RoomPlacement = require("models.room_placement")

local RoomVariants = {}

-- The catalog anchors, sorted: the parents any home names that are
-- catalog items (is_catalog(id) says). Flavour parents are not variables.
function RoomVariants.anchors(placed, is_catalog)
    local out = {}
    for _, id in ipairs(RoomPlacement.anchorIds(placed)) do
        if is_catalog(id) then out[#out + 1] = id end
    end
    return out
end

function RoomVariants.count(anchors)
    return 2 ^ #anchors
end

-- The anchors OFF in variant i: bit b of the Gray code of i.
function RoomVariants.offSet(anchors, i)
    local g = i ~ (i >> 1)
    local off = {}
    for b = 1, #anchors do
        if (g >> (b - 1)) & 1 == 1 then off[anchors[b]] = true end
    end
    return off
end

-- Variant i as words: the anchors off, sorted.
function RoomVariants.offList(anchors, i)
    local off = RoomVariants.offSet(anchors, i)
    local list = {}
    for id in pairs(off) do list[#list + 1] = id end
    table.sort(list)
    return list
end

return RoomVariants
