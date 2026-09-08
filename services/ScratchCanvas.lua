-- services/ScratchCanvas.lua
--
-- One full-frame canvas, lent out and handed back.
--
-- Several passes need somewhere to compose a full-screen image before
-- blitting it: the hint layer's feathered dim, the title's menu fade. Each
-- kept its own, sized to the frame, reallocated on resize and never
-- released — so the game held several full-screen render targets to use one
-- at a time.
--
-- Only for scratch: draw into it, blit it, give it back within the same
-- pass. Anything that must SURVIVE the frame (the grind's room thumbnail is
-- a cache; the shove's snapshot is handed to the credits screen) owns its
-- own canvas and does not belong here. Nothing nests, which is what makes
-- one canvas enough — a checkout while another is out returns nil and the
-- caller falls back to its un-composited path.
--
-- Engine-agnostic apart from love.graphics.

local ScratchCanvas = {}

local _canvas, _w, _h = nil, 0, 0
local _out = false

-- Borrow the frame-sized canvas. Returns nil when canvases are unavailable
-- or one is already checked out.
function ScratchCanvas.acquire(w, h)
    if _out then return nil end
    if not (love.graphics and love.graphics.newCanvas) then return nil end
    if not _canvas or _w ~= w or _h ~= h then
        local ok, fresh = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
        if not ok or not fresh then return nil end
        if _canvas and _canvas.release then pcall(_canvas.release, _canvas) end
        _canvas, _w, _h = fresh, w, h
    end
    _out = true
    return _canvas
end

function ScratchCanvas.release()
    _out = false
end

-- Drop it entirely (a resize handled elsewhere, a full reset).
function ScratchCanvas.clear()
    if _canvas and _canvas.release then pcall(_canvas.release, _canvas) end
    _canvas, _w, _h, _out = nil, 0, 0, false
end

return ScratchCanvas
