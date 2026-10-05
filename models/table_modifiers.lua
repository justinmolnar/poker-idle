-- models/table_modifiers.lua
--
-- What is acting on ONE table because of where it sits and what is around
-- it: the per-table item bonuses the EV readout already prices but never
-- names. The table header shows them as a row of item icons
-- (views/TablePanel drawHeader) and the EV tooltip lists them.
--
--   Yellow Sticky Note  +5% odds per empty side (inside the board's area)
--   Throw Pillow        x1.5 winnings with nothing on any side
--   Receipt Printer     Zoom: +pace per Zoom neighbour
--   Mirror              Heads-Up: +stack odds per Heads-Up table open
--   (a pending tier-up) the next win here lands a size up
--
-- Only what changes with the board, never per hand: a streak or a live
-- counter would rebuild the cached panel every hand (those have their own
-- live readouts). `sig` is one integer that moves exactly when the row's
-- picture would: the panel cache keys on it.
--
-- Allocation-free on a steady board: entries are reused, and the strings
-- are rebuilt only when the signature moves.

local Catalog = require("data.catalog")

local TableMods = {}

local _names
local function nameFor(id)
    if not id then return nil end
    if not _names then
        _names = {}
        for _, it in ipairs(Catalog) do _names[it.id] = it.name end
    end
    return _names[id] or id
end

local function pct(v) return string.format("%+d%%", math.floor(v * 100 + 0.5)) end

-- Fill tbl._mods (a reused list of { kind, item, text, tip }) and return
-- n, sig. `ctx` is the controller's rollup.
function TableMods.stamp(tbl, ctx)
    local list = tbl._mods
    if not list then list = {}; tbl._mods = list end
    if not ctx then tbl._mods_n, tbl._mods_sig = 0, 0; return 0, 0 end
    local src = ctx.sources or {}
    local sig, n = 0, 0
    local ea = tbl._empty_adjacent or 0
    local sticky = (ctx.odds_per_empty_adjacent or 0) > 0 and ea > 0
    local pillow = ctx.lonely_winnings_mult and tbl._lonely and true or false
    local zn = (tbl.game_type_id == "zoom" and (ctx.zoom_block_pace or 0) > 0) and (tbl._zoom_neighbours or 0) or 0
    local hu = (tbl.game_type_id == "hu" and (ctx.stack_odds_per_hu_table or 0) > 0)
               and math.min(31, ctx.hu_table_count or 0) or 0
    local tier = tbl._next_win_tier_up and true or false
    if sticky then sig = sig + ea end
    if pillow then sig = sig + 8 end
    sig = sig + 16 * zn + 128 * hu
    if tier then sig = sig + 8192 end
    if sig == tbl._mods_sig then return tbl._mods_n or 0, sig end

    local function add(kind, item, text, tip)
        n = n + 1
        local e = list[n]
        if not e then e = {}; list[n] = e end
        e.kind, e.item, e.text, e.tip = kind, item, text, tip
    end
    local function item(kind) local ids = src[kind]; return ids and ids[1] end
    if sticky then
        local id = item("odds_per_empty_adjacent")
        add("sticky", id, pct(ctx.odds_per_empty_adjacent * ea),
            string.format("%s: %s odds here (%d empty side%s)", nameFor(id) or "Empty sides",
                pct(ctx.odds_per_empty_adjacent * ea), ea, ea == 1 and "" or "s"))
    end
    if pillow then
        local id = item("lonely_winnings_mult")
        add("pillow", id, string.format("x%.1f", ctx.lonely_winnings_mult),
            string.format("%s: winnings x%.1f here (nothing on any side)", nameFor(id) or "Alone",
                ctx.lonely_winnings_mult))
    end
    if zn > 0 then
        local id = item("zoom_block_pace")
        add("zoom_block", id, pct(ctx.zoom_block_pace * zn),
            string.format("%s: %s pace here (%d Zoom neighbour%s)", nameFor(id) or "Zoom block",
                pct(ctx.zoom_block_pace * zn), zn, zn == 1 and "" or "s"))
    end
    if hu > 0 then
        local id = item("hu_stack_odds_per_hu_table")
        add("mirror", id, pct(ctx.stack_odds_per_hu_table * hu),
            string.format("%s: %s stack odds here (%d Heads-Up table%s open)", nameFor(id) or "Heads-Up",
                pct(ctx.stack_odds_per_hu_table * hu), hu, hu == 1 and "" or "s"))
    end
    if tier then
        add("tier_up", nil, "next win up", "The next win here lands a size up.")
    end
    for i = #list, n + 1, -1 do list[i] = nil end
    tbl._mods_n, tbl._mods_sig = n, sig
    return n, sig
end

return TableMods
