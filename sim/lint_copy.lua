-- sim/lint_copy.lua
--
-- The style-sheet lint (docs/copy-style.md). Walks every copy field
-- (sim/copy_fields.lua) and checks:
--
--   ERROR  a retired word (data/terms.lua `banned`) outside a story beat
--   ERROR  a number in a rule line that the item's effects do not produce,
--          or a number the effects produce that the line does not print
--          (catalog effect_text, corrupt effect_text, deck capstone; deck
--          bonus.per_level against the effect it describes)
--   ERROR  a chance anywhere in data/procs.lua, data/routers.lua or an
--          effect that is not a printable fraction (1 in N, 2 in 3, 2 in 5)
--   WARN   a rule line with "chance" that is not "N in M chance"
--   WARN   an unlock sticker that starts with a capital or an imperative
--          on a kind that prints a counter
--
--   lua sim/lint_copy.lua           (exit 1 on any ERROR)
--   lua sim/lint_copy.lua --quiet   (errors only)
--
-- How a number is expected: each effect kind maps to the string the sheet
-- says it prints (EXPECT below). A proc or router contributes its own
-- chance / every. An item may list `allow_numbers = { 10 }` for a number
-- that is a real-time or count noun with no effect behind it ("10 seconds").
-- Numbers glued to letters or symbols (NL2, T10, 6-Max, 4+) are not numbers.
--
-- Standalone: no LÖVE.

io.stdout:setvbuf("no")
package.path = package.path .. ";./?.lua"

local Terms   = require("data.terms")
local Fields  = require("sim.copy_fields")
local Procs   = require("data.procs")
local Routers = require("data.routers")

local quiet = arg and arg[1] == "--quiet"
local errors, warns = 0, 0
local function err(where, msg, text)
    errors = errors + 1
    print(("ERROR %s: %s in %q"):format(where, msg, text or ""))
end
local function warn(where, msg, text)
    if quiet then return end
    warns = warns + 1
    print(("warn  %s: %s in %q"):format(where, msg, text or ""))
end

-- ── numbers ───────────────────────────────────────────────────────────
local EPS = 1e-6
local FRACTIONS = {}
for _, m in ipairs({ 2, 3, 4, 5, 6, 8, 10, 12, 20, 25, 50, 100 }) do FRACTIONS[#FRACTIONS + 1] = { 1, m } end
FRACTIONS[#FRACTIONS + 1] = { 2, 3 }
FRACTIONS[#FRACTIONS + 1] = { 2, 5 }

local function fraction(c)
    for _, f in ipairs(FRACTIONS) do
        if math.abs(f[1] / f[2] - c) < EPS then return ("%d in %d"):format(f[1], f[2]) end
    end
    return nil
end

local function trim(n)
    -- 1.2 → "1.2", 2.0 → "2", 0.075*100 → "7.5"
    local s = ("%.4f"):format(n):gsub("0+$", ""):gsub("%.$", "")
    return s
end
local function pct(v) return trim(v * 100) end
local function signedPct(v)
    return (v >= 0 and "+" or "-") .. pct(math.abs(v)) .. "%"
end
local function money(v)
    local s = ("%d"):format(math.floor(v + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return "+$" .. out
end

-- effect kind → list of expected strings (nil = prints nothing)
local EXPECT = {
    shove_rate_add            = function() return nil end,
    stack_mult                = function(e) return { "×" .. trim(e.value) } end,
    earnings_mult             = function(e) return { "×" .. trim(e.value) } end,
    loss_mult                 = function(e) return { "×" .. trim(e.value) } end,
    chip_award_mult           = function(e) return { "×" .. trim(e.value) } end,
    bounty_gtype_mult         = function(e) return { "×" .. trim(e.value) } end,
    deck_xp_mult              = function(e) return { "×" .. trim(e.value) } end,
    anti_award_mult           = function(e) return { "×" .. trim(e.value) } end,
    first_anti_mult           = function(e) return { "×" .. trim(e.value) } end,
    cursor_speed_mult         = function(e) return { "×" .. trim(e.value) } end,
    ratchet_gain_mult         = function() return nil end,   -- the Whiteboard states the Prize Vase's new number in words; allow_numbers carries it
    hand_pace_mult            = function(e) return { "×" .. trim(e.value) } end,
    pure_board_pace           = function(e) return { "×" .. trim(e.value) } end,
    win_chance_shift          = function(e) return { signedPct(e.amount) } end,
    corner_win_chance         = function(e) return { signedPct(e.value) } end,
    tourney_backing           = function(e) return { signedPct(e.value) } end,
    run_upgrade_strength_mult = function(e) return { signedPct(e.value) } end,
    run_upgrade_cost_mult     = function(e) return { signedPct(e.value - 1) } end,
    rebuy_discount            = function(e) return { signedPct(-e.value) } end,
    bust_refund_pct           = function(e) return { pct(e.value) .. "%" } end,
    -- the bankroll is multiplied by (1 + value): a value under 1 prints as
    -- the percentage added, a value of 1 or more as the whole multiplier
    start_bankroll_pct        = function(e)
        if e.value < 1 then return { signedPct(e.value) } end
        return { "×" .. trim(1 + e.value) }
    end,
    start_bankroll_add        = function(e) return { money(e.value) } end,
    stack_chip_add            = function(e) return { "+" .. trim(e.value) } end,
    focus_capacity_add        = function(e) return { "+" .. trim(e.value) } end,
    cursor_count_add          = function(e) return { "+" .. trim(e.value) } end,
    run_upgrade_bonus_levels  = function(e) return { "+" .. trim(e.value) } end,
    ko_targets_add            = function(e) return { "+" .. trim(e.value) } end,
    start_table_count         = function(e) return { trim(e.value) } end,
    win_tier_shift            = function(e, where, text)
        local f = fraction(e.chance)
        if not f then err(where, ("chance %s is not a printable fraction"):format(tostring(e.chance)), text) end
        return { f or "?", "{w:" .. e.from .. "}", "{w:" .. e.to .. "}" }
    end,
    loss_tier_shift           = function(e, where, text)
        local f = fraction(e.chance)
        if not f then err(where, ("chance %s is not a printable fraction"):format(tostring(e.chance)), text) end
        return { f or "?", "{l:" .. e.from .. "}", "{l:" .. e.to .. "}" }
    end,
    win_tier_bump_chance      = function(e, where, text)
        local f = fraction(e.value)
        if not f then err(where, ("chance %s is not a printable fraction"):format(tostring(e.value)), text) end
        return { f or "?" }
    end,
    win_payout_double_chance  = function(e, where, text)
        local f = fraction(e.value)
        if not f then err(where, ("chance %s is not a printable fraction"):format(tostring(e.value)), text) end
        return { f or "?", "×2" }
    end,
    earnings_scale_by_bankroll = function(e) return { "×" .. trim(e.cap) } end,
    shove_base_double         = function() return { "×2" } end,
    proc                      = function(e, where, text)
        local p = Procs[e.proc]
        if not p then err(where, "unknown proc " .. tostring(e.proc), text) return nil end
        local out = {}
        if p.chance then
            local f = fraction(p.chance)
            if not f then err(where, ("proc %s chance %s is not a printable fraction"):format(e.proc, tostring(p.chance)), text) end
            out[#out + 1] = f or "?"
        end
        if p.every then out[#out + 1] = "Every " .. trim(p.every) end
        -- a ratchet prints the quantity it adds each time it fires
        if p.payload and p.payload.kind == "ratchet" and p.payload.magnitude then
            out[#out + 1] = signedPct(p.payload.magnitude)
        end
        return out
    end,
    router                    = function(e, where, text)
        local r = Routers[e.router]
        if not r then err(where, "unknown router " .. tostring(e.router), text) return nil end
        if r.chance then
            local f = fraction(r.chance)
            if not f then err(where, ("router %s chance %s is not a printable fraction"):format(e.router, tostring(r.chance)), text) end
            return { f or "?" }
        end
        return nil
    end,
}
-- kinds that print nothing
for _, k in ipairs({ "void_first_loss", "void_first_stack_loss", "six_max_unlocked", "cursor_unlocked",
                     "cursor_instant_click", "cursor_rebuy_unlocked", "cursor_optical_sensor",
                     "cursor_memory_unlocked", "cursor_sync_unlocked", "cursor_collision_phasing",
                     "cascade_deals_empty", "start_biggest_pot", "ultra_unlock_effect",
                     "shove_base_per_deck_level" }) do
    EXPECT[k] = function() return nil end
end

-- Every number in `text` as { s, e, value }, skipping numbers glued to
-- letters or symbols (NL2, T10, 6-Max, 4+, 12:00).
local function numbersIn(text)
    local out = {}
    local bare = text
    local i = 1
    while true do
        local s, e = bare:find("%d[%d,]*", i)
        if not s then break end
        while bare:sub(e, e) == "," do e = e - 1 end   -- a comma after, not a thousands mark
        -- a decimal part, but never a sentence's full stop
        local _, e2 = bare:find("^%.%d+", e + 1)
        if e2 then e = e2 end
        local before = s > 1 and bare:sub(s - 1, s - 1) or " "
        local after  = bare:sub(e + 1, e + 1)
        local glued = before:match("[%w%-%.:]") or after:match("[%w%-%+:]")
        if not glued then
            local v = tonumber((bare:sub(s, e):gsub(",", "")))
            if v then out[#out + 1] = { s = s, e = e, value = v } end
        end
        i = e + 1
    end
    return out
end

-- Two effect entries are the same rule when every field matches.
local function sameEffect(a, b)
    if a.kind ~= b.kind then return false end
    for k, v in pairs(a) do if type(v) ~= "table" and b[k] ~= v then return false end end
    for k, v in pairs(b) do if type(v) ~= "table" and a[k] ~= v then return false end end
    return true
end

-- `inherit`: the base effects a "Same, and <penalty>." corrupt line restates
-- without printing; their numbers are not expected in the text.
local function checkNumbers(where, text, effects, allow, inherit)
    if type(text) ~= "string" or text == "" then return end
    local expected = {}
    local same = inherit and text:match("^Same[,.]") and inherit or nil
    for _, e in ipairs(effects or {}) do
        local fn = EXPECT[e.kind]
        local inherited = false
        if same then
            for _, b in ipairs(same) do if sameEffect(e, b) then inherited = true break end end
        end
        if not fn then
            err(where, "lint has no number rule for effect kind " .. tostring(e.kind), text)
        elseif not inherited then
            for _, s in ipairs(fn(e, where, text) or {}) do expected[#expected + 1] = s end
        end
    end
    -- every expected string must appear; remember the spans it covers
    local covered = {}
    for _, s in ipairs(expected) do
        local a, b = text:find(s, 1, true)
        if not a then
            err(where, ("expected %q from the effects"):format(s), text)
        else
            covered[#covered + 1] = { a, b }
            -- "1 in 4" and "+10%" may legitimately recur (base and corrupt
            -- restated); cover every occurrence
            local i = b + 1
            while true do
                local a2, b2 = text:find(s, i, true)
                if not a2 then break end
                covered[#covered + 1] = { a2, b2 }
                i = b2 + 1
            end
        end
    end
    -- every number in the text must sit inside an expected span (or be allowed)
    local allowed = {}
    for _, n in ipairs(allow or {}) do allowed[n] = true end
    for _, n in ipairs(numbersIn(text)) do
        local ok = allowed[n.value]
        for _, c in ipairs(covered) do
            if n.s >= c[1] and n.e <= c[2] then ok = true break end
        end
        if not ok then err(where, ("number %s has no effect behind it"):format(text:sub(n.s, n.e)), text) end
    end
end

-- deck bonus: per_level in the printed unit. A kind that multiplies once
-- per level must carry `compound = true` on the bonus (models/Decks
-- compounds the shown number), an additive kind must not.
local COMPOUND_KINDS = { earnings_mult = true, hand_pace_mult = true, heater_win_mult = true,
                         tilted_loss_mult = true, pure_board_bonus = true }
local PER_LEVEL = {
    earnings_mult        = function(e) return (e.value - 1) * 100 end,
    hand_pace_mult       = function(e) return (e.value - 1) * 100 end,
    heater_win_mult      = function(e) return (e.value - 1) * 100 end,
    tilted_loss_mult     = function(e) return (1 - e.value) * 100 end,
    win_chance_shift     = function(e) return e.amount * 100 end,
    unbanked_stack_shift = function(e) return e.value * 100 end,
    pure_board_bonus     = function(e) return (e.earnings_mult - 1) * 100 end,
    earnings_per_tier    = function(e) return e.value * 100 end,
    ko_targets_add       = function(e) return e.value end,
    win_dist_shift       = function(e)
        local m = 0
        for _, v in pairs(e.shift) do if v > m then m = v end end
        return m * 100
    end,
    loss_dist_shift      = function(e)
        local m = 0
        for _, v in pairs(e.shift) do if v > m then m = v end end
        return m * 100
    end,
}

-- ── banned words ──────────────────────────────────────────────────────
local BANNED = {}
for phrase, hint in pairs(Terms.banned or {}) do
    local plain = phrase:lower()
    local pat
    if plain:match("^[%w%s%-']+$") then
        pat = "%f[%w]" .. plain:gsub("%-", "%%-") .. "%f[%W]"
    else
        pat = nil   -- plain find
    end
    BANNED[#BANNED + 1] = { phrase = plain, pat = pat, hint = hint }
end
table.sort(BANNED, function(a, b) return a.phrase < b.phrase end)

local function checkBanned(where, text)
    local bare = text:gsub("{[^}]*}", " ")   -- markers are not prose
    local lower = bare:lower() .. " "
    for _, b in ipairs(BANNED) do
        local hit
        if b.pat then hit = lower:find(b.pat) else hit = lower:find(b.phrase, 1, true) end
        if hit then err(where, ("retired %q (write: %s)"):format(b.phrase, b.hint), text) end
    end
    -- spellings: matched as written, case-sensitively
    for phrase, hint in pairs(Terms.banned_case or {}) do
        if bare:find(phrase, 1, true) then err(where, ("retired spelling %q (write: %s)"):format(phrase, hint), text) end
    end
end

-- ── keywords ({k:…}) ──────────────────────────────────────────────────
-- A {k:…} must name a listed keyword; a rule line must not carry a listed
-- keyword bare (the House's lines and flavour are left alone).
local KEYWORDS, KEYWORD_LIST = {}, {}
for _, k in ipairs(Terms.keywords or {}) do
    KEYWORDS[k:lower()] = k
    KEYWORD_LIST[#KEYWORD_LIST + 1] = k:lower()
end
table.sort(KEYWORD_LIST, function(a, b) return #a > #b end)   -- longest first

local function checkKeywords(f)
    local text = f.text
    for word in text:gmatch("{k:([^}]*)}") do
        local w = word:gsub("_", " "):lower()
        if not KEYWORDS[w] then
            err(f.where, ("{k:%s} is not a listed keyword (data/terms.lua keywords)"):format(word), text)
        end
    end
    if f.kind ~= "rule" then return end
    local bare = text:gsub("{[^}]*}", " "):lower()
    for _, k in ipairs(KEYWORD_LIST) do
        local pat = "%f[%w]" .. k:gsub("%-", "%%-") .. "%f[%W]"
        if bare:find(pat) then
            err(f.where, ("bare keyword %q in a rule line (write {k:%s})"):format(k, KEYWORDS[k]:gsub(" ", "_")), text)
            bare = bare:gsub(pat, " ")   -- one report per keyword
        end
    end
end

-- The noise guard: a rule line carries at most two pills, three tints and
-- three keywords.
local function checkNoise(f)
    if f.kind ~= "rule" then return end
    local text = f.text
    local pills = 0
    for _ in text:gmatch("%d+ in %d+") do pills = pills + 1 end
    for _ in text:gmatch("×%d") do pills = pills + 1 end
    for _ in text:gmatch("[%+%-]%$?%d") do pills = pills + 1 end
    local tints, keys = 0, 0
    for _ in text:gmatch("{c:") do tints = tints + 1 end
    for _ in text:gmatch("{k:") do keys = keys + 1 end
    if pills > 2 or tints > 3 or keys > 3 then
        warn(f.where, ("loud: %d pills, %d tints, %d keywords"):format(pills, tints, keys), text)
    end
end

-- ── skeleton hints ────────────────────────────────────────────────────
local IMPERATIVES = { Play = 1, Win = 1, Bank = 1, Hit = 1, Catch = 1, Take = 1, Lose = 1, Earn = 1, Max = 1, Make = 1 }
local function checkSkeleton(f)
    local text = f.text
    if f.where:find(" unlock$") then
        local first = text:match("^(%a+)")
        local counted = f.item and f.item.unlock and f.item.unlock.kind
                        and not f.item.unlock.kind:match("^(has_|shove_r|hu_unlocked)")
        if counted and first and IMPERATIVES[first] then
            warn(f.where, "sticker starts with an imperative on a counted kind (the counter starts the sentence)", text)
        end
    end
end

-- ── walk ──────────────────────────────────────────────────────────────
for _, f in ipairs(Fields) do
    if f.kind ~= "story" then checkBanned(f.where, f.text) end
    if f.item and f.slot == "base" then
        checkNumbers(f.where, f.text, f.item.effects, f.item.allow_numbers)
    elseif f.item and f.slot == "corrupt" then
        checkNumbers(f.where, f.text, f.item.corrupt.effects,
                     f.item.corrupt.allow_numbers or f.item.allow_numbers, f.item.effects)
    elseif f.item and f.slot == "capstone" then
        checkNumbers(f.where, f.text, f.item.capstone.effects, f.item.capstone.allow_numbers)
    elseif f.item and f.slot == "bonus" then
        local d = f.item
        if d.bonus.per_level then
            local got, kind
            for _, e in ipairs(d.effects or {}) do
                local fn = PER_LEVEL[e.kind]
                if fn then got = fn(e) kind = e.kind break end
            end
            if kind then
                local wants = COMPOUND_KINDS[kind] or false
                if (d.bonus.compound or false) ~= wants then
                    err(f.where, ("effect %s is %s per level, so bonus.compound must be %s"):format(
                        kind, wants and "multiplied" or "added", tostring(wants)), f.text)
                end
            end
            if not got then
                err(f.where, "lint has no per_level rule for this deck's effects", f.text)
            elseif math.abs(got - d.bonus.per_level) > EPS then
                err(f.where, ("per_level %s but the effect says %s"):format(tostring(d.bonus.per_level), trim(got)), f.text)
            end
            if not f.text:find("{n}", 1, true) then err(f.where, "bonus text has no {n}", f.text) end
            -- the only number allowed in a bonus line is {n}'s neighbour, none
            for _, n in ipairs(numbersIn((f.text:gsub("{n}", " ")))) do
                if not (d.bonus.allow_numbers and d.bonus.allow_numbers[n.value]) then
                    err(f.where, ("number %s in a bonus line (the number is {n})"):format(tostring(n.value)), f.text)
                end
            end
        end
    end
    checkSkeleton(f)
    checkKeywords(f)
    checkNoise(f)
end

-- every chance in procs/routers is printable, whether or not an item prints it
for id, p in pairs(Procs) do
    if type(p) == "table" and p.chance and not fraction(p.chance) then
        err("proc " .. id, ("chance %s is not a printable fraction"):format(tostring(p.chance)))
    end
end
for id, r in pairs(Routers) do
    if type(r) == "table" and r.chance and not fraction(r.chance) then
        err("router " .. id, ("chance %s is not a printable fraction"):format(tostring(r.chance)))
    end
end

print(("\n%d error%s, %d warning%s"):format(errors, errors == 1 and "" or "s", warns, warns == 1 and "" or "s"))
os.exit(errors > 0 and 1 or 0)
