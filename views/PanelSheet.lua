-- views/PanelSheet.lua
--
-- The panel cache's texture: ONE canvas holding every table panel's resting
-- picture, one slot per panel. views/TablePanel renders a panel's static
-- layers into its slot only when the panel's dirty key changes, and blits
-- the slot every frame with the live layers (piles, pot text, status FX)
-- drawn on top. At 34 tables that turns ~66 primitives and ~16 batch
-- flushes per panel per frame into one textured quad.
--
-- One sheet rather than a canvas per panel: every dirty panel of a frame is
-- rendered inside a single canvas switch (beginWrite ... endWrite), and
-- every blit samples the same texture, so LÖVE batches the whole board's
-- blits into one draw call.
--
-- Slots are (w + 2) x (h + 2): a one-pixel pad on every side for the
-- chrome's border stroke, which straddles the panel's edge. The slot's
-- scissor stays set for the whole render, so nothing a panel draws can
-- reach a neighbour's slot.
--
-- The sheet is rebuilt (the old canvas released) when the panel size or
-- the table count changes: the grid resizes its cells on every open and
-- close, and the sheet follows. `available()` is false headless, on a
-- build whose newCanvas refuses, or when the sheet would not fit the
-- texture limit; every panel then takes the immediate path.
--
-- Premultiplied: the slot is rendered with the ordinary alpha blend into a
-- transparent canvas, which leaves premultiplied colour behind, and blitted
-- with ("alpha", "premultiplied") in white, the frame canvas's own
-- convention (main.lua's strain pass).

local Perf = require("services.Perf")

local PanelSheet = {}

local PAD = 1

local _canvas = nil
local _n, _w, _h = 0, 0, 0     -- what the sheet was built for
local _cols, _rows = 0, 0
local _quads = {}              -- one persistent Quad per slot
local _owner = {}              -- who last wrote each slot (clearSlot's owner)
local _writing = false
local _prev_canvas = nil
local _limit = nil
-- Bumped on every build and release: a new sheet holds no pictures, so
-- every panel's key carries this and rebuilds into it.
local _gen = 0

local function textureLimit()
    if _limit then return _limit end
    local lim
    if love.graphics.getSystemLimits then
        local ok, l = pcall(love.graphics.getSystemLimits)
        if ok and type(l) == "table" then lim = l.texturesize end
    end
    -- Headless the stub answers nothing; 8192 is the floor every desktop
    -- GPU of the last decade clears, and the fit test below still runs.
    _limit = lim or 8192
    return _limit
end

local function drop()
    if _canvas and _canvas.release then _canvas:release() end
    _canvas = nil
    for i = #_quads, 1, -1 do _quads[i] = nil end
    for k in pairs(_owner) do _owner[k] = nil end
    _n, _w, _h, _cols, _rows = 0, 0, 0, 0, 0
    _gen = _gen + 1
    Perf.gauge("sheet_mb", 0)
end

-- Size the sheet for `n` slots of `w` x `h` panels. A no-op while those
-- three hold (a build that failed for them is not retried until they
-- move); otherwise the old canvas goes and a new one is made, or none,
-- when it would not fit or the build cannot make one.
function PanelSheet.ensure(n, w, h)
    n, w, h = n or 0, math.floor(w or 0), math.floor(h or 0)
    if n == _n and w == _w and h == _h then return _canvas ~= nil end
    drop()
    _n, _w, _h = n, w, h
    if n <= 0 or w <= 0 or h <= 0 then return false end
    local sw, sh = w + 2 * PAD, h + 2 * PAD
    local lim  = textureLimit()
    local cols = math.min(n, math.floor(lim / sw))
    if cols < 1 then return false end
    local rows = math.ceil(n / cols)
    if rows * sh > lim then return false end
    local W, H = cols * sw, rows * sh
    local ok, canvas = pcall(love.graphics.newCanvas, W, H, { dpiscale = 1 })
    if not ok or not canvas then return false end
    if canvas.setFilter then canvas:setFilter("nearest", "nearest") end
    _canvas, _cols, _rows = canvas, cols, rows
    if love.graphics.newQuad then
        for i = 1, n do
            local sx, sy = PanelSheet.slotRect(i)
            _quads[i] = love.graphics.newQuad(sx, sy, sw, sh, W, H)
        end
    end
    Perf.gauge("sheet_mb", W * H * 4 / 1048576)
    return true
end

function PanelSheet.available()
    return _canvas ~= nil
end

function PanelSheet.generation()
    return _gen
end

-- Top-left of slot i's cell (the pad included) on the sheet.
function PanelSheet.slotRect(i)
    local c = (i - 1) % _cols
    local r = math.floor((i - 1) / _cols)
    return c * (_w + 2 * PAD), r * (_h + 2 * PAD)
end

-- Where a panel drawn at (x, y) must be translated to land in slot i:
-- returns (dx, dy) such that the panel's origin maps to the slot's origin
-- plus the pad.
function PanelSheet.slotOffset(i, x, y)
    local sx, sy = PanelSheet.slotRect(i)
    return sx + PAD - x, sy + PAD - y
end

-- Open the sheet for rendering. Lazy: called on the first dirty panel of a
-- frame, so a frame with nothing to rebuild switches no canvas at all.
-- push("all") keeps the caller's transform, scissor, shader, blend, font
-- and line width for endWrite's pop.
function PanelSheet.beginWrite()
    if _writing or not _canvas then return end
    _writing = true
    _prev_canvas = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha")
    love.graphics.setCanvas(_canvas)
    Perf.count("canvas_switch")
end

function PanelSheet.writing() return _writing end

-- Wipe slot i to transparent and scissor the sheet to it for the render
-- that follows. A replace-blend fill rather than love.graphics.clear: clear
-- ignores the scissor on some drivers and would take the whole sheet with
-- it. The scissor stays until the next clearSlot or endWrite, so the
-- render is clipped to its own cell.
function PanelSheet.clearSlot(i, owner)
    if not _writing then return end
    _owner[i] = owner
    local sx, sy = PanelSheet.slotRect(i)
    local sw, sh = _w + 2 * PAD, _h + 2 * PAD
    love.graphics.setScissor(sx, sy, sw, sh)
    love.graphics.setBlendMode("replace")
    love.graphics.setColor(0, 0, 0, 0)
    love.graphics.rectangle("fill", sx, sy, sw, sh)
    love.graphics.setBlendMode("alpha")
    love.graphics.setColor(1, 1, 1, 1)
end

function PanelSheet.endWrite()
    if not _writing then return end
    _writing = false
    love.graphics.setScissor()
    love.graphics.setCanvas(_prev_canvas)
    love.graphics.pop()
    _prev_canvas = nil
end

-- Draw slot i so the panel it holds lands with its origin at (x, y).
-- Under whatever transform the caller has pushed (a shove, a lean, the
-- deal's spring all apply to the blit).
function PanelSheet.blit(i, x, y)
    local q = _quads[i]
    if not (_canvas and q) then return end
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(_canvas, q, x - PAD, y - PAD)
    love.graphics.setBlendMode("alpha")
    Perf.count("panel_blit")
end

function PanelSheet.bytes()
    if not _canvas then return 0 end
    return _cols * (_w + 2 * PAD) * _rows * (_h + 2 * PAD) * 4
end

-- A copy of slot i's picture as its own small canvas (with the slot's
-- gutter, `PAD` px on every side), or nil. For a panel that is about to
-- vanish (a closing table's ghost): the slot is reused next frame. The
-- caller releases it. With `owner`, only when that owner wrote the slot
-- last (slots follow the draw order, so another panel may have taken it).
function PanelSheet.copySlot(i, owner)
    local q = i and _quads[i]
    if not (_canvas and q and love.graphics.newCanvas) then return nil end
    if owner ~= nil and _owner[i] ~= owner then return nil end
    local w, h = _w + 2 * PAD, _h + 2 * PAD
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok or not c then return nil end
    love.graphics.push("all")
    love.graphics.setCanvas(c)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(_canvas, q, 0, 0)
    love.graphics.pop()
    return c, PAD
end

-- The canvas itself (tests watch its release).
function PanelSheet.debugCanvas() return _canvas end
function PanelSheet.debugSize() return _n, _w, _h, _cols, _rows end

-- Drop the sheet (the cache switched off; a fresh one comes with the next
-- ensure). Nothing held, nothing done: the generation moves only when a
-- picture was lost.
function PanelSheet.release()
    if _writing then PanelSheet.endWrite() end
    if _canvas or _n ~= 0 then drop() end
end

return PanelSheet
