-- services/GlyphMorph.lua
--
-- Text that arrives as something else. Every plain character starts as a
-- glyph from an alien pool (Σ, ∞, ◊, Þ, ¶ ...), re-rolls on a tick, and
-- locks into its real character left to right as `progress` runs 0 → 1,
-- with a little per-character stagger so the line settles like a hash
-- resolving rather than a curtain. IconText markers ({achip}, {arrow}) and
-- spaces are never touched, so the string stays renderable through
-- views/IconText at every step.
--
-- Pure: no time source, no randomness of its own. The caller passes
-- `progress` (0..1) and `tick` (an integer that advances when the caller
-- wants the unresolved glyphs to change); the glyph for a slot is a hash of
-- (seed, slot, tick), so the same inputs draw the same string and nothing
-- flickers between frames the caller did not ask for.
--
-- Engine-agnostic: no love.*, plain arithmetic hashing (no bitwise ops, so
-- it runs under LuaJIT and 5.4 alike). Lifts into any idle game that wants
-- text to look like someone ELSE put it there.

local Motion = require("services.Motion")
local GlyphMorph = {}

-- Glyphs the game font carries (see the font's character set) that read as
-- nothing in particular: maths, currency, runes.
GlyphMorph.POOL = {
    "Δ", "Π", "Σ", "√", "∞", "∫", "≈", "≠", "≤", "≥", "◊", "Ω", "π",
    "ß", "Ð", "Þ", "ð", "§", "¶", "¥", "€", "¢", "¬", "¿", "¡", "†", "‡",
    "½", "¼", "¾", "Æ", "Ø", "Ł",
}

local M = 2147483647
local function hash(seed, a, b)
    local h = 5381
    local key = tostring(seed) .. ":" .. tostring(a) .. ":" .. tostring(b)
    for i = 1, #key do h = (h * 33 + key:byte(i)) % M end
    -- one squaring round so adjacent inputs scatter (see services/Decal)
    h = (h % 67108859)
    h = (h * h + 7) % 67108859
    return h
end

-- Split a marker string into pieces: { text = "..." } for plain runs and
-- { marker = "{name}" } for markers, preserving order.
local function split(str)
    local out, i, n = {}, 1, #str
    while i <= n do
        local a, b = str:find("%b{}", i)
        if a == i then
            out[#out + 1] = { marker = str:sub(a, b) }
            i = b + 1
        else
            local stop = (a and a - 1) or n
            out[#out + 1] = { text = str:sub(i, stop) }
            i = stop + 1
        end
    end
    return out
end

-- UTF-8 aware character iteration.
local function chars(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end

-- The string to draw for this frame.
--   text      the real string, markers allowed
--   progress  0 = all alien, 1 = all real
--   seed      anything stable per string (an item id)
--   tick      integer; bump it to re-roll the unresolved glyphs
--   opts.stagger  0..1 how uneven the per-character lock order is (default 0.35)
function GlyphMorph.text(text, progress, seed, tick, opts)
    -- Motion: Low and None print the real text; Medium resolves twice as fast.
    do
        local lvl = Motion.level("text")
        if lvl <= Motion.LOW then return text end
        if lvl == Motion.MEDIUM then progress = math.min(1, (progress or 0) * 2) end
    end
    opts = opts or {}
    if progress == nil then progress = 1 end
    if progress >= 1 then return text end
    local stagger = opts.stagger or 0.35
    local pieces = split(text)
    -- count plain, non-space characters to place each on the 0..1 line
    local total = 0
    for _, p in ipairs(pieces) do
        if p.text then
            for _, ch in ipairs(chars(p.text)) do
                if ch ~= " " then total = total + 1 end
            end
        end
    end
    if total == 0 then return text end
    local pool = GlyphMorph.POOL
    local out, slot = {}, 0
    for _, p in ipairs(pieces) do
        if p.marker then
            out[#out + 1] = p.marker
        else
            for _, ch in ipairs(chars(p.text)) do
                if ch == " " then
                    out[#out + 1] = ch
                else
                    slot = slot + 1
                    -- this slot locks at its position on the line, jittered
                    local base   = (slot - 0.5) / total
                    local jitter = (hash(seed, slot, "lock") % 1000) / 1000 - 0.5
                    local lock_at = base + jitter * stagger
                    if progress >= lock_at then
                        out[#out + 1] = ch
                    else
                        out[#out + 1] = pool[(hash(seed, slot, tick) % #pool) + 1]
                    end
                end
            end
        end
    end
    return table.concat(out)
end

-- A settled line, with one glyph briefly wrong: the text re-asserting
-- itself. `which` picks the slot (hash it from a slow tick); nil = none.
function GlyphMorph.spark(text, seed, tick, which_tick)
    local pieces = split(text)
    local total = 0
    for _, p in ipairs(pieces) do
        if p.text then for _, ch in ipairs(chars(p.text)) do if ch ~= " " then total = total + 1 end end end
    end
    if total == 0 then return text end
    local target = (hash(seed, "spark", which_tick) % total) + 1
    local out, slot = {}, 0
    for _, p in ipairs(pieces) do
        if p.marker then out[#out + 1] = p.marker
        else
            for _, ch in ipairs(chars(p.text)) do
                if ch == " " then out[#out + 1] = ch
                else
                    slot = slot + 1
                    if slot == target then
                        out[#out + 1] = GlyphMorph.POOL[(hash(seed, slot, tick) % #GlyphMorph.POOL) + 1]
                    else
                        out[#out + 1] = ch
                    end
                end
            end
        end
    end
    return table.concat(out)
end

return GlyphMorph
