-- utils/easing.lua
--
-- Shared easing curves + frame-rate-independent damping. These lived as
-- private per-view copies (ItemGhosts, Button, ShoveView) before the
-- table-drag work needed a fourth; consolidated here instead.
--
-- Pure functions, no deps, engine-agnostic. All curves take t in [0, 1]
-- and return the eased progress (outBack overshoots past 1 by design).

local Easing = {}

-- Ease-out-back: overshoots past 1 then settles — the "pop".
function Easing.outBack(t)
    local c1, c3 = 1.70158, 2.70158
    local u = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
end

function Easing.outCubic(t)
    return 1 - (1 - t) ^ 3
end

function Easing.outQuad(t)
    return 1 - (1 - t) * (1 - t)
end

-- Exponential approach: eases `curr` toward `target` by rate-per-second,
-- independent of frame rate for the small dt steps games run at. The same
-- `k = min(1, dt * rate)` lerp GrindView:tweenNumber and Table's lift
-- tween use.
function Easing.damp(curr, target, rate, dt)
    local k = math.min(1, (dt or 0) * rate)
    return curr + (target - curr) * k
end

return Easing
