-- utils/lookups.lua
--
-- Find an entry in an ordered data list by its `id`. Engine-agnostic and
-- game-agnostic: the lists are data/stakes, data/game_types, data/catalog,
-- data/run_upgrades and friends, and the callers are everywhere.
--
-- ─── Why this is indexed ───────────────────────────────────────────────
-- These were linear scans, and they sit in the frame: models/Table calls
-- findById ~19 times per deal and per update, views/TablePanel ~10 times
-- per panel per frame (plus one per opponent seat), GrindController ~18.
-- At 36 open tables that is thousands of scans over an 11-entry stake list
-- every frame.
--
-- So a list's id → entry map is built on first use and cached against the
-- list itself (weak keys: a temporary list does not pin its index). The
-- lists here are static data modules loaded once, but a cache that goes
-- stale silently would be a nasty class of bug, so the length is stamped
-- at build time and re-checked on every read — a list that grew or shrank
-- rebuilds. That check is one `#` against one integer, which is still O(1)
-- and still far cheaper than the scan it replaces.
--
-- Entries whose `id` is reassigned in place after indexing would go stale,
-- and nothing does that: ids are authored constants, and the one pass that
-- rewrites catalog entries (models/catalog_loader.deriveAll) only fills in
-- derived prices.

local Lookups = {}

-- list -> { n = #list at build, by_id = {...}, idx = {...} }
local _cache = setmetatable({}, { __mode = "k" })

local function indexOf(list)
    local e = _cache[list]
    if e and e.n == #list then return e end
    local by_id, idx = {}, {}
    for i, item in ipairs(list) do
        local id = item.id
        if id ~= nil and by_id[id] == nil then
            by_id[id] = item
            idx[id]   = i
        end
    end
    e = { n = #list, by_id = by_id, idx = idx }
    _cache[list] = e
    return e
end

-- The index for `list`, built if needed. Exposed for callers that want to
-- do many lookups against one list without paying the guard each time.
function Lookups.index(list)
    if not list then return nil end
    return indexOf(list).by_id
end

function Lookups.findById(list, id)
    if not list or id == nil then return nil end
    return indexOf(list).by_id[id]
end

function Lookups.indexById(list, id)
    if not list or id == nil then return nil end
    return indexOf(list).idx[id]
end

return Lookups
