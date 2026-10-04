-- services/CursorIntent.lua
--
-- Which shape the player's cursor takes this frame (services/PlayerCursor).
-- begin() at the top of the update; whatever owns a hoverable thing calls
-- mark(kind) from its hover pass (ComponentRenderer's buttons, GrindView's
-- table hit boxes and drag); resolve() at the end of the update picks the
-- highest priority and shows it. Highest first:
--
--   wait    the story is holding the click (decided in resolve, from opts)
--   fist    a table is being carried
--   lock    on a locked control
--   no      on a refusal: a disabled button, a dead REBUY (any surface the
--           click registry calls "denied", services/ClickSurfaces)
--   point   a click here does something
--   open    a table header, which can be picked up
--   info    a tooltip is up and nothing above applies (services/Tooltip)
--   arrow   otherwise
--
-- Modifiers: pressed while the mouse button is down; a glitch frame now and
-- then while the board is over its focus cap or the bankroll has
-- underflowed (never while waiting, never at Motion None).

local Cfg = require("data.player_cursor")

local CursorIntent = {}

local PRIORITY = { wait = 8, fist = 7, lock = 6, no = 5, point = 4, open = 3, info = 2, arrow = 1 }
CursorIntent.PRIORITY = PRIORITY

local _kind
local _next_glitch, _glitch_until, _glitch_frame = nil, 0, 1
local _rng = (love and love.math and love.math.random) or math.random

function CursorIntent.begin() _kind = nil end

function CursorIntent.mark(kind)
    local p = PRIORITY[kind]
    if p and (not _kind or p > PRIORITY[_kind]) then _kind = kind end
end

function CursorIntent.marked() return _kind end

local function between(r) return r[1] + (r[2] - r[1]) * _rng() end

-- opts: waiting (bool), denied (the surface under the pointer refuses a
-- click), tooltip (one is up), pressed, strain (tables over the focus cap),
-- underflow, still (Motion None for cursors), now (seconds), apply (a
-- function(kind, pressed, glitch); PlayerCursor.set by default).
-- Returns the kind, pressed, and the glitch frame (or nil).
function CursorIntent.resolve(opts)
    opts = opts or {}
    if opts.denied then CursorIntent.mark("no") end
    local kind = _kind
    if opts.waiting then kind = "wait" end
    if not kind then kind = opts.tooltip and "info" or "arrow" end

    local glitch = nil
    local g = Cfg.glitch
    local strain = opts.strain or 0
    local now = opts.now or 0
    if g and (strain > 0 or opts.underflow) and not opts.still and kind ~= "wait" then
        if not _next_glitch then _next_glitch = now + between(g.every) / (1 + (g.strain_speedup or 0) * strain) end
        if now >= _next_glitch then
            _glitch_until = now + between(g.show)
            _glitch_frame = math.max(1, math.min(g.frames or 1, math.floor(_rng() * (g.frames or 1)) + 1))
            _next_glitch = now + between(g.every) / (1 + (g.strain_speedup or 0) * strain)
        end
        if now < _glitch_until then glitch = _glitch_frame end
    else
        _next_glitch = nil
    end

    local apply = opts.apply or require("services.PlayerCursor").set
    apply(kind, opts.pressed and true or false, glitch)
    return kind, opts.pressed and true or false, glitch
end

-- Tests: forget the glitch clock.
function CursorIntent.reset() _kind, _next_glitch, _glitch_until = nil, nil, 0 end

return CursorIntent
