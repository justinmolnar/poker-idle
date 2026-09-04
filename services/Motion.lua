-- services/Motion.lua
--
-- How much the game moves, by group and by level. The accessibility knob:
-- a player who wants less motion sets a level here and every animation
-- primitive (FlightSystem, Tumble, AnimationSystem, RollingValue,
-- GlyphMorph, FloatingTextSystem, ClickFlash, AwardGlow, SpriteLoader,
-- ShaderRegistry) and every hand-drawn effect asks this before it moves.
--
-- Levels, applied to every group:
--   4 Full    as authored
--   3 High    the flourishes go: shake, confetti, sparkles, ripples, tumble,
--             scatters, glow loops. Flights and turns stay.
--   2 Medium  flights and turns shortened (×SCALE_MEDIUM, no stagger);
--             nothing loops (idle shine, pulses, breathing, animated art);
--             no hover lifts; floaters don't drift.
--   1 Low     no flights, turns, lifts or offsets. Everything appears by a
--             short fade at its final place (Motion.fade). Still indicators.
--   0 None    Low without the fades: instant. Cursors hidden, cinematics
--             skipped, floaters off.
--
-- Groups are the checkboxes on the Settings > Motion page. A master level
-- writes every group; groups can then differ ("Custom").
--
-- Engine-agnostic apart from the wall clock. Persisted as motion_<group>
-- keys in settings.save (absent = Full), through load / save below.

local Motion = {}

Motion.NONE, Motion.LOW, Motion.MEDIUM, Motion.HIGH, Motion.FULL = 0, 1, 2, 3, 4
Motion.LEVEL_LABELS = { [0] = "None", [1] = "Low", [2] = "Medium", [3] = "High", [4] = "Full" }

-- Duration multiplier at Medium. Below Medium nothing travels.
local SCALE_MEDIUM = 0.6
-- The universal substitute at Low: the fade-in at the final place.
Motion.FADE_SECS = 0.15

Motion.GROUPS = {
    { id = "cards",      label = "Cards",      desc = "Card flights and turns" },
    { id = "chips",      label = "Chips",      desc = "Chip flights, piles, bursts, confetti" },
    { id = "tables",     label = "Tables",     desc = "Lift, shake, pulses, tilt, fire, punches" },
    { id = "cursors",    label = "Cursors",    desc = "The cursors (hidden at None; they still deal)" },
    { id = "paper",      label = "Paper",      desc = "Catalog and pamphlet throws, page turns, receipt" },
    { id = "text",       label = "Text",       desc = "Floaters, rolling numbers, typewriter" },
    { id = "shine",      label = "Shine",      desc = "Foil, item shaders, animated art, room lighting" },
    { id = "ui",         label = "Interface",  desc = "Button press, flashes, glows, stickers, stamps, slides" },
    { id = "cinematics", label = "Cinematics", desc = "The shove's room count and buildup" },
}

local _level = {}
for _, g in ipairs(Motion.GROUPS) do _level[g.id] = Motion.FULL end

local function clampLevel(n)
    n = tonumber(n) or Motion.FULL
    n = math.floor(n + 0.5)
    if n < 0 then return 0 elseif n > 4 then return 4 end
    return n
end

-- ── Reading ───────────────────────────────────────────────────────────

-- The level for a group. Unknown groups read as Full, so a mistyped id
-- can only ever fail toward motion, never toward a frozen screen.
function Motion.level(group)
    local l = _level[group]
    if l == nil then return Motion.FULL end
    return l
end

-- Is the group at `n` or above?
function Motion.at(group, n)
    return Motion.level(group) >= (n or Motion.FULL)
end

-- Duration multiplier for a travelling thing: 1 at High and Full, shorter
-- at Medium, 0 below (the caller lands it at once).
function Motion.scale(group)
    local l = Motion.level(group)
    if l >= Motion.HIGH then return 1 end
    if l == Motion.MEDIUM then return SCALE_MEDIUM end
    return 0
end

-- A clock for things that loop (shaders, drifting art): live at High and
-- above, frozen below.
function Motion.time(group, t)
    if Motion.level(group) >= Motion.HIGH then return t end
    return 0
end

-- ── The fade ──────────────────────────────────────────────────────────
-- Alpha for something that has just appeared under `key`. At Low it runs
-- 0 → 1 over FADE_SECS from the first call; at every other level it is 1
-- (above Low the thing travelled; at None it is simply there). Keys are
-- forgotten once they reach 1, so a key reused for the next appearance
-- fades again.
local _fade = {}
local function now() return (love and love.timer and love.timer.getTime()) or 0 end

function Motion.fade(group, key)
    if Motion.level(group) ~= Motion.LOW or not key then
        if key then _fade[key] = nil end
        return 1
    end
    local t0 = _fade[key]
    local t  = now()
    if not t0 then _fade[key] = t; return 0 end
    local a = (t - t0) / Motion.FADE_SECS
    if a >= 1 then _fade[key] = nil; return 1 end
    return a
end

-- Forget a fade key (the thing left before its fade finished).
function Motion.forget(key) if key then _fade[key] = nil end end

-- A pop through the level: as authored at High and Full, half the bump at
-- Medium, none below. `Pop.progress` returns 1 → 0; callers scale it.
function Motion.pop(group, progress)
    local l = Motion.level(group)
    if l >= Motion.HIGH then return progress or 0 end
    if l == Motion.MEDIUM then return (progress or 0) * 0.5 end
    return 0
end

-- ── Writing ───────────────────────────────────────────────────────────

function Motion.set(group, n)
    if _level[group] ~= nil then _level[group] = clampLevel(n) end
end

function Motion.setAll(n)
    n = clampLevel(n)
    for _, g in ipairs(Motion.GROUPS) do _level[g.id] = n end
end

-- The common level of every group, or nil when they differ.
function Motion.master()
    local m
    for _, g in ipairs(Motion.GROUPS) do
        local l = _level[g.id]
        if m == nil then m = l elseif l ~= m then return nil end
    end
    return m
end

function Motion.masterLabel()
    local m = Motion.master()
    return m and Motion.LEVEL_LABELS[m] or "Custom"
end

function Motion.label(group)
    return Motion.LEVEL_LABELS[Motion.level(group)] or "Full"
end

-- The next level down, wrapping from None back to Full (a click cycles).
function Motion.nextLevel(n)
    n = clampLevel(n)
    if n <= 0 then return Motion.FULL end
    return n - 1
end

-- ── Persistence (settings.save keys, merged by the caller) ────────────

function Motion.load(settings)
    if type(settings) ~= "table" then return end
    for _, g in ipairs(Motion.GROUPS) do
        local v = settings["motion_" .. g.id]
        _level[g.id] = (v == nil) and Motion.FULL or clampLevel(v)
    end
end

function Motion.save(settings)
    if type(settings) ~= "table" then return end
    for _, g in ipairs(Motion.GROUPS) do
        settings["motion_" .. g.id] = _level[g.id]
    end
end

return Motion
