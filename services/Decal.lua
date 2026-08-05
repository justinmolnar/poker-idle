-- services/Decal.lua
--
-- Deterministic placement jitter for things APPLIED to a surface — stickers,
-- rubber stamps, decals, anything that a person put there by hand and so
-- should not be laser-aligned.
--
-- The whole point is that it is deterministic. Real randomness re-rolls every
-- frame and the decal vibrates; `love.math.random` also depends on how many
-- other draws happened first, so the same card would sit differently depending
-- on which page you opened. Instead every offset is hashed from a stable key
-- (an item id, usually), so a given decal lands in exactly the same spot on
-- every frame, every session, forever — but a different decal, or the same
-- decal on a different item, lands somewhere else.
--
-- Engine-agnostic: no love.* calls, no game concepts, pure arithmetic. It
-- returns numbers; the caller decides what to do with them.
--
--   local dx, dy, angle = Decal.place("ordered:" .. item.id, {
--       dx = 8, dy = 5, angle = 0.10, base_angle = -0.12,
--   })
--
-- Bitwise ops are avoided on purpose: LÖVE ships LuaJIT (5.1 semantics) where
-- `~` and `&` are syntax errors, so this stays on plain arithmetic that runs
-- identically under 5.1 and 5.4. All intermediates stay under 2^53 so double
-- precision is exact.

local Decal = {}

local M = 2147483647   -- 2^31 - 1, Mersenne prime
local A = 48271        -- Lehmer/MINSTD multiplier; A * M < 2^53, so exact

-- djb2, modulo-folded to stay in integer range.
local function hashKey(key)
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + key:byte(i)) % M
    end
    return h
end

-- One decorrelated value in [0, 1) per `salt`, so dx / dy / angle drawn from
-- the same key don't march in lockstep.
local function unit(h, salt)
    local v = (h + salt * 2654435761) % M
    v = (v * A) % M
    return v / M
end

-- Symmetric spread: [0,1) → [-range, +range].
local function spread(u, range)
    return (u * 2 - 1) * (range or 0)
end

-- Stable pseudo-random offset + angle for the decal identified by `key`.
--
-- opts:
--   dx, dy      (px, default 0) — maximum offset either way from the anchor
--   angle       (radians, default 0) — maximum tilt either way
--   base_angle  (radians, default 0) — tilt to jitter around, so a stamp can
--                                      keep a deliberate lean and still vary
--
-- Returns dx, dy, angle.
function Decal.place(key, opts)
    opts = opts or {}
    local h = hashKey(tostring(key or ""))
    return spread(unit(h, 1), opts.dx),
           spread(unit(h, 2), opts.dy),
           (opts.base_angle or 0) + spread(unit(h, 3), opts.angle)
end

-- A single stable value in [0, 1) for `key`, when a caller wants to vary
-- something other than position (which of several stamp arts, say).
function Decal.unit(key, salt)
    return unit(hashKey(tostring(key or "")), salt or 0)
end

-- A stable value somewhere in [lo, hi] for `key`.
--
-- Prefer this over `place` when you know the actual room available. Jittering
-- a few pixels around a fixed anchor reads as "the same place" no matter how
-- random the number is — what makes decals look hand-applied is landing
-- anywhere in the space they COULD occupy. Callers pass the real bounds
-- (left edge of the free area, right edge minus the decal's width) and get a
-- position that uses all of it. `lo > hi` collapses to `lo`, so a decal
-- bigger than its space just pins instead of inverting.
function Decal.lerp(key, salt, lo, hi)
    if hi <= lo then return lo end
    return lo + (hi - lo) * unit(hashKey(tostring(key or "")), salt or 0)
end

return Decal
