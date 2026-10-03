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

-- `add` for a rect in the CURRENT drawing coordinates (a scrolled sidebar,
-- a shaken panel): its corners go through love.graphics.transformPoint, and
-- the result is clipped to the scissor, so a button scrolled out of view
-- registers nothing. Rotation is ignored (the bounding box of the corners).
function ClickSurfaces.addLocal(material, x, y, w, h, opts)
    local lg = love and love.graphics
    if not (lg and lg.transformPoint) then return ClickSurfaces.add(material, x, y, w, h, opts) end
    local x1, y1 = lg.transformPoint(x, y)
    local x2, y2 = lg.transformPoint(x + w, y + h)
    local x3, y3 = lg.transformPoint(x + w, y)
    local x4, y4 = lg.transformPoint(x, y + h)
    if not (x1 and x2 and x3 and x4) then return end
    local l, t = math.min(x1, x2, x3, x4), math.min(y1, y2, y3, y4)
    local r, b = math.max(x1, x2, x3, x4), math.max(y1, y2, y3, y4)
    if lg.getScissor then
        local sx, sy, sw, sh = lg.getScissor()
        if sx then
            l, t = math.max(l, sx), math.max(t, sy)
            r, b = math.min(r, sx + sw), math.min(b, sy + sh)
        end
    end
    return ClickSurfaces.add(material, l, t, r - l, b - t, opts)
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
