-- services/ClickFlash.lua
--
-- Per-element click-feedback flash registry. Mirrors HoverService — stateless
-- module, file-local state, callers pass (namespace, id) tuples.
--
-- Flow each frame:
--   1. love.update calls ClickFlash.update(dt) — decays every active flash.
--   2. UI click handlers call ClickFlash.flash(ns, id) at dispatch time.
--   3. Render functions read ClickFlash.alpha(ns, id) and apply a press
--      tint when > 0.
--
-- Engine-agnostic: the registry has no idea what a "button" is. The only
-- assumptions are that ns/id form a stable lookup key and that 0..1 alpha
-- is a sensible decay value for the renderer.

local Motion = require("services.Motion")
local ClickFlash = {}

-- { [ns] = { [id] = alpha } }. Empty namespaces get pruned during update.
local _flashes = {}

-- Fade duration ~0.5 s — slow enough to read as a press, fast enough to
-- feel responsive. Earlier 0.17 s was technically correct but easy to miss.
local DECAY_RATE = 2.0

function ClickFlash.flash(ns, id, intensity)
    intensity = intensity or 1.0
    local bucket = _flashes[ns]
    if not bucket then
        bucket = {}
        _flashes[ns] = bucket
    end
    -- Refresh always wins over decayed-in-progress; pressing twice keeps the
    -- visual responsive instead of fading mid-press.
    bucket[id] = intensity
end

function ClickFlash.alpha(ns, id)
    -- Motion: at Low and None a press shows no decaying flash.
    if Motion.level("ui") <= Motion.LOW then return 0 end
    local bucket = _flashes[ns]
    if not bucket then return 0 end
    return bucket[id] or 0
end

-- The flash regardless of motion level, for a renderer that stills it
-- itself (views/AwardGlow).
function ClickFlash.raw(ns, id)
    local bucket = _flashes[ns]
    if not bucket then return 0 end
    return bucket[id] or 0
end

function ClickFlash.update(dt)
    if not dt or dt <= 0 then return end
    local step = DECAY_RATE * dt
    for ns, bucket in pairs(_flashes) do
        local empty = true
        for id, a in pairs(bucket) do
            local na = a - step
            if na <= 0 then
                bucket[id] = nil
            else
                bucket[id] = na
                empty = false
            end
        end
        if empty then _flashes[ns] = nil end
    end
end

function ClickFlash.clear()
    _flashes = {}
end

return ClickFlash
