-- views/TablePanelDrag.lua
--
-- The held-table render + hold feel for drag-to-rearrange: the picked-up
-- panel lifts (scale-up + spread drop shadow), sways with mouse velocity,
-- and is drawn above the sidebars while the rest of the grid slides its
-- insert-shift preview underneath (that part lives in GrindView's grid
-- loop). Sibling module split off TablePanel, same as TablePanelEffects /
-- TablePanelStats — TablePanel stays the stateless panel renderer.
--
-- State lives on GrindView's drag latch (passed in); this module is pure
-- functions over it.

local TablePanel = require("views.TablePanel")
local Effects    = require("views.TablePanelEffects")
local Easing     = require("utils.easing")

local TablePanelDrag = {}

local LIFT_IN_S      = 0.14     -- pick-up: seconds to full lift
local HELD_SCALE     = 1.06     -- held panel grows to this at full lift
local TILT_MAX_RAD   = 0.10     -- sway cap (radians)
local TILT_VEL_GAIN  = 0.0009   -- radians per px/s of horizontal velocity
local TILT_DAMP_RATE = 12       -- how fast velocity + tilt settle

-- Advance the hold feel. `drag` is GrindView's latch: px/py (held top-
-- left), vx (damped velocity), tilt, lift all live on it.
function TablePanelDrag.update(drag, dt, mx, my)
    if not dt or dt <= 0 then return end
    local px = mx - (drag.grab_dx or 0)
    local py = my - (drag.grab_dy or 0)
    local vx = drag.px and ((px - drag.px) / dt) or 0
    drag.vx   = Easing.damp(drag.vx or 0, vx, TILT_DAMP_RATE, dt)
    local want = math.max(-TILT_MAX_RAD,
                 math.min( TILT_MAX_RAD, drag.vx * TILT_VEL_GAIN))
    drag.tilt = Easing.damp(drag.tilt or 0, want, TILT_DAMP_RATE, dt)
    drag.px, drag.py = px, py
    drag.lift = math.min(1, (drag.lift or 0) + dt / LIFT_IN_S)
end

-- Render the held panel at the mouse. `held` = { tbl, idx, pw, ph }
-- stashed by _drawCenterGrid (the grid's live cell size).
--
-- Notes:
--  • Shadow via a proxy table — Table:update owns the real tbl.lift_t
--    (deal lift) and must not be written from a view.
--  • Scale-up goes through the SIZE PARAMS, not a graphics scale:
--    TablePanel re-derives all chrome from w/h, so the held panel stays
--    proportional and crisp instead of stretched.
--  • Hit boxes: a throwaway table — the held panel contributes no click
--    targets, so seeking cursors cleanly release it until the drop.
function TablePanelDrag.drawHeld(game, controller, drag, held)
    local tbl = held and held.tbl
    if not (tbl and drag and drag.px) then return end
    local pw, ph = held.pw, held.ph
    local lift   = Easing.outCubic(drag.lift or 0)

    Effects.drawHoverShadow({ lift_t = lift }, drag.px, drag.py, pw, ph)

    local gw = pw * (1 + (HELD_SCALE - 1) * lift)
    local gh = ph * (1 + (HELD_SCALE - 1) * lift)
    local gx = drag.px - (gw - pw) / 2
    local gy = drag.py - (gh - ph) / 2
    local cx = gx + gw / 2
    local cy = gy + gh / 2

    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.rotate(drag.tilt or 0)
    love.graphics.translate(-cx, -cy)
    TablePanel.draw(tbl, held.idx, gx, gy, gw, gh, game, controller, {})
    love.graphics.pop()
end

return TablePanelDrag
