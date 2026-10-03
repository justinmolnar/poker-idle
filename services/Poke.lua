-- services/Poke.lua
--
-- One spring for every little reaction to a click: a card jumping, a chip
-- column hopping, the House poster swinging on its pin, a refused button
-- shaking its head. `hit(key, kind, strength)` starts one; a renderer asks
-- `offset(key)` while it draws the thing and gets dx, dy, rot, scale to
-- apply (0, 0, 0, 1 at rest). Time-based (love.timer), so nothing ticks it.
--
-- Kinds (amplitude in px or radians, duration in seconds, the shape):
--   shake   side to side, decaying      (a denied button)
--   jump    up and back with a settle   (a card)
--   hop     a short up-down             (a chip column)
--   wobble  a lean back and forth       (a pile)
--   swing   a pendulum about the top    (the poster on its pin)
--   bob     a soft down-up              (a room item)
--   jostle  a nudge up with a squash    (a rail readout)
--   scoot   a slide away and back       (the book or pamphlet on the felt)
--   rattle  a fast small shiver         (the speaker grille)
--
-- Motion: at "ui" Low or None nothing moves (offset is always at rest),
-- except shake at Low, a third as wide: a refusal has to read somehow.

local Motion = require("services.Motion")

local Poke = {}

local KINDS = {
    shake  = { dur = 0.36, amp = 6,    freq = 5.5 },
    jump   = { dur = 0.32, amp = 10 },
    hop    = { dur = 0.26, amp = 9 },
    wobble = { dur = 0.45, amp = 0.09, freq = 2.5 },
    swing  = { dur = 1.10, amp = 0.14, freq = 1.6 },
    bob    = { dur = 0.36, amp = 5 },
    jostle = { dur = 0.28, amp = 5 },
    scoot  = { dur = 0.34, amp = 9 },
    rattle = { dur = 0.28, amp = 2.5,  freq = 14 },
}
Poke.KINDS = KINDS

local _hits = {}      -- key -> { kind, t0, strength, dir }

local function now() return (love and love.timer and love.timer.getTime()) or os.clock() end

function Poke.hit(key, kind, strength, dir)
    if not key or not KINDS[kind] then return end
    local h = _hits[key]
    if not h then h = {}; _hits[key] = h end
    h.kind, h.t0, h.strength, h.dir = kind, now(), strength or 1, dir or 1
end

-- Is a poke on `key` still moving?
function Poke.active(key)
    local h = key and _hits[key]
    if not h then return false end
    if now() - h.t0 >= KINDS[h.kind].dur then _hits[key] = nil; return false end
    return true
end

-- dx, dy, rot, scale for `key` this frame.
function Poke.offset(key)
    local h = key and _hits[key]
    if not h then return 0, 0, 0, 1 end
    local k = KINDS[h.kind]
    local t = (now() - h.t0) / k.dur
    if t >= 1 then _hits[key] = nil; return 0, 0, 0, 1 end
    local lvl = Motion.level("ui")
    local s = h.strength
    if lvl <= Motion.LOW then
        if h.kind ~= "shake" or lvl < Motion.LOW then return 0, 0, 0, 1 end
        s = s / 3
    end
    local decay = 1 - t
    local kind, amp = h.kind, k.amp * s
    if kind == "shake" then
        return math.sin(t * k.freq * 2 * math.pi) * amp * decay, 0, 0, 1
    elseif kind == "jump" then
        -- up fast, down, a small settle bounce
        local y = (t < 0.5) and math.sin(t / 0.5 * math.pi) or (0.25 * math.sin((t - 0.5) / 0.5 * math.pi))
        return 0, -y * amp, 0, 1
    elseif kind == "hop" then
        return 0, -math.sin(t * math.pi) * amp, 0, 1
    elseif kind == "wobble" or kind == "swing" then
        return 0, 0, math.sin(t * k.freq * 2 * math.pi) * amp * decay * h.dir, 1
    elseif kind == "bob" then
        return 0, math.sin(t * math.pi) * amp, 0, 1
    elseif kind == "jostle" then
        local y = math.sin(t * math.pi)
        return 0, -y * amp, 0, 1 + 0.06 * y * s
    elseif kind == "scoot" then
        return math.sin(t * math.pi) * amp * h.dir, 0, 0, 1
    elseif kind == "rattle" then
        return math.sin(t * k.freq * 2 * math.pi) * amp * decay, math.cos(t * k.freq * 2 * math.pi * 1.3) * amp * 0.5 * decay, 0, 1
    end
    return 0, 0, 0, 1
end

-- Draw `fn` under the key's offset, pivoting rotation and scale on (px, py).
function Poke.draw(key, px, py, fn, ...)
    local dx, dy, rot, sc = Poke.offset(key)
    if dx == 0 and dy == 0 and rot == 0 and sc == 1 then return fn(...) end
    love.graphics.push()
    love.graphics.translate(px + dx, py + dy)
    if rot ~= 0 then love.graphics.rotate(rot) end
    if sc ~= 1 then love.graphics.scale(sc, sc) end
    love.graphics.translate(-px, -py)
    fn(...)
    love.graphics.pop()
end

-- Is any poke whose key starts with `prefix` still moving? Walks only the
-- live pokes (a handful at most).
function Poke.anyActive(prefix)
    local n = #prefix
    for key in pairs(_hits) do
        if key:sub(1, n) == prefix and Poke.active(key) then return true end
    end
    return false
end

function Poke.clear() _hits = {} end

return Poke
