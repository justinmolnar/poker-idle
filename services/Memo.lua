-- services/Memo.lua
--
-- A keyed result cache for things that are expensive to build, cheap to
-- compare, and rebuilt far more often than they change — the derived UI:
-- tooltip line tables, EV breakdowns, range readouts. Each of those was
-- being rebuilt from scratch on the draw path every frame.
--
-- ─── The contract ──────────────────────────────────────────────────────
-- A caller supplies a KEY (what is being built) and a TOKEN (a value that
-- changes when the answer would change — usually GrindController.display_rev).
-- On a token match the stored value comes straight back; otherwise it is
-- rebuilt and stored. Nothing is evicted, so:
--
--   * The KEY SPACE MUST BE BOUNDED. These are per stake, per game type,
--     per upgrade, per catalog item — small fixed sets. Never key a memo on
--     something open-ended like a formatted money string.
--   * The stored value MUST BE TREATED AS READ-ONLY by every caller, since
--     they all share one table. Anything that needs to append (the debug
--     payout breakdown) must build fresh instead.
--
-- Entries are reused in place on a rebuild, so a steady state allocates
-- nothing at all.
--
-- Engine-agnostic; no love, no game knowledge.

local Memo = {}
Memo.__index = Memo

-- `name` is for debugging only.
function Memo.new(name)
    return setmetatable({ entries = {}, name = name }, Memo)
end

-- Up to four extra arguments are forwarded to `build`, so call sites can
-- stay closure-free (a closure per call would undo the point).
function Memo:get(key, token, build, a, b, c, d)
    local e = self.entries[key]
    if e ~= nil and e.token == token then return e.value end
    local value = build(a, b, c, d)
    if e then
        e.token, e.value = token, value
    else
        self.entries[key] = { token = token, value = value }
    end
    return value
end

-- Two-part key without concatenating a string on every lookup (a hit
-- allocates nothing). Same rules as :get.
function Memo:get2(k1, k2, token, build, a, b, c, d)
    local level = self.entries[k1]
    if not level then
        level = {}
        self.entries[k1] = level
    end
    local e = level[k2]
    if e ~= nil and e.token == token then return e.value end
    local value = build(a, b, c, d)
    if e then
        e.token, e.value = token, value
    else
        level[k2] = { token = token, value = value }
    end
    return value
end

function Memo:clear()
    self.entries = {}
end

return Memo
