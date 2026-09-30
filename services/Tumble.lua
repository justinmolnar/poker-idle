-- services/Tumble.lua
--
-- Fake-3D motion for things thrown through the air. Two forms of the same
-- maths:
--
--   * roll(opts, rec) / eval(rec, t) — the motion numbers written onto a
--     caller's record and read back as (squash, near, spin) at a progress.
--     What services/FlightSystem's chip records use: no closure per chip,
--     and the renderer folds the three into one sprite transform.
--   * wrap(render_fn, opts) — the decorator form. Wraps a `function(x, y)`
--     and returns a `function(x, y, t)` that draws the same thing spinning
--     and tumbling under love.graphics transforms. Cards and the currency
--     glyph still fly this way.
--
-- Knows NOTHING about what it's decorating — chips, cards, quads, sprites,
-- anything with a render callback. Composes with services/FlightSystem
-- (which supplies the `t`) but doesn't depend on it: any caller that can
-- produce a 0..1 progress can drive this.
--
-- ─── How the 3D read works ──────────────────────────────────────────────
-- A poker chip is a flat cylinder. Thrown, it does two things at once:
--
--   TUMBLE — rotation about an axis lying IN the object's face. You see it
--            go face-on (full circle) → edge-on (thin sliver) → face-on.
--            This is the effect that actually sells depth, and it's just a
--            one-axis scale by |cos(angle)|.
--   SPIN   — rotation about the axis through the face. On a plain disc this
--            is nearly invisible; on a chip with a denomination label it's
--            what makes the label wheel around.
--   LOFT   — the third one: it comes toward the camera. A thrown object
--            rises out of the plane and gets nearer, so it reads BIGGER at
--            the top of its arc and back to its own size when it lands.
--            A uniform scale on a half-sine, peaking at the midpoint. The
--            bezier arc in services/FlightSystem bends the path; this is
--            what makes the arc read as height rather than as a detour.
--
-- All three are driven off flight progress, not delta-time, so the motion
-- is frame-rate independent and two chips launched together stay in sync.
--
-- `min_squash` stops the tumble collapsing to a zero-height line. A real
-- chip has thickness, so it never disappears at edge-on — clamping the
-- squash is a one-number stand-in for drawing an actual edge, and it means
-- this module never has to know the object's color or dimensions.
--
-- ─── Usage ──────────────────────────────────────────────────────────────
--   local fn = function(x, y) Chips.drawChip(x, y, idx, 1, true, tint) end
--   FlightSystem.emit(a, b, Tumble.wrap(fn))
--
-- The wrapped callback is invoked as fn(x, y, t, squash). `squash` is the
-- current foreshortening, 0..1, and a callback may use it to swap in an
-- edge-on representation of itself — see views/ChipFlight.
--
-- Every option is optional; omitted ones are randomised per roll so a
-- burst of them doesn't move as one rigid body.

local Motion = require("services.Motion")

local Tumble = {}

-- Defaults, expressed as full rotations over the whole flight.
local SPINS_MIN,  SPINS_MAX  = 0.5, 2.5
local FLIPS_MIN,  FLIPS_MAX  = 0.75, 2.75
local MIN_SQUASH             = 0.14
-- Loft as a fraction of the object's own size at the apex: 0.4 = 40%
-- larger halfway through the flight.
local LOFT_MIN,   LOFT_MAX   = 0.18, 0.45

local TAU = math.pi * 2

local function rand(lo, hi) return lo + love.math.random() * (hi - lo) end

-- An option may be a fixed number (pin it), a { min, max } table (roll in
-- that range, per entity), or nil (roll in the module default range).
local function pick(v, lo, hi)
    if type(v) == "table" then return rand(v[1], v[2]) end
    if v then return v end
    return rand(lo, hi)
end

-- ─── Presets ────────────────────────────────────────────────────────────
-- Named motion characters, so call sites say what the movement MEANS
-- instead of picking numbers. Pass one as the opts table.
--
--   toss  — a chip moved deliberately from one place to another: into the
--           pot, to your stack, to the bankroll. Barely more than half a
--           lazy turn, never gets thin, lifted just off the felt. Adds
--           life without cartwheeling.
--   throw — a chip that has been launched: a pot detonating, a table
--           flipped. Multiple full tumbles, goes properly edge-on, and
--           comes well up toward the camera.
Tumble.PRESETS = {
    toss  = { flips = { 0.25, 0.70 }, spins = { 0.20, 0.80 }, min_squash = 0.35,
              loft = { 0.10, 0.22 } },
    throw = { flips = { 0.75, 2.75 }, spins = { 0.50, 2.50 }, min_squash = 0.14,
              loft = { 0.35, 0.60 } },
}

local EMPTY = {}

-- ─── The record form ────────────────────────────────────────────────────
-- Roll one flight's motion onto `rec` (seven numbers, prefixed tb_). No
-- table is made: services/FlightSystem pools its records and a thousand
-- chips a second fly through here.
--
-- opts: a PRESET table (Tumble.PRESETS.toss / .throw) or your own. Each
-- field may be a number (pinned), a { min, max } range, or omitted.
--   spins       — face rotations over the flight (default random)
--   flips       — edge-over-edge tumbles over the flight (default random)
--   axis        — radians; which way the tumble axis lies (default random)
--   min_squash  — floor on the foreshortening, 0..1 (default 0.14). Lower
--                 reads thinner/sharper; 1.0 disables tumble entirely.
--   phase       — starting point in the tumble cycle (default random, so a
--                 burst doesn't flash edge-on in unison)
--   spin_dir    — 1 or -1 (default random)
--   loft        — extra size at the apex as a fraction of the object's own
--                 size (0.4 = 40% bigger halfway through). 0 keeps it
--                 flat in the plane. Always returns to 1.0 at both ends,
--                 so an object leaves and arrives at its true size — a
--                 chip joining a pile has to be the size of the pile's
--                 chips at the moment it lands.
-- `group` (default "chips"): the motion group; below Full the record is
-- marked flat (tb_on = false) and eval returns the identity, so the thing
-- flies without turning.
--
-- The rolls happen in the order wrap always made them, so a seeded run
-- reproduces the motion it had before the record form existed.
function Tumble.roll(opts, rec, group)
    if not Motion.at(group or "chips", Motion.FULL) then
        rec.tb_on = false
        return rec
    end
    opts = opts or EMPTY
    rec.tb_on     = true
    rec.tb_spins  = pick(opts.spins, SPINS_MIN, SPINS_MAX)
    rec.tb_flips  = pick(opts.flips, FLIPS_MIN, FLIPS_MAX)
    rec.tb_loft   = pick(opts.loft,  LOFT_MIN,  LOFT_MAX)
    rec.tb_axis   = opts.axis       or (love.math.random() * math.pi)
    rec.tb_minsq  = opts.min_squash or MIN_SQUASH
    rec.tb_phase  = opts.phase      or (love.math.random() * TAU)
    rec.tb_dir    = opts.spin_dir   or ((love.math.random() < 0.5) and -1 or 1)
    return rec
end

-- The motion at progress t: squash (foreshortening across the tumble axis,
-- min_squash..1), near (the loft scale, 1 at both ends) and spin (the face
-- rotation, radians). A record roll() marked flat is the identity.
function Tumble.eval(rec, t)
    if not rec.tb_on then return 1, 1, 0 end
    t = t or 0
    local squash = math.abs(math.cos(rec.tb_phase + t * rec.tb_flips * TAU))
    local minsq  = rec.tb_minsq
    if squash < minsq then squash = minsq end
    local near = 1
    local loft = rec.tb_loft
    if loft ~= 0 then near = 1 + loft * math.sin(math.pi * t) end
    return squash, near, rec.tb_dir * t * rec.tb_spins * TAU
end

-- ─── The decorator form ─────────────────────────────────────────────────
-- Wrap a render callback so it tumbles in flight. Options as roll(). Below
-- Full the callback is returned untouched and the thing flies flat.
function Tumble.wrap(render_fn, opts, group)
    if not render_fn then return render_fn end
    if not Motion.at(group or "chips", Motion.FULL) then return render_fn end

    local rec = Tumble.roll(opts, {}, group)

    return function(x, y, t)
        t = t or 0
        local squash, near, spin = Tumble.eval(rec, t)

        love.graphics.push()
        love.graphics.translate(x, y)
        -- Nearness to the camera. Uniform, so it scales the whole object
        -- including its label, and applied before the tumble so the two
        -- compose instead of fighting: the chip is bigger AND edge-on at
        -- the same moment if that's where its arc puts it.
        if near ~= 1 then love.graphics.scale(near, near) end
        -- Orient the tumble axis, flatten across it, then spin the face
        -- inside the flattened frame. Spinning after the squash is what
        -- makes the face features sweep in a foreshortened arc instead of
        -- gliding around a flat circle.
        love.graphics.rotate(rec.tb_axis)
        love.graphics.scale(1, squash)
        love.graphics.rotate(spin)
        -- `squash` is handed on so a callback can draw a DIFFERENT thing
        -- when it is nearly edge-on, rather than just a flattened version
        -- of the same thing. A chip on its side shows its rim, not its
        -- face. Callbacks that don't care simply ignore the extra
        -- arguments, which is why this is safe to add.
        render_fn(0, 0, t, squash)
        love.graphics.pop()
    end
end

-- Wrap a whole list in one call. Each entry gets its own randomised
-- motion unless `opts` pins it.
function Tumble.wrapAll(render_fns, opts, group)
    local out = {}
    for i, fn in ipairs(render_fns or {}) do
        out[i] = Tumble.wrap(fn, opts, group)
    end
    return out
end

return Tumble
