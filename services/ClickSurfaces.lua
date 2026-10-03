-- services/ClickSurfaces.lua
--
-- What is under the cursor, by material. Whatever draws a surface registers
-- its rect each frame (`add`), in draw order; `at` returns the topmost (the
-- last added that contains the point), so a modal drawn over the board
-- answers for the board beneath it. Nothing matching = the wall.
--
-- Records are reused frame to frame (no table per surface per frame).
-- Fields beyond the rect ride in `opts` and are copied: tint (a felt's
-- colour, for its dust), poke (a services/Poke key the click reacts on),
-- poke_kind (overrides the material's), item (a room item id: its foley),
-- pile (a views/ChipPile key: the column under the click hops).
--
-- Engine-agnostic: rects and strings, no love.*.

local ClickSurfaces = {}

local _list = {}
local _n    = 0
local DEFAULT = { material = "wall", x = 0, y = 0, w = 0, h = 0 }

function ClickSurfaces.beginFrame()
    _n = 0
end

function ClickSurfaces.add(material, x, y, w, h, opts)
    if not (material and x and y and w and h) or w <= 0 or h <= 0 then return end
    _n = _n + 1
    local r = _list[_n]
    if not r then r = {}; _list[_n] = r end
    r.material, r.x, r.y, r.w, r.h = material, x, y, w, h
    r.tint      = opts and opts.tint or nil
    r.poke      = opts and opts.poke or nil
    r.poke_kind = opts and opts.poke_kind or nil
    r.item      = opts and opts.item or nil
    r.pile      = opts and opts.pile or nil
end

-- The topmost surface containing (x, y), or the wall.
function ClickSurfaces.at(x, y)
    for i = _n, 1, -1 do
        local r = _list[i]
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r end
    end
    return DEFAULT
end

function ClickSurfaces.count() return _n end

return ClickSurfaces
