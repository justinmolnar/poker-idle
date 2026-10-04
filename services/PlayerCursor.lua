-- services/PlayerCursor.lua
--
-- The player's mouse cursor: the chunky pixel shapes in data/player_cursor.lua
-- as hardware cursors (love.mouse.newCursor), so they track the mouse with no
-- frame of lag and draw over everything. apply() (at load and on every
-- resize, rebuilding only when the pixel size changes) builds every kind at
-- the window's pixel size, plus for each a pressed variant (the art one art
-- pixel lower under the same hot spot: it dips while the button is down) and
-- a few corrupted glitch frames. set(kind, pressed, glitch) shows one,
-- calling setCursor only when it changes. services/CursorIntent decides
-- which, per frame. Where the engine has no custom cursors (love.js, the
-- headless stub) the system arrow stays.

local Cfg = require("data.player_cursor")

local PlayerCursor = {}

local _px                 -- the pixel size the set was built at
local _set                -- [kind] = { base, pressed, glitch = { ... } }
local _current            -- the cursor object last handed to setCursor

local function color(spec)
    if type(spec) == "table" then return spec end
    local ok, Theme = pcall(require, "views.Theme")
    if ok and Theme then
        local c = (Theme.semColor and Theme.semColor(spec))
               or (Theme.currency and Theme.currency[spec])
        if c then return c end
    end
    return { 1, 1, 1 }
end

function PlayerCursor.pixelSize(window_h)
    local s = math.floor((window_h or 720) / 100 * Cfg.px_per_100h + 0.5)
    return math.max(Cfg.min_px, math.min(Cfg.max_px, s))
end

local function toGrid(rows)
    local g = {}
    for y, r in ipairs(rows) do
        g[y] = {}
        for x = 1, #r do g[y][x] = r:sub(x, x) end
    end
    return g
end

local function size(g) return #g[1], #g end

-- `badge` over `base` at art offset `at`, the grid grown to hold both.
local function compose(base, badge, at)
    local bw, bh = size(badge)
    local w0, h0 = size(base)
    local w, h = math.max(w0, at[1] + bw), math.max(h0, at[2] + bh)
    local g = {}
    for y = 1, h do
        g[y] = {}
        for x = 1, w do g[y][x] = (base[y] and base[y][x]) or "." end
    end
    for y = 1, bh do
        for x = 1, bw do
            local ch = badge[y][x]
            if ch ~= "." then g[at[2] + y][at[1] + x] = ch end
        end
    end
    return g
end

-- One "O" (rim) pixel around every outline pixel, the grid grown by one
-- on every side.
local function addRim(g0)
    local w0, h0 = size(g0)
    local w, h = w0 + 2, h0 + 2
    local g = {}
    for y = 1, h do
        g[y] = {}
        for x = 1, w do g[y][x] = (g0[y - 1] and g0[y - 1][x - 1]) or "." end
    end
    if not Cfg.rim then return g end
    local out = {}
    for y = 1, h do
        out[y] = {}
        for x = 1, w do
            local ch = g[y][x]
            if ch == "." then
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local row = g[y + dy]
                        if row and row[x + dx] == "X" then ch = "O" end
                    end
                end
            end
            out[y][x] = ch
        end
    end
    return out
end

-- The art of one kind: { grid, w, h, hot = { x, y } (rimmed art pixels),
-- badge = the badge's colour or nil }. Cached.
local _arts = {}
function PlayerCursor.art(kind)
    kind = kind or "arrow"
    local a = _arts[kind]
    if a then return a end
    local k = Cfg.kinds[kind] or Cfg.kinds.arrow
    local shape = Cfg.shapes[k.shape]
    local g = toGrid(shape.rows)
    local badge = k.badge and Cfg.badges[k.badge]
    if badge then g = compose(g, toGrid(badge.rows), Cfg.badge_at) end
    g = addRim(g)
    local w, h = size(g)
    a = { grid = g, w = w, h = h, hot = { shape.hot[1] + 1, shape.hot[2] + 1 },
          badge = badge and color(badge.color) or nil }
    _arts[kind] = a
    return a
end

-- The pressed variant: the art one row lower (a blank row on top).
local function pressedGrid(g)
    local w = size(g)
    local out = { {} }
    for x = 1, w do out[1][x] = "." end
    for y = 1, #g do out[y + 1] = g[y] end
    return out
end

-- A glitch frame: some rows slid sideways and some body pixels gone the
-- anti-chip colour ("P"). Deterministic per (frame, row, column).
local function glitchGrid(g, frame)
    local w, h = size(g)
    local out = {}
    for y = 1, h do
        local shift = 0
        if (y * 7 + frame * 5) % 6 == 0 then shift = 1 + (y + frame) % 2 end
        if (y * 3 + frame) % 11 == 0 then shift = -1 end
        out[y] = {}
        for x = 1, w + 2 do
            local sx = x - shift
            local ch = (g[y][sx]) or "."
            if ch == "#" and (x * 13 + y * 7 + frame * 5) % 9 == 0 then ch = "P" end
            out[y][x] = ch
        end
    end
    return out
end

local function imageData(g, px, badge)
    local w, h = size(g)
    local data = love.image.newImageData(w * px, h * px)
    local colors = { X = Cfg.outline, ["#"] = Cfg.fill, O = Cfg.rim, W = { 1, 1, 1 },
                     B = badge or Cfg.fill, P = color((Cfg.glitch or {}).color or "achip") }
    for y = 1, h do
        for x = 1, w do
            local c = colors[g[y][x]]
            if c then
                for yy = 0, px - 1 do
                    for xx = 0, px - 1 do
                        data:setPixel((x - 1) * px + xx, (y - 1) * px + yy, c[1], c[2], c[3], 1)
                    end
                end
            end
        end
    end
    return data
end

-- The ImageData of one kind at `px` screen pixels per art pixel, with its
-- hot spot in screen pixels. variant: nil, "pressed", or a glitch frame
-- number.
function PlayerCursor.imageData(px, kind, variant)
    local a = PlayerCursor.art(kind)
    local g = a.grid
    if variant == "pressed" then g = pressedGrid(g)
    elseif type(variant) == "number" then g = glitchGrid(g, variant) end
    return imageData(g, px, a.badge), a.hot[1] * px, a.hot[2] * px
end

local function newCursor(px, kind, variant)
    local ok, cur = pcall(function()
        local data, hx, hy = PlayerCursor.imageData(px, kind, variant)
        return love.mouse.newCursor(data, hx, hy)
    end)
    return ok and cur or nil
end

local function releaseSet(set)
    for _, v in pairs(set or {}) do
        if v.base and v.base.release then v.base:release() end
        if v.pressed and v.pressed.release then v.pressed:release() end
        for _, gc in ipairs(v.glitch or {}) do if gc.release then gc:release() end end
    end
end

function PlayerCursor.available()
    return (love.mouse and love.mouse.newCursor and love.mouse.setCursor and love.image
            and love.image.newImageData) and true or false
end

function PlayerCursor.apply()
    if not PlayerCursor.available() then return false end
    local px = PlayerCursor.pixelSize(love.graphics and love.graphics.getHeight and love.graphics.getHeight())
    if px == _px and _set then return true end
    local set = {}
    local frames = (Cfg.glitch and Cfg.glitch.frames) or 0
    for kind in pairs(Cfg.kinds) do
        local e = { base = newCursor(px, kind), pressed = newCursor(px, kind, "pressed"), glitch = {} }
        for f = 1, frames do e.glitch[f] = newCursor(px, kind, f) end
        set[kind] = e
    end
    if not (set.arrow and set.arrow.base) then return false end
    local old = _set
    _px, _set, _current = px, set, nil
    PlayerCursor.set("arrow")
    releaseSet(old)
    return true
end

-- Show one kind: pressed while the button is down, or glitch frame n.
function PlayerCursor.set(kind, pressed, glitch)
    if not _set then return end
    local e = _set[kind] or _set.arrow
    local cur = (glitch and e.glitch[glitch]) or (pressed and e.pressed) or e.base or _set.arrow.base
    if cur and cur ~= _current then
        love.mouse.setCursor(cur)
        _current = cur
    end
end

-- The cursor object last set (tests).
function PlayerCursor.current() return _current end
function PlayerCursor.cursorFor(kind, variant)
    local e = _set and _set[kind]
    if not e then return nil end
    if variant == "pressed" then return e.pressed end
    if type(variant) == "number" then return e.glitch[variant] end
    return e.base
end

return PlayerCursor
