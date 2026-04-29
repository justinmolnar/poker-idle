-- services/Ghosts.lua
--
-- Press-then-vanish ghost-button registry. Stateless module mirroring
-- HoverService / ClickFlash / ChipFlightSystem. When an ephemeral button
-- (DEAL / REBUY / [×]) is clicked, the underlying render path stops
-- because the table state changes (or the table itself is removed). To
-- keep the press-in animation visible for a beat after the click, the
-- click handler stashes a "ghost" entry here: a snapshot of the button's
-- rect plus a render callback that draws it. The ghost runs alpha 1 → 0
-- at DECAY_RATE, then despawns.
--
-- Engine-agnostic: opaque rect + render-fn. No knowledge of buttons or
-- poker beyond what the caller bundles into the closure.

local Ghosts = {}

local _ghosts = {}

-- Ghost lifetime in ~seconds. Matches the ClickFlash decay so persistent
-- buttons (which animate via ClickFlash) and ephemeral buttons (which
-- animate via Ghosts) feel the same on click.
local DECAY_RATE = 2.0

-- Push a ghost. `render_fn(alpha)` is called each frame with alpha in
-- [0, 1] — 1 = fresh click (button still pressed), 0 = animation done
-- (despawn imminent). Caller typically maps this to Button.draw with
-- press_alpha = (1 - alpha) so the ghost rises out of its press-down
-- state, plus an opacity multiplier of `(1 - alpha)` to fade away as the
-- press completes.
function Ghosts.add(render_fn)
    if not render_fn then return end
    _ghosts[#_ghosts + 1] = { fn = render_fn, alpha = 1.0 }
end

function Ghosts.update(dt)
    if not dt or dt <= 0 then return end
    local step = DECAY_RATE * dt
    for i = #_ghosts, 1, -1 do
        local g = _ghosts[i]
        g.alpha = g.alpha - step
        if g.alpha <= 0 then
            table.remove(_ghosts, i)
        end
    end
end

function Ghosts.draw()
    for _, g in ipairs(_ghosts) do
        g.fn(g.alpha)
    end
end

function Ghosts.clear()
    _ghosts = {}
end

function Ghosts.count()
    return #_ghosts
end

return Ghosts
